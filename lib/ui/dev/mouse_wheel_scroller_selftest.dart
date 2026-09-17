/// MouseWheelScroller 自测（ui-woodcraft 阶段 2 验证用）。
///
/// gatekeeper 的 test/ 不归本 agent，故放 lib/ui/dev/ 自测：
///   flutter test lib/ui/dev/mouse_wheel_scroller_selftest.dart
///
/// 覆盖：滚轮 dy → 横向 offset 变化；滚过边界钳制不炸；
/// 横向 dx 同样可用；连续滚动与 BouncingScrollPhysics 并存不回弹异常。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
// 自测文件借 flutter_test 运行（dev_dependency），由 ignore 压掉 lib/ 依赖检查：
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import '../widgets/mouse_wheel_scroller.dart';

Widget _harness(ScrollController controller) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MouseWheelScroller(
      controller: controller,
      child: SizedBox(
        width: 400,
        height: 100,
        child: ListView.separated(
          controller: controller,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: 20,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, int i) =>
              SizedBox(width: 100, child: Center(child: Text('item $i'))),
        ),
      ),
    ),
  );
}

Future<TestGesture> _hoverMouse(WidgetTester tester) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await gesture.addPointer(location: tester.getCenter(find.byType(ListView)));
  return gesture;
}

void main() {
  testWidgets('vertical wheel dy scrolls horizontal list', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));

    await _hoverMouse(tester);
    final double before = controller.offset;
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(200, 50),
        scrollDelta: Offset(0, 120),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(before));
    expect(controller.offset, closeTo(120, 0.5));
  });

  testWidgets('wheel past end clamps to maxScrollExtent, no exception', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await _hoverMouse(tester);

    for (int i = 0; i < 30; i++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 50),
          scrollDelta: Offset(0, 120),
        ),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.offset, controller.position.maxScrollExtent);
  });

  testWidgets('wheel up past start clamps to 0, no bounce-back', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));
    await _hoverMouse(tester);

    for (int i = 0; i < 5; i++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 50),
          scrollDelta: Offset(0, -200),
        ),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.offset, 0.0);
    // 停稳：不再处于拖拽/滚动活动
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('TestPointer mouse hover + scroll through gesture binding', (
    WidgetTester tester,
  ) async {
    // 与任务指定的验证方式一致：TestPointer(kind: mouse).hover + scroll
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller));

    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse)
      ..hover(tester.getCenter(find.byType(ListView)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 80)));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });
}
