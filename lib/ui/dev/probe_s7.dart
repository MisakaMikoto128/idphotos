/// 临时诊断（W1 自测用，用完即删）：驱动 S7_about 场景并打印
/// `about_sheet` 这个 Key 是否存在及其全局矩形。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'shot_harness.dart';

Future<void> main() async {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('probe S7_about', (WidgetTester tester) async {
    await tester.pumpWidget(buildShotScenario('S7_about'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    for (final String keyName in <String>['about_sheet', 'btn_about', 'area_c']) {
      final Finder f = find.byKey(Key(keyName));
      final int n = f.evaluate().length;
      if (n == 0) {
        debugPrint('PROBE $keyName found=0');
        continue;
      }
      final RenderObject? ro = f.evaluate().first.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final Rect r = ro.localToGlobal(Offset.zero) & ro.size;
        debugPrint('PROBE $keyName found=$n rect=$r');
      } else {
        debugPrint('PROBE $keyName found=$n rect=NO-SIZE');
      }
    }
    await binding.takeScreenshot('probe_S7');
  });
}
