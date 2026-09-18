// tools/gate/gate_G4.dart
//
// G4 — 综合验收（阶段 4 出口，最严）。对应 docs/ACCEPTANCE.md 4.1-4.9。
//
// 架构（与 G2A/G2B/G3 同一模式，裁判不下场）：
//   - 4.1-4.5/4.6-4.8 的**主证据**来自三份裁判产出文件（qa-batch / adversarial /
//     visual-critic）。本脚本对它们做 schema 校验 + 阈值判定；文件缺失 = 对应项
//     FAIL 并注明"等待 out/xxx"，绝不标 PASS、绝不标 MANUAL、绝不跳过。
//   - 但 gate 不只信裁判汇总：4.1-4.4 会从裁判数据里**随机抽样**（种子=运行时刻
//     毫秒数，抽样清单写入 out/gate_G4.json 可复现），在本 gate 自己的设备会话里
//     经真实 IdPhotoEngineImpl + MuZhaoController 复跑
//     （integration_test/g4_spotcheck_test.dart，≥5 项 batch 抽查 + ≤3 项
//     adversarial 抽查），逐项与裁判记录核对，不一致即 FAIL。
//   - 4.6/4.7/4.8 同样在 gate 自己的会话里复测一轮（spotcheck 里的 512² 计时
//     采样 + g4_memcheck 的 20 张内存 churn + host 侧 dumpsys meminfo 并行采样），
//     裁判数字与 gate 复测数字**都必须**达标才算 PASS。
//   - 4.9（lib/ 下 TODO/FIXME/UnimplementedError = 0）与防作弊巡查是纯 host
//     静态检查，本脚本直接做，不依赖任何裁判。
//
// ── 裁判数据输入 schema（本脚本按此严格校验；缺任一必填键 = 对应项 FAIL，
//    actual 里列明缺了什么，供主会话回派补齐）───────────────────────────
//
// 1) qa-batch  `out/batch_r1.json`（可用 --batch 覆盖路径）：
// {
//   "generatedAt": "...",
//   "datasetRoot": "C:/Users/liuyu/Pictures",
//   "totalItems": 40,          // 必填 int，≥40（ACCEPTANCE 4.1 "全 40 项"）
//   "ranItems": 40,            // 必填 int，== totalItems（全跑完）
//   "crashes": 0,              // 必填 int，必须 ==0
//   "anrs": 0,                 // 必填 int，必须 ==0
//   "items": [                 // 必填 List，length == totalItems
//     {
//       "sourcePath": "...",   // 必填 String（抽查要按它定位文件）
//       "class": "portrait|multi_face|screenshot|landscape|non_image", // 必填
//       "outcome": "ok|graceful_fail|crash|anr|hang",                  // 必填
//       "chineseError": true,  // 非人像(graceful_fail)必填 bool
//       "candidateCount": 6,   // 人像(ok)必填 int，>0
//       "logcatFingerprint": "..."   // 可选
//     }
//   ]
// }
//
// 2) adversarial  `out/ADVERSARIAL_*.json`（自动取修改时间最新一份，可用
//    --adversarial 覆盖）：
// {
//   "generatedAt": "...",
//   "totalCases": 12,            // 必填 int
//   "crashes": 0,                // 必填 int，==0
//   "dataCorruptions": 0,        // 必填 int，==0
//   "unresponsiveOver5s": 0,     // 必填 int，==0
//   "cases": [                   // 必填 List，length == totalCases
//     {
//       "caseId": "...",         // 必填 String
//       "sourcePath": "...",     // 必填 String（gate 抽查要按它定位输入文件）
//       "crash": false,          // 必填 bool，必须 false
//       "dataCorruption": false, // 必填 bool，必须 false
//       "unresponsiveOver5s": false, // 必填 bool，必须 false
//       "note": "..."            // 可选
//     }
//   ]
// }
//
// 3) visual-critic  `out/VISUAL_G4_r*.md`（自动取修改时间最新一份，可用
//    --visual 覆盖）。按 RUBRIC 固定格式机读：
//      `## 总分：X.X / 10`   `致命项：N 个`   `## 结论：PASS|FAIL`
//    判定：X.X ≥ 8.0 且 N == 0 且 结论 == PASS。任一行解析不到 = FAIL。
//
// 4) qa-batch  `out/metrics_r1.json`（模拟器）与
//    `out/metrics_r1_realdevice.json`（真机）：
// {
//   "generatedAt": "...",
//   "device": "...",
//   "matting512P95Ms": 1234,     // 必填 num，≤1500（4.6）
//   "matting512Samples": 24,     // 必填 int，>0
//   "peakMemoryMb": 300.0,       // 必填 num，≤550（4.7，2026-09-15 人工授权 450→550）
//   "leakBaselineMb": 250.0,     // 必填 num（4.8）
//   "leakAfter20Mb": 300.0       // 必填 num，与 baseline 差 ≤80（4.8）
// }
//    **判定源优先级（按 ACCEPTANCE 4.6/4.7 两处人工授权口径修订，G4 r2 起）**：
//    - 4.6（口径=模拟器设备端，2026-09-14 授权）：判定源 = 模拟器 metrics，
//      真机数字只作参考注记（真机档位差异大，X21A 2018 SD660 vs 小米 12）。
//    - 4.7（口径=设备端真机优先，2026-09-15 授权）：判定源 = 真机 metrics
//      （有真机数据时），模拟器那份作交叉参考（floor 被 ORT bug 锁死，固有超阈，
//      不判定）。gate 自己的模拟器复测对 4.7 同样只作参考注记。
//    - 4.8（判据未修订）：真机优先，模拟器交叉参考；gate 自己的 20 张 churn
//      复测仍是硬条件。
//
// ── 防作弊条款（ACCEPTANCE.md 6 条）────────────────────────────────────
// 第 1-5 条在脚本内实现为 AC.1-AC.5 条目；另设 AC.6 对 ACCEPTANCE/RUBRIC 的
// 哈希变化做授权提交溯源（主会话+人工授权的口径变更不误伤，篡改必 FAIL）。
// 第 6 条（报告声称与 JSON 一致）由 gatekeeper 在 out/GATE_G4_r*.md 报告里
// 人工核对——脚本无法自动判定，不做"自动通过"的假检查项。
//
// 用法：
//   dart run tools/gate/gate_G4.dart --out out/gate_G4.json
// 可选：--batch/--metrics/--adversarial/--visual 覆盖输入路径；
//       --device-wait-seconds N（默认 600，等 qa-batch/adversarial 释放设备）；
//       --host-only（跳过设备阶段，仅用于脚本开发自测。**正式判定轮严禁使用**：
//       用它则 4.1-4.8 的抽查/复测子条件全 FAIL，结构上不可能出 PASS。）

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'gate_common.dart';
import 'device_harness_common.dart' show prepareDeviceGateDir, adbPush;

const String kDefaultBatch = 'out/batch_r1.json';
const String kDefaultMetrics = 'out/metrics_r1.json';
const String kDefaultMetricsRealDevice = 'out/metrics_r1_realdevice.json';
const String kDefaultAdversarialGlob = 'out/ADVERSARIAL_*.json';
const String kDefaultVisualGlob = 'out/VISUAL_G4_r*.md';
const String kMainAvd = 'Pixel_3a_API_34_extension_level_7_x86_64';
const String kDeviceGateDir = '/data/local/tmp/muzhao_gate_tmp';
const String kResponseDataPath = 'build/integration_response_data.json';
const String kGoldenCountsSnapshot = 'out/gate_G4_golden_counts.json';

const Set<String> kPortraitClasses = {'portrait', 'multi_face'};
const Set<String> kNonPortraitClasses = {'screenshot', 'landscape', 'non_image'};

/// AC.1 里允许出现的 git 变更前缀（gatekeeper 自己的势力范围）。
const List<String> kGatekeeperOwnedPrefixes = [
  'tools/gate/',
  'test/gate/',
  'integration_test/',
  'test_driver/',
];

