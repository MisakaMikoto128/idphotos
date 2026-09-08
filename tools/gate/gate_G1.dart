// tools/gate/gate_G1.dart
//
// G1 — 环境与黄金集（阶段 1 出口）。逐条对应 docs/ACCEPTANCE.md 的 1.1-1.7。
//
// 用法：
//   dart run tools/gate/gate_G1.dart [--out out/gate_G1.json]
//
// 退出码 0 = 全部 PASS；非 0 = 存在 FAIL 或 MANUAL（未验证）项。
// 势力范围：gatekeeper。任何实现类 agent 不应修改本文件。

import 'dart:io';

import 'gate_common.dart';
import 'png_utils.dart';
import 'capture_shots.dart';
import 'collect_metrics.dart';

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G1.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final items = <Map<String, dynamic>>[];

  items.add(await _check1_1());
  items.add(await _check1_2());
  items.add(await _check1_3());
  final refCheck = await _check1_4And1_5();
  items.add(refCheck['1.4']!);
  items.add(refCheck['1.5']!);
  items.add(await _check1_6());
  items.add(await _check1_7());

  await writeGateReport(outPath: outPath, gateId: 'G1', items: items);

  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G1 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  for (final i in items) {
    stdout.writeln('  ${i['id']}: pass=${i['pass']} manual=${i['manual']} actual=${_shorten(i['actual'])}');
  }
  exit(allPass ? 0 : 1);
}

String _shorten(dynamic v) {
  final s = v?.toString() ?? '';
  if (s.length <= 200) return s;
  return '${s.substring(0, 200)}...(截断)';
}

/// 1.1 `flutter build apk --debug` 退出码必须 0。
Future<Map<String, dynamic>> _check1_1() async {
  const id = '1.1';
  const desc = 'flutter build apk --debug 退出码为 0';

  final flutterCheck = await runProcess('flutter', ['--version'], timeout: const Duration(seconds: 30));
  if (!flutterCheck.ok) {
    return _fail(id, desc, expected: '0',
        actual: 'flutter 命令不可用（可能 env-setup 尚未完成安装或未加入 PATH）: ${flutterCheck.stderr}');
  }

  if (!await File('pubspec.yaml').exists()) {
    return _fail(id, desc, expected: '0',
        actual: '项目根目录尚无 pubspec.yaml，Flutter 工程还未脚手架化，无法执行 flutter build');
  }

  final build = await runProcess(
    'flutter',
    ['build', 'apk', '--debug'],
    timeout: const Duration(minutes: 15),
  );
  return {
    'id': id,
    'description': desc,
    'expected': '0',
    'actual': 'exitCode=${build.exitCode} timedOut=${build.timedOut}\n${build.tail()}',
    'pass': build.success,
    'manual': false,
  };
}

/// 1.2 docs/ENV.md 无 `- [ ]` 未填项。
Future<Map<String, dynamic>> _check1_2() async {
  const id = '1.2';
  const desc = 'docs/ENV.md 中 "- [ ]" 计数为 0';
  final f = File('docs/ENV.md');
  if (!await f.exists()) {
    return _fail(id, desc, expected: '0', actual: 'docs/ENV.md 不存在');
  }
  final content = await f.readAsString();
  final count = RegExp(r'- \[ \]').allMatches(content).length;
  return {
    'id': id,
    'description': desc,
    'expected': '0',
    'actual': '$count',
    'pass': count == 0,
    'manual': false,
  };
}

/// 1.3 test/golden/src/ 下 >=8 张人像 JPEG。
Future<Map<String, dynamic>> _check1_3() async {
  const id = '1.3';
  const desc = 'test/golden/src/ 下 >= 8 张 JPEG';
  final dir = Directory('test/golden/src');
  if (!await dir.exists()) {
    return _fail(id, desc, expected: '>=8', actual: 'test/golden/src/ 目录不存在');
  }
  final files = await dir
      .list()
      .where((e) => e is File && _isJpeg(e.path))
      .toList();
  final count = files.length;
  return {
    'id': id,
    'description': desc,
    'expected': '>=8',
    'actual': '$count',
    'pass': count >= 8,
    'manual': false,
  };
}

bool _isJpeg(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg');
}

