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
import '../../tools/gate/gate_P0.dart' as gate;

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

  test('E 条款 5：单行与**跨行**空 catch 都必须抓到（正例），非空 catch 不得误报（负例）',
      () async {
    // 存在理由：原来的 `grep -rn` 是**逐行**匹配，而 dart format 之后
    //     } catch (e) {
    //     }
    // 是最自然的写法 —— 跨行空 catch 结构性地抓不到，等于条款 5 有一半是摆设。
    // 一个只有负例的自测，与"永远返回合规"的坏实现无法区分，所以这里两种
    // 写法各造一个**真样本**，并且必须都命中。
    final Directory tmp = Directory.systemTemp.createTempSync('gate_anticheat_');
    try {
      final String root = tmp.path.replaceAll('\\', '/');
      File('${tmp.path}/single.dart').writeAsStringSync(
        'void a() {\n  try { b(); } catch (_) {}\n}\n',
      );
      File('${tmp.path}/multiline.dart').writeAsStringSync(
        'void c() {\n  try { d(); }\n  catch (e) {\n  }\n}\n',
      );
      // 负例控制：**非空** catch 不许命中，否则说明模式退化成"见到 catch 就报"。
      File('${tmp.path}/handled.dart').writeAsStringSync(
        'void e() {\n  try { f(); } catch (err) {\n    log(err);\n  }\n}\n',
      );

      final Map<String, dynamic> s = await scanEmptyCatches(root);
      final String bare = (s['empty_body_hits'] as List<dynamic>).cast<String>().join('\n');
      final String commented =
          (s['commented_body_hits'] as List<dynamic>).cast<String>().join('\n');

      expect(s['undecidable'], false,
          reason: '临时目录上的扫描该是可判的（why=${s['why']}）');
      expect(s['files_scanned'], 3,
          reason: '三个 .dart 都得真被读到 —— '
              '"扫了 0 个文件"和"扫了但没命中"不是一回事');
      expect(bare.contains('single.dart'), true,
          reason: '单行空 catch `catch (_) {}` 必须报违规');
      expect(bare.contains('multiline.dart'), true,
          reason: '跨行空 catch `catch (e) {\\n}` 必须报违规 —— '
              '这正是原来逐行 grep 漏掉的那一半');
      expect(bare.contains('handled.dart'), false,
          reason: '有实参的非空 catch 不是违规，误报和漏报一样有害');
      expect(commented.contains('handled.dart'), false,
          reason: '有实参的非空 catch 也不该出现在"带理由的吞"名单里');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('H 条款 5 的判据不是它的严格子集：注释体、分号体、字符串/注释里的假 catch', () async {
    // 上一版的 `catch\\s*\\(...\\)\\s*\\{\\s*\\}` 只认**空白**体，于是
    //     } catch (_) {
    //       // 换下一个候选。
    //     }
    // 和 `catch (_) { ; }` 全都漏掉 —— `lib/` 里正好漏了 2 处注释体。
    // **判据是条款的严格子集，就等于悄悄放行了一个子集。**
    final Directory tmp = Directory.systemTemp.createTempSync('gate_anticheat_');
    try {
      final String root = tmp.path.replaceAll('\\', '/');
      // ① 注释体：体内只有一句说明 → 必须命中，且归入"带理由"那一类。
      File('${tmp.path}/comment_body.dart').writeAsStringSync(
        'void a() {\n  try { b(); }\n  catch (_) {\n    // 换下一个候选。\n  }\n}\n',
      );
      // ② 分号体：`;` 是空语句，也等于什么都没做。
      File('${tmp.path}/semi_body.dart').writeAsStringSync(
        'void c() {\n  try { d(); } catch (_) { ; }\n}\n',
      );
      // ③ 负例：体内有真语句，不许命中。
      File('${tmp.path}/real_body.dart').writeAsStringSync(
        'void e() {\n  try { f(); } catch (err) {\n    log(err);\n  }\n}\n',
      );
      // ④ 负例：**注释与字符串里的 `catch (_) {}` 不是代码**，不许命中。
      //    不遮罩的话，文档注释里写个示例就会被判成违规。
      File('${tmp.path}/in_comment.dart').writeAsStringSync(
        '/// 反例：`} catch (_) {}` 这种写法不要用。\n'
        'const String sample = "catch (_) {}";\n'
        'void g() {\n  try { h(); } catch (err) {\n    log(err);\n  }\n}\n',
      );

      final Map<String, dynamic> s = await scanEmptyCatches(root);
      final String bare = (s['empty_body_hits'] as List<dynamic>).cast<String>().join('\n');
      final String commented =
          (s['commented_body_hits'] as List<dynamic>).cast<String>().join('\n');
      final String all = '$bare\n$commented';

      expect(s['undecidable'], false, reason: 'why=${s['why']}');
      expect(commented.contains('comment_body.dart'), true,
          reason: '注释体的空 catch 必须命中，且归入带理由的一类');
      expect(commented.contains('换下一个候选'), true,
          reason: '命中里要带上作者自述的理由，供人裁定 —— 只报"有违规"没法回派');
      expect(bare.contains('semi_body.dart'), true,
          reason: '`catch (_) { ; }` 是空语句体，必须命中');
      expect(all.contains('real_body.dart'), false,
          reason: '体内有真语句的不许命中');
      expect(all.contains('in_comment.dart'), false,
          reason: '注释与字符串里的 `catch (_) {}` 不是代码，遮罩没做好就会误报');

      // 状态机 vs 正则：正则只是空白体的子集，两者必须一致到"正则命中 ⊆ 状态机命中"。
      expect(emptyCatchSites('void a() { try { b(); } catch (_) { ; } }').length, 1);
      expect(emptyCatchSites('void a() { try { b(); } catch (e) { log(e); } }').length, 0);
      expect(emptyCatchSites('// catch (_) {}').length, 0,
          reason: '注释里的不算 —— 文档注释里写示例是常事');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('I 条款 3 第三款「注释掉的断言」直接扫，不靠 diff 兜', () async {
    // 条款 3 正文有四款：skip: / @Skip / **注释掉的断言** / **被放宽的阈值常量**。
    // 后两款此前没有任何扫描器，报告却读起来像"条款 3 已完整扫描"。
    // 这里把第三款补成直接扫描；第四款是结构性覆盖（写进 evidence，见 patrol）。
    final Directory tmp = Directory.systemTemp.createTempSync('gate_anticheat_');
    try {
      final String root = tmp.path.replaceAll('\\', '/');
      File('${tmp.path}/commented.dart').writeAsStringSync(
        'void a() {\n'
        '  // expect(result, 42);\n'
        '  // assert(x > 0);\n'
        '  expect(real, 1);\n'
        '  // 这里顺带提一句 expect 这个词，不算注释掉的断言。\n'
        '}\n',
      );

      final Map<String, dynamic> s = await scanCommentedAssertions(root);
      final String hits = (s['hits'] as List<dynamic>).cast<String>().join('\n');
      expect(s['undecidable'], false, reason: 'why=${s['why']}');
      expect(hits.contains('// expect(result, 42);'), true,
          reason: '注释掉的 expect 必须命中');
      expect(hits.contains('// assert(x > 0);'), true,
          reason: '注释掉的 assert 也必须命中');
      expect(hits.contains('expect(real, 1)'), false,
          reason: '**真跑着的** expect 不是违规 —— 误报会给实现方制造假回派');
      expect(hits.split('\n').length, 2,
          reason: '散文里顺带提到 expect 不算，只该有 2 条');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('F 「零命中」与「判不了」必须可区分', () async {
    // 这条是同一个形态的收口：仪表看不见对象时，必须说"我看不见"，
    // 而不是说"没有"。空 hits 和真零命中在报告里长得一模一样，
    // 只有把"扫了什么/有没有打架"一并记下来才分得开。
    //
    // 现实教训：r1 的条款 3/5 用外部 grep，Windows 在参数传递途中吃掉了
    // 模式里的 `\` `{` `}`，grep 报 exit 2 —— 而报告里写的是"命中 0"。
    // **扫描从未真正跑过。** 下面这条就是把那种情形变成红色。
    final Directory tmp = Directory.systemTemp.createTempSync('gate_anticheat_');
    try {
      final String root = tmp.path.replaceAll('\\', '/');
      File('${tmp.path}/clean.dart').writeAsStringSync(
        'void a() {\n  try { b(); } catch (err) {\n    log(err);\n  }\n}\n',
      );

      // 真零命中：可判，且 hits 为空。
      final Map<String, dynamic> zero = await scanDir(
        root,
        pattern: RegExp(kEmptyCatchPattern),
        prefilter: const <String>['catch'],
      );
      expect(zero['undecidable'], false, reason: '干净的目录必须是可判的');
      expect(zero['files_scanned'], 1, reason: '必须真读到那一个文件');
      expect(zero['hits'], <String>[], reason: '确无命中就该是空，不许伪造出条目');

      // 判不了（引擎打架）：正则命中，但字面量预筛没筛出来 ⇒ 有东西不对劲。
      File('${tmp.path}/dirty.dart')
          .writeAsStringSync('void c() {\n  try { d(); } catch (_) {}\n}\n');
      final Map<String, dynamic> broken = await scanDir(
        root,
        pattern: RegExp(kEmptyCatchPattern),
        prefilter: const <String>['zzz-not-a-real-literal'],
      );
      expect(broken['undecidable'], true,
          reason: '两个引擎结论打架时必须报"判不了"—— '
              '把它当零命中，就是 r1 那次"扫描从未跑过却写命中 0"换个地方重演');
      expect((broken['why'] as String).isNotEmpty, true,
          reason: '判不了的时候必须给出原因，否则报告里没法回派');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('G 巡检自身领地的命中：登记但不判违规，且不能借机洗白别人', () {
    // 扫描器扫不了自己：anticheat.dart 里必然写着模式常量 `skip:`/`@Skip`，
    // anticheat_test.dart 里必然摆着正例夹具 `catch (_) {}`。
    // 一刀切会把这两处每轮都判成违规（噪声），全部隐去则是作弊。
    // 采取的是第三条路：**登记并公开**。
    expect(isScannerSelfTerritory('tools/gate/anticheat.dart'), true);
    expect(isScannerSelfTerritory('test/gate/anticheat_test.dart'), true);
    expect(isScannerSelfTerritory('tools\\gate\\anticheat.dart'), true,
        reason: 'Windows 分隔符也要认出，否则本机跑就漏判');

    // 负例：别人写的测试**不**在自身领地里，命中就得照样判违规。
    for (final String p in <String>[
      'test/batch/p0_compose_test.dart',
      'test/adversarial/a_test.dart',
      'test/widget_test.dart',
      'integration_test/coldstart_probe_test.dart',
      'lib/core/matting/x.dart',
    ]) {
      expect(isScannerSelfTerritory(p), false, reason: '$p 不该被当成巡检自身领地');
    }

    // 命中行解析：取不到路径时**原样返回**，不许返回空串——
    // 空串会从自身领地的判定里漏出去，变成一条假违规。
    expect(hitPath('test/gate/x.dart:12: catch (_) {}'), 'test/gate/x.dart');
    expect(hitPath('没有行号的怪东西'), '没有行号的怪东西');
    expect(isScannerSelfTerritory(hitPath('没有行号的怪东西')), false);
  });

  test('J 判据分母（真值文件）钉住了：数值动一个就 FAIL，纯表述订正放行', () {
    // 缺陷原样：`out/P0_truth.json` 装的是全部 P0 判据的**分母**，
    // 而它既不在冻结范围、也不在哈希表里 —— baseline 之后改一个真值，
    // 两处都不响。这是"为通过而放宽"最短的一条路，比改阈值隐蔽得多。
    // 2026-09-17 qa-batch 确实改过这个文件（改得对），但**门禁本来不会发现**。
    final Directory tmp = Directory.systemTemp.createTempSync('gate_truth_');
    try {
      final String truth = '${tmp.path}/truth.json'.replaceAll('\\', '/');
      final String base = '${tmp.path}/baseline.txt'.replaceAll('\\', '/');

      // ① 数值叶抽取：只认数，不认措辞。
      final List<String> leaves = gate.numericLeaves(<String, dynamic>{
        'a': 1.5,
        'b': <String, dynamic>{'c': -0.11, 'note': '真值'},
        'd': <dynamic>[1, 2.25],
        'e': true,
      });
      expect(leaves, <String>['a=1.5', 'b.c=-0.11', 'd[0]=1', 'd[1]=2.25'],
          reason: '布尔与字符串不是判据分母，不许混进来；顺序必须稳定');

      // ② 首轮：建立基线，不判 FAIL。
      File(truth).writeAsStringSync('{"anchors":[{"id":"c11","trueRollDeg":-0.11}]}');
      final gate.TruthDrift first = gate.truthDrift(truthPath: truth, baselinePath: base);
      expect(first.baselineEstablished, true);
      expect(first.numericChanges, <String>[]);
      expect(first.leafCount, 1);

      // ③ 改一个数值 → 必须报出来（这就是"改真值放行"那条路）。
      File(truth).writeAsStringSync('{"anchors":[{"id":"c11","trueRollDeg":-0.05}]}');
      final gate.TruthDrift changed = gate.truthDrift(truthPath: truth, baselinePath: base);
      expect(changed.baselineEstablished, false);
      expect(changed.numericChanges.length, 1);
      expect(changed.numericChanges.first.contains('anchors[0].trueRollDeg'), true);
      expect(changed.numericChanges.first.contains('-0.11 → -0.05'), true,
          reason: '必须报出旧值与新值，否则没法回派');

      // ④ **纯表述订正**：数值一个没动、整文件哈希变了 → 登记为豁免，不判 FAIL。
      //    qa-batch 在 c11df1c 做的那次就是这个形状，通道必须留着。
      File(truth).writeAsStringSync(
          '{"anchors":[{"id":"c11","trueRollDeg":-0.11,"note":"口径 6 订正后的表述"}]}');
      final gate.TruthDrift wording = gate.truthDrift(truthPath: truth, baselinePath: base);
      expect(wording.numericChanges, <String>[], reason: '数值没动就不许报改动');
      expect(wording.wordingOnly, true, reason: '整文件哈希变了、数值没动 → 表述订正');
      expect(wording.describe().contains('表述差异'), true);

      // ⑤ 删掉一个数值叶也算改动（否则"删掉不好看的样本"就没人拦）。
      File(truth).writeAsStringSync('{"anchors":[]}');
      final gate.TruthDrift removed = gate.truthDrift(truthPath: truth, baselinePath: base);
      expect(removed.numericChanges.length, 1);
      expect(removed.numericChanges.first.contains('删除'), true);
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('K 巡检失败时必须报"不可判"，不许从表里静默消失', () async {
    // `_sha256` 原来的失败模式：算不出来 `return null`，调用方
    // `if (s != null) h[p] = s;` → 该文件**从哈希表里蒸发**，不报错、不标不可判。
    // 与条款 3/5 的 grep 事故是同一个形状。这里从**巡检出口**验它：
    // 传进去一个"算不出哈希"的文件，必须变成违规 + 不可判，而不是无声无息。
    final Map<String, dynamic> ac = await patrol(
      baseline: 'baseline-p6p0',
      currentHashes: <String, String>{},
      prevHashes: null,
      goldenSrcCount: 8,
      goldenRefCount: 8,
      unhashable: <String>['tools/gate/ghost.dart'],
      judgmentInputDrift: <String>['anchors[0].trueRollDeg: -0.11 → -0.05'],
      judgmentInputNote: '测试桩',
    );

    final List<Map<String, dynamic>> vs =
        (ac['violations'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(
        vs.any((Map<String, dynamic> v) =>
            v['clause'] == '2' && '${v['path']}'.contains('ghost.dart')),
        true,
        reason: '算不出哈希的文件必须报出来，不许从表里消失');
    expect(
        vs.any((Map<String, dynamic> v) =>
            v['clause'] == '2' && '${v['detail']}'.contains('trueRollDeg')),
        true,
        reason: '判据分母被改必须判违规——这条以前完全没人守');
    expect((ac['undecidable'] as List<dynamic>).isNotEmpty, true,
        reason: '哈希算不出来属于"巡检自己判不了"，不得当清白');
    expect(ac['clean'], false, reason: '有违规就不是清白');
  });
}