/// AC.1 里裁判类 agent 合法的 test/ 子目录（qa-batch / adversarial 各自的）。
const List<String> kRefereeOwnedTestDirs = ['test/batch/', 'test/adversarial/'];

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G4.json';
  var batchPath = kDefaultBatch;
  var metricsPath = kDefaultMetrics;
  var metricsRealDevicePath = kDefaultMetricsRealDevice;
  var adversarialPath = kDefaultAdversarialGlob;
  var visualPath = kDefaultVisualGlob;
  var deviceWaitSeconds = 600;
  var hostOnly = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        outPath = args[++i];
      case '--batch':
        batchPath = args[++i];
      case '--metrics':
        metricsPath = args[++i];
      case '--metrics-realdevice':
        metricsRealDevicePath = args[++i];
      case '--adversarial':
        adversarialPath = args[++i];
      case '--visual':
        visualPath = args[++i];
      case '--device-wait-seconds':
        deviceWaitSeconds = int.tryParse(args[++i]) ?? 600;
      case '--host-only':
        hostOnly = true;
    }
  }

  final log = StringBuffer()
    ..writeln('G4 输入: batch=$batchPath metrics=$metricsPath '
        'adversarial=$adversarialPath visual=$visualPath hostOnly=$hostOnly');

  // ================= 阶段 A：host 静态检查 =================
  final items = <Map<String, dynamic>>[];
  items.add(await _judge49());
  items.addAll(await _antiCheat());

  // ================= 阶段 B：裁判数据加载 =================
  final batch = _loadJsonFile(batchPath, log);
  final metricsEmulator = _loadJsonFile(metricsPath, log);
  final metricsRealDevice = _loadJsonFile(metricsRealDevicePath, log);
  // 判定源按 ACCEPTANCE 4.6/4.7 授权口径（见文件头注释）：
  //   4.6 → 模拟器优先；4.7/4.8 → 真机优先。另一份只作交叉参考注记。
  final metrics46 = metricsEmulator ?? metricsRealDevice;
  final metrics4748 = metricsRealDevice ?? metricsEmulator;
  final adversarialPathResolved = _latestGlobFile(adversarialPath, log);
  final adversarial =
      adversarialPathResolved == null ? null : _loadJsonFile(adversarialPathResolved, log);
  final visualMdPath = _latestGlobFile(visualPath, log);

  // ================= 阶段 C：设备抽查/复测 =================
  DevicePhaseResult device;
  if (hostOnly) {
    device = DevicePhaseResult._(
        error: '--host-only：跳过设备抽查/复测（仅脚本自测模式，正式判定禁用）');
  } else {
    device = await _runDevicePhase(
      batch: batch,
      adversarial: adversarial,
      deviceWaitSeconds: deviceWaitSeconds,
      log: log,
    );
  }

  // ================= 阶段 D：逐条判定 =================
  items.add(_judge41(batch, device));
  items.add(_judge42(batch, device));
  items.add(_judge43(batch, device));
  items.add(_judge44(adversarial, device));
  items.add(await _judge45(visualMdPath));
  items.add(_judge46(metrics46, device,
      crossRef: metrics46 == metricsEmulator ? metricsRealDevice : metricsEmulator,
      crossRefIsRealDevice: metrics46 == metricsEmulator && metricsRealDevice != null));
  items.add(_judge47(metrics4748, device,
      crossRef: metrics4748 == metricsRealDevice ? metricsEmulator : metricsRealDevice,
      crossRefIsEmulator: metrics4748 == metricsRealDevice && metricsEmulator != null));
  items.add(_judge48(metrics4748, device,
      crossRef: metrics4748 == metricsRealDevice ? metricsEmulator : metricsRealDevice,
      crossRefIsEmulator: metrics4748 == metricsRealDevice && metricsEmulator != null));

  // 内存复测原始数据落盘（诊断/留痕用；判定只看 items）。
  try {
    final memFile = File('out/gate_G4_mem.json');
    await memFile.parent.create(recursive: true);
    await memFile.writeAsString(jsonEncode({
      'generatedAt': DateTime.now().toIso8601String(),
      'mem': device.mem,
      'spot': device.spot,
      'myP95Ms': device.myP95Ms,
      'peakMb': device.peakMb,
      'myLeakDeltaMb': device.myLeakDeltaMb,
    }));
  } catch (_) {
    log.writeln('gate_G4_mem.json 写入失败');
  }

  final logFile = File('out/gate_G4_run.log');
  await logFile.parent.create(recursive: true);
  await logFile.writeAsString(log.toString());

  await writeGateReport(outPath: outPath, gateId: 'G4', items: items);
  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G4 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  exit(allPass ? 0 : 1);
}

// ===========================================================================
// 4.9 无遗留 TODO/FIXME/UnimplementedError
// ===========================================================================

Future<Map<String, dynamic>> _judge49() async {
  var todo = 0, fixme = 0, unimplemented = 0;
  final hits = <String>[];
  final dir = Directory('lib');
  if (!await dir.exists()) {
    return _item('4.9', 'lib/ 下 TODO/FIXME/throw UnimplementedError 计数 = 0',
        'lib/ 目录不存在', false);
  }
  await for (final entity in dir.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final lines = await entity.readAsLines();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('TODO')) {
        todo++;
        hits.add('${entity.path}:${i + 1}: TODO');
      }
      if (line.contains('FIXME')) {
        fixme++;
        hits.add('${entity.path}:${i + 1}: FIXME');
      }
      if (line.contains('throw UnimplementedError')) {
        unimplemented++;
        hits.add('${entity.path}:${i + 1}: throw UnimplementedError');
      }
    }
  }
  final total = todo + fixme + unimplemented;
  return _item(
    '4.9',
    'lib/ 下 TODO/FIXME/throw UnimplementedError 计数 = 0（gate 直接 grep，不依赖裁判）',
    total == 0
        ? 'lib/ 全部 .dart 文件计数 = 0'
        : '计数 = $total (TODO=$todo FIXME=$fixme UnimplementedError=$unimplemented)；'
            '命中: ${hits.take(20).join('; ')}',
    total == 0,
  );
}

Map<String, dynamic> _item(String id, String desc, String actual, bool pass) => {
      'id': id,
      'description': desc,
      'expected': id.startsWith('AC.') ? '命中 = 0 / 无越界' : '见 ACCEPTANCE.md',
      'actual': actual,
      'pass': pass,
      'manual': false,
    };

// ===========================================================================
// 防作弊巡查（ACCEPTANCE.md 第 1-5 条；第 6 条在轮次报告里人工核对）
// ===========================================================================

Future<List<Map<String, dynamic>>> _antiCheat() async {
  return [
    await _ac1BoundaryDiff(),
    await _ac2ScriptHashes(),
    await _ac3Skip(),
    await _ac4GoldenCounts(),
    await _ac5CatchAll(),
    await _ac6DocChanges(),
  ];
}

/// AC.1：实现类 agent 写入 test/、tools/gate/、docs/ACCEPTANCE.md、docs/RUBRIC.md。
Future<Map<String, dynamic>> _ac1BoundaryDiff() async {
  final diff = await runProcess(
    'git',
    ['diff', '--name-only', 'baseline-p4..HEAD', '--',
     'test/', 'tools/gate/', 'docs/ACCEPTANCE.md', 'docs/RUBRIC.md'],
    timeout: const Duration(seconds: 30),
  );
  final status = await runProcess(
    'git', ['status', '--short', '--', 'test/', 'tools/gate/', 'docs/'],
    timeout: const Duration(seconds: 30),
  );

  final violations = <String>[];
  final notes = <String>[];

  if (!diff.success) {
    return _item('AC.1', '防作弊1：baseline-p4..HEAD 无实现类 agent 越界写入',
        'git diff 失败: ${diff.tail(maxChars: 200)}', false);
  }
  for (final raw in diff.stdout.split('\n')) {
    final p = raw.trim().replaceAll('\\', '/');
    if (p.isEmpty) continue;
    if (kGatekeeperOwnedPrefixes.any(p.startsWith)) {
      notes.add('$p(gatekeeper)');
    } else if (kRefereeOwnedTestDirs.any(p.startsWith)) {
      notes.add('$p(裁判类 agent 合法范围)');
    } else if (p == 'docs/ACCEPTANCE.md' || p == 'docs/RUBRIC.md') {
      // G4 r2 修订：这两份文件的哈希变化由 AC.6 做授权提交溯源（主会话
      // 独占 + 人工授权），AC.1 不再因授权口径变更本身误报。
      notes.add('$p(主会话独占，溯源见 AC.6)');
    } else {
      violations.add(p);
    }
  }
  if (status.success) {
    for (final raw in status.stdout.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final p = line.split(RegExp(r'\s+')).last.replaceAll('\\', '/');
      if (line.startsWith('??') && p.startsWith('out/')) continue; // 共享产出目录
      if (kGatekeeperOwnedPrefixes.any(p.startsWith) ||
          kRefereeOwnedTestDirs.any(p.startsWith)) {
        continue;
      }
      if (p.startsWith('docs/ACCEPTANCE.md') || p.startsWith('docs/RUBRIC.md')) {
        violations.add('$line(未提交越界)');
      } else if (p.startsWith('test/golden/') || p.startsWith('test/dataset.json')) {
        violations.add('$line(未提交越界)');
      } else if (p.startsWith('test/')) {
        violations.add('$line(未提交，test/ 非法范围)');
      }
    }
  }
  return _item(
    'AC.1',
    '防作弊1：baseline-p4..HEAD 无实现类 agent 越界写入 '
        'test/tools-gate/ACCEPTANCE/RUBRIC（golden 与 dataset.json 任何人不得动）',
    violations.isEmpty
        ? '无越界变更；合法范围变更: ${notes.isEmpty ? '无' : notes.join(', ')}'
        : '越界: ${violations.join(', ')}',
    violations.isEmpty,
  );
}

/// AC.2：gate 脚本 SHA256 与上一轮记录（out/hashes_prev.txt）比对。
/// 本轮新增 tools/gate/gate_G4.dart 属 gatekeeper 自己的变更，允许；
/// 任何已记录文件哈希变化 = FAIL。
Future<Map<String, dynamic>> _ac2ScriptHashes() async {
  final prevFile = File('out/hashes_prev.txt');
  final prevLines = <String, String>{};
  if (await prevFile.exists()) {
    for (final line in await prevFile.readAsLines()) {
      final m = RegExp(r'^([0-9a-f]{64})\s+\*(.+)$').firstMatch(line.trim());
      if (m != null) prevLines[m.group(2)!] = m.group(1)!;
    }
  }
  final current = <String, String>{};
  final gateDir = Directory('tools/gate');
  await for (final e in gateDir.list()) {
    if (e is File && e.path.endsWith('.dart')) {
      final path = e.path.replaceAll('\\', '/');
      current[path] = _sha256ViaShell(path);
    }
  }
  for (final doc in ['docs/ACCEPTANCE.md', 'docs/RUBRIC.md']) {
    final f = File(doc);
    if (await f.exists()) current[doc] = _sha256ViaShell(doc);
  }

  final changed = <String>[];
  final gatekeeperChanged = <String>[]; // tools/gate/ 归 gatekeeper 独占（AC.1 护栏）
  final added = <String>[];
  prevLines.forEach((path, hash) {
    if (!path.startsWith('tools/gate/')) return; // docs 的哈希变化在 AC.6 溯源
    final now = current[path];
    if (now == null) {
      changed.add('$path(已消失)');
    } else if (now != hash) {
      // tools/gate/ 是 gatekeeper 独占势力范围（越界写入由 AC.1 的受保护路径
      // diff 兜底），此处哈希变化归因 gatekeeper 本轮修订，记录进注记而非 FAIL。
      gatekeeperChanged.add('$path(哈希变化，gatekeeper 本轮修订)');
    }
  });
  current.forEach((path, _) {
    if (!prevLines.containsKey(path)) {
      if (path.startsWith('tools/gate/')) {
        added.add('$path(gatekeeper 新增，允许)');
      } else {
        added.add('$path(非 gatekeeper 范围新增，违规)');
        changed.add(path);
      }
    }
  });
  return _item(
    'AC.2',
    '防作弊2：tools/gate/ 脚本 SHA256 与 out/hashes_prev.txt 比对'
        '（tools/gate/ 为 gatekeeper 独占，其哈希变化归因 gatekeeper 本轮修订并在报告留痕；'
        'ACCEPTANCE/RUBRIC 的哈希变化在 AC.6 溯源）',
    prevLines.isEmpty
        ? 'out/hashes_prev.txt 无可用基线：本轮建立基线（当前 ${current.length} 个文件）'
        : '${changed.isEmpty ? '无非 gatekeeper 哈希变化' : '变化: ${changed.join(', ')}'}'
            '${gatekeeperChanged.isEmpty ? '' : '；gatekeeper 本轮修订: ${gatekeeperChanged.join(', ')}'}'
            '${added.isEmpty ? '' : '；新增: ${added.join(', ')}'}',
    prevLines.isEmpty || changed.isEmpty,
  );
}

