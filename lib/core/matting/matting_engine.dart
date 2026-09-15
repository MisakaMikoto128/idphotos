/// 抠图 / 人脸检测引擎。
///
/// 实现 `docs/CONTRACTS.md` 第 2 节里归 ml-porting 的三个方法：
/// [MattingEngineMixin.warmUp]、[MattingEngineMixin.removeBackground]、
/// [MattingEngineMixin.detectFace]。
///
/// 用法（阶段 3 由主会话接线）：
///
/// ```dart
/// class IdPhotoEngineImpl with MattingEngineMixin, ComposeEngineMixin
///     implements IdPhotoEngine {
///   @override
///   void dispose() => disposeMattingEngine();
/// }
/// ```
///
/// 内存口径（G4.7）：长边 > [kEngineMaxEdge] 的图先读文件头规划工作分辨率，
/// dart:ui 原生降采样解码（失败退化到 image 包解码后降采样），全程不持有
/// 全尺寸像素缓冲；[MattingResult] 的 rgba/alpha/width/height 均为**引擎
/// 工作分辨率**，与原图等比（见该类的契约注记）。黄金集（≤2048）不受影响。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../api.dart';
import 'flutter_decode.dart';
import 'image_ops.dart';
import 'matting_worker.dart';
import 'ort_runtime.dart';
import 'session_factory.dart';

