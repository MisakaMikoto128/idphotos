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
import 'iris_roll.dart';
import 'matting_worker.dart';
import 'ort_runtime.dart';
import 'session_factory.dart';

/// MODNet（fast 档）+ BiRefNet（fine 档）+ YuNet 的端侧实现。全程本地，不触网。
///
/// 双模型口径（db778aa 契约）：fast = MODNet-1024，warmUp 时与人脸模型一起
/// 加载；fine = BiRefNet-lite-1024（67MB），首次 fine 档调用时懒加载、之后
/// 常驻，加载失败允许重试（不一次故障钉死，成法同 [warmUp]）。
mixin MattingEngineMixin {
  int? _fastSession;
  int? _fineSession;
  int? _faceSession;
  Future<void>? _warmUp;
  Future<int>? _fineLoading;
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

  /// fine 档会话的执行提供者（未加载过为 null）。仅供排查。
  String? get fineMattingProvider => _fineProvider;
  String? _fineProvider;

  /// 工厂 isolate 里 OrtEnv 的 native 地址，供 bench 验证
  /// "每进程一个 env"（warmUp 失败重试前后必须同值）。生产代码勿用。
  int? get debugEnvAddress => _factory?.envAddress;

  /// 加载 fast 档抠图模型与人脸模型（契约：fine 档大模型不在此加载，首次
  /// fine 档调用时懒加载，见 [_loadFineSession]）。重复调用幂等：并发
  /// 调用共享同一个 Future。
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
    if (_fastSession != null && _faceSession != null) return;
    // Windows：flutter test / 宿主机 bench 形态下 onnxruntime.dll 不在
    // 可执行文件旁，先按绝对路径预载（App 形态下是空操作）。必须在任何
    // ORT 绑定被触碰之前执行，否则 DynamicLibrary.open('onnxruntime.dll')
    // 直接失败。
    ensureOrtRuntimeLoaded();
    final mattingPath = await resolveModelPath(kMattingModelAsset);
    final facePath = await resolveModelPath(kFaceModelAsset);
    // 建会话要读 7.5MB 模型并做图优化，放后台 isolate，别卡住首帧。
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
    _fastSession = matting.address;
    _mattingProvider = matting.provider;
    _faceSession = face.address;
  }

  /// fine 档会话：首次调用时懒加载（67MB 模型，读盘 + 图优化要数秒），之后
  /// 常驻。并发调用共享同一个 Future；失败后重置 [_fineLoading] 允许重试
  /// （成法同 [warmUp]，一次瞬时故障不把 fine 档永久钉死）。
  ///
  /// 前提：[_factory] 已由 [warmUp] 建好（fine 档调用必经 [_requireSession]，
  /// 它内部先 await warmUp()）。
  Future<int> _loadFineSession() async {
    final existing = _fineSession;
    if (existing != null) return existing;
    final factory = _factory;
    if (factory == null) {
      throw StateError('fine session before warmUp factory');
    }
    final finePath = await resolveModelPath(kFineMattingModelAsset);
    final fine = await factory.createSessionInFactory(finePath);
    if (!fine.ok) {
      throw StateError('fine session: ${fine.error}');
    }
    _fineSession = fine.address;
    _fineProvider = fine.provider;
    return fine.address;
  }

  Future<int> _requireSession(bool matting,
      {MattingQuality quality = MattingQuality.fast}) async {
    await warmUp();
    if (matting && quality == MattingQuality.fine) {
      return _fineLoading ??= _loadFineSession()
          .catchError((Object e, StackTrace s) {
        _fineLoading = null;
        throw MattingException(cause: e.toString());
      });
    }
    final s = matting ? _fastSession : _faceSession;
    if (s == null) {
      throw const MattingException();
    }
    return s;
  }

  /// 抠图。[quality] 选择模型：fast = MODNet（默认，快），fine = BiRefNet
  /// （慢，发丝级；首次调用懒加载 67MB 模型）。
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
  Future<MattingResult> removeBackground(Uint8List imageBytes,
      {MattingQuality quality = MattingQuality.fast}) async {
    final session = await _requireSession(true, quality: quality);
    final model = quality == MattingQuality.fine
        ? MattingModelKind.birefnet
        : MattingModelKind.modnet;
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
      // 是异步原生解码，不卡 UI 线程；后台 isolate 的 dart:ui 解码实测
      // 不可用（ml_probe2_main P2，恒返回 null）。orientation 5–8 也走
      // dart:ui：设备端已验证它烘焙 EXIF（ml_probe2_main P1，orientation=6
      // 样张摆正后顶边带出现在右侧），而 image_header 的宽高本来就按摆正后
      // 口径给出，目标尺寸直接传即可。plan 为 null 或解码失败时，兜底路径
      // 在 worker isolate 里全尺寸解码后立即降采样。
      final plan = planWorkingSize(imageBytes);
      Uint8List? rgba;
      if (plan != null && plan.downsampled) {
        final decoded =
            await decodeDownsampledUi(imageBytes, plan.width, plan.height);
        if (decoded != null) {
          rgba = decoded.rgba;
        }
      }
      // 两条路径拆成两个闭包：闭包只捕获自己真正引用的变量。合并写法会把
      // imageBytes 一并拷进降采样路径的 worker isolate（一次全文件大小的
      // 无谓拷贝，G4.7 瞬时滞留的直接来源之一）。
      //
      // G4 r3：降采样路径改为**宿主就地从 rgba 备好模型输入**，worker 只收
      // 固定两张 Float32 输入（YuNet letterbox 4.9MB + 抠图 1024² 12.6MB，
      // 合计 17.5MB），不再拷 rgba（w*h*4）、不再在 worker 里转 rgb
      // （w*h*3）——模型输入与旧路径逐位一致
      // （见 modnetInputFromRgba / yunetInputFromRgba），输出不变，
      // isolate 拷贝与 worker 峰值各少 ~12.6/9.4MB（2048 口径）。
      // 输入构建（面积重采样 ~20-40ms）留在宿主是为了不拷大缓冲；代价是
      // NoFace 图也付一次抠图输入构建（门槛没过时白备 12.6MB），与
      // "门槛在抠图推理之前省整次推理"的大头相比可忽略。
      final MattingPayload payload;
      if (rgba != null && plan != null) {
        final r = rgba;
        final p = plan;
        final LetterboxInput? yunet =
            runGate ? yunetInputFromRgba(r, p.width, p.height, kFaceInputSize)
                : null;
        // 瞳孔估计要的灰度平面也在宿主从同一份 rgba 备好：worker 里没有
        // rgba，而 1 字节/像素的灰度是这条路径上最小的一份拷贝。
        final Uint8List? gray =
            runGate ? grayPlaneFromRgba(r, p.width, p.height) : null;
        final Float32List matting = model == MattingModelKind.birefnet
            ? birefnetInputFromRgba(r, p.width, p.height, kMattingInputSize)
            : modnetInputFromRgba(r, p.width, p.height, kMattingInputSize);
        payload = await Isolate.run(() {
          // alpha-only 路径：worker 只回 alpha（+人像门槛的检脸结果），
          // rgba 缓冲留在宿主，就地强制 A=255 后直接作为结果——不跨
          // isolate 搬运、不重建 w*h*4 大缓冲（G4.7 瞬时滞留压缩）。
          return runMattingPrecomputed(
            mattingInput: matting,
            yunetInput: yunet,
            gray: gray,
            sessionAddress: session,
            faceSessionAddress: runGate ? faceSession : null,
            width: p.width,
            height: p.height,
            sourceWidth: p.sourceWidth,
            sourceHeight: p.sourceHeight,
            model: model,
          );
        });
      } else {
        payload = await Isolate.run(() {
          return runMattingSync(imageBytes, session,
              maxEdge: kEngineMaxEdge,
              targetEdge: kBigImageWorkEdge,
              faceSessionAddress: runGate ? faceSession : null,
              model: model);
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
      if (plan != null && plan.downsampled) {
        final decoded =
            await decodeDownsampledUi(imageBytes, plan.width, plan.height);
        if (decoded != null) {
          rgba = decoded.rgba;
        }
      }
      // 与 removeBackground 同理：闭包只捕获所需变量，未命中降采样路径时
      // 不把 imageBytes 拷进 worker。降采样路径同样在宿主预计算 letterbox
      // 输入（G4 r3），worker 只收 4.9MB 的 Float32。
      final FaceInfo? result;
      if (rgba != null && plan != null) {
        final r = rgba;
        final p = plan;
        final LetterboxInput yunet =
            yunetInputFromRgba(r, p.width, p.height, kFaceInputSize);
        final Uint8List gray = grayPlaneFromRgba(r, p.width, p.height);
        result = await Isolate.run(() {
          return faceFromYunetInput(yunet, session, p.width, p.height,
              gray: gray);
        });
      } else {
        result = await Isolate.run(() {
          return runFaceSync(imageBytes, session,
              maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
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

  /// 释放全部会话（fast / fine / face）与工厂 isolate。组合类的
  /// `dispose()` 应当调用它。fine 档会话可能从未加载，按 null 跳过。
  Future<void> disposeMattingEngine() async {
    final fast = _fastSession;
    final fine = _fineSession;
    final face = _faceSession;
    final factory = _factory;
    _fastSession = null;
    _fineSession = null;
    _faceSession = null;
    _warmUp = null;
    _fineLoading = null;
    _factory = null;
    _faceCacheKey = null;
    _faceCacheValue = null;
    _faceCacheValid = false;
    if (fast != null) releaseSession(fast);
    if (fine != null) releaseSession(fine);
    if (face != null) releaseSession(face);
    // 会话全部释放后再关工厂，worker 里的 ReleaseEnv 才是安全的。
    await factory?.dispose();
  }
}