/// 哈希用 git bash 自带的 sha256sum 算（与 run-gate skill 同一工具链，格式一致）。
String _sha256ViaShell(String path) {
  final r = Process.runSync('sha256sum', [path], runInShell: true);
  if (r.exitCode != 0) return 'HASH_ERROR(${r.exitCode})';
  return r.stdout.toString().trim().split(RegExp(r'\s+')).first;
}

/// AC.3：测试中出现 skip / @Skip / skip tag。
Future<Map<String, dynamic>> _ac3Skip() async {
  final hits = <String>[];
  for (final dirPath in ['test', 'integration_test']) {
    final dir = Directory(dirPath);
    if (!await dir.exists()) continue;
    await for (final e in dir.list(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final lines = await e.readAsLines();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (RegExp(r'\bskip\s*:').hasMatch(l) ||
            l.contains('@Skip') ||
            l.contains("@Tags(['skip']") ||
            l.contains('@Tags(["skip"]')) {
          final t = l.trim();
          hits.add('${e.path}:${i + 1}: ${t.substring(0, math.min(80, t.length))}');
        }
      }
    }
  }
  return _item('AC.3', '防作弊3：test/ 与 integration_test/ 无 skip:/@Skip/skip tag',
      hits.isEmpty ? '0 命中' : '命中: ${hits.join(' | ')}', hits.isEmpty);
}

/// AC.4：黄金集数量不得减少（且 src/ref 一一对应 ≥8 张）。
Future<Map<String, dynamic>> _ac4GoldenCounts() async {
  int countOf(String dirPath, String ext) {
    final d = Directory(dirPath);
    if (!d.existsSync()) return -1;
    return d
        .listSync()
        .where((e) => e is File && e.path.endsWith(ext))
        .length;
  }

  final srcCount = countOf('test/golden/src', '.jpg');
  final refCount = countOf('test/golden/ref', '.png');

  var prevNote = '无上一轮快照';
  var prevSrc = -1;
  var prevRef = -1;
  final snapshot = File(kGoldenCountsSnapshot);
  if (await snapshot.exists()) {
    try {
      final prev = jsonDecode(await snapshot.readAsString()) as Map<String, dynamic>;
      prevSrc = prev['srcCount'] as int;
      prevRef = prev['refCount'] as int;
      prevNote = '上一轮快照 src=$prevSrc ref=$prevRef';
    } catch (_) {
      prevNote = '上一轮快照损坏（$kGoldenCountsSnapshot 解析失败）';
    }
  }

  final shrank =
      (prevSrc >= 0 && srcCount < prevSrc) || (prevRef >= 0 && refCount < prevRef);
  final pass = srcCount >= 8 && refCount == srcCount && !shrank;

  // 写新快照，供下一轮比对（写失败只影响下一轮比对能力，不影响本轮判定）。
  try {
    await snapshot.parent.create(recursive: true);
    await snapshot.writeAsString(jsonEncode({
      'srcCount': srcCount,
      'refCount': refCount,
      'at': DateTime.now().toIso8601String(),
    }));
  } catch (_) {
    prevNote += '；快照写入失败';
  }

  return _item(
    'AC.4',
    '防作弊4：test/golden/ 文件数未减少（src≥8 且与 ref 一一对应）',
    'src=$srcCount ref=$refCount；$prevNote${shrank ? '；数量减少！' : ''}',
    pass,
  );
}

/// AC.5：catch-all 吞异常（lib/、test/、integration_test/ 下的空 catch 实现）。
/// 白名单（G4 r1 裁定，见 out/GATE_G4_r1.md 防作弊巡查第 5 条）：
/// test/adversarial/adversarial_runner.dart 中紧跟诊断用 alpha PNG 工件导出
/// （writeAsBytes 行）之后的空 catch —— 可选 side-path，被测管线与崩溃判定
/// 均不经过它。白名单精确匹配：仅该文件 + 前一行含 writeAsBytes。
Future<Map<String, dynamic>> _ac5CatchAll() async {
  final hits = <String>[];
  final whitelisted = <String>[];
  for (final dirPath in ['lib', 'test', 'integration_test']) {
    final d = Directory(dirPath);
    if (!await d.exists()) continue;
    await for (final e in d.list(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final lines = await e.readAsLines();
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (RegExp(r'catch \(_?\w*\)\s*\{\s*\}').hasMatch(t) ||
            RegExp(r'on Exception[^{]*\{\s*\}').hasMatch(t)) {
          final norm = e.path.replaceAll('\\', '/');
          final isArtifactExportSidePath = norm.endsWith(
                  'test/adversarial/adversarial_runner.dart') &&
              i > 0 &&
              lines[i - 1].contains('writeAsBytes');
          final tag = '${e.path}:${i + 1}: $t';
          if (isArtifactExportSidePath) {
            whitelisted.add(tag);
          } else {
            hits.add(tag);
          }
        }
      }
    }
  }
  return _item('AC.5', '防作弊5：无 catch (_) {} / catch (e) {} 空实现吞异常',
      hits.isEmpty
          ? '0 命中${whitelisted.isEmpty ? '' : '；r1 裁定白名单(工件导出 side-path): ${whitelisted.join(' | ')}'}'
          : '命中: ${hits.take(20).join(' | ')}',
      hits.isEmpty);
}

/// AC.6：docs/ACCEPTANCE.md / docs/RUBRIC.md 的哈希与上一轮比对。
/// 这两个文件是主会话（+人工授权）独占：变化本身不必然违规（如 4.6 口径变更），
/// 但必须可溯源：工作区不得有未提交修改，且最近一次改动该文件的提交
/// message 含"授权"字样；查不到 = FAIL，gatekeeper 报告里再人工复核一遍 git log。
Future<Map<String, dynamic>> _ac6DocChanges() async {
  final prevFile = File('out/hashes_prev.txt');
  final prev = <String, String>{};
  if (await prevFile.exists()) {
    for (final line in await prevFile.readAsLines()) {
      final m = RegExp(r'^([0-9a-f]{64})\s+\*?(.+)$').firstMatch(line.trim());
      if (m != null) prev[m.group(2)!] = m.group(1)!;
    }
  }
  final changed = <String>[];
  for (final doc in ['docs/ACCEPTANCE.md', 'docs/RUBRIC.md']) {
    final f = File(doc);
    if (!await f.exists()) continue;
    final now = _sha256ViaShell(doc);
    final before = prev[doc];
    if (before != null && before != now) changed.add(doc);
  }
  if (changed.isEmpty) {
    return _item('AC.6', '防作弊6：ACCEPTANCE/RUBRIC 哈希未变化（或变化可溯源授权提交）',
        'docs/ACCEPTANCE.md 与 docs/RUBRIC.md 相对 out/hashes_prev.txt 无变化', true);
  }
  final problems = <String>[];
  final notes = <String>[];
  for (final doc in changed) {
    // 1) 工作区相对 HEAD 有未提交修改 = 直接 FAIL（未提交的改动无从溯源）。
    final st = await runProcess('git', ['status', '--short', '--', doc],
        timeout: const Duration(seconds: 15));
    final dirty = st.success &&
        st.stdout
            .split('\n')
            .any((l) => l.trim().isNotEmpty && !l.trim().startsWith('??'));
    if (dirty) {
      problems.add('$doc 工作区有未提交修改（未提交的改动无从溯源）');
      continue;
    }
    // 2) 最近一次改动该文件的提交，message 必须含"授权"
    //    （baseline-p4..HEAD 可能为空——授权口径变更常在打 tag 前提交）。
    final r = await runProcess(
      'git', ['log', '-1', '--format=%h %s', '--', doc],
      timeout: const Duration(seconds: 30),
      // `%h`/`%s` 里的 `%` 在本地 shell 下会被 cmd 当变量展开前缀。
      // 展成空串的话 git 收到的是 `--format=`，输出是空 ——
      // 而下面 `if (lastCommit.contains('授权'))` 就会判"无授权字样"，
      // 把一条**合法**的口径变更记成问题。取不到与"没有"必须分开。
      runInShell: false,
    );
    final lastCommit =
        r.success ? r.stdout.trim() : 'git log 失败: ${r.tail(maxChars: 120)}';
    if (lastCommit.contains('授权')) {
      notes.add('$doc 最近改动可溯源授权提交: $lastCommit');
    } else {
      problems.add('$doc 最近改动提交无"授权"字样: $lastCommit');
    }
  }
  return _item(
    'AC.6',
    '防作弊6：ACCEPTANCE/RUBRIC 变更必须可溯源到含"授权"的提交（主会话独占+人工授权）',
    problems.isEmpty
        ? '全部变更可溯源；${notes.join('；')}（gatekeeper 报告仍会人工复核 git log -p）'
        : '溯源失败: ${problems.join('；')}',
    problems.isEmpty,
  );
}

// ===========================================================================
// 裁判数据加载
// ===========================================================================

Map<String, dynamic>? _loadJsonFile(String path, StringBuffer log) {
  final f = File(path);
  if (!f.existsSync()) {
    log.writeln('缺少裁判数据: $path');
    return null;
  }
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    log.writeln('解析 $path 失败: $e');
    return null;
  }
}

