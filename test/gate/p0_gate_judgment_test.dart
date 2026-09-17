// test/gate/p0_gate_judgment_test.dart
//
// **门禁判定逻辑的自检 —— 考卷的考卷。**
//
// 存在理由：gatekeeper 自己写的门禁如果永远输出 PASS，它比没有门禁更糟
// （给了全自动模式一个假的"已验证"）。这个测试把**已知答案**的原始记录灌进
// `gate_P0.dart` 的纯判定函数 `evaluateP0`，断言它在该 FAIL 的地方 FAIL、
// 在该 PASS 的地方 PASS。
//
// 每条用例的"已知答案"都来自一个真实的失败模式，不是我编的：
//   A. 修前事故态（PITFALLS 2026-09-17）：p1 真值 −4.4 却不转；p2 真值 −0.2 被转歪 +3.7
//   B. 合格实现 → 必须全 PASS（防止门禁"宁枉勿纵"到谁都过不了）
//   C. 该摆正却返回 unavailable → P0.1b / P0.3b 条件覆盖率 FAIL
//   D. 残余随倾角增长（估计衰减）→ P0.3a 硬判据② FAIL
//   E. 量具自检不过 → 一律 MANUAL，**不许**默认通过
//   F. 锚点不足 8 张 → P0.1a FAIL
//   G. dev_selfcheck 回归 → P0.5a FAIL
//   H. unavailable 却施加了非零角 → P0.4 诚实性 FAIL
//   O. P0.1a 的样本下限数的是**不同照片**而非行数（含 c03≡c04 的负向对照）
//
// 本文件属 gatekeeper 势力范围（test/gate/），实现类 agent 改动即 FAIL。
//
// 运行：
// ```
// flutter test test/gate/p0_gate_judgment_test.dart
// ```

// flutter_test 是 dev_dependency。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';
import 'dart:io';

import '../../tools/gate/gate_P0.dart' as gate;

const String kSpec = 'cn_big_1inch';

/// 一条"生产记录 + 独立测量"的组合。字段名与 out/P0_compose_items.jsonl 一致。
Map<String, dynamic> item({
  required String id,
  required String corpus,
  required double truth,
  required String source,
  required double applied,
}) =>
    <String, dynamic>{
      'id': id,
      'corpus': corpus,
      'truthTiltDeg': truth,
      'rollSource': source,
      'straightenDeg': applied,
      'specId': kSpec,
    };

/// 一个"可判"的轮次状态：工作树冻结、样本条数对得上、成片文件都在。
/// 大多数用例要考的是判定逻辑本身，所以默认给一个可信的 roundState；
/// 专测"输入不可信"的用例（N）自己覆盖它。
Map<String, dynamic> goodRoundState() => <String, dynamic>{
      'frozen': true,
      'dirty': <String>[],
      'composeDeclared': 100,
      'composeParsed': 100,
      'composeMissingFiles': 0,
      'composeMissingIds': <String>[],
    };

/// 组装 evaluateP0 的输入。
///
/// [measured] 是 id → gatekeeper 眼线量具测出的成片倾角；没给的 id 视为
/// 量具测不出（走 derived_identity 兜底）。
Map<String, dynamic> inputs({
  required List<Map<String, dynamic>> compose,
  Map<String, double> measured = const <String, double>{},
  double eyeErr = 0.20,
  double rigidErr = 0.10,
  List<String> blockers = const <String>[],
  int devExit = 0,
  String devTail = '+9: All tests passed!',
  bool gateJsonsPass = true,
  double siftDelta = 0.0,
  Object? anticheat = const <String, dynamic>{'clean': true, 'summary': '测试桩'},
  Map<String, dynamic>? roundState,
  /// 测量产出的来源绑定结论。真实内容由 `provenanceReport()` 产出，
  /// 这里只放**它的输出形状**：本文件测的是"判定函数怎么用这个结论"，
  /// 结论本身怎么算出来由 `test/gate/provenance_test.dart` 负责。
  Map<String, dynamic>? provenance = const <String, dynamic>{
    'reasons': <String>[],
    'summary': '测试桩：三份测量产出均可自证与当前树同源',
    'allBound': true,
  },
  Object? overlap = const <String, dynamic>{
    'intra_duplicates': <Map<String, dynamic>>[
      <String, dynamic>{'a': 'c03', 'b': 'c04', 'mae': 2.33},
    ],
  },
}) {
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  measured.forEach((String id, double v) {
    rows.add(<String, dynamic>{'id': id, 'ok': true, 'tilt_deg': v});
  });
  for (final Map<String, dynamic> c in compose) {
    if (!measured.containsKey(c['id'])) {
      rows.add(<String, dynamic>{'id': c['id'], 'ok': false, 'reason': 'no_face'});
    }
  }
  // SIFT 路径：把"实际施加角"原样量回来（合格实现下与记录一致），
  // 残余 = 真值 − 实测施加角。
  final List<Map<String, dynamic>> sift = <Map<String, dynamic>>[];
  for (final Map<String, dynamic> c in compose) {
    final double t = c['truthTiltDeg'] as double;
    final double a = c['straightenDeg'] as double;
    sift.add(<String, dynamic>{
      'id': c['id'],
      'ok': true,
      'measured_applied_deg': a + siftDelta,
      'residual_deg': t - a,
      'applied_delta_vs_record': siftDelta,
    });
  }
  return <String, dynamic>{
    'spec': kSpec,
    'compose': compose,
    'eyeline': <String, dynamic>{'rows': rows},
    'siftAlign': <String, dynamic>{'rows': sift},
    'eyelineSelftest': <String, dynamic>{'max_abs_err_deg': eyeErr, 'pass': eyeErr <= 0.5},
    'rigidSelftest': <String, dynamic>{'max_abs_err_deg': rigidErr, 'pass': rigidErr <= 0.5},
    'blockers': blockers,
    'devSelfcheck': <String, dynamic>{'exitCode': devExit, 'tail': devTail},
    'gateG2B': <String, dynamic>{
      'gate': 'G2B',
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'id': '2B.1', 'pass': gateJsonsPass},
      ],
    },
    'gateG4': <String, dynamic>{
      'gate': 'G4',
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'id': '4.1', 'pass': gateJsonsPass},
      ],
    },
    'anticheat': anticheat,
    'overlap': overlap,
    'provenance': provenance,
    'roundState': roundState ?? goodRoundState(),
  };
}