/// 1.4 test/golden/ref/ 下与 src 同名 PNG，数量一致。
/// 1.5 每张参考 alpha 前景占比在 8%-70% 之间。
/// 两者共用同一份文件枚举，合并实现，分别返回两个 item。
Future<Map<String, Map<String, dynamic>>> _check1_4And1_5() async {
  const id4 = '1.4';
  const desc4 = 'test/golden/ref/ 下与 src 同名 PNG，数量一致';
  const id5 = '1.5';
  const desc5 = '每张参考 alpha 前景占比在 8%-70% 之间';

  final srcDir = Directory('test/golden/src');
  final refDir = Directory('test/golden/ref');

  if (!await srcDir.exists()) {
    final fail4 = _fail(id4, desc4, expected: '与 src 数量一致', actual: 'test/golden/src/ 不存在');
    final fail5 = _fail(id5, desc5, expected: '全部在 8%-70%', actual: 'test/golden/src/ 不存在，无法比对');
    return {'1.4': fail4, '1.5': fail5};
  }
  if (!await refDir.exists()) {
    final fail4 = _fail(id4, desc4, expected: '与 src 数量一致', actual: 'test/golden/ref/ 目录不存在');
    final fail5 = _fail(id5, desc5, expected: '全部在 8%-70%', actual: 'test/golden/ref/ 目录不存在');
    return {'1.4': fail4, '1.5': fail5};
  }

  final srcFiles = await srcDir.list().where((e) => e is File && _isJpeg(e.path)).toList();
  final srcStems = srcFiles.map((e) => _stem(e.path)).toSet();

  final refFiles = await refDir
      .list()
      .where((e) => e is File && e.path.toLowerCase().endsWith('.png'))
      .cast<File>()
      .toList();
  final refStems = refFiles.map((e) => _stem(e.path)).toSet();

  final missing = srcStems.difference(refStems);
  final extra = refStems.difference(srcStems);
  final countMatch = srcStems.length == refStems.length && missing.isEmpty && extra.isEmpty;

  final item4 = {
    'id': id4,
    'description': desc4,
    'expected': 'src=${srcStems.length} 张，ref 同名同数量',
    'actual': 'ref=${refStems.length} 张；缺失=${missing.toList()}；多余=${extra.toList()}',
    'pass': countMatch,
    'manual': false,
  };

  // 1.5：只对 src/ref 都存在的交集文件做前景占比校验；解码失败的文件单独列出并判 FAIL。
  final commonStems = srcStems.intersection(refStems);
  final outOfRange = <String>[];
  final decodeErrors = <String>[];
  for (final stem in commonStems) {
    final refFile = refFiles.firstWhere((f) => _stem(f.path) == stem);
    try {
      final bytes = await refFile.readAsBytes();
      final png = decodePng(bytes);
      final ratio = foregroundRatio(png);
      if (ratio < 0.08 || ratio > 0.70) {
        outOfRange.add('$stem(${(ratio * 100).toStringAsFixed(1)}%)');
      }
    } catch (e) {
      decodeErrors.add('$stem(解码失败: $e)');
    }
  }

  final pass5 = commonStems.isNotEmpty && outOfRange.isEmpty && decodeErrors.isEmpty;
  final item5 = {
    'id': id5,
    'description': desc5,
    'expected': '全部在 8%-70%',
    'actual': commonStems.isEmpty
        ? '没有可比对的 src/ref 交集文件'
        : '超范围: ${outOfRange.isEmpty ? '无' : outOfRange.join(', ')}；'
            '解码失败: ${decodeErrors.isEmpty ? '无' : decodeErrors.join(', ')}',
    'pass': pass5,
    'manual': false,
  };

  return {'1.4': item4, '1.5': item5};
}

String _stem(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot == -1 ? name : name.substring(0, dot);
}

/// 1.6 截图流水线打通：至少落盘 1 张非纯黑 PNG 到 out/shots/。
Future<Map<String, dynamic>> _check1_6() async {
  const id = '1.6';
  const desc = '截图流水线打通，out/shots/ 下 >=1 张非纯黑 PNG';

  if (!await File('integration_test/shots_test.dart').exists() ||
      !await File('lib/main.dart').exists()) {
    return _fail(id, desc,
        expected: '>=1 张非纯黑 PNG',
        actual: 'lib/main.dart 尚不存在（Flutter 工程还未脚手架化），流水线本身已就绪，'
            '待主会话/env-setup 完成 flutter create 后可验证');
  }

  final result = await runCaptureShots();
  return {
    'id': id,
    'description': desc,
    'expected': '>=1 张非纯黑 PNG，写明 degraded 标记',
    'actual': 'success=${result.success} degraded=${result.degraded} '
        'shots=${result.shotFiles} error=${result.error ?? '无'}\n${_shorten(result.log)}',
    'pass': result.success,
    'manual': false,
    if (result.degraded) 'degraded': true,
  };
}

/// 1.7 内存/耗时采集打通：能从模拟器读到峰值内存与单步耗时，写入 JSON。
Future<Map<String, dynamic>> _check1_7() async {
  const id = '1.7';
  const desc = '内存/耗时采集打通，写入 out/gate_metrics.json';

  final result = await runCollectMetrics();
  return {
    'id': id,
    'description': desc,
    'expected': 'coldStartMs 与 peakMemoryKb 均非 null',
    'actual': 'coldStartMs=${result.coldStartMs} peakMemoryKb=${result.peakMemoryKb} '
        'packageId=${result.packageId} error=${result.error ?? '无'}\n${_shorten(result.log)}',
    'pass': result.success,
    'manual': false,
  };
}

Map<String, dynamic> _fail(String id, String desc, {required String expected, required String actual}) {
  return {
    'id': id,
    'description': desc,
    'expected': expected,
    'actual': actual,
    'pass': false,
    'manual': false,
  };
}
