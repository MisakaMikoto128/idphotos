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

/// 不变量：**成片台的语料本身就分得开**，竖直样本独立成栏。
///
/// 抽成函数是为了能对它做**负向对照**——一条不能失败的断言等于没有断言，
/// 甚至更坏（它会让人停止怀疑）。见 main() 里的对照。
bool _uprightIsOwnCorpus(Iterable<P0Case> cs, int expect) {
  final m = <String, int>{};
  for (final c in cs) {
    m[c.corpus] = (m[c.corpus] ?? 0) + 1;
  }
  return m.containsKey('uprightSynthetic') && m['uprightSynthetic'] == expect;
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

  // P0.2 要的样本集来自正交字段 synthetic。
  // 注意：这个字段是为**覆盖率台**的合并标签而加的（那边把 uprightSynthetic 并进了
  // `anchor_${id}` 键）；**成片台的 corpus 本来就是分开的**，这里打印并断言，
  // 是为了保证两个台子对"竖直样本"的判别一致、且取样本时不走 byCorpus。
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

  // 真正需要钉住的不变量：成片台语料里竖直样本独立成栏。
  // 这条断言的前身写成 `perCorpus['anchor'] > 9`，是**假绿**——`buildCases` 从不把
  // uprightSynthetic 并进 anchor，所以它实际只测了"anchor 条数 > 9"，
  // **不可能因它名字所述的原因失败**。一个因错误原因而变绿的检查比没有更坏。
  _check('成片台语料里竖直样本**独立成栏**：uprightSynthetic 恰好 $expectUpright 条',
      _uprightIsOwnCorpus(cases.values, expectUpright),
      '${perCorpus['uprightSynthetic']?.first}');

  // 负向对照：证明上面这条**能失败**。模拟两种真实可能的坏法：
  // (a) 竖直样本被并进 anchor（覆盖率台那种键法）；(b) 少了一条。
  final collapsed = cases.values
      .map((c) => c.corpus == 'uprightSynthetic'
          ? P0Case(c.id, c.path, c.truthTiltDeg, 'anchor')
          : c)
      .toList();
  final dropped =
      cases.values.where((c) => c.corpus != 'uprightSynthetic').toList();
  _check('负向对照：并进 anchor → 必须变红',
      !_uprightIsOwnCorpus(collapsed, expectUpright));
  _check('负向对照：少一条 → 必须变红',
      !_uprightIsOwnCorpus(dropped, expectUpright));

  // 注意本文件**不**断言覆盖率台的 `anchor_<id>` 标签：那在另一个文件里，
  // 且已裁定**保持不动**（改它只会污染 r1↔r2 差分）。别在这里假装验证过它。
  stdout.writeln('  （覆盖率台的 anchor_<id> 合并标签未在此断言：另一文件、已裁定不动，'
      'P0.2 改走 synthetic）');

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
