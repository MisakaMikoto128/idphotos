/// 木照 MuZhao — 真实控制器（接线层）。
///
/// 阶段 3 由主会话实现 `docs/CONTRACTS.md` 第 3 节的 [IdPhotoController]：
/// 编排 [IdPhotoEngine] 的抠图 → 检脸 → 自动裁剪 → 合成流水线，
/// 并按 CONTRACTS 第 6 节把所有异常翻译成中文文案。
///
/// 势力范围：主会话（CLAUDE.md §4 接线层）。本文件只做**编排**：
/// 推理在 `lib/core/matting/`、几何与合成在 `lib/core/imaging/`、
/// 交互呈现由 `lib/ui/` 通过 [AppState] 观察 —— 这里不写任何一层的领域逻辑。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'engine_impl.dart';
import 'specs/photo_specs.dart';

/// 保存失败。CONTRACTS 第 6 节的异常表只覆盖引擎侧，落盘/相册写入的失败
/// 在这里补一个同风格的类型，文案与 UI 的 fallback 保持一致。
class SaveException extends IdPhotoException {
  const SaveException({super.cause}) : super('保存失败了，请再试一次');
}

/// [IdPhotoController] 的真实实现。
///
/// - 抠图/检脸结果按"当前图片"缓存，`setCrop` / `setSpec` 只触发重新合成，
///   不重跑模型。
/// - `setCrop` 在拖拽过程中会被高频调用（UI 每个拖拽帧都转发），
///   因此**去抖 300ms** 后才重新合成；预览由 UI 本地实时绘制，
///   候选图在用户停手后跟上。
/// - 每个异步阶段带代数（[_gen]）：新请求会让旧请求的结果作废，
///   避免乱序返回把旧候选覆盖到新图上。
class MuZhaoController implements IdPhotoController {
  /// 创建即持有引擎。同一进程只应有一个实例（见 `lib/main.dart`）。
  MuZhaoController(this._engine, {PhotoSpec? initialSpec})
      : _state = AppState(spec: initialSpec ?? defaultPhotoSpec);

  /// 引擎字段用具体实现类型：`suggestedCropInSourcePx` 是 ComposeEngineMixin
  /// 提供的公开方法、不在 `IdPhotoEngine` 抽象面上 —— 自动推算属于几何层能力，
  /// 控制器作为接线层直接依赖接线层的 engine_impl 是合理的。
  final IdPhotoEngineImpl _engine;
  final StreamController<AppState> _out =
      StreamController<AppState>.broadcast();

  AppState _state;
  int _gen = 0;

  MattingResult? _matting;
  FaceInfo? _face;
  Rect? _cropOverride;
  Timer? _debounce;

  /// 拖拽停止多久后触发重新合成。
  static const Duration kCropDebounce = Duration(milliseconds: 300);

  @override
  AppState get currentState => _state;

  @override
  Stream<AppState> get state => _out.stream;

  void _emit(AppState s) {
    _state = s;
    if (!_out.isClosed) _out.add(s);
  }

  @override
  Future<void> loadImage(Uint8List bytes) async {
    _cropOverride = null;
    final int gen = ++_gen;
    _emit(_state.copyWith(
      sourceImage: bytes,
      stage: Stage.matting,
      candidates: const <Candidate>[],
      clearSuggestedCrop: true,
      clearError: true,
    ));
    try {
      final MattingResult mat = await _engine.removeBackground(bytes);
      if (gen != _gen) return;
      _matting = mat;

      // 检脸失败（引擎内部错误）按"无人脸"降级处理，不阻断流程：
      // 契约里 NoFaceException 本来就是"仅提示，可手动框选"，
      // 检脸环节出故障不该连抠图成果一起丢掉。
      FaceInfo? face;
      try {
        face = await _engine.detectFace(bytes);
      } on IdPhotoException {
        face = null;
      }
      if (gen != _gen) return;
      _face = face;

      final Rect suggested = _engine.suggestedCropInSourcePx(
        imageWidth: mat.width,
        imageHeight: mat.height,
        spec: _state.spec,
        face: face,
      );
      _emit(_state.copyWith(
        stage: Stage.composing,
        suggestedCrop: suggested,
        clearError: true,
      ));

      final List<Candidate> candidates = await _composeAll();
      if (gen != _gen) return;
      _emit(_state.copyWith(
        candidates: candidates,
        stage: Stage.ready,
        // 无人脸是提示不是错误：候选照常产出，用户可手动框选。
        errorMessage:
            face == null ? const NoFaceException().messageZh : null,
      ));
    } on UnsupportedImageException catch (e) {
      _fail(gen, e);
    } on ImageTooLargeException catch (e) {
      _fail(gen, e);
    } on IdPhotoException catch (e) {
      _fail(gen, e);
    } catch (e, st) {
      // 契约第 6 节：任何异常都不许穿透到 UI，统一翻成中文。
      // 未预期异常按抠图失败呈现；原始错误挂在 cause 里便于排查。
      _fail(gen, MattingException(cause: '$e\n$st'));
    }
  }

