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

import '../../tools/gate/anticheat.dart' as ac;
import '../../tools/gate/gate_P0.dart' as gate;
import '../../tools/gate/sha256.dart' as sha;

const String kSpec = 'cn_big_1inch';

/// 一条"生产记录 + 独立测量"的组合。字段名与 out/P0_compose_items.jsonl 一致。
///
/// [est] 是引擎**自报**的倾角估计（`FaceInfo.rollDeg` → compose 记录的 `faceRollDeg`）。
/// 它是**独立于 [applied] 的一个输入**，不能由 [applied] 反推 —— P0.6 的主判据问的
/// 正是"引擎有没有照它**自己报的角**行事"，反推的话那条判据就退化成恒真。
/// 缺省 = 真值（合格实现下自报 ≈ 真值）；`unavailable` 的样本可以不给（＝读不到自报角）。
Map<String, dynamic> item({
  required String id,
  required String corpus,
  required double truth,
  required String source,
  required double applied,
  double? est,
}) =>
    <String, dynamic>{
      'id': id,
      'corpus': corpus,
      'truthTiltDeg': truth,
      'rollSource': source,
      'straightenDeg': applied,
      'specId': kSpec,
      'faceRollDeg': est ?? truth,
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
  /// 生成分母 vs 手写分母的逐条比对结论。真实内容由 `denominatorAgreement()`
  /// 产出；本文件测的是**判定函数怎么用这个结论**，结论本身怎么算出来由下面
  /// 那一组用例负责。
  Object? denominatorAgreement = const <String, dynamic>{
    'readable': true,
    'pass': true,
    'problems': <String>[],
    'extraUndeclared': <String>[],
    'summary': '测试桩：逐条相等',
  },
  /// 派生块证据溯源的结论。同上。
  Object? evidenceProvenance = const <String, dynamic>{
    'readable': true,
    'pass': true,
    'problems': <String>[],
    'summary': '测试桩：逐份相符',
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
    'denominatorAgreement': denominatorAgreement,
    'evidenceProvenance': evidenceProvenance,
    'roundState': roundState ?? goodRoundState(),
  };
}

Map<String, dynamic> row(List<Map<String, dynamic>> items, String id) =>
    items.firstWhere((Map<String, dynamic> i) => i['id'] == id);

