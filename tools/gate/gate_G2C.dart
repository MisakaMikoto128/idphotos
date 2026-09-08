// tools/gate/gate_G2C.dart
//
// G2C — 界面（ui-woodcraft 出口）。对应 docs/ACCEPTANCE.md 2C.1-2C.10。
//
// 2C.1/2C.2/2C.3/2C.4 靠截图（tools/gate/capture_shots.dart 的 runFullShotsPipeline，
// 依赖 docs/CONTRACTS.md 第 7 节的 shot_harness 接缝，ui-woodcraft 未交付前必然 FAIL，
// 见报告）。2C.5/2C.6/2C.7 是 widget test，本文件只负责调用
// `flutter test test/gate/crop_interaction_test.dart` 并读取其结果（那三项的具体
// 断言逻辑写在 test/gate/ 下，理由：widget test 需要 `flutter test` 的测试运行器，
// 不适合塞进用 `dart run` 跑的本文件）。2C.8/2C.9/2C.10 是纯静态检查，本文件直接做。
//
// CIEDE2000 用 tools/gate/color_utils.dart；跑之前先跑它的 selfTest()，
// 硬门槛不过就整体 FAIL——不能拿一个可能有 bug 的色差公式去判别人。
//
// 性能说明：2C.2/2C.3 要对每张截图逐像素算 ΔE00，为了让 gate 能在合理时间内跑完，
// 用步进采样（默认每 3px 取 1 个，约 1/9 像素），采样密度和总像素数一起记进
// actual 字段，方便复核不是"抽样太稀导致虚假通过"。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';
import 'png_utils.dart';
import 'color_utils.dart';
import 'capture_shots.dart';

const List<int> kDesignTokens = [
  0x3E2A1B, // woodDark
  0x6B4A2F, // woodBase
  0xA9784F, // woodLight
  0xB08D3F, // brass
  0xE8CE7A, // brassHi
  0x6E5320, // brassShadow
  0xF4E9D6, // paper
  0xDCCBAE, // paperEdge
  0x2F4F3A, // feltGreen
  0x3A2B1C, // inkBrown
  0x7A6A55, // inkFaded
  0xF0E4CE, // creamText
  0x8C2B22, // accentRed
];

const List<int> kMaterialPurpleColors = [0x6750A4, 0xD0BCFF, 0xEADDFF];

const int kSampleStride = 3;

class _Rect {
  final double left, top, right, bottom;
  const _Rect(this.left, this.top, this.right, this.bottom);
  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;
}

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G2C.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final colorSelfTestResult = selfTest();
  if (!colorSelfTestResult.hardPass) {
    stderr.writeln('CIEDE2000 自检硬门槛未通过，拒绝继续判定 G2C: ${colorSelfTestResult.hardFailures}');
    final items = [
      {
        'id': 'G2C.internal',
        'description': 'CIEDE2000 自检（本脚本内部前置条件，不是 ACCEPTANCE.md 条目）',
        'expected': '硬门槛全部通过',
        'actual': colorSelfTestResult.hardFailures.join('; '),
        'pass': false,
        'manual': false,
      }
    ];
    await writeGateReport(outPath: outPath, gateId: 'G2C', items: items);
    exit(1);
  }

  final items = <Map<String, dynamic>>[];

  final capture = await runFullShotsPipeline();
  final requiredNames = [
    'S1_empty', 'S2_loaded', 'S3_dragging', 'S4_generating', 'S5_ready', 'S6_saved',
    'S2_small', 'S5_small',
  ];
  final gotNames = capture.shotFiles.map((f) => f.replaceAll('.png', '')).toSet();
  final missing = requiredNames.where((n) => !gotNames.contains(n)).toList();

  items.add({
    'id': '2C.1',
    'description': '8 张 golden 截图全部产出且非纯黑',
    'expected': requiredNames.join(', '),
    'actual': 'success=${capture.success} degraded=${capture.degraded} '
        '得到=${capture.shotFiles.join(', ')} 缺失=${missing.join(', ')} '
        'error=${capture.error ?? '无'}',
    'pass': capture.success && missing.isEmpty && !capture.degraded,
    'manual': false,
  });

  if (missing.isNotEmpty || !capture.success) {
    // 截图都凑不齐，2C.2/2C.3/2C.4 没有输入，直接标 FAIL 并说明，不猜、不跳过。
    for (final id in ['2C.2', '2C.3', '2C.4']) {
      items.add({
        'id': id,
        'description': '依赖 2C.1 的截图产出',
        'expected': '见 ACCEPTANCE.md',
        'actual': '截图未凑齐（缺 ${missing.join(', ')}），无法判定',
        'pass': false,
        'manual': false,
      });
    }
  } else {
    items.addAll(await _colorChecks(requiredNames));
  }

  items.addAll(await _widgetTestChecks());
  items.add(await _fontSizeCheck());
  items.add(await _noSplashCheck());
  items.add(await _noNetworkCheck());

  await writeGateReport(outPath: outPath, gateId: 'G2C', items: items);
  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G2C 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  exit(allPass ? 0 : 1);
}

