/// P0.6 判据的自检 —— 门禁**自己的量具**在自证。
///
/// ## 为什么必须有这个文件
///
/// P0.6（"死区内不得被转动"）是随 10° 死区一起新加的条目。**一条从未在
/// 任何输入上跑过的判据脚本，它的绿色与"根本没跑"在人读的报告里长得一模一样**
/// —— 这正是本项目当天反复出现的失效形态（某个名字/字段/机制声称的口径
/// 宽于它实际覆盖的范围，而它读起来完全正常）。
///
/// 所以这里用**构造输入**把 P0.6 的五种结局各跑一遍，证明它真的会分类，
/// 而不是恒绿或恒红：
///
/// | 用例 | 构造 | 期望 |
/// |---|---|---|
/// | `ok` | 死区内、自洽、残余 = 真值 | PASS |
/// | `rot` | 死区内、引擎自报转了 | FAIL（真违规） |
/// | `meter` | 死区内、引擎自报没转、眼线量具读数离谱、SIFT 复核正常 | PASS + 挂牌「量测失效」并扣除分母 |
/// | `blind` | 同 `meter` 但第二支量具也拿不到 | **MANUAL**（对该样本没有读数，不靠主判据通过） |
/// | `ext` | 死区外夹具 | 不得进入 P0.6 的范围 |
///
/// 2026-09-17 追加：**"判定集为空时本项声称什么"** 是同一天另一条真实缺陷的形态
/// —— 空集上的 `every(...)` 恒真，于是"没有任何样本"会被读成"没有任何违规"。
/// 故用例 7–10 把三处空集结局各钉一遍：
///
/// | 用例 | 构造 | 期望 |
/// |---|---|---|
/// | `cov` | 锚点栏空、夹具栏非空 | P0.1b **PASS** 且正文写明「覆盖由 P0.3b 夹具栏承担」 |
/// | `allEmpty` | 锚点栏与夹具栏都空 | P0.1b **FAIL + MANUAL**（这时才真的没读数） |
/// | `covEmpty` | 夹具栏无死区外样本 | P0.3b **FAIL + MANUAL**（不许空真通过） |
/// | `noSample` | 一条可合成样本都没有 | P0.4 **FAIL + MANUAL**（同上） |
///
/// `cov` 存在的理由：P0.1b 的锚点栏在本语料上**结构性为空**。若把它一律记 MANUAL，
/// 而 `_finish` 的 `allPass = every(pass==true)` 又把 MANUAL 当不通过，整轮就**永远
/// 不能 PASS** —— 那是把"已记录的覆盖收缩"读成"实现方永远不达标"。
///
/// 运行：`dart run tools/gate/p0_p06_selftest.dart`
/// **不要**用 `flutter test` 跑（`main(List<String>)` 与 harness 的 `main()` 不兼容，
/// 会报 `Connection closed before test suite loaded` —— 见 docs/PITFALLS.md）。
library;

import 'dart:io';

import 'gate_P0.dart';

/// 构造一条成片台记录。只写判据真正读的字段，其余留默认。
Map<String, dynamic> row({
  required String id,
  required double truth,
  required double est,
  double applied = 0.0,
  bool? straightened,
  String corpus = 'rotated',
  String source = 'pupil',
}) {
  return <String, dynamic>{
    'id': id,
    'specId': kSpec,
    'corpus': corpus,
    'truthTiltDeg': truth,
    'straightenDeg': applied,
    'straightened': straightened ?? applied.abs() > 1e-9,
    'rollSource': source,
    'faceRollDeg': est,
  };
}

Map<String, dynamic> eyeRow(String id, double tilt, {bool ok = true}) =>
    <String, dynamic>{'id': id, 'ok': ok, 'tilt_deg': tilt, 'reason': 'ok'};

Map<String, dynamic> siftRow(String id, double residual, {bool ok = true}) =>
    <String, dynamic>{
      'id': id,
      'ok': ok,
      'residual_deg': residual,
      'measured_applied_deg': 0.0,
      'applied_delta_vs_record': 0.0,
    };

/// 把一批构造样本喂给 `evaluateP0`，取回指定 id 的那一条。
Map<String, dynamic> pick(
  String id,
  List<Map<String, dynamic>> compose,
  List<Map<String, dynamic>> eyeline,
  List<Map<String, dynamic>> sift,
) {
  final Map<String, dynamic> inputs = <String, dynamic>{
    'spec': kSpec,
    'compose': compose,
    'eyeline': <String, dynamic>{'rows': eyeline},
    'siftAlign': <String, dynamic>{'rows': sift},
    'qaResidual': <String, dynamic>{'items': <dynamic>[]},
    'eyelineSelftest': <String, dynamic>{'max_abs_err_deg': 0.1},
    'rigidSelftest': <String, dynamic>{'max_abs_err_deg': 0.1},
    'blockers': <String>[],
    'roundState': <String, dynamic>{
      'frozen': true,
      'dirty': <dynamic>[],
      'composeMissingFiles': 0,
      'composeDeclared': compose.length,
      'composeParsed': compose.length,
      'composeBadLines': <dynamic>[],
    },
    'provenance': <String, dynamic>{'reasons': <dynamic>[]},
    'denominatorAgreement': <String, dynamic>{'readable': true},
    'evidenceProvenance': <String, dynamic>{'readable': true},
  };
  for (final Map<String, dynamic> i in evaluateP0(inputs)) {
    if (i['id'] == id) return i;
  }
  throw StateError('evaluateP0 没有产出 $id 条目');
}

