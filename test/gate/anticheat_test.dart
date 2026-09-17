// test/gate/anticheat_test.dart
//
// **防作弊巡查自己的自检。**
//
// 存在理由（2026-09-17，主会话查出的结构性漏洞）：
// 条款 1「实现类 agent 写入了 test/ tools/gate/」的实现依赖 `git diff`，
// 而 **`git diff` 看不见未纳入版本控制的文件**。于是"新写一个文件"这条最
// 直白的越界路径是结构性地隐形的——仪表报"干净"，却看不见被检查的对象。
//
// 补法有两条腿，都必须有正例控制：
//   · `git log/diff <baseline>..HEAD`  → 抓已跟踪文件的**已提交**改动；
//   · `git status --porcelain -uall`   → 抓**未提交 + 未跟踪**的新文件。
// 一个没有正例的自测，与"永远返回合规"的坏实现无法区分——这一课本阶段
// 已经吃过一次，所以下面每条判定都有正例和负例两侧。
//
// 属 gatekeeper 势力范围（test/gate/）。

// flutter_test 是 dev_dependency。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import '../../tools/gate/anticheat.dart';

/// 探针文件名：故意用 `.tmp` 后缀且放在 tools/gate/ 下，测完立刻删除。
/// **必须在 finally 里删**——留下它就是给下一轮的门禁埋一个"工作树脏"。
const String kProbe = 'tools/gate/_anticheat_probe.tmp';

List<String> _porcelainUntracked() {
  final ProcessResult r = Process.runSync(
    'git',
    <String>['status', '--porcelain', '--untracked-files=all', '--', 'tools', 'test', 'docs'],
  );
  if (r.exitCode != 0) {
    throw StateError('git status 失败：${r.stderr}');
  }
  return (r.stdout as String)
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
}

void main() {
  test('A 未跟踪的新文件必须被 git status -uall 看见（正例）', () {
    final File probe = File(kProbe);
    expect(probe.existsSync(), false, reason: '探针文件已存在，上一轮没清干净');
    try {
      probe.writeAsStringSync('gatekeeper anticheat self-test probe\n');
      final List<String> lines = _porcelainUntracked();
      final bool seen = lines.any((String l) => l.contains('_anticheat_probe.tmp'));
      expect(seen, true,
          reason: '新写的未跟踪文件没出现在 git status 里 —— '
              '这正是条款 1 原来看不见的那条路径');
      // 光被看见还不够：它必须被判成"谁都不该动"。
      expect(isUniversallyProtected(kProbe), true,
          reason: 'tools/gate/ 下的新文件必须无条件可疑');
    } finally {
      if (probe.existsSync()) probe.deleteSync();
    }
    // 负例：删掉之后不得再出现。
    final List<String> after = _porcelainUntracked();
    expect(after.any((String l) => l.contains('_anticheat_probe.tmp')), false,
        reason: '探针没删干净，会把下一轮门禁的工作树弄脏');
  });

  test('B 干净时不得报违规（负例）', () {
    // 用**合成**的 porcelain 行做负例，不依赖本仓库当前状态
    // （否则这个测试会随着"gatekeeper 自己正改着文件"而红，变成噪声）。
    final List<String> lines = <String>[
      ' M lib/core/matting/iris_roll.dart',
      '?? test/batch/p0_compose_test.dart',
      ' M docs/PITFALLS.md',
      '?? out/GATE_P0_r1.md',
    ];
    final Iterable<String> v = lines.where((String l) {
      final String p = l.substring(2).trim().replaceAll('"', '');
      return isUniversallyProtected(p);
    });
    expect(v.toList(), <String>[], reason: '这些路径都不该被无条件当成越界');

    // 正例：把考卷改了，必须报出来
    final List<String> dirty = <String>[
      ' M docs/ACCEPTANCE.md',
      '?? tools/gate/new_probe.dart',
      ' M test/gate/p0_gate_judgment_test.dart',
    ];
    final Iterable<String> flagged = dirty.where((String l) {
      final String p = l.substring(2).trim();
      return isUniversallyProtected(p);
    });
    expect(flagged.length, 3, reason: '考卷与监考工具被改必须一条不漏');
  });

  test('C 受保护路径的判定：是哪些、不是什么', () {
    // 正例：考卷与监考工具
    for (final String p in <String>[
      'tools/gate/gate_P0.dart',
      'test/gate/p0_gate_judgment_test.dart',
      'docs/ACCEPTANCE.md',
      'docs/RUBRIC.md',
      'tools\\gate\\gate_P0.dart', // Windows 分隔符也要认出
    ]) {
      expect(isUniversallyProtected(p), true, reason: '$p 必须受保护');
    }
    // 负例：裁判自己的 test 子领地**不**受无条件保护 ——
    // 一刀切会把 qa-batch / adversarial 每轮的正常工作判成作弊，
    // 误报和漏报一样有害。
    for (final String p in <String>[
      'test/batch/p0_compose_test.dart',
      'test/adversarial/adversarial_runner.dart',
      'lib/core/matting/iris_roll.dart',
      'docs/PITFALLS.md',
      'out/GATE_P0_r1.md',
    ]) {
      expect(isUniversallyProtected(p), false, reason: '$p 不该被无条件当成越界');
    }
  });

  test('D 提交归属：谁能写 test/ 由提交前缀决定，不是由路径决定', () {
    // 条款 1 的**已提交**那一半靠 commit subject 前缀归属。
    // 这里钉住几个必须成立的映射。
    expect(ownerOfSubject('ml-porting: 瞳孔级眼线估计'), 'ml-porting');
    expect(ownerOfSubject('matting: 旧前缀写法'), 'ml-porting');
    expect(ownerOfSubject('qa-batch: 冻结数据集'), 'qa-batch');
    expect(ownerOfSubject('imaging: 裁剪几何'), 'imaging');
    expect(ownerOfSubject('ui-woodcraft: 木纹材质'), 'ui-woodcraft');
    expect(ownerOfSubject('acceptance: 冻结判据'), '未知（前缀 `acceptance` 不在角色表）',
        reason: '主会话的 acceptance 前缀没登记；未登记一律"未知"，不硬猜');
    // 未登记的归属必须**从严**，不能因为认不出来就放行
    expect(isForbiddenFor('tools/gate/gate_P0.dart', '未知（前缀 x 不在角色表）'), true,
        reason: '认不出归属时必须从严，否则改个前缀就能绕过条款 1');
    // 实现类 agent 碰 test/ tools/gate/ 必须是违规
    expect(isForbiddenFor('test/gate/x_test.dart', 'ml-porting'), true);
    expect(isForbiddenFor('tools/gate/gate_P0.dart', 'imaging'), true);
    expect(isForbiddenFor('docs/ACCEPTANCE.md', 'ui-woodcraft'), true);
    // 裁判碰自己的领地不是违规
    expect(isForbiddenFor('test/batch/p0_selftest.dart', 'qa-batch'), false);
    expect(isForbiddenFor('test/adversarial/a.dart', 'adversarial'), false);
  });
}