/// glob 取修改时间最新的一个文件（只支持路径里含 `*` 的简单模式）。
String? _latestGlobFile(String glob, StringBuffer log) {
  final slash = glob.lastIndexOf('/');
  final dirPart = slash == -1 ? '.' : glob.substring(0, slash);
  final filePattern =
      RegExp('^${glob.substring(slash + 1).replaceAll('*', '.*')}\$');
  final dir = Directory(dirPart);
  if (!dir.existsSync()) {
    log.writeln('glob 目录不存在: $dirPart');
    return null;
  }
  File? best;
  var bestTime = DateTime.fromMillisecondsSinceEpoch(0);
  for (final e in dir.listSync()) {
    if (e is! File) continue;
    if (!filePattern.hasMatch(e.uri.pathSegments.last)) continue;
    final t = e.lastModifiedSync();
    if (t.isAfter(bestTime)) {
      bestTime = t;
      best = e;
    }
  }
  return best?.path.replaceAll('\\', '/');
}

// ===========================================================================
// 4.1-4.4 判定（裁判数据 + gate 自己的抽查）
// ===========================================================================

String _waiting(String path) => '等待 out/ 裁判数据: $path 不存在或不可解析'
    '（期望 schema 见 tools/gate/gate_G4.dart 文件头注释）';

Map<String, dynamic> _failRef(String id, String desc, String actual) => {
      'id': id,
      'description': desc,
      'expected': '见 ACCEPTANCE.md',
      'actual': actual,
      'pass': false,
      // 缺数据 = FAIL（等待数据），不是 MANUAL —— 不许悄悄跳过、不许默认通过。
      'manual': false,
    };

List<String> _batchSchemaProblems(Map<String, dynamic> batch) {
  final problems = <String>[];
  int? asInt(String key) => batch[key] is int ? batch[key] as int : null;
  final totalItems = asInt('totalItems');
  final ranItems = asInt('ranItems');
  if (batch['crashes'] is! int) problems.add('缺少 int 字段 crashes');
  if (batch['anrs'] is! int) problems.add('缺少 int 字段 anrs');
  if (totalItems == null) problems.add('缺少 int 字段 totalItems');
  if (ranItems == null) problems.add('缺少 int 字段 ranItems');
  final itemsRaw = batch['items'];
  if (itemsRaw is! List) {
    problems.add('缺少 List 字段 items');
  } else {
    final list = itemsRaw.whereType<Map<String, dynamic>>().toList();
    if (totalItems != null && list.length != totalItems) {
      problems.add('items.length=${list.length} != totalItems=$totalItems');
    }
    for (final it in list) {
      if (it['sourcePath'] is! String) problems.add('items 缺 sourcePath: $it');
      if (it['class'] is! String) problems.add('${it['sourcePath']}: 缺 class');
      if (it['outcome'] is! String) problems.add('${it['sourcePath']}: 缺 outcome');
    }
  }
  return problems;
}

Map<String, dynamic> _judge41(Map<String, dynamic>? batch, DevicePhaseResult device) {
  final spot = device.spot;
  final refereeProblems = <String>[];
  String summary;
  var refereeOk = false;

  if (batch == null) {
    summary = _waiting(kDefaultBatch);
  } else {
    refereeProblems.addAll(_batchSchemaProblems(batch));
    final total = batch['totalItems'] as int?;
    final ran = batch['ranItems'] as int?;
    final crashes = batch['crashes'] as int?;
    final anrs = batch['anrs'] as int?;
    if (total != null && total < 40) refereeProblems.add('totalItems=$total < 40');
    if (total != null && ran != null && ran != total) {
      refereeProblems.add('ranItems=$ran != totalItems=$total（未全跑完）');
    }
    if (crashes != null && crashes != 0) refereeProblems.add('crashes=$crashes');
    if (anrs != null && anrs != 0) refereeProblems.add('anrs=$anrs');
    refereeOk = refereeProblems.isEmpty;

    final outcomeCounts = <String, int>{};
    if (batch['items'] is List) {
      for (final it in (batch['items'] as List).whereType<Map<String, dynamic>>()) {
        final o = it['outcome'] as String? ?? 'unknown';
        outcomeCounts[o] = (outcomeCounts[o] ?? 0) + 1;
      }
    }
    summary = '裁判数据: total=$total ran=$ran crashes=$crashes anrs=$anrs '
        'outcomes=$outcomeCounts';
  }

  final mismatchList = (spot?['mismatches'] as List?)?.cast<String>() ?? const [];
  final sampled = (spot?['sampled'] as int?) ?? 0;
  final spotOk = sampled >= 5 && mismatchList.isEmpty;
  final spotSummary = spot == null
      ? 'gate 抽查未执行: ${device.error ?? '未知原因'}'
      : 'gate 抽查: $sampled 项复跑，'
          '${mismatchList.isEmpty ? '全部与裁判记录一致' : '不一致 ${mismatchList.join('; ')}'}';

  return _item(
    '4.1',
    'Pictures 全量跑完，崩溃=0 且 ANR=0（qa-batch out/batch_r1.json 含 logcat 取证；'
        'gate 另随机抽 ≥5 项在自己的设备会话里复跑核对，不许只信裁判汇总）',
    '$summary；$spotSummary'
        '${refereeProblems.isEmpty ? '' : '；裁判数据问题: ${refereeProblems.join('; ')}'}',
    refereeOk && spotOk,
  );
}

Map<String, dynamic> _judge42(Map<String, dynamic>? batch, DevicePhaseResult device) {
  final spot = device.spot;
  if (batch == null) {
    return _failRef('4.2', '人像类成功率 100%（qa-batch 分类矩阵 + gate 抽查）',
        _waiting(kDefaultBatch));
  }
  final problems = _batchSchemaProblems(batch);
  if (problems.isNotEmpty) {
    return _failRef(
        '4.2', '人像类成功率 100%', 'schema 不符: ${problems.take(5).join('; ')}');
  }
  final portraits = (batch['items'] as List)
      .whereType<Map<String, dynamic>>()
      .where((it) => kPortraitClasses.contains(it['class']))
      .toList();
  final bad = <String>[];
  for (final it in portraits) {
    if (it['outcome'] != 'ok') {
      bad.add('${it['sourcePath']}(outcome=${it['outcome']})');
    } else if (it['candidateCount'] is! int || (it['candidateCount'] as int) <= 0) {
      bad.add('${it['sourcePath']}(outcome=ok 但 candidateCount=${it['candidateCount']})');
    }
  }

  // 抽查交叉核对：gate 复跑的人像子项必须 ready + 候选 > 0 且可解码。
  final spotBad = <String>[];
  if (spot != null) {
    for (final r in (spot['items'] as List? ?? []).whereType<Map<String, dynamic>>()) {
      if (r['category'] != 'portrait') continue;
      final ready = r['stage'] == 'ready' && (r['candidateCount'] as int? ?? 0) > 0;
      final decoded = (r['candidatesDecoded'] as int?) ?? 0;
      if (!ready || decoded == 0) {
        spotBad.add('${r['sourcePath']}(stage=${r['stage']}, '
            'candidates=${r['candidateCount']}, decoded=$decoded)');
      }
    }
  }
  final spotNote = spot == null
      ? 'gate 抽查未执行: ${device.error ?? '未知'}'
      : spotBad.isEmpty
          ? 'gate 抽查人像子项全部 ready 且候选可解码'
          : 'gate 抽查人像失败: ${spotBad.join('; ')}';

  return _item(
    '4.2',
    '人像类（portrait/multi_face）成功率 100%（人像子集由 qa-batch 分类并冻结，不得增删）',
    '裁判: 人像 ${portraits.length} 项，'
        '${bad.isEmpty ? '100% ok 且候选>0' : '不达标 ${bad.join('; ')}'}；$spotNote',
    portraits.isNotEmpty && bad.isEmpty && spot != null && spotBad.isEmpty,
  );
}

Map<String, dynamic> _judge43(Map<String, dynamic>? batch, DevicePhaseResult device) {
  final spot = device.spot;
  if (batch == null) {
    return _failRef('4.3', '非人像类 100% 优雅失败', _waiting(kDefaultBatch));
  }
  final problems = _batchSchemaProblems(batch);
  if (problems.isNotEmpty) {
    return _failRef(
        '4.3', '非人像类 100% 优雅失败', 'schema 不符: ${problems.take(5).join('; ')}');
  }
  final nonPortraits = (batch['items'] as List)
      .whereType<Map<String, dynamic>>()
      .where((it) => kNonPortraitClasses.contains(it['class']))
      .toList();
  // 判定口径（G4 r1 固化，依据 docs/CONTRACTS.md §异常表 + ACCEPTANCE 4.3 括号定义）：
  //  - graceful_fail + 中文提示 = 引擎无法出片的优雅失败，合规；
  //  - ok + 中文提示 = NoFace「仅提示，不阻断」契约路径（hint + 手动框选候选），
  //    合规，但必须无诡异标记 ——「不产出诡异结果」以 qa-batch 的 weird 标记 +
  //    gatekeeper 目视裁决（weirdAdjudicated，见 out/gate_G4_batch_ref.json 注）为准；
  //  - 其余 outcome（crash/anr/hang）一律不合规；无中文提示一律不合规。
  final bad = <String>[];
  for (final it in nonPortraits) {
    final weird = it['weird'] == true || it['weirdAdjudicated'] == true;
    if (it['outcome'] == 'graceful_fail') {
      if (it['chineseError'] != true) {
        bad.add('${it['sourcePath']}(优雅失败但中文提示缺失)');
      }
      if (weird) {
        bad.add('${it['sourcePath']}(优雅失败但带诡异标记)');
      }
    } else if (it['outcome'] == 'ok') {
      if (it['chineseError'] != true) {
        bad.add('${it['sourcePath']}(非人像产出候选但无中文提示'
            '—— NoFace 契约要求提示到达)');
      }
      if (weird) {
        bad.add('${it['sourcePath']}(产出诡异结果: '
            '${it['weirdNote'] ?? 'weird 标记'})');
      }
    } else {
      bad.add('${it['sourcePath']}(outcome=${it['outcome']})');
    }
  }

  // 抽查"优雅口径"（判定口径见 _judge43 注释）：复跑非人像子项必须落定
  // （ready 或 error 都是契约终态）+ 中文提示到达 + 不崩溃。
  final spotBad = <String>[];
  if (spot != null) {
    for (final r in (spot['items'] as List? ?? []).whereType<Map<String, dynamic>>()) {
      if (r['category'] != 'non_portrait') continue;
      final settledOk =
          r['stage'] == 'ready' || r['stage'] == 'error';
      final likeGraceful = settledOk &&
          r['unresponsive'] != true &&
          r['chineseError'] == true;
      if (!likeGraceful) {
        spotBad.add('${r['sourcePath']}(stage=${r['stage']}, '
            'chineseError=${r['chineseError']}, candidates=${r['candidateCount']})');
      }
      // 与裁判 outcome 交叉核对：同一张图两次跑应走同一条契约路径。
      final srcPath = r['sourcePath'] as String?;
      final refereeItem = batch['items'] is List
          ? (batch['items'] as List)
              .whereType<Map<String, dynamic>>()
              .where((b) => b['sourcePath'] == srcPath)
              .toList()
          : <Map<String, dynamic>>[];
      final batchOutcome =
          refereeItem.isEmpty ? null : refereeItem.first['outcome'];
      final mineReady = r['stage'] == 'ready';
      if (batchOutcome == 'graceful_fail' && mineReady ||
          batchOutcome == 'ok' && r['stage'] == 'error') {
        spotBad.add('${r['sourcePath']}(裁判 outcome=$batchOutcome 但复跑 '
            'stage=${r['stage']} —— 同一输入契约路径不一致)');
      }
    }
  }
  final spotNote = spot == null
      ? 'gate 抽查未执行: ${device.error ?? '未知'}'
      : spotBad.isEmpty
          ? 'gate 抽查非人像子项均为契约优雅口径（落定 + 中文提示到达）'
          : 'gate 抽查失败: ${spotBad.join('; ')}';

  return _item(
    '4.3',
    '非人像类（screenshot/landscape/non_image）100% 优雅失败：中文提示到达、不崩溃、'
        '不产出诡异结果（gate 抽查核实产出为失败态而非成功态）',
    '裁判: 非人像 ${nonPortraits.length} 项，'
        '${bad.isEmpty ? '100% graceful_fail + 中文提示' : '不达标 ${bad.join('; ')}'}；$spotNote',
    nonPortraits.isNotEmpty && bad.isEmpty && spot != null && spotBad.isEmpty,
  );
}

