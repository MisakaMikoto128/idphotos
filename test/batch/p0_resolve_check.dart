/// 成片台样本清单的**廉价 前置检查**：`dart run test/batch/p0_resolve_check.dart`
///
/// 检查 `out/P0_truth.json` 里每条样本都能解析到一个**真实存在的文件**。
///
/// 为什么值得单跑：成片台一轮 17 分钟，而"路径解析错"这类问题会让它**静默**跳过
/// 全部夹具（`missing` 分支 continue），跑完还是 exit 0 —— 花 17 分钟换来一份
/// "P0.2/P0.3 零样本"的报告。这里 3 秒就能提前问出来。
///
/// 它驱动 `p0_cases.dart` 的**同一份** `buildCases`，不是复制品。
library;

import 'dart:convert';
import 'dart:io';

import 'p0_cases.dart';

int _fail = 0;

void _check(String name, bool ok, [String detail = '']) {
  stdout.writeln('  ${ok ? 'ok  ' : 'FAIL'} $name${detail.isEmpty ? '' : '  -- $detail'}');
  if (!ok) _fail++;
}

void main() {
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  final truthPath = '$repo${sep}out${sep}P0_truth.json';
  final truth =
      jsonDecode(File(truthPath).readAsStringSync()) as Map<String, dynamic>;

  final cases = <String, P0Case>{};
  for (final c in buildCases(truth, repo: repo, sep: sep)) {
    cases[c.id] = c;
  }

  final perCorpus = <String, List<int>>{}; // corpus -> [total, missing]
  final missing = <P0Case>[];
  for (final c in cases.values) {
    final e = perCorpus.putIfAbsent(c.corpus, () => <int>[0, 0]);
    e[0]++;
    if (!File(c.path).existsSync()) {
      e[1]++;
      missing.add(c);
    }
  }

  stdout.writeln('清单来源 $truthPath');
  stdout.writeln('样本总数（按 id 去重后）: ${cases.length}\n');
  var totalMissing = 0;
  for (final k in perCorpus.keys.toList()..sort()) {
    final e = perCorpus[k]!;
    totalMissing += e[1];
    stdout.writeln('  ${k.padRight(18)} ${e[0].toString().padLeft(3)} 条，'
        '解析失败 ${e[1]}');
  }

  // P0.2 要的样本集来自正交字段 synthetic，**不是** byCorpus
  // （corpus 把 uprightSynthetic 并进了 'anchor'，分不出来）。
  // 这里顺带把它的分布打出来并断言具体条数，免得"字段加了但取错"。
  final bySyn = <String, int>{};
  for (final c in cases.values) {
    bySyn[c.synthetic ?? '(无)'] = (bySyn[c.synthetic ?? '(无)'] ?? 0) + 1;
  }
  stdout.writeln('\n按 synthetic 字段（P0.2 用这个取样本）:');
  for (final k in bySyn.keys.toList()..sort()) {
    stdout.writeln('  ${k.padRight(12)} ${bySyn[k]}');
  }
  const expectUpright = 9;
  const expectRotated = 78;
  final upOk = (bySyn['upright'] ?? 0) == expectUpright;
  final rotOk = (bySyn['rotated'] ?? 0) == expectRotated;
  _check('synthetic=upright 恰为 $expectUpright 条（P0.2 样本集）', upOk,
      '${bySyn['upright']}');
  _check('synthetic=rotated 恰为 $expectRotated 条', rotOk, '${bySyn['rotated']}');
  _check('corpus 仍把竖直样本并进 anchor（未改动，r1↔r2 结构可比）',
      (perCorpus['anchor']?[0] ?? 0) > expectUpright,
      'anchor=${perCorpus['anchor']?[0]}');

  if (missing.isNotEmpty) {
    stdout.writeln('\n解析失败明细（前 10）:');
    for (final c in missing.take(10)) {
      stdout.writeln('  [${c.corpus}] ${c.id}\n      ${c.path}');
    }
  }

  // 双重拼接是本次事故的特征：绝对路径又被拼了一次仓库前缀。
  final doubled =
      missing.where((c) => c.path.contains('$sep$repo$sep')).length;
  if (doubled > 0) {
    stdout.writeln('\n⚠ 其中 $doubled 条呈现**路径被拼接两次**的特征'
        '（路径里又出现了一次仓库根），这是 p0_cases.dart 修掉的那个 bug 的指纹。');
  }

  final bad = totalMissing + _fail;
  stdout.writeln('\n${bad == 0 ? 'RESOLVE CHECK PASS' : 'RESOLVE CHECK FAIL ($bad)'}');
  exit(bad == 0 ? 0 : 1);
}
