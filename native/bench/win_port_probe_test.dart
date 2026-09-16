// ml-porting 自用：Windows 桌面移植探针（宿主侧）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/win_port_probe_test.dart
//
// 产出与 Android 模拟器侧（win_cmp_android_main.dart）逐字节可比：
//   - 黄金集 8 张 alpha sha256（CPU EP 钉死）
//   - g01 原始 alpha 字节（写系统临时目录，路径见输出）
//   - g01 FaceInfo 数值、512×512 单张耗时、非人像优雅失败抽查
@Timeout(Duration(minutes: 30))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'win_cmp_core.dart';

void main() {
  late String outDir;
  setUpAll(() async {
    outDir = '${Directory.systemTemp.path}'
        '${Platform.pathSeparator}muzhao_win_cmp';
    Directory(outDir).createSync(recursive: true);
  });

  test('windows port numeric comparison', () async {
    await runWinCompare(
      log: (line) {
        // ignore: avoid_print
        print(line);
      },
      outDir: outDir,
      includeRobustness: true,
    );
    // ignore: avoid_print
    print('OUTDIR $outDir');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
