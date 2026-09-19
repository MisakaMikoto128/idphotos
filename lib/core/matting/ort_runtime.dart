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

import 'dart:convert' show jsonDecode, utf8;
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

// package:ffi 是 onnxruntime 插件的传递依赖，这里用它的 calloc/free 给
// FFI 调用分配出参/临时字符串内存（dart:ffi 自身没有分配器；pubspec 归
// 主会话，暂不能显式声明，见 G4 报告的接口请求）。
// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart' as fz;
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
// 下面两个是插件未从公共入口导出的内部绑定：OrtApi 的 ffigen 结构体
// （CreateArenaCfg / AddSessionConfigEntry 等 Dart 层没有包装的入口）与
// 预 lookup 的导出符号（NNAPI/CPU EP 的追加函数）。插件自带的 OrtApi 结构
// 与设备上的 libonnxruntime.so 1.15.1 同源，字段按序追加、向前兼容。
// ignore: implementation_imports
import 'package:onnxruntime/src/bindings/bindings.dart' as ob;
// ignore: implementation_imports
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart'
    as obg;
// ignore: implementation_imports
import 'package:path_provider/path_provider.dart';

/// 抠图模型（BiRefNet_lite，MIT 许可，来源 onnx-community/BiRefNet_lite-ONNX
/// fp32 导出件，权重 int8 混合量化 + 整数网格常量无损 fp16；生成脚本
/// native/quantize/build_birefnet_model.py，输入钉死 1024×1024）。
///
/// 2026-09-19 从 MODNet 换为 BiRefNet：MODNet 的发丝边缘是分割式的硬过渡，
/// 换红底后白边/色边明显；BiRefNet 输出真正的抠图 alpha（发丝级软过渡）。
/// 与 MODNet 的三处管线差异（缺一不可）：
///   1. 归一化：RGB 通道序 + ImageNet mean/std（见 image_ops.dart 的
///      kBirefnetMean/kBirefnetStd），不再是 BGR + (x/255−0.5)/0.5；
///   2. 输出是 **logits**，要过 sigmoid 才是 alpha（见 matting_worker.dart）；
///   3. 体积 67MB（MODNet 是 7.5MB），用户已批准"App 大点就大点"。
/// 旧 MODNet 模型保留在 assets/models/ 供 A/B 对照 bench 使用，验收通过后清理。
const String kMattingModelAsset = 'assets/models/birefnet_lite_1024_int8.onnx';

/// 人脸模型（YuNet 2023mar）。
const String kFaceModelAsset = 'assets/models/face_yunet_2023mar.onnx';

/// 抠图模型的固定输入边长。
///
/// BiRefNet_lite 导出件把输入钉死在 1024×1024（MODNet 时代 512→1024 换档
/// 的论证不变：发丝细节上限由模型输入分辨率决定）。
///
/// 所有以"模型像素"为单位的下游参数（去斑/平滑/碎片判据/羽化）都以
/// 本常量为基准换算，改这里即可整体换档，不要散落硬编码。
const int kMattingInputSize = 1024;

/// YuNet 的固定输入边长。
const int kFaceInputSize = 640;

/// 开发/自测用：直接从磁盘目录读模型，跳过 assets 拷贝。
///
/// `native/bench/` 下的脚本与宿主机上的测试没有 `path_provider` 的
/// 应用目录，把这个设成仓库里的 `assets/models` 即可。生产代码不会设置它。
String? debugModelDirectory;

