// integration_test/shots_test.dart
//
// 截图流水线（G1.6 生命线，阶段 2 起扩成 capture-shots skill 规定的 8 张）。
// 势力范围：gatekeeper。ui-woodcraft/qa-batch/visual-critic/store-assets 只消费
// out/shots/ 下的产出，不应修改本文件。
//
// 阶段 2 起靠 docs/CONTRACTS.md 第 7 节的接缝对接 ui-woodcraft：
//   import 'package:muzhao/ui/dev/shot_harness.dart' show kShotScenarios, buildShotScenario;
// 本文件只认这个接缝和第 7.2 节列出的稳定 Key，不读 ui-woodcraft 内部 widget 结构。
// 此刻（阶段 2 刚开始）ui-woodcraft 还没交付 shot_harness.dart，本文件编译不过——
// 预期状态，见 gatekeeper 报告。
//
// 两台 AVD 跑两遍：
//   - 主截图 S1-S6：在 Pixel_3a_API_34...（1080x2220）上跑，SHOT_MODE=main。
//   - 小屏 S2_small/S5_small：在 MuZhao_Small（720x1280）上跑，SHOT_MODE=small，
//     场景内容用 S2_loaded/S5_ready，只是落盘文件名加 _small 后缀。
// 由 tools/gate/capture_shots.dart 负责两次调用、传对应 --dart-define。
//
// 稳定 Key 矩形边框：为了让 gate_G2C.dart 能在"排除照片区域"的前提下做调色板/
// 纯黑纯白检测（2C.2/2C.4），本文件把关键 Key（area_a/b/c、crop_box、
// candidate_<styleId>）的屏幕矩形（物理像素，已乘 devicePixelRatio）写进
// `binding.reportData`，flutter drive 跑完后会落盘到
// build/integration_response_data.json，gate_G2C.dart 从那里读。
//
// `/code-review high`（out/REVIEW_G2.md #7）指出：区域 A 里"裁剪框外、照片内"
// 的部分只是被压暗（60% alpha scrim），像素仍然是照片内容，不是 chrome，
// 但旧版 `_loadExcludeRects` 只排除 crop_box——2C.2/2C.4 换成饱和度高的真实照片后
// 会被拖累。正确排除范围应该是**照片的 display 矩形**（BoxFit.contain 的整张图），
// 比 crop_box 大。CONTRACTS.md §7.2 规定"gatekeeper 只准用列出的稳定 Key"，
// 而照片 display 矩形目前没有对应的 Key（挂在 `Image.memory` 外层的
// `Positioned.fromRect` 上，是 ui-woodcraft 的内部实现，不在契约范围内）。
// 已向主会话申请在 CONTRACTS §7.2 追加 `Key('photo_display')`（gatekeeper 报告，
// 未定案，未擅自去改 lib/ui/）。这里先把 'photo_display' 加进待记录列表——
// 在这个 Key 真正落地前，`_rectOf` 找不到它会静默跳过（不算错误，见下方列表注释），
// 行为等价于目前状态；Key 落地后本文件不需要再改，自动开始记录。

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/ui/dev/shot_harness.dart' show kShotScenarios, buildShotScenario;

const String kShotMode = String.fromEnvironment('SHOT_MODE', defaultValue: 'main');

const String kPhotoDisplayKey = 'photo_display';

/// 主截图场景就是 shot_harness 里定义的全部场景（S1-S6）。
/// 小屏模式只重跑 S2_loaded/S5_ready 两个，落盘时改名加 _small 后缀。
const List<String> kSmallScreenSourceScenarios = ['S2_loaded', 'S5_ready'];

/// 稳定 Key 列表，见 CONTRACTS.md 第 7.2 节。不是每个场景都有全部这些 widget，
/// 找不到的 Key 直接跳过，不算错误。
const List<String> kStableKeysToRecord = [
  'area_a', 'area_b', 'area_c',
  'crop_box',
  'candidate_white', 'candidate_blue', 'candidate_red',
  'candidate_deep_blue', 'candidate_gray', 'candidate_blue_gradient',
  // 待契约追加，见上方说明；未落地前 _rectOf 会因找不到该 Key 而静默跳过。
  kPhotoDisplayKey,
];

Map<String, dynamic>? _rectOf(WidgetTester tester, String keyName) {
  final finder = find.byKey(Key(keyName));
  if (finder.evaluate().isEmpty) return null;
  final rect = tester.getRect(finder);
  final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
  return {
    'left': rect.left * dpr,
    'top': rect.top * dpr,
    'right': rect.right * dpr,
    'bottom': rect.bottom * dpr,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture shots pipeline', (tester) async {
    final allRects = <String, Map<String, dynamic>?>{};

    final scenarios = kShotMode == 'small' ? kSmallScreenSourceScenarios : kShotScenarios;

    // convertFlutterSurfaceToImage() 只能在整个测试生命周期里调用一次——
    // 曾经错放在循环里，第 2 个场景起必然抛 "Surface already converted to an
    // image"，导致官方 8 张只出得来 1 张（ui-woodcraft 发现并上报，记入
    // docs/PITFALLS.md）。现在只在第一个场景的首帧之后转换一次。
    var surfaceConverted = false;
    for (final scenarioId in scenarios) {
      await tester.pumpWidget(buildShotScenario(scenarioId));
      // 确定性场景：不依赖真实异步/时序，一次 pumpAndSettle 应该就能稳定下来。
      await tester.pumpAndSettle(const Duration(seconds: 2));
      if (!surfaceConverted) {
        await binding.convertFlutterSurfaceToImage();
        surfaceConverted = true;
      }
      await tester.pumpAndSettle();

      // 小屏模式最终文件名是 S2_small/S5_small，不是 S2_loaded_small——
      // 用固定映射转换，避免在 driver 侧再猜文件名规则。
      final finalName = kShotMode == 'small'
          ? (scenarioId == 'S2_loaded' ? 'S2_small' : 'S5_small')
          : scenarioId;
      await binding.takeScreenshot(finalName);

      final rects = <String, dynamic>{};
      for (final keyName in kStableKeysToRecord) {
        final r = _rectOf(tester, keyName);
        if (r != null) rects[keyName] = r;
      }
      allRects[finalName] = rects.isEmpty ? null : rects;
    }

    // 坑（本轮实测发现，记入 docs/PITFALLS.md）：`takeScreenshot()` 内部把每张截图
    // append 进 `binding.reportData!['screenshots']`（见
    // packages/integration_test/lib/integration_test.dart）。这里如果直接
    // `binding.reportData = {'rects': allRects}` 做整体赋值，会把 takeScreenshot
    // 已经积累的 'screenshots' 列表整个覆盖掉——`flutter drive` 侧的
    // `integrationDriver()` 只在 `response.data['screenshots'] != null` 时才会调用
    // `onScreenshot` 回调落盘，于是 8 张截图全部"跑完但没人写盘"，报出 0/8 且没有
    // 任何报错（All tests passed. 之下悄悄丢数据）。必须合并写入，不能整体替换。
    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['rects'] = allRects;
  });
}