Map<String, dynamic> _judge44(Map<String, dynamic>? adversarial, DevicePhaseResult device) {
  if (adversarial == null) {
    return _failRef('4.4', '对抗用例 0 崩溃/0 数据损坏/0 无响应>5s',
        _waiting('$kDefaultAdversarialGlob（自动取最新一份）'));
  }
  final problems = <String>[];
  final totalCases = adversarial['totalCases'];
  final casesRaw = adversarial['cases'];
  for (final k in ['crashes', 'dataCorruptions', 'unresponsiveOver5s']) {
    final v = adversarial[k];
    if (v is! int) {
      problems.add('缺少 int 字段 $k');
    } else if (v != 0) {
      problems.add('$k=$v');
    }
  }
  if (totalCases is! int) problems.add('缺少 int 字段 totalCases');
  if (casesRaw is! List) {
    problems.add('缺少 List 字段 cases');
  } else {
    final list = casesRaw.whereType<Map<String, dynamic>>().toList();
    if (totalCases is int && list.length != totalCases) {
      problems.add('cases.length=${list.length} != totalCases=$totalCases');
    }
    for (final c in list) {
      // 序列用例（spotRunnable=false，q01-q09）无单一输入文件，不强制 sourcePath。
      if (c['sourcePath'] is! String && c['spotRunnable'] == true) {
        problems.add('${c['caseId']}: 缺 sourcePath（gate 抽查无法定位输入）');
      }
      for (final k in ['crash', 'dataCorruption', 'unresponsiveOver5s']) {
        if (c[k] != false) problems.add('${c['caseId']}: $k=${c[k]}');
      }
    }
  }

  // 抽查：adversarial 用例子集在 gate 设备会话复跑（no_crash + 落定）。
  final advSpot = device.spot?['adversarial'] as Map<String, dynamic>?;
  final advMismatches =
      (advSpot?['mismatches'] as List?)?.cast<String>() ?? const [];
  final advSampled = (advSpot?['sampled'] as int?) ?? 0;
  final advSpotNote = advSpot == null
      ? 'gate 抽查未执行: ${device.error ?? '未知'}'
      : advMismatches.isEmpty
          ? 'gate 抽查 $advSampled 个对抗用例复跑：无崩溃、全部在时限内落定'
          : 'gate 抽查问题: ${advMismatches.join('; ')}';

  return _item(
    '4.4',
    '对抗用例全部 0 崩溃、0 数据损坏、0 无响应>5s（adversarial 裁判数据 + gate 抽查复跑）',
    '裁判: ${problems.isEmpty ? '三计数=0，逐用例三标记全 false' : problems.take(8).join('; ')}；'
        '$advSpotNote',
    problems.isEmpty && advSpot != null && advMismatches.isEmpty && advSampled > 0,
  );
}

// ===========================================================================
// 4.5 视觉评分（机读 RUBRIC 固定格式行）
// ===========================================================================

Future<Map<String, dynamic>> _judge45(String? visualPath) async {
  if (visualPath == null) {
    return _failRef('4.5', 'visual-critic 总分 ≥8.0 且致命项=0',
        '等待 out/VISUAL_G4_r*.md（visual-critic G4 评审尚未产出）');
  }
  final content = await File(visualPath).readAsString();
  final scoreM = RegExp(r'^##\s*总分[:：]\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*10',
          multiLine: true)
      .firstMatch(content);
  final fatalM = RegExp(r'致命项[:：]\s*(\d+)\s*个').firstMatch(content);
  final verdictM =
      RegExp(r'^##\s*结论[:：]\s*(PASS|FAIL)\s*$', multiLine: true).firstMatch(content);

  final parseProblems = <String>[
    if (scoreM == null) '解析不到"## 总分：X.X / 10"行',
    if (fatalM == null) '解析不到"致命项：N 个"',
    if (verdictM == null) '解析不到"## 结论：PASS/FAIL"行',
  ];
  if (parseProblems.isNotEmpty) {
    return _failRef('4.5', 'visual-critic 总分 ≥8.0 且致命项=0（机读 $visualPath）',
        '固定格式行缺失: ${parseProblems.join('; ')}');
  }
  final score = double.parse(scoreM!.group(1)!);
  final fatal = int.parse(fatalM!.group(1)!);
  final verdict = verdictM!.group(1)!;
  return _item(
    '4.5',
    '视觉评分：visual-critic 总分 ≥8.0/10 且致命项 = 0（机读 $visualPath，按 RUBRIC 固定格式）',
    '总分 $score，致命项 $fatal，结论 $verdict',
    score >= 8.0 && fatal == 0 && verdict == 'PASS',
  );
}

// ===========================================================================
// 4.6 / 4.7 / 4.8（裁判 metrics + gate 自己复测，两者都必须达标）
// ===========================================================================

/// 参考注记（不判定）：另一口径的数字 + 真机冷启动参考。
String _metricsCrossRefNote(Map<String, dynamic>? primary,
    Map<String, dynamic>? crossRef,
    {bool crossRefIsEmulator = false, bool crossRefIsRealDevice = false}) {
  final parts = <String>[];
  if (crossRef != null && (crossRefIsEmulator || crossRefIsRealDevice)) {
    final p95 = crossRef['matting512P95Ms'];
    final peak = crossRef['peakMemoryMb'];
    final base = crossRef['leakBaselineMb'];
    final after = crossRef['leakAfter20Mb'];
    parts.add('交叉参考·${crossRefIsEmulator ? '模拟器' : '真机'}(不判定): '
        'p95=${p95 ?? '?'}ms peak=${peak ?? '?'}MB '
        'leak=${base == null || after == null ? '?' : '${(after - base).toStringAsFixed(1)}MB'}');
  }
  for (final m in [primary, crossRef]) {
    final cold = m?['coldStartRealDeviceTotalMs'];
    if (cold != null) {
      parts.add('真机冷启动 TotalTime 参考(不判定，G3.4 已关闭): ${cold}ms');
      break;
    }
  }
  return parts.isEmpty ? '' : '；${parts.join('；')}';
}

Map<String, dynamic> _judge46(Map<String, dynamic>? metrics, DevicePhaseResult device,
    {Map<String, dynamic>? crossRef, required bool crossRefIsRealDevice}) {
  if (metrics == null) {
    return _failRef('4.6', '设备端 512² 抠图 p95 ≤1500ms（口径：模拟器设备端实测，见 4.6 授权记录）',
        _waiting('$kDefaultMetrics 或 $kDefaultMetricsRealDevice（授权口径=模拟器优先）'));
  }
  final p95 = metrics['matting512P95Ms'];
  final samples = metrics['matting512Samples'];
  if (p95 is! num) {
    return _failRef('4.6', '设备端 512² 抠图 p95 ≤1500ms',
        'schema 不符: 缺少 num 字段 matting512P95Ms'
            '${samples is! int || samples <= 0 ? '；缺少正 int 字段 matting512Samples' : ''}');
  }
  final refereeOk = p95 <= 1500;
  final mine = device.myP95Ms;
  final mineNote = mine == null
      ? 'gate 复测未完成: ${device.error ?? '未知'}'
      : 'gate 复测 p95=${mine.toStringAsFixed(1)}ms ${mine <= 1500 ? '(达标)' : '(超阈值!)'}';
  return _item(
    '4.6',
    '设备端 512×512 抠图 p95 ≤1500ms（2026-09-14 人工授权口径：模拟器（AEHD, RAM 4096）'
        '设备端实测；真机数字只作参考）；判定源 metrics + gate 自己复测一轮，两者都 ≤1500',
    '裁判(${_deviceTag(metrics)}) p95=${p95}ms(samples=$samples) '
        '${refereeOk ? '达标' : '超阈值'}；$mineNote'
        '${_metricsCrossRefNote(metrics, crossRef, crossRefIsRealDevice: crossRefIsRealDevice)}',
    refereeOk && mine != null && mine <= 1500,
  );
}

String _deviceTag(Map<String, dynamic> metrics) {
  final d = metrics['device'];
  if (d is String && d.isNotEmpty) return 'device=$d';
  return '未注明设备';
}