/// Windows：把 onnxruntime.dll 预载进进程（幂等）。
///
/// 背景：插件的绑定层在 Windows 上执行 `DynamicLibrary.open('onnxruntime.dll')`，
/// 按 LoadLibrary 语义搜索"可执行文件所在目录 → 系统目录 → PATH"。
/// 两条运行形态的差别：
///
/// 1. **Flutter 桌面 App**（`flutter run -d windows` / build）：插件的
///    `windows/CMakeLists.txt` 把 vendored 插件里的 onnxruntime.dll 列进
///    `onnxruntime_bundled_libraries`，构建时自动拷到 runner.exe 旁边，
///    什么都不用做（候选 3 的 exe 旁路径覆盖同一文件，显式预载等价）。
/// 2. **`flutter test` / 宿主机 bench**（flutter_tester.exe）：没有任何
///    打包步骤，按名字搜索会命中**错误来源**——本机 System32 里躺着别的
///    软件装的 onnxruntime.dll 1.17.1（2026-09-19 实测劫持：标着"1.29 A/B"
///    的两组数字其实在跑 1.17.1）。所以**绝不先按名字 open**，一律按绝对
///    路径预载候选，全部失败才轮到按名字兜底。
///
/// 候选顺序：环境变量 `MUZHAO_ORT_DLL`（A/B 切换用）→ package_config 解析的
/// 插件包 windows/onnxruntime.dll（hosted/path 依赖都正确）→ 可执行文件旁
/// （App 形态）→ pub cache hosted 目录（旧布局兼容）。
/// 实际命中的路径记在 [ortLoadedFrom]，版本可经 [ortVersionString] 复核。
/// 非 Windows 平台是空操作。
///
/// 必须在**任何** ORT 绑定被触碰之前调用（warmUp / createSession 之前）。
bool ensureOrtRuntimeLoaded() {
  if (!Platform.isWindows) return false;
  final candidates = <String>[];
  final env = Platform.environment['MUZHAO_ORT_DLL'];
  if (env != null && env.isNotEmpty) {
    candidates.add(env);
  }
  // 2026-09-19 起 onnxruntime 改为 path 依赖（native/vendor/onnxruntime_flutter，
  // ORT 1.29.0 二进制）。宿主 test/bench 形态下按 package_config 解析插件的
  // 真实落点——不能只看 pub cache：那里残留 hosted 1.4.1 的旧 dll（1.15.1），
  // 抢先把旧库载进进程会让升级静默失效。
  final vendored = _pluginDllFromPackageConfig();
  if (vendored != null) {
    candidates.add(vendored);
  }
  candidates.add('${File(Platform.resolvedExecutable).parent.path}'
      '\\onnxruntime.dll');
  final pubCache = Platform.environment['PUB_CACHE'];
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final cacheRoots = <String>[
    if (pubCache != null && pubCache.isNotEmpty) pubCache,
    if (localAppData != null && localAppData.isNotEmpty)
      '$localAppData\\Pub\\Cache',
  ];
  for (final root in cacheRoots) {
    final hosted = Directory('$root${Platform.pathSeparator}hosted'
        '${Platform.pathSeparator}pub.dev');
    if (!hosted.existsSync()) continue;
    for (final e in hosted.listSync()) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (e is Directory && name.startsWith('onnxruntime-')) {
        candidates.add('${e.path}\\windows\\onnxruntime.dll');
      }
    }
  }
  for (final path in candidates) {
    if (!File(path).existsSync()) continue;
    try {
      ffi.DynamicLibrary.open(path);
      ortLoadFailureReason = null;
      ortLoadedFrom = path;
      return true;
    } catch (e) {
      // 换下一个候选，但**把原因留下来**：候选全失败时本函数只回 false，
      // 调用方随后撞上 ORT 绑定自己的 `onnxruntime.dll` 装载错误，那条消息
      // 不会说试过哪些路径、各自为什么失败。全部候选都失败时这里就是唯一线索。
      ortLoadFailureReason = '$path: $e';
    }
  }
  // 全部候选不可用：按名字兜底（App 形态的正常路径；宿主形态下若命中
  // System32 的异版 dll，ortLoadedFrom 会如实记下 'by-name' 供排查）。
  try {
    ffi.DynamicLibrary.open('onnxruntime.dll');
    ortLoadFailureReason = null;
    ortLoadedFrom ??= 'by-name (system search)';
    return false;
  } on ArgumentError {
    // 继续按候选路径找。
  } on IOException {
    // 同上（路径存在但加载失败等）。
  }
  return false;
}

/// 实际预载命中的 dll 路径（'by-name (system search)' 表示按名字命中系统
/// 搜索序——宿主形态下这通常意味着 System32 里异版 dll 劫持，要警惕）。
/// 与 [ortVersionString] 配合是"运行时版本自证"的两条腿。
String? ortLoadedFrom;

