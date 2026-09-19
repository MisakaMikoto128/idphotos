/// 木照 MuZhao — 真实控制器（接线层）。
///
/// 阶段 3 由主会话实现 `docs/CONTRACTS.md` 第 3 节的 [IdPhotoController]：
/// 编排 [IdPhotoEngine] 的抠图 → 检脸 → 自动裁剪 → 合成流水线，
/// 并按 CONTRACTS 第 6 节把所有异常翻译成中文文案。
///
/// 并发与失效模型（`/code-review` 后定型，见 `out/REVIEW_G3.md`）：
/// - 所有状态写入走 [_emit] 单一路径，不存在绕过广播的直接 `_state =` 赋值。
/// - 每个异步编排体由 [_guarded] 包裹：代数守卫（[_checkGen]）+ 异常统一翻译。
///   被更新的请求（[_Superseded]）静默退出，不产出错误态。
/// - [loadImage] 入口即取消去抖计时器并**清空上一张图的缓存**——
///   加载失败后绝不允许用旧像素合成新图（审查 X1：会把 A 图的脸存成 B 图）。
/// - [_composeAll] 在入口对 crop/spec/face 做快照，合成途中用户拖拽不影响
///   本批候选的一致性（审查 L1）。
///
/// 势力范围：主会话（CLAUDE.md §4 接线层）。本文件只做**编排**：
/// 推理在 `lib/core/matting/`、几何与合成在 `lib/core/imaging/`、
/// 交互呈现由 `lib/ui/` 通过 [AppState] 观察 —— 这里不写任何一层的领域逻辑。
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'specs/photo_specs.dart';

/// 保存失败。CONTRACTS 第 6 节的异常表只覆盖引擎侧，落盘/相册写入的失败
/// 在这里补一个同风格的类型，文案与 UI 的 fallback 保持一致。
class SaveException extends IdPhotoException {
  const SaveException({super.cause}) : super('保存失败了，请再试一次');
}

/// 内部哨兵：当前编排体已被更新的请求作废。绝不逃出 [_guarded]。
class _Superseded implements Exception {
  const _Superseded();
}

/// [IdPhotoController] 的真实实现。
class MuZhaoController implements IdPhotoController {
  /// 创建即持有引擎。同一进程只应有一个实例（见 `lib/main.dart`）。
  MuZhaoController(this._engine, {PhotoSpec? initialSpec})
      : _state = AppState(spec: initialSpec ?? defaultPhotoSpec);

  final IdPhotoEngine _engine;
  final StreamController<AppState> _out =
      StreamController<AppState>.broadcast();

  AppState _state;
  int _gen = 0;

  MattingResult? _matting;
  FaceInfo? _face;
  Rect? _cropOverride;
  Timer? _debounce;

  /// 用户手动微调的面内角度。**不随规格/裁剪重置**，只在换图时归零。
  double _manualAngleDeg = 0.0;

  /// 拖拽停止多久后触发**全精度**重新合成。交互期间候选条由 UI 按
  /// [AppState.composedAngleDeg]/[AppState.composedCrop] 快照做实时变换，
  /// 不在这里出中间档。
  static const Duration kCropDebounce = Duration(milliseconds: 600);

  @override
  AppState get currentState => _state;

  @override
  Stream<AppState> get state => _out.stream;

  // ---------------------------------------------------------------------------
  // 状态与失效基建
  // ---------------------------------------------------------------------------

  /// **唯一**的状态写入路径。任何状态变更必须经此广播。
  void _emit(AppState s) {
    _state = s;
    if (!_out.isClosed) _out.add(s);
  }

  /// 代数守卫：不匹配（被更新的请求作废）或流已关时抛 [_Superseded]。
  void _checkGen(int gen) {
    if (gen != _gen || _out.isClosed) {
      throw const _Superseded();
    }
  }

  /// 统一的失败出口。只有当前代仍在位时才落错误态。
  void _fail(int gen, IdPhotoException e) {
    if (gen != _gen || _out.isClosed) return;
    _emit(_state.copyWith(stage: Stage.error, errorMessage: e.messageZh));
  }

