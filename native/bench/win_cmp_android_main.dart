// ml-porting 自用：Windows 移植的 Android 模拟器侧对照探针。
//
// 跑法（Windows，仓库根目录；换 --target 必须先 flutter clean，
// 见 PITFALLS「Windows 增量构建保留旧入口点」）：
//   export MSYS2_ARG_CONV_EXCL="*"
//   adb shell mkdir -p /data/local/tmp/win_cmp_in
//   adb push test/golden/src/. /data/local/tmp/win_cmp_in/
//   flutter clean && flutter build apk --release \
//     --target=native/bench/win_cmp_android_main.dart
//   adb install -r build/app/outputs/flutter-apk/app-release.apk
//   adb shell am start -W -n com.muzhao.muzhao/.MainActivity
//   adb root && adb pull /data/user/0/com.muzhao.muzhao/app_flutter/win_cmp .
//
// 黄金集输入经 --dart-define=WIN_CMP_IN 传入（默认见 win_cmp_core.dart）；
// 模型 assets 经 rootBundle 正常落地；alpha 产物写应用自有
// getApplicationSupportDirectory 下的 win_cmp/（emulator 可 adb root 拉取）。
// 非平台专属逻辑全部在 win_cmp_core.dart，保证两边同码。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

// path_provider 是 onnxruntime 插件的传递依赖（session_factory 同款用法）。
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import 'win_cmp_core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final outDir =
      '${support.path}${Platform.pathSeparator}win_cmp';
  Directory(outDir).createSync(recursive: true);
  await runWinCompare(
    log: (line) {
      // ignore: avoid_print
      print('WINCMP $line');
    },
    outDir: outDir,
  );
  File('$outDir${Platform.pathSeparator}win_cmp_done')
      .writeAsStringSync('done');
  exit(0);
}