/// 从 `.dart_tool/package_config.json` 解析 onnxruntime 插件包的真实根目录，
/// 返回其 `windows/onnxruntime.dll` 路径（不存在返回 null）。
///
/// 同时兼容 hosted 与 path 两种依赖形态；flutter test / 宿主 bench 的 cwd 是
/// 仓库根目录，package_config 就在那里。解析失败一律返回 null（让候选链继续）。
String? _pluginDllFromPackageConfig() {
  try {
    final cfg = File('.dart_tool${Platform.pathSeparator}package_config.json');
    if (!cfg.existsSync()) return null;
    final json = jsonDecode(cfg.readAsStringSync()) as Map<String, dynamic>;
    for (final p in (json['packages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      if (p['name'] != 'onnxruntime') continue;
      // rootUri 可能是相对 package_config.json 的相对路径（path 依赖）或
      // file:/// 绝对 URI（hosted）。统一交给 Uri 解析。
      final root = Uri.parse(p['rootUri'] as String);
      final resolved = root.isAbsolute
          ? root.toFilePath()
          : Uri.file('${cfg.parent.path}${Platform.pathSeparator}')
              .resolveUri(root)
              .toFilePath();
      final dll = '$resolved${Platform.pathSeparator}windows'
          '${Platform.pathSeparator}onnxruntime.dll';
      if (File(dll).existsSync()) return dll;
    }
  } catch (_) {
    // 解析失败不挡路：返回 null，候选链继续。
  }
  return null;
}

/// 最近一次候选路径装载失败的原因（`"<path>: <error>"`），成功装载或按名字
/// 直接打开时置 null。仅供排查——见 [ensureOrtRuntimeLoaded]。
String? ortLoadFailureReason;

/// 当前进程实际加载的 ORT 库版本字符串（如 "1.15.1" / "1.29.0"）。
///
/// 排查口：二进制替换（vendor 升级）或预载路径出错时，这里说的是**实际生效**
/// 的版本，比 pubspec.lock 可信。必须在任一 ORT 绑定被触碰后调用才有意义
/// （本质是问已加载的 dll/so 要版本号）。
String ortVersionString() {
  final base = ob.onnxRuntimeBinding.OrtGetApiBase();
  final fn = base.ref.GetVersionString
      .asFunction<ffi.Pointer<ffi.Char> Function()>();
  return fn().cast<fz.Utf8>().toDartString();
}

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

/// 抠图会话的默认 intra-op 线程数（2026-09-19 提速专项标定）。
///
/// 标定数据（native/bench/ort_speed_sweep_test.dart 轮询交替采样，PC 16 逻辑
/// 核）：t4→t6 的 min 口径 −6~9%（1.15.1 与 1.29 一致），t8 的 min 更好但
/// p95 在负载下显著劣化（更多线程对争抢更敏感），取 6 为上界。
/// 中低端 Android（4–8 逻辑核）落在 2–4，与阶段 2 的原默认一致。
int defaultInferenceThreads() {
  final n = Platform.numberOfProcessors;
  if (n >= 12) return 6;
  if (n >= 6) return 4;
  return 2;
}

/// 按 XNNPACK → NNAPI → CPU 的顺序创建会话，返回第一个成功的。
///
/// [threads] 为 intra-op 线程数；null（默认）按 [defaultInferenceThreads]
/// 自适应。中端机大核通常 2–4 个，给 4 已经够用，再多反而因为调度抖动
/// 拉高 p95。
///
/// 内存口径（G4.7 floor）：本函数绕过插件的 `OrtSessionOptions`，直接走
/// OrtApi 的 FFI 入口建会话（插件不暴露 options 的 native 指针，无法在其上
/// 附加 session config entry）。除 arena 政策（见 [_ensureEnvAllocatorPolicy]）
/// 外，EP 顺序、线程数、图优化级别与旧实现逐项一致，输出已用探针验证
/// 与插件路径逐位一致（native/bench/ort_footprint_probe_test.dart）。
///
/// **arena 政策默认不启用**（G4 r5 实测矩阵，见 ml_probe2_main.dart）：
/// kSameAsRequested 共享 arena 选入 + XNNPACK = 首次推理 SIGSEGV
/// （ORT 1.15.1，x86_64 模拟器，arm64 无法在本机验证故按有坑处理）；
/// 关掉 CPU arena（DisableCpuMemArena）+ XNNPACK 同样崩——XNNPACK 路径
/// 只能用默认 arena 配置。CPU 直连（无 XNNPACK）+ kSameAsRequested 实测
/// 稳定，但瞬态峰值反而更高（+75MB vs +25MB）。要启用需显式调
/// [applySameAsRequestedArena]（生产代码不要调）。
OrtSessionHandle createSession(String modelPath, {int? threads}) {
  _ensureEnv();
  final intra = threads ?? defaultInferenceThreads();
  if (debugUsePluginSessionCreation) {
    return _createSessionViaPlugin(modelPath, threads: intra);
  }
  // 刻意不用 `OrtSession.fromFile`：插件把路径按 UTF-8 `char*` 传给
  // `CreateSession`，而 Windows 上 ORT 的 `ORTCHAR_T` 是 `wchar_t`，
  // 路径会被解释成乱码、报 "File doesn't exist"。`CreateSessionFromArray`
  // 收字节数组，没有这个编码坑，各平台行为一致。
  final modelBytes = File(modelPath).readAsBytesSync();
  final api = OrtEnv.instance.ortApiPtr.ref;
  final env = OrtEnv.instance.ptr;
  final attempts = debugForceEp != null
      ? <String>[debugForceEp!]
      : <String>['xnnpack', 'nnapi', 'cpu'];
  Object? lastError;
  lastEpErrors.clear();
  for (final ep in attempts) {
    if (ep == 'nnapi' && !Platform.isAndroid) {
      continue;
    }
    ffi.Pointer<obg.OrtSessionOptions>? options;
    try {
      options = _createSessionOptions(api, ep, intra);
      if (_envAllocatorReady && !debugOptOutEnvAllocator) {
        // 会话显式改用环境共享分配器（CreateAndRegisterAllocator 注册的那份，
        // 带 kSameAsRequested arena）。键名在 ORT 1.15 的
        // kOrtSessionOptionsConfigUseEnvAllocators，未知键会在建会话时报错。
        _setConfigEntry(
            api, options, 'session.use_env_allocators', '1');
      }
      final sessionPtr =
          _createSessionFromArray(api, env, options, modelBytes);
      try {
        final session = OrtSession.fromAddress(sessionPtr.address);
        return OrtSessionHandle(session.address, ep);
      } catch (e) {
        // fromAddress 的 _init（读输入输出名）意外失败：释放 native 会话
        // 再交给外层记录 lastError，否则下一个 EP 尝试前留一个泄漏。
        releaseSession(sessionPtr.address);
        rethrow;
      }
    } catch (e) {
      lastError = e;
      lastEpErrors[ep] = e.toString();
    } finally {
      // 成功、失败两条路径都要释放：`CreateSessionFromArray` 成功后
      // session 内部已经拷走了它需要的配置，`options` 不再被引用，
      // 不释放就是每次成功 `warmUp()` 泄漏一个 native 对象。
      if (options != null) {
        api.ReleaseSessionOptions.asFunction<
            void Function(ffi.Pointer<obg.OrtSessionOptions>)>()(options);
      }
    }
  }
  throw StateError('failed to create ORT session for $modelPath: $lastError');
}

/// OrtArenaCfg 的 `arena_extend_strategy` 取值（onnxruntime_c_api.h）：
/// 0 = kNextPowerOf2（默认，arena 按 2 的幂扩张，首个大张量会把整块 arena
/// 顶到远超实际需要），1 = kSameAsRequested（按需分配，与推理峰值成比例）。
const int kArenaExtendSameAsRequested = 1;

/// bench A/B 钩子：true 时新建的会话**不**选择环境共享分配器（回退 ORT
/// 默认的 kNextPowerOf2 arena）。只允许 native/bench 的探针翻转，
/// 生产代码保持 false。
bool debugOptOutEnvAllocator = false;

/// bench 钩子：true 时**不做**环境分配器注册（探针归因用：区分"FFI 建会话
/// 本身"与"arena 政策"两个变量）。生产代码保持 false。
bool debugSkipEnvAllocatorRegistration = false;

/// bench 钩子：非 null 时只尝试这一个执行提供者（如 'cpu'）。
/// 生产代码保持 null（按 XNNPACK → NNAPI → CPU 顺序降级）。
String? debugForceEp;

/// bench 钩子：true 时对会话调 `DisableCpuMemArena`（关掉 BFC arena，
/// 张量直接走分配器）——XNNPACK + kSameAsRequested 共享 arena 组合会崩
/// （实测 SIGSEGV），关 arena 是 floor 压缩的替代杠杆，性能代价待测。
/// 生产代码保持 false。
bool debugDisableCpuMemArena = false;

/// bench 钩子：true 时走插件自带的 `OrtSessionOptions`+`fromBuffer`
/// 建会话（归因基准：把"FFI 建会话"从方程里消掉）。生产代码保持 false。
bool debugUsePluginSessionCreation = false;

/// bench 钩子：非 null 时覆盖 inter-op 线程数（生产恒为 1）。
int? debugInterOpThreads;

/// bench 钩子：true 时对会话调 `DisableMemPattern`（默认启用内存模式）。
/// 生产代码保持 false。
bool debugDisableMemPattern = false;

/// bench 钩子：true 时把会话执行模式切到 PARALLEL（配合 inter-op>1 才有意义）。
/// 生产代码保持 false（SEQUENTIAL）。
bool debugParallelExecutionMode = false;

/// bench 钩子：true 时设 `session.set_denormal_as_zero=1`（denormal 刷新为零，
/// 部分 fp32 负载可免去 denormal 微码陷阱）。生产代码保持 false。
bool debugSetDenormalAsZero = false;

/// bench 钩子：true 时设 `session.disable_prepacking=1`（关掉权重预打包——
/// 预打包会把 fp32 权重再拷一份 packed 布局，大模型上省 ~200MB 常驻，
/// 代价是 conv 走非打包 kernel 变慢）。生产代码保持 false。
bool debugDisablePrepacking = false;

/// 最近一次 [createSession] 每个 EP 的失败原因（成功的 EP 不在表里）。
/// 仅供 bench/排查读取。
final Map<String, String> lastEpErrors = <String, String>{};

/// 把 bench 钩子打包（跨 isolate 传递用）。这些全局量在工厂 isolate 里有
/// **独立副本**——Isolate.spawn 不继承主 isolate 的全局量，必须在孵化时
/// 显式带过去，否则 bench 的 A/B 开关在工厂里全部静默失效（踩过：
/// 所有变体看起来都在跑，实际跑的全是同一份生产配置）。
Map<String, Object?> debugBenchFlags() => <String, Object?>{
      'optOutEnvAllocator': debugOptOutEnvAllocator,
      'skipEnvAllocatorRegistration': debugSkipEnvAllocatorRegistration,
      'forceEp': debugForceEp,
      'usePluginSessionCreation': debugUsePluginSessionCreation,
      'disableCpuMemArena': debugDisableCpuMemArena,
      'interOpThreads': debugInterOpThreads,
      'disableMemPattern': debugDisableMemPattern,
      'parallelExecutionMode': debugParallelExecutionMode,
      'setDenormalAsZero': debugSetDenormalAsZero,
      'disablePrepacking': debugDisablePrepacking,
    };

/// 在工厂 isolate 里应用 [debugBenchFlags] 的快照。
void applyDebugBenchFlags(Map<Object?, Object?> f) {
  if (f.isEmpty) return;
  debugOptOutEnvAllocator = f['optOutEnvAllocator'] == true;
  debugSkipEnvAllocatorRegistration =
      f['skipEnvAllocatorRegistration'] == true;
  debugUsePluginSessionCreation = f['usePluginSessionCreation'] == true;
  debugDisableCpuMemArena = f['disableCpuMemArena'] == true;
  debugInterOpThreads = f['interOpThreads'] as int?;
  debugDisableMemPattern = f['disableMemPattern'] == true;
  debugParallelExecutionMode = f['parallelExecutionMode'] == true;
  debugSetDenormalAsZero = f['setDenormalAsZero'] == true;
  debugDisablePrepacking = f['disablePrepacking'] == true;
  debugForceEp = f['forceEp'] as String?;
}

/// 插件原生路径（旧实现原样保留，仅供 bench 归因对照）。
OrtSessionHandle _createSessionViaPlugin(String modelPath, {int threads = 4}) {
  final modelBytes = File(modelPath).readAsBytesSync();
  final attempts = <String>['xnnpack', 'nnapi', 'cpu'];
  Object? lastError;
  for (final ep in attempts) {
    if (ep == 'nnapi' && !Platform.isAndroid) continue;
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
      options?.release();
    }
  }
  throw StateError(
      'failed to create ORT session for $modelPath: $lastError');
}

/// 显式应用环境分配器政策（幂等）。返回是否已生效；未生效原因见
/// [arenaPolicyError]。
bool applySameAsRequestedArena() {
  _ensureEnvAllocatorPolicy();
  return _envAllocatorReady;
}

/// 环境级共享分配器是否已注册成功。false 时会话回退到默认 arena，
/// [arenaPolicyError] 说明原因（供 bench/报告取证，不影响功能）。
bool _envAllocatorReady = false;
String? arenaPolicyError;

/// 注册**环境级共享 CPU 分配器**（arena 扩张策略 = kSameAsRequested）。
///
/// 每进程只做一次，必须在**拥有 OrtEnv 的 isolate**（工厂）里调用——
/// 注册动作记在 OrtEnv 上，之后同 env 建的会话经
/// `session.use_env_allocators=1` 选择性改用它（ORT 的官方挂接方式：
/// C API 没有 SessionOptionsSetArenaCfg，只能 env 注册 + 会话配置项）。
/// 两个会话共用这一个 arena，顺序推理互不重叠，不存在并发争用。
///
/// 失败不抛：只记账并回退到默认 arena。理由——这是内存优化而非功能；
/// 若在这里抛，个别机型上注册失败会把整个引擎钉死（4.1 崩溃回归），
/// 而"floor 偏高"是可被 gate 数字如实暴露的。
void _ensureEnvAllocatorPolicy() {
  if (_envAllocatorReady || debugSkipEnvAllocatorRegistration) return;
  try {
    final api = OrtEnv.instance.ortApiPtr.ref;
    // 进程级默认 CPU 分配器：它的 OrtMemoryInfo 正是 CPU EP 请求分配器时
    // 使用的那个 info——用 AllocatorGetInfo 取它而不是自己 CreateCpuMemoryInfo，
    // 匹配键（name/type/id/mem_type）由 ORT 自己保证一致。
    final allocPP = fz.calloc<ffi.Pointer<obg.OrtAllocator>>();
    final infoPP = fz.calloc<ffi.Pointer<obg.OrtMemoryInfo>>();
    final cfgPP = fz.calloc<ffi.Pointer<obg.OrtArenaCfg>>();
    try {
      _checkOrt(
          api.GetAllocatorWithDefaultOptions.asFunction<
              obg.OrtStatusPtr Function(
                  ffi.Pointer<ffi.Pointer<obg.OrtAllocator>>)>()(allocPP),
          'GetAllocatorWithDefaultOptions');
      final allocator = allocPP.value;
      _checkOrt(
          api.AllocatorGetInfo.asFunction<
              obg.OrtStatusPtr Function(ffi.Pointer<obg.OrtAllocator>,
                  ffi.Pointer<ffi.Pointer<obg.OrtMemoryInfo>>)>()(
              allocator, infoPP),
          'AllocatorGetInfo');
      final memInfo = infoPP.value; // 常量，属 allocator 所有，不释放
      _checkOrt(
          api.CreateArenaCfg.asFunction<
                  obg.OrtStatusPtr Function(
                      int,
                      int,
                      int,
                      int,
                      ffi.Pointer<ffi.Pointer<obg.OrtArenaCfg>>)>()(0,
              // max_mem=0、chunk 尺寸 -1：除扩张策略外全用 ORT 默认值。
              kArenaExtendSameAsRequested, -1, -1, cfgPP),
          'CreateArenaCfg');
      final arenaCfg = cfgPP.value;
      // 刻意**不** ReleaseArenaCfg：ORT 1.15 的 CreateAndRegisterAllocator
      // 对 cfg 的所有权语义不明（C API 文档未注明是否拷贝）。这是进程级
      // 一次性 ~40 字节结构体，留活到进程结束最稳——若 ORT 内部仍持指针，
      // 提前释放会把该分配器的每次使用都变成未定义行为。
      _checkOrt(
          api.CreateAndRegisterAllocator.asFunction<
                  obg.OrtStatusPtr Function(
                      ffi.Pointer<obg.OrtEnv>,
                      ffi.Pointer<obg.OrtMemoryInfo>,
                      ffi.Pointer<obg.OrtArenaCfg>)>()(
              OrtEnv.instance.ptr, memInfo, arenaCfg),
          'CreateAndRegisterAllocator');
      _envAllocatorReady = true;
    } finally {
      fz.calloc
        ..free(allocPP)
        ..free(infoPP)
        ..free(cfgPP);
    }
  } catch (e) {
    arenaPolicyError = e.toString();
  }
}

/// 设置一条 session config entry（键值都是临时 native 字符串，调用后即还）。
void _setConfigEntry(obg.OrtApi api, ffi.Pointer<obg.OrtSessionOptions> options,
    String key, String value) {
  final k = _toNativeUtf8(key);
  final v = _toNativeUtf8(value);
  try {
    _checkOrt(
        api.AddSessionConfigEntry.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<obg.OrtSessionOptions>,
                    ffi.Pointer<ffi.Char>,
                    ffi.Pointer<ffi.Char>)>()(options, k, v),
        'AddSessionConfigEntry($key)');
  } finally {
    fz.calloc
      ..free(k)
      ..free(v);
  }
}

