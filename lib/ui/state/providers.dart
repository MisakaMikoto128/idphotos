/// UI 状态层。
///
/// `lib/ui/` **只依赖** `IdPhotoController` 与 `AppState`（CONTRACTS §3），
/// 不 import 任何实现类。[controllerProvider] 必须在 `ProviderScope` 里被覆盖 ——
/// 阶段 2 由 `lib/ui/dev/fake_controller.dart` 覆盖，阶段 3 由主会话用真实
/// controller 覆盖。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';

/// 引擎入口。**必须在 ProviderScope 里 override**。
final Provider<IdPhotoController> controllerProvider =
    Provider<IdPhotoController>((Ref ref) {
  throw StateError(
    'controllerProvider 未被覆盖：请在 ProviderScope.overrides 里注入 '
    'IdPhotoController 实现（阶段 2 用 FakeController，阶段 3 用真实实现）。',
  );
});

/// 把 `IdPhotoController.state` 这条流接成 Riverpod 状态。
class AppStateNotifier extends Notifier<AppState> {
  @override
  AppState build() {
    final IdPhotoController c = ref.watch(controllerProvider);
    final sub = c.state.listen((AppState s) => state = s);
    ref.onDispose(sub.cancel);
    return c.currentState;
  }
}

final NotifierProvider<AppStateNotifier, AppState> appStateProvider =
    NotifierProvider<AppStateNotifier, AppState>(AppStateNotifier.new);

/// 界面运行配置。截图/测试场景把动画钉死，保证同一场景每次画同一帧。
class UiConfig {
  /// true = 所有循环动画停在 [frozenPhase]，且不启用自动消失的计时器。
  final bool freezeAnimations;

  /// 冻结时的动画相位（0..1）。
  final double frozenPhase;

  /// 是否触发震动反馈。截图场景关掉，避免多余的平台通道调用。
  final bool haptics;

  const UiConfig({
    this.freezeAnimations = false,
    this.frozenPhase = 0.38,
    this.haptics = true,
  });
}

final Provider<UiConfig> uiConfigProvider =
    Provider<UiConfig>((Ref ref) => const UiConfig());

/// 纯 UI 的瞬时状态（不属于引擎，不进 `AppState`）。
class WorkbenchState {
  /// 用户拖出来的裁剪框，**原图像素坐标**。null = 还没动过，用 `suggestedCrop`。
  final Rect? crop;

  /// [crop] 归属的"图片 + 规格"标识。换图或换规格后旧框自动作废。
  final String? cropToken;

  /// 当前按住的控制点。非 null 时裁剪框边框高亮（DESIGN.md §5）。
  final CropHandleId? activeHandle;

  /// 选中的候选底色 id。
  final String selectedStyleId;

  /// 保存成功反馈是否可见。
  final bool saveFeedback;

  /// 规格抽屉是否展开。
  final bool specSheetOpen;

  const WorkbenchState({
    this.crop,
    this.cropToken,
    this.activeHandle,
    this.selectedStyleId = 'white',
    this.saveFeedback = false,
    this.specSheetOpen = false,
  });

  WorkbenchState copyWith({
    Rect? crop,
    String? cropToken,
    CropHandleId? activeHandle,
    bool clearHandle = false,
    String? selectedStyleId,
    bool? saveFeedback,
    bool? specSheetOpen,
  }) {
    return WorkbenchState(
      crop: crop ?? this.crop,
      cropToken: cropToken ?? this.cropToken,
      activeHandle: clearHandle ? null : (activeHandle ?? this.activeHandle),
      selectedStyleId: selectedStyleId ?? this.selectedStyleId,
      saveFeedback: saveFeedback ?? this.saveFeedback,
      specSheetOpen: specSheetOpen ?? this.specSheetOpen,
    );
  }
}

/// [WorkbenchState.activeHandle] 用的轻量标识，避免 state 层 import widget 层。
typedef CropHandleId = String;

class WorkbenchNotifier extends Notifier<WorkbenchState> {
  /// 允许注入初始状态：截图场景要把"正在拖拽右下角""已保存"这类瞬时态钉死
  /// （CONTRACTS §7.1 明确禁止靠 `Future.delayed` 碰运气）。
  final WorkbenchState seed;

  WorkbenchNotifier({this.seed = const WorkbenchState()});

  @override
  WorkbenchState build() => seed;

  void updateCrop(Rect r, String token) =>
      state = state.copyWith(crop: r, cropToken: token);

  void beginDrag(CropHandleId handle) =>
      state = state.copyWith(activeHandle: handle);

  void endDrag() => state = state.copyWith(clearHandle: true);

  void select(String styleId) =>
      state = state.copyWith(selectedStyleId: styleId);

  void setSaveFeedback(bool v) => state = state.copyWith(saveFeedback: v);

  void setSpecSheet(bool v) => state = state.copyWith(specSheetOpen: v);
}

final NotifierProvider<WorkbenchNotifier, WorkbenchState> workbenchProvider =
    NotifierProvider<WorkbenchNotifier, WorkbenchState>(
        WorkbenchNotifier.new);

/// 当前"图片 + 规格"的标识，用来判断本地裁剪框是否还有效。
String cropTokenOf(AppState s) =>
    '${s.sourceImage?.length ?? 0}:${identityHashCode(s.sourceImage)}:${s.spec.id}';
