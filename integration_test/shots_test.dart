// integration_test/shots_test.dart
//
// 截图流水线（G1.6 生命线 / capture-shots skill 的唯一实现）。
// 势力范围：gatekeeper。ui-woodcraft/qa-batch/visual-critic/store-assets 只消费
// out/shots/ 下的产出，不应修改本文件；如需新增截图场景，在报告里向 gatekeeper 提需求。
//
// 当前阶段（G1，lib/ 还没有正式 UI）：只验证"流水线本身能不能跑通"——
// 启动 App → convertFlutterSurfaceToImage() → pumpAndSettle() → takeScreenshot()
// → 由 test_driver/integration_test_driver.dart 落盘到 out/shots/。
//
// 阶段 2 UI 就绪后，把 kScenarios 换成 capture-shots skill 规定的 8 个场景
// （S1_empty / S2_loaded / S3_dragging / S4_generating / S5_ready / S6_saved /
//  S2_small / S5_small），每个场景的 prepare 回调负责把界面/FakeController
// 驱动到对应状态。这里先用常量列表把结构搭好，方便后续只改列表不改主流程。
//
// 依赖：需要 pubspec.yaml 的 dev_dependencies 声明
//   integration_test: { sdk: flutter }
//   flutter_test: { sdk: flutter }
// 这是主会话（pubspec.yaml 唯一写入者）的职责，本文件写好后请主会话在阶段 1.5 补上。
//
// 关于 app 入口的引用：pubspec.yaml 的 name 现已确定为 muzhao，
// 本文件用标准的 package:muzhao/main.dart 引用应用入口（符合 Flutter 官方 integration_test 惯例，
// 也避免 avoid_relative_lib_imports lint）。

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:muzhao/main.dart' as app;

/// 一个截图场景：名字 + 如何把界面驱动到该场景对应的状态。
class ShotScenario {
  final String name;
  final Future<void> Function(WidgetTester tester) prepare;
  const ShotScenario(this.name, this.prepare);
}

/// 阶段 1（G1）场景列表：只验证流水线本身，截 1 张默认 App 的首屏。
final List<ShotScenario> kPhase1Scenarios = <ShotScenario>[
  ShotScenario('S1_empty', (tester) async {
    // 阶段1还没有真实 UI，这里只是等首帧稳定下来。
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }),
];

/// 阶段 2 起替换为这份（示例结构，具体 prepare 实现留给阶段 2 时的 gatekeeper 补全，
/// 依赖 ui-woodcraft 提供的 FakeController /真实 Controller 状态钩子）：
///
/// final List<ShotScenario> kFullScenarios = <ShotScenario>[
///   ShotScenario('S1_empty', ...),
///   ShotScenario('S2_loaded', ...),
///   ShotScenario('S3_dragging', ...),
///   ShotScenario('S4_generating', ...),
///   ShotScenario('S5_ready', ...),
///   ShotScenario('S6_saved', ...),
///   ShotScenario('S2_small', ...), // 需在 MuZhao_Small (720x1280) AVD 上跑
///   ShotScenario('S5_small', ...),
/// ];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture shots pipeline', (tester) async {
    app.main();
    // 首帧可能有异步初始化（比如后续阶段的 warmUp），多等一会儿再转换 surface。
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 关键：不转换成 image 的话，截图会是纯黑——这是最常见的失败模式。
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();

    for (final scenario in kPhase1Scenarios) {
      await scenario.prepare(tester);
      await tester.pumpAndSettle();
      await binding.takeScreenshot(scenario.name);
    }
  });
}
