// test/gate/crop_interaction_test.dart
//
// G2C.5/2C.6/2C.7 的 widget test。跑法：`flutter test test/gate/crop_interaction_test.dart`
// （host 端跑，不需要模拟器——widget test 用 Flutter 的软件渲染测试环境）。
// `tools/gate/gate_G2C.dart` 会调用这个文件并从 `flutter test` 的输出里读每个用例的通过情况，
// 用例名字里必须带 2C.5/2C.6/2C.7 前缀，方便它用文本匹配对号入座。同一前缀允许对应多个
// 用例（gate 侧要求**全部**通过才算这一项通过，见 gate_G2C.dart 的聚合逻辑）。
//
// 只用 docs/CONTRACTS.md 第 7.2 节列出的稳定 Key 做 widget 查找，不碰 ui-woodcraft 的
// 内部 widget 结构（不用 find.byType 挖内部实现）。但 `CropMath`
// （lib/ui/util/crop_geometry.dart）是文档明确声明的**纯函数**（"不依赖 widget，
// 便于单独验证"），直接单测它的数学契约不算越界——这是它自己文档承诺的用法。
// 场景固定用 buildShotScenario('S2_loaded')（裁剪框默认位置，已加载 g01.jpg）。
//
// 假设（若与 ui-woodcraft 实现不符，请在报告里回派，不是我自己改这个文件去将就实现）：
//   1. `crop_handle_tl/tr/bl/br/t/b/l/r` 这 8 个 Key 挂在**可点击命中区域**本身
//      （不是挂在视觉图标上，若图标比命中区域小，Key 应该挂在外层 GestureDetector/InkWell 上）。
//   2. `buildShotScenario('S2_loaded')` 用的是默认规格 `kDefaultSpec`（即 `kSpecCn1inch`，
//      宽高比 295/413），2C.6 按这个比例校验。
//   3. 裁剪框支持 `tester.drag()`/手势拖拽来改变大小和位置。
//
// 2C.7 本轮加强（回应 `/code-review high` out/REVIEW_G2.md #2，责任 ui-woodcraft）：
// 原本的手势集成用例只把 crop_box 的边界对着**区域 A**（比照片显示区域大很多，
// 含外围木框/绒布/铜包角的留白）校验，抓不到"角点缩放返回越界矩形"这个真实缺陷——
// 那个缺陷只在锚点贴近图片边界、且请求的最小宽度超出可用空间时才会露出来，
// 露出来的越界量级往往远小于区域 A 的留白，不会被原用例的宽松边界绊到。
// 保留原用例（验证真实交互路径不出离谱情况），另加一个针对 `CropMath.resize`
// 本身的纯函数回归用例，直接构造能触发该缺陷的边界条件。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muzhao/core/api.dart' show kSpecCn1inch;
import 'package:muzhao/ui/dev/shot_harness.dart' show buildShotScenario;
import 'package:muzhao/ui/util/crop_geometry.dart' show CropMath, CropHandle;

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

  test('2C.7 边界约束(纯函数回归): 角点缩放在锚点贴近边界时仍需钳制在 bounds 内', () {
    // 复现 out/REVIEW_G2.md #2：CropMath.resize 的角点分支（topLeft/topRight/
    // bottomLeft/bottomRight）只把宽度 clamp 到 [lo, hi]，没有像边控制点分支那样
    // 结尾调用 translateIntoBounds。当 lo（minWidth 与 maxW 的较小者）超过锚点
    // （拖拽点对角的固定角）朝目标方向的可用空间时，hi 被 `math.max(lo, ...)`
    // 强制拉到等于 lo，clamp 后宽度恒为 lo，但 `left = anchor.dx - w` 完全可能
    // 落在 bounds 之外——下面构造的场景里，锚点离左边界只有 100px，
    // 但 minWidth 要求 300px，结果左边界必然探出 bounds 200px。
    const bounds = Rect.fromLTWH(0, 0, 1000, 1000);
    const aspect = 295 / 413; // kSpecCn1inch
    // current.bottomRight == (100, 500)：topLeft 拖拽时的固定锚点。
    const current = Rect.fromLTWH(50, 450, 50, 50);

    final result = CropMath.resize(
      current: current,
      handle: CropHandle.topLeft,
      pointer: const Offset(-1000, -1000),
      aspect: aspect,
      bounds: bounds,
      minWidth: 300,
    );

    expect(result.left, greaterThanOrEqualTo(bounds.left),
        reason: '角点缩放结果左边界越界: left=${result.left}（bounds.left=${bounds.left}）。'
            '说明角点分支缺少 translateIntoBounds 钳制（见 out/REVIEW_G2.md #2，责任 ui-woodcraft）。');
    expect(result.top, greaterThanOrEqualTo(bounds.top),
        reason: '角点缩放结果上边界越界: top=${result.top}（bounds.top=${bounds.top}）。');
    expect(result.right, lessThanOrEqualTo(bounds.right),
        reason: '角点缩放结果右边界越界: right=${result.right}（bounds.right=${bounds.right}）。');
    expect(result.bottom, lessThanOrEqualTo(bounds.bottom),
        reason: '角点缩放结果下边界越界: bottom=${result.bottom}（bounds.bottom=${bounds.bottom}）。');
  });
}
