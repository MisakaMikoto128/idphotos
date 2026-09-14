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

  /// 照片/候选缩略图用**同步**光栅渲染（`SyncRaster`）。
  ///
  /// `Image.memory` 的引擎解码是异步的，`pumpAndSettle` 等不到"尚未开始解码"
  /// 的帧回调，官方截图曾因此间歇性丢掉整张照片（out/VISUAL_2C.md 致命项）。
  /// 截图/测试场景必须置 true，保证首帧就含有照片像素；
  /// 真机运行保持 false——大图同步解码会卡 UI 线程。
  final bool syncRaster;

  const UiConfig({
    this.freezeAnimations = false,
    this.frozenPhase = 0.38,
    this.haptics = true,
    this.syncRaster = false,
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

  /// 取图/载入阶段的错误（区域 A 的提示行显示）。
  ///
  /// CONTRACTS §6 要求引擎异常在 controller 层转成 `AppState.errorMessage`，
  /// 但**取图不经过 controller** —— `ImagePicker` 在用户拒绝
  /// `READ_MEDIA_IMAGES`、picker activity 被系统回收时抛 `PlatformException`，
  /// 这条路径上没有 controller 可以兜底。所以 UI 层自备这一个错误位，
  /// 保证"任何失败都有中文提示"，而不是静默退回空态。
  final String? pickError;

  /// 保存失败的中文提示（区域 C 的纸条显示）。null = 没失败过。
  final String? saveError;

  const WorkbenchState({
    this.crop,
    this.cropToken,
    this.activeHandle,
    this.selectedStyleId = 'white',
    this.saveFeedback = false,
    this.specSheetOpen = false,
    this.pickError,
    this.saveError,
  });

  WorkbenchState copyWith({
    Rect? crop,
    String? cropToken,
    CropHandleId? activeHandle,
    bool clearHandle = false,
    String? selectedStyleId,
    bool? saveFeedback,
    bool? specSheetOpen,
    String? pickError,
    bool clearPickError = false,
    String? saveError,
    bool clearSaveError = false,
  }) {
    return WorkbenchState(
      crop: crop ?? this.crop,
      cropToken: cropToken ?? this.cropToken,
      activeHandle: clearHandle ? null : (activeHandle ?? this.activeHandle),
      selectedStyleId: selectedStyleId ?? this.selectedStyleId,
      saveFeedback: saveFeedback ?? this.saveFeedback,
      specSheetOpen: specSheetOpen ?? this.specSheetOpen,
      pickError: clearPickError ? null : (pickError ?? this.pickError),
      saveError: clearSaveError ? null : (saveError ?? this.saveError),
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

  void setSaveFeedback(bool v) => state = state.copyWith(
        saveFeedback: v,
        clearSaveError: v,
      );

  /// [msg] 为 null 表示清除上一条取图错误。
  void setPickError(String? msg) => state = msg == null
      ? state.copyWith(clearPickError: true)
      : state.copyWith(pickError: msg);

  /// [msg] 为 null 表示清除上一条保存错误。
  void setSaveError(String? msg) => state = msg == null
      ? state.copyWith(clearSaveError: true)
      : state.copyWith(saveError: msg, saveFeedback: false);

  void setSpecSheet(bool v) => state = state.copyWith(specSheetOpen: v);
}

final NotifierProvider<WorkbenchNotifier, WorkbenchState> workbenchProvider =
    NotifierProvider<WorkbenchNotifier, WorkbenchState>(
        WorkbenchNotifier.new);

/// 当前"图片 + 规格"的标识，用来判断本地裁剪框是否还有效。
String cropTokenOf(AppState s) =>
    '${s.sourceImage?.length ?? 0}:${identityHashCode(s.sourceImage)}:${s.spec.id}';