  /// 统一包装所有异步编排体：代数守卫 + 异常→中文翻译（CONTRACTS §6）。
  Future<void> _guarded(int gen, Future<void> Function() body) async {
    try {
      await body();
    } on _Superseded {
      // 被更新的请求接管了状态，静默退出。
    } on IdPhotoException catch (e) {
      _fail(gen, e);
    } catch (e, st) {
      // 契约第 6 节：任何异常都不许穿透到 UI，统一按抠图失败呈现；
      // 原始错误挂进 cause 便于排查。
      _fail(gen, MattingException(cause: '$e\n$st'));
    }
  }

  // ---------------------------------------------------------------------------
  // 流水线编排
  // ---------------------------------------------------------------------------

  @override
  Future<void> loadImage(Uint8List bytes) async {
    // 新图入场三件事（审查 X1/X2）：
    // 1. 取消未触发的去抖计时器——否则它会在下方 await 期间触发
    //    _recompose 的 ++_gen，把本次加载整体作废，UI 卡在"B 图 + A 候选"；
    // 2. 立即清空上一张图的缓存——加载失败后绝不允许 setCrop 用
    //    旧像素 + 新坐标合成出"别人的脸"；
    // 3. 代数前进，让一切在途请求作废。
    _debounce?.cancel();
    _debounce = null;
    _matting = null;
    _face = null;
    _cropOverride = null;
    _manualAngleDeg = 0.0;
    final int gen = ++_gen;
    _emit(_state.copyWith(
      sourceImage: bytes,
      stage: Stage.matting,
      candidates: const <Candidate>[],
      manualAngleDeg: 0.0,
      clearSuggestedCrop: true,
      clearError: true,
    ));
    await _guarded(gen, () async {
      final MattingResult mat = await _engine.removeBackground(
        bytes,
        quality: _state.mattingQuality,
      );
      _checkGen(gen);
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
      _checkGen(gen);
      _face = face;

      // 坐标链（G4.7 降采样后）：face 是引擎工作分辨率坐标；
      // suggestedCrop 必须在**原图（摆正后）**空间——UI 的框画在原图上。
      final Rect suggested = _engine.suggestedCropInSourcePx(
        imageWidth: mat.srcWidth,
        imageHeight: mat.srcHeight,
        spec: _state.spec,
        face: _scaledFace(face, mat, toSource: true),
      );
      _emit(_state.copyWith(
        stage: Stage.composing,
        suggestedCrop: suggested,
        clearError: true,
      ));

      final List<Candidate> candidates = await _composeAll();
      _checkGen(gen);
      // 用显式构造而不是 copyWith：errorMessage 的语义是"从当前事实重算"
      //（无人脸 → 提示；有人脸 → 无），copyWith 的 null 保留语义做不到。
      _emit(AppState(
        sourceImage: _state.sourceImage,
        suggestedCrop: _state.suggestedCrop,
        candidates: candidates,
        spec: _state.spec,
        manualAngleDeg: _manualAngleDeg,
        mattingQuality: _state.mattingQuality,
        stage: Stage.ready,
        errorMessage:
            face == null ? const NoFaceException().messageZh : null,
      ));
    });
  }

  /// 坐标换算（G4.7）：FaceInfo 的 box/chinY/headTopY 是线性量，按
  /// `srcWidth/width` 等比缩放；rollDeg/confidence 是无量纲量，原样保留。
  /// [toSource] true = 工作分辨率 → 原图（放大），false = 反向（缩小）。
  FaceInfo? _scaledFace(FaceInfo? f, MattingResult m, {required bool toSource}) {
    if (f == null) return null;
    final double k = toSource
        ? m.srcWidth / m.width
        : m.width / m.srcWidth;
    if (k == 1.0) return f;
    return FaceInfo(
      box: _scaleRect(f.box, k),
      chinY: f.chinY * k,
      headTopY: f.headTopY * k,
      rollDeg: f.rollDeg,
      confidence: f.confidence,
    );
  }