Future<Map<String, List<_Rect>>> _loadExcludeRects() async {
  final f = File('out/shots/_rects.json');
  final result = <String, List<_Rect>>{};
  if (!await f.exists()) return result;
  try {
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    data.forEach((scenario, v) {
      if (v == null) return;
      final rects = <_Rect>[];
      final m = v as Map<String, dynamic>;
      m.forEach((key, rv) {
        if (key == 'crop_box' || key.startsWith('candidate_')) {
          final r = rv as Map<String, dynamic>;
          rects.add(_Rect(
            (r['left'] as num).toDouble(),
            (r['top'] as num).toDouble(),
            (r['right'] as num).toDouble(),
            (r['bottom'] as num).toDouble(),
          ));
        }
      });
      result[scenario] = rects;
    });
  } catch (e) {
    stderr.writeln('警告: 解析 out/shots/_rects.json 失败: $e');
  }
  return result;
}

Future<List<Map<String, dynamic>>> _colorChecks(List<String> names) async {
  final excludeRects = await _loadExcludeRects();
  final tokenLabs = kDesignTokens
      .map((c) => rgbToLab((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF))
      .toList();
  final purpleLabs = kMaterialPurpleColors
      .map((c) => rgbToLab((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF))
      .toList();

  var totalSampled = 0;
  var totalWithinPalette = 0;
  var purpleViolations = 0;
  var totalPixelsChecked = 0;
  var blackWhiteCount = 0;
  final perImagePurpleHits = <String>[];

  for (final name in names) {
    final file = File('out/shots/$name.png');
    if (!await file.exists()) continue;
    final png = decodePng(await file.readAsBytes());
    final rects = excludeRects[name] ?? const [];

    for (var y = 0; y < png.height; y++) {
      for (var x = 0; x < png.width; x++) {
        final excluded = rects.any((r) => r.contains(x, y));
        if (excluded) continue;

        // 2C.4 纯黑/纯白：全量扫描（等值比较很便宜，不需要采样）。
        totalPixelsChecked++;
        final r = png.r(x, y), g = png.g(x, y), b = png.b(x, y);
        if ((r == 0 && g == 0 && b == 0) || (r == 255 && g == 255 && b == 255)) {
          blackWhiteCount++;
        }

        // 2C.2/2C.3 用 ΔE00，比较贵，做步进采样。
        if (x % kSampleStride != 0 || y % kSampleStride != 0) continue;
        totalSampled++;
        final lab = rgbToLab(r, g, b);
        var minDe = double.infinity;
        for (final t in tokenLabs) {
          final de = deltaE2000(lab, t);
          if (de < minDe) minDe = de;
        }
        if (minDe <= 12) totalWithinPalette++;

        for (var i = 0; i < purpleLabs.length; i++) {
          if (deltaE2000(lab, purpleLabs[i]) <= 6) {
            purpleViolations++;
            if (perImagePurpleHits.length < 20) {
              perImagePurpleHits.add('$name@($x,$y)~${kMaterialPurpleColors[i].toRadixString(16)}');
            }
          }
        }
      }
    }
  }

  final paletteRatio = totalSampled == 0 ? 0.0 : totalWithinPalette / totalSampled;
  final blackWhiteRatio = totalPixelsChecked == 0 ? 0.0 : blackWhiteCount / totalPixelsChecked;

  return [
    {
      'id': '2C.2',
      'description': '截图去除照片区域后，>=95% 像素与 DESIGN.md 色卡 ΔE00<=12',
      'expected': '>=95%',
      'actual': '${(paletteRatio * 100).toStringAsFixed(2)}%（采样 $totalSampled 像素，步进 $kSampleStride）',
      'pass': paletteRatio >= 0.95,
      'manual': false,
    },
    {
      'id': '2C.3',
      'description': '不得出现 Material 紫 #6750A4/#D0BCFF/#EADDFF 及 ΔE00<=6 邻域',
      'expected': '0',
      'actual': '$purpleViolations（示例: ${perImagePurpleHits.join(', ')}）',
      'pass': purpleViolations == 0,
      'manual': false,
    },
    {
      'id': '2C.4',
      'description': '照片区域外，纯黑#000000与纯白#FFFFFF像素合计占比<=2%',
      'expected': '<=2%',
      'actual': '${(blackWhiteRatio * 100).toStringAsFixed(3)}%（全量扫描 $totalPixelsChecked 像素）',
      'pass': blackWhiteRatio <= 0.02,
      'manual': false,
    },
  ];
}

Future<List<Map<String, dynamic>>> _widgetTestChecks() async {
  const ids = ['2C.5', '2C.6', '2C.7'];
  const descs = [
    '触摸热区：8 个裁剪控制点命中区 >=44x44 逻辑像素',
    '宽高比锁定：拖拽任一角后裁剪框宽高比与 spec 偏差 <=0.5%',
    '边界约束：拖出图片范围时裁剪框被钳制在图内',
  ];
  const testFile = 'test/gate/crop_interaction_test.dart';
  if (!await File(testFile).exists()) {
    return List.generate(
        ids.length,
        (i) => {
              'id': ids[i],
              'description': descs[i],
              'expected': '见 ACCEPTANCE.md',
              'actual': '$testFile 不存在',
              'pass': false,
              'manual': false,
            });
  }

  // 用 --reporter=json 而不是抓文本：文本格式（+1:/-1: 前缀）容易因 Flutter 版本
  // 微调而错配，JSON 事件流（testStart/testDone）是结构化的，逐条对号入座更可靠。
  final run = await runProcess('flutter', ['test', testFile, '--reporter=json'],
      timeout: const Duration(minutes: 5));

  final testNames = <int, String>{}; // testID -> name
  final testResults = <int, String>{}; // testID -> 'success'|'failure'|'error'
  for (final line in run.stdout.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
    Map<String, dynamic> event;
    try {
      event = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    if (event['type'] == 'testStart') {
      final test = event['test'] as Map<String, dynamic>;
      testNames[test['id'] as int] = test['name'] as String? ?? '';
    } else if (event['type'] == 'testDone') {
      final id = event['testID'] as int;
      if (event['hidden'] == true) continue;
      testResults[id] = event['result'] as String? ?? 'unknown';
    }
  }

  return List.generate(ids.length, (i) {
    final id = ids[i];
    String? matchedResult;
    for (final entry in testNames.entries) {
      if (entry.value.startsWith(id)) {
        matchedResult = testResults[entry.key];
        break;
      }
    }
    final pass = matchedResult == 'success';
    return {
      'id': id,
      'description': descs[i],
      'expected': 'success',
      'actual': matchedResult == null
          ? '在 flutter test --reporter=json 输出里没找到名字以 "$id" 开头的用例'
              '${run.success ? '' : '（且整体进程退出码=${run.exitCode}，可能编译失败）\n${run.tail(maxChars: 800)}'}'
          : matchedResult,
      'pass': pass,
      'manual': false,
    };
  });
}

Future<Map<String, dynamic>> _fontSizeCheck() async {
  final dir = Directory('assets/fonts');
  var total = 0;
  var count = 0;
  if (await dir.exists()) {
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        total += await e.length();
        count++;
      }
    }
  }
  return {
    'id': '2C.8',
    'description': 'assets/fonts/ 总计 <=400KB',
    'expected': '<= 409600 字节',
    'actual': '$count 个文件，合计 $total 字节',
    'pass': count > 0 && total <= 400 * 1024,
    'manual': false,
  };
}

Future<Map<String, dynamic>> _noSplashCheck() async {
  final libDir = Directory('lib');
  if (!await libDir.exists()) {
    return {
      'id': '2C.9',
      'description': 'splashFactory: NoSplash 已全局设置，无裸 InkWell',
      'expected': '两个条件都满足',
      'actual': 'lib/ 不存在',
      'pass': false,
      'manual': false,
    };
  }
  var hasNoSplash = false;
  final bareInkWells = <String>[];
  await for (final e in libDir.list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final content = await e.readAsString();
    if (content.contains('splashFactory: NoSplash') || content.contains('splashFactory:NoSplash')) {
      hasNoSplash = true;
    }
    for (final m in RegExp(r'\bInkWell\s*\(').allMatches(content)) {
      // 排除 "NoSplash"/"InkWellXxx" 之类误报已经被上面的精确正则规避；
      // 这里进一步排除紧跟在 "splashFactory:" 赋值里出现的类型引用（理论上不会匹配到，
      // 因为那是 "NoSplash" 不是 "InkWell(" 调用形式）。
      bareInkWells.add('${e.path}@${m.start}');
    }
  }
  return {
    'id': '2C.9',
    'description': 'splashFactory: NoSplash 已全局设置，无裸 InkWell',
    'expected': 'hasNoSplash=true 且 裸InkWell计数=0',
    'actual': 'hasNoSplash=$hasNoSplash，裸InkWell=${bareInkWells.length}'
        '${bareInkWells.isEmpty ? '' : ' (${bareInkWells.take(5).join(', ')})'}',
    'pass': hasNoSplash && bareInkWells.isEmpty,
    'manual': false,
  };
}

Future<Map<String, dynamic>> _noNetworkCheck() async {
  final libDir = Directory('lib');
  if (!await libDir.exists()) {
    return {
      'id': '2C.10',
      'description': '全 lib/ grep 无 http/dio/Socket/HttpClient',
      'expected': '0 命中',
      'actual': 'lib/ 不存在',
      'pass': false,
      'manual': false,
    };
  }
  final pattern = RegExp(r'\b(http|dio|Socket|HttpClient)\b');
  final hits = <String>[];
  await for (final e in libDir.list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final content = await e.readAsString();
    for (final m in pattern.allMatches(content)) {
      hits.add('${e.path}:${m.group(0)}');
      if (hits.length >= 20) break;
    }
  }
  return {
    'id': '2C.10',
    'description': '全 lib/ grep 无 http/dio/Socket/HttpClient',
    'expected': '0 命中',
    'actual': '${hits.length} 命中${hits.isEmpty ? '' : ': ${hits.join(', ')}'}',
    'pass': hits.isEmpty,
    'manual': false,
  };
}
