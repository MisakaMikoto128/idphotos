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
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../api.dart';
import 'matting_worker.dart';
import 'ort_runtime.dart';

/// MODNet + YuNet 的端侧实现。全程本地，不触网。
mixin MattingEngineMixin {
  int? _mattingSession;
  int? _faceSession;
  Future<void>? _warmUp;

  /// 已生效的执行提供者，形如 `xnnpack` / `nnapi` / `cpu`。仅供排查。
  String? get mattingProvider => _mattingProvider;
  String? _mattingProvider;

  /// 加载两个模型。重复调用幂等：并发调用共享同一个 Future。
  Future<void> warmUp() {
    return _warmUp ??= _loadModels().catchError((Object e, StackTrace s) {
      // 失败后允许重试，否则一次瞬时故障会把引擎永久钉死。
      _warmUp = null;
      throw MattingException(cause: e.toString());
    });
  }

  Future<void> _loadModels() async {
    if (_mattingSession != null && _faceSession != null) return;
    final mattingPath = await resolveModelPath(kMattingModelAsset);
    final facePath = await resolveModelPath(kFaceModelAsset);
    // 建会话要读 7MB 模型并做图优化，放后台 isolate，别卡住首帧。
    final handles = await Isolate.run(() {
      final matting = createSession(mattingPath);
      final face = createSession(facePath, threads: 2);
      return <Object>[
        matting.address,
        matting.provider,
        face.address,
        face.provider,
      ];
    });
    _mattingSession = handles[0] as int;
    _mattingProvider = handles[1] as String;
    _faceSession = handles[2] as int;
  }

  Future<int> _requireSession(bool matting) async {
    await warmUp();
    final s = matting ? _mattingSession : _faceSession;
    if (s == null) {
      throw const MattingException();
    }
    return s;
  }

  /// 抠图。返回的 rgba / alpha 均为**原图分辨率**。
  ///
  /// - 解不开的文件 → [UnsupportedImageException]
  /// - 长边 > [kMaxImageEdgePx] → [ImageTooLargeException]
  /// - 其它失败（含"图里根本没有人"）→ [MattingException]
  Future<MattingResult> removeBackground(Uint8List imageBytes) async {
    final session = await _requireSession(true);
    try {
      final payload =
          await Isolate.run(() => runMattingSync(imageBytes, session));
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
  /// 图片本身打不开仍会抛 [UnsupportedImageException] / [ImageTooLargeException]
  /// ——那是"图有问题"，不是"没有人脸"。推理层面的意外失败翻译成
  /// [MattingException]；这里刻意不吞异常，否则模型坏掉会伪装成"这张图没人脸"。
  Future<FaceInfo?> detectFace(Uint8List imageBytes) async {
    final session = await _requireSession(false);
    try {
      return await Isolate.run(() => runFaceSync(imageBytes, session));
    } on IdPhotoException {
      rethrow;
    } catch (e) {
      throw MattingException(cause: e.toString());
    }
  }

  /// 释放两个会话。组合类的 `dispose()` 应当调用它。
  void disposeMattingEngine() {
    final matting = _mattingSession;
    final face = _faceSession;
    _mattingSession = null;
    _faceSession = null;
    _warmUp = null;
    if (matting != null) releaseSession(matting);
    if (face != null) releaseSession(face);
  }
}
