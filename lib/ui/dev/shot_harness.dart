/// 截图接缝（CONTRACTS §7.1）。
///
/// gatekeeper 的 `integration_test/shots_test.dart` 只认这个文件导出的
/// [kShotScenarios] 与 [buildShotScenario]，不读 `lib/ui/` 的内部结构。
///
/// **确定性保证**：
/// * 每个场景的 `AppState` 与 `WorkbenchState` 都是**直接构造好的状态**，
///   不经过 `loadImage()` 这类异步流程，也就不存在"截到中间帧"的可能；
/// * S3（按住右下角拖拽中）靠 `WorkbenchState.activeHandle = 'br'` 钉死，
///   不需要真的按住手指；
/// * S4（冲洗中）靠 `Stage.composing` + 空候选列表钉死，不需要卡住任何 Future；
/// * `UiConfig.freezeAnimations = true` 让"显影"这类循环动画停在固定相位 ——
///   否则 `pumpAndSettle()` 会因为永远有新帧被调度而超时；
/// * 照片输入固定为内嵌的原创卡通吉祥物"木木"生活照样张
///   （见 `sample_photo.dart`；阶段 6 前是黄金集 g01，因官方截图不得含
///   真人肖像而更换，黄金集本身仍是门禁资产、未动），不读运行时相册。
///
/// 势力范围：ui-woodcraft。场景 id 与稳定 Key 的改名必须先经主会话同意。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../app.dart';
import '../state/photo_source.dart';
import '../state/providers.dart';
import '../util/crop_geometry.dart';
import 'fake_controller.dart';
import 'sample_photo.dart';

/// 截图场景 id，与 capture-shots skill 的文件名一一对应，不得增删改名。
const List<String> kShotScenarios = <String>[
  'S1_empty', // 空态，未选照片
  'S2_loaded', // 已加载照片，裁剪框默认位置
  'S3_dragging', // 按住右下角控制点拖拽中
  'S4_generating', // 候选区生成中
  'S5_ready', // 6 个候选就绪，选中蓝底
  'S6_saved', // 保存成功反馈态
  'S7_about', // "关于"浮层展开（PHASE6 W1 新增，主会话追认见报告）
];

/// 截图/测试场景里不弹系统相册，直接给出内置样张。
class SampleSource implements PhotoSource {
  const SampleSource();

  @override
  Future<Uint8List?> pick() async => sampleSourceJpeg();
}

/// 构造处于指定场景状态的完整 App 根 widget（自带 MaterialApp / ProviderScope）。
Widget buildShotScenario(String scenarioId) {
  if (!kShotScenarios.contains(scenarioId)) {
    throw ArgumentError.value(
      scenarioId,
      'scenarioId',
      '未知截图场景，可用值见 kShotScenarios',
    );
  }
  return KeyedSubtree(
    // 场景切换必须整个换树：截图流水线在同一个 tester 里连续 pumpWidget 各场景，
    // 若 ProviderScope 元素被原地复用（widget 类型/位置相同），Riverpod 容器会
    // 沿用第一帧的 overrides —— 后面场景钉死的 WorkbenchState（S3 拖拽框、
    // S5 选中蓝底、S6 保存反馈）会被静默丢弃，全部回落到默认值。
    // 换 key 强制旧 scope 卸载、新容器按本场景的 overrides 重建。
    key: ValueKey<String>('MuZhaoScope-$scenarioId'),
    child: _scenarioTree(scenarioId),
  );
}

Widget _scenarioTree(String scenarioId) {
  final Uint8List photo = sampleSourceJpeg();
  const PhotoSpec spec = kDefaultSpec;
  final Rect suggested = defaultSuggestedCrop(photo, spec);
  final Rect bounds =
      Rect.fromLTWH(0, 0, kSampleWidth.toDouble(), kSampleHeight.toDouble());

  AppState loaded({
    Stage stage = Stage.ready,
    bool withCandidates = true,
  }) {
    return AppState(
      sourceImage: photo,
      suggestedCrop: suggested,
      candidates: withCandidates
          ? buildFakeCandidates(spec)
          : const <Candidate>[],
      spec: spec,
      stage: stage,
    );
  }

  // S3：右下角被按住并往内收了一截。用真实的 resize 运算得到，
  // 因此画面里的框宽高比与 spec 严格一致（G2C.6 用同一套数学）。
  final Rect dragged = CropMath.resize(
    current: suggested,
    handle: CropHandle.bottomRight,
    pointer: Offset(
      suggested.left + suggested.width * 0.80,
      suggested.top + suggested.height * 0.80,
    ),
    aspect: spec.aspectRatio,
    bounds: bounds,
    minWidth: 80,
  );

  final AppState app = switch (scenarioId) {
    'S1_empty' => const AppState.initial(),
    'S4_generating' => loaded(stage: Stage.composing, withCandidates: false),
    _ => loaded(),
  };

  final WorkbenchState wb = switch (scenarioId) {
    'S3_dragging' => WorkbenchState(
        crop: dragged,
        cropToken: cropTokenOf(app),
        activeHandle: CropHandle.bottomRight.keySuffix,
      ),
    'S5_ready' => const WorkbenchState(selectedStyleId: 'blue'),
    'S6_saved' =>
      const WorkbenchState(selectedStyleId: 'blue', saveFeedback: true),
    'S7_about' => const WorkbenchState(aboutOpen: true),
    _ => const WorkbenchState(),
  };

  return buildMuZhaoScope(
    controller: FakeController(initial: app),
    workbench: wb,
    // syncRaster：照片与候选缩略图首帧即出图。Image.memory 的引擎解码是
    // 异步的，pumpAndSettle 等不到"还没开始解码"的回调，官方 S2 截图曾
    // 间歇性整张丢照片（out/VISUAL_2C.md 致命项 [F-场景]）。
    config: const UiConfig(
      freezeAnimations: true,
      haptics: false,
      syncRaster: true,
    ),
    photoSource: const SampleSource(),
  );
}

/// 组装一棵完整的 App 树。开发入口与截图场景共用。
Widget buildMuZhaoScope({
  required IdPhotoController controller,
  WorkbenchState workbench = const WorkbenchState(),
  UiConfig config = const UiConfig(),
  PhotoSource photoSource = const SampleSource(),
}) {
  return ProviderScope(
    overrides: [
      controllerProvider.overrideWithValue(controller),
      uiConfigProvider.overrideWithValue(config),
      photoSourceProvider.overrideWithValue(photoSource),
      workbenchProvider.overrideWith(
        () => WorkbenchNotifier(seed: workbench),
      ),
    ],
    child: const MuZhaoUiApp(),
  );
}
