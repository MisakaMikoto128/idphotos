/// ONNX Runtime 会话的创建、执行提供者选择与模型文件落地。
///
/// 两个约束决定了这里的写法：
///
/// 1. `assets/` 里的 `.onnx` 在 APK 里是压缩存放的，ORT 只能从**文件路径**
///    或完整字节数组加载。首次使用时把资源拷到 App 私有目录，之后直接读文件，
///    避免每次启动都把 7MB 塞进堆里。
/// 2. NNAPI 在部分机型（尤其是 int8 + 自定义算子组合）会在 session 创建阶段
///    直接失败或产出错误结果，因此按 XNNPACK → NNAPI → 纯 CPU 的顺序逐个尝试，
///    任一步失败都能降级，不会让 App 起不来。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

/// 抠图模型（MODNet photographic portrait matting，权重 int8 混合量化）。
const String kMattingModelAsset = 'assets/models/modnet_portrait_int8.onnx';

/// 人脸模型（YuNet 2023mar）。
const String kFaceModelAsset = 'assets/models/face_yunet_2023mar.onnx';

/// MODNet 的固定输入边长。参考实现用的就是 512，黄金集据此生成。
const int kMattingInputSize = 512;

/// YuNet 的固定输入边长。
const int kFaceInputSize = 640;

/// 开发/自测用：直接从磁盘目录读模型，跳过 assets 拷贝。
///
/// `native/bench/` 下的脚本与宿主机上的测试没有 `path_provider` 的
/// 应用目录，把这个设成仓库里的 `assets/models` 即可。生产代码不会设置它。
String? debugModelDirectory;

/// 把模型资源落地成一个可被 ORT 直接打开的文件路径。
Future<String> resolveModelPath(String assetKey) async {
  final fileName = assetKey.split('/').last;
  final override = debugModelDirectory;
  if (override != null) {
    final f = File('$override${Platform.pathSeparator}$fileName');
    if (!f.existsSync()) {
      throw StateError('model not found: ${f.path}');
    }
    return f.path;
  }
  final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}models');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final target = File('${dir.path}${Platform.pathSeparator}$fileName');
  final data = await rootBundle.load(assetKey);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  // 版本升级后资源体积会变，长度不一致就重写，避免读到上一版模型。
  if (!target.existsSync() || target.lengthSync() != bytes.length) {
    await target.writeAsBytes(bytes, flush: true);
  }
  return target.path;
}

/// 一次会话创建的结果，含实际生效的执行提供者，便于日志与降级排查。
class OrtSessionHandle {
  OrtSessionHandle(this.address, this.provider);

  final int address;
  final String provider;
}

/// 是否已经在当前 isolate 里创建过 ORT 环境。
///
/// `OrtEnv.init()` 不是幂等的：连续调用两次会各自 `CreateEnv` 一次，
/// 第二次直接覆盖 Dart 侧持有的指针，第一个环境的 native 内存从此没有任何
/// 句柄能再释放它。`_loadModels()`（见 matting_engine.dart）在同一个
/// `Isolate.run` 里先后为抠图、人脸两个模型各调一次 [createSession]，
/// 必须共用同一个环境，否则每次 `warmUp()` 都会静默泄漏一个 env。
bool _envInitialized = false;

void _ensureEnv() {
  if (_envInitialized) return;
  OrtEnv.instance.init(level: OrtLoggingLevel.error);
  _envInitialized = true;
}

/// 按 XNNPACK → NNAPI → CPU 的顺序创建会话，返回第一个成功的。
///
/// [threads] 为 intra-op 线程数。中端机大核通常 2–4 个，给 4 已经够用，
/// 再多反而因为调度抖动拉高 p95。
OrtSessionHandle createSession(String modelPath, {int threads = 4}) {
  _ensureEnv();
  // 刻意不用 `OrtSession.fromFile`：插件把路径按 UTF-8 `char*` 传给
  // `CreateSession`，而 Windows 上 ORT 的 `ORTCHAR_T` 是 `wchar_t`，
  // 路径会被解释成乱码、报 "File doesn't exist"。`CreateSessionFromArray`
  // 收字节数组，没有这个编码坑，各平台行为一致。
  final modelBytes = File(modelPath).readAsBytesSync();
  final attempts = <String>['xnnpack', 'nnapi', 'cpu'];
  Object? lastError;
  for (final ep in attempts) {
    if (ep == 'nnapi' && !Platform.isAndroid) {
      continue;
    }
    OrtSessionOptions? options;
    try {
      options = OrtSessionOptions()
        ..setInterOpNumThreads(1)
        ..setIntraOpNumThreads(threads)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
      switch (ep) {
        case 'xnnpack':
          options.appendXnnpackProvider();
          break;
        case 'nnapi':
          // 不给 useFp16：int8 权重在部分厂商的 NNAPI 实现上配合 fp16
          // 会产生明显偏差；宁可慢一点也要保证 mask 正确。
          options.appendNnapiProvider(NnapiFlags.useNone);
          break;
        case 'cpu':
          options.appendCPUProvider(CPUFlags.useArena);
          break;
      }
      final session = OrtSession.fromBuffer(modelBytes, options);
      return OrtSessionHandle(session.address, ep);
    } catch (e) {
      lastError = e;
    } finally {
      // 成功、失败两条路径都要释放：`OrtSession.fromBuffer` 成功后
      // session 内部已经拷走了它需要的配置，`options` 不再被引用，
      // 不释放就是每次成功 `warmUp()` 泄漏一个 native 对象。
      options?.release();
    }
  }
  throw StateError('failed to create ORT session for $modelPath: $lastError');
}

/// 在当前 isolate 里跑一次推理。输入为 NCHW float32。
List<OrtValue?> runFloatInput(
  int sessionAddress,
  Float32List input,
  List<int> shape,
  List<String> outputNames,
) {
  final session = OrtSession.fromAddress(sessionAddress);
  final tensor = OrtValueTensor.createTensorWithDataList(input, shape);
  final runOptions = OrtRunOptions();
  try {
    return session.run(runOptions, {session.inputNames.first: tensor},
        outputNames.isEmpty ? null : outputNames);
  } finally {
    tensor.release();
    runOptions.release();
  }
}

/// 释放会话。dispose 走这里，避免把 native 指针泄漏到进程结束。
void releaseSession(int address) {
  OrtSession.fromAddress(address).release();
}