Map<String, dynamic> row(List<Map<String, dynamic>> items, String id) =>
    items.firstWhere((Map<String, dynamic> i) => i['id'] == id);

/// 造一整套"合格实现"的记录：12 条倾斜锚点 + p2 竖直 + 9 张合成竖直 + 旋转夹具。
List<Map<String, dynamic>> goodCorpus() {
  final List<Map<String, dynamic>> c = <Map<String, dynamic>>[];
  const List<double> truth = <double>[4.4, -1.3, 0.25, 3.72, 8.01, 1.73, 0.35, 8.01, 3.44, 0.11, 2.09, 3.91];
  for (int i = 0; i < truth.length; i++) {
    final String id = i == 0 ? 'p1' : 'c${i.toString().padLeft(2, '0')}';
    // 合格实现：估计值 ≈ 真值，死区内不转（0.25/0.35/0.11 落进 1° 死区）。
    final double applied = truth[i].abs() > 1.0 ? truth[i] : 0.0;
    c.add(item(id: id, corpus: 'anchor', truth: truth[i], source: 'pupil', applied: applied));
  }
  c.add(item(id: 'p2', corpus: 'straight', truth: -0.2, source: 'pupil', applied: 0.0));
  for (final String id in <String>['p1', 'c01', 'c03', 'c04', 'c05', 'c06', 'c08', 'c10', 'c12']) {
    c.add(item(id: '${id}_upright', corpus: 'uprightSynthetic', truth: 0.0, source: 'pupil', applied: 0.0));
  }
  for (final double base in <double>[-4.4, 3.72, -8.01]) {
    for (final double d in <double>[3, -3, 5, -5, 10, -10]) {
      final double t = base + d;
      c.add(item(
        id: 'f${base}_d$d',
        corpus: 'rotated',
        truth: t,
        source: 'pupil',
        applied: t.abs() > 1.0 ? t : 0.0,
      ));
    }
  }
  return c;
}

/// 合格实现下，量具测得的成片倾角：理想 0，给一点点噪声。
Map<String, double> goodMeasured(List<Map<String, dynamic>> compose) {
  final Map<String, double> m = <String, double>{};
  for (final Map<String, dynamic> c in compose) {
    m[c['id'] as String] = (c['truthTiltDeg'] as double) - (c['straightenDeg'] as double);
  }
  return m;
}

