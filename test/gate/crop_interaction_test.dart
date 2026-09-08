// test/gate/crop_interaction_test.dart
//
// G2C.5/2C.6/2C.7 的 widget test。跑法：`flutter test test/gate/crop_interaction_test.dart`
// （host 端跑，不需要模拟器——widget test 用 Flutter 的软件渲染测试环境）。
// `tools/gate/gate_G2C.dart` 会调用这个文件并从 `flutter test` 的输出里读每个用例的通过情况，
// 用例名字里必须带 2C.5/2C.6/2C.7 前缀，方便它用文本匹配对号入座。
//
// 只用 docs/CONTRACTS.md 第 7.2 节列出的稳定 Key，不碰 ui-woodcraft 的内部实现。
// 场景固定用 buildShotScenario('S2_loaded')（裁剪框默认位置，已加载 g01.jpg）。
//
// 假设（若与 ui-woodcraft 实现不符，请在报告里回派，不是我自己改这个文件去将就实现）：
//   1. `crop_handle_tl/tr/bl/br/t/b/l/r` 这 8 个 Key 挂在**可点击命中区域**本身
//      （不是挂在视觉图标上，若图标比命中区域小，Key 应该挂在外层 GestureDetector/InkWell 上）。
//   2. `buildShotScenario('S2_loaded')` 用的是默认规格 `kDefaultSpec`（即 `kSpecCn1inch`，
//      宽高比 295/413），2C.6 按这个比例校验。
//   3. 裁剪框支持 `tester.drag()`/手势拖拽来改变大小和位置。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muzhao/core/api.dart' show kSpecCn1inch;
import 'package:muzhao/ui/dev/shot_harness.dart' show buildShotScenario;

const double kMinHitTargetSize = 44.0;

const List<String> kCropHandleKeys = [
  'crop_handle_tl', 'crop_handle_tr', 'crop_handle_bl', 'crop_handle_br',
  'crop_handle_t', 'crop_handle_b', 'crop_handle_l', 'crop_handle_r',
];

void main() {
  testWidgets('2C.5 触摸热区: 8 个裁剪控制点命中区 >= 44x44 逻辑像素', (tester) async {
    await tester.pumpWidget(buildShotScenario('S2_loaded'));
    await tester.pumpAndSettle();

    final undersized = <String>[];
    for (final key in kCropHandleKeys) {
      final finder = find.byKey(Key(key));
      expect(finder, findsOneWidget, reason: '找不到稳定 Key $key，CONTRACTS.md 第 7.2 节要求必须挂');
      final rect = tester.getRect(finder);
      if (rect.width < kMinHitTargetSize || rect.height < kMinHitTargetSize) {
        undersized.add('$key(${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)})');
      }
    }
    expect(undersized, isEmpty, reason: '以下控制点命中区小于 44x44: ${undersized.join(', ')}');
  });

  testWidgets('2C.6 宽高比锁定: 拖拽任一角后裁剪框宽高比与 spec 偏差 <= 0.5%', (tester) async {
    await tester.pumpWidget(buildShotScenario('S2_loaded'));
    await tester.pumpAndSettle();

    final handle = find.byKey(const Key('crop_handle_br'));
    expect(handle, findsOneWidget);
    final start = tester.getCenter(handle);

    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-40, -60)); // 往内缩一点，触发 resize
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final boxFinder = find.byKey(const Key('crop_box'));
    expect(boxFinder, findsOneWidget);
    final rect = tester.getRect(boxFinder);
    final actualRatio = rect.width / rect.height;
    final expectedRatio = kSpecCn1inch.aspectRatio;
    final deviation = (actualRatio - expectedRatio).abs() / expectedRatio;
    expect(deviation, lessThanOrEqualTo(0.005),
        reason: '拖拽后宽高比 $actualRatio，期望 $expectedRatio（cn_1inch），偏差 ${deviation * 100}%');
  });

  testWidgets('2C.7 边界约束: 拖出图片范围时裁剪框被钳制在图内', (tester) async {
    await tester.pumpWidget(buildShotScenario('S2_loaded'));
    await tester.pumpAndSettle();

    final areaAFinder = find.byKey(const Key('area_a'));
    expect(areaAFinder, findsOneWidget);
    final areaRect = tester.getRect(areaAFinder);

    final handle = find.byKey(const Key('crop_handle_tl'));
    expect(handle, findsOneWidget);
    final start = tester.getCenter(handle);

    final gesture = await tester.startGesture(start);
    // 故意拖到远超区域 A 边界之外（左上角拖到负坐标很远的地方）。
    await gesture.moveBy(const Offset(-5000, -5000));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    final boxFinder = find.byKey(const Key('crop_box'));
    expect(boxFinder, findsOneWidget);
    final boxRect = tester.getRect(boxFinder);

    expect(boxRect.left, greaterThanOrEqualTo(areaAFinder.evaluate().isEmpty ? 0 : areaRect.left - 1),
        reason: '裁剪框左边界跑出了区域 A 之外: box.left=${boxRect.left} area.left=${areaRect.left}');
    expect(boxRect.top, greaterThanOrEqualTo(areaRect.top - 1),
        reason: '裁剪框上边界跑出了区域 A 之外: box.top=${boxRect.top} area.top=${areaRect.top}');
  });
}