Map<String, dynamic> p06(
  List<Map<String, dynamic>> compose,
  List<Map<String, dynamic>> eyeline,
  List<Map<String, dynamic>> sift,
) =>
    pick('P0.6', compose, eyeline, sift);

int failures = 0;

void check(String name, bool cond, String detail) {
  if (cond) {
    stdout.writeln('  PASS  $name');
  } else {
    failures++;
    stdout.writeln('  FAIL  $name —— $detail');
  }
}

void main(List<String> args) {
  stdout.writeln('P0.6 自检（构造输入，不经生产代码）\n');

  // ---- 用例 1：死区内、自洽、残余 = 真值 → PASS ----
  {
    stdout.writeln('[1] ok：死区内自洽');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[row(id: 'ok', truth: 5.0, est: 5.1)],
      <Map<String, dynamic>>[eyeRow('ok', 5.05)],
      <Map<String, dynamic>>[siftRow('ok', 5.05)],
    );
    check('PASS', it['pass'] == true, '实际 pass=${it['pass']}');
    check('不标 MANUAL', it['manual'] == false, '实际 manual=${it['manual']}');
    check('挂「自洽性检查」标',
        (it['actual'] as String).contains('自洽性检查'), '正文缺该标记');
    check('主判据与次判据同报',
        (it['actual'] as String).contains('主判据') &&
            (it['actual'] as String).contains('次判据'),
        '正文没有同时报两条');
    stdout.writeln('');
  }

  // ---- 用例 2：死区内、引擎自报转了 → FAIL ----
  {
    stdout.writeln('[2] rot：死区内被转动（P0.6 存在的理由）');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[
        row(id: 'rot', truth: 5.0, est: 5.1, applied: 5.1, straightened: true)
      ],
      <Map<String, dynamic>>[eyeRow('rot', 0.05)],
      <Map<String, dynamic>>[siftRow('rot', 0.05)],
    );
    check('FAIL', it['pass'] == false, '实际 pass=${it['pass']}');
    check('点名 rot', (it['actual'] as String).contains('rot'), '正文没点名');
    stdout.writeln('');
  }

  // ---- 用例 3：眼线量具读数离谱、SIFT 复核正常 → 挂牌「量测失效」并扣分母 ----
  {
    stdout.writeln('[3] meter：量具读错，独立量具已复核');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[row(id: 'meter', truth: 5.0, est: 4.9)],
      <Map<String, dynamic>>[eyeRow('meter', 13.657)],
      <Map<String, dynamic>>[siftRow('meter', 5.02)],
    );
    check('PASS', it['pass'] == true, '实际 pass=${it['pass']}');
    check('不标 MANUAL', it['manual'] == false, '实际 manual=${it['manual']}');
    check('点名 meter 并挂牌', (it['actual'] as String).contains('meter'),
        '正文没点名');
    check('分母扣除已声明',
        (it['actual'] as String).contains('分母') &&
            (it['actual'] as String).contains('扣除'),
        '正文没写分母扣除');
    stdout.writeln('');
  }

  // ---- 用例 4：两支量具都拿不到 → MANUAL，不靠主判据通过 ----
  {
    stdout.writeln('[4] blind：无第二支量具，不许静默通过');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[row(id: 'blind', truth: 5.0, est: 4.9)],
      <Map<String, dynamic>>[eyeRow('blind', 13.657)],
      <Map<String, dynamic>>[siftRow('blind', 0.0, ok: false)],
    );
    check('FAIL', it['pass'] == false, '实际 pass=${it['pass']}');
    check('标 MANUAL', it['manual'] == true, '实际 manual=${it['manual']}');
    check('点名 blind', (it['actual'] as String).contains('blind'), '正文没点名');
    stdout.writeln('');
  }

  // ---- 用例 5：死区外夹具不得进 P0.6 的范围 ----
  {
    stdout.writeln('[5] ext：死区外夹具归 P0.3a，不归 P0.6');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[
        row(id: 'ext', truth: -18.0, est: -17.9, applied: -17.9),
        row(id: 'in', truth: 1.0, est: 1.1),
      ],
      <Map<String, dynamic>>[eyeRow('ext', -0.1), eyeRow('in', 1.05)],
      <Map<String, dynamic>>[siftRow('ext', -0.1), siftRow('in', 1.05)],
    );
    final String a = it['actual'] as String;
    check('范围只算死区内 1 条', a.contains('主判据范围 1 条'), '正文范围计数不对');
    check('ext 未进范围', !a.contains('`ext`'), '死区外样本混进了 P0.6');
    stdout.writeln('');
  }

  // ---- 用例 6：边界带只报数、不判 FAIL ----
  {
    stdout.writeln('[6] band：9°–11° 带内只报数');
    final Map<String, dynamic> it = p06(
      <Map<String, dynamic>>[
        row(id: 'band', truth: 9.9, est: 10.3, applied: 10.3, straightened: true)
      ],
      <Map<String, dynamic>>[eyeRow('band', -0.4)],
      <Map<String, dynamic>>[siftRow('band', -0.4)],
    );
    check('PASS（带内不判 FAIL）', it['pass'] == true, '实际 pass=${it['pass']}');
    check('带内逐条列出', (it['actual'] as String).contains('band'),
        '带内样本被静默丢弃');
    stdout.writeln('');
  }

  // ---- 用例 7：锚点栏空、夹具栏非空 → P0.1b 必须 PASS，且写明覆盖由夹具栏承担 ----
  {
    stdout.writeln('[7] cov：锚点栏结构性空，覆盖由夹具栏承担');
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      row(id: 'a1', truth: 5.0, est: 5.05, corpus: 'anchor'),
      row(id: 'f1', truth: -18.0, est: -17.9, applied: -17.9),
    ];
    final List<Map<String, dynamic>> eye = <Map<String, dynamic>>[
      eyeRow('a1', 5.02),
      eyeRow('f1', -0.1),
    ];
    final List<Map<String, dynamic>> sft = <Map<String, dynamic>>[
      siftRow('a1', 5.02),
      siftRow('f1', -0.1),
    ];
    final Map<String, dynamic> b = pick('P0.1b', compose, eye, sft);
    check('P0.1b PASS（不因锚点栏空而永久停机）', b['pass'] == true,
        '实际 pass=${b['pass']}');
    check('P0.1b 不标 MANUAL', b['manual'] == false, '实际 manual=${b['manual']}');
    check('P0.1b 写明覆盖由夹具栏承担',
        (b['actual'] as String).contains('覆盖由 P0.3b 夹具栏承担'), '正文没写明');
    final Map<String, dynamic> c3 = pick('P0.3b', compose, eye, sft);
    check('P0.3b PASS（夹具判定集 1 条）', c3['pass'] == true,
        '实际 pass=${c3['pass']}');
    stdout.writeln('');
  }

  // ---- 用例 8：两栏都空 → P0.1b 不许白拿 PASS ----
  {
    stdout.writeln('[8] allEmpty：锚点栏与夹具栏都空');
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      row(id: 'a1', truth: 5.0, est: 5.05, corpus: 'anchor'),
    ];
    final List<Map<String, dynamic>> eye = <Map<String, dynamic>>[eyeRow('a1', 5.02)];
    final List<Map<String, dynamic>> sft = <Map<String, dynamic>>[siftRow('a1', 5.02)];
    final Map<String, dynamic> b = pick('P0.1b', compose, eye, sft);
    check('P0.1b FAIL', b['pass'] == false, '实际 pass=${b['pass']}');
    check('P0.1b 标 MANUAL', b['manual'] == true, '实际 manual=${b['manual']}');
    stdout.writeln('');
  }

  // ---- 用例 9：P0.3b 判定集为空不许静默 PASS（空真是最危险的那种通过）----
  {
    stdout.writeln('[9] covEmpty：夹具栏无死区外样本');
    final List<Map<String, dynamic>> compose = <Map<String, dynamic>>[
      row(id: 'f1', truth: 5.0, est: 5.05),
    ];
    final List<Map<String, dynamic>> eye = <Map<String, dynamic>>[eyeRow('f1', 5.02)];
    final List<Map<String, dynamic>> sft = <Map<String, dynamic>>[siftRow('f1', 5.02)];
    final Map<String, dynamic> c3 = pick('P0.3b', compose, eye, sft);
    check('P0.3b FAIL（空真不许当通过）', c3['pass'] == false,
        '实际 pass=${c3['pass']}');
    check('P0.3b 标 MANUAL', c3['manual'] == true, '实际 manual=${c3['manual']}');
    stdout.writeln('');
  }

  // ---- 用例 10：P0.4 无样本不许静默 PASS ----
  {
    stdout.writeln('[10] noSample：一条可合成样本都没有');
    final Map<String, dynamic> p = pick('P0.4', <Map<String, dynamic>>[],
        <Map<String, dynamic>>[], <Map<String, dynamic>>[]);
    check('P0.4 FAIL（空真不许当通过）', p['pass'] == false, '实际 pass=${p['pass']}');
    check('P0.4 标 MANUAL', p['manual'] == true, '实际 manual=${p['manual']}');
    stdout.writeln('');
  }

  stdout.writeln(failures == 0
      ? 'P0 自检：全部通过（10 组用例）'
      : 'P0 自检：$failures 项失败');
  exit(failures == 0 ? 0 : 1);
}
