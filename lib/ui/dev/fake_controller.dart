/// 阶段 2 的假引擎。
///
/// 只实现 `IdPhotoController`（CONTRACTS §3），让界面在真实抠图/合成引擎就绪前
/// 就能跑起来、能被截图评审。**不 import 任何实现类**。
///
/// 确定性：全部状态转换默认**同步**完成，不用 `Future.delayed`。
/// 截图场景需要的"抠图中/冲洗中"这类瞬时态，由构造时直接钉在 [initial] 上，
/// 不靠时序碰运气（CONTRACTS §7.1）。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../../core/api.dart';
import '../util/image_size.dart';
import 'fake_thumbs.dart';
import 'sample_photo.dart';

class FakeController implements IdPhotoController {
  final StreamController<AppState> _out =
      StreamController<AppState>.broadcast();

  AppState _state;

  /// 每一步状态之间的停顿。截图/测试场景保持 [Duration.zero]；
  /// 手动把玩时可以给个 400ms 看动效。
  final Duration stepDelay;

  FakeController({AppState? initial, this.stepDelay = Duration.zero})
      : _state = initial ?? const AppState.initial();

  @override
  AppState get currentState => _state;

  @override
  Stream<AppState> get state => _out.stream;

  void _emit(AppState s) {
    _state = s;
    if (!_out.isClosed) _out.add(s);
  }

  Future<void> _pause() => stepDelay == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(stepDelay);

  @override
  Future<void> loadImage(Uint8List bytes) async {
    _emit(_state.copyWith(
      sourceImage: bytes,
      stage: Stage.matting,
      candidates: const <Candidate>[],
      // 换图归零（AppState.manualAngleDeg 的约定）：新照片的倾角与上一张无关，
      // 留着旧角度会让用户拿到一张莫名其妙歪着的成片。
      manualAngleDeg: 0.0,
      clearError: true,
    ));
    await _pause();
    _emit(_state.copyWith(stage: Stage.composing));
    await _pause();
    _emit(_state.copyWith(
      stage: Stage.ready,
      suggestedCrop: defaultSuggestedCrop(bytes, _state.spec),
      candidates: buildFakeCandidates(_state.spec),
    ));
  }

  @override
  void setCrop(Rect rectInSourcePx) {
    _emit(_state.copyWith(suggestedCrop: rectInSourcePx));
  }

  @override
  void setManualAngle(double deg) {
    if (_state.sourceImage == null) return; // 无图：忽略，与真 controller 一致
    if (!deg.isFinite) return;
    final double v =
        deg.clamp(kManualAngleMinDeg, kManualAngleMaxDeg).toDouble();
    if (v == _state.manualAngleDeg) return;
    // 真 controller 会去抖后重跑合成；假引擎没有可重算的东西，直接广播状态，
    // 让画布与读数在截图/自测里跟手。
    _emit(_state.copyWith(manualAngleDeg: v));
  }

  @override
  void setSpec(PhotoSpec spec) {
    if (_state.sourceImage == null) {
      _emit(_state.copyWith(spec: spec));
      return;
    }
    _emit(_state.copyWith(
      spec: spec,
      suggestedCrop: defaultSuggestedCrop(_state.sourceImage!, spec),
      candidates: buildFakeCandidates(spec),
      stage: Stage.ready,
    ));
  }

  @override
  Future<String> save(Candidate c) async {
    await _pause();
    return '/storage/emulated/0/Pictures/MuZhao/${c.style.id}.jpg';
  }

  void dispose() {
    _out.close();
  }
}

final Map<String, List<Candidate>> _candidateCache = <String, List<Candidate>>{};

/// 6 张候选，顺序与 [kBuiltInBackgrounds] 一致（CONTRACTS §5）。
///
/// 按规格缓存：截图流水线会为 6 个场景各建一次 FakeController，
/// 每次重新编码 6 张 JPEG 会把单测时间拖长好几倍。
List<Candidate> buildFakeCandidates(PhotoSpec spec) {
  return _candidateCache.putIfAbsent(spec.id, () => <Candidate>[
    for (final BackgroundStyle s in kBuiltInBackgrounds)
      Candidate(
        style: s,
        jpegBytes: renderFakeCandidate(spec: spec, style: s, longEdge: 480),
        thumbBytes: renderFakeCandidate(spec: spec, style: s),
      ),
  ]);
}

/// 假的"自动推算裁剪框"：锁定规格比例，纵向偏上。
Rect defaultSuggestedCrop(Uint8List bytes, PhotoSpec spec) {
  final PixelSize size =
      readImageSize(bytes) ?? const PixelSize(kSampleWidth, kSampleHeight);
  final double w0 = size.width.toDouble();
  final double h0 = size.height.toDouble();
  final double ar = spec.aspectRatio;
  double h = h0 * 0.94;
  double w = h * ar;
  if (w > w0 * 0.96) {
    w = w0 * 0.96;
    h = w / ar;
  }
  final double left = (w0 - w) / 2;
  final double top = (h0 - h) * 0.30;
  return Rect.fromLTWH(left, top, w, h);
}