/// 造一整套"合格实现"的记录：12 条倾斜锚点 + p2 竖直 + 9 张合成竖直 + 旋转夹具。
///
/// **"合格"的口径必须跟着判据走，而判据在 v2（冻结于 `d4fb782`）里改过**：
/// 死区从 1° 放到 **10°**（`kDeadZoneDeg`），并新增 P0.6「死区内不得被转动」。
/// 本夹具原先按 1° 死区写（`|真值| > 1°` 就施加旋转），于是：
///   · P0.1a 的 `|残余 − 真值|` 在 p1/c04/c07 上读到 4.4 / 8.01 度 → 假 FAIL；
///   · P0.6 的次判据把 16 条"在死区内老老实实转过的"样本全判违规。
/// **那不是门禁宁枉勿纵，是夹具比判据旧了一版。** 这里把它对齐到 v2：
/// 施加与否一律按 `kDeadZoneDeg` 分档，自报角（`est`）＝ 真值。
List<Map<String, dynamic>> goodCorpus() {
  final List<Map<String, dynamic>> c = <Map<String, dynamic>>[];
  const List<double> truth = <double>[4.4, -1.3, 0.25, 3.72, 8.01, 1.73, 0.35, 8.01, 3.44, 0.11, 2.09, 3.91];
  for (int i = 0; i < truth.length; i++) {
    final String id = i == 0 ? 'p1' : 'c${i.toString().padLeft(2, '0')}';
    // 合格实现：真值全落在 10° 死区内 ⇒ 一律不施加旋转（"没被乱动"）。
    final double applied = truth[i].abs() > gate.kDeadZoneDeg ? truth[i] : 0.0;
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
        applied: t.abs() > gate.kDeadZoneDeg ? t : 0.0,
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
    // 记录**原样保留**（这三行就是 2026-09-17 的现场），但断言按 v2 口径重新对位。
    //
    // v2 把死区从 1° 放到 10°，于是这场事故分成两半，两半的账不一样：
    //   · **仍然违规的一半**：p2 真值 −0.2°（本来就竖直）被转歪 3.65°。
    //     死区内被转动，v1/v2 都违规 —— 这是本用例真正要钉的那一条。
    //   · **被 v2 明文豁免的一半**：p1/c03 真值 −4.4°/−3.72°，`unavailable` 没转，
    //     成片仍歪着真值那个角。它们在 v1（死区 1°）下是"该摆正却说测不出"的违规，
    //     在 v2 下**落在死区内 ⇒ 按 ACCEPTANCE 口径 2 可接受**。
    //     ⇒ 本用例断言 P0.1b **在**这里给出"豁免"，而不是断言它 FAIL。
    //     这一条是有意加的：豁免生效与"这条判据根本没跑"在报告里长得一模一样，
    //     不写死一条断言，就没法把它俩分开。（这也是本文件存在的理由本身。）
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      // p1：旧估角器给出 +0.84（落进死区）→ 不转；真值 −4.4，成片仍歪 −4.4
      item(id: 'p1', corpus: 'anchor', truth: -4.4, source: 'unavailable', applied: 0.0),
      // p2：旧估角器给出 −3.85 → 转歪；真值 −0.2 → 成片残余 +3.65
      item(id: 'p2', corpus: 'straight', truth: -0.2, source: 'pupil', applied: -3.85, est: -3.85),
      item(id: 'c03', corpus: 'anchor', truth: -3.72, source: 'unavailable', applied: 0.0),
    ];
    final Map<String, double> m = <String, double>{
      'p1': -4.4, // 成片仍歪 −4.4
      'p2': 3.65, // 成片被转歪 +3.65
      'c03': -3.72,
    };
    final List<Map<String, dynamic>> items =
        gate.evaluateP0(inputs(compose: compose, measured: m));

    // p2 被转歪 3.65°。
    expect(row(items, 'P0.2')['pass'], false, reason: '转歪了竖直样本，必须 FAIL');
    // 同一件事在 P0.6 上必须也被抓住：自报 −3.85°（死区内）却施加了 −3.85°。
    final Map<String, dynamic> p06 = row(items, 'P0.6');
    expect(p06['pass'], false, reason: '死区内被转动，必须 FAIL');
    expect((p06['actual'] as String).contains('p2'), true,
        reason: '违规必须点名到样本，否则读者不知道该看哪一张');
    // p1/c03 的豁免必须**写明**，不许与"这条判据没跑"同形。
    final String p01b = row(items, 'P0.1b')['actual'] as String;
    expect(p01b.contains('按口径 2 可接受'), true,
        reason: '死区内的 unavailable 是 ACCEPTANCE 明文豁免；报告不写这一句，'
            '读者分不清"豁免生效"与"这一栏根本没判"');
    expect(p01b.contains('p1') && p01b.contains('c03'), true,
        reason: '豁免要逐条点名，不是给一个数');
  });

  test('B 合格实现必须全 PASS（门禁不能宁枉勿纵到谁都过不了）', () {
    // **这条用例守的是什么，以及它守不到什么。**
    // 守：判定的**逻辑** —— 一份"按当前判据算合格"的语料必须让每一项都能到
    // pass=true，且 MANUAL 项**恰好**只有 P0.5c（它必须重跑上游才有读数）。
    // 一个恒 MANUAL 的项会让整轮永远不能 PASS（`_finish` 的
    // `allPass = every(pass == true)`），本文件历史上已经栽过两次
    // （P0.1b 恒 MANUAL、P0.5c 恒 exit 1）——这条用例就是防它第三次。
    //
    // **守不到**：`kDeadZoneDeg`（10°）这个**值本身**。语料是从生产常量取的
    // （`goodCorpus()` 里 `applied = |真值| > gate.kDeadZoneDeg ? … : 0`），
    // 常量改了语料跟着改，这条用例照样绿。**它不保护 10° 这个数** ——
    // 那个数由 ACCEPTANCE 的冻结文本与用户的产品决定守着。
    // 写在这里，免得下一个人以为"B 是绿的"等于"死区是 10° 被验过了"。
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
    // 挑一条**死区外**（|真值| > 10°）的夹具。死区内的样本本来就不该转，
    // 把它们改成 unavailable 是豁免项、不进 P0.3b 的判定集 —— 原先这里挑的
    // 是真值 5.6° 的那条，在 v1（死区 1°）下在判定集里，在 v2 下不在。
    const String kVictim = 'f-4.4_d-10.0'; // 真值 −14.4°
    final int i = compose.indexWhere((Map<String, dynamic> c) => c['id'] == kVictim);
    expect(i >= 0, true, reason: '夹具里必须有这条，否则本用例测的是空气');
    expect((compose[i]['truthTiltDeg'] as double).abs() > gate.kDeadZoneDeg, true,
        reason: '必须挑死区外的夹具，否则它根本不进 P0.3b 的判定集');
    compose[i]['rollSource'] = 'unavailable';
    compose[i]['straightenDeg'] = 0.0;
    m[kVictim] = -14.4; // 成片实测仍歪 14.4°
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
  // 判据分母的钉子：**钉哪个文件、换目标怎么处理、改了一个数怎么报**。
  //
  // 2026-09-17 主会话裁定换了钉子对象：内容钉从**生成**的 `out/P0_truth.json`
  // 换到**手写**的 `out/P0_truth_v0.json`。理由两条：
  //   · 生成件含每轮必变的溯源块（`evaluatedState`：`headAtFinalize`、
  //     `codeFingerprintAtFinalize.*`），钉它就得在**判据分母**上永久开一个
  //     不受内容钉保护的洞，还要靠 review 兜；
  //   · 改 v0 才是"改判据分母"的正路 —— 钉产物钉不住动机。
  //
  // **保护没减少，换了形式**：整文件字节相等 → ①分母一致性（生成件 vs 手写件
  // 逐条）②派生数字的证据溯源（叙述 vs 盘上产物）。前者的覆盖其实更宽：
  // 它不只知道"数变了"，还知道**变的是哪一条的哪个字段**。
  //
  // 这一组同时钉住"换目标"这个动作本身：换目标要**两件事同时成立** ——
  // 变更在代码里（受条款 2 的 SHA256 保护）**且** `旧 -> 新` 这一对在
  // `kPinRetargetLedger` 里登记过理由。只做到前者，等于把"删掉基线文件重设锚"
  // 换成"改一个常数重设锚"，同一条绕过路径换了个入口。
  //
  // 排除集机制**保留但当前为空**（v0 是人写的，里面没有一块该豁免）。
  // 机制本身照旧可测：`truthLeafExcluded` / `truthDrift` 都接受显式前缀表，
  // 于是"哪天真要豁免"时那段代码不是没人跑过的。
  group('判据分母的钉子与两道替代保护', () {
    const String kTmp = 'out/tmp_gk_truth_test';
    const String kTruthV0 = '$kTmp/truth_v0.json';
    const String kGen = '$kTmp/truth_gen.json';
    const String kBase = '$kTmp/leaves.txt';
    // 排除集机制的对照用表。生产路径上是**空的**（见 P'）。
    const List<String> kLegacy = <String>['evaluatedState'];

    void writeJson(String path, Map<String, dynamic> m) {
      final File f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(m));
    }

    void writeTruth(Map<String, dynamic> m) => writeJson(kTruthV0, m);

    /// 基线用**门禁自己的抽叶函数**生成，不手搓格式 ——
    /// 手搓一份"我以为的"基线格式，测的是我的想象，不是生产路径。
    /// `pin=` 行必须写：没有它，锚就不知道自己钉的是哪个文件。
    void writeBaseline(Map<String, dynamic> m, {String pin = kTruthV0}) {
      final List<String> leaves = gate.numericLeaves(m)..sort();
      final File f = File(kBase);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
          'sha256=deadbeef\n${gate.kPinStampPrefix}$pin\n${leaves.join("\n")}\n');
    }

    gate.TruthDrift drift({List<String> prefixes = gate.kTruthLeafExcludedPrefixes}) =>
        gate.truthDrift(
            truthPath: kTruthV0, baselinePath: kBase, excludedPrefixes: prefixes);

    tearDown(() {
      final Directory d = Directory(kTmp);
      if (d.existsSync()) d.deleteSync(recursive: true);
    });

    test("P' 钉子对象是**手写件**，生成件不在受钉集里，且排除集为空", () {
      // 把钉子本身钉住：谁想换目标或加豁免，必须先改这里，于是改动必然出现在
      // diff 里，而不是靠改数据悄悄做到。
      expect(gate.kPinnedJudgmentInputs, contains(gate.kTruthV0Path),
          reason: '内容钉要钉**手写**分母 —— 那才是"改一个真值让不合格样本过关"的正路');
      expect(gate.kPinnedJudgmentInputs, isNot(contains(gate.kTruthPath)),
          reason: '生成件是**产出**：它每轮重生成，钉它只会每轮报一次假阳性。'
              '它由 `denominatorAgreement` 按条目对，不是按字节对');
      expect(gate.kTruthLeafExcludedPrefixes, isEmpty,
          reason: '手写分母里**没有一块该豁免**。非空 = 判据分母上有个洞，'
              '加一条必须留痕并说明为什么那个块不是判据输入');
      expect(gate.kPinRetargetLedger.containsKey('${gate.kTruthPath} -> ${gate.kTruthV0Path}'),
          true,
          reason: '这次换目标本身必须登记 —— 否则"改常数重设锚"就是一条新绕过路径');
    });

    test("Q' 排除按**路径段**匹配：evaluatedStateX 不许被顺带豁免", () {
      // 机制在，只是生产上不启用（空表）。用显式前缀表验它的行为。
      expect(gate.truthLeafExcluded('evaluatedState', prefixes: kLegacy), true);
      expect(gate.truthLeafExcluded('evaluatedState.files', prefixes: kLegacy), true);
      expect(
          gate.truthLeafExcluded('evaluatedState.codeFingerprintAtFinalize.files',
              prefixes: kLegacy),
          true);
      expect(gate.truthLeafExcluded('evaluatedState.roundChangedFiles[0]', prefixes: kLegacy),
          true);
      // **不该排的**：同前缀但不是那个块。子串匹配会误伤，这里钉死。
      expect(gate.truthLeafExcluded('evaluatedStateX', prefixes: kLegacy), false);
      expect(gate.truthLeafExcluded('evaluatedStateX.files', prefixes: kLegacy), false);
      expect(gate.truthLeafExcluded('myEvaluatedState.files', prefixes: kLegacy), false);
      expect(gate.truthLeafExcluded('anchors[0].truthTiltDeg', prefixes: kLegacy), false);
      expect(gate.truthLeafExcluded('straight', prefixes: kLegacy), false);
      // 生产路径（空表）：上面全部为假。
      expect(gate.truthLeafExcluded('evaluatedState.files'), false,
          reason: '当前**一个都不排** —— 这是收紧，不是放宽');
    });

    test("R' 排除机制的正向对照：被排的块变了 → 不报改动，但**必须逐条列出**", () {
      final Map<String, dynamic> before = <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
        'evaluatedState': <String, dynamic>{
          'codeFingerprintAtFinalize': <String, dynamic>{'files': 29},
        },
      };
      writeBaseline(before);
      writeTruth(before);
      final Map<String, dynamic> after =
          jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
      (after['evaluatedState'] as Map<String, dynamic>)['codeFingerprintAtFinalize'] =
          <String, dynamic>{'files': 101};
      writeTruth(after);

      final gate.TruthDrift d = drift(prefixes: kLegacy);
      expect(d.numericChanges, isEmpty,
          reason: '被排的块不参与比对 —— 但**只有显式排了才这样**，'
              '默认（空表）下它就必须红');
      expect(d.leafCount, 1, reason: '参与比对的只剩 anchors[0].truthTiltDeg');
      expect(d.excludedLeafPaths,
          <String>['evaluatedState.codeFingerprintAtFinalize.files'],
          reason: '**排除必须被打印**：命名、钉住、打印。'
              '静默跳过的豁免和一个没写出来的豁免是一样的');

      // 同一份数据、**不排**任何前缀 → 必须红。这是"排了"与"没排"的对照，
      // 否则上面那个 isEmpty 分不清"排掉了"和"根本没看"。
      final gate.TruthDrift d0 = drift(prefixes: const <String>[]);
      expect(d0.numericChanges.isNotEmpty, true,
          reason: '不排就该看见 —— 生产路径正是这一档');
    });

    test("R2' 深层排除不误伤兄弟：同一份文件里换个判据输入改了 → 必须红", () {
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
      final gate.TruthDrift d = drift(prefixes: kLegacy);
      expect(d.numericChanges, <String>['anchors[0].truthTiltDeg: -15.424 → -4.4'],
          reason: '改真值让不合格样本过关，是这个钉**唯一**要拦的事。'
              '它必须在豁免生效的同时照旧拦住 —— 否则豁免就不是豁免，是拆门');
    });

    test("S' 两侧同用：基线里有、现值里没有 → 不许报成「删除」（纯假阳性）", () {
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
          'codeFingerprintAtFinalize': <String, dynamic>{'files': '101'},
        },
      });
      final gate.TruthDrift d = drift(prefixes: kLegacy);
      expect(d.numericChanges, isEmpty,
          reason: '只过滤当前侧的话，基线里那个叶子会被报成'
              '「evaluatedState.codeFingerprintAtFinalize.files: 删除（原 29）」——'
              '一个看起来像"有人动过判据输入"的假阳性。'
              '排除的定义是"这块不参与比对"，对两侧必须对称');
    });

    test("T' 排除清单在「排除 0 个」时**也要打印**，且要点名排除集本身", () {
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
      expect(n.contains('空'), true,
          reason: '一条只在非空时才出现的说明，读者分不清"没有豁免"和"豁免没被打印"。'
              '豁免清单必须每轮出现，哪怕内容是 0');
      final String n2 = drift().describe();
      expect(n2.contains('排除集'), true,
          reason: 'AC 条目里渲染的是 describe()，豁免说明必须跟着进报告');
    });

    test("U' 端到端：手写分母被改一个数 → 报告文本里看得见，且判 FAIL 的原料齐备", () {
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': 0.0},
        ],
      });
      final gate.TruthDrift d = drift();
      expect(d.numericChanges.isNotEmpty, true);
      final String s = d.describe();
      expect(s.contains('truthTiltDeg'), true, reason: '要指名道姓，不是"有 1 处改动"');
      expect(s.contains('改动了'), true);
      expect(s.contains('排除集'), true, reason: '同一句里也要带上豁免说明');
      expect(s.contains(kTruthV0), true, reason: '要写明钉的是哪个文件');
    });

    test("V' 渲染：缺输入 → 判不了（不许默认清白）；有输入 → 钉子与豁免都印出来", () {
      final String missing = gate.truthPinMdSection(null);
      expect(missing.contains('无法证明'), true);
      expect(missing.contains('不判通过'), true);

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
      final String md = gate.truthPinMdSection(drift());
      expect(md.contains(gate.kTruthV0Path), true, reason: '要写明钉子对象是哪个文件');
      expect(md.contains('本轮未变'), true,
          reason: '钉子对象没换也要**显式说没换** —— 只在变了时才出现的说明，'
              '读者分不清"没换"与"换了没印"');
      expect(md.contains('kTruthLeafExcludedPrefixes'), true,
          reason: '要写明排除集定义在哪，读者才能去查它受不受条款 2 保护');
      expect(md.contains('SHA256'), true);
      // 换目标的两条件必须写在报告里，否则读的人以为改常数就能换。
      expect(md.contains('kPinRetargetLedger'), true);
      // 内容钉覆盖不到的地方要**主动列出**，不能留给人自己发现。
      expect(md.contains('convention'), true,
          reason: '字符串字段（convention/generatedBy/baselineTag/version）不在内容钉里，'
              '这是已知缺口，必须写在报告里而不是藏着');
      expect(md.contains('已知缺口'), true);
      // 这条附注是这个豁免最容易被误读的地方：叶没变 ≠ 数据仍然成立。
      expect(md.contains('不是"数据仍然成立"的证据') || md.contains('证据仍然有效'), true,
          reason: '必须写明"叶哈希未变 ≠ 证据仍然有效"，'
              '否则下一轮就会有人拿"叶没变"论证数据没问题');
      expect(md.contains('c06_d-3'), true, reason: '附注要带可复核的实例，不是泛泛而谈');
      expect(md.contains('-15.424'), true);
      expect(md.contains('Instance of'), false,
          reason: '渲染事故的回归：StringBuffer 插值写歪时曾渲染出 Instance of ...');
    });

    test("W' 删掉基线文件 = 重置锚点：必须买不到「本轮免疫」", () {
      // 这是我在自己门禁里找到的洞，不是设想的：
      //     del out\hashes_P0_truth_leaves_baseline.txt
      // 旧措辞是"本轮不判 FAIL"，于是删一个文件就能把"改过判据分母"洗掉。
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

    test("X' 基线文件本身在受钉之列（改它 / 删它都要看得见）", () {
      expect(gate.kPinnedJudgmentInputs, contains(gate.kTruthLeavesBaselinePath),
          reason: '锚必须在受钉集里，否则删掉它 = 重置 = 免疫');
    });

    // ---- 换钉子对象：两种情形都要有对照 ----

    test("AA 基线带 pin= 行：目标一致 → 走正常比对，不报换靶", () {
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      final gate.TruthDrift d = drift();
      expect(d.pinRetargeted, false);
      expect(d.pinRetargetUndeclared, isNull);
      expect(d.pinFrom, kTruthV0);
      expect(d.pinTo, kTruthV0);
      expect(d.numericChanges, isEmpty);
      expect(d.describe().contains('本轮未变'), true);
    });

    test("AB 换目标但**没登记** → 必须判违规（不许静默重设锚）", () {
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      // 基线是给**另一个**文件建的，而那个 `旧 -> 新` 对不在登记簿里。
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      }, pin: '$kTmp/some_other_truth.json');
      final gate.TruthDrift d = drift();
      expect(d.pinRetargetUndeclared, isNotNull,
          reason: '换目标要**两件事同时成立**：变更在代码里 + 这一对登记过理由。'
              '只做到前者 = 把"删掉基线文件重设锚"换成"改常数重设锚"');
      expect(d.pinRetargeted, false);
      expect(d.describe().contains('未登记'), true);
      expect(d.describe().contains('kPinRetargetLedger'), true);
    });

    test("AC 换目标且**已登记** → 重钉锚，本轮不报数值差异，且原样印出来", () {
      // 用登记簿里真实的那一对：旧 = 生成的真值文件，新 = 手写真值文件。
      writeTruth(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': -4.4},
        ],
      });
      // 基线里存的是**另一份**文件的叶子（故意与现值的数不同），
      // 若无条件比对会报一堆"改动" —— 那些"改动"全是假的。
      writeBaseline(<String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'truthTiltDeg': 99.0},
        ],
      }, pin: gate.kTruthPath);
      // 目标必须是**登记簿里那一对**的新端（`kTruthV0Path`），不能用临时路径：
      // 用临时路径测的就是"未登记"那一档，与 AB 重复了。
      gate.TruthDrift d() =>
          gate.truthDrift(truthPath: gate.kTruthV0Path, baselinePath: kBase);
      expect(d().pinRetargeted, true);
      expect(d().pinRetargetUndeclared, isNull);
      expect(d().numericChanges, isEmpty,
          reason: '锚是新的，本轮没有可比对象；拿旧锚的叶子报"改动"是纯假阳性');
      expect(File(kBase).readAsStringSync().contains(gate.kPinStampPrefix + gate.kTruthV0Path),
          true,
          reason: '重钉要真的落盘，否则每一轮都重钉一次');
      // 第二次读：pin 已前移，不再报换靶 —— 但**换靶这件事必须还看得见**。
      final gate.TruthDrift d2 = d();
      expect(d2.pinRetargeted, false);
      expect(d2.retargetHistory, <String>['${gate.kTruthPath} -> ${gate.kTruthV0Path}'],
          reason: '换靶历史要落盘并且**只增不删**。只写在当轮报告里的话，'
              '一次"改常数重设锚"熬过当轮就在此后所有报告里彻底消失');
      expect(d2.describe().contains('本轮未变'), true);
      expect(d2.describe().contains(gate.kTruthV0Path), true,
          reason: '钉子对象是哪个文件，每轮都要说');
      expect(d2.describe().contains('换靶历史'), true);
    });

    // ---- 替代保护①：生成件 vs 手写件，逐条 ----

    Map<String, dynamic> v0Doc() => <String, dynamic>{
          'anchors': <dynamic>[
            <String, dynamic>{'id': 'p1', 'trueRollDeg': -4.4, 'eyedistPx': 412.0},
            <String, dynamic>{'id': 'c01', 'trueRollDeg': 3.72, 'eyedistPx': 388.0},
          ],
          'straight': <dynamic>[
            <String, dynamic>{'id': 'p2', 'trueRollDeg': -0.2},
          ],
          'nonPortrait': <dynamic>['C:/x/a.jpeg', 'C:/x/b.jpeg'],
        };

    test('AD 分母一致：生成件改了手写件里的一个真值 → 必须逐条报出来', () {
      writeJson(kTruthV0, v0Doc());
      final Map<String, dynamic> gen =
          jsonDecode(jsonEncode(v0Doc())) as Map<String, dynamic>;
      ((gen['anchors'] as List<dynamic>)[0] as Map<String, dynamic>)['trueRollDeg'] = -1.0;
      writeJson(kGen, gen);
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.readable, true);
      expect(a.pass, false);
      expect(a.problems.any((String s) =>
          s.contains('anchors/p1.trueRollDeg') && s.contains('-4.4')), true,
          reason: '要指名道姓到"哪一条的哪个字段"，不是"不相等"了事');
      expect(a.summary().contains('anchors=2'), true, reason: '比了多少条要能被看见');
    });

    test('AE 分母一致：生成件**丢了一条** → 整条缺失必须报出来', () {
      writeJson(kTruthV0, v0Doc());
      final Map<String, dynamic> gen =
          jsonDecode(jsonEncode(v0Doc())) as Map<String, dynamic>;
      (gen['anchors'] as List<dynamic>).removeAt(1);
      writeJson(kGen, gen);
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.pass, false);
      expect(a.problems.any((String s) => s.contains('anchors/c01') && s.contains('缺失')),
          true);
    });

    test('AF 分母一致：生成件**凭空多出一条** → 未登记，判违规', () {
      writeJson(kTruthV0, v0Doc());
      final Map<String, dynamic> gen =
          jsonDecode(jsonEncode(v0Doc())) as Map<String, dynamic>;
      (gen['anchors'] as List<dynamic>)
          .add(<String, dynamic>{'id': 'ghost', 'trueRollDeg': 0.1});
      writeJson(kGen, gen);
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.pass, false,
          reason: '凭空加一条分母 = 改判据的分母。这正是内容钉改钉手写件之后'
              '必须由这条补上的保护');
      expect(a.extraUndeclared.any((String s) => s.contains('anchors/ghost')), true);
    });

    test('AG 分母一致：登记过、且在 v0 出现过的条目才允许多出来', () {
      writeJson(kTruthV0, v0Doc());
      final Map<String, dynamic> gen =
          jsonDecode(jsonEncode(v0Doc())) as Map<String, dynamic>;
      // `p2` 在 v0 的 `straight` 里，生成件把它并进 `anchors` —— 这是已知形状。
      (gen['anchors'] as List<dynamic>)
          .add(<String, dynamic>{'id': 'p2', 'trueRollDeg': -0.2});
      writeJson(kGen, gen);
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.extraAllowed, <String>['anchors/p2']);
      expect(a.extraUndeclared, isEmpty);
      expect(a.pass, true, reason: '并集化是已知且被审过的形状，不算改动分母');
      // 反向对照：**登记了但 v0 里根本没有这个 id** → 仍然不许。
      final Map<String, dynamic> gen2 =
          jsonDecode(jsonEncode(v0Doc())) as Map<String, dynamic>;
      writeJson(kGen, gen2);
      final gate.DenominatorAgreement a2 =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a2.pass, true, reason: '没有多出来的条目就是相等');
    });

    test('AH 分母一致：读不到手写件 → 不可判，**不默认相等**', () {
      writeJson(kGen, v0Doc());
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.readable, false);
      expect(a.pass, false);
      expect(a.summary().contains('不可判'), true);
    });

    test('AH2 路径的两种写法（仓库相对 vs 盘上绝对）是**同一个文件**，不报', () {
      // 实测形状：手写件记 `out/P0_anchors/c01_d+3.png`，生成件记
      // `C:/Users/.../out/P0_anchors/c01_d+3.png`。对它报 FAIL 是纯假阳性，
      // 而一个在诚实数据上永远红的检查，最后一定会被豁免掉。
      writeJson(kTruthV0, <String, dynamic>{
        'rotated': <dynamic>[
          <String, dynamic>{'id': 'p1_d+3', 'path': 'out/P0_anchors/p1_d+3.png'},
        ],
      });
      writeJson(kGen, <String, dynamic>{
        'rotated': <dynamic>[
          <String, dynamic>{
            'id': 'p1_d+3',
            'path': 'C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/P0_anchors/p1_d+3.png',
          },
        ],
      });
      final gate.DenominatorAgreement ok =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(ok.pass, true, reason: '同一份文件的两个写法，不是分母改动');
      expect(ok.problems, isEmpty);

      // 归一化是**收窄**：去掉前缀之后必须逐字符相等 —— 指到别的文件上照样红。
      writeJson(kGen, <String, dynamic>{
        'rotated': <dynamic>[
          <String, dynamic>{
            'id': 'p1_d+3',
            'path': 'C:/Users/liuyu/Desktop/WorkPlace/idPhotos/out/P0_anchors/p1_d-3.png',
          },
        ],
      });
      final gate.DenominatorAgreement bad =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(bad.pass, false, reason: 'd+3 与 d-3 是两个文件，前缀一样也不行');
      expect(bad.problems.any((String s) => s.contains('p1_d+3.path')), true);
    });

    test('AH3 形状豁免**必须打印**；未登记的形状差异一律报出来', () {
      // 登记过的字段（`methods`：简表 vs 逐量具记录）跳过，但**跳过本身要看得见**。
      writeJson(kTruthV0, <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'methods': <String>['a', 'b']},
        ],
      });
      writeJson(kGen, <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{
            'id': 'p1',
            'methods': <dynamic>[
              <String, dynamic>{'name': 'm1'},
              <String, dynamic>{'name': 'm2'},
              <String, dynamic>{'name': 'm3'},
            ],
          },
        ],
      });
      final gate.DenominatorAgreement a =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(a.pass, true);
      expect(a.shapeSkipped['methods'], 1);
      expect(a.summary().contains('methods×1'), true,
          reason: '**豁免了多少次要印出来** —— 一条只在"没豁免时"才不出现的说明，'
              '读者分不清"没豁免"与"豁免没被打印"');
      expect(a.summary().contains('kDenominatorShapeAllowance'), true,
          reason: '要写明豁免表定义在哪，读者才能去核它受不受条款 2 保护');

      // 没登记的字段形状变了 → 报。
      writeJson(kTruthV0, <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'trueRollDeg': '-4.4'},
        ],
      });
      writeJson(kGen, <String, dynamic>{
        'anchors': <dynamic>[
          <String, dynamic>{'id': 'p1', 'trueRollDeg': -4.4},
        ],
      });
      final gate.DenominatorAgreement b =
          gate.denominatorAgreement(v0Path: kTruthV0, generatedPath: kGen);
      expect(b.pass, false,
          reason: '一个真值从字符串变成数字是**形状**变化，必须有人看一眼 ——'
              '"类型不同所以跳过"是一条谁都想不到去查的滑过去的路');
      expect(b.problems.any((String s) => s.contains('两种东西')), true);
    });

    // ---- 替代保护②：派生数字 vs 盘上产物 ----

    test('AI 证据溯源：摘要不符 → 报出来；相符 → 通过', () {
      const String src = '$kTmp/src.json';
      writeJson(src, <String, dynamic>{'a': 1});
      final String good = sha.sha256Hex(File(src).readAsBytesSync());
      final Map<String, dynamic> doc = <String, dynamic>{
        'gateInputs': <String, dynamic>{
          'rotationFailureBoundary': <String, dynamic>{
            'evidenceProvenance': <String, dynamic>{
              'sourceSha256': <String, dynamic>{src: good},
            },
          },
        },
      };
      writeJson(kGen, doc);
      final gate.EvidenceProvenanceCheck ok =
          gate.evidenceProvenanceCheck(generatedPath: kGen);
      expect(ok.readable, true);
      expect(ok.pass, true);

      // 产物在 finalize 之后被改过 → 摘要对不上。
      writeJson(src, <String, dynamic>{'a': 2});
      final gate.EvidenceProvenanceCheck bad =
          gate.evidenceProvenanceCheck(generatedPath: kGen);
      expect(bad.pass, false);
      expect(bad.problems.any((String s) => s.contains('被改过')), true,
          reason: '要说明这意味着**叙述描述的不是现在这份产物**');

      // 产物不在了。
      File(src).deleteSync();
      final gate.EvidenceProvenanceCheck gone =
          gate.evidenceProvenanceCheck(generatedPath: kGen);
      expect(gone.pass, false);
      expect(gone.problems.any((String s) => s.contains('不存在')), true);
    });

    test('AJ 证据溯源：指针取不到 → 不可判，**不默认相符**', () {
      writeJson(kGen, <String, dynamic>{'gateInputs': <String, dynamic>{}});
      final gate.EvidenceProvenanceCheck c =
          gate.evidenceProvenanceCheck(generatedPath: kGen);
      expect(c.readable, false);
      expect(c.pass, false);
      expect(c.error!.contains('rotationFailureBoundary'), true);
      expect(c.summary().contains('不可判'), true);
    });

    test('AK 两道替代保护**不可判**时整轮作废；**不等**时判 FAIL 并点名', () {
      final List<Map<String, dynamic>> compose = goodCorpus();
      final Map<String, dynamic> base =
          inputs(compose: compose, measured: goodMeasured(compose));

      // (1) 不可判 → void，不赖实现方。
      final Map<String, dynamic> voided = <String, dynamic>{
        ...base,
        'denominatorAgreement': <String, dynamic>{
          'readable': false,
          'pass': false,
          'error': '测试桩：读不到手写分母',
        },
      };
      final List<Map<String, dynamic>> vi = gate.evaluateP0(voided);
      expect(vi.every((Map<String, dynamic> i) => i['roundInvalid'] == true), true);
      expect(vi.first['actual'].toString().contains('不可判'), true);

      // (2) 读得到但不等 → PIN 条目 FAIL，且**不**把整轮标成作废
      //     （那是"实现方要修"的措辞，不是"输入不可信"）。
      final Map<String, dynamic> failed = <String, dynamic>{
        ...base,
        'denominatorAgreement': <String, dynamic>{
          'readable': true,
          'pass': false,
          'problems': <String>['anchors/p1.trueRollDeg：手写 -4.4 ≠ 生成 -1'],
          'extraUndeclared': <String>[],
          'summary': '测试桩',
        },
      };
      final List<Map<String, dynamic>> fi = gate.evaluateP0(failed);
      final Map<String, dynamic> pin = row(fi, 'PIN');
      expect(pin['pass'], false);
      expect(pin['manual'], false, reason: '读得到就不算"不可判"，是可判的 FAIL');
      expect(pin['owner'].toString().contains('qa-batch'), true,
          reason: '要回派给持有这两份文件的人，不是笼统说"不通过"');
      expect((pin['actual'] as String).contains('anchors/p1.trueRollDeg'), true,
          reason: '错在哪一条要进报告');
      expect(fi.every((Map<String, dynamic> i) => i['roundInvalid'] == true), false,
          reason: '内容不等不是"输入不可信"，是判据分母被改 —— 应当 FAIL 并点名');
    });

    test('AL 扫描区域表：逐区印出来，**0 与「根本没扫」都要看得见**', () {
      // 存在理由：一份只写"命中 0"的扫描报告，读者分不清两件含义相反的事 ——
      // 「这个区域扫过、干干净净」与「这个区域根本没进扫描范围」。
      // 报告文本一模一样，而本项目已经栽过三次同形状的坑。
      final Map<String, dynamic> ev = <String, dynamic>{
        'scan_roots': <String>['lib', 'test', 'tools/gate', 'integration_test'],
        'scan_roots_excluded': <String, String>{
          'native': '主会话裁定不纳入条款 5（对照试验目录，不是交付代码）',
        },
        'skip_scans': <String, dynamic>{
          'skip:lib': <String, dynamic>{'files_scanned': 67, 'hits': <String>[]},
          'skip:test': <String, dynamic>{
            'files_scanned': 22,
            'hits': <String>['test/x.dart:1: @Skip'],
          },
          // 故意缺 tools/gate 与 integration_test → 必须显示"无记录"，
          // 不许因为"没有这个键"就从表里消失。
        },
        'commented_assertion_scans': <String, dynamic>{},
        'catch_scans': <String, dynamic>{
          'catch:lib': <String, dynamic>{
            'files_scanned': 67,
            'hits': <String>[],
            'undecidable': false,
          },
        },
      };
      final String md =
          gate.scanRootsMdSection(<String, dynamic>{'evidence': ev});
      for (final String d in <String>['lib', 'test', 'tools/gate', 'integration_test']) {
        expect(md.contains('`$d`'), true,
            reason: '每个**声称扫了**的区域都要逐行出现，不能只给一句"全部区域"');
      }
      expect(md.contains('67 个文件 / 0 命中'), true,
          reason: '**0 命中也要印** —— 只印非零的话，"扫过且干净"会从表里消失');
      expect(md.contains('22 个文件 / 1 命中'), true);
      expect(md.contains('**无记录**'), true,
          reason: '声称扫了、却没有扫描记录的区域，必须报"无记录"，'
              '不许因为键不存在就静默跳过（那正是"漏扫"与"0 命中"同形的入口）');
      expect(md.contains('native'), true);
      expect(md.contains('刻意不扫'), true,
          reason: '「根本没扫」必须与「扫过、0 命中」分开写 —— 两者在报告里长得一样');
      expect(md.contains('kScanRoots'), true,
          reason: '要写明三处循环共用一个常数，读者才能去核它们有没有不同步');
      // 整块缺失时不许默认"都扫了"。
      final String none = gate.scanRootsMdSection(<String, dynamic>{});
      expect(none.contains('无从核对'), true);
      expect(none.contains('不默认'), true);
    });

    test('AM 三处扫描循环必须共用同一个区域常数（结构对照，不是行为对照）', () {
      // 行为对照测不出"三份列表不同步"：条款 3 扫了 lib、条款 5 漏了 lib 时，
      // 两条的报告**都写"命中 0"**，任何一条单测都不会红。
      // 所以这条直接扫源码：那个字面量数组不许再出现，`kScanRoots` 必须被三处引用。
      final String src = File('tools/gate/anticheat.dart').readAsStringSync();
      expect(src.contains("['lib', 'test', 'tools/gate', 'integration_test']"), false,
          reason: '区域表不许有第二份字面量副本 —— 副本一多，'
              '就必然出现"条款 3 扫了某区域、条款 5 漏了它"这种没人会发现的覆盖缺口');
      final int uses =
          RegExp(r'for \(final String dir in kScanRoots\)').allMatches(src).length;
      expect(uses, 3,
          reason: '三处循环（skip / 注释掉的断言 / 空 catch）都要走同一张表。'
              '改成两处或四条，这条会红 —— 这正是它存在的意义');
      expect(ac.kScanRoots.contains('lib'), true);
      expect(ac.kScanRoots.contains('integration_test'), true);
    });
  });

  // ---------------------------------------------------------------------
  // 轮次号是**账本**：它错了，前面所有"第几轮"的说法都不可信。
  test('Y 轮次号由产物推出，且不许把已有的轮次覆盖掉', () {
    // 事故原样（2026-09-17，就在 r2 之前发现）：
    //   `_nextRound()` 只看 `out/gate_P0_r<N>.json`，而 r1 的 JSON 落在了当时写死的
    //   默认路径 `out/gate_P0.json` 上 —— 于是它算出的"下一轮" = **1**，
    //   把 `out/GATE_P0_r1.md`（重写轮的记录）直接盖掉，
    //   并让真正的第 2 轮顶着 r1 的编号去套 `kRoundErrata` 与修复轮次记账。
    final Directory tmp = Directory('out/tmp_gk_round_test');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    try {
      final String d = tmp.path.replaceAll('\\', '/');
      expect(gate.nextRound(dir: d), 1, reason: '一个产物都没有 → 从第 1 轮开始');

      // **只有 md、没有 json** —— 正是 r1 的实际形状。
      File('$d/GATE_P0_r1.md').writeAsStringSync('# r1\n');
      expect(gate.nextRound(dir: d), 2,
          reason: '只看 json 会算出 1，然后把 r1 的 md 覆盖掉 —— 这就是那条事故');

      File('$d/gate_P0_r2.json').writeAsStringSync('{}\n');
      expect(gate.nextRound(dir: d), 3);

      // 取**最大值**，不是"第一个空位"。造一个**真正的**缺号：有 r1 和 r3、
      // 没有 r2。按"第一个空位"实现会算出 2 —— 而 r2 是**已经跑过、产物后来
      // 被删掉**的那一轮，把新一轮塞进 2 号位就等于让两轮共用一个编号，
      // `kRoundErrata` 与修复轮次记账会串台。
      File('$d/gate_P0_r3.json').writeAsStringSync('{}\n');
      File('$d/gate_P0_r2.json').deleteSync();
      expect(gate.nextRound(dir: d), 4,
          reason: '缺号必须按最大值前进 —— 空位是"那一轮的产物没了"，不是"可以用"');

      // 负例：不匹配的文件名不许被当成轮次产物。
      File('$d/GATE_P0_rX.md').writeAsStringSync('x\n');
      File('$d/gate_P0_eyeline.json').writeAsStringSync('{}\n');
      File('$d/hashes_P0_r9.txt').writeAsStringSync('x\n');
      expect(gate.nextRound(dir: d), 4,
          reason: '非轮次产物不许把轮次号顶上去（否则会凭空跳过修复轮次）');
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  });

  test('Y2 无编号的 `gate_P0.json` 就是第 1 轮，不许把它漏出账本', () {
    // 残洞（team-lead 2026-09-17 指出）：`nextRound` 只认带 `_r<N>` 的名字。
    // 于是只要 `out/GATE_P0_r1.md` **不在**（被删、被移走、被一次死运行覆盖），
    // 光有 `out/gate_P0.json`（r1 的 JSON）时仍会算出"下一轮 = 1" ——
    // 与"只看 json 不看 md"是同一类错误：**账本漏了一个曾经存在的条目**，
    // 只不过这次漏的是那个不带编号的名字。
    final Directory tmp = Directory('out/tmp_gk_round_test2');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    try {
      final String d = tmp.path.replaceAll('\\', '/');
      expect(gate.nextRound(dir: d), 1);
      File('$d/gate_P0.json').writeAsStringSync('{}\n');
      expect(gate.nextRound(dir: d), 2,
          reason: '它就是第 1 轮的机读产物。不认它 → r1 的编号会被再用一次');
      // 大写的旧名同样算。
      File('$d/gate_P0.json').deleteSync();
      File('$d/GATE_P0.md').writeAsStringSync('# r1\n');
      expect(gate.nextRound(dir: d), 2);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------------------
  // 真仓库上的**金丝雀**：不去断言"必须全等"（`out/` 是可再生的，
  // 每轮重生成后数值本来就会变），只断言那条**任何情况下都不该发生**的事：
  // 生成件里出现手写分母没有、也没登记过的条目。出现了就说明有人
  // 造了一条新的判据分母 —— 那是"为通过而放宽"最直接的一种做法。
  test('Z2 真仓库：生成件不许凭空多出手写分母里没有的条目', () {
    final gate.DenominatorAgreement da = gate.denominatorAgreement();
    expect(da.readable, true,
        reason: '两份真值文件都该在（它们都是入库件，不是临时文件）');
    expect(da.extraUndeclared, isEmpty,
        reason: '凭空多出来的分母条目必须为零。要加，先加进手写分母 '
            '`${gate.kTruthV0Path}`，或在 `kDenominatorExtraAllowance` 里登记 ——'
            '两条路都留痕');
    expect(da.extraAllowed, <String>['anchors/p2'],
        reason: '登记豁免只此一条（判据口径第 6 条：p2 归 straight，生成件做了并集）');
  });

  test('Z 真仓库上的轮次号必须 > 1（回归：r1 的 md 已经存在）', () {    // 这条针对真实仓库状态：`out/GATE_P0_r1.md` 存在（重写轮的记录）。
    // 若下一轮算成 1，r2 会把 r1 的报告覆盖掉 —— 证据被销毁，而且没人会发现。
    final int n = gate.nextRound();
    expect(n >= 2, true,
        reason: 'out/ 下已有 r1 的产物，下一轮不能再是 1。实算 = $n');
  });
}