void main() {
  test('A 修前事故态必须 FAIL（门禁抓得住已知坏状态）', () {
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      // p1：旧估角器给出 +0.84（落进死区）→ 不转；真值 −4.4，成片仍歪 −4.4
      item(id: 'p1', corpus: 'anchor', truth: -4.4, source: 'unavailable', applied: 0.0),
      // p2：旧估角器给出 −3.85 → 转歪；真值 −0.2 → 成片残余 +3.65
      item(id: 'p2', corpus: 'straight', truth: -0.2, source: 'pupil', applied: -3.85),
      item(id: 'c03', corpus: 'anchor', truth: -3.72, source: 'unavailable', applied: 0.0),
    ];
    final Map<String, double> m = <String, double>{
      'p1': -4.4, // 成片仍歪 −4.4
      'p2': 3.65, // 成片被转歪 +3.65
      'c03': -3.72,
    };
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: m));

    // p1/c03 真值 |tilt| > 1.5 却 unavailable —— 这正是事故的机制。
    expect(row(items, 'P0.1b')['pass'], false, reason: '该摆正却说测不出，必须 FAIL');
    // p2 被转歪 3.65°。
    expect(row(items, 'P0.2')['pass'], false, reason: '转歪了竖直样本，必须 FAIL');
    expect(row(items, 'P0.3b')['pass'], true, reason: '这条夹具都把角给出了，覆盖率本身没问题');
  });

  test('B 合格实现必须全 PASS（门禁不能宁枉勿纵到谁都过不了）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: goodMeasured(compose)));
    final List<Map<String, dynamic>> failed = items
        .where((Map<String, dynamic> i) => i['pass'] != true && i['manual'] != true)
        .toList();
    expect(failed.map((Map<String, dynamic> i) => i['id']).toList(), <String>[],
        reason: '合格数据被判 FAIL，说明判定逻辑有 bug');
    // P0.5c 恒为 MANUAL：它要重跑设备端才知道有没有退化，本轮不重跑。
    // 把它钉在测试里，防止哪天它被悄悄改成"默认通过"。
    final List<String> manual = items
        .where((Map<String, dynamic> i) => i['manual'] == true)
        .map((Map<String, dynamic> i) => i['id'] as String)
        .toList();
    expect(manual, <String>['P0.5c']);
  });

  test('C 该摆正却返回 unavailable → P0.3b FAIL（堵住"永远返回测不出"的免费通道）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final Map<String, double> m = goodMeasured(compose);
    // 把一条真值 6.28° 的夹具改成"测不出"：成片就会歪着 6.28°。
    final int i = compose.indexWhere((Map<String, dynamic> c) => c['id'] == 'f-4.4_d10.0');
    compose[i]['rollSource'] = 'unavailable';
    compose[i]['straightenDeg'] = 0.0;
    m['f-4.4_d10.0'] = 5.6; // 成片实测仍歪 5.6°
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: m));
    expect(row(items, 'P0.3b')['pass'], false);
    // 口径 1/2 的分工：unavailable 的样本不进 P0.3a 的残余统计
    //（否则"永远返回测不出"在近竖直样本上残差天然为 0，会免费过关），
    // 它的账由 P0.3b 的条件覆盖率来算。这条断言把这个分工钉住，
    // 防止以后有人把 unavailable 混回残余统计里。
    expect((row(items, 'P0.3a')['actual'] as String).contains('unavailable'),
        true, reason: 'unavailable 样本必须离开残余统计，并在报告里看得见');
  });

  test('D 残余随倾角增长（估计衰减）→ P0.3a FAIL，且与符号约定无关', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    // 估计只做到真值的一半：真值 t 的成片残余 = t − t/2 = t/2，斜率 0.5。
    for (final Map<String, dynamic> c in compose) {
      if (c['corpus'] != 'rotated') continue;
      final double t = c['truthTiltDeg'] as double;
      c['straightenDeg'] = t / 2.0;
      c['rollSource'] = 'pupil';
    }
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: goodMeasured(compose)));
    expect(row(items, 'P0.3a')['pass'], false);
    expect((row(items, 'P0.3a')['actual'] as String).contains('② 硬判据'), true);
  });

  test('E 量具自检不过 → 一律 MANUAL，且永不算通过', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final List<Map<String, dynamic>> items = gate.evaluateP0(inputs(
      compose: compose,
      measured: goodMeasured(compose),
      eyeErr: 1.2, // 量不准
    ));
    final List<Map<String, dynamic>> manual =
        items.where((Map<String, dynamic> i) => i['manual'] == true).toList();
    expect(manual, isNotEmpty, reason: '量具不可信时必须标 MANUAL');
    expect(manual.every((Map<String, dynamic> i) => i['pass'] != true), true,
        reason: 'MANUAL 项绝不允许 pass=true');
  });

  test('F 锚点不足 8 张 → P0.1a FAIL', () {
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      for (int i = 0; i < 5; i++)
        item(id: 'a$i', corpus: 'anchor', truth: 3.0 + i, source: 'pupil', applied: 3.0 + i),
    ];
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: goodMeasured(compose)));
    expect(row(items, 'P0.1a')['pass'], false);
  });

  test('G dev_selfcheck 回归 → P0.5a FAIL', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final List<Map<String, dynamic>> items = gate.evaluateP0(inputs(
      compose: compose,
      measured: goodMeasured(compose),
      devExit: 1,
      devTail: '+8 -1: Some tests failed.',
    ));
    expect(row(items, 'P0.5a')['pass'], false);
  });

  test('H unavailable 却施加了非零角 → P0.4 诚实性 FAIL', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    compose.add(item(id: 'x1', corpus: 'anchor', truth: 0.1, source: 'unavailable', applied: 2.5));
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: goodMeasured(compose)));
    expect(row(items, 'P0.4')['pass'], false);
  });

  test('I 眼线量具测不出的样本，由 SIFT 独立补测并显式记账（条款 7）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final Map<String, double> m = goodMeasured(compose);
    m.remove('p1'); // 眼线量具测不出这条
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: m));
    final String actual = row(items, 'P0.1a')['actual'] as String;
    expect(actual.contains('gate_sift_align'), true,
        reason: '眼线量不出来的样本必须换一条独立路径量出来并写明出处，不许从统计里消失');
  });

  test('J 三条路径全测不出时，退回恒等式但必须显式标注（不许静默）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final Map<String, double> m = goodMeasured(compose);
    m.remove('p1');
    final Map<String, dynamic> inp = inputs(compose: compose, measured: m);
    final List<Map<String, dynamic>> sift =
        (inp['siftAlign'] as Map<String, dynamic>)['rows'] as List<Map<String, dynamic>>;
    sift.removeWhere((Map<String, dynamic> r) => r['id'] == 'p1');
    final List<Map<String, dynamic>> items = gate.evaluateP0(inp);
    expect((row(items, 'P0.1a')['actual'] as String).contains('derived_identity'), true,
        reason: '兜底路径必须留痕，否则就等于"悄悄算它通过"');
  });

  // ---------------------------------------------------------------------
  // K / L：AC（防作弊）必须有 FAIL 控制。
  // 背景：AC 曾把缺输入 `?? {'clean': true}` 默认成"清白"——"我不知道"被
  // 翻译成"干净"。而 AC 恰恰是条款 1 唯一有结构性盲点的组件，
  // 却没有一条用例能在它被接成恒真时变红。
  // ---------------------------------------------------------------------
  test('K 防作弊输入缺失 → AC 必须 MANUAL 且 pass 不得为 true（不许默认真清白）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final List<Map<String, dynamic>> items = gate.evaluateP0(inputs(
      compose: compose,
      measured: goodMeasured(compose),
      anticheat: null, // 巡检未产出
    ));
    final Map<String, dynamic> ac = row(items, 'AC');
    expect(ac['pass'], false, reason: '"我不知道"不得被翻译成"干净"');
    expect(ac['manual'], true, reason: '缺输入必须是 MANUAL，不是 PASS');
    expect((ac['actual'] as String).contains('不可判'), true);
  });

  test('L 防作弊巡检报出违规 → AC FAIL（接成恒真必须变红）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final List<Map<String, dynamic>> items = gate.evaluateP0(inputs(
      compose: compose,
      measured: goodMeasured(compose),
      anticheat: <String, dynamic>{
        'clean': false,
        'violations': <Map<String, dynamic>>[
          <String, dynamic>{
            'clause': '1',
            'path': 'test/foo_test.dart',
            'attribution': 'ml-porting',
            'detail': '越界写 test/',
          },
        ],
      },
    ));
    final Map<String, dynamic> ac = row(items, 'AC');
    expect(ac['pass'], false);
    expect((ac['actual'] as String).contains('test/foo_test.dart'), true,
        reason: '违规必须点名到文件，否则读者不知道找谁');
  });

  test('M 2B.8 施加几何对不上 → P0.5b FAIL（此前无人守这一项）', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    // 施加角被量出来与记录差 4°：成片残余不受影响，只有 SIFT 的施加几何炸。
    final List<Map<String, dynamic>> items = gate.evaluateP0(inputs(
      compose: compose,
      measured: goodMeasured(compose),
      siftDelta: 4.0,
    ));
    expect(row(items, 'P0.5b')['pass'], false);
    expect((row(items, 'P0.5b')['actual'] as String).contains('①'), true,
        reason: '报告必须把炸掉的那个子量标出来');
  });

  // ---------------------------------------------------------------------
  // N：一轮判决只能来自同一个被冻结、被标识的代码状态。
  // 三种不可信输入都必须令整轮**作废**，而不是加一行说明放过去——
  // r1 就是这么滑过去的（判决由两个不同状态的测量拼成）。
  // ---------------------------------------------------------------------
  test('N 输入不来自同一冻结状态 → 整轮作废，不得当成对代码的判决', () {
    final List<Map<String, dynamic>> compose = goodCorpus();
    final Map<String, double> m = goodMeasured(compose);

    // N1：缺 roundState —— 不许默认可信（与 AC 那处同源：缺失 ≠ 通过）
    final Map<String, dynamic> noStateInp = inputs(compose: compose, measured: m);
    noStateInp.remove('roundState');
    final List<Map<String, dynamic>> noStateItems = gate.evaluateP0(noStateInp);
    expect(noStateItems.every((Map<String, dynamic> i) => i['roundInvalid'] == true),
        true, reason: '缺 roundState 必须整轮作废，不得默认可信');

    for (final Map<String, dynamic> bad in <Map<String, dynamic>>[
      <String, dynamic>{
        'frozen': false,
        'dirty': <String>[' M lib/core/matting/iris_roll.dart'],
        'composeDeclared': 100,
        'composeParsed': 100,
        'composeMissingFiles': 0,
      },
      <String, dynamic>{
        'frozen': true,
        'dirty': <String>[],
        'composeDeclared': 100,
        'composeParsed': 87, // 87 条静默 continue（qa-batch 真实踩过）
        'composeMissingFiles': 0,
      },
      <String, dynamic>{
        'frozen': true,
        'dirty': <String>[],
        'composeDeclared': 100,
        'composeParsed': 87,
        'composeMissingFiles': 13,
      },
    ]) {
      final Map<String, dynamic> inp = inputs(
        compose: compose,
        measured: m,
        roundState: bad,
      );
      final List<Map<String, dynamic>> items = gate.evaluateP0(inp);
      expect(items.every((Map<String, dynamic> i) => i['pass'] != true), true,
          reason: '输入不可信时任何一项都不得判 PASS');
      expect(items.every((Map<String, dynamic> i) => i['roundInvalid'] == true), true,
          reason: '必须整轮作废，而不是逐项解释');
      expect(items.every((Map<String, dynamic> i) => i['manual'] == true), true,
          reason: '作废轮是 MANUAL，不消耗实现方的修复轮次');
    }
  });

  // ---------------------------------------------------------------------
  test('P 测量产出与本轮代码不同源 → 整轮作废（`out/` 不受冻结约束）', () {
    // 缺陷原样（主会话 2026-09-17 裁定）：`out/` 是共享输出目录，
    // `git status -- lib test tools docs` 为空**推不出**"盘上这几份数是当前代码跑的"。
    // 一份上一轮遗留的 `P0_output_residual.json` 会被当成当轮读数 ——
    // 与 r1 判决作废同源（判决由两个不同代码状态的测量拼成），只是换了个入口。
    // 机器检查落在 `inputs['provenance']` 上：缺、或有 reasons，都判整轮作废。
    final List<Map<String, dynamic>> compose = goodCorpus();
    final Map<String, double> m = goodMeasured(compose);

    // 前提：合格的 provenance → 本轮可判（否则下面的反例证明不了任何东西）。
    final List<Map<String, dynamic>> ok = gate.evaluateP0(inputs(compose: compose, measured: m));
    expect(ok.any((Map<String, dynamic> i) => i['roundInvalid'] == true), false,
        reason: '绑定成立时不该作废 —— 一个谁都要作废的检查拦不住任何人');

    // P1：整个 provenance 缺失 —— 不许默认可信（与 AC/roundState 两处同源）。
    final Map<String, dynamic> noPv = inputs(compose: compose, measured: m);
    noPv.remove('provenance');
    final List<Map<String, dynamic>> noPvItems = gate.evaluateP0(noPv);
    expect(noPvItems.every((Map<String, dynamic> i) => i['roundInvalid'] == true), true,
        reason: '缺来源绑定必须作废，不得默认"这轮的数就是当前代码的"');

    // P2：绑定产出但结论是"绑不上"（指纹不一致 / 产出缺字段 / roundValid=false）。
    final Map<String, dynamic> unbound = inputs(
      compose: compose,
      measured: m,
      provenance: const <String, dynamic>{
        'reasons': <String>[
          '测量产出 `out/P0_output_residual.json` 不可自证属于当前代码：'
              '1 个文件的 blob 哈希与当前树不一致（＝这些数是**别的代码**跑出来的）',
        ],
        'summary': '**1/3 份测量产出无法自证来源**',
        'allBound': false,
      },
    );
    final List<Map<String, dynamic>> unboundItems = gate.evaluateP0(unbound);
    expect(unboundItems.every((Map<String, dynamic> i) => i['roundInvalid'] == true), true);
    expect(unboundItems.every((Map<String, dynamic> i) => i['pass'] != true), true,
        reason: '不许拿旧代码的数当本轮的数 —— 一项都不许判 PASS');
    expect(unboundItems.every((Map<String, dynamic> i) => i['manual'] == true), true,
        reason: '作废轮是 MANUAL，不消耗实现方的修复轮次');
    final String why = unboundItems.first['actual'] as String;
    expect(why.contains('测量产出'), true, reason: '理由要写进报告，否则没法回派');
  });

  // ---------------------------------------------------------------------
  test('O P0.1a 的样本下限数的是**不同照片**，不是行数（负向对照）', () {
    // 缺陷原样（主会话 2026-09-17 报，qa-batch 提供实况）：
    //   `cohort.length >= kMinDistinctPhotos`
    // 而**同一项**的 expected 写的是「样本 ≥ 8 张**不同照片**」。
    // `cohort.length` 是**行数**，恒 ≥ 不同照片数 —— 判据比它的名字松。
    // 这是把实现对齐到冻结的判据文本，阈值 8 未动。
    const Map<String, dynamic> ov = <String, dynamic>{
      'intra_duplicates': <Map<String, dynamic>>[
        <String, dynamic>{'a': 'c03', 'b': 'c04', 'mae': 2.33},
      ],
    };
    List<Map<String, dynamic>> rows(List<String> ids) =>
        ids.map((String id) => <String, dynamic>{'id': id}).toList();

    // ① 11 行里 c03≡c04 是同一张 → 必须报 **10**，不是 11。
    final List<String> eleven = <String>[
      'p1', 'c01', 'c02', 'c03', 'c04', 'c05', 'c06', 'c07', 'c08', 'c11', 'c12',
    ];
    expect(eleven.length, 11);
    expect(gate.distinctPhotoCount(rows(eleven), ov), 10,
        reason: '数行数会得到 11；判据要的是不同照片数');

    // ② **少一张真照片**：8 行看着正好卡在下限上，实际只有 7 张不同照片。
    //    这正是这条缺陷的假通过 —— 行数达标而不同照片数不达标。
    final List<String> eight = <String>[
      'p1', 'c01', 'c02', 'c03', 'c04', 'c05', 'c06', 'c07',
    ];
    expect(eight.length, 8, reason: '行数正好等于下限');
    expect(gate.distinctPhotoCount(rows(eight), ov), 7,
        reason: '行数 8、不同照片 7 —— 必须能分辨出来，否则下限形同虚设');

    // ③ 端到端：同一条记录，行数达标而不同照片不达标 → P0.1a 必须变红。
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      for (final String id in eight)
        item(id: id, corpus: 'anchor', truth: 3.0, source: 'pupil', applied: 3.0),
    ];
    final Map<String, dynamic> inp =
        inputs(compose: compose, measured: goodMeasured(compose));
    expect(row(gate.evaluateP0(inp), 'P0.1a')['pass'], false,
        reason: '8 行但只有 7 张不同照片，仍不得过 8 张不同照片的下限');

    // ④ 去重量具缺位/结论不完整 → **判不了**，不许退回行数。
    //    退回行数正是这条缺陷本身，所以这里必须 manual 而不是 pass。
    expect(gate.distinctPhotoCount(rows(eleven), null), isNull);
    expect(gate.distinctPhotoCount(rows(eleven), <String, dynamic>{}), isNull);
    expect(
        gate.distinctPhotoCount(
            rows(eleven),
            <String, dynamic>{
              'intra_duplicates': <dynamic>[<String, dynamic>{'a': 'c03'}],
            }),
        isNull,
        reason: '同图对字段不完整时也必须报判不了，不能当成"无重复"');
    final Map<String, dynamic> noOv =
        inputs(compose: goodCorpus(), measured: goodMeasured(goodCorpus()), overlap: null);
    final Map<String, dynamic> p1a = row(gate.evaluateP0(noOv), 'P0.1a');
    expect(p1a['pass'], false, reason: '去重量具缺位时不得判过');
    expect(p1a['manual'], true, reason: '去重量具缺位时必须显式报"判不了"');
  });

  // ---------------------------------------------------------------------
  // 判据分母（`out/P0_truth.json`）数值叶基线的**排除集**。
  //
  // 存在理由：`evaluatedState` 那一块记的是"这份文件在什么状态下收尾"
  // （`headAtFinalize`、`codeFingerprintAtFinalize.*`），是 **HEAD 与工作区的函数**。
  // r2 在 tag 之后重新生成该文件时它必然变，逐叶通道会真报差异——不是理论风险。
  // 所以主会话 2026-09-17 裁定：**只排这一块**。
  //
  // 豁免写歪的后果是把"判据输入可被改动而不响"重新打开，而那正是这个钉存在的原因。
  // 所以豁免的**每一条性质**都要有对照，尤其是**不许宽一个字节**：
  // 上一轮已经栽过三次"判据是条款的严格子集"（`lib` 域 29 vs 101、`files` 计数相等
  // 而集合不同、扫描范围漏掉 `tools/gate`），这里是第四次机会。
  group('判据分母数值叶基线：排除集', () {
    const String kTmp = 'out/tmp_gk_truth_test';
    const String kTruth = '$kTmp/truth.json';
    const String kBase = '$kTmp/leaves.txt';

    void writeTruth(Map<String, dynamic> m) {
      final File f = File(kTruth);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(m));
    }

    /// 基线用**门禁自己的抽叶函数**生成，不手搓格式 ——
    /// 手搓一份"我以为的"基线格式，测的是我的想象，不是生产路径。
    void writeBaseline(Map<String, dynamic> m) {
      final List<String> leaves = gate.numericLeaves(m)..sort();
      final File f = File(kBase);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('sha256=deadbeef\n${leaves.join("\n")}\n');
    }

    gate.TruthDrift drift() =>
        gate.truthDrift(truthPath: kTruth, baselinePath: kBase);

    tearDown(() {
      final Directory d = Directory(kTmp);
      if (d.existsSync()) d.deleteSync(recursive: true);
    });

    test('P 排除集被钉在**唯一命名的块**上（放宽必须在 diff 里可见）', () {
      // 这不是"测逻辑"，是把豁免本身钉住：谁想多豁免一处，必须先改这里，
      // 于是改动必然出现在 diff 里，而不是靠改数据悄悄做到。
      expect(gate.kTruthLeafExcludedPrefixes, <String>['evaluatedState'],
          reason: '这是**唯一**被允许的豁免块。加一条 = 放宽判据 = 必须留痕。'
              '真有必要加，请连同 docs/ACCEPTANCE.md 的说明一起改，别加个常量了事。');
    });

    test('Q 排除按**路径段**匹配：evaluatedStateX 不许被顺带豁免', () {
      // 该排的（真形状来自 out/P0_truth.json）。
      expect(gate.truthLeafExcluded('evaluatedState'), true);
      expect(gate.truthLeafExcluded('evaluatedState.files'), true);
      expect(gate.truthLeafExcluded('evaluatedState.codeFingerprintAtFinalize.files'), true);
      expect(gate.truthLeafExcluded('evaluatedState.roundChangedFiles[0]'), true);
      // **不该排的**：同前缀但不是那个块。子串匹配会误伤，这里钉死。
      expect(gate.truthLeafExcluded('evaluatedStateX'), false);
      expect(gate.truthLeafExcluded('evaluatedStateX.files'), false);
      expect(gate.truthLeafExcluded('myEvaluatedState.files'), false);
      expect(gate.truthLeafExcluded('anchors[0].truthTiltDeg'), false);
      expect(gate.truthLeafExcluded('straight'), false);
    });

    test('R 正向对照：evaluatedState 的数值叶变了 → 不报改动，但**必须逐条列出**', () {
      final Map<String, dynamic> before = <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'headAtFinalize': 'aaa',
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 29},
        },
      };
      writeBaseline(before);
      writeTruth(before);

      // 只有 evaluatedState 里的那个数值叶变了 —— 正是 r2 会真实发生的事。
      final Map<String, dynamic> after =
          jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
      (after['evaluatedState'] as Map<String, dynamic>)['codeFingerprintAtFinalize'] =
          <String, dynamic>{'files': 101};
      writeTruth(after);

      final gate.TruthDrift d = drift();
      expect(d.numericChanges, isEmpty,
          reason: '这一块的漂移是**预期的**（HEAD 的函数），不该判 FAIL；'
              '判了就是拿一个必然变化的东西当判据，等于每轮都红，'
              '红到后来就没人看了 —— 那是比不判更坏的结局');
      expect(d.leafCount, 1, reason: '参与比对的只剩 anchors[0].truthTiltDeg');
      expect(d.excludedLeafPaths, <String>['evaluatedState.codeFingerprintAtFinalize.files'],
          reason: '**排除必须被打印**：命名、钉住、打印。'
              '静默跳过的豁免和一个没写出来的豁免是一样的');
    });

    test('R2 深层排除不误伤兄弟：同一份文件里换个判据输入改了 → 必须红', () {
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'c06', 'truthTiltDeg': -15.424},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 29},
        },
      });
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'c06', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 101},
        },
      });
      final gate.TruthDrift d = drift();
      expect(d.numericChanges, <String>['anchors[0].truthTiltDeg: -15.424 → -4.4'],
          reason: '改真值让不合格样本过关，是这个钉**唯一**要拦的事。'
              '它必须在豁免生效的同时照旧拦住 —— 否则豁免就不是豁免，是拆门');
    });

    test('S 两侧同用：基线里有、现值里没有 → 不许报成"删除"（纯假阳性）', () {
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 29},
        },
      });
      // 现值里这一项变成了字符串（不再是数值叶）——
      // 生产者换个写法就会这样，什么都没做错。
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': '101'},
        },
      });
      final gate.TruthDrift d = drift();
      expect(d.numericChanges, isEmpty,
          reason: '只过滤当前侧的话，基线里那个叶子会被报成'
              '「evaluatedState.codeFingerprintAtFinalize.files: 删除（原 29）」——'
              '一个看起来像"有人动过判据输入"的假阳性。'
              '排除的定义是"这块不参与比对"，对两侧必须对称');
    });

    test('T 豁免清单在"排除 0 个"时**也要打印**，且必须点名排除集', () {
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      final gate.TruthDrift d = drift();
      expect(d.excludedLeafPaths, isEmpty);
      final String n = d.exclusionNote();
      expect(n.contains('实际排除 0 个'), true,
          reason: '一条只在非空时才出现的说明，读者分不清"没有豁免"和"豁免没被打印"。'
              '豁免清单必须每轮出现，哪怕内容是 0');
      expect(n.contains('evaluatedState'), true,
          reason: '要点名**排除集本身**，不只报个数 —— 只看个数看不出豁免了什么');
      expect(d.describe().contains('evaluatedState'), true,
          reason: 'AC 条目里渲染的是 describe()，豁免说明必须跟着进报告');
    });

    test('U 端到端：判据分母被改一个数 → 报告文本里看得见，且判 FAIL 的原料齐备', () {
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{'files': 29},
      });
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': 0.0},
        ],
        'evaluatedState': <String, dynamic>{'files': 101},
      });
      final gate.TruthDrift d = drift();
      expect(d.numericChanges.isNotEmpty, true);
      final String s = d.describe();
      expect(s.contains('truthTiltDeg'), true, reason: '要指名道姓，不是"有 1 处改动"');
      expect(s.contains('改动了'), true);
      expect(s.contains('evaluatedState'), true, reason: '同一句里也要带上豁免说明');
    });

    test('V 渲染：缺输入 → 判不了（不许默认清白）；有输入 → 豁免逐条印出来', () {
      // 缺输入时必须显式说"判不了"，而不是渲染成空串 —— 空串在报告里
      // 与"这一节没内容"长得一模一样。
      final String missing = gate.truthPinMdSection(null);
      expect(missing.contains('无法证明'), true);
      expect(missing.contains('不判通过'), true);

      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 29},
        },
      });
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 101},
        },
      });
      final String md = gate.truthPinMdSection(drift());
      // 每一条豁免都要能被读者看见，而不是"排除了 1 个"了事。
      expect(md.contains('evaluatedState.codeFingerprintAtFinalize.files'), true,
          reason: '被排除的路径要逐条印出来');
      expect(md.contains('kTruthLeafExcludedPrefixes'), true,
          reason: '要写明排除集定义在哪，读者才能去查它受不受条款 2 保护');
      expect(md.contains('SHA256'), true);
      // 这条附注是这个豁免最容易被误读的地方：叶没变 ≠ 数据仍然成立。
      expect(md.contains('不是"数据仍然成立"的证据') || md.contains('证据仍然有效'), true,
          reason: '必须写明"叶哈希未变 ≠ 证据仍然有效"，'
              '否则下一轮就会有人拿"叶没变"论证数据没问题');
      expect(md.contains('c06_d-3'), true, reason: '附注要带可复核的实例，不是泛泛而谈');
      expect(md.contains('-15.424'), true);
      // 渲染事故的回归：`'$b.path'` 曾渲染成 `Instance of ...`。
      expect(md.contains('Instance of'), false);
    });

    test('W 删掉基线文件 = 重置锚点：必须买不到"本轮免疫"', () {
      // 这是我**在自己门禁里找到的洞**，不是设想的：
      // `truthDrift` 在基线文件不存在时会建立一份新的并返回 `baselineEstablished: true`，
      // 而旧措辞是"本轮不判 FAIL"。于是
      //     del out\hashes_P0_truth_leaves_baseline.txt
      // 一步就能把"改过判据分母"洗掉 —— 比改一个数容易得多，
      // 且与 `kTruthPath` 当初两边都不在是同一个洞，只换了入口。
      //
      // 现在的规则：重建轮**整轮作废**。删文件买到的是 void，不是放过。
      final Directory d = Directory(kTmp);
      if (d.existsSync()) d.deleteSync(recursive: true);
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      final gate.TruthDrift fresh = drift();
      expect(fresh.baselineEstablished, true, reason: '文件不存在 → 本轮只能重建');
      expect(File(kBase).existsSync(), true, reason: '重建要真的把锚落盘，否则永远重建');
      expect(fresh.describe().contains('不判 FAIL'), false,
          reason: '**不许再出现"本轮不判 FAIL"** —— 这句话就是那条绕过路径的门');
      expect(fresh.describe().contains('整轮作废'), true);

      // 端到端：重建轮必须整轮作废，且**不许**消耗实现方的修复轮次。
      final List<Map<String, dynamic>> compose = goodCorpus();
      final Map<String, dynamic> inp =
          inputs(compose: compose, measured: goodMeasured(compose));
      inp['truthDriftResult'] = fresh;
      final List<Map<String, dynamic>> items = gate.evaluateP0(inp);
      expect(items.every((Map<String, dynamic> i) => i['roundInvalid'] == true), true,
          reason: '锚被重建的那一轮不作判决');
      expect(items.every((Map<String, dynamic> i) => i['pass'] != true), true,
          reason: '作废轮一项都不许判 PASS');
      expect(items.every((Map<String, dynamic> i) => i['manual'] == true), true,
          reason: '作废轮是 MANUAL，不消耗实现方的修复预算');
      expect((items.first['actual'] as String).contains('重建'), true,
          reason: '要写明是重建轮，不能让人以为是普通作废');
    });

    test('X 基线文件本身在受钉之列（改它 / 删它都要看得见）', () {
      // 只把 `kTruthPath` 放进受钉集是不够的：钉的**锚**不受钉，
      // 绕过就只是"删一个文件"。
      expect(gate.kPinnedJudgmentInputs, contains(gate.kTruthPath));
      expect(gate.kPinnedJudgmentInputs, contains(gate.kTruthLeavesBaselinePath),
          reason: '锚必须在受钉集里，否则删掉它 = 重置 = 免疫');
    });
  });
}