  void _fail(int gen, IdPhotoException e) {
    if (gen != _gen || _out.isClosed) return;
    _emit(_state.copyWith(stage: Stage.error, errorMessage: e.messageZh));
  }

  /// 用当前缓存的抠图结果 + 规格，为 6 种内置底色各合成一张候选。
  /// 顺序即 CONTRACTS 第 5 节锁定的展示顺序。
  Future<List<Candidate>> _composeAll() async {
    final MattingResult mat = _matting!;
    final List<Candidate> out = <Candidate>[];
    for (final BackgroundStyle style in kBuiltInBackgrounds) {
      out.add(await _engine.compose(
        matting: mat,
        spec: _state.spec,
        style: style,
        face: _face,
        cropOverride: _cropOverride,
      ));
    }
    return out;
  }

  /// 重新合成当前图。保留 [_matting] / [_face] 缓存，只重跑 compose。
  Future<void> _recompose({required bool showProgress}) async {
    final int gen = ++_gen;
    if (showProgress) {
      _emit(_state.copyWith(stage: Stage.composing, clearError: true));
    }
    try {
      final List<Candidate> candidates = await _composeAll();
      if (gen != _gen || _out.isClosed) return;
      _emit(_state.copyWith(candidates: candidates, stage: Stage.ready));
    } on IdPhotoException catch (e) {
      if (gen != _gen || _out.isClosed) return;
      _emit(_state.copyWith(stage: Stage.error, errorMessage: e.messageZh));
    } catch (e, st) {
      if (gen != _gen || _out.isClosed) return;
      _emit(_state.copyWith(
        stage: Stage.error,
        errorMessage: MattingException(cause: '$e\n$st').messageZh,
      ));
    }
  }

  @override
  void setCrop(Rect rectInSourcePx) {
    if (_matting == null) return; // 还没有图，忽略
    _cropOverride = rectInSourcePx;
    // 拖拽是高频事件：去抖后合成，用户停手 300ms 出候选。
    _debounce?.cancel();
    _debounce = Timer(kCropDebounce, () {
      _recompose(showProgress: false);
    });
  }

  @override
  void setSpec(PhotoSpec spec) {
    if (spec.id == _state.spec.id) return;
    // 规格变了宽高比就变了，用户旧框按新比例解释没有意义，作废回自动推算。
    _cropOverride = null;
    _state = _state.copyWith(spec: spec);
    if (_matting == null) {
      _emit(_state);
      return;
    }
    final Rect suggested = _engine.suggestedCropInSourcePx(
      imageWidth: _matting!.width,
      imageHeight: _matting!.height,
      spec: spec,
      face: _face,
    );
    _emit(_state.copyWith(
      suggestedCrop: suggested,
      stage: Stage.composing,
      clearError: true,
    ));
    _recompose(showProgress: false);
  }

  @override
  Future<String> save(Candidate c) async {
    // 返回的路径必须真实存在且可重新解码（G3.3），所以先在私有目录落一份。
    // 相册写入走 MediaStore（gal），不返回路径，二者各司其职：
    // 私有文件给门禁/回读用，相册条目才是用户看到的"已保存到相册"。
    // 两者都由用户点击"保存"触发（CLAUDE.md §6 的例外条款）。
    final Directory dir = await getTemporaryDirectory();
    final File file = File(
      '${dir.path}'
      '/muzhao_${DateTime.now().millisecondsSinceEpoch}_${c.style.id}.jpg',
    );
    try {
      await file.writeAsBytes(c.jpegBytes, flush: true);
    } on FileSystemException catch (e) {
      throw SaveException(cause: e);
    }
    try {
      await Gal.putImageBytes(c.jpegBytes, album: '木照');
    } on GalException catch (e) {
      throw SaveException(cause: e);
    }
    return file.path;
  }

  /// 释放资源。引擎归 [IdPhotoEngine] 所有，不由控制器代管；
  /// 进程生命周期内引擎常驻，这里只停掉去抖计时器和状态流。
  void dispose() {
    _debounce?.cancel();
    _gen++; // 让在途的异步全部作废
    _out.close();
  }
}