/// MODNet + YuNet 的端侧实现。全程本地，不触网。
mixin MattingEngineMixin {
  int? _mattingSession;
  int? _faceSession;
  Future<void>? _warmUp;
  SessionFactory? _factory;

  /// 单槽人脸缓存（G4.3 人像门槛 + G4.7 内存）：key 是**同一实例**的输入
  /// bytes。controller/批量 runner 对同一张图先 removeBackground（内部要跑
  /// 人像门槛）再 detectFace，第二次直接命中缓存，省一次解码 + 一次 YuNet
  /// 推理；key 用 identical() 保证绝不会把 A 图的脸配给 B 图。缓存值可能是
  /// null（确实没有合格人脸），所以用 [_faceCacheValid] 区分"没缓存过"。
  Uint8List? _faceCacheKey;
  FaceInfo? _faceCacheValue;
  bool _faceCacheValid = false;

  /// 已生效的执行提供者，形如 `xnnpack` / `nnapi` / `cpu`。仅供排查。
  String? get mattingProvider => _mattingProvider;
  String? _mattingProvider;

  /// 工厂 isolate 里 OrtEnv 的 native 地址，供 bench 验证
  /// "每进程一个 env"（warmUp 失败重试前后必须同值）。生产代码勿用。
  int? get debugEnvAddress => _factory?.envAddress;

  /// 加载两个模型。重复调用幂等：并发调用共享同一个 Future。
  Future<void> warmUp() {
    return _warmUp ??= _loadModels().catchError((Object e, StackTrace s) {
      // 失败后允许重试，否则一次瞬时故障会把引擎永久钉死。
      // 重试复用同一个 [_factory]（见 session_factory.dart 头注）：
      // env 不会随重试次数增长。
      _warmUp = null;
      throw MattingException(cause: e.toString());
    });
  }

  Future<void> _loadModels() async {
    if (_mattingSession != null && _faceSession != null) return;
    final mattingPath = await resolveModelPath(kMattingModelAsset);
    final facePath = await resolveModelPath(kFaceModelAsset);
    // 建会话要读 7MB 模型并做图优化，放后台 isolate，别卡住首帧。
    // 会话创建固定在常驻的工厂 isolate 里（env 每进程只建一次），
    // 推理另用瞬态 Isolate.run（不触 env，见 session_factory.dart 头注）。
    final factory = _factory ??= SessionFactory();
    final matting = await factory.createSessionInFactory(mattingPath);
    if (!matting.ok) {
      throw StateError('matting session: ${matting.error}');
    }
    final face =
        await factory.createSessionInFactory(facePath, threads: 2);
    if (!face.ok) {
      // 抠图会话已建、人脸会话失败：释放前者，别留半个引擎。
      releaseSession(matting.address);
      throw StateError('face session: ${face.error}');
    }
    _mattingSession = matting.address;
    _mattingProvider = matting.provider;
    _faceSession = face.address;
  }

  Future<int> _requireSession(bool matting) async {
    await warmUp();
    final s = matting ? _mattingSession : _faceSession;
    if (s == null) {
      throw const MattingException();
    }
    return s;
  }

  /// 抠图。
  ///
  /// 返回的 rgba / alpha 同分辨率，为**引擎工作分辨率**：原图等比降采样
  /// 到长边 ≤ [kEngineMaxEdge]（原图本就 ≤ 该值时两者相同）。width/height
  /// 如实描述返回缓冲，合成与几何全部按它自洽工作；与原图坐标的换算只
  /// 依赖 `原图尺寸 / width` 这一个等比系数。
  ///
  /// - 解不开的文件 → [UnsupportedImageException]
  /// - 长边 > [kMaxImageEdgePx] → [ImageTooLargeException]（读文件头即抛，
  ///   不先解码）
  /// - 检不到合格人脸（非人像或主脸过小，门槛见 matting_worker.dart）→
  ///   [NoFaceException]（"没找到人脸，请手动框选"）；alpha 呈碎片状 →
  ///   [MattingException]
  Future<MattingResult> removeBackground(Uint8List imageBytes) async {
    final session = await _requireSession(true);
    // 人像门槛裁决优先吃缓存：同一 bytes 实例上次已检过脸，直接用结论，
    // 连解码都可以省（检不过的图在这儿就抛，不再进解码/推理管线）。
    // 缓存值在本 await 之前就拷进局部量，避免并发调用中途换条目。
    final gateKnown = identical(_faceCacheKey, imageBytes) && _faceCacheValid;
    final gatePassed = gateKnown && _faceCacheValue != null;
    if (gateKnown && !gatePassed) {
      throw const NoFaceException(cause: 'face gate (cached): no face');
    }
    // 会话常驻，热路径上 faceSession 非空；空则本轮跳过门槛（不抛），
    // 保持"会话异常不改变拒绝语义"的旧兜底行为。
    final faceSession = _faceSession;
    final runGate = !gateKnown && faceSession != null;
    try {
      // 头部预扫与降采样解码都在**宿主** isolate 做：instantiateImageCodec
      // 是异步原生解码，不卡 UI 线程；后台 isolate 能否用 dart:ui 解码
      // 未探针钉死，不押注。plan 为 null 或解码失败时，兜底路径在
      // worker isolate 里全尺寸解码后立即降采样。
      final plan = planWorkingSize(imageBytes);
      Uint8List? rgba;
      if (plan != null &&
          plan.downsampled &&
          plan.orientation < 5) {
        final decoded =
            await decodeDownsampledUi(imageBytes, plan.width, plan.height);
        if (decoded != null) {
          rgba = decoded.rgba;
        }
      }
      // 两条路径拆成两个闭包：闭包只捕获自己真正引用的变量。合并写法会把
      // imageBytes 一并拷进降采样路径的 worker isolate（一次全文件大小的
      // 无谓拷贝，G4.7 瞬时滞留的直接来源之一）。
      final MattingPayload payload;
      if (rgba != null && plan != null) {
        final r = rgba;
        final p = plan;
        payload = await Isolate.run(() {
          // alpha-only 路径：worker 只回 alpha（+人像门槛的检脸结果），
          // rgba 缓冲留在宿主，就地强制 A=255 后直接作为结果——不跨
          // isolate 搬运、不重建 w*h*4 大缓冲（G4.7 瞬时滞留压缩）。
          return runMattingAlphaOnly(
            rgbaToDecoded(
              r,
              p.width,
              p.height,
              sourceWidth: p.sourceWidth,
              sourceHeight: p.sourceHeight,
            ),
            session,
            faceSessionAddress: runGate ? faceSession : null,
          );
        });
      } else {
        payload = await Isolate.run(() {
          return runMattingSync(imageBytes, session,
              maxEdge: kEngineMaxEdge,
              faceSessionAddress: runGate ? faceSession : null);
        });
      }
      if (runGate) {
        // 只有真正跑过检脸才更新缓存，门槛被跳过时保留旧结论。
        _faceCacheKey = imageBytes;
        _faceCacheValue = payload.subjectFace;
        _faceCacheValid = true;
      }
      if (payload.alphaOnly) {
        // 宿主自己持有的 rgba，就地改写 alpha 字节（契约：A 恒 255）。
        for (var i = 3; i < rgba!.length; i += 4) {
          rgba[i] = 255;
        }
        return payload.materialize(rgbaOverride: rgba);
      }
      return payload.materialize();
    } on IdPhotoException {
      rethrow;
    } catch (e) {
      // ORT / 解码库抛出的原始错误统一翻译成契约异常，绝不让它穿到 UI。
      throw MattingException(cause: e.toString());
    }
  }

  /// 人脸检测。**没有人脸时返回 null，不抛异常。**
  ///
  /// 返回的 [FaceInfo] 坐标与 [removeBackground] 的 MattingResult 同一
  /// 坐标系（引擎工作分辨率）。
  ///
  /// 图片本身打不开仍会抛 [UnsupportedImageException] / [ImageTooLargeException]
  /// ——那是"图有问题"，不是"没有人脸"。推理层面的意外失败翻译成
  /// [MattingException]；这里刻意不吞异常，否则模型坏掉会伪装成"这张图没人脸"。
  ///
  /// 对与最近一次检脸**同一实例**的输入直接命中单槽缓存（removeBackground
  /// 的人像门槛已对它检过），不再解码、不再推理。
  Future<FaceInfo?> detectFace(Uint8List imageBytes) async {
    if (identical(_faceCacheKey, imageBytes) && _faceCacheValid) {
      return _faceCacheValue;
    }
    final session = await _requireSession(false);
    try {
      final plan = planWorkingSize(imageBytes);
      Uint8List? rgba;
      if (plan != null && plan.downsampled && plan.orientation < 5) {
        final decoded =
            await decodeDownsampledUi(imageBytes, plan.width, plan.height);
        if (decoded != null) {
          rgba = decoded.rgba;
        }
      }
      // 与 removeBackground 同理：闭包只捕获所需变量，未命中降采样路径时
      // 不把 imageBytes 拷进 worker。
      final FaceInfo? result;
      if (rgba != null && plan != null) {
        final r = rgba;
        final p = plan;
        result = await Isolate.run(() {
          return runFaceFromRgb(rgbaToDecoded(r, p.width, p.height), session);
        });
      } else {
        result = await Isolate.run(() {
          return runFaceSync(imageBytes, session, maxEdge: kEngineMaxEdge);
        });
      }
      _faceCacheKey = imageBytes;
      _faceCacheValue = result;
      _faceCacheValid = true;
      return result;
    } on IdPhotoException {
      rethrow;
    } catch (e) {
      throw MattingException(cause: e.toString());
    }
  }

  /// 释放两个会话与工厂 isolate。组合类的 `dispose()` 应当调用它。
  Future<void> disposeMattingEngine() async {
    final matting = _mattingSession;
    final face = _faceSession;
    final factory = _factory;
    _mattingSession = null;
    _faceSession = null;
    _warmUp = null;
    _factory = null;
    _faceCacheKey = null;
    _faceCacheValue = null;
    _faceCacheValid = false;
    if (matting != null) releaseSession(matting);
    if (face != null) releaseSession(face);
    // 会话全部释放后再关工厂，worker 里的 ReleaseEnv 才是安全的。
    await factory?.dispose();
  }
}