/// 建会话 options 并按 [ep] 追加执行提供者。失败时（含 status 错误）抛出，
/// 调用方负责释放已建出的 options。
ffi.Pointer<obg.OrtSessionOptions> _createSessionOptions(
    obg.OrtApi api, String ep, int threads) {
  final pp = fz.calloc<ffi.Pointer<obg.OrtSessionOptions>>();
  try {
    _checkOrt(
        api.CreateSessionOptions.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<ffi.Pointer<obg.OrtSessionOptions>>)>()(pp),
        'CreateSessionOptions');
  } catch (_) {
    fz.calloc.free(pp);
    rethrow;
  }
  final options = pp.value;
  fz.calloc.free(pp);
  try {
    _checkOrt(
        api.SetIntraOpNumThreads.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<obg.OrtSessionOptions>, int)>()(
            options, threads),
        'SetIntraOpNumThreads');
    _checkOrt(
        api.SetInterOpNumThreads.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<obg.OrtSessionOptions>, int)>()(
            options, debugInterOpThreads ?? 1),
        'SetInterOpNumThreads');
    _checkOrt(
        api.SetSessionGraphOptimizationLevel.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<obg.OrtSessionOptions>, int)>()(
            options, GraphOptimizationLevel.ortEnableAll.value),
        'SetSessionGraphOptimizationLevel');
    if (debugDisableMemPattern) {
      _checkOrt(
          api.DisableMemPattern.asFunction<
              obg.OrtStatusPtr Function(
                  ffi.Pointer<obg.OrtSessionOptions>)>()(options),
          'DisableMemPattern');
    }
    if (debugParallelExecutionMode) {
      // ExecutionMode.ORT_PARALLEL = 1（onnxruntime_c_api.h）。
      _checkOrt(
          api.SetSessionExecutionMode.asFunction<
              obg.OrtStatusPtr Function(
                  ffi.Pointer<obg.OrtSessionOptions>, int)>()(options, 1),
          'SetSessionExecutionMode(PARALLEL)');
    }
    if (debugSetDenormalAsZero) {
      _setConfigEntry(api, options, 'session.set_denormal_as_zero', '1');
    }
    if (debugDisablePrepacking) {
      _setConfigEntry(api, options, 'session.disable_prepacking', '1');
    }
    if (debugDisableCpuMemArena) {
      final disableArena = api.DisableCpuMemArena.asFunction<
          obg.OrtStatusPtr Function(ffi.Pointer<obg.OrtSessionOptions>)>();
      _checkOrt(disableArena(options), 'DisableCpuMemArena');
    }
    switch (ep) {
      case 'xnnpack':
        // 与插件 appendXnnpackProvider 同参：provider options 里传
        // intra_op_num_threads（XNNPACK 自己的线程池规模）。
        final name = _toNativeUtf8('XNNPACK');
        final key = _toNativeUtf8('intra_op_num_threads');
        final val = _toNativeUtf8('$threads');
        final keys = fz.calloc<ffi.Pointer<ffi.Char>>();
        final vals = fz.calloc<ffi.Pointer<ffi.Char>>();
        try {
          keys[0] = key;
          vals[0] = val;
          _checkOrt(
              api.SessionOptionsAppendExecutionProvider.asFunction<
                      obg.OrtStatusPtr Function(
                          ffi.Pointer<obg.OrtSessionOptions>,
                          ffi.Pointer<ffi.Char>,
                          ffi.Pointer<ffi.Pointer<ffi.Char>>,
                          ffi.Pointer<ffi.Pointer<ffi.Char>>,
                          int)>()(options, name, keys, vals, 1),
              'AppendExecutionProvider(XNNPACK)');
        } finally {
          fz.calloc
            ..free(name)
            ..free(key)
            ..free(val)
            ..free(keys)
            ..free(vals);
        }
        break;
      case 'nnapi':
        // 不给 useFp16：int8 权重在部分厂商的 NNAPI 实现上配合 fp16
        // 会产生明显偏差；宁可慢一点也要保证 mask 正确。
        _checkOrt(ob.onnxRuntimeBinding.OrtSessionOptionsAppendExecutionProvider_Nnapi(
                options, NnapiFlags.useNone.value),
            'AppendExecutionProvider(NNAPI)');
        break;
      case 'cpu':
        _checkOrt(ob.onnxRuntimeBinding.OrtSessionOptionsAppendExecutionProvider_CPU(
                options, CPUFlags.useArena.value),
            'AppendExecutionProvider(CPU)');
        break;
    }
    return options;
  } catch (_) {
    api.ReleaseSessionOptions.asFunction<
        void Function(ffi.Pointer<obg.OrtSessionOptions>)>()(options);
    rethrow;
  }
}