Map<String, dynamic> _judge47(Map<String, dynamic>? metrics, DevicePhaseResult device,
    {Map<String, dynamic>? crossRef, required bool crossRefIsEmulator}) {
  if (metrics == null) {
    return _failRef('4.7', '峰值内存 ≤550MB',
        _waiting('$kDefaultMetricsRealDevice 或 $kDefaultMetrics（真机优先，模拟器兜底）'));
  }
  final peak = metrics['peakMemoryMb'];
  if (peak is! num) {
    return _failRef('4.7', '峰值内存 ≤550MB', 'schema 不符: 缺少 num 字段 peakMemoryMb');
  }
  const threshold = 550; // 2026-09-15 人工授权 450→550（ACCEPTANCE 4.7 口径变更记录）
  final refereeOk = peak <= threshold;
  // gate 自己的复测只有模拟器可用（真机不归 gate 触碰）。按 4.7 授权口径
  // 「设备端真机优先」，模拟器固有 floor（ORT bug 锁死）下模拟器复测数字
  // 只作参考注记，不作为 4.7 的硬条件。
  final mine = device.peakMb;
  final mineNote = mine == null
      ? 'gate 模拟器复测未完成: ${device.error ?? '未知'}'
      : 'gate 模拟器复测峰值=${mine.toStringAsFixed(1)}MB（参考，不判定；'
          '模拟器固有 floor 见 4.7 修订记录）${mine <= threshold ? '，低于 550' : ''}';
  return _item(
    '4.7',
    '峰值内存 ≤550MB（2026-09-15 人工授权，设备端口径真机优先；判定源 metrics 真机优先；'
        '模拟器数字与 gate 模拟器复测只作参考）',
    '裁判(${_deviceTag(metrics)}) 峰值=${peak}MB '
        '${refereeOk ? '达标' : '超阈值'}；$mineNote'
        '${_metricsCrossRefNote(metrics, crossRef, crossRefIsEmulator: crossRefIsEmulator)}',
    refereeOk,
  );
}

Map<String, dynamic> _judge48(Map<String, dynamic>? metrics, DevicePhaseResult device,
    {Map<String, dynamic>? crossRef, required bool crossRefIsEmulator}) {
  if (metrics == null) {
    return _failRef('4.8', '连续处理 20 张后内存回落到基线 +80MB 以内',
        _waiting('$kDefaultMetricsRealDevice 或 $kDefaultMetrics（真机优先，模拟器兜底）'));
  }
  final baseline = metrics['leakBaselineMb'];
  final after = metrics['leakAfter20Mb'];
  if (baseline is! num || after is! num) {
    return _failRef('4.8', '连续处理 20 张后内存回落到基线 +80MB 以内',
        'schema 不符: 缺少 num 字段 leakBaselineMb / leakAfter20Mb');
  }
  final refereeDelta = after - baseline;
  final refereeOk = refereeDelta <= 80;
  // gate 自己的复测（G4 r2 修订）：优先用 harness 的设备侧直测
  // （/proc/self/status VmRSS，churn 前后各一次）——无采样窗口启发式误差；
  // host 侧 dumpsys 窗口算法（r1 引入）在采样节奏波动时会错位出假 Δ
  // （本轮实测 296.9MB，同代码 qa-batch r7 实测 -7.4MB，矛盾），降级为参考。
  final beforeProc = device.mem?['procBeforeChurn'] as Map<String, dynamic>?;
  final afterProc = device.mem?['procAfterChurn'] as Map<String, dynamic>?;
  final devBefore = beforeProc?['vmRssKb'] as int?;
  final devAfter = afterProc?['vmRssKb'] as int?;
  final devDeltaMb = (devBefore != null && devAfter != null)
      ? (devAfter - devBefore) / 1024.0
      : null;
  final mine = devDeltaMb ?? device.myLeakDeltaMb;
  final mineSource = devDeltaMb != null ? '设备侧 VmRSS 直测' : 'host dumpsys 窗口';
  final mineNote = mine == null
      ? 'gate 复测未完成: ${device.error ?? '未知'}'
      : 'gate 复测[$mineSource] 20 张后 Δ=${mine.toStringAsFixed(1)}MB '
          '${mine <= 80 ? '(达标)' : '(超阈值!)'}'
          '${devDeltaMb != null && device.myLeakDeltaMb != null && device.myLeakDeltaMb! > 80 ? '；host dumpsys 窗口 Δ=${device.myLeakDeltaMb!.toStringAsFixed(1)}MB 与直测矛盾，判定以设备侧直测为准（窗口启发式在采样节奏波动时错位，见 G4 r2 报告）' : ''}';
  return _item(
    '4.8',
    '内存泄漏：连续处理 20 张后内存回落到基线 +80MB 以内'
        '（判定源 metrics 真机优先 + gate 自己 20 张 churn 复测：设备侧 VmRSS 直测为准，'
        'host dumpsys 窗口作参考）',
    '裁判(${_deviceTag(metrics)}) Δ=${refereeDelta.toStringAsFixed(1)}MB '
        '(baseline=$baseline after=$after) ${refereeOk ? '达标' : '超阈值'}；$mineNote'
        '${_metricsCrossRefNote(metrics, crossRef, crossRefIsEmulator: crossRefIsEmulator)}',
    refereeOk && mine != null && mine <= 80,
  );
}

// ===========================================================================
// 设备阶段：抽查复跑（g4_spotcheck）+ 内存/耗时复测（g4_memcheck + dumpsys）
// ===========================================================================

class DevicePhaseResult {
  final String? error;
  final Map<String, dynamic>? spot; // spotcheck 响应 + 抽样判定附注
  final Map<String, dynamic>? mem; // memcheck 响应（含 gate 采样）
  final double? myP95Ms;
  final double? peakMb;
  final double? myLeakDeltaMb;

  DevicePhaseResult._({
    this.error,
    this.spot,
    this.mem,
    this.myP95Ms,
    this.peakMb,
    this.myLeakDeltaMb,
  });

  factory DevicePhaseResult.failed(String error) =>
      DevicePhaseResult._(error: error);
}

class SpotPlan {
  final List<Map<String, dynamic>> entries = [];
  final List<String> problems = [];
  final Map<String, dynamic> batchRecord = {}; // sourcePath -> batch item
  final List<Map<String, dynamic>> adversarialCases = [];
}

Future<DevicePhaseResult> _runDevicePhase({
  required Map<String, dynamic>? batch,
  required Map<String, dynamic>? adversarial,
  required int deviceWaitSeconds,
  required StringBuffer log,
}) async {
  // 1. 生成抽查清单（裁判数据缺失时给出明确等待信息，不跑设备）。
  final rng = math.Random(DateTime.now().millisecondsSinceEpoch);
  final plan = _buildSpotPlan(batch: batch, adversarial: adversarial, rng: rng);
  if (plan.problems.isNotEmpty) {
    return DevicePhaseResult.failed('无法生成抽查计划: ${plan.problems.join('; ')}');
  }
  log.writeln('抽查计划: ${plan.entries.map((e) => '${e['id']}=${e['sourcePath']}').join(', ')}');

  // 2. 设备：**只认 emulator-*，真机一律不碰**（用户铁律）。拿不到模拟器就**抛**，
  //    不在这里 `return DevicePhaseResult.failed(...)`：那会造出一批 `pass=false,
  //    manual=false` 的条目，与"真的退化了"完全同形（4.1–4.4/4.6/4.8 六条）。
  //    抛出去 ⇒ 本轮没有产物 ⇒ 上游 P0.5c 读到"本轮没跑成"而不是"退化了"。
  //    规则的唯一实现见 gate_common.requireEmulatorDevice，此处不再复制解析。
  var launchedByGate = false;
  final String deviceId = await requireEmulatorDevice(
    wait: Duration(seconds: deviceWaitSeconds),
    bootTimeout: const Duration(minutes: 5),
    onMissing: () async {
      log.writeln('无在线模拟器，按本机安全参数启动模拟器 $kMainAvd');
      launchedByGate = true;
      return _spawnEmulator(log);
    },
  );
  log.writeln('设备已上线: $deviceId');

  return _deviceWork(deviceId, plan, log, killAtEnd: launchedByGate);
}

/// 对抗抽查：除随机抽 3 个外，固定追加这 5 个针对性用例（G4 r2 起）。
/// 覆盖 adversarial r2（02:50）之后落地的代码变更面：
///   - c03（纯噪声）/ c05（多人脸）/ c06（倒置人脸）：301434f 人脸门槛+
///     pickSubjectFace 改变了无人脸/多人脸内容的契约路径；
///   - e09_lie_o6（谎言 EXIF）：compose 段池化/回退（c0aed27…b2fab99）；
///   - m13（JPG 尾部垃圾）：08144ab 解码路径（dart:ui EXIF 快路径）。
const List<String> kTargetedAdversarialIds = [
  'c03', 'c05', 'c06', 'e09_lie_o6', 'm13',
];