  /// 矩形等比缩放（原点不动）。[k] == 1.0 时原样返回。
  static Rect _scaleRect(Rect r, double k) =>
      k == 1.0
          ? r
          : Rect.fromLTRB(
              r.left * k, r.top * k, r.right * k, r.bottom * k,
            );

  /// 坐标换算（G4.7）：cropOverride 由 UI 以**原图坐标**送入
  /// （[IdPhotoController.setCrop] 契约），compose 需要工作分辨率坐标。
  Rect? _cropInWorkingSpace(Rect? r, MattingResult m) {
    if (r == null) return null;
    return _scaleRect(r, m.width / m.srcWidth);
  }

  /// Windows 保存：另存为对话框。用户取消返回 null。
  static Future<File?> _pickSaveDestination(Candidate c) async {
    final FileSaveLocation? loc = await getSaveLocation(
      suggestedName:
          'muzhao_${DateTime.now().millisecondsSinceEpoch}_${c.style.id}.jpg',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'JPEG 图片', extensions: <String>['jpg']),
      ],
    );
    if (loc == null) return null;
    return File(loc.path);
  }

  /// 用当前缓存的抠图结果 + 规格，为 6 种内置底色各合成一张候选。
  /// 顺序即 CONTRACTS 第 5 节锁定的展示顺序。
  ///
  /// 入口对 matting/spec/face/crop 做**快照**：合成 6 张是顺序异步，
  /// 途中用户拖拽（改 [_cropOverride]）或换规格不得让同一批候选
  /// 混用两种几何（审查 L1）。
  Future<List<Candidate>> _composeAll() async {
    final MattingResult mat = _matting!;
    final PhotoSpec spec = _state.spec;
    // face 本就是工作分辨率坐标（detectFace 契约），compose 直接可用；
    // cropOverride 是原图坐标，换算到工作分辨率。
    final FaceInfo? face = _face;
    final Rect? cropOverride = _cropInWorkingSpace(_cropOverride, mat);
    final double manualAngleDeg = _manualAngleDeg;
    final List<Candidate> out = <Candidate>[];
    for (final BackgroundStyle style in kBuiltInBackgrounds) {
      out.add(await _engine.compose(
        matting: mat,
        spec: spec,
        style: style,
        face: face,
        cropOverride: cropOverride,
        manualRollDeg: manualAngleDeg,
      ));
    }
    return out;
  }

  /// 重新合成当前图（保留 [_matting] / [_face] 缓存，只重跑 compose）。
  Future<void> _recompose({required bool showProgress}) async {
    final int gen = ++_gen;
    if (showProgress) {
      _emit(_state.copyWith(stage: Stage.composing, clearError: true));
    }
    // 几何快照必须与 _composeAll 实际读到的值同源（都在本同步段内读取，
    // 途中不会被拖拽改写）——它随候选一起发给 UI 做实时预览变换的基准。
    final double composedAngle = _manualAngleDeg;
    final Rect? composedCrop = _cropOverride ?? _state.suggestedCrop;
    await _guarded(gen, () async {
      final List<Candidate> candidates = await _composeAll();
      _checkGen(gen);
      // 成功即重算 errorMessage（审查 X3）：此前失败的红色提示不能在
      // 恢复正常后残留；无人脸的提示则随事实保持。
      _emit(AppState(
        sourceImage: _state.sourceImage,
        suggestedCrop: _state.suggestedCrop,
        candidates: candidates,
        spec: _state.spec,
        manualAngleDeg: _manualAngleDeg,
        composedAngleDeg: composedAngle,
        composedCrop: composedCrop,
        mattingQuality: _state.mattingQuality,
        stage: Stage.ready,
        errorMessage:
            _face == null ? const NoFaceException().messageZh : null,
      ));
    });
  }

  @override
  void setCrop(Rect rectInSourcePx) {
    if (_matting == null) return; // 无图或在加载中：忽略
    _cropOverride = rectInSourcePx;
    // 拖拽是高频事件：交互中候选条靠 UI 实时变换跟手，
    // 停手 600ms 后这里全精度重合成替换。
    _debounce?.cancel();
    _debounce = Timer(kCropDebounce, () {
      _recompose(showProgress: false);
    });
  }

  @override
  void setManualAngle(double deg) {
    if (_matting == null) return; // 无图或在加载中：忽略
    if (!deg.isFinite) return;
    final double v =
        deg.clamp(kManualAngleMinDeg, kManualAngleMaxDeg).toDouble();
    if (v == _state.manualAngleDeg) return;
    // 角度**立刻**广播：UI 的表盘、裁剪框与候选条实时变换都跟手。
    // 全精度重合成则去抖 —— 一次拖动会经过几十个角度，
    // 逐个合成会把主 isolate 压死。
    _manualAngleDeg = v;
    _emit(_state.copyWith(manualAngleDeg: v));
    _debounce?.cancel();
    _debounce = Timer(kCropDebounce, () {
      _recompose(showProgress: false);
    });
  }

  @override
  void setSpec(PhotoSpec spec) {
    // 调校表替换（CONTRACTS §2 / photo_specs.dart 头注：接线层职责）。
    // 否则 UI 抽屉里的 api.dart 常量（未调校）会让同一规格 id 在
    // 首帧与切换后给出不同的头身比（审查 #2/L5）。
    final PhotoSpec tuned = tunedSpecFor(spec);
    if (tuned.id == _state.spec.id) return;
    // 宽高比变了，用户旧框按新比例解释没有意义：作废回自动推算。
    _cropOverride = null;
    _debounce?.cancel();
    if (_matting == null) {
      // 无图（含加载中）：只更新规格，等 loadImage 走完后按新规格出图。
      _emit(_state.copyWith(spec: tuned));
      return;
    }
    final Rect suggested = _engine.suggestedCropInSourcePx(
      imageWidth: _matting!.srcWidth,
      imageHeight: _matting!.srcHeight,
      spec: tuned,
      face: _scaledFace(_face, _matting!, toSource: true),
    );
    _emit(_state.copyWith(
      spec: tuned,
      suggestedCrop: suggested,
      stage: Stage.composing,
      clearError: true,
    ));
    _recompose(showProgress: false);
  }

  @override
  void setMattingQuality(MattingQuality quality) {
    if (quality == _state.mattingQuality) return;
    _debounce?.cancel();
    _debounce = null;
    final Uint8List? bytes = _state.sourceImage;
    if (bytes == null) {
      // 空态：只记档位，下次 loadImage 生效。
      _emit(_state.copyWith(mattingQuality: quality));
      return;
    }
    // 换档 = 换模型：旧 alpha 作废，必须重新抠图（alpha 来自哪个模型由
    // 调用时的档位决定，旧结果不能换档后继续用）。检脸与抠图模型无关，
    // [_face] 保留；用户的框选与手动角度也保留。
    // 正在进行的 loadImage / 重合成由 ++_gen 整体作废，避免旧档结果落地。
    _matting = null;
    final int gen = ++_gen;
    _emit(_state.copyWith(
      mattingQuality: quality,
      stage: Stage.matting,
      candidates: const <Candidate>[],
      clearError: true,
    ));
    unawaited(_guarded(gen, () async {
      final MattingResult mat =
          await _engine.removeBackground(bytes, quality: quality);
      _checkGen(gen);
      _matting = mat;

      // 换图途中换档（loadImage 被作废）：检脸可能还没跑过，这里补一次。
      // 引擎对同一 bytes 实例有单槽缓存，已检过则近零开销。
      FaceInfo? face = _face;
      if (face == null) {
        try {
          face = await _engine.detectFace(bytes);
        } on IdPhotoException {
          face = null;
        }
        _checkGen(gen);
        _face = face;
      }

      _emit(_state.copyWith(stage: Stage.composing, clearError: true));
      final List<Candidate> candidates = await _composeAll();
      _checkGen(gen);
      _emit(AppState(
        sourceImage: _state.sourceImage,
        suggestedCrop: _state.suggestedCrop,
        candidates: candidates,
        spec: _state.spec,
        manualAngleDeg: _manualAngleDeg,
        composedAngleDeg: _manualAngleDeg,
        composedCrop: _cropOverride ?? _state.suggestedCrop,
        mattingQuality: quality,
        stage: Stage.ready,
        errorMessage:
            face == null ? const NoFaceException().messageZh : null,
      ));
    }));
  }

  /// 保存序号：与时间戳共同保证文件名在本进程内唯一
  /// （审查对抗 q06：仅毫秒时间戳在同毫秒连点时撞名，并发 writeAsBytes
  /// 互相截断产出损坏文件，X4 的失败清理还会误删同名文件）。
  int _saveSeq = 0;

  /// 安全审查 M1：保存成功的私有 temp 文件会携带全分辨率人像照片滞留
  /// cache 目录（Android 12+ 的 D2D 换机迁移会连带复制 cache）。构造时
  /// 清理超过 24 小时的历史产出——相册里的正式副本不受影响，24 小时内
  /// 的文件保留供"保存后立即重读"类验证使用。
  static Future<void> _purgeStaleSavedFiles(Directory dir) async {
    try {
      final DateTime cutoff =
          DateTime.now().subtract(const Duration(hours: 24));
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File) continue;
        final String name = e.uri.pathSegments.last;
        if (!name.startsWith('muzhao_') || !name.endsWith('.jpg')) continue;
        final FileStat st = await e.stat();
        if (st.modified.isBefore(cutoff)) {
          try {
            await e.delete();
          } on FileSystemException catch (e) {
            developer.log('清理过期保存产物失败: $e', name: 'muzhao.controller');
          }
        }
      }
    } on FileSystemException catch (e) {
      developer.log('扫描保存产物目录失败: $e', name: 'muzhao.controller');
    }
  }

  @override
  Future<String> save(Candidate c) async {
    // 落盘字节永远来自**当前几何的全精度重合成**，不用候选列表里的字节：
    // 列表在 draft-then-final 交互中可能还是草稿分辨率（契约：草稿禁止落盘），
    // 也可能在用户停手到全精度刷新之间的窗口内是上一档几何。
    Uint8List bytes = c.jpegBytes;
    final MattingResult? mat = _matting;
    if (mat != null) {
      bytes = (await _engine.compose(
        matting: mat,
        spec: _state.spec,
        style: c.style,
        face: _face,
        cropOverride: _cropInWorkingSpace(_cropOverride, mat),
        manualRollDeg: _manualAngleDeg,
      ))
          .jpegBytes;
    }
    // 返回的路径必须真实存在且可重新解码（G3.3），所以先在私有目录落一份。
    // 相册写入走 MediaStore（gal），不返回路径，二者各司其职：
    // 私有文件给门禁/回读用，相册条目才是用户看到的"已保存到相册"。
    // 两者都由用户点击"保存"触发（CLAUDE.md §6 的例外条款）。
    // Windows：gal 不支持桌面端——走"另存为"对话框由用户选择落盘位置。
    // 隐私语义不变：文件只写到用户亲自选定的本地路径。
    if (!kIsWeb && Platform.isWindows) {
      final File? dest = await _pickSaveDestination(c);
      if (dest == null) return ''; // 用户取消——UI 按空路径静默处理
      await dest.writeAsBytes(bytes, flush: true);
      return dest.path;
    }
    final Directory dir = await getTemporaryDirectory();
    // M1：异步清理过期产物，不阻塞本次保存路径。
    unawaited(_purgeStaleSavedFiles(dir));
    final File file = File(
      '${dir.path}'
      '/muzhao_${DateTime.now().millisecondsSinceEpoch}'
      '_${_saveSeq++}_${c.style.id}.jpg',
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (e) {
      throw SaveException(cause: e);
    }
    try {
      await Gal.putImageBytes(bytes, album: '木照');
    } on GalException catch (e) {
      // 审查 X4：相册写入失败时清掉已落的私有文件——失败的保存不能把
      // 全分辨率用户照片永久留在 temp 目录。
      try {
        await file.delete();
      } on FileSystemException catch (cleanupError) {
        developer.log('清理失败保存的临时文件未成功: $cleanupError',
            name: 'muzhao.controller');
      }
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