/// `CreateSessionFromArray` + 插件 `OrtSession.fromAddress` 包装。
/// 成功返回的 session 由调用方持有（releaseSession 释放）。
ffi.Pointer<obg.OrtSession> _createSessionFromArray(obg.OrtApi api,
    ffi.Pointer<obg.OrtEnv> env, ffi.Pointer<obg.OrtSessionOptions> options,
    Uint8List modelBytes) {
  final buf = fz.calloc<ffi.Uint8>(modelBytes.length);
  buf.asTypedList(modelBytes.length).setAll(0, modelBytes);
  final sessPP = fz.calloc<ffi.Pointer<obg.OrtSession>>();
  try {
    _checkOrt(
        api.CreateSessionFromArray.asFunction<
                obg.OrtStatusPtr Function(
                    ffi.Pointer<obg.OrtEnv>,
                    ffi.Pointer<ffi.Void>,
                    int,
                    ffi.Pointer<obg.OrtSessionOptions>,
                    ffi.Pointer<ffi.Pointer<obg.OrtSession>>)>()(
            env, buf.cast(), modelBytes.length, options, sessPP),
        'CreateSessionFromArray');
    return sessPP.value;
  } finally {
    fz.calloc
      ..free(buf)
      ..free(sessPP);
  }
}

/// 非 OK 的 OrtStatus 取出错误信息后抛 [StateError]（信息进异常文本，
/// 便于 warmUp 失败原因与 bench 日志定位）。
void _checkOrt(obg.OrtStatusPtr? status, String what) {
  if (status == null || status == ffi.nullptr) return;
  final api = OrtEnv.instance.ortApiPtr.ref;
  final msg = api.GetErrorMessage.asFunction<
          ffi.Pointer<ffi.Char> Function(obg.OrtStatusPtr)>()(status)
      .cast<fz.Utf8>()
      .toDartString();
  api.ReleaseStatus
      .asFunction<void Function(obg.OrtStatusPtr)>()(status);
  throw StateError('ORT $what failed: $msg');
}

/// UTF-8 + NUL 结尾的临时 native 字符串。调用方用完必须 `fz.calloc.free`。
ffi.Pointer<ffi.Char> _toNativeUtf8(String s) {
  final units = utf8.encode(s);
  final p = fz.calloc<ffi.Uint8>(units.length + 1);
  p.asTypedList(units.length + 1)
    ..setAll(0, units)
    ..[units.length] = 0;
  return p.cast<ffi.Char>();
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