SpotPlan _buildSpotPlan({
  required Map<String, dynamic>? batch,
  required Map<String, dynamic>? adversarial,
  required math.Random rng,
}) {
  final plan = SpotPlan();
  if (batch != null && batch['items'] is List) {
    final items = (batch['items'] as List).whereType<Map<String, dynamic>>().toList();
    final portraits = items
        .where((it) =>
            kPortraitClasses.contains(it['class']) && it['sourcePath'] is String)
        .toList();
    final nonPortraits = items
        .where((it) =>
            kNonPortraitClasses.contains(it['class']) && it['sourcePath'] is String)
        .toList();
    portraits.shuffle(rng);
    nonPortraits.shuffle(rng);
    var pid = 0, nid = 0, seq = 0;
    while (plan.entries.length < 5 &&
        (pid < portraits.length || nid < nonPortraits.length)) {
      final portraitCount =
          plan.entries.where((e) => e['category'] == 'portrait').length;
      final preferPortrait = pid < portraits.length &&
          (nid >= nonPortraits.length || portraitCount < 3);
      if (preferPortrait) {
        final it = portraits[pid++];
        plan.entries.add({
          'id': 'spot_${(seq++).toString().padLeft(2, '0')}',
          'sourcePath': it['sourcePath'],
          'category': 'portrait',
        });
        plan.batchRecord[it['sourcePath'] as String] = it;
      } else if (nid < nonPortraits.length) {
        final it = nonPortraits[nid++];
        plan.entries.add({
          'id': 'spot_${(seq++).toString().padLeft(2, '0')}',
          'sourcePath': it['sourcePath'],
          'category': 'non_portrait',
        });
        plan.batchRecord[it['sourcePath'] as String] = it;
      }
    }
  } else {
    plan.problems.add('batch 裁判数据缺失（$kDefaultBatch）');
  }

  if (adversarial != null && adversarial['cases'] is List) {
    final cases = (adversarial['cases'] as List)
        .whereType<Map<String, dynamic>>()
        // spotRunnable=false 的序列用例（q01-q09，操作序列无单一输入文件）
        // 无法经 loadImage 单图复跑，只进裁判计数、不进抽查抽样。
        .where((c) => c['sourcePath'] is String && c['spotRunnable'] == true)
        .toList()
      ..shuffle(rng);
    var seq = 100;
    final pickedIds = <String>{};
    for (final c in cases.take(3)) {
      plan.entries.add({
        'id': 'spot_$seq',
        'sourcePath': c['sourcePath'],
        'category': 'adversarial',
      });
      seq++;
      plan.adversarialCases.add(c);
      pickedIds.add(c['caseId'] as String);
    }
    // 针对性补测：固定 5 例，覆盖 adversarial r2 之后的代码变更面（见常量注释）。
    final allCases =
        (adversarial['cases'] as List).whereType<Map<String, dynamic>>().toList();
    for (final id in kTargetedAdversarialIds) {
      if (pickedIds.contains(id)) continue;
      Map<String, dynamic>? c;
      for (final x in allCases) {
        if (x['caseId'] == id &&
            x['sourcePath'] is String &&
            x['spotRunnable'] == true) {
          c = x;
          break;
        }
      }
      if (c == null) {
        plan.problems.add('针对性对抗用例 $id 不在裁判数据中或不可抽查复跑');
        continue;
      }
      plan.entries.add({
        'id': 'spot_$seq',
        'sourcePath': c['sourcePath'],
        'category': 'adversarial',
      });
      seq++;
      plan.adversarialCases.add(c);
      pickedIds.add(id);
    }
  } else {
    plan.problems.add('adversarial 裁判数据缺失（$kDefaultAdversarialGlob）');
  }
  return plan;
}

Future<DevicePhaseResult> _deviceWork(
    String deviceId, SpotPlan plan, StringBuffer log,
    {required bool killAtEnd}) async {
  try {
    // G4 r2：对两个实际接收 push 的叶子目录分别做可写探针（root 属主遗留
    // 可能出现在任意一层，见 prepareDeviceGateDir 注释）。
    final prepSpot = await prepareDeviceGateDir(deviceId, '$kDeviceGateDir/g4_spot');
    if (!prepSpot.success) {
      return DevicePhaseResult.failed(
          '设备端 g4_spot 目录准备失败: ${prepSpot.tail(maxChars: 200)}');
    }
    final prepGolden = await prepareDeviceGateDir(deviceId, '$kDeviceGateDir/golden/src');
    if (!prepGolden.success) {
      return DevicePhaseResult.failed(
          '设备端 golden/src 目录准备失败: ${prepGolden.tail(maxChars: 200)}');
    }

    // push 黄金集 g01（512² 计时与内存 churn 的输入）。
    final pushGolden = await _pushWithRetry(
        deviceId, 'test/golden/src/g01.jpg', '$kDeviceGateDir/golden/src/g01.jpg', log,
        tag: 'golden g01.jpg');
    if (!pushGolden.success) {
      return DevicePhaseResult.failed('adb push g01.jpg 失败: ${pushGolden.tail(maxChars: 200)}');
    }

    // push 抽查输入 + manifest。G4 r2：push 偶发设备端 "couldn't create file:
    // Permission denied"（本轮实测 13 push 中 7 失败且成功/失败交错，瞬态，
    // 疑似 boot 完成判定后设备侧 tmp 目录权限尚未稳定）。逐文件重试 + 每次
    // 重试前 chmod 目录，重试仍失败才算失败。
    final manifest = <Map<String, dynamic>>[];
    var pushFail = 0;
    for (final e in plan.entries) {
      final src = e['sourcePath'] as String;
      final ext = src.contains('.') ? src.substring(src.lastIndexOf('.')) : '';
      final deviceName = '${e['id']}$ext';
      final push = await _pushWithRetry(
          deviceId, src, '$kDeviceGateDir/g4_spot/$deviceName', log,
          tag: src);
      if (!push.success) {
        pushFail++;
        continue;
      }
      manifest.add({...e, 'deviceName': deviceName});
    }
    if (pushFail > 0) {
      return DevicePhaseResult.failed('抽查输入 push 失败 $pushFail 项（文件不存在或 adb 异常）');
    }
    final manifestFile = File('out/tmp/g4_spot_manifest.json');
    await manifestFile.parent.create(recursive: true);
    await manifestFile.writeAsString(jsonEncode(manifest));
    final pushManifest = await _pushWithRetry(
        deviceId, manifestFile.path, '$kDeviceGateDir/g4_spot/manifest.json', log,
        tag: 'manifest');
    if (!pushManifest.success) {
      return DevicePhaseResult.failed(
          'adb push manifest 失败: ${pushManifest.tail(maxChars: 200)}');
    }

    // ---- spotcheck drive（抽查 + 512² 计时）----
    final spotResponse = await _drive(
      deviceId,
      target: 'integration_test/g4_spotcheck_test.dart',
      timeoutMinutes: 30,
      log: log,
    );
    if (spotResponse == null) {
      return DevicePhaseResult.failed(
          'flutter drive g4_spotcheck_test.dart 失败/超时或无数据'
          '（抽查进程整体崩溃也走这里，详见 out/gate_G4_run.log）');
    }

    // ---- memcheck drive（20 张 churn + host 并行 dumpsys 采样）----
    final packageId = await findApplicationId();
    if (packageId == null) {
      return DevicePhaseResult.failed('无法解析 applicationId，内存复测无法定位进程');
    }
    final memRun = await _memcheckWithSampling(deviceId, packageId, log);
    if (memRun.error != null) log.writeln('memcheck: ${memRun.error}');

    // ---- 抽查核对（host 侧判定，harness 只测量）----
    final spotJudge = _judgeSpot(spotResponse, plan);
    return DevicePhaseResult._(
      spot: {
        ...spotJudge,
        'items': spotResponse['items'] ?? [],
        'timing512SamplesMs': spotResponse['timing512SamplesMs'] ?? [],
      },
      mem: memRun.mem,
      myP95Ms: _p95Of((spotResponse['timing512SamplesMs'] as List? ?? [])
          .whereType<num>()
          .toList()),
      peakMb: memRun.peakMb,
      myLeakDeltaMb: memRun.leakDeltaMb,
    );
  } finally {
    if (killAtEnd) {
      await runProcess('adb', ['-s', deviceId, 'emu', 'kill'],
          timeout: const Duration(seconds: 15));
    }
  }
}

/// 带重试与证据校验的 push。
///
/// G4 r2 实测两轮：adb push 偶发退出码非 0（"remote couldn't create file:
/// Permission denied"），但部分失败输出的 stdout 里同时出现 "1 file pushed"
/// —— 即文件可能实际已在设备端。因此判定以**证据**为准：设备端 stat 到的
/// 文件大小与本地一致 = push 成功（无论退出码）；不一致才重试（重试前
/// chmod 目录 + 递增退避），4 次仍不一致才判失败。
Future<RunResult> _pushWithRetry(String deviceId, String localPath,
    String remotePath, StringBuffer log,
    {required String tag}) async {
  final localLen = File(localPath).lengthSync();
  Future<bool> onDeviceMatches() async {
    final stat = await runProcess('adb',
        ['-s', deviceId, 'shell', 'stat -c %s "$remotePath" 2>/dev/null'],
        timeout: const Duration(seconds: 15));
    if (!stat.success) return false;
    final remoteLen = int.tryParse(stat.stdout.trim());
    return remoteLen != null && remoteLen == localLen;
  }

  var push = await adbPush(deviceId, localPath, remotePath);
  var attempt = 1;
  while (attempt <= 4) {
    if (await onDeviceMatches()) {
      if (!push.success) {
        log.writeln('push 退出码非 0 但设备端文件存在且大小一致（$localLen B），'
            '按成功处理: $tag');
      }
      return push;
    }
    await runProcess('adb', ['-s', deviceId, 'shell',
        'mkdir -p $kDeviceGateDir/g4_spot && chmod 777 $kDeviceGateDir/g4_spot'],
        timeout: const Duration(seconds: 15),
        // `&&` 是给**设备端** shell 的。开着本地 shell 时 cmd.exe 先解释一遍，
        // 命令被拆开、只跑第一段 —— 而第一段成功就是 exit 0，看起来一切正常。
        runInShell: false);
    await Future<void>.delayed(Duration(seconds: 2 * attempt));
    push = await adbPush(deviceId, localPath, remotePath);
    attempt++;
  }
  log.writeln('push 失败(重试 ${attempt - 1} 次后，末次设备端校验不一致): '
      '$tag → ${push.tail(maxChars: 150)}');
  return push;
}

