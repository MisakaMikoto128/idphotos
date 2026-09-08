// test_driver/integration_test_driver.dart
//
// 配合 integration_test/shots_test.dart 使用的标准 driver：
// 把 binding.takeScreenshot(name) 产出的字节落盘到 out/shots/<name>.png。
//
// 运行方式（由 tools/gate/capture_shots.dart 封装调用）：
//   flutter drive --driver=test_driver/integration_test_driver.dart \
//                  --target=integration_test/shots_test.dart -d <deviceId>
//
// 势力范围：gatekeeper。
//
// 依赖：pubspec.yaml 的 dev_dependencies 需要
//   integration_test: { sdk: flutter }
// （提供 integration_test_driver_extended.dart），这是主会话的职责。

import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String screenshotName, List<int> screenshotBytes,
        [Map<String, Object?>? args]) async {
      final dir = Directory('out/shots');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final file = File('${dir.path}/$screenshotName.png');
      await file.writeAsBytes(screenshotBytes, flush: true);
      // 返回 true 告知 driver 落盘成功，否则 flutter drive 会把整个流程标记为失败。
      return true;
    },
  );
}
