/// 开发预览入口（**不是** App 的正式入口，`lib/main.dart` 才是）。
///
/// 用途：ui-woodcraft 自查材质与布局。
///
///     flutter run -d <device> -t lib/ui/dev/shot_app.dart
///
/// 右上角有一块 80×80 的**透明**热区，点一下切到下一个截图场景 —— 这样可以用
///
///     adb shell input tap <x> <y>
///     adb exec-out screencap -p > out/shots/Sx.png
///
/// 一次构建把 6 个场景全看完，不用为每个场景重编一次。热区完全透明，
/// 不影响画面，也不参与正式构建（正式入口不引用本文件）。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import 'shot_harness.dart';

void main() {
  runApp(const ShotPreviewApp());
}

class ShotPreviewApp extends StatefulWidget {
  const ShotPreviewApp({super.key});

  @override
  State<ShotPreviewApp> createState() => _ShotPreviewAppState();
}

class _ShotPreviewAppState extends State<ShotPreviewApp> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          KeyedSubtree(
            key: ValueKey<int>(_i),
            child: buildShotScenario(kShotScenarios[_i]),
          ),
          Align(
            alignment: Alignment.topRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(
                  () => _i = (_i + 1) % kShotScenarios.length),
              child: const SizedBox(width: 80, height: 80),
            ),
          ),
        ],
      ),
    );
  }
}