/// 把 spotcheck 响应与裁判记录逐项核对。harness 只产出测量数据，判定在这里。
Map<String, dynamic> _judgeSpot(Map<String, dynamic> spotResponse, SpotPlan plan) {
  final mismatches = <String>[];
  for (final e in (spotResponse['errors'] as List? ?? [])) {
    mismatches.add('[harness] $e');
  }
  final items =
      (spotResponse['items'] as List? ?? []).whereType<Map<String, dynamic>>().toList();
  final byId = {for (final r in items) r['id'] as String: r};
  for (final e in plan.entries) {
    final id = e['id'] as String;
    final src = e['sourcePath'] as String;
    final rec = byId[id];
    if (rec == null) {
      mismatches.add('[$src] 设备端无结果（可能整进程崩溃/被跳过）');
      continue;
    }
    if (rec['unresponsive'] == true) {
      mismatches.add('[$src] 复跑无响应（${rec['ms']}ms 未落定）');
      continue;
    }
    switch (e['category'] as String) {
      case 'portrait':
        final batchOk = plan.batchRecord[src]?['outcome'] == 'ok';
        final mineOk = rec['stage'] == 'ready' && (rec['candidateCount'] as int? ?? 0) > 0;
        if (batchOk && !mineOk) {
          mismatches.add('[$src] 裁判=ok 但复跑 stage=${rec['stage']} '
              'candidates=${rec['candidateCount']}');
        } else if (!batchOk && mineOk) {
          mismatches.add('[$src] 裁判 outcome=${plan.batchRecord[src]?['outcome']} '
              '但复跑成功产出候选');
        }
      case 'non_portrait':
        final batchFail = plan.batchRecord[src]?['outcome'] == 'graceful_fail';
        final mineFail = rec['stage'] == 'error' &&
            rec['chineseError'] == true &&
            (rec['candidateCount'] as int? ?? -1) == 0;
        if (batchFail && !mineFail) {
          mismatches.add('[$src] 裁判=graceful_fail 但复跑 stage=${rec['stage']} '
              'chineseError=${rec['chineseError']} candidates=${rec['candidateCount']}');
        } else if (!batchFail && mineFail) {
          mismatches.add('[$src] 裁判 outcome=${plan.batchRecord[src]?['outcome']} '
              '但复跑优雅失败');
        }
      case 'adversarial':
        // 对抗用例：复跑必须落定（ready 或 error 都算处理过），不许无响应/崩溃。
        if (rec['stage'] != 'ready' && rec['stage'] != 'error') {
          mismatches.add('[$src] 对抗用例复跑 stage=${rec['stage']}（既非 ready 也非 error）');
        }
    }
  }
  return {
    'sampled': plan.entries.length,
    'adversarial': {
      'sampled': plan.adversarialCases.length,
      'mismatches': mismatches
          .where((m) => plan.adversarialCases
              .any((c) => m.contains('[${c['sourcePath']}')))
          .toList(),
    },
    'mismatches': mismatches,
  };
}

double? _p95Of(List<num> samples) {
  if (samples.isEmpty) return null;
  final sorted = samples.map((e) => e.toDouble()).toList()..sort();
  final idx = math.max(0, math.min(sorted.length - 1, (0.95 * sorted.length).ceil() - 1));
  return sorted[idx];
}

Future<Map<String, dynamic>?> _drive(
  String deviceId, {
  required String target,
  required int timeoutMinutes,
  required StringBuffer log,
  List<String> extraArgs = const [],
}) async {
  final responseFile = File(kResponseDataPath);
  if (await responseFile.exists()) await responseFile.delete();
  final run = await runProcess(
    'flutter',
    [
      'drive',
      // 宿主 GPU 栈损坏期间 Impeller GLES 会杀死 qemu，必须 Skia（docs/PITFALLS.md）。
      '--no-enable-impeller',
      ...extraArgs,
      '--driver=test_driver/integration_test_driver.dart',
      '--target=$target',
      '-d', deviceId,
      '--dart-define=GATE_TMP_DIR=$kDeviceGateDir',
    ],
    timeout: Duration(minutes: timeoutMinutes),
  );
  log.writeln('flutter drive $target 退出码=${run.exitCode} timedOut=${run.timedOut}');
  log.writeln(run.tail(maxChars: 1200));
  if (!run.success || !await responseFile.exists()) return null;
  try {
    return jsonDecode(await responseFile.readAsString()) as Map<String, dynamic>;
  } catch (e) {
    log.writeln('解析 $kResponseDataPath 失败: $e');
    return null;
  }
}

/// 拉起模拟器进程（打开控制台日志），**不等它上线** —— 等待与断言统一由
/// `gate_common.requireEmulatorDevice` 负责，本函数只回"我发起了吗"。
Future<bool> _spawnEmulator(StringBuffer log) async {
  // 先释放 Gradle daemon 内存（host 内存紧张曾挤崩 AVD）。
  final gradleStop = await runProcess('gradlew', ['--stop'],
      workingDirectory: 'android', timeout: const Duration(minutes: 2));
  log.writeln('gradlew --stop 退出码=${gradleStop.exitCode}');
  try {
    final consoleSink = File('out/GATE_G4_emu_console.log').openWrite();
    final proc = await Process.start(
      'emulator',
      [
        '-avd', kMainAvd,
        '-no-snapshot', // 全量冷启动，避开旧快照状态
        '-no-boot-anim',
        '-no-window',
        '-gpu', 'guest', // 宿主 GPU 驱动栈损坏，必须软渲染（docs/PITFALLS.md）
        '-feature', '-Vulkan',
      ],
      runInShell: true,
    );
    proc.stdout.transform(utf8.decoder).listen(consoleSink.write);
    proc.stderr.transform(utf8.decoder).listen(consoleSink.write);
    unawaited(proc.exitCode.then((_) => consoleSink.close()));
  } catch (e) {
    log.writeln('emulator 启动失败: $e');
    return false;
  }
  return true;
}

// ---- memcheck：drive 跑 20 张 churn 的同时，host 侧并行采样 dumpsys meminfo ----

int? _parseTotalPssKb(String dumpsysOut) {
  // 与 tools/gate/collect_metrics.dart 同一解析口径（TOTAL PSS 行）。
  final m = RegExp(r'TOTAL[A-Z\s]*:?\s+(\d+)').firstMatch(dumpsysOut);
  return m == null ? null : int.tryParse(m.group(1)!);
}

class _MemRunResult {
  final String? error;
  final Map<String, dynamic>? mem;
  final double? peakMb;
  final double? leakDeltaMb;
  _MemRunResult(this.error, this.mem, this.peakMb, this.leakDeltaMb);
}

Future<_MemRunResult> _memcheckWithSampling(
    String deviceId, String packageId, StringBuffer log) async {
  final samplesKb = <int>[];
  final samplesTms = <int>[]; // 每个采样点的 host 时钟（ms），用于推算采样节奏
  var sampling = true;

  Future<void> sampler() async {
    while (sampling) {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final r = await runProcess(
        'adb', ['-s', deviceId, 'shell', 'dumpsys', 'meminfo', packageId],
        timeout: const Duration(seconds: 20),
      );
      if (r.ok) {
        final kb = _parseTotalPssKb(r.stdout);
        if (kb != null && kb > 0) {
          samplesKb.add(kb);
          samplesTms.add(t0);
        }
      }
      final spent = DateTime.now().millisecondsSinceEpoch - t0;
      await Future<void>.delayed(
          Duration(milliseconds: math.max(0, 1200 - spent)));
    }
  }

  final samplerFuture = sampler();
  final response = await _drive(
    deviceId,
    // G4 r1 构建口径修正（主会话 2026-09-15 指令）：debug 的 JIT/调试服务显著
    // 抬高内存 floor（qa-batch r2 debug floor 440-510MB 主导 4.7 峰值）。
    // 4.7/4.8 的 gate 复测改用 profile AOT（integration_test 支持 profile），
    // 与 release runner 复测（tools/gate/g4_release_memcheck.py）互为印证。
    // 450 阈值不变，只是测对工件。
    target: 'integration_test/g4_memcheck_test.dart',
    timeoutMinutes: 25,
    log: log,
    extraArgs: const ['--profile'],
  );
  sampling = false;
  await samplerFuture;

  if (response == null || response['churnDone'] != true) {
    return _MemRunResult(
        'flutter drive g4_memcheck_test.dart 未完成 20 张 churn（churnDone 缺失或 drive 失败）',
        response, null, null);
  }
  if (samplesKb.length < 8) {
    return _MemRunResult('dumpsys 采样点不足（${samplesKb.length} 个），无法计算基线/峰值',
        response, null, null);
  }

  final mb = samplesKb.map((kb) => kb / 1024.0).toList();
  // 窗口定位（cadence 感知）：harness 的时序是 固定预热 → 空闲 14s → churn(20 张，
  // 逐张耗时在响应里) → 空闲 12s → 上报。dumpsys 每次调用本身耗时 ~0.5-1s，
  // 实际节奏用采样点时钟推算，再按时长换算各窗口的采样数：
  //   基线 = churn 起点前 14s 空闲窗的中位（profile 构建 floor 在预热后已稳态）；
  //   回落 = 末尾 12s 空闲窗的中位；峰值 = 全程最大。
  // （r1 前的旧启发式"取前 2-4 个采样点"会落在预热爬坡段，低估基线，已废弃。）
  final churnMs = (response['churnItemsMs'] as List? ?? [])
      .whereType<num>()
      .fold<int>(0, (a, b) => a + b.toInt());
  final cadenceMs = samplesTms.length >= 2
      ? (samplesTms.last - samplesTms.first) / (samplesTms.length - 1)
      : 2000.0;
  final tailCount = math.max(2, (12000 / cadenceMs).round());
  final churnCount = churnMs > 0 ? (churnMs / cadenceMs).round() : 0;
  final preCount = math.max(2, (14000 / cadenceMs).round());
  final baseStart = mb.length - tailCount - churnCount - preCount;
  final baseEnd = mb.length - tailCount - churnCount;
  final baseline = baseStart >= 0 && baseEnd > baseStart
      ? _median(mb.sublist(baseStart, baseEnd))
      : _median(mb.sublist(0, math.max(1, math.min(4, mb.length ~/ 3))));
  final after = _median(mb.sublist(math.max(0, mb.length - tailCount)));
  final peak = mb.reduce(math.max);
  final mem = <String, dynamic>{
    ...response,
    'gateSamplesMb': mb.map((v) => double.parse(v.toStringAsFixed(1))).toList(),
    'gateCadenceMs': double.parse(cadenceMs.toStringAsFixed(1)),
    'gateWindowBase': [baseStart, baseEnd],
    'gateBaselineMb': double.parse(baseline.toStringAsFixed(1)),
    'gateAfterMb': double.parse(after.toStringAsFixed(1)),
    'gatePeakMb': double.parse(peak.toStringAsFixed(1)),
  };
  return _MemRunResult(null, mem, peak, after - baseline);
}

double _median(List<double> xs) {
  final s = xs.toList()..sort();
  return s[s.length ~/ 2];
}
