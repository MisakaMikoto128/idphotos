// tools/gate/gate_P0.dart
//
// G2B-P0 — 摆正估计准确性（ACCEPTANCE.md `## G2B-P0` 一节）。
// 属 gatekeeper 势力范围。
//
// 架构（重写于 2026-09-17，起因见下）：
//   test/batch/p0_*.py            —— qa-batch 的测量与真值（裁判甲，出数字，不出判决）
//   tools/gate/p0_eyeline.py      —— gatekeeper 的独立眼线量具（Haar 级联路径）
//   tools/gate/p0_rigid_check.py  —— gatekeeper 的刚体轮廓配准量具（条款 7 的独立复核路径）
//   tools/gate/gate_P0.dart（本文件）—— 判定（阈值、口径、防作弊、退出码）
//
// **重写原因（记录在案）**：本文件初版实现的是 G2B-P0 的草稿版判据，用
// `ComposeDiagnostics.straightenDeg` 当硬指标。主会话在 03:23 / 03:24 / 03:39 / 03:47
// 四次修订 ACCEPTANCE，现版「计分口径」第 5 条明令硬判据只能用**成片端到端残余**，
// straightenDeg 降级为"只作诊断与定位"。初版判决因此作废，本版按现版条目重写。
//
// 运行（项目根目录）：
// ```
// dart run tools/gate/gate_P0.dart
// ```
// **轮次号自动推**（`nextRound()`：1 + `out/` 下已有的最大轮次，md/json 两种产物都算）。
// 需要指定时用 `--round N`；输出默认落在 `out/gate_P0_r<N>.json`，
// 报告固定写 `out/GATE_P0_r<N>.md`。
//
// 注意：`out/` 下**不要**留测试性的 `GATE_P0_r<N>.md` / `gate_P0_r<N>.json` ——
// `nextRound()` 取最大值，一个残留的 r99 会把真正的下一轮顶到 100。
// `--reuse` 只跳过两条量具自检，**不**跳过测量与 dev_selfcheck，不是"快速干跑"。
//
// 阈值全部抄自 docs/ACCEPTANCE.md；本文件里的数字若与 ACCEPTANCE 不符，
// 以 ACCEPTANCE 为准并视为 gatekeeper 的 bug。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'anticheat.dart';
import 'gate_common.dart';
import 'provenance.dart';
import 'sha256.dart';

const String kBaseline = 'baseline-p6p0';

/// 成片规格：ACCEPTANCE P0.1a 指定 `cn_big_1inch` 390×567
/// （一寸 295×413 上瞳孔太小，测量可靠性不足——这是法典写明的）。
const String kSpec = 'cn_big_1inch';

/// **生成**的判据分母：`p0_finalize_v1.py` 每轮重写，判据**读**的是它。
/// 它**不按内容钉**（理由见 `kTruthV0Path` 的长注），只按「与手写分母逐条相等」核。
const String kTruthPath = 'out/P0_truth.json';

/// **手写**的判据分母（`out/P0_truth_v0.json`，入库、不随轮次重生成）。
/// **内容钉钉的是它。**
///
/// 为什么换钉子对象（主会话 2026-09-17 裁定）：
///  - 旧钉子钉在生成的 `$kTruthPath` 上，于是必须用排除集把 `evaluatedState`
///    挖掉 —— 那个块记 `headAtFinalize` 与 `codeFingerprintAtFinalize.*`，是
///    **HEAD 与工作区的函数**，每轮必变。为它做豁免，等于在一个"判据分母"上
///    永久开一个不受内容钉保护的洞，还得靠 review 兜。
///  - v0 才是**人写的、要审的那一份**：改它才是"为通过而放宽"的正路。
///    生成的产物是它的函数，把产物钉死既钉不住改分母的动机（改 v0 照样过关），
///    又制造了一堆与判据无关的假阳性。
///  - 换过之后排除集**不再是必需的**（见 `kTruthLeafExcludedPrefixes`），
///    代价是保护必须换成两道**语义**检查（`denominatorAgreement` 与
///    `evidenceProvenanceCheck`），比逐叶相等更强：那两道查的是
///    "生成的分母是不是 v0 的分母"与"派生数字是不是盘上产物的函数"。
const String kTruthV0Path = 'out/P0_truth_v0.json';

/// 量具自检的输入图。**`test/` 下的冻结夹具源**，不是 `out/` 下的成片。
///
/// 为什么是 `g01.jpg`：它是 qa-batch 的黄金集源图，入库、受冻结与条款 1 保护，
/// 2026-09-17 实测眼线量具 6/6、最大误差 0.41°（阈值 0.5°），
/// 刚体配准最大误差 0.500°（阈值 1.0°）—— 两条量具都有余量。
/// 被它替掉的那张 `out/P0_anchors/composed/c01__cn_big_1inch.jpg` 已经不在了
/// （可再生目录被覆盖），而自检失败表现为"量具没自证"，与"量具不准"同形。
const String kSelftestImagePath = 'test/golden/src/g01.jpg';

const String kComposePath = 'out/P0_compose_items.jsonl';
const String kComposeSummaryPath = 'out/P0_compose_summary.json';

/// 冻结判定覆盖的路径。`out/` 是共享输出目录，**不在**冻结条件内
/// （它的脏是预期的：每轮都会往里写）。
const List<String> kFreezeScopes = <String>['lib', 'test', 'tools', 'docs'];

/// 冻结范围的**唯一豁免**：只此一个文件，不是整个 `docs/`。
///
/// 主会话 2026-09-17 裁定（选 B：窄口径）。理由三条：
///  1. 冻结的目的是"判决的输入来自同一个代码状态"。PITFALLS **不进任何测量链** ——
///     门禁不读它、判据不引用它、读数不经过它。
///  2. CLAUDE.md §4 写"`docs/PITFALLS.md`：**所有 agent 只追加**"，即所有 agent
///     **随时**可写。把它放进冻结范围，等于让一次**合规的**追加动作触发整轮作废 ——
///     这条规则会对着正确行为开火。豁免涵盖主会话与各裁判。
///  3. r1 死于"判据中途被改"，那是 ACCEPTANCE/RUBRIC 的问题，与 PITFALLS 同类不同源。
///
/// **不要用"把 `docs/` 移出 `kFreezeScopes`"来实现这条豁免** —— 那会连带放行
/// `ACCEPTANCE.md` / `RUBRIC.md`（判据本体，r1 就是被它坑掉的）以及
/// `CONTRACTS.md` / `DESIGN.md` / `ENV.md` 的中途改动。
const String kFreezeExemptPath = 'docs/PITFALLS.md';

/// 从 porcelain v1 的一行（`XY PATH`，重命名是 `XY OLD -> NEW`）里取回路径。
String _porcelainPath(String line) {
  if (line.length < 4) return line.trim();
  String p = line.substring(3).trim();
  if (p.contains(' -> ')) p = p.split(' -> ').last.trim();
  return p.replaceAll('"', '').replaceAll('\\', '/');
}

/// 事后勘误，按轮次。**只追加，不改动下方任何原始结论。**
///
/// 写在生成器里而不是手工贴在 md 上：报告是可重生成的产物，
/// 手贴的批注会在下一次 `--reuse` 时被冲掉，等于没有。
const Map<int, List<String>> kRoundErrata = <int, List<String>>{
  1: <String>[
    '### 事后勘误（2026-09-17 追加；不推翻下方任何原始结论，只标注哪些证据当时是空的）',
    '1. **「防作弊巡查：清白」这句话在条款 3 / 条款 5 上当时是空的。** '
        '本轮用的扫描器是 `grep` 子进程，而本机从 Dart 起 `grep` 时 Windows 会在参数传递途中'
        '吃掉模式里的 `\\` `{` `}` `,`：`catch\\s*\\(...\\)\\s*\\{[\\s\\S]{0,80}?\\}` 到达 grep 时'
        '已变成 `catchs*(s*[A-Za-z_]*s*)s*{[sS]80?}`，grep 直接报 exit 2；'
        '`skip:|@Skip|@skip` 里的 `|` 还被 shell 当管道，报 `\'Skip\' is not recognized`、exit 255。'
        '**也就是说条款 3/5 的扫描从未真正跑过，而报告写的是"命中 0"。**'
        '这正是本项目反复出现的那同一个形态：**仪表看不见对象时说了"没有"，而不是"我看不见"。**',
    '2. **改用纯 Dart 正则后（`tools/gate/anticheat.dart`，同一提交内自报）的复核读数**：'
        '`lib/` 67 个文件、`test/` 22 个、`tools/gate/` 20 个、`integration_test/` 9 个；'
        'skip 命中仅出现在 `tools/gate/`（16 条，全是扫描器自己的模式常量与 gate_G4 里的字样）；'
        '空 catch 命中仅出现在 `test/gate/anticheat_test.dart`（3 条，全是自检的正例夹具）。'
        '**`lib/` 与 `integration_test/` 两项均为 0 命中。**',
    '3. 由此新增一条口径：命中落在巡检自身领地（`tools/gate/`、`test/gate/`）时'
        '**逐条登记但不判违规**——扫描器扫不了自己，而这两个目录本就只有 gatekeeper 能写，'
        '别人往里写已先被条款 1 拦下。登记并公开 ≠ 隐去。',
    '4. 本文件是**再生成**（`--reuse`），不是一次新判决；第 1 轮的「作废」结论原样保留，'
        '也不会因为再生成而变成对某个代码状态的判决。',
    '5. 判据第 6 条的表述在上游被订正过（`6f01e6e` → `98f3331`）：'
        '不同照片数是 **11**（12 条锚点 − `c03`/`c04` 这一对真重复），'
        '`c10`/`c11`/`c12` 是**三张不同照片**各自计数，`p2` 归 `straight` 不在锚点栏。'
        '数字未变，变的是理由与算式。',
  ],
};
/// **条款 1 从 `7773df4` 起才真正执行。** 这句话每轮都印。
///
/// 事故：`git()` 一直用 `runInShell: true`（默认），参数被喂给 `cmd.exe`。
/// `--format=%h %s` 里的 `%s` 被 cmd 当成未定义变量，命令直接 exit 255、
/// stdout 为空 —— 而调用方把"空输出"读成"没有改动"。**条款 1 因此静默失效了
/// 整段时间**：它从来没有一次真的报过改动。
///
/// 影响面**只在结论的可引用性上**，不在本轮读数上：`7773df4` 之前所有轮次的
/// 「防作弊巡查：清白」里，条款 1 那一半是**空的**。条款 3 / 条款 5 另有各自
/// 的失效史（`grep` 子进程被 Windows 吃掉模式里的 `\` `{` `}` `,`，见 r1 勘误），
/// 也在同一时期修复。
///
/// 所以：**`7773df4` 之前任何一轮的「清白」都不得被引用为历史**
/// （不许写"上一轮还是清白的"）。这不是"那几轮判错了"——它们判的别的条目可能是对的；
/// 是"那几轮里有一项检查根本没跑，而报告说它跑过了且干净"。
/// 修好之后同一命令在真实仓库上给出 **219 条改动路径**（修前是 0 条）。
const String kClause1ExecutionNote =
    '> **条款 1 的执行史（每轮必读）**：`git()` 原用 `runInShell: true`，'
        '参数被喂给 `cmd.exe` 后 `%s` 被吃掉 → 命令 exit 255、stdout 为空，'
        '而空输出被读成"没有改动"。**条款 1 直到 `7773df4` 才真正执行**'
        '（修后同一命令在真实仓库上给出 219 条改动路径，修前 0 条）。'
        '因此 **`7773df4` 之前所有轮次的「防作弊巡查：清白」在条款 1 上是空的，'
        '不得被引用为历史**（不许写"上一轮还是清白的"）。'
        '条款 3 / 条款 5 有各自的同类失效史（`grep` 子进程被 Windows 吃掉模式字符），'
        '见第 1 轮勘误。';

const String kEyelinePath = 'out/gate_P0_eyeline.json';const String kEyelineSelftestPath = 'out/gate_P0_eyeline_selftest.json';
const String kRigidSelftestPath = 'out/gate_P0_rigid_selftest.json';
const String kSiftPath = 'out/gate_P0_sift_align.json';
const String kOverlapPath = 'out/gate_P0_overlap.json';
const String kHashesRolling = 'out/hashes_P0_prev.txt';

/// 残差容差。严格 ≤，不四舍五入。
const double kResidualMaxDeg = 1.5;
/// P0.1a 另要求中位数 ≤ 1.0。
const double kResidualMedianMaxDeg = 1.0;
/// P0.3a ① 估计值斜率带（只作诊断）。
const double kSlopeLo = 0.85;
const double kSlopeHi = 1.15;
/// P0.3a ② 成片残余回归：斜率应 ≈ 0（硬判据）。
const double kResidSlopeAbsMax = 0.15;
const double kResidInterceptAbsMax = 0.5;
/// 条件覆盖率阈值：与残差容差同值，语义才自洽（ACCEPTANCE 口径 2 的脚注）。
const double kCoverageMinTruthDeg = 1.5;
/// 锚点下限，按法典口径 6 表述为"11 张不同照片"。
const int kMinDistinctPhotos = 8;
/// 合成竖直样本（uprightSynthetic）的条数下限。法典 P0.2 写的是 9 张。
/// 设下限是为了不让"空集"静默通过：`notPupil.isEmpty` 在空集上恒真。
const int kUprightSyntheticMin = 9;
/// 量具自检的最大允许误差。量不准的量具没有资格判别人。
///
/// 两条量具的门槛不同，是因为**它们在判据里扮演的角色不同**，不是通融：
///  - 眼线量具直接喂 P0.1a/P0.2/P0.3a 的残余统计（含"中位 ≤ 1.0°"这种亚度判据），
///    所以要求 0.5°——它自己的误差必须明显小于它要判的最小量。
///  - 刚体配准量具只用于条款 7 的交叉复核，裁决的是"某条样本到底歪没歪"这类
///    ≥1.5° 的分歧，0.55° 的读回误差是判据容差的 1/3，够用。
const double kEyelineMaxErrDeg = 0.5;
const double kRigidMaxErrDeg = 1.0;

Future<void> main(List<String> args) async {
  int round = 0;
  bool reuse = false;
  // 空串 = "没指定，按轮次推"。**不能在这里就定死一个固定默认值**：
  // 默认值写死成 `out/gate_P0.json` 的话，每一轮的 JSON 都落在同一个文件上，
  // 于是 `_nextRound()` 找 `out/gate_P0_r<n>.json` 永远找不到 —— 下一轮又算回 r1，
  // 把上一轮的 `out/GATE_P0_r1.md` **覆盖掉**。r1 就是这么写出来的，
  // 所以第 2 轮若不显式传 `--round 2` 就会毁掉 r1 的报告。
  String? outPathArg;
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--round' && i + 1 < args.length) {
      round = int.parse(args[i + 1]);
    } else if (args[i] == '--out' && i + 1 < args.length) {
      outPathArg = args[i + 1];
    } else if (args[i] == '--reuse') {
      reuse = true;
    }
  }
  if (round == 0) round = nextRound();
  final String outPath = outPathArg ?? 'out/gate_P0_r$round.json';

  // 坏行账要在读输入之前清零，否则会把上一轮（或 `_roundState` 里的重复读取）
  // 的条目算进本轮。
  _jsonlBadLines.clear();

  final HashScan hs = hashScan();
  final Map<String, String> hashes = hs.hashes;
  // 判据分母（真值文件）的数值叶漂移。**必须在读输入之前算**，
  // 否则本轮读数就可能已经建立在被改过的真值上而不自知。
  final TruthDrift drift = truthDrift();
  // 测量产出（`out/` 下那几份每轮重生成的数据）与本轮代码的同源绑定。
  // 同样**必须在读输入之前算**：它决定下面读到的数能不能用。
  final ProvenanceReport prov = provenanceReport();
  // 换钉之后补上的两道：生成件的分母是不是手写件的分母、派生数字是不是
  // 盘上产物的函数。同样**必须在读输入之前算**。
  final DenominatorAgreement da = denominatorAgreement();
  final EvidenceProvenanceCheck ev = evidenceProvenanceCheck();
  File('out/hashes_P0_r${round}_pre.txt')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_formatHashes(hashes));

  final List<String> blockers = <String>[];
  // 量具自检用的图。**必须是 `test/` 下的冻结夹具源**，不能是
  // `out/P0_anchors/composed/` 的成片 —— 那个目录是**可再生的混合态**
  // （2026-09-17 实测只剩 93/110：一次脏树轮的覆盖把 17 张顶掉了），
  // 拿它当基准等于把量具的自证挂在"上一轮恰好没把它删掉"上。
  // 也不要把任何成片的**字节哈希**钉成冻结基准，理由同上。
  final String selftestImage = kSelftestImagePath;

  if (!reuse) {
    // ---- 量具自检：两条路径各自证明自己量得准 ----
    await _instrument(
      '眼线量具自检',
      kEyelineSelftestPath,
      <String>[
        'tools/gate/p0_eyeline.py', 'selftest',
        '--image', selftestImage, '--out', kEyelineSelftestPath,
      ],
      blockers,
    );
    await _instrument(
      '刚体配准量具自检',
      kRigidSelftestPath,
      <String>[
        'tools/gate/p0_rigid_check.py', 'selftest',
        '--image', selftestImage, '--out', kRigidSelftestPath,
      ],
      blockers,
    );
    // ---- 独立测量 ----
    final RunResult meas = await runProcess(
      'python',
      <String>[
        'tools/gate/p0_eyeline.py', 'run',
        '--items', kComposePath, '--spec', kSpec, '--out', kEyelinePath,
      ],
      timeout: const Duration(minutes: 20),
    );
    stdout.writeln('--- 眼线量具退出码 ${meas.exitCode} ---\n${meas.stdout}');
    if (!File(kEyelinePath).existsSync()) {
      blockers.add('眼线量具未产出 $kEyelinePath\n${meas.tail(maxChars: 800)}');
    }
    // ---- 第二条独立路径：SIFT 源图↔成片配准（对手裁坏/打洞的成片免疫）----
    final RunResult siftRun = await runProcess(
      'python',
      <String>[
        'tools/gate/p0_rigid_check.py', 'align',
        '--items', kComposePath, '--spec', kSpec, '--out', kSiftPath,
      ],
      timeout: const Duration(minutes: 30),
    );
    stdout.writeln('--- SIFT 配准退出码 ${siftRun.exitCode} ---\n${siftRun.stdout}');
    if (!File(kSiftPath).existsSync()) {
      blockers.add('SIFT 配准未产出 $kSiftPath\n${siftRun.tail(maxChars: 800)}');
    }
    // ---- 去重口径（法典条款 6 同性质）：测黄金集与锚点的重叠，不许虚增覆盖 ----
    await _instrument(
      '去重口径量具',
      kOverlapPath,
      <String>['tools/gate/p0_overlap.py', '--out', kOverlapPath],
      blockers,
    );
  }

  final RunResult selfcheck = await runProcess(
    'flutter',
    <String>['test', 'lib/core/imaging/dev_selfcheck.dart'],
    timeout: const Duration(minutes: 40),
  );

  final Map<String, dynamic> inputs = <String, dynamic>{
    'truth': _readJson(kTruthPath),
    'compose': _readJsonl(kComposePath),
    'eyeline': _readJson(kEyelinePath),
    'siftAlign': _readJson(kSiftPath),
    'overlap': _readJson(kOverlapPath),
    'eyelineSelftest': _readJson(kEyelineSelftestPath),
    'rigidSelftest': _readJson(kRigidSelftestPath),
    'devSelfcheck': <String, dynamic>{
      'exitCode': selfcheck.exitCode,
      'timedOut': selfcheck.timedOut,
      'tail': selfcheck.tail(maxChars: 2500),
    },
    'gateG2B': _readJson('out/gate_G2B.json'),
    'gateG4': _readJson('out/gate_G4.json'),
    'composeSummary': _readJson(kComposeSummaryPath),
    'blockers': blockers,
    'spec': kSpec,
    'roundState': _roundState(),
    'provenance': prov.toJson(),
    'denominatorAgreement': da.toJson(),
    'evidenceProvenance': ev.toJson(),
  };

  final List<Map<String, dynamic>> items = evaluateP0(inputs);
  await _finish(
    outPath: outPath,
    round: round,
    items: items,
    hashes: hashes,
    inputs: inputs,
    hashScanResult: hs,
    truthDriftResult: drift,
  );
}

/// 本轮输入是否来自**同一个被冻结、被标识的代码状态**。
///
/// 三件事一起测，缺一不可：
///  1. `git status --porcelain -- lib test tools docs` 为空（冻结；`out/` 除外）；
///  2. `$kComposePath` 的每条样本都能解析、成片文件都在；
///  3. 清单声明的条数 == 实际解析到的条数（防"静默 continue 后在零样本上判定"）。
///
/// 教训来源（2026-09-17）：qa-batch 的成片台因路径被拼两次，87/100 静默跳过，
/// **exit 0、crash 0、summary 看着完全健康**，却是在零样本上判 P0.2/P0.3a/P0.3b。
/// 所以"进程没崩"不能当完整性证据，必须数条数。
Map<String, dynamic> _roundState() {
  final Map<String, dynamic> s = <String, dynamic>{};
  final RunResult st = _gitSync(<String>[
    'status', '--porcelain', '--untracked-files=all', '--', ...kFreezeScopes,
  ]);
  final List<String> dirtyAll = st.stdout
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  // 唯一豁免：`docs/PITFALLS.md`（见 kFreezeExemptPath）。豁免的条目**照记不误**，
  // 只是不计入"未冻结"——登记而公开，不是隐去。
  final List<String> exempted =
      dirtyAll.where((String l) => _porcelainPath(l) == kFreezeExemptPath).toList();
  final List<String> dirty =
      dirtyAll.where((String l) => _porcelainPath(l) != kFreezeExemptPath).toList();
  s['frozen'] = st.exitCode == 0 && dirty.isEmpty;
  s['dirty'] = dirty.take(20).toList();
  s['freezeExempt'] = exempted.take(20).toList();
  s['freezeExemptPath'] = kFreezeExemptPath;

  final List<dynamic> rows = _readJsonl(kComposePath);
  int declared = 0;
  int parsed = 0;
  int missingFiles = 0;
  final List<String> missingIds = <String>[];
  for (final dynamic raw in rows) {
    if (raw is! Map<String, dynamic>) continue;
    if (raw['specId'] != kSpec) continue;
    declared++;
    if (raw['id'] == null || raw['truthTiltDeg'] == null) continue;
    parsed++;
    final Object? p = raw['composed'];
    if (p is! String || !File(p).existsSync()) {
      missingFiles++;
      if (missingIds.length < 20) missingIds.add('${raw['id']}');
    }
  }
  s['composeDeclared'] = declared;
  s['composeParsed'] = parsed;
  s['composeMissingFiles'] = missingFiles;
  s['composeMissingIds'] = missingIds;
  // 解析不了的行：**不许静默丢**。见 `_jsonlBadLines` 的注释。
  // 放在这里读是因为 `_roundState()` 是最后读 `$kComposePath` 的地方，
  // 前面 main() 里那次 `_readJsonl` 的坏行已经记进同一个集合了。
  s['composeBadLines'] = _jsonlBadLines.toList()..sort();

  // 成片台的 summary 只作**旁证**：它缺 `casesAttempted`/`missing`/`complete`
  // 三件套时不可作为完整性证据（`crash == 0` 本身不是证据）。
  final Object? sum = _readJson(kComposeSummaryPath);
  if (sum is Map<String, dynamic>) {
    final bool hasTriple = sum.containsKey('casesAttempted') &&
        sum.containsKey('missing') &&
        sum.containsKey('complete');
    s['summaryHasCompletenessTriple'] = hasTriple;
    s['summaryCrash'] = sum['crash'];
    s['summaryCases'] = sum['cases'];
    s['summaryOk'] = sum['ok'];
  } else {
    s['summaryHasCompletenessTriple'] = false;
  }
  return s;
}

/// 量具自检：跑完检查有没有产出结果文件。
///
/// 只看"有没有结果"，不拿工具自己的退出码当判据——判定门槛写在**门禁**里
/// （kEyelineMaxErrDeg / kRigidMaxErrDeg），不由被考的工具自己说了算。
/// 工具崩溃/超时会产不出文件，那才是 blocker。
Future<void> _instrument(
  String label,
  String outFile,
  List<String> cmd,
  List<String> blockers,
) async {
  final RunResult r = await runProcess('python', cmd,
      timeout: const Duration(minutes: 20));
  stdout.writeln('--- $label 退出码 ${r.exitCode} ---\n${r.stdout}');
  if (!File(outFile).existsSync()) {
    blockers.add('$label 未产出 $outFile（退出码 ${r.exitCode}）\n${r.tail(maxChars: 800)}');
  }
}

// ---------------------------------------------------------------------------
// 判定
// ---------------------------------------------------------------------------

/// 把真值 + 生产记录 + 独立测量拼成"每个夹具一条"的样本表。
///
/// 这是判定唯一的输入口径；evaluateP0 只吃它的输出，保持可被
/// `test/gate/p0_gate_judgment_test.dart` 用假数据直接考。
List<Map<String, dynamic>> buildSamples(Map<String, dynamic> inputs) {
  final Map<String, dynamic> eyeline = inputs['eyeline'] as Map<String, dynamic>? ?? <String, dynamic>{};
  final Map<String, Map<String, dynamic>> mine = <String, Map<String, dynamic>>{};
  for (final dynamic r in (eyeline['rows'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> m = r as Map<String, dynamic>;
    mine[m['id'] as String] = m;
  }

  final List<Map<String, dynamic>> samples = <Map<String, dynamic>>[];
  for (final dynamic raw in (inputs['compose'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    if (inputs['spec'] != null && c['specId'] != inputs['spec']) continue;
    final String id = c['id'] as String;
    final double truth = (c['truthTiltDeg'] as num).toDouble();
    final double applied = (c['straightenDeg'] as num?)?.toDouble() ?? 0.0;
    final String source = c['rollSource'] as String? ?? 'unknown';

    final Map<String, dynamic>? g = mine[id];
    double? measured;
    String by = 'none';
    if (g != null && g['ok'] == true) {
      measured = (g['tilt_deg'] as num).toDouble();
      by = 'gate_eyeline';
    }
    // 我的眼线量具测不出时，走 SIFT 源图↔成片配准：它不碰眼线、不碰 alpha，
    // 对"成片被裁坏"和"抠图打洞"两种破坏都免疫，实测 100/100 全部配得上。
    // 残余 = 真值 − 实测施加角，是被测量出来的，不是照抄生产记录。
    final Map<String, dynamic>? sift = _siftOf(inputs, id);
    if (measured == null && sift != null && sift['ok'] == true) {
      measured = (sift['residual_deg'] as num).toDouble();
      by = 'gate_sift_align';
    }
    // 我量不出来时，退回 qa-batch 的量测值，但标明出处——两者的独立性写在报告里。
    final Map<String, dynamic>? qa = _qaOf(inputs, id);
    if (measured == null &&
        qa != null &&
        qa['primary_tilt_deg'] != null &&
        qa['end_to_end_status'] != 'reliability_mismatch' &&
        qa['end_to_end_status'] != 'unmeasured') {
      measured = (qa['primary_tilt_deg'] as num).toDouble();
      by = 'qa_eyeline';
    }

    // 三条路径全测不出时，才退回恒等式。正常轮次这条应当为 0 条——
    // 一条都不该有，因为条款 7 要求"量测失效"的样本必须被独立复核，
    // 而不是换个说法当成通过。
    final bool derived = measured == null;
    if (derived) {
      measured = truth - applied;
      by = 'derived_identity';
    }

    samples.add(<String, dynamic>{
      'id': id,
      'corpus': c['corpus'],
      'truth': truth,
      'applied': applied,
      'source': source,
      'residual': measured,
      'residualBy': by,
      'derived': derived,
      'qa_residual': qa?['primary_tilt_deg'],
      'qa_status': qa?['end_to_end_status'],
      'qa_spread': qa?['methodSpreadDeg'],
      'gate_measurable': g != null && g['ok'] == true,
      'gate_reason': g == null ? 'not_in_eyeline_run' : g['reason'],
      'sift_ok': sift != null && sift['ok'] == true,
      'sift_applied': sift?['measured_applied_deg'],
      'sift_residual': sift?['residual_deg'],
      'sift_delta_vs_record': sift?['applied_delta_vs_record'],
    });
  }
  return samples;
}

Map<String, dynamic>? _qaOf(Map<String, dynamic> inputs, String id) {
  final Object? q = inputs['qaResidual'];
  if (q is! Map<String, dynamic>) return null;
  for (final dynamic it in (q['items'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> m = it as Map<String, dynamic>;
    if (m['id'] == id && m['specId'] == inputs['spec']) return m;
  }
  return null;
}

Map<String, dynamic>? _siftOf(Map<String, dynamic> inputs, String id) {
  final Object? s = inputs['siftAlign'];
  if (s is! Map<String, dynamic>) return null;
  for (final dynamic it in (s['rows'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> m = it as Map<String, dynamic>;
    if (m['id'] == id) return m;
  }
  return null;
}

/// G2B-P0 判定。纯函数：输入是测量结果，输出是条目表。
List<Map<String, dynamic>> evaluateP0(Map<String, dynamic> inputs) {
  final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> samples = buildSamples(inputs);
  final Map<String, dynamic> eyeSelf =
      inputs['eyelineSelftest'] as Map<String, dynamic>? ?? <String, dynamic>{};
  final Map<String, dynamic> rigidSelf =
      inputs['rigidSelftest'] as Map<String, dynamic>? ?? <String, dynamic>{};
  final List<String> blockers =
      (inputs['blockers'] as List<dynamic>? ?? <dynamic>[]).cast<String>();
  final Map<String, dynamic> devSelf =
      inputs['devSelfcheck'] as Map<String, dynamic>? ?? <String, dynamic>{};

  final double? eyeErr = (eyeSelf['max_abs_err_deg'] as num?)?.toDouble();
  final double? rigidErr = (rigidSelf['max_abs_err_deg'] as num?)?.toDouble();
  final bool eyeOk = eyeErr != null && eyeErr <= kEyelineMaxErrDeg;
  final bool rigidOk = rigidErr != null && rigidErr <= kRigidMaxErrDeg;
  final bool instrumentsOk = blockers.isEmpty && eyeOk && rigidOk;

  final List<Map<String, dynamic>> anchors =
      samples.where((Map<String, dynamic> s) => s['corpus'] == 'anchor').toList();
  final List<Map<String, dynamic>> straight =
      samples.where((Map<String, dynamic> s) => s['corpus'] == 'straight').toList();
  final List<Map<String, dynamic>> upright =
      samples.where((Map<String, dynamic> s) => s['corpus'] == 'uprightSynthetic').toList();
  final List<Map<String, dynamic>> rotated =
      samples.where((Map<String, dynamic> s) => s['corpus'] == 'rotated').toList();
  final List<Map<String, dynamic>> pupils =
      samples.where((Map<String, dynamic> s) => s['source'] == 'pupil').toList();

  // ---------------- P0.1a：锚点成片端到端残余 ----------------
  {
    final List<Map<String, dynamic>> cohort =
        anchors.where((Map<String, dynamic> s) => s['source'] == 'pupil').toList();
    final List<double> res =
        cohort.map((Map<String, dynamic> s) => (s['residual'] as double).abs()).toList();
    final double maxAbs = res.isEmpty ? double.nan : res.reduce(math.max);
    final double median = _median(res);
    // 下限数的是**不同照片**，不是行数。见 distinctPhotoCount 的注释：
    // 判据文本写的是"≥ 8 张不同照片"，用 `cohort.length` 判就是判据比它的名字松。
    final int? distinct =
        distinctPhotoCount(cohort, inputs['overlap'] as Map<String, dynamic>?);
    final bool pass = instrumentsOk &&
        distinct != null &&
        distinct >= kMinDistinctPhotos &&
        maxAbs <= kResidualMaxDeg &&
        median <= kResidualMedianMaxDeg;
    items.add(<String, dynamic>{
      'id': 'P0.1a',
      'description': '锚点残差（只用 pupil 锚点）：成片端到端残余 |residual| ≤ 1.5°，中位 ≤ 1.0°',
      'expected': '|residual| ≤ $kResidualMaxDeg，中位 ≤ $kResidualMedianMaxDeg，'
          '样本 ≥ $kMinDistinctPhotos 张不同照片（数**不同照片**，不数行数）',
      'actual': _text(
        <String>[
          distinct == null
              ? '**去重量具未产出/结论不完整，无法把行数折算成不同照片数** —— '
                  '本项按判不了处理（不退回行数：退回行数正是这条缺陷本身）'
              : '可计分锚点 ${cohort.length} 条 = **$distinct 张不同照片**，'
                  '下限 $kMinDistinctPhotos 张不同照片',
          '去重口径出自 `$kOverlapPath`（48×48 灰度签名逐对 MAE，≤5.0 记同图）：'
              '本轮判定 `c03≡c04` 为同一张照片（同图不同分辨率），故 11 行 → 10 张。'
              '**该量具分辨不了 `c10`/`c11`/`c12` 这类"同一场景的不同取景"**，'
              '声明不参与那三者的判定；法典条款 6 @ `98f3331` 裁定它们是**三张不同照片**、各自计数。'
              '量具不去重它们，方向上是保守的（只会让计数偏高、更容易过下限），'
              '因此不会制造假 FAIL，但也**不能**反过来用它论证"三张里有两张其实是同一张"。'
              '原始锚点栏 12 条，`p2` 不在锚点栏——它同现于 anchors 与 straight，'
              '成片台按 id 合并后归入 straight。',
          'max|残余| = ${_f(maxAbs)}，中位 = ${_f(median)}',
          _provenance(cohort),
          _sampleLine(cohort),
        ],
        blockers,
      ),
      'pass': pass,
      'manual': !instrumentsOk || distinct == null,
      'owner': instrumentsOk ? 'ml-porting' : 'gatekeeper（量具未通过自检，不计实现方责任）',
    });
  }

  // ---------------- P0.1b：条件覆盖率 ----------------
  {
    final List<Map<String, dynamic>> need =
        anchors.where((Map<String, dynamic> s) => (s['truth'] as double).abs() > kCoverageMinTruthDeg).toList();
    final List<Map<String, dynamic>> bad =
        need.where((Map<String, dynamic> s) => s['source'] == 'unavailable').toList();
    final List<Map<String, dynamic>> exempt =
        anchors.where((Map<String, dynamic> s) => (s['truth'] as double).abs() <= kCoverageMinTruthDeg &&
            s['source'] == 'unavailable').toList();
    items.add(<String, dynamic>{
      'id': 'P0.1b',
      'description': '条件覆盖率：真值 |tilt| > 1.5° 的锚点必须给出 pupil 估计，unavailable 必须 = 0',
      'expected': '需要摆正的 ${need.length} 条锚点上 unavailable = 0',
      'actual': _text(
        <String>[
          '需要摆正（|truth| > 1.5°）的锚点 ${need.length} 条，其中 unavailable ${bad.length} 条'
              '${bad.isEmpty ? "" : "：" + bad.map((Map<String, dynamic> s) => "${s['id']}(truth ${_f(s['truth'] as double)})").join("、")}',
          '|truth| ≤ 1.5° 而返回 unavailable 的 ${exempt.length} 条，按口径 2 可接受：'
              '${exempt.map((Map<String, dynamic> s) => "${s['id']}(${_f(s['truth'] as double)})").join("、")}',
        ],
        blockers,
      ),
      'pass': instrumentsOk && bad.isEmpty,
      'manual': !instrumentsOk,
      'owner': 'ml-porting',
    });
  }

  // ---------------- P0.2：不引入歪斜 ----------------
  {
    // 语料取自**成片台**（`$kComposePath`）的 `corpus` 字段，那里的标注是准的。
    // **不要改用覆盖率台的 `byCorpus`**：它把 uprightSynthetic 并进了 'anchor'
    // （`p0_coverage_test.dart:99` 硬写 'corpus': 'anchor'），用它取 P0.2 的样本
    // 会**整批漏掉且不报错**。
    //
    // `upright.length >= kUprightSyntheticMin` 这道下限是防"空集静默通过"：
    // `notPupil.isEmpty` 在 upright 为空时为真，光靠它会让"一张竖直样本都没有"
    // 也判 PASS——拿一个不存在的集合去证明"没有非 pupil"是假证据。
    final List<Map<String, dynamic>> cohort = <Map<String, dynamic>>[...straight, ...upright];
    final List<double> res =
        cohort.map((Map<String, dynamic> s) => (s['residual'] as double).abs()).toList();
    final double maxAbs = res.isEmpty ? double.nan : res.reduce(math.max);
    final List<Map<String, dynamic>> notPupil =
        upright.where((Map<String, dynamic> s) => s['source'] != 'pupil').toList();
    final bool pass = instrumentsOk &&
        cohort.isNotEmpty &&
        upright.length >= kUprightSyntheticMin &&
        maxAbs <= kResidualMaxDeg &&
        notPupil.isEmpty;
    items.add(<String, dynamic>{
      'id': 'P0.2',
      'description': '不引入歪斜：已知竖直样本残余 ≤ 1.5°，且 uprightSynthetic 必须返回 pupil',
      'expected': '|residual| ≤ $kResidualMaxDeg 且 $kUprightSyntheticMin 张 uprightSynthetic 全部 source=pupil',
      'actual': _text(
        <String>[
          '竖直样本 ${cohort.length} 条（用户 2.jpg ${straight.length} 条 + 合成竖直 ${upright.length} 条，'
              '后者下限 $kUprightSyntheticMin 条），max|残余| = ${_f(maxAbs)}'
              '${upright.length >= kUprightSyntheticMin ? "" : " —— **合成竖直样本不足，本项不可判**"}',
          'uprightSynthetic 来源分布：${_sourceHist(upright)}'
              '${notPupil.isEmpty ? "（全部 pupil）" : "—— 非 pupil：" + notPupil.map((Map<String, dynamic> s) => s['id'] as String).join("、")}',
          _sampleLine(cohort),
        ],
        blockers,
      ),
      'pass': pass,
      'manual': !instrumentsOk || upright.length < kUprightSyntheticMin,
      'owner': 'ml-porting',
    });
  }

  // ---------------- P0.3a：旋转等变（线性度） ----------------
  {
    final List<Map<String, dynamic>> cohort = pupils.isNotEmpty ? pupils : samples;
    final List<List<double>> estPts = cohort
        .where((Map<String, dynamic> s) => s['source'] == 'pupil')
        .map((Map<String, dynamic> s) => <double>[s['truth'] as double, s['applied'] as double])
        .toList();
    final double estSlope = _slope(estPts);

    final List<List<double>> resPts =
        cohort.map((Map<String, dynamic> s) => <double>[s['truth'] as double, s['residual'] as double]).toList();
    final double resSlope = _slope(resPts);
    final double resIntercept = _intercept(resPts);
    final List<Map<String, dynamic>> over = cohort
        .where((Map<String, dynamic> s) => (s['residual'] as double).abs() > kResidualMaxDeg)
        .toList()
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          (b['residual'] as double).abs().compareTo((a['residual'] as double).abs()));
    final List<Map<String, dynamic>> excluded =
        samples.where((Map<String, dynamic> s) => s['source'] != 'pupil').toList();

    final bool pass = instrumentsOk &&
        resSlope.isFinite &&
        resSlope.abs() <= kResidSlopeAbsMax &&
        resIntercept.abs() <= kResidInterceptAbsMax &&
        over.isEmpty;
    items.add(<String, dynamic>{
      'id': 'P0.3a',
      'description': '旋转等变：① 估计值 vs 真值斜率 ∈[0.85,1.15]（只作诊断）；'
          '② 成片残余 vs 真值斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°（硬判据，口径无关）',
      'expected': '② 斜率 |·| ≤ $kResidSlopeAbsMax、|截距| ≤ $kResidInterceptAbsMax°、max|残余| ≤ $kResidualMaxDeg°',
      'actual': _text(
        <String>[
          '② 硬判据：残余 vs 真值 斜率 = ${_f(resSlope)}（|·| ≤ 0.15），截距 = ${_f(resIntercept)}°'
              '（|·| ≤ 0.5），max|残余| = ${_f(over.isEmpty ? 0.0 : (over.first['residual'] as double).abs())}°'
              '（≤ 1.5）',
          '超 1.5° 的夹具 ${over.length} 条：${over.map((Map<String, dynamic> s) => "${s['id']}(${_f(s['residual'] as double)}°)").join("、")}',
          '只用 pupil 夹具 ${cohort.length} 条（原始 ${samples.length} 条）',
          '① 诊断：估计值 vs 真值 斜率 = ${_f(estSlope)}（带 [0.85, 1.15]，不参与 PASS/FAIL）',
          '按口径 1 排除在残余统计外的 unavailable 样本 ${excluded.length} 条'
              '（它们的账由 P0.3b 条件覆盖率算，不许在这里被悄悄算成通过）：'
              '${excluded.map((Map<String, dynamic> s) => s['id'] as String).join("、")}',
          _provenance(cohort),
        ],
        blockers,
      ),
      'pass': pass,
      'manual': !instrumentsOk,
      'owner': 'ml-porting',
    });
  }

  // ---------------- P0.3b：旋转等变（覆盖率） ----------------
  {
    final List<Map<String, dynamic>> need =
        rotated.where((Map<String, dynamic> s) => (s['truth'] as double).abs() > kCoverageMinTruthDeg).toList();
    final List<Map<String, dynamic>> bad =
        need.where((Map<String, dynamic> s) => s['source'] == 'unavailable').toList();
    final List<Map<String, dynamic>> exempt =
        rotated.where((Map<String, dynamic> s) => (s['truth'] as double).abs() <= kCoverageMinTruthDeg &&
            s['source'] == 'unavailable').toList();
    items.add(<String, dynamic>{
      'id': 'P0.3b',
      'description': '旋转夹具条件覆盖率：真值 |tilt| > 1.5° 的夹具上 unavailable 必须 = 0',
      'expected': '需要摆正的 ${need.length} 条夹具上 unavailable = 0',
      'actual': _text(
        <String>[
          bad.isEmpty
              ? '需要摆正（|truth| > 1.5°）的 ${need.length} 条夹具上 unavailable = 0'
              : '违规 ${bad.length} 条（需要摆正 |truth| > 1.5° 却返回 unavailable）：'
                  '${bad.map((Map<String, dynamic> s) => "${s['id']}(truth ${_f(s['truth'] as double)}°)").join("、")}'
                  '——这 ${bad.length} 条成片未施加任何旋转，仍歪着对应角度',
          '旋转夹具原始总数 ${rotated.length} 条，需要摆正 ${need.length} 条',
          '|truth| ≤ 1.5° 而 unavailable 的 ${exempt.length} 条，按口径 2 可接受',
          '分母：可计分 ${rotated.length} 条 / 原始 ${rotated.length} 条（无样本因量测失效被扣除，见条款 7 样本账）',
        ],
        blockers,
      ),
      'pass': instrumentsOk && bad.isEmpty,
      'manual': !instrumentsOk,
      'owner': 'ml-porting',
    });
  }

  // ---------------- P0.4：诚实性与分布 ----------------
  {
    final List<Map<String, dynamic>> unavail =
        samples.where((Map<String, dynamic> s) => s['source'] == 'unavailable').toList();
    // unavailable 必须 rollDeg = 0.0：compose 记录里 applied 就是施加角，
    // rollDeg 与它同源；这里同时看记录里的 applied 与真值无关性。
    final List<Map<String, dynamic>> dishonest =
        unavail.where((Map<String, dynamic> s) => (s['applied'] as double).abs() > 1e-9).toList();
    final List<Map<String, dynamic>> given =
        samples.where((Map<String, dynamic> s) => s['source'] == 'given').toList();
    final bool pass = instrumentsOk && dishonest.isEmpty && given.isEmpty;
    items.add(<String, dynamic>{
      'id': 'P0.4',
      'description': '诚实性与分布：报告 RollSource 分布；unavailable 的施加角必须 = 0.0；'
          '禁止回退到 YuNet 眼睑路径（夹具里不得出现 given）',
      'expected': 'unavailable 样本施加角 = 0 的违规数 = 0，且不得出现 source=given',
      'actual': _text(
        <String>[
          '全量可合成样本 ${samples.length} 条，来源分布：${_sourceHist(samples)}',
          '锚点：${_sourceHist(anchors)}；竖直：${_sourceHist(<Map<String, dynamic>>[...straight, ...upright])}；夹具：${_sourceHist(rotated)}',
          'unavailable 的施加角 ≠ 0 的违规 ${dishonest.length} 条；夹具里 source=given 的 ${given.length} 条',
        ],
        blockers,
      ),
      'pass': pass,
      'manual': !instrumentsOk,
      'owner': 'ml-porting',
    });
  }

  // ---------------- P0.5a：dev_selfcheck ----------------
  {
    final int code = (devSelf['exitCode'] as num?)?.toInt() ?? -1;
    final String tail = devSelf['tail'] as String? ?? '';
    final RegExp re = RegExp(r'\+(\d+)(?:\s*-(\d+))?');
    final Iterable<RegExpMatch> ms = re.allMatches(tail);
    final RegExpMatch? last = ms.isEmpty ? null : ms.last;
    final int passedN = last == null ? -1 : int.parse(last.group(1)!);
    final int failedN = last?.group(2) == null ? 0 : int.parse(last!.group(2)!);
    final bool pass = code == 0 && passedN >= 9 && failedN == 0;
    items.add(<String, dynamic>{
      'id': 'P0.5a',
      'description': '不回归：dev_selfcheck 9/9',
      'expected': '退出码 0 且 通过 ≥ 9、失败 = 0',
      'actual': '退出码=$code；解析到 通过=$passedN 失败=$failedN（命中「+$passedN」）\n$tail',
      'pass': pass,
      'manual': false,
      'owner': 'imaging',
    });
  }

  // ---------------- P0.5b：2B.8 不回归（用成片实测反查施加几何） ----------------
  {
    // 2B.8 只问"给了角就转对"：成片实测旋转 应等于 真值 − 施加角。
    // 这里不注入夹具，而是拿真值已知的夹具反查同一件事，覆盖 90+ 条。
    final List<Map<String, dynamic>> meas = samples
        .where((Map<String, dynamic> s) => s['residualBy'] == 'gate_eyeline' || s['residualBy'] == 'qa_eyeline')
        .toList();
    final List<double> dev =
        meas.map((Map<String, dynamic> s) => (s['residual'] as double) - ((s['truth'] as double) - (s['applied'] as double))).toList();
    final double maxDev = dev.isEmpty ? double.nan : dev.map((double d) => d.abs()).reduce(math.max);
    final bool pass = instrumentsOk && meas.length >= 20 && maxDev <= kResidualMaxDeg;
    // SIFT 路径直接把"管线实际转了多少度"量出来，与生产记录对账——这是 2B.8
    // 最干净的证据：不注入夹具、不读诊断，纯几何。
    final List<double> siftDeltas = samples
        .where((Map<String, dynamic> s) => s['sift_delta_vs_record'] != null)
        .map((Map<String, dynamic> s) => (s['sift_delta_vs_record'] as num).toDouble().abs())
        .toList();
    final double siftMax =
        siftDeltas.isEmpty ? double.nan : siftDeltas.reduce(math.max);
    items.add(<String, dynamic>{
      'id': 'P0.5b',
      'description': '不回归：2B.8 摆正几何（成片实测旋转 = 真值 − 施加角）',
      'expected': '两个**分开报**的子量都要过：'
          '① 施加几何 —— SIFT 实测施加角 vs 生产记录 |差| ≤ $kResidualMaxDeg°；'
          '② 跨量具一致性 —— 眼线实测残余 vs (真值−施加角) ≤ $kResidualMaxDeg°',
      // 本项有两个量，含义不同、量级差一个数量级，必须分开写清楚，
      // 否则读者会把"擦线的那个"和"余量充足的那个"混成一个数。
      //   ① 施加几何（0.070°）：直接量"管线转了多少度"，不经过任何成片端测。
      //      这才是 2B.8 的本体（"给了角就转对"），也是唯一口径无关的量。
      //   ② 跨量具一致性（1.450°）：拿眼线在成片上量出的残余，去对"真值−记录施加角"。
      //      它同时含**眼线量具自身噪声**，真实几何误差被淹没在里面，所以它擦线。
      'actual': _text(
        <String>[
          '①【判据量·施加几何】SIFT 源图↔成片配准，可配准 ${siftDeltas.length} 条，'
              '实测施加角 vs 生产记录 |差| 最大 ${_f(siftMax)}° '
              '（阈值 $kResidualMaxDeg°，余量 ${_f(kResidualMaxDeg - siftMax)}°）'
              '—— 此项不读眼线、不读 alpha、不读生产诊断，是 2B.8 本体的直接测量',
          '②【辅助量·跨量具一致性】眼线路径，可实测夹具 ${meas.length} 条，'
              '|眼线实测残余 − (真值−施加角)| 最大 ${_f(maxDev)}° '
              '（阈值 $kResidualMaxDeg°，余量 ${_f(kResidualMaxDeg - maxDev)}°，'
              '眼线量具自检误差 ${eyeErr == null ? "N/A" : _f(eyeErr)}°）'
              '—— 这个量把**量具噪声**和几何误差混在一起，余量小于量具误差，**不作为定罪依据**',
          '说明：本项不注入夹具，而是用真值已知的旋转夹具反查同一件事；'
              '施加几何一旦出问题（符号反了/没转），① 会立刻爆到 2 倍真值',
        ],
        blockers,
      ),
      'pass': pass && siftDeltas.isNotEmpty && siftMax <= kResidualMaxDeg,
      'subchecks': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': '① 施加几何',
          'value': siftMax,
          'criterion': true,
          'margin': kResidualMaxDeg - siftMax,
          'instrumentErr': rigidErr,
        },
        <String, dynamic>{
          'name': '② 跨量具一致性',
          'value': maxDev,
          'criterion': false,
          'margin': kResidualMaxDeg - maxDev,
          'instrumentErr': eyeErr,
        },
      ],
      // 贴线记账：本项的判决落在眼线量具分辨不出的区间里时，单支量具的
      // FAIL 不足以定罪，必须第二支量具（SIFT 配准）独立复现同一超线。
      // 阈值不动（判据已冻结），只在报告里把余量、量具误差、复核结论一并亮出来。
      'margin': kResidualMaxDeg - maxDev,
      'instrumentErr': eyeErr,
      'corroboration': 'margin > instrumentErr 才是确定性违规；'
          '若 margin < instrumentErr，须 SIFT 路径独立复现同一超线才计违规，'
          '否则记「边界噪声 / 证据不足」，不消耗实现方修复轮次（本条不适用 P0.3a：'
          'P0.3a 超阈值 7 倍以上，两支量具均独立复现，按原样记 FAIL）',
      'corroborated': siftMax <= kResidualMaxDeg,
      'manual': !instrumentsOk,
      'owner': 'imaging',
    });
  }

  // ---------------- P0.5c：G2B 其余项 / G4 已过项不退化 ----------------
  {
    final Map<String, dynamic>? g2b = inputs['gateG2B'] as Map<String, dynamic>?;
    final Map<String, dynamic>? g4 = inputs['gateG4'] as Map<String, dynamic>?;
    if (g2b == null || g4 == null) {
      items.add(<String, dynamic>{
        'id': 'P0.5c',
        'description': '不回归：G2B 其余项 / G4 已过项',
        'expected': 'out/gate_G2B.json 与 out/gate_G4.json 全 PASS',
        'actual': '缺 ${g2b == null ? "out/gate_G2B.json " : ""}${g4 == null ? "out/gate_G4.json" : ""}，'
            '无法判定。本轮上游未全过，未触发重跑。',
        'pass': false,
        'manual': true,
        'owner': 'gatekeeper（缺既有 gate 结果，留待下轮）',
      });
    } else {
      // 法典 P0.5 的原话是"G4 **已过项**全部不退化"——只有原本通过的项才谈得上退化。
      // 直接要求"两个 gate 全 PASS"会凭空多出一条法典没有的要求（现成的反例：
      // G4/4.7 真机内存本就是既有未过项，把它算成 P0 的账是冤枉 ml-porting）。
      // 而"有没有退化"只能靠重跑才知道，本轮上游没修好、不重跑，故标 MANUAL，
      // 并把既有的未过项如实列出来，不许藏。
      final List<String> failing = <String>[];
      for (final Map<String, dynamic> g in <Map<String, dynamic>>[g2b, g4]) {
        for (final dynamic it in (g['items'] as List<dynamic>? ?? <dynamic>[])) {
          final Map<String, dynamic> m = it as Map<String, dynamic>;
          if (m['pass'] != true) failing.add('${g['gate']}/${m['id']}');
        }
      }
      items.add(<String, dynamic>{
        'id': 'P0.5c',
        'description': '不回归：2B.8 之外的 G2B 项 / G4 已过项不退化（判据只覆盖"原本通过的项"）',
        'expected': '原本通过的项重跑后仍 PASS；本项需重跑才能判定',
        'actual': _text(
          <String>[
            '本轮未重跑设备端（上游 P0.3a/P0.3b 未修好时重跑不产生新信息，一轮约 40 分钟）。',
            '既有 gate 结果里的未过项：${failing.isEmpty ? "无" : failing.join("、")}',
            failing.isEmpty
                ? ''
                : '注意：这些是**本轮之前就存在的**未过项，不是 P0 引入的退化；'
                    '逐条原因见各自的 out/GATE_*_r*.md，不计在 ml-porting 账上。',
          ],
          blockers,
        ),
        'pass': false,
        'manual': true,
        'owner': 'gatekeeper（本轮未重跑，无法判定是否退化；留待上游修好后补跑）',
      });
    }
  }

  // -------- PIN：生成的分母是不是手写分母 --------
  //
  // 这条不是 ACCEPTANCE 里的条目，是**判据分母本身的完整性**，与 AC 同性质：
  // 它红了，那一轮所有以真值为分母的判定都失去意义。所以它单独成项、参与总判。
  {
    final Object? raw = inputs['denominatorAgreement'];
    if (raw is! Map<String, dynamic>) {
      items.add(<String, dynamic>{
        'id': 'PIN',
        'description': '判据分母：生成的 `$kTruthPath` 与手写的 `$kTruthV0Path` 逐条相等',
        'expected': '逐条相等（唯一允许的差：${kDenominatorExtraAllowance.join("、")}）',
        'actual': '未产出（`inputs["denominatorAgreement"]` 缺失或类型不对），'
            '**本轮不可判**——不默认相等。',
        'pass': false,
        'manual': true,
        'owner': 'gatekeeper（检查未产出，不计实现方责任）',
      });
    } else {
      final bool ok = raw['pass'] == true;
      final List<dynamic> probs =
          <dynamic>[...(raw['problems'] as List<dynamic>? ?? <dynamic>[]),
                   ...(raw['extraUndeclared'] as List<dynamic>? ?? <dynamic>[])];
      items.add(<String, dynamic>{
        'id': 'PIN',
        'description': '判据分母：生成的 `$kTruthPath` 与手写的 `$kTruthV0Path` 逐条相等',
        'expected': '逐条相等（唯一允许的差：'
            '${kDenominatorExtraAllowance.isEmpty ? "无" : kDenominatorExtraAllowance.join("、")}）',
        'actual': ok
            ? '逐条相等。${raw['summary'] ?? ""}'
            : '**不相等**：${raw['error'] ?? raw['summary'] ?? ""}\n'
                '${probs.map((dynamic x) => "- $x").join("\n")}',
        'pass': ok,
        'manual': raw['readable'] != true,
        'owner': ok ? null : 'qa-batch（`$kTruthV0Path` 与 `$kTruthPath` 属其中）',
      });
    }
  }

  // -------- EVID：派生数字是不是盘上产物的函数 --------
  {
    final Object? raw = inputs['evidenceProvenance'];
    if (raw is! Map<String, dynamic>) {
      items.add(<String, dynamic>{
        'id': 'EVID',
        'description': '派生块证据溯源：`${kEvidenceProvenancePointer.join("/")}` '
            '记的摘要 == 盘上产物现算的摘要',
        'expected': '逐份相符',
        'actual': '未产出（`inputs["evidenceProvenance"]` 缺失或类型不对），'
            '**本轮不可判**——不默认相符。',
        'pass': false,
        'manual': true,
        'owner': 'gatekeeper（检查未产出，不计实现方责任）',
      });
    } else {
      final bool ok = raw['pass'] == true;
      final List<dynamic> probs = raw['problems'] as List<dynamic>? ?? <dynamic>[];
      items.add(<String, dynamic>{
        'id': 'EVID',
        'description': '派生块证据溯源：`${kEvidenceProvenancePointer.join("/")}` '
            '记的摘要 == 盘上产物现算的摘要',
        'expected': '逐份相符（**只证"叙述与产物一致"，不证"产物出自当前代码"**）',
        'actual': ok
            ? '相符。${raw['summary'] ?? ""}'
            : '**不相符**：${raw['error'] ?? raw['summary'] ?? ""}\n'
                '${probs.map((dynamic x) => "- $x").join("\n")}',
        'pass': ok,
        'manual': raw['readable'] != true,
        'owner': ok
            ? null
            : 'qa-batch（叙述与产物不同源；若产物被 finalize 之后重跑过，重跑 finalize 即可）',
      });
    }
  }

  // ---------------- AC：防作弊 ----------------
  {
    // **缺输入绝不允许默认成"清白"。** 这里以前写成
    //   inputs['anticheat'] ?? {'clean': true, ...}
    // 等于把"我不知道"翻译成"干净"——巡检抛异常、键没设上、将来有人构造
    // inputs 时漏了这个键，门禁都会静默报 AC PASS。而 AC 恰恰是最可疑的一条
    // （条款 1 的可提交面依赖 diff，不看未跟踪文件的历史）。
    // 现在：缺失 → MANUAL，pass 恒 false，报告写明"本轮不可判"。
    final Object? rawAc = inputs['anticheat'];
    if (rawAc is! Map<String, dynamic>) {
      items.add(<String, dynamic>{
        'id': 'AC',
        'description': 'ACCEPTANCE 防作弊条款 1–6',
        'expected': '0 命中',
        'actual': '防作弊巡检未产出（`inputs["anticheat"]` 缺失或类型不对），'
            '**本轮不可判**——不默认清白。',
        'pass': false,
        'manual': true,
        'owner': 'gatekeeper（巡检未产出，不计实现方责任）',
      });
    } else {
      final Map<String, dynamic> ac = rawAc;
      // 用 `== true`（而非真值判断）：缺键/`null`/非布尔一律落到"非 clean"。
      final bool clean = ac['clean'] == true;
      // 巡检自己报"判不了"时，**不得**当清白：仪表看不见对象时必须说
      // "我看不见"，而不是说"没有"。这是同一形态在本链上的最后一处。
      final List<dynamic> undecidable =
          ac['undecidable'] as List<dynamic>? ?? <dynamic>[];
      if (undecidable.isNotEmpty) {
        items.add(<String, dynamic>{
          'id': 'AC',
          'description': 'ACCEPTANCE 防作弊条款 1–6',
          'expected': '0 命中',
          'actual': '**本轮不可判**：防作弊巡检自身有判不了的扫描——'
              '${undecidable.join("；")}。\n'
              '（扫描的退出码与 stdout 是否为空已记进 out/gate_P0.json 的 evidence；'
              '空输出与"确实零命中"必须可区分，判不了就不许报清白。）',
          'pass': false,
          'manual': true,
          'owner': 'gatekeeper（巡检自身不可判，不计实现方责任）',
        });
      } else {
        items.add(<String, dynamic>{
          'id': 'AC',
          'description': 'ACCEPTANCE 防作弊条款 1–6',
          'expected': '0 命中',
          'actual': clean
              ? '清白（${inputs['acSummary'] ?? ""}）'
              : (ac['violations'] as List<dynamic>? ?? <dynamic>[])
                  .map((dynamic v) => (v as Map<String, dynamic>)['path'] +
                      ' ← ' +
                      (v['attribution'] as String) +
                      '：' +
                      (v['detail'] as String))
                  .join('\n'),
          'pass': clean,
          'manual': false,
          'owner': clean ? null : '见每条的 attribution',
        });
      }
    }
  }

  return _applyRoundValidity(items, inputs);
}

/// 一轮判决只能由**同一个被冻结、被标识的代码状态**上的测量推导出来。
///
/// 存在理由（2026-09-17，主会话裁定，源自 r1 的真实缺陷）：r1 的判决是**拼起来的**
/// ——P0.1a/2/3a/3b 来自 qa-batch 在它自己那版工作树上产出的 `P0_compose_items.jsonl`，
/// 而 P0.5a 来自本机**当前**工作树编译的代码。两半可能不是同一版代码，
/// 所以 r1 不是"对某个单一代码状态的判决"，只是基线测量。
///
/// **加一行说明拦不住它**（r1 就是这么滑过去的），所以这里直接令该轮**无效**：
/// 所有条目 pass=false、manual=true，理由写在 actual 里。无效轮不消耗实现方的
/// 修复轮次，也不得被引用为判决。
List<Map<String, dynamic>> _applyRoundValidity(
  List<Map<String, dynamic>> items,
  Map<String, dynamic> inputs,
) {
  final List<String> reasons = _roundInvalidReasons(inputs);
  if (reasons.isEmpty) return items;
  final String why = '**本轮无效：${reasons.join("；")}**';
  return items.map((Map<String, dynamic> i) {
    return <String, dynamic>{
      ...i,
      'pass': false,
      'manual': true,
      'roundInvalid': true,
      'actual': '$why\n原判定依据（**不作为判决**）：\n${i['actual']}',
      'owner': 'gatekeeper（本轮输入不可信，不计实现方责任）',
    };
  }).toList();
}

/// 本轮输入是否可信。返回空表 = 可信；非空 = 逐条说明为何无效。
List<String> _roundInvalidReasons(Map<String, dynamic> inputs) {
  final List<String> r = <String>[];
  final Object? rs = inputs['roundState'];
  if (rs is! Map<String, dynamic>) {
    // 缺失**不默认可信**——这正是 AC 那一处踩过的坑，不能在这里重演。
    r.add('缺少 `roundState`，无法证明所有输入来自同一个被冻结的代码状态');
    return r;
  }
  if (rs['frozen'] != true) {
    r.add('工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，'
        '唯一豁免 `$kFreezeExemptPath`）：'
        '${(rs['dirty'] as List<dynamic>? ?? <dynamic>[]).join("、")}');
  }
  final int missing = (rs['composeMissingFiles'] as num?)?.toInt() ?? -1;
  final int declared = (rs['composeDeclared'] as num?)?.toInt() ?? -1;
  final int parsed = (rs['composeParsed'] as num?)?.toInt() ?? -1;
  if (missing < 0 || declared < 0 || parsed < 0) {
    r.add('缺少样本解析计数（declared/parsed/missingFiles 三件套不齐）');
  } else {
    if (missing > 0) {
      r.add('$declared 条样本里有 $missing 条的成片文件不存在');
    }
    if (declared != parsed) {
      r.add('清单声明 $declared 条，实际只解析到 $parsed 条'
          '（静默 `continue` 是已知失效模式：exit 0、crash 0、却在零样本上判定）');
    }
  }
  // 第四条：样本清单里有**解析不了的行**。从前那种行被一个空 catch 吞掉，
  // 只在页面上少一条 —— 而 `parsed` 只数本 spec 的行，所以坏行未必表现为条数差。
  final List<String> badLines =
      (rs['composeBadLines'] as List<dynamic>? ?? <dynamic>[]).map((dynamic e) => '$e').toList();
  if (badLines.isNotEmpty) {
    r.add('$kComposePath 有 ${badLines.length} 行解析不了（已列进报告，未静默丢弃）：'
        '${badLines.take(5).join("；")}${badLines.length > 5 ? " …" : ""}');
  }
  // 第五条：`out/` 是共享输出目录，不受冻结约束，所以"工作树是干净的"并不能
  // 保证**盘上这几份测量产出**就是当前代码跑出来的。它们可能是上一轮的遗留。
  // 缺这一条时，一份过期的 `P0_output_residual.json` 会被当成当轮读数 ——
  // 与 r1 判决作废同源（判决由两个不同代码状态的测量拼成），换个入口而已。
  final Object? pv = inputs['provenance'];
  if (pv is! Map<String, dynamic>) {
    r.add('缺少 `provenance`（测量产出的代码来源绑定），无法证明盘上的数是当前代码跑的');
  } else {
    for (final dynamic x in (pv['reasons'] as List<dynamic>? ?? <dynamic>[])) {
      r.add('$x');
    }
  }
  // 第六条：判据分母的**锚**本轮被重建过 → 作废。
  //
  // 这一条拦的是"删掉钉 = 本轮免疫"：`truthDrift` 在基线文件不存在时会建立一份新的
  // 并返回 `baselineEstablished = true`，而旧逻辑下那一句是"本轮不判 FAIL"。
  // 于是删一个文件就能把"改过判据分母"洗掉 —— 比改一个数容易得多。
  // 现在重建轮一律 void：删文件买不到通过，只买到一轮作废，且作废写进报告。
  final Object? td = inputs['truthDriftResult'];
  if (td is TruthDrift && td.baselineEstablished) {
    r.add(kBaselineRetakeNote);
  }
  // 第六条之二：换成"手写分母按内容钉"之后补上的两道。
  //
  // 只加 PIN/EVID 两个**条目**是不够的：条目红了确实会让总判变 FAIL，但那是
  // "某个实现方没达标"的措辞；这两件事的正确定性是**本轮输入不可信**——
  // 分母对不上时，P0.1a / P0.2 / P0.3a / P0.3b 读到的每个数都没有立足点，
  // 报成"某条 AC 没过"会误导回派方向。所以**不可判**那一侧也走 void。
  //
  // 注意分工：`readable == false`（取不到）→ void，不赖实现方；
  // `readable == true` 而内容不等 → 由 PIN/EVID 条目判 FAIL 并点名，不走这里。
  final Object? dax = inputs['denominatorAgreement'];
  if (dax is! Map<String, dynamic> || dax['readable'] != true) {
    r.add('生成分母与手写分母的一致性**不可判**：'
        '${dax is Map<String, dynamic> ? (dax['error'] ?? "未给出理由") : "缺 `denominatorAgreement`"}。'
        '分母对不上时，本轮所有以真值为分母的判定都没有立足点');
  }
  final Object? evx = inputs['evidenceProvenance'];
  if (evx is! Map<String, dynamic> || evx['readable'] != true) {
    r.add('派生块证据溯源**不可判**：'
        '${evx is Map<String, dynamic> ? (evx['error'] ?? "未给出理由") : "缺 `evidenceProvenance`"}');
  }
  return r;
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

double _median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final List<double> s = <double>[...xs]..sort();
  final int n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}

double _slope(List<List<double>> pts) {
  if (pts.length < 2) return double.nan;
  final double mx = pts.map((List<double> p) => p[0]).reduce((double a, double b) => a + b) / pts.length;
  final double my = pts.map((List<double> p) => p[1]).reduce((double a, double b) => a + b) / pts.length;
  double num = 0, den = 0;
  for (final List<double> p in pts) {
    num += (p[0] - mx) * (p[1] - my);
    den += (p[0] - mx) * (p[0] - mx);
  }
  return den == 0 ? double.nan : num / den;
}

double _intercept(List<List<double>> pts) {
  if (pts.isEmpty) return double.nan;
  final double mx = pts.map((List<double> p) => p[0]).reduce((double a, double b) => a + b) / pts.length;
  final double my = pts.map((List<double> p) => p[1]).reduce((double a, double b) => a + b) / pts.length;
  return my - _slope(pts) * mx;
}

String _f(double v) => v.isFinite ? v.toStringAsFixed(3) : 'N/A';

String _sourceHist(List<Map<String, dynamic>> ss) {
  final Map<String, int> h = <String, int>{};
  for (final Map<String, dynamic> s in ss) {
    final String k = s['source'] as String;
    h[k] = (h[k] ?? 0) + 1;
  }
  final List<String> ks = h.keys.toList()..sort();
  return '{${ks.map((String k) => "$k: ${h[k]}").join(", ")}}';
}

/// 量测出处统计：多少条是 gatekeeper 自己量的、多少条是退回 qa-batch 的、
/// 多少条只能用已验证恒等式推出。**不许有来历不明的数字。**
String _provenance(List<Map<String, dynamic>> ss) {
  final Map<String, int> h = <String, int>{};
  for (final Map<String, dynamic> s in ss) {
    h[s['residualBy'] as String] = (h[s['residualBy'] as String] ?? 0) + 1;
  }
  final List<String> ks = h.keys.toList()..sort();
  return '残余出处：{${ks.map((String k) => "$k: ${h[k]}").join(", ")}}'
      '（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）';
}

String _sampleLine(List<Map<String, dynamic>> ss) {
  return ss
      .map((Map<String, dynamic> s) =>
          "${s['id']}: truth=${_f(s['truth'] as double)} applied=${_f(s['applied'] as double)} "
          "resid=${_f(s['residual'] as double)} src=${s['source']} by=${s['residualBy']}")
      .join('\n');
}

String _text(List<String> lines, List<String> blockers) {
  final List<String> ls = lines.where((String l) => l.trim().isNotEmpty).toList();
  if (blockers.isNotEmpty) ls.add('阻塞：${blockers.join("；")}');
  return ls.join('\n');
}

Map<String, dynamic> _readJson(String path) {
  final File f = File(path);
  if (!f.existsSync()) return <String, dynamic>{};
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// `_readJsonl` 里**解析不了的行**。
///
/// 从前这里是一个带注释的空 catch（"单行坏掉不该让整轮判定崩掉；缺的样本会在
/// 结果里以条数差暴露出来"）。**那个理由不成立**：条数差只对本 spec 的行敏感，
/// 而 `parsed` 只数 `specId == kSpec` 的行 —— 一条被改坏的非本 spec 行会同时从
/// 计数与视线里消失。空 catch 一律不许，所以改成把行号与原因记下来，
/// 由 `_roundInvalidReasons` 判本轮作废。
final Set<String> _jsonlBadLines = <String>{};

List<Map<String, dynamic>> _readJsonl(String path) {
  final File f = File(path);
  if (!f.existsSync()) return <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  final List<String> lines = f.readAsLinesSync();
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (line.trim().isEmpty) continue;
    try {
      out.add(jsonDecode(line) as Map<String, dynamic>);
    } catch (e) {
      _jsonlBadLines.add('$path:${i + 1}: ${e.runtimeType}: $e');
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 收尾：防作弊 + 落盘
// ---------------------------------------------------------------------------

Future<void> _finish({
  required String outPath,
  required int round,
  required List<Map<String, dynamic>> items,
  required Map<String, String> hashes,
  required Map<String, dynamic> inputs,
  required HashScan hashScanResult,
  required TruthDrift truthDriftResult,
}) async {
  final Map<String, String>? prev =
      _readHashes(File(kHashesRolling).existsSync() ? kHashesRolling : null);
  final int srcCount = countFiles('test/golden/src', extensions: <String>{'.jpg', '.jpeg', '.png'});
  final int refCount = countFiles('test/golden/ref', extensions: <String>{'.png'});
  final Map<String, dynamic> ac = await patrol(
    baseline: kBaseline,
    currentHashes: hashes,
    prevHashes: prev,
    goldenSrcCount: srcCount,
    goldenRefCount: refCount,
    prevGoldenSrcCount: _readCount(kHashesRolling, 'golden_src'),
    prevGoldenRefCount: _readCount(kHashesRolling, 'golden_ref'),
    selfTouched: _selfTouched(),
    unhashable: hashScanResult.unhashable,
    judgmentInputDrift: <String>[
      ...truthDriftResult.numericChanges,
      // 换钉子对象但没登记 —— 与"改了一个数"同性质（都是绕开判据分母的冻结），
      // 所以走同一条通道判违规，不另开一条只在报告里出现、不参与判定的说明。
      if (truthDriftResult.pinRetargetUndeclared != null)
        '**钉子对象被换成未登记的目标**：${truthDriftResult.pinRetargetUndeclared}'
            '（旧 `$kTruthPath` → 新 `${truthDriftResult.pinTo}`，'
            '不在 `kPinRetargetLedger` 里）',
    ],
    judgmentInputNote: truthDriftResult.describe(),
  );
  inputs['anticheat'] = ac;
  inputs['qaResidual'] = _readJson('out/P0_output_residual.json');
  inputs['acSummary'] = '**条款 1 自 `7773df4` 起才真正执行 —— 该 commit 之前各轮的'
      '「清白」在条款 1 上是空的，不得引用为历史**；'
      '黄金集 src=$srcCount ref=$refCount；'
      'skip/catch 扫描：${_scanSummary(ac)}；'
      '**判据分母内容钉（$kTruthV0Path 手写件）**：${truthDriftResult.describe()}；'
      '**分母一致性（生成件 vs 手写件）**：'
      '${(inputs['denominatorAgreement'] as Map<String, dynamic>?)?['summary'] ?? "（缺 denominatorAgreement，不可判）"}；'
      '**派生数字证据溯源**：'
      '${(inputs['evidenceProvenance'] as Map<String, dynamic>?)?['summary'] ?? "（缺 evidenceProvenance，不可判）"}；'
      '**测量产出同源**：${(inputs['provenance'] as Map<String, dynamic>?)?['summary'] ?? "（缺 provenance，无法自证）"}；'
      '受钉文件 ${hashes.length} 个'
      '${hashScanResult.unhashable.isEmpty ? "" : "，**另有 ${hashScanResult.unhashable.length} 个算不出哈希（已判不可判，未从表中消失）**"}；'
      '基线 $kBaseline 以来 test/ tools/gate/ ACCEPTANCE/RUBRIC 无实现类 agent 改动；'
      '门禁自身未提交改动 ${_selfTouched().length} 个，已在 out/GATE_P0_selfchanges.txt 逐条自报';
  // AC 条目要吃 patrol 结果，而 patrol 依赖本轮的哈希与黄金集计数，
  // 只能等这些算完再重跑一次纯判定（纯函数，代价可忽略）。
  final List<Map<String, dynamic>> finalItems = evaluateP0(inputs);
  if (finalItems.length != items.length) {
    throw StateError('gate 内部错误：重跑判定得到的条目数 ${finalItems.length} != ${items.length}');
  }

  await writeGateReport(outPath: outPath, gateId: 'G2B-P0', items: finalItems);

  File(kHashesRolling).writeAsStringSync(
      _formatHashes(hashes) + 'golden_src=$srcCount\ngolden_ref=$refCount\n');
  File('out/hashes_P0_r$round.txt').writeAsStringSync(
      _formatHashes(hashes) + 'golden_src=$srcCount\ngolden_ref=$refCount\n');

  final bool allPass = finalItems.every((Map<String, dynamic> i) => i['pass'] == true);
  File('out/GATE_P0_r$round.md').writeAsStringSync(_renderMd(
    round: round,
    items: finalItems,
    ac: ac,
    hashes: hashes,
    prevHashes: prev,
    inputs: inputs,
  ));
  stdout.writeln('G2B-P0 第 $round 轮: ${allPass ? 'PASS' : 'FAIL'}，详情 $outPath / out/GATE_P0_r$round.md');
  exit(allPass ? 0 : 1);
}

/// 下一轮轮次号 = 1 + 已存在的最大轮次。
///
/// **无编号的产物也要算进去。** `out/gate_P0.json`（以及 `out/GATE_P0.json`）
/// 是 r1 当时写死默认路径留下的名字，**它就是第 1 轮的 JSON**。
/// 不认它的话，`out/GATE_P0_r1.md` 一旦不在（被删、被移走、被一次死运行覆盖），
/// 旧算法会算出"下一轮 = 1"，于是新一轮把 r1 的编号再占一次 ——
/// 与"只看 JSON 不看 md"是同一类错误：**账本漏了一个曾经存在的条目**。
///
/// 教训来源（2026-09-17）：r1 的 JSON 落在 `out/gate_P0.json` 上，
/// 于是只认 `out/gate_P0_r<N>.json` 的版本算出"下一轮 = 1"，
/// 把 `out/GATE_P0_r1.md` **覆盖掉**，同时让第 2 轮顶着 r1 的编号去套
/// `kRoundErrata` 与修复轮次记账。轮次号是账本，账本算错等于前面
/// 所有的"第几轮"都不可信。
///
/// 取最大值而不是"找到第一个空位"：中间缺一个号（比如 r2 的 JSON 被删了）
/// 时，"第一个空位"会把新一轮塞进那个洞里、盖掉它的 md。
int nextRound({String dir = 'out'}) {
  final RegExp re = RegExp(r'[/\\](?:GATE_P0_r|gate_P0_r)(\d+)\.(?:md|json)$');
  final RegExp legacy = RegExp(r'[/\\](?:GATE_P0|gate_P0)\.(?:md|json)$');
  int maxRound = 0;
  final Directory d = Directory(dir);
  if (d.existsSync()) {
    for (final FileSystemEntity e in d.listSync()) {
      if (e is! File) continue;
      final String path = e.path.replaceAll('\\', '/');
      final RegExpMatch? m = re.firstMatch(path);
      if (m != null) {
        final int n = int.parse(m.group(1)!);
        if (n > maxRound) maxRound = n;
      } else if (legacy.hasMatch(path) && maxRound < 1) {
        maxRound = 1;
      }
    }
  }
  return maxRound + 1;
}

/// 哈希扫描的结果：算出来的哈希 + **算不出来的**文件。
///
/// 后者必须单独带出来：让它"从表里消失"就是静默少报。
class HashScan {
  final Map<String, String> hashes;
  final List<String> unhashable;
  HashScan(this.hashes, this.unhashable);
}

/// 判据的**输入**也钉住 —— 不只是"考卷"。
///
/// `$kTruthV0Path` 是**手写的判据分母**（每条夹具的真值），也就是全部 P0 判据的分母。
/// 它此前两边都不在：`kFreezeScopes` 只有 lib/test/tools/docs；
/// `hashScan` 只有 tools/gate、test/gate、integration_test、ACCEPTANCE、RUBRIC。
/// 于是 baseline 之后**改一个真值**，冻结检查不响、哈希比对也不响 ——
/// 这是"为通过而放宽"最短的一条路，比改阈值隐蔽得多（阈值至少还有常数清单可核）。
/// 2026-09-17 qa-batch 在 `c11df1c` 里确实改过真值文件（改得诚实且正确），
/// 但**门禁本来不会发现**：一个只在当事人自觉时才存在的检查，不是检查。
///
/// **钉的对象在 2026-09-17 由生成的 `$kTruthPath` 换成了手写的 `$kTruthV0Path`**
/// （理由写在 `kTruthV0Path` 的长注里）。换成 v0 之后，`$kTruthPath` 是产出、
/// 不是判据输入，**不进本表**：把它也钉住只会每轮报一次"哈希变了"的假阳性，
/// 真正的保护由 `denominatorAgreement` 按条目对而不是按字节对给出。
///
/// **基线文件本身也在受钉之列。**
///
/// 它是钉的**锚**，不是钉的产出。不钉它的后果是一条一步到位的绕过：
///
/// ```
/// del out\hashes_P0_truth_leaves_baseline.txt
/// ```
///
/// 下一次运行就会 `baselineEstablished = true` → "首轮建立基线，本轮不判 FAIL"，
/// 于是**改过判据分母也能全身而退**。这与 `kTruthPath` 当初两边都不在是同一个洞，
/// 只不过入口从"改文件内容"换成了"删文件"—— 而删一个文件比改一个数容易得多。
///
/// 放进 `kPinnedJudgmentInputs` 之后它进哈希表，删掉会表现为"算不出哈希"
/// （不判成不存在，见 `HashScan.unhashable`），改掉会表现为哈希漂移。
const List<String> kPinnedJudgmentInputs = <String>[
  kTruthV0Path,
  kTruthLeavesBaselinePath,
];

/// 基线**重建**轮：应当被显式登记，而不是被当成"没这回事"。
///
/// 删除基线文件仍会建立一份新的，但那一轮**不作判决**（整轮作废）——
/// 否则"删掉钉 = 本轮免疫"这个激励还在。把它做成作废轮，删文件就买不到任何东西：
/// 买到的是一轮 void，且 void 会被逐条写进报告。
///
/// 首次落地时同样会走这里（首轮本来就是 void），这是**故意**的：
/// 建立钉的那一轮不该同时充当判决，两件事分开。
const String kBaselineRetakeNote =
    '基线文件 `$kTruthLeavesBaselinePath` 本轮为**重建**（原文件不存在）。'
        '本轮只建立锚点、**不作判决**（整轮作废，不消耗实现方修复轮次）。'
        '理由：钉的锚如果能靠删掉它来重置，那"删掉即免疫"就是一条最短的绕过路径。'
        '重建必须是有意识的行为，因此必须留下记录 —— 见下方「排除集与豁免」一节。';

/// 判据分母的**数值叶基线**。首行 `sha256=<被钉文件的整文件哈希>`，
/// 第二行 `pin=<相对路径>`，其后每行一个 `路径=数值`。
/// 用数值叶而不是整文件哈希，是为了给**合法表述订正**留一条通道：
/// 表述变了、数值一个没动 → 登记为豁免；**数值动了一个 → 判 FAIL**。
///
/// 这个文件本身也受钉（见 `kPinnedJudgmentInputs`），且**不存在时建立的那一轮
/// 整轮作废**（见 `kBaselineRetakeNote`）—— 否则删掉它就能重置锚点，
/// "删掉即免疫"比"改一个数"容易得多。
const String kTruthLeavesBaselinePath = 'out/hashes_P0_truth_leaves_baseline.txt';

/// `pin=` 那一行在基线文件里的行首标记。
const String kPinStampPrefix = 'pin=';

/// 换靶**历史**的标记。每换一次追加一行 `retarget=旧 -> 新`，**只增不删**。
///
/// 为什么要有它：换靶那一轮的报告会说"换过"，但**下一轮就不会再提**——
/// 锚已经是新的了，`pin=` 也已经是新值，没有任何字段还记得发生过什么。
/// 于是一次"改常数重设锚"只要熬过当轮，就在此后的所有报告里彻底消失。
/// 历史行把这件事变成**永久可见**：每一次换靶都躺在基线文件里，
/// 每轮随 `pinNote()` 打印。
const String kRetargetStampPrefix = 'retarget=';

/// **换钉子对象的登记簿**。键 `旧目标 -> 新目标`，值 = 理由（含日期与裁定人）。
///
/// 为什么需要它：基线文件是数值叶锚，而锚**只对某一个被钉文件有意义**。
/// 换了钉子对象而不换锚，锚就变成了噪声源（旧文件的叶子全被读成"删除"）；
/// 换了锚而不留痕，就等于演示了一遍"重设锚点"本身 —— 那正是
/// `kBaselineRetakeNote` 要堵的动作，只不过入口从"删文件"换成"改常数"。
///
/// 所以：目标变了要**同时**满足两件事 —— 变更在代码里（受条款 2 的 SHA256 保护，
/// 想放宽必须在 diff 里留下改动），**且**这一对 (旧, 新) 在下面这张表里登记过理由。
/// 表里没有 → 判 FAIL，并点名。表里有 → 当轮**重新生成**基线锚，并把这件事
/// 原样印进报告（不是静默接受，也不是整轮作废：换目标本身不改变任何一个分母值，
/// 真正约束分母的是 `denominatorAgreement`，作废一轮买不到任何安全）。
///
/// 旧基线文件没有 `pin=` 行（本机制落地前的版本）时按 `$kTruthPath` 认 ——
/// 它当年确实是从那个文件建的。
const Map<String, String> kPinRetargetLedger = <String, String>{
  '$kTruthPath -> $kTruthV0Path':
      '2026-09-17 主会话裁定：内容钉改钉**手写**分母，生成产物改按「与手写件逐条相等」核。'
          '理由：生成件含每轮必变的溯源块，钉它就得永久豁免一块判据分母；'
          '且改 v0 才是改分母的正路，钉产物钉不住动机。',
};

/// 真值数值叶比对里**唯一**的排除块。**当前为空**（一个都不排）。
///
/// 历史：这个钉原先指在**生成**的 `out/P0_truth.json` 上，而该文件含
/// `evaluatedState`（`headAtFinalize` + `codeFingerprintAtFinalize.*` 数值叶），
/// 是 **HEAD 与工作区的函数**，每轮必变，所以必须把这一整块排掉，
/// 否则逐叶通道会真报差异。代价是"判据分母上永久开一个不受内容钉保护的洞"。
///
/// 2026-09-17 把钉子换成**手写**的 `$kTruthV0Path` 之后，这个代价的来源消失了：
/// v0 是人写的、不随轮次重生成，**它的每一个数值叶都是判据输入**，没有一块该豁免。
/// 于是本表清空 —— 不是"放宽"，是**把原来那块洞收回来**：现在 v0 里
/// **任何**数值叶被改动都会被逐叶通道看见，包括当年必须豁免的那类。
///
/// 纪律不变（缺一不可）：
///  1. 只能是常数，放在 `tools/gate/` —— 于是它受条款 2 的 SHA256 保护，
///     谁想放宽都必须在 diff 里留下代码改动；
///  2. **每轮把被排除的路径清单印出来**（空也要印"本轮实际排除 0 个"），
///     与被钉住的东西同一个待遇：**命名、钉住、打印**，不许做成静默跳过；
///  3. 除此以外的任何数值叶，照旧逐叶比对。
///
/// 生成件那一侧的保护**没有消失，换了形式**：`denominatorAgreement` 逐条比对
/// 它与 v0 的每一条分母（换目标前是比字节，现在比条目 —— 比字节反而漏掉
/// "把某条真值改小以过关"以外的形状）。
const List<String> kTruthLeafExcludedPrefixes = <String>[];

/// 某个数值叶路径是否落在排除块里。前缀匹配按路径段，不做子串匹配 ——
/// `evaluatedStateX` 不该被 `evaluatedState` 匹配掉。
///
/// `prefixes` 可覆盖，**只为让自测能验这个机制本身**：生产路径传空表
/// （见 `kTruthLeafExcludedPrefixes`），一个可测的机制即使当前是空表，
/// 也好过"等哪天真要豁免时再写一段没人跑过的代码"。
bool truthLeafExcluded(String leafPath, {List<String> prefixes = kTruthLeafExcludedPrefixes}) {
  for (final String p in prefixes) {
    if (leafPath == p || leafPath.startsWith('$p.') || leafPath.startsWith('$p[')) {
      return true;
    }
  }
  return false;
}

/// 把 JSON 里所有**数值叶**抽成 `路径=值` 的排序列表。
/// 布尔与字符串不算：本门禁关心的是判断用的数，不是措辞。
List<String> numericLeaves(Object? node) {
  final List<String> out = <String>[];
  void walk(Object? n, String p) {
    if (n is Map) {
      final List<String> ks =
          n.keys.map((Object? k) => k.toString()).toList()..sort();
      for (final String k in ks) {
        walk(n[k], p.isEmpty ? k : '$p.$k');
      }
    } else if (n is List) {
      for (int i = 0; i < n.length; i++) {
        walk(n[i], '$p[$i]');
      }
    } else if (n is num) {
      out.add('$p=$n');
    }
  }

  walk(node, '');
  out.sort();
  return out;
}

HashScan hashScan() {
  final Map<String, String> h = <String, String>{};
  final List<String> unhashable = <String>[];
  void take(String p) {
    final String? s = _sha256(p);
    if (s == null) {
      unhashable.add(p);
    } else {
      h[p] = s;
    }
  }

  for (final String dir in <String>['tools/gate', 'test/gate', 'integration_test']) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) continue;
    final List<FileSystemEntity> es = d.listSync(recursive: true)
      ..sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
    for (final FileSystemEntity e in es) {
      if (e is! File) continue;
      take(e.path.replaceAll('\\', '/'));
    }
  }
  for (final String p in <String>[
    'docs/ACCEPTANCE.md',
    'docs/RUBRIC.md',
    ...kPinnedJudgmentInputs,
  ]) {
    take(p);
  }
  return HashScan(h, unhashable);
}
/// 算一个文件的 SHA-256。**算不出来返回 null，由调用方登记为"不可判"**。
///
/// 上一版调 `sha256sum` 子进程，失败模式是**静默少报**：`exitCode != 0` 或空输出
/// 就返回 null，调用方 `if (s != null) h[p] = s;` 于是该文件**从哈希表里直接消失**，
/// 不报错、不标不可判。这与条款 3/5 的 `grep` 事故是同一个形状 ——
/// **仪表失败时报告"更少"，而不是"看不到"。**
/// 现在改用纯 Dart 实现（`tools/gate/sha256.dart`，已对 NIST 向量与 `sha256sum`
/// 逐位校验），不再依赖外部进程，`null` 只剩"文件读不出来"这一种含义。
String? _sha256(String path) {
  try {
    final File f = File(path);
    if (!f.existsSync()) return null;
    return sha256Hex(f.readAsBytesSync());
  } catch (_) {
    return null;
  }
}

/// 真值文件（判据分母）相对**基线**的漂移。
///
/// 为什么要有它：`out/P0_truth.json` 装的是每条夹具的真值，也就是全部 P0 判据的
/// 分母。此前它既不在冻结范围、也不在哈希表里，于是 baseline 之后**改一个真值**
/// 两处都不响。这是"为通过而放宽"最短的一条路。
///
/// 但要给**合法表述订正**留通道（qa-batch 在 `c11df1c` 就做过一次正确的表述订正）：
/// 所以判的不是整文件哈希，而是**数值叶逐叶比对** ——
/// 表述变了、数值一个没动 ⇒ 登记为豁免；**数值动了一个 ⇒ FAIL**。
class TruthDrift {
  final String path;
  final bool baselineEstablished;
  final List<String> numericChanges;
  final bool wordingOnly;
  final int leafCount;

  /// 被 `kTruthLeafExcludedPrefixes` 排除掉的数值叶路径（**只记路径，不记值** ——
  /// 这块的值每轮都变，记值等于把噪声当证据）。**每轮原样打印**。
  final List<String> excludedLeafPaths;
  final String? currentHash;
  final String? baselineHash;

  /// 基线文件自报的钉子对象（无 `pin=` 行的旧基线按 `$kTruthPath` 认）。
  final String? pinFrom;
  /// 本轮的钉子对象。
  final String? pinTo;
  /// 目标变过、且这一对变更在 `kPinRetargetLedger` 里登记过 → 当轮重建锚。
  final bool pinRetargeted;
  /// 目标变过、但**未登记** → 非空即 FAIL 理由。这是本机制要拦的那条路。
  final String? pinRetargetUndeclared;

  /// 换靶历史（`旧 -> 新`，按发生顺序）。**只增不删**，每轮随 `pinNote()` 打印 ——
  /// 否则一次换靶熬过当轮就永远看不到了。
  final List<String> retargetHistory;

  TruthDrift({
    required this.path,
    required this.baselineEstablished,
    required this.numericChanges,
    required this.wordingOnly,
    required this.leafCount,
    required this.excludedLeafPaths,
    required this.currentHash,
    required this.baselineHash,
    this.pinFrom,
    this.pinTo,
    this.pinRetargeted = false,
    this.pinRetargetUndeclared,
    this.retargetHistory = const <String>[],
  });

  /// 排除清单的渲染。**空的时候也要显式说"排除了 0 个"**，不能因为没内容就消失 ——
  /// 一条只在非空时才出现的说明，读者无法分辨"没有豁免"和"豁免没被打印"。
  String exclusionNote() {
    if (kTruthLeafExcludedPrefixes.isEmpty) {
      return '数值叶排除集：**空**（一个都不排，全部逐叶比对）';
    }
    final String ps = kTruthLeafExcludedPrefixes.map((String p) => '`$p`').join('、');
    if (excludedLeafPaths.isEmpty) {
      return '数值叶排除集：$ps —— 本轮**实际排除 0 个数值叶**'
          '（该块当前不含数值叶；排除集本身照列，供核对）';
    }
    return '数值叶排除集：$ps —— 本轮**实际排除 ${excludedLeafPaths.length} 个数值叶**，'
        '逐条列出：${excludedLeafPaths.map((String p) => '`$p`').join('、')}';
  }

  /// 钉子对象是否本轮被换过（含未登记的换法）。**每轮原样打印**，理由与
  /// `exclusionNote()` 相同：一条只在"变过"时才出现的说明，读者分不清
  /// "没换过"与"换了但没印"。
  String pinNote() {
    final String to = pinTo ?? path;
    final String h = retargetHistory.isEmpty
        ? '换靶历史：**无**（自本机制落地以来未换过钉子对象）'
        : '换靶历史（**只增不删**）：${retargetHistory.map((String x) => '`$x`').join('、')}';
    if (pinRetargetUndeclared != null) {
      return '钉子对象：`$to`（**变了但未登记** —— $pinRetargetUndeclared）；$h';
    }
    if (pinRetargeted) {
      return '钉子对象：`$pinFrom` → `$to`（**本轮换过，已在 `kPinRetargetLedger` 登记**；'
          '基线锚已按新目标重建。理由见登记簿：${kPinRetargetLedger["$pinFrom -> $to"] ?? "（登记簿无此对）"}）；$h';
    }
    return '钉子对象：`$to`（本轮未变）；$h';
  }

  String describe() {
    final String ex = exclusionNote();
    final String pin = pinNote();
    if (pinRetargetUndeclared != null) {
      return '**判据分母的钉子对象被换成了未登记的目标**：'
          '基线自报 `$pinFrom`，本轮指向 `${pinTo ?? path}`。$pin。'
          '换目标要同时满足"变更在代码里"与"这一对在 `kPinRetargetLedger` 里登记过理由"，'
          '只做到前者等于绕开 `kBaselineRetakeNote`（把"删文件重设锚"换成"改常数重设锚"）。';
    }
    if (baselineEstablished) {
      // 措辞要紧：这里**不再**写"本轮不判 FAIL"。写成那样，删掉基线文件
      // 就等于"本轮免疫"，而删文件是绕过整个真值钉最短的一条路。
      return '**$path 的数值叶基线本轮为重建**（原基线文件不存在）：'
          '已建立 $leafCount 个数值叶的锚点，但**本轮整轮作废、不作判决**，'
          '不消耗实现方修复轮次。$ex $pin';
    }
    if (pinRetargeted) {
      return '**$path 的数值叶锚已按新钉子对象重建**：$pin。'
          '本轮**不作数值叶差异判决**（锚是新的，没有可比对象），'
          '但换目标这件事与新建基线不同 —— 它不改变任何一个分母值，'
          '真正的约束在 `denominatorAgreement`（生成件与手写件逐条相等）。$ex';
    }
    if (numericChanges.isNotEmpty) {
      return '**$path 的数值叶相对基线改动了 ${numericChanges.length} 处**'
          '：${numericChanges.take(10).join("；")}'
          '${numericChanges.length > 10 ? " …" : ""}。$ex $pin';
    }
    if (wordingOnly) {
      return '$path 相对基线**只有表述差异**（整文件哈希变了、'
          '$leafCount 个数值叶一个没动）→ 登记为豁免，不判 FAIL。$ex $pin';
    }
    return '$path 相对基线无变化（$leafCount 个数值叶参与比对）。$ex $pin';
  }
}

/// 数值叶 `路径=值` → `路径`。
String _leafKey(String leaf) {
  final int i = leaf.indexOf('=');
  return i > 0 ? leaf.substring(0, i) : leaf;
}

TruthDrift truthDrift({
  String truthPath = kTruthV0Path,
  String baselinePath = kTruthLeavesBaselinePath,
  List<String> excludedPrefixes = kTruthLeafExcludedPrefixes,
}) {
  final Object? json = _readJson(truthPath);
  final List<String> allLeaves = json == null ? <String>[] : numericLeaves(json);

  // 排除集**两侧同用**。只排一侧的后果：基线文件里存着 `evaluatedState.*` 的叶子，
  // 当前侧排掉之后它们在 `b` 里没有对应项，会被报成 **N 处"删除"** —— 一个纯粹的
  // 假阳性，且看起来像是有人动过判据输入。排除的定义是"这块钱不参与比对"，
  // 对基线和现值必须是对称的。
  final List<String> leaves = <String>[];
  final List<String> excluded = <String>[];
  for (final String l in allLeaves) {
    if (truthLeafExcluded(_leafKey(l), prefixes: excludedPrefixes)) {
      // 只记**路径**，不记值：这块的值每轮都变，记进去等于把噪声当证据，
      // 而且清单每轮都不一样就 diff 不了 —— 豁免清单要能被逐行对比才有用。
      excluded.add(_leafKey(l));
    } else {
      leaves.add(l);
    }
  }
  excluded.sort();

  final String? curHash = _sha256(truthPath);
  final File f = File(baselinePath);

  Map<String, String> asMap(List<String> ls) {
    final Map<String, String> m = <String, String>{};
    for (final String l in ls) {
      final int i = l.indexOf('=');
      if (i > 0) m[l.substring(0, i)] = l.substring(i + 1);
    }
    return m;
  }

  /// 写锚。`pin=` 行**必须**写：没有它，锚就不知道自己钉的是哪个文件，
  /// 换了钉子对象之后唯一的症状是"几百个叶子全被读成删除"——一个看起来像
  /// 有人篡改的假阳性，而真原因是没人动过任何数。
  void writeBaseline(String pin, [List<String> history = const <String>[]]) {
    final String hist = history.isEmpty
        ? ''
        : history.map((String x) => '$kRetargetStampPrefix$x\n').join();
    f
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('sha256=${curHash ?? "?"}\n'
          '$kPinStampPrefix$pin\n$hist${leaves.join("\n")}\n');
  }

  if (!f.existsSync()) {
    writeBaseline(truthPath);
    return TruthDrift(
      path: truthPath,
      baselineEstablished: true,
      numericChanges: <String>[],
      wordingOnly: false,
      leafCount: leaves.length,
      excludedLeafPaths: excluded,
      currentHash: curHash,
      baselineHash: null,
      pinTo: truthPath,
    );
  }

  final List<String> lines = f.readAsLinesSync();
  final String? baseHash = lines.isNotEmpty && lines.first.startsWith('sha256=')
      ? lines.first.substring(7).trim()
      : null;
  // 旧基线（本机制落地前写的）没有 `pin=` 行 —— 它当年确实是从生成的
  // `$kTruthPath` 建的，按那个认；否则这次换目标会被误读成"锚被人换过"。
  String? stamp;
  final List<String> history = <String>[];
  for (final String l in lines) {
    final String t = l.trim();
    if (t.startsWith(kPinStampPrefix) && stamp == null) {
      stamp = t.substring(kPinStampPrefix.length).trim();
    } else if (t.startsWith(kRetargetStampPrefix)) {
      final String v = t.substring(kRetargetStampPrefix.length).trim();
      if (v.isNotEmpty && !history.contains(v)) history.add(v);
    }
  }
  final String pinFrom = stamp ?? kTruthPath;

  if (pinFrom != truthPath) {
    final String? reason = kPinRetargetLedger['$pinFrom -> $truthPath'];
    if (reason == null) {
      return TruthDrift(
        path: truthPath,
        baselineEstablished: false,
        numericChanges: <String>[],
        wordingOnly: false,
        leafCount: leaves.length,
        excludedLeafPaths: excluded,
        currentHash: curHash,
        baselineHash: baseHash,
        pinFrom: pinFrom,
        pinTo: truthPath,
        pinRetargetUndeclared:
            '`kPinRetargetLedger` 里没有 `$pinFrom -> $truthPath` 这一对',
        retargetHistory: history,
      );
    }
    final List<String> h2 = <String>[...history, '$pinFrom -> $truthPath'];
    writeBaseline(truthPath, h2);
    return TruthDrift(
      path: truthPath,
      baselineEstablished: false,
      numericChanges: <String>[],
      wordingOnly: false,
      leafCount: leaves.length,
      excludedLeafPaths: excluded,
      currentHash: curHash,
      baselineHash: baseHash,
      pinFrom: pinFrom,
      pinTo: truthPath,
      pinRetargeted: true,
      retargetHistory: h2,
    );
  }

  final Map<String, String> b = asMap(lines
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .where((String l) => !l.startsWith('sha256='))
      .where((String l) => !l.startsWith(kPinStampPrefix))
      .where((String l) => !l.startsWith(kRetargetStampPrefix))
      .where((String l) => !truthLeafExcluded(_leafKey(l), prefixes: excludedPrefixes))
      .toList());
  final Map<String, String> c = asMap(leaves);

  final List<String> changes = <String>[];
  for (final MapEntry<String, String> e in c.entries) {
    final String? old = b[e.key];
    if (old == null) {
      changes.add('${e.key}: 新增 ${e.value}');
    } else if (old != e.value) {
      changes.add('${e.key}: $old → ${e.value}');
    }
  }
  for (final MapEntry<String, String> e in b.entries) {
    if (!c.containsKey(e.key)) changes.add('${e.key}: 删除（原 ${e.value}）');
  }
  changes.sort();

  final bool wordingOnly = changes.isEmpty &&
      baseHash != null &&
      curHash != null &&
      baseHash != curHash;

  return TruthDrift(
    path: truthPath,
    baselineEstablished: false,
    numericChanges: changes,
    wordingOnly: wordingOnly,
    leafCount: leaves.length,
    excludedLeafPaths: excluded,
    currentHash: curHash,
    baselineHash: baseHash,
    pinFrom: pinFrom,
    pinTo: truthPath,
    retargetHistory: history,
  );
}

/// 读一份 JSON。**读不到 / 解析不出都返回 null**，与 `_readJson` 的
/// "读不到就是空对象"分开 —— 这里需要区分"文件没有"与"文件里没有这一项"。
Map<String, dynamic>? _tryReadJson(String path) {
  final File f = File(path);
  if (!f.existsSync()) return null;
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

String _shortJson(Object? v) {
  final String s = jsonEncode(v);
  return s.length <= 160 ? s : '${s.substring(0, 160)}…';
}

/// 生成件里允许比手写分母**多出来**的条目，写成 `清单/id`。**每轮原样打印**。
///
/// 判据口径第 6 条：`p2` 归 `straight`、不在锚点栏 —— 但生成件把两张清单**并集**成
/// `anchors`，于是它多出 `p2` 这一条。这是**已知且被审过的**形状，写在这里。
///
/// 光登记还不够，`denominatorAgreement` 还要求被豁免的 id **在 v0 里某个清单出现过**
/// —— 否则"往登记表里加一行"就成了凭空造分母的通道（加登记要改代码，改代码要过
/// 条款 2 的 SHA256，两道都在，但能白拿的白拿不要）。
const List<String> kDenominatorExtraAllowance = <String>['anchors/p2'];

/// 手写分母与生成件之间**允许存在的形状差异**：字段名 -> 理由。**每轮原样打印**。
///
/// 为什么需要它、又为什么只放一个字段：真跑一次就知道 —— 手写件与生成件逐条比，
/// 在全量数据上恰好只有**两个**字段对不上（2026-09-17 实测：`methods` 13 条、
/// `path` 87 条，除此之外一条不差）。`path` 由下面的**路径归一化**处理掉，
/// 不占豁免名额；剩下 `methods` 这一个：
///   · 手写件记的是**量具名简表**（`["pupil-centroid","haar-eyeline"]`），
///     生成件记的是**逐量具的完整记录**（`{name, value_deg, evidence, doc, …}`）；
///   · 两者的 `name` 连命名都不同（简表用 `pupil-centroid`，详情用 `m1_pupil`），
///     所以不是简单的投影，归并不掉；
///   · 这个字段**不进任何判据** —— 判据读的是 `trueRollDeg` /
///     `expectedEngineRollDeg`，以及成片端到端残余。`methods` 是佐证元数据。
///
/// **豁免是有代价的，代价写在这里**：`methods` 之下的任何形状变化都不再被报告。
/// 谁要再放宽一个字段，必须改这个常数 —— 它在 `tools/gate/` 下，受条款 2 的
/// SHA256 保护，改动必然出现在 diff 里。
///
/// 刻意**按字段名**而不是按"清单.字段"：`methods` 出现在多个清单里，
/// 逐清单登记会让表长得看不出重点，而豁免的理由对每个清单是同一个。
const Map<String, String> kDenominatorShapeAllowance = <String, String>{
  'methods': '手写件记量具名简表，生成件记逐量具完整记录；两种形状，都不是判据输入',
};

/// 生成的分母文件与**手写**分母逐条相等。
///
/// 这是把内容钉从生成件换到 `$kTruthV0Path` 之后补上的那道保护：内容钉答的是
/// "有没有人改过手写件里的数"，本检查答的是"生成件用的**就是**手写件的分母吗"。
/// 两者互补，缺一不可 ——
/// 只钉 v0 而不比生成件，改 `p0_finalize_v1.py` 就能让生成件用另一套分母；
/// 只比生成件而不钉 v0，改 v0 两处一起改就看不出来了。
///
/// 比对范围**由 v0 决定**（不硬编码清单名）：v0 里每个列表值都要在生成件里
/// 逐条对上。v0 里没有的清单（`knownLimitations` 等派生块）不参与 ——
/// 它们是产物，不是分母。**这一条要印在报告里**，否则"没比"读起来像"比过了"。
/// 两个字符串是否指向**同一个文件**：原样相等，或只差一个绝对路径前缀。
///
/// 实测形状：手写件把成片记成仓库相对路径（`out/P0_anchors/c01_d+3.png`），
/// 生成件记成盘上的绝对路径（`C:/Users/.../out/P0_anchors/c01_d+3.png`）。
/// 这是同一份文件的两个写法，不是分母改动 —— 对它报 FAIL 是纯假阳性，
/// 而一个在诚实数据上永远红的检查，最后一定会被豁免掉，等于没写。
///
/// 归一化是**收窄**不是放宽：去掉前缀之后两串必须逐字符相等，
/// 指到别的文件上照样红。
bool _samePathSpelling(String a, String b) {
  if (a == b) return true;
  final String x = a.replaceAll('\\', '/');
  final String y = b.replaceAll('\\', '/');
  if (x == y) return true;
  bool absPrefixOf(String longer, String shorter) {
    if (longer.length <= shorter.length) return false;
    if (!longer.endsWith(shorter)) return false;
    final String head = longer.substring(0, longer.length - shorter.length);
    if (!head.endsWith('/')) return false;
    // 前缀必须是绝对路径（`C:/…` 或 `/…`），不许是随便一段相对目录 ——
    // 否则 `a/b.png` 与 `x/a/b.png` 会被判成同一个文件。
    return RegExp(r'^(?:[A-Za-z]:)?/').hasMatch(head);
  }

  return absPrefixOf(x, y) || absPrefixOf(y, x);
}

String _kindOf(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return 'bool';
  if (v is num) return 'num';
  if (v is String) return 'string';
  if (v is List) return 'list';
  if (v is Map) return 'map';
  return v.runtimeType.toString();
}

/// **逐值**比较，允许两件已声明的事：路径的两种写法、以及
/// `kDenominatorShapeAllowance` 里登记过的字段。
///
/// 递归到底、不做投影：`anchors[0].trueRollDeg` 改一个数会被指名道姓地报出来。
void _cmpJson(
  Object? a,
  Object? b,
  String path,
  String field,
  List<String> problems,
  Map<String, int> shapeSkipped,
) {
  if (a is num && b is num) {
    if (a != b) problems.add('$path：手写 $a ≠ 生成 $b');
    return;
  }
  if (a is String && b is String) {
    if (!_samePathSpelling(a, b)) {
      problems.add('$path：手写 ${_shortJson(a)} ≠ 生成 ${_shortJson(b)}');
    }
    return;
  }
  if (a is bool && b is bool) {
    if (a != b) problems.add('$path：手写 $a ≠ 生成 $b');
    return;
  }
  if (a == null && b == null) return;
  if (a is List && b is List) {
    if (a.length != b.length) {
      // 长度不同也是**形状**不同的一种（简表 2 项 vs 逐量具记录 4 项）。
      // 登记过的字段照登记处理，没登记的一律报出来。
      if (kDenominatorShapeAllowance.containsKey(field)) {
        shapeSkipped[field] = (shapeSkipped[field] ?? 0) + 1;
        return;
      }
      problems.add('$path：长度不同（手写 ${a.length} ≠ 生成 ${b.length}）');
      return;
    }
    for (int i = 0; i < a.length; i++) {
      _cmpJson(a[i], b[i], '$path[$i]', field, problems, shapeSkipped);
    }
    return;
  }
  if (a is Map && b is Map) {
    for (final Object? k in a.keys) {
      if (!b.containsKey(k)) {
        problems.add('$path.$k：生成件里没有这个字段（手写 ${_shortJson(a[k])}）');
      } else {
        _cmpJson(a[k], b[k], '$path.$k', field, problems, shapeSkipped);
      }
    }
    return;
  }
  // 形状不同
  if (kDenominatorShapeAllowance.containsKey(field)) {
    shapeSkipped[field] = (shapeSkipped[field] ?? 0) + 1;
    return;
  }
  problems.add('$path：同一个字段在两边是**两种东西**'
      '（手写 ${_kindOf(a)} ${_shortJson(a)} vs 生成 ${_kindOf(b)} ${_shortJson(b)}）——'
      '形状变了就该有人看一眼，不能靠"类型不同所以跳过"滑过去');
}

class DenominatorAgreement {
  final bool readable;
  final String? error;
  final List<String> problems;

  /// 每个清单比了多少条（v0 侧条数）。
  final Map<String, int> compared;
  /// 生成件多出来、且已登记 + 在 v0 出现过 → 登记豁免。
  final List<String> extraAllowed;
  /// 生成件多出来、但**没登记**（或凭空出现）→ 逐条 FAIL 理由。
  final List<String> extraUndeclared;
  /// v0 里没有、生成件里有的清单名（派生块）。**列出来才知道没比哪些。**
  final List<String> generatedOnlyLists;

  /// 因 `kDenominatorShapeAllowance` 被跳过的字段 -> 次数。**每轮原样打印**：
  /// 一个只在"有豁免时"才出现的说明，读者分不清"没豁免"与"豁免没被打印"。
  final Map<String, int> shapeSkipped;
  final String? v0Hash;
  final String? generatedHash;

  DenominatorAgreement({
    required this.readable,
    this.error,
    required this.problems,
    required this.compared,
    required this.extraAllowed,
    required this.extraUndeclared,
    required this.generatedOnlyLists,
    this.shapeSkipped = const <String, int>{},
    this.v0Hash,
    this.generatedHash,
  });

  bool get pass => readable && problems.isEmpty && extraUndeclared.isEmpty;

  String summary() {
    if (!readable) return '**不可判**（${error ?? "读不到"}）——不默认通过。';
    final String cmp = compared.keys.isEmpty
        ? '0 个清单'
        : compared.keys
            .toList()
            .map((String k) => '$k=${compared[k]}条')
            .join('、');
    final List<String> shapeKeys = shapeSkipped.keys.toList()..sort();
    return '比了 $cmp；登记豁免 ${extraAllowed.length} 条'
        '${extraAllowed.isEmpty ? "" : "（${extraAllowed.join("、")}）"}；'
        'v0 没有、故**未比**的生成件清单：'
        '${generatedOnlyLists.isEmpty ? "无" : generatedOnlyLists.join("、")}；'
        '因形状豁免**未逐值比**的字段：'
        '${shapeKeys.isEmpty ? "无" : shapeKeys.map((String k) => "$k×${shapeSkipped[k]}").join("、")}'
        '（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'readable': readable,
        'error': error,
        'pass': pass,
        'problems': problems,
        'extraUndeclared': extraUndeclared,
        'extraAllowed': extraAllowed,
        'compared': compared,
        'generatedOnlyLists': generatedOnlyLists,
        'shapeSkipped': shapeSkipped,
        'v0Hash': v0Hash,
        'generatedHash': generatedHash,
        'summary': summary(),
      };
}

DenominatorAgreement denominatorAgreement({
  String v0Path = kTruthV0Path,
  String generatedPath = kTruthPath,
}) {
  final Map<String, dynamic>? v0 = _tryReadJson(v0Path);
  final Map<String, dynamic>? gen = _tryReadJson(generatedPath);
  final String? h0 = _sha256(v0Path);
  final String? h1 = _sha256(generatedPath);
  final List<String> problems = <String>[];
  final Map<String, int> compared = <String, int>{};
  final List<String> allowed = <String>[];
  final List<String> undeclared = <String>[];
  final Map<String, int> shapeSkipped = <String, int>{};

  if (v0 == null) {
    return DenominatorAgreement(
      readable: false,
      error: '读不到或解析不出 `$v0Path`（手写分母）',
      problems: problems,
      compared: compared,
      extraAllowed: allowed,
      extraUndeclared: undeclared,
      generatedOnlyLists: <String>[],
      shapeSkipped: shapeSkipped,
      v0Hash: h0,
      generatedHash: h1,
    );
  }
  if (gen == null) {
    return DenominatorAgreement(
      readable: false,
      error: '读不到或解析不出 `$generatedPath`（生成分母）',
      problems: problems,
      compared: compared,
      extraAllowed: allowed,
      extraUndeclared: undeclared,
      generatedOnlyLists: <String>[],
      shapeSkipped: shapeSkipped,
      v0Hash: h0,
      generatedHash: h1,
    );
  }

  // v0 里出现过的所有 `id`。被豁免的条目必须在这里面（不许凭空造分母）。
  final Set<String> v0Ids = <String>{};
  for (final Object? v in v0.values) {
    if (v is! List) continue;
    for (final Object? e in v) {
      if (e is Map && e['id'] is String) v0Ids.add(e['id'] as String);
    }
  }

  final List<String> v0Lists = v0.keys.where((String k) => v0[k] is List).toList()
    ..sort();
  final List<String> genLists = gen.keys.where((String k) => gen[k] is List).toList()
    ..sort();
  final List<String> generatedOnly =
      genLists.where((String k) => !v0.containsKey(k)).toList();

  for (final String key in v0Lists) {
    final List<dynamic> want = v0[key] as List<dynamic>;
    final Object? gotRaw = gen[key];
    if (gotRaw is! List) {
      problems.add('$key：生成件里没有这个清单（或不是列表）');
      continue;
    }
    final List<dynamic> got = gotRaw;
    compared[key] = want.length;

    final bool byId = want.any((dynamic e) => e is Map && e['id'] is String);
    if (byId) {
      final Map<String, dynamic> gotById = <String, dynamic>{};
      for (final dynamic e in got) {
        if (e is Map && e['id'] is String) gotById[e['id'] as String] = e;
      }
      for (final dynamic e in want) {
        if (e is! Map || e['id'] is! String) {
          problems.add('$key：手写分母里有一条没有 `id`，无法逐条比对（'
              '${_shortJson(e)}）——手写分母的每一条都必须可标识');
          continue;
        }
        final String id = e['id'] as String;
        final dynamic g = gotById[id];
        if (g == null) {
          problems.add('$key/$id：生成件里**整条缺失**（手写分母有、生成件没有）');
          continue;
        }
        if (g is! Map) {
          problems.add('$key/$id：生成件里不是对象（${_shortJson(g)}）');
          continue;
        }
        // 只比**手写件里写了**的字段：生成件有自己的派生字段（corpus / kind /
        // derivedAnnotations / end_to_end …），那些是产物，不是分母。
        // 但**手写件写了的字段，生成件必须逐值相等** —— 数字精确比，不四舍五入。
        for (final Object? f in e.keys) {
          final String field = '$f';
          if (!g.containsKey(f)) {
            problems.add('$key/$id.$field：生成件里**没有这个字段**'
                '（手写值 ${_shortJson(e[f])}）');
          } else {
            _cmpJson(e[f], g[f], '$key/$id.$field', field, problems, shapeSkipped);
          }
        }
      }
      // 生成件多出来的条目
      for (final String id in gotById.keys) {
        if (want.any((dynamic e) => e is Map && e['id'] == id)) continue;
        final String tag = '$key/$id';
        if (kDenominatorExtraAllowance.contains(tag) && v0Ids.contains(id)) {
          allowed.add(tag);
        } else {
          undeclared.add('$tag：生成件多出这一条，'
              '${kDenominatorExtraAllowance.contains(tag) ? "登记了但 v0 里没有这个 id" : "且不在 kDenominatorExtraAllowance 里"}');
        }
      }
    } else {
      // 无 `id` 的清单（本轮是路径字符串表）：按**排序后的多重集**比。
      // 排序是为了不让顺序抖动冒充分母改动；多重集（不是集合）是为了让
      // "删一条 + 加一条"仍然看得见。
      final List<String> w = want.map((dynamic e) => _shortJson(e)).toList()..sort();
      final List<String> g = got.map((dynamic e) => _shortJson(e)).toList()..sort();
      final Set<String> onlyV0 = <String>{...w}..removeAll(g);
      final Set<String> onlyGen = <String>{...g}..removeAll(w);
      if (onlyV0.isNotEmpty) {
        problems.add('$key：手写分母有、生成件没有的 ${onlyV0.length} 条（'
            '例如 ${onlyV0.first}）');
      }
      if (onlyGen.isNotEmpty) {
        problems.add('$key：生成件有、手写分母没有的 ${onlyGen.length} 条（'
            '例如 ${onlyGen.first}）');
      }
    }
  }

  return DenominatorAgreement(
    readable: true,
    problems: problems..sort(),
    compared: compared,
    extraAllowed: allowed..sort(),
    extraUndeclared: undeclared..sort(),
    generatedOnlyLists: generatedOnly,
    shapeSkipped: shapeSkipped,
    v0Hash: h0,
    generatedHash: h1,
  );
}

/// 派生块的**证据溯源**核对：`evidenceProvenance.sourceSha256` 记的摘要，
/// 必须与**盘上那几份测量产物**现在算出来的摘要相同。
///
/// 为什么需要它：这个钉换到 v0 之后，生成件的派生叙述（`rotationFailureBoundary`
/// 里的行值、条数）不再受内容钉保护 —— 它们是**产物**，本来就该按指纹钉。
/// `sourceSha256` 正是那个指纹：finalize 写完叙述时把源产物的摘要一起记下。
/// 于是"叙述描述的是不是盘上这几份产物"变成一条机器可核的等式。
///
/// **这条检查的边界要说清楚（不许被读大）**：它证明的是「叙述与盘上产物一致」，
/// **不是**「产物出自当前被测代码」。源产物自己**没有**代码指纹
/// （见 `PITFALLS.md`）——那件事由 `provenanceReport()` 那一侧管，两件事别混。
class EvidenceProvenanceCheck {
  final bool readable;
  final String? error;
  final List<String> problems;
  /// 指针里记的路径 → 记录的摘要。
  final Map<String, String> recorded;
  /// 同路径 → 盘上现算的摘要（null = 文件不在）。
  final Map<String, String?> onDisk;

  EvidenceProvenanceCheck({
    required this.readable,
    this.error,
    required this.problems,
    required this.recorded,
    required this.onDisk,
  });

  bool get pass => readable && problems.isEmpty;

  String summary() {
    if (!readable) return '**不可判**（${error ?? "取不到"}）——不默认通过。';
    return '核了 ${recorded.length} 份源产物：'
        '${recorded.keys.map((String p) => '$p=${problems.any((String x) => x.startsWith(p)) ? "不一致" : "一致"}').join("、")}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'readable': readable,
        'error': error,
        'pass': pass,
        'problems': problems,
        'recorded': recorded,
        'onDisk': onDisk,
        'summary': summary(),
      };
}

/// `evidenceProvenance` 在生成件里的指针。写死在门禁里：指针能随数据飘，
/// 这条检查就成了"数据说自己在哪就在哪"。
const List<String> kEvidenceProvenancePointer = <String>[
  'gateInputs',
  'rotationFailureBoundary',
  'evidenceProvenance',
  'sourceSha256',
];

EvidenceProvenanceCheck evidenceProvenanceCheck({
  String generatedPath = kTruthPath,
  List<String> pointer = kEvidenceProvenancePointer,
}) {
  final List<String> problems = <String>[];
  final Map<String, String> recorded = <String, String>{};
  final Map<String, String?> onDisk = <String, String?>{};
  final Map<String, dynamic>? gen = _tryReadJson(generatedPath);
  final String ptr = pointer.join('/');
  if (gen == null) {
    return EvidenceProvenanceCheck(
      readable: false,
      error: '读不到或解析不出 `$generatedPath`',
      problems: problems,
      recorded: recorded,
      onDisk: onDisk,
    );
  }
  Object? cur = gen;
  for (final String k in pointer) {
    if (cur is! Map || !cur.containsKey(k)) {
      return EvidenceProvenanceCheck(
        readable: false,
        error: '`$generatedPath` 里取不到指针 `$ptr`（在 `$k` 处断掉）。'
            '注意：这**不是**"没问题"——它意味着派生数字与产物之间'
            '**没有任何机器可核的绑定**；生产者 `test/batch/p0_finalize_v1.py` 会写这个块',
        problems: problems,
        recorded: recorded,
        onDisk: onDisk,
      );
    }
    cur = cur[k];
  }
  if (cur is! Map) {
    return EvidenceProvenanceCheck(
      readable: false,
      error: '`$generatedPath` 的 `$ptr` 不是对象（${cur.runtimeType}）',
      problems: problems,
      recorded: recorded,
      onDisk: onDisk,
    );
  }
  for (final Object? k in cur.keys) {
    final Object? v = cur[k];
    final String p = '$k';
    if (v is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
      problems.add('$p：记录的摘要不是 64 位小写十六进制（${_shortJson(v)}）——'
          '算不出的指纹若退化成 ""/null，两份不同的产物会互相判等');
      continue;
    }
    recorded[p] = v;
    final String? now = _sha256(p);
    onDisk[p] = now;
    if (now == null) {
      problems.add('$p：盘上**不存在或读不出** —— 叙述所依据的产物不在了，'
          '这块派生数字无从核对');
    } else if (now != v) {
      problems.add('$p：记录的摘要 ${v.substring(0, 16)}… ≠ 盘上现算的 '
          '${now.substring(0, 16)}… —— **产物在 finalize 之后被改过**，'
          '叙述里的行值/条数描述的不是现在这份产物');
    }
  }
  if (recorded.isEmpty && problems.isEmpty) {
    problems.add('`$ptr` 是**空对象** —— 一个都不绑定等于没绑定');
  }
  return EvidenceProvenanceCheck(
    readable: true,
    problems: problems..sort(),
    recorded: recorded,
    onDisk: onDisk,
  );
}

String _formatHashes(Map<String, String> h) {
  final List<String> ks = h.keys.toList()..sort();
  return ks.map((String k) => '${h[k]} *$k').join('\n') + '\n';
}

Map<String, String>? _readHashes(String? path) {
  if (path == null || !File(path).existsSync()) return null;
  final Map<String, String> h = <String, String>{};
  for (final String line in File(path).readAsLinesSync()) {
    final int i = line.indexOf(' *');
    if (i < 0) continue;
    h[line.substring(i + 2).trim()] = line.substring(0, i).trim();
  }
  return h.isEmpty ? null : h;
}

int? _readCount(String path, String key) {
  if (!File(path).existsSync()) return null;
  for (final String line in File(path).readAsLinesSync()) {
    if (line.startsWith('$key=')) return int.tryParse(line.substring(key.length + 1).trim());
  }
  return null;
}

Set<String> _selfTouched() {
  final File f = File('out/GATE_P0_selfchanges.txt');
  if (!f.existsSync()) return <String>{};
  return f
      .readAsLinesSync()
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty && !l.startsWith('#'))
      .toSet();
}

String _renderMd({
  required int round,
  required List<Map<String, dynamic>> items,
  required Map<String, dynamic> ac,
  required Map<String, String> hashes,
  required Map<String, String>? prevHashes,
  required Map<String, dynamic> inputs,
}) {
  final int passed = items.where((Map<String, dynamic> i) => i['pass'] == true).length;
  final int manual = items.where((Map<String, dynamic> i) => i['manual'] == true).length;
  final bool invalid =
      items.any((Map<String, dynamic> i) => i['roundInvalid'] == true);
  final List<Map<String, dynamic>> failed =
      items.where((Map<String, dynamic> i) => i['pass'] != true).toList();

  final StringBuffer b = StringBuffer();
  b.writeln('## G2B-P0 第 $round 轮：'
      '${invalid ? '**作废（本轮无效，不是对代码的判决）**' : (failed.isEmpty ? 'PASS' : 'FAIL')}');
  b.writeln('## 通过 $passed / ${items.length} 项，MANUAL 项 $manual 个'
      '${invalid ? '（全部条目因本轮输入不可信而作废）' : ''}');
  b.writeln('## 脚本完整性：${_hashVerdict(hashes, prevHashes)}');
  b.writeln('## 防作弊巡查：${ac['clean'] == true ? '清白' : '命中（见 AC 条目）'}');
  b.writeln();
  // **这句话必须每轮都出现**，不能只写在 r1 的勘误里 —— 它管的是"历史结论能不能被引用"，
  // 而引用历史结论这件事发生在**每一轮**（"上一轮还是清白的"）。
  b.writeln(kClause1ExecutionNote);
  b.writeln();
  b.writeln('### 扫描区域（**含 0 与「根本没扫」**）');
  b.writeln(scanRootsMdSection(ac));
  b.writeln();
  for (final String line in kRoundErrata[round] ?? const <String>[]) {
    b.writeln(line);
  }
  if ((kRoundErrata[round] ?? const <String>[]).isNotEmpty) b.writeln();
  b.writeln('规格：`$kSpec`（ACCEPTANCE P0.1a 指定）；'
      '真值（生成件，判据读它）：`$kTruthPath`；'
      '真值（手写件，内容钉钉它）：`$kTruthV0Path`；'
      '生产记录：`$kComposePath`；'
      'gatekeeper 独立测量：`$kEyelinePath`。');
  b.writeln();
  b.writeln('### 判据版本声明（ACCEPTANCE 冻结条款要求写明）');
  b.writeln('本轮判决依据的判据 = `docs/ACCEPTANCE.md` @ commit `6f01e6e`（P0 判据冻结点）。');
  b.writeln('**第 1 轮初判作废的原因**：主会话在门禁运行期间于 03:23 / 03:24 / 03:39 / 03:47 '
      '连续四次修改 G2B-P0 判据，本门禁初版按改动前的草稿实现，且判据被从"读 '
      '`ComposeDiagnostics.straightenDeg`"改成"只认成片端到端残余"——初版判的正是新法典'
      '明令不作判据的量。故初判作废，本文件是**按冻结版判据重跑**后的第 1 轮结果，'
      '不消耗实现方的修复轮次。详见 `docs/ACCEPTANCE.md` 的「判据冻结声明」。');
  b.writeln();
  b.writeln('### 轮次记账（主会话 2026-09-17 裁定，按 CLAUDE.md §7「最多 3 轮修复」）');  b.writeln('第 1 轮是**重写轮**（判据被中途改动致初判作废），**不消耗** ml-porting 的修复预算。');
  b.writeln('ml-porting 有 3 次修复机会，对应门禁运行 **r2 / r3 / r4**；r4 仍 FAIL → '
      '写 `out/BLOCKED_G2B-P0.md`，全流程停止等人工，不降阈值、不删夹具、不跳门禁。');
  b.writeln('本轮按 `r$round` 编号。');
  b.writeln();
  b.writeln('### 轮次有效性判定（主会话 2026-09-17 裁定，**r2 起生效**）');
  b.writeln('> **一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来。**'
      '任何一项判据的输入若来自另一个状态（不同工作树、不同 revision、'
      '不同测量台的上一次产出），**要么重测，要么把该项标为无效**。');
  b.writeln('机检七件：① `git status --porcelain -- lib test tools docs` 为空（`out/` 除外）；'
      '② 每条样本都解析得到、成片文件都在；③ 声明条数 == 实际解析条数；'
      '④ 样本清单里**没有解析不了的行**；'
      '⑤ **`out/` 下三份测量产出各自记录的代码指纹与当前树逐条一致**'
      '（`out/` 不受冻结约束，所以"工作树干净"推不出"盘上的数是当前代码跑的"——'
      '缺这一条，上一轮的遗留会被当成本轮读数）；'
      '⑥ **生成分母与手写分母逐条相等**（`denominatorAgreement`）；'
      '⑦ **派生块的证据溯源与盘上产物相符**（`evidenceProvenanceCheck`）。'
      '任一不过 → **整轮作废**（全部条目 pass=false、manual=true），'
      '不消耗实现方修复轮次。**加一行说明拦不住它**——r1 就是这么滑过去的，'
      '所以这里是判 `roundInvalid` 而不是写备注。'
      '⑥⑦ 有一条分工要说清楚：**「取不到」判作废（不赖实现方），'
      '「取到了但不等」判 FAIL 并点名**（那是判据分母被动过的措辞，不是输入不可信的措辞）。');
  b.writeln('**本机制晚于 r1**：r1 的 FAIL 判决（P0.3a max 11.368°、P0.3b 9 条）'
      '按主会话裁定**保留为基线测量**，不因本机制追溯作废；'
      '但它**不是对任何单一代码状态的判决**，不得用来论证"改了一轮没修好"。');
  b.writeln();
  b.writeln();
  b.writeln('### 本轮输入的一致性（读数绑在哪个版本上）');
  b.writeln(_treeState(inputs));
  b.writeln();
  b.writeln('### 测量产出的来源绑定（`out/` 不受冻结约束，所以另有一道绑定）');
  b.writeln(_provenanceSection(inputs));
  b.writeln();
  b.writeln('### 判据分母的内容钉（$kTruthV0Path 手写件）与**豁免清单**');
  b.writeln(_truthPinSection(inputs));
  b.writeln();
  b.writeln('### 判据分母的一致性（生成的 $kTruthPath 是不是手写件的分母）');
  b.writeln(_denominatorMdSection(inputs));
  b.writeln();
  b.writeln('### 派生数字的证据溯源（叙述是不是盘上产物的函数）');
  b.writeln(_evidenceProvenanceMdSection(inputs));
  b.writeln();
  b.writeln('### 硬判据出自哪支量具（避免把量具差异读成分歧）');
  b.writeln('- **P0.1a / P0.2 / P0.3a② / P0.5b** 的成片残余：gatekeeper 的 **Haar 眼线量具**'
      '（`tools/gate/p0_eyeline.py`，自检最大误差见上）为第一读出；'
      '它测不出的样本改由 **SIFT 源图↔成片配准**（`tools/gate/p0_rigid_check.py align`）读出，'
      '逐条出处写在样本账里。');
  b.writeln('- **交叉复核**用的第二支是 qa-batch 的瞳孔法（`out/P0_output_residual.json`），'
      '两者是独立量具：同一张成片上读数可以不同（本轮最大差 1.414°），'
      '但只要两者都远超阈值就不构成分歧。**报告里的硬指标一律注明出自哪支**。');
  b.writeln('- 口径无关性：SIFT 只量"管线实际转了多少度"，不读眼线、不读 alpha、不读生产诊断，'
      '是符号约定出错时唯一不会跟着一起错的路径。');
  b.writeln();

  final Map<String, dynamic> eyeSelf = inputs['eyelineSelftest'] as Map<String, dynamic>? ?? <String, dynamic>{};
  final Map<String, dynamic> rigidSelf = inputs['rigidSelftest'] as Map<String, dynamic>? ?? <String, dynamic>{};
  b.writeln('### 量具自检（量不准的量具没有资格判别人）');
  b.writeln('- 眼线量具：最大误差 ${eyeSelf['max_abs_err_deg'] ?? 'N/A'}°，'
      '门槛 $kEyelineMaxErrDeg° → ${_okStr(eyeSelf['max_abs_err_deg'], kEyelineMaxErrDeg)}');
  b.writeln('- 刚体配准量具：最大误差 ${rigidSelf['max_abs_err_deg'] ?? 'N/A'}°，'
      '门槛 $kRigidMaxErrDeg° → ${_okStr(rigidSelf['max_abs_err_deg'], kRigidMaxErrDeg)}');
  b.writeln('- 两条路径的独立测量一致性：见「交叉复核」一节');
  b.writeln('- 门槛由**门禁**定（不是工具自报）：眼线量具喂亚度级统计，故要求 0.5°；'
      '刚体量具只用于 ≥1.5° 量级的分歧复核，1.0° 够用。');
  b.writeln();

  b.writeln('### 交叉复核（gatekeeper 眼线量具 vs qa-batch 眼线测量）');
  b.writeln(_crossCheck(inputs));
  b.writeln();
  b.writeln('### 去重口径（法典条款 6 的同性质要求：不得用未去重的计数虚增覆盖）');
  b.writeln(_dedup(inputs));
  b.writeln();
  b.writeln('### 样本账（ACCEPTANCE 计分口径第 7 条：样本不得静默消失）');
  b.writeln(_sampleLedger(inputs));
  b.writeln();
  b.writeln('### 贴线项（余量 vs 量具误差）');
  b.writeln(_borderline(items));
  b.writeln();

  b.writeln('### 判定明细');
  for (final Map<String, dynamic> i in items) {
    b.writeln('#### ${i['id']} ${i['pass'] == true ? 'PASS' : (i['manual'] == true ? 'FAIL [MANUAL]' : 'FAIL')}');
    b.writeln('- 期望：${i['expected']}');
    b.writeln('- 实测：');
    for (final String line in (i['actual'] as String).split('\n')) {
      b.writeln('  $line');
    }
  }

  if (failed.isNotEmpty) {
    b.writeln();
    b.writeln('### 失败项');
    b.writeln('| 项 | 期望 | 实测 | 责任 agent |');
    b.writeln('|---|---|---|---|');
    for (final Map<String, dynamic> i in failed) {
      final String act = (i['actual'] as String).split('\n').first;
      b.writeln('| ${i['id']} ${i['description']} | ${_oneLine(i['expected'])} | ${_oneLine(act)} '
          '| ${i['owner'] ?? '未定位'} |');
    }
    b.writeln();
    b.writeln('### 回派指令');
    final Map<String, List<String>> byOwner = <String, List<String>>{};
    for (final Map<String, dynamic> i in failed) {
      final String o = (i['owner'] as String?) ?? '未定位';
      byOwner.putIfAbsent(o, () => <String>[]).add(i['id'] as String);
    }
    for (final MapEntry<String, List<String>> e in byOwner.entries) {
      b.writeln('- ${e.key}：${e.value.join("、")} 未达标，详见上面各项「实测」。');
    }
  }

  b.writeln();
  b.writeln('### 哈希（本轮 pre-run 快照）');
  b.writeln('```');
  b.write(_formatHashes(hashes));
  b.writeln('```');
  return b.toString();
}

String _oneLine(Object? v) => (v?.toString() ?? '').replaceAll('\n', ' ').replaceAll('|', '/');

String _okStr(Object? v, double limit) {
  final double? d = (v as num?)?.toDouble();
  if (d == null) return '未产出（无法判定）';
  return d <= limit ? '合格' : '超限 → 判定标 MANUAL，不计实现方责任';
}

String _hashVerdict(Map<String, String> cur, Map<String, String>? prev) {
  if (prev == null) return '首轮，建立基线';
  final List<String> diffs = <String>[];
  final Set<String> self = _selfTouched();
  for (final MapEntry<String, String> e in cur.entries) {
    if (self.contains(e.key)) continue;
    final String? p = prev[e.key];
    if (p != null && p != e.value) diffs.add('${e.key}: $p → ${e.value}');
  }
  for (final String k in prev.keys) {
    if (!cur.containsKey(k) && !self.contains(k)) diffs.add('$k: 上一轮存在，本轮消失');
  }
  if (diffs.isEmpty) return 'OK（本轮自报改动：${self.where(cur.containsKey).length} 个，见 out/GATE_P0_selfchanges.txt）';
  return '已变更：\n  - ${diffs.join('\n  - ')}';
}

/// 条款 7 的样本账。
///
/// 法典原话：任何"不可计分"的样本必须逐条列出并归类（抠图失效 / 量测失效 / 其他），
/// 且在总数与通过数里同时显式扣除；归类为"量测失效"的每一条，必须由 gatekeeper
/// 用与 qa-batch 不同的独立路径复核一次并写明结论。
///
/// 本门的做法是**不扣除**：每一条样本都拿到了残余值，只是出处不同
/// （gate_eyeline / qa_eyeline / derived_identity），并逐条写明复核结论。
/// 分母因此保持 100 = 原始总数，不存在"样本悄悄消失"的空间。
String _sampleLedger(Map<String, dynamic> inputs) {
  final List<Map<String, dynamic>> samples = buildSamples(inputs);
  final List<Map<String, dynamic>> mineFail =
      samples.where((Map<String, dynamic> s) => s['gate_measurable'] != true).toList();
  final StringBuffer b = StringBuffer();
  b.writeln('原始样本总数 ${samples.length} 条（全部来自 `$kComposePath` 的 `$kSpec` 记录），'
      '扣除 0 条，可计分 ${samples.length} 条。');
  b.writeln();
  b.writeln('没有样本"因为量不出来而不算数"：眼线量具测不出的 ${mineFail.length} 条，'
      '全部改由 SIFT 源图↔成片配准独立测出（残余 = 真值 − 实测施加角），逐条如下。');
  b.writeln();
  b.writeln('| 样本 | 眼线量具为何失效 | 归类 | SIFT 独立复核 | 最终取值 |');
  b.writeln('|---|---|---|---|---|');
  for (final Map<String, dynamic> s in mineFail) {
    final bool siftOk = s['sift_ok'] == true;
    final Object? qa = s['qa_residual'];
    final String qaStatus = (s['qa_status'] as String?) ?? 'n/a';
    final String reason = s['gate_reason'] as String;
    // 归类依据事实，不依据猜测：眼线量具失败的两种成因是"成片被裁坏、人脸出画"
    // 和"抠图把眼区打成 alpha 空洞"。二者都会让 Haar 找不到眼，但成因和责任方不同。
    final bool cropBroken = reason == 'no_face' && siftOk;
    final String cat = reason == 'implausible_eyedist'
        ? '量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下）'
        : (cropBroken
            ? '成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**）'
            : '抠图失效（眼区被 alpha 空洞打掉）');
    String concl;
    if (!siftOk) {
      concl = 'SIFT 也配不上——这条仍未测出，须人工介入。';
    } else {
      final Object? sr = s['sift_residual'];
      concl = 'SIFT 实测施加角 ${_f((s['sift_applied'] as num).toDouble())}°，'
          '与生产记录差 ${_f((s['sift_delta_vs_record'] as num).toDouble())}° → 残余 '
          '${sr == null ? "（该条真值缺失，算不出残余）" : _f((sr as num).toDouble()) + "°"}';
      if (qa != null) {
        concl += '；qa-batch 读数 ${_f((qa as num).toDouble())}°（$qaStatus）';
        if (qaStatus == 'reliability_mismatch' || qaStatus == 'unmeasured') {
          concl += ' —— 已被 qa-batch 自己声明不可靠，不采信';
        }
      }
    }
    b.writeln('| ${s['id']} | $reason | $cat | $concl | ${_f(s['residual'] as double)}°'
        '（${s['residualBy']}） |');
  }
  b.writeln();
  // 条款 7 点名的 c08_d+10 单独写结论。数字全部从样本表里取，不写死——
  // 写死的话下一轮换了 revision 就会变成假证据。
  Map<String, dynamic>? find(String id) {
    for (final Map<String, dynamic> s in samples) {
      if (s['id'] == id) return s;
    }
    return null;
  }

  final Map<String, dynamic>? up = find('c08_d+10');
  final Map<String, dynamic>? dn = find('c08_d-10');
  if (up != null && up['sift_ok'] == true) {
    b.writeln('**条款 7 点名的那条（`c08_d+10`）的定论**：它的 alpha 是干净的'
        '（qa-batch 扫到 eyeBandZeroFrac 0.002），却被 qa-batch 的自证式检查判为 unreliable，'
        '正是"把真实缺陷归成量不出来"的现成嫌疑。本门用 SIFT 独立量了源图→成片这一跳：'
        '实测施加角 ${_f((up['sift_applied'] as num).toDouble())}°，'
        '与生产记录 ${_f(up['applied'] as double)}° 差 '
        '${_f((up['sift_delta_vs_record'] as num).toDouble())}°，'
        '残余 = 真值 ${_f(up['truth'] as double)} − 实测施加角 = '
        '**${_f(up['residual'] as double)}°**，|残余| ≤ ${kResidualMaxDeg}° → **不构成违规**。'
        'qa-batch 那一支的 ${up['qa_residual'] == null ? "—" : _f((up['qa_residual'] as num).toDouble())}° '
        '是量测假象，它自己也已标注 reliability_mismatch。'
        '（顺带纠正一处易错：`c08_d+10` 的真值是 −8.01+10 = ${_f(up['truth'] as double)}°，'
        '不是 18.01°；18.01° 是 `d-10` 那条'
        '${dn == null ? "" : "，它反而被正常摆平到 ${_f(dn['residual'] as double)}°"}。）');
    b.writeln();
  }
  b.writeln('三台量具在 c08 家族上的对照（同一批成片，互不调用）：'
      '眼线量具全部失效；SIFT 全部配得上；qa-batch 的 pupil 法在 4 条上给出被它自己否掉的数。'
      '值得一提：`c08_d-10` 的眼区被抠图打掉 96.8%，SIFT 仍给出与生产记录差 0.032° 的读数——'
      '它配的是整个头部的特征，不吃眼睛那一块。');
  b.writeln();
  b.writeln('**顺带发现：1 条须回派，1 条经代码复核后关掉**');
  b.writeln('1. **【独立的 G2B 缺陷｜归属 imaging｜处置时序"P0 PASS 后"】'
      '紧取景源图的裁剪框落到源图之外，成片留下底色填充的切口。**'
      '**它不是 P0 的失败项**——P0 判的是摆正估计的准确性，本条与摆正无关；'
      '记在这里，只是因为本门为了量摆正把成片逐张渲染出来时看见了它。');
  b.writeln('   本门**渲染成片逐张看过**，不是只看指标：'
      '真实照片 `C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_11_Pro.jpg`（`c08`）'
      '的成片人头占满上部、**下巴被下边缘切掉**、下缘约三成是空白底色；'
      '它的竖直副本 `c08_upright`（`straightened=false`，**没做任何旋转**）同样坏，越界 29.0%。');
  b.writeln('   **疑似是两种不同的缺陷，请 imaging 逐张判、别统一成一条**：'
      '① **裁剪**——`c08` 下缘是**水平**切口（取景框伸到图片下边界之外）；'
      '② **抠图**——同一张成片左侧中部与右侧中部**各有一团孤立碎屑**'
      '（浮在空白背景里、与人物不连通），属 G2A/2A 口径，不是裁剪。'
      '`p1` 的切口则是**斜的**（左下），与 `c08` 的水平切口形态不同，'
      '所以**可能不止一种机制**。');
  b.writeln('   指标分布（`cn_big_1inch` 100 条）：越界 >0 共 73 条、>0.10 共 40 条、>0.20 共 26 条，'
      '中位 0.0423，最大 `c05_upright` 43.5%；用户自己的照片 `p1` 15.4%、`p2` 2.1%。');
  b.writeln('   **两条必须写清楚，免得被读歪**：'
      '① **不是旋转造成的**——最坏的两条 `c05_upright` / `c08_upright` 恰恰没旋转，'
      '`c05` 家族跨 Δ 无单调趋势（Δ=0 → 0.360，d+3 → 0.429，d+10 → 0.323，d−5 → 0.272）；'
      '② **越界比例本身不等于可见破损**——`c05` 越界 36.0% 成片仍然正常，'
      '真正肉眼可见破损的是 `c08` 与 `c08_upright`。'
      '**不要拿一个数字去推断严重程度。**');
  b.writeln('2. **`c08` 旋转夹具的眼区 alpha 空洞 = 夹具伪影 / 无用户影响**（不复判、不回派）。'
      '现象：源图先旋转再喂给管线时，c08 的旋转夹具眼区被 alpha 打掉'
      '（`c08_d-10` 96.8%、`c08_d-5` 75.5%、`c08_upright` 61.9%），'
      '而 Pictures 里 14 张未旋转人像的空洞率全为 0.0000（`out/P0_alpha_holes.json`）。'
      '裁定它不是产品缺陷，依据是生产路径**永远不会**把面内旋转过的图喂给抠图引擎——'
      '四条都由本门独立复核过，不是转述：'
      '`lib/core/controller.dart:137` 把用户原始 `bytes` 直传 `removeBackground`，'
      '同一份 `bytes` 在 `:146` 传给 `detectFace`，中间无预处理；'
      '`lib/core/matting/matting_engine.dart` 与 `matting_worker.dart` 内'
      '**没有任何**旋转/转置/仿射调用（grep 命中 0）；'
      '抠图前的唯一朝向处理是 `lib/core/matting/image_ops.dart` 的 EXIF `bakeOrientation`，'
      '它只可能是 90° 整数倍的转置，不产生任意面内角；'
      '面内旋转只出现在 `lib/core/imaging/compose_engine.dart:232` 的 `planRotation`，'
      '而 compose 跑在抠图**之后**。'
      '推论：该空洞需要"输入被任意角旋转过"这一前提，用户碰不到，'
      '故**既不进 P0 判据，也不进 G2A 判据，不回派**。'
      '本门采信它的唯一后果是：那几条不得不用 SIFT 兜底，不影响任何一条 P0 结论。');
  return b.toString();
}

/// 去重口径：把"覆盖了多少张不同照片"按去重后的数写，并点出重叠关系。
///
/// 数字全部来自 `out/gate_P0_overlap.json`（gatekeeper 自己的量具量的），
/// 不写死——写死的话下一轮换了夹具就变成假证据。
/// 用**去重量具**（`tools/gate/p0_overlap.py` → `$kOverlapPath`）给出的同图对，
/// 把一组样本按"是不是同一张照片"归并，返回**不同照片数**。
///
/// 为什么不能直接用 `rows.length`：那是**行数**，恒 ≥ 不同照片数。
/// P0.1a 的判据文本写的是"样本 ≥ 8 张**不同照片**"，用行数判就是**判据比它的
/// 名字松** —— 同一个形状本轮已经在 `visual`、`singleObsDeg`、`_delta_of`、
/// owner 别名上见过五次，这次长在门禁自己身上（主会话 2026-09-17 报的）。
/// 这是把**实现对齐到冻结的判据文本**，不是改阈值：`kMinDistinctPhotos = 8` 未动。
///
/// 量具的**局限一并继承**：48×48 签名法测不出"同一场景的不同裁切/不同取景"，
/// `c10`/`c11`/`c12` 这类它分辨不了 —— 所以它**不去重**它们（法典条款 6 的订正
/// 结论本就是三张不同照片、各自计数）。不去重是保守方向：只会让计数偏高、
/// 更容易过下限，因此**不会**制造假 FAIL；但也**不能**反过来拿它论证
/// "那三张里有两张其实是同一张"。
///
/// 返回 `null` = 去重量具没产出 / 结论不完整 ⇒ 调用方必须报"判不了"。
/// **不许退回行数** —— 退回行数正是这个缺陷本身。
int? distinctPhotoCount(
  List<Map<String, dynamic>> rows,
  Map<String, dynamic>? overlap,
) {
  if (overlap == null) return null;
  final Object? dup = overlap['intra_duplicates'];
  if (dup is! List<dynamic>) return null;
  final Map<String, String> parent = <String, String>{};
  String find(String x) {
    parent.putIfAbsent(x, () => x);
    String root = x;
    while (parent[root] != root) {
      root = parent[root]!;
    }
    // 路径压缩
    String cur = x;
    while (parent[cur] != root) {
      final String next = parent[cur]!;
      parent[cur] = root;
      cur = next;
    }
    return root;
  }

  for (final dynamic d in dup) {
    if (d is! Map<String, dynamic>) return null;
    final Object? a = d['a'];
    final Object? b = d['b'];
    if (a is! String || b is! String) return null;
    parent[find(a)] = find(b);
  }
  final Set<String> roots = <String>{};
  for (final Map<String, dynamic> r in rows) {
    final Object? id = r['id'];
    if (id is! String) return null;
    roots.add(find(id));
  }
  return roots.length;
}

String _dedup(Map<String, dynamic> inputs) {
  final Map<String, dynamic>? o = inputs['overlap'] as Map<String, dynamic>?;
  if (o == null) return '去重量具未产出 `$kOverlapPath`，本轮无法给出重叠关系。';
  final StringBuffer b = StringBuffer();
  final int entries = (o['anchor_entries'] as num).toInt();
  final List<dynamic> intra = (o['intra_duplicates'] as List<dynamic>? ?? <dynamic>[]);
  final List<dynamic> cross = (o['golden_overlap'] as List<dynamic>? ?? <dynamic>[]);
  b.writeln('- 锚点条目 **$entries** 条（`corpus == anchor`，**不含 `p2`**——法典条款 6 订正后'
      '明写 p2 归入 `straight`、不计入锚点栏）。本量具测出**同图重复 ${intra.length} 对**：'
      '${intra.map((dynamic d) => '`${(d as Map<String, dynamic>)['a']}` ≡ '
          '`${d['b']}`（MAE ${(d['mae'] as num).toStringAsFixed(2)}）').join('、')}。');
  b.writeln('- **去重后 = $entries − ${intra.length} = '
      '${(o['distinct_photos_after_dedup'] as num).toInt()} 张不同照片**，'
      '与法典条款 6 订正后的算式「12 − `c03`/`c04` 这一对真重复 = 11」**独立吻合**。');
  final int same = (o['golden_same_photo_n'] as num?)?.toInt() ?? 0;
  final int gn = (o['golden_n'] as num?)?.toInt() ?? 0;
  b.writeln('- 黄金集 $gn 张中 **$same 张在非旋转源照片里有同图**'
      '${o['golden_all_in_anchor'] == true ? '（**全部 $gn 张都是锚点/竖直样本的照片**，黄金集不是独立样本）' : ''}：');
  for (final dynamic raw in cross) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    if (c['same_photo'] != true) continue;
    b.writeln('  - `${c['golden']}` ≡ `${c['nearest_anchor']}`'
        '（${c['nearest_corpus'] ?? "anchor"}，MAE ${(c['mae'] as num).toStringAsFixed(2)}）');
  }
  b.writeln('- **本量具的局限（必须写明）**：整幅签名法**测不出"同一场景的不同裁切/不同取景"**，'
      '所以 `c10`/`c11`/`c12` 这类它分辨不了。**法典条款 6 已于 2026-09-17 订正：'
      '三者是同一场景的三张不同照片，不去重、各自计数**（依据是"只统计结构像素"的'
      'ECC 对齐复核，`c10`/`c11` 结构像素 ≤5 灰阶仅 11.3%，而已知同图对 `c03`/`c04` 为 95.2%）。'
      '本门**不推翻也不重复验证**该结论，只声明本量具对这个量级不敏感、不参与该判定。');
  b.writeln('- 同一订正还排除了 `c07`↔`p2`（全图相似度一度很高，限制到结构像素后仅 24.2%）。'
      '这与本门的观察一致：该对 MAE 9.10，比同图簇（≤2.4）高一个量级，'
      '本门当时就**没有**按同图计。');
  b.writeln('- **结论**：`P0.4` 的 `RollSource` 分布里，'
      '"黄金集"与"锚点"两列**讲的是同一批照片**，不得相加当作独立覆盖数；'
      '凡涉及"覆盖了多少张不同照片"的表述，本报告一律按去重口径写。');
  return b.toString();
}

/// 贴线项：判决余量小于该判据所用**量具自身误差**的条目。
///
/// 判据与量具误差同量级时，单次读数翻不翻更多取决于量具噪声，而不是实现改了什么。
/// 阈值已冻结、不动；这里只做两件事：把余量写进报告（读者才知道是稳过还是擦过），
/// 以及在真翻 FAIL 时要求第二支独立量具复现同一超线才计违规。
String _borderline(List<Map<String, dynamic>> items) {
  final StringBuffer b = StringBuffer();
  final List<String> rows = <String>[];
  final List<String> notes = <String>[];
  for (final Map<String, dynamic> i in items) {
    // 一个条目可以有多个子量（如 P0.5b 的"施加几何"与"跨量具一致性"），
    // 逐个报，免得读者把判据量和辅助量混成一个数。
    final Object? subs = i['subchecks'];
    if (subs is List) {
      for (final dynamic raw in subs) {
        final Map<String, dynamic> s = raw as Map<String, dynamic>;
        final num? m = s['margin'] as num?;
        final String val = _f((s['value'] as num).toDouble());
        final String role = s['criterion'] == true ? '**判据量**' : '辅助量';
        final Object? e = s['instrumentErr'];
        final String tail = e is num
            ? (m != null && m.abs() < e
                ? '**贴线**（余量 < 量具误差）'
                : '余量 > 量具误差，稳过')
            : '—（无对应该量的量具误差）';
        final String margin = m == null ? '—' : '${_f(m.toDouble())}°';
        final String err = e is num ? '${_f(e.toDouble())}°' : '—';
        rows.add('| ${i['id']} | $role ${s['name']} | 实测 $val° | '
            '$margin | $err | $tail |');
        if (s['criterion'] == true && m != null) {
          final String q = (e is num && m.abs() < e) ? '**贴线，须两支量具一致才定罪**' : '余量充足';
          notes.add('${s['name']}（判据量）实测 $val°，余量 ${_f(m.toDouble())}° → $q。');
        }
      }
      continue;
    }
    final Object? m = i['margin'];
    final Object? e = i['instrumentErr'];
    if (m is! num || e is! num) continue;
    final String verdict = i['pass'] == true ? 'PASS' : 'FAIL';
    final String tail = m.abs() < e
        ? '**贴线**（余量 < 量具误差）'
        : '余量 > 量具误差';
    rows.add('| ${i['id']} | $verdict | 实测 — | ${_f(m.toDouble())}° | '
        '${_f(e.toDouble())}° | $tail |');
  }
  if (rows.isEmpty) {
    return '本轮没有条目带"余量 / 量具误差"记账。';
  }
  b.writeln('| 项 | 子量 | 本轮实测 | 余量 | 该量具自检误差 | 结论 |');
  b.writeln('|---|---|---|---|---|---|');
  for (final String r in rows) {
    b.writeln(r);
  }
  b.writeln();
  if (notes.isNotEmpty) {
    for (final String n in notes) {
      b.writeln('- $n');
    }
    b.writeln();
  }
  for (final Map<String, dynamic> i in items) {
    if (i['corroboration'] == null) continue;
    b.writeln('- **${i['id']} 的复核口径**：${i['corroboration']}'
        '（本轮第二支量具 ${i['corroborated'] == true ? '未超线 → 若本项翻 FAIL 即属边界噪声' : '亦超线 → 计违规'}）');
  }
  b.writeln();
  b.writeln('规则（主会话 2026-09-17 裁定，与条款 7 同源）：余量 < 量具误差的条目，'
      '**单支量具的 FAIL 不足以定罪** —— 必须第二支独立量具复现同一超线才计违规；'
      '只有一支超线则记「边界噪声 / 证据不足」，不消耗实现方修复轮次。'
      '**本规则不适用于 P0.3a**：它超阈值 7 倍以上且两支量具独立复现，是确定性违规。');
  return b.toString();
}

/// 把"这份判决绑在哪个版本上"写成一行，避免读者以为它绑定到了某个 commit。
///
/// 教训来源（PITFALLS 2026-09-17）：**测量台是从工作树编译的**，
/// "提交了"只保证存在一个可引用的版本，不保证被测的字节就是它。HEAD 干净而
/// 工作树脏时，跑出来的读数绑不到任何 commit，而且**不会报错**。
/// 本项只报告事实，不因此判 FAIL——它是纪律问题，不是作弊。
String _treeState(Map<String, dynamic> inputs) {
  final StringBuffer b = StringBuffer();
  final RunResult head = _gitSync(<String>['rev-parse', '--short', 'HEAD']);
  final RunResult dirty = _gitSync(<String>['status', '--porcelain', 'lib/']);
  final String headStr = head.exitCode == 0 ? head.stdout.trim() : '（取不到）';
  final String dirtyStr = dirty.stdout.trim();
  b.writeln('- HEAD = `$headStr`；'
      '判 selfcheck 那几条（P0.5a）编译自**工作树**，不是这个 commit。');
  if (dirty.exitCode != 0) {
    // 取不到 ≠ 没有。`git status` 失败时 stdout 是空的，若照旧走下面那条
    // "干净"分支，报告会**断言一个它没能验证的事实** ——
    // 与条款 1 那次是同一形状（命令没跑成，检查读成干净）。
    // 判据侧的 `frozen` 已经查了 exitCode，这里修的是**报告文字**不许说假话。
    b.writeln('- `git status lib/` **取不到**（exitCode=${dirty.exitCode}）：'
        '本轮**无法**断言工作树是否干净。诊断：${dirty.stderr.trim()}');
  } else if (dirtyStr.isEmpty) {
    b.writeln('- `git status lib/` **干净**：本轮读数可绑定到 `$headStr`。');
  } else {
    final List<String> files =
        dirtyStr.split('\n').where((String s) => s.trim().isNotEmpty).toList();
    b.writeln('- `git status lib/` **不干净**（${files.length} 个文件）：'
        '${files.map((String s) => '`${s.trim()}`').join('、')}。');
    b.writeln('- **结论：本轮读数绑定不到任何 commit。** '
        '其中 P0.1a / P0.2 / P0.3a / P0.3b 来自 `$kComposePath`'
        '（qa-batch 在它自己那一版工作树上产出），'
        'P0.5a 来自本机**当前**工作树编译的 `dev_selfcheck` —— '
        '两半可能不是同一版代码。修掉的办法只有一个：'
        '运行期间冻结 `lib/`，开跑前 `git status lib/` 必须干净。');
  }
  b.writeln(_inputIntegrity(inputs));
  b.writeln(_summaryCompleteness(inputs));
  return b.toString();
}

/// 测量产出的来源绑定：`out/` 下的数据每轮重生成，**不受冻结约束**，
/// 所以"工作树干净"推不出"盘上的数是当前代码跑的"。这一节把绑定结论原样印出来。
///
/// 渲染实现在 `provenance.dart`（`provenanceMdSection`）—— 放那边是为了能自测：
/// 这段文本只有在 `main()` 走到最后才会生成，写在私有函数里就只能靠跑一整轮
/// （含 40 分钟的 flutter test）来发现它崩了。
String _provenanceSection(Map<String, dynamic> inputs) =>
    provenanceMdSection(inputs['provenance'] as Map<String, dynamic>?);

/// 判据分母的内容钉 —— 含**被排除的路径逐条列出**，以及一条不许被误读的附注。
///
/// 附注存在的理由（主会话 2026-09-17 要求写进 evidence）：
/// 「数值叶哈希未变」**推不出**「证据仍然有效」。叶子不变只能证明**没人在文件里
/// 改过这个数**，证明不了**这个数还是当前代码会产生的结果**。两条真实的反例：
///
///  - `c06_d-3`（具体到可复核）：真值文件记着 `appliedStraightenDeg = -15.424`、
///    `outputTiltDeg = 10.638`。而 `native/bench/` 连续四版（04:47 / 05:04 / 05:20 /
///    05:44）都报 `c06_d-3 est=unavail` —— 按契约 `unavailable ⇒ rollDeg = 0.0`，
///    于是实际施加 0.0。**记着的 −15.424 是陈旧的**，叶没变、值已经不成立。
///  - "数目相等 ≠ 内容相同"：本轮之前已经出现两次（`lib` 域 29 vs 101 个文件、
///    `files` 计数相等而集合不同）。叶比对是同一形状的第三次机会。
///
/// 所以：**内容钉只覆盖"判据输入有没有被人动过"，覆盖率/有效性由覆盖率类条目与
/// 同源绑定分别管**，本条目不兼任。
String _truthPinSection(Map<String, dynamic> inputs) {
  final Object? t = inputs['truthDriftResult'];
  return truthPinMdSection(t is TruthDrift ? t : null);
}

String _denominatorMdSection(Map<String, dynamic> inputs) {
  final Object? d = inputs['denominatorAgreement'];
  return denominatorMdSection(d is Map<String, dynamic> ? d : null);
}

String _evidenceProvenanceMdSection(Map<String, dynamic> inputs) {
  final Object? e = inputs['evidenceProvenance'];
  return evidenceProvenanceMdSection(e is Map<String, dynamic> ? e : null);
}

/// 渲染实现**公开**，理由与 `provenanceMdSection` 相同：这段文本只有
/// `gate_P0.dart` 的 `main()` 走到最后才会生成，留在私有函数里就只能靠跑一整轮
/// （含 40 分钟的 `flutter test dev_selfcheck`）才发现它崩了。已经栽过一次
/// （`'$b.path'` 被 Dart 解析成 `$b` + 字面量 `.path`，渲染出 `Instance of ...`）。
String truthPinMdSection(TruthDrift? t) {
  if (t == null) {
    return '缺少 `truthDriftResult`，**无法证明判据分母未被改动** → 判不可判，不判通过。';
  }
  final StringBuffer b = StringBuffer();
  b.writeln('- 参与逐叶比对的数值叶：**${t.leafCount} 个**；'
      '被排除：**${t.excludedLeafPaths.length} 个**');
  b.writeln('- ${t.pinNote()}');
  b.writeln('- ${t.exclusionNote()}');
  b.writeln('- 排除集定义位置：`tools/gate/gate_P0.dart` 的 '
      '`kTruthLeafExcludedPrefixes`（**常数**，故受防作弊条款 2 的 SHA256 保护 —— '
      '想放宽必须在 diff 里留下代码改动，不能靠改数据做到）');
  b.writeln('- 排除**两侧同用**（基线侧也过滤）：只排一侧会把基线里的同名叶子报成 N 处"删除"，'
      '是纯假阳性。');
  b.writeln('- 换钉子对象要**同时**满足两件事：变更在代码里（受条款 2 保护），'
      '**且** `旧 -> 新` 这一对在 `kPinRetargetLedger` 里登记过理由。'
      '只做到前者，等于把「删掉基线文件重设锚」换成「改一个常数重设锚」——'
      '同一条绕过路径换了个入口。');
  b.writeln('- **内容钉覆盖不到的地方（逐条列出，不藏）**：'
      '本钉只比**数值叶**。`$kTruthV0Path` 里另有一批**字符串**字段也是判据输入，'
      '它们**不在**内容钉里：`convention`（符号约定的正文）、`generatedBy`、'
      '`baselineTag`、`version`。改这些字符串不会让本钉响。'
      '它们目前只有两道覆盖：`test/` 冻结（条款 1）与 git 历史。'
      '**这是一处已知缺口，不当作已覆盖。**（把字符串也纳入内容钉会让"合法表述订正"'
      '与"改口径"无法区分，那是另一件事，不在本轮改。）');
  b.writeln('- **附注（不许被误读）：数值叶哈希未变 ≠ 证据仍然有效。**'
      '叶不变只证明**没人在文件里改过这个数**，证明不了**这个数还是当前代码会产生的结果**。'
      '实例：`c06_d-3` 在本文件里记着 `appliedStraightenDeg = -15.424`、'
      '`outputTiltDeg = 10.638`，而 `native/bench/` 连续四版（04:47 / 05:04 / 05:20 / 05:44）'
      '均报 `c06_d-3 est=unavail` —— 按契约"`unavailable` ⇒ `rollDeg = 0.0`"，'
      '实际施加的是 **0.0**，记着的 −15.424 是**陈旧的**。'
      '这个叶从头到尾没变过，值却早就不成立了。'
      '**"叶哈希未变"是"没人动过"的证据，不是"数据仍然成立"的证据**——'
      '后者由覆盖率类条目（P0.1b / P0.3b）与测量产出的同源绑定分别负责。');
  return b.toString();
}

/// 生成件与手写分母的逐条比对 —— **渲染实现公开，可自测**，理由同 `truthPinMdSection`。
String denominatorMdSection(Map<String, dynamic>? da) {
  if (da == null) {
    return '- **不可判**：缺 `denominatorAgreement`（本检查未产出）。**不默认相等。**';
  }
  final StringBuffer b = StringBuffer();
  b.writeln('- 手写分母 `$kTruthV0Path`（sha256 前缀 '
      '`${(da['v0Hash'] as String?)?.substring(0, 16) ?? "?"}…`）'
      ' vs 生成分母 `$kTruthPath`（`${(da['generatedHash'] as String?)?.substring(0, 16) ?? "?"}…`）');
  b.writeln('- **比对范围由手写件决定**（不硬编码清单名）：手写件里每个**列表**值'
      '都要在生成件里逐条对上 —— 生成件不得改动或丢掉任何一条，'
      '也不得缺少手写件写了任何一个字段。'
      '生成件**自己的派生字段**（`corpus` / `kind` / `derivedAnnotations` / `end_to_end` …）'
      '不参与比对：它们是产物，不是分母。');
  b.writeln('- ${da['summary'] ?? "（无摘要）"}');
  final List<dynamic> und = da['extraUndeclared'] as List<dynamic>? ?? <dynamic>[];
  final List<dynamic> probs = da['problems'] as List<dynamic>? ?? <dynamic>[];
  if (probs.isEmpty && und.isEmpty && da['readable'] == true) {
    b.writeln('- 结论：**逐条相等**。');
  } else {
    b.writeln('- 结论：**不等** → 本项 FAIL（判据分母是全部 P0 条目的立足点）。逐条：');
    for (final dynamic x in und) {
      b.writeln('  - [多出] $x');
    }
    for (final dynamic x in probs) {
      b.writeln('  - $x');
    }
  }
  b.writeln('- **不许被读大**：这一条证明"生成件用的是手写件的分母"，'
      '**不证明**这份分母本身是对的。前者是完整性，后者要靠锚点复核与人工审查。');
  return b.toString();
}

/// 派生块证据溯源 —— **渲染实现公开，可自测**，理由同上。
String evidenceProvenanceMdSection(Map<String, dynamic>? ev) {
  if (ev == null) {
    return '- **不可判**：缺 `evidenceProvenance`（本检查未产出）。**不默认相符。**';
  }
  final StringBuffer b = StringBuffer();
  b.writeln('- 指针（写死在门禁里，不随数据飘）：'
      '`${kEvidenceProvenancePointer.join("/")}`');
  b.writeln('- ${ev['summary'] ?? "（无摘要）"}');
  final Map<String, dynamic> rec =
      ((ev['recorded'] as Map?) ?? <String, dynamic>{}).cast<String, dynamic>();
  final Map<String, dynamic> now =
      ((ev['onDisk'] as Map?) ?? <String, dynamic>{}).cast<String, dynamic>();
  for (final String p in rec.keys) {
    final String? a = rec[p] as String?;
    final String? c = now[p] as String?;
    b.writeln('  - `$p`：记录 `${a?.substring(0, 16)}…`，'
        '盘上 ${c == null ? "**不在**" : "`${c.substring(0, 16)}…`"}');
  }
  final List<dynamic> probs = ev['problems'] as List<dynamic>? ?? <dynamic>[];
  if (probs.isEmpty && ev['readable'] == true) {
    b.writeln('- 结论：**逐份相符**。');
  } else {
    b.writeln('- 结论：**不相符 → 本项 FAIL**。逐条：');
    if (ev['error'] != null) b.writeln('  - ${ev['error']}');
    for (final dynamic x in probs) {
      b.writeln('  - $x');
    }
  }
  b.writeln('- **边界（不许被读大）**：这证明的是「派生叙述与盘上这几份产物一致」，'
      '**不是**「产物出自当前被测代码」—— 源产物自己**没有**代码指纹。'
      '后一件事由「测量产出的来源绑定」那一节管，两件事别混。');
  return b.toString();
}

/// 输入文件完整性：`$kComposePath` 里记的成片路径，**现在是否还在磁盘上**。
/// 存在理由（2026-09-17 实测）：qa-batch 的一轮死运行覆盖了 r1 的成片，
/// 回滚后 13 条锚点成片（11 张锚点 + p1 + p2）不在原路径上，
/// 于是 `out/P0_compose_items.jsonl` 记的路径**指向不存在的文件**。
/// 这种情况下 `--reuse` 会把上一轮的读数当成这一轮的——看起来一切正常。
/// 所以每次出报告都必须把这件事写出来，不许它静默。
String _inputIntegrity(Map<String, dynamic> inputs) {
  final Object? rs = inputs['roundState'];
  if (rs is! Map<String, dynamic>) {
    return '- **输入完整性：无法判定**（缺 `roundState`）。';
  }
  final Map<String, dynamic> r = rs;
  final List<String> exempt = (r['freezeExempt'] as List<dynamic>? ?? <dynamic>[])
      .map((dynamic e) => e.toString())
      .toList();
  // 豁免的**范围与理由**必须写在报告里，免得将来有人把"一个文件不进测量链"
  // 读成"门禁放松了"。
  final String freezeNote = '- **冻结范围**：`lib` / `test` / `tools` / `docs` **全部在冻结内**；'
      '唯一豁免 `$kFreezeExemptPath` 这一个文件（它不进任何测量链——门禁不读它、判据不引用它、'
      '读数不经过它；且 CLAUDE.md §4 规定所有 agent 可随时只追加）。'
      '**`docs/` 里除它以外的任何改动（含 `ACCEPTANCE.md`/`RUBRIC.md`/`CONTRACTS.md`/`DESIGN.md`/`ENV.md`）'
      '仍会作废整轮。**'
      '${exempt.isEmpty ? "本轮无豁免条目。" : "本轮豁免条目：${exempt.join("、")}。"}\n';
  final int total = (r['composeDeclared'] as num?)?.toInt() ?? 0;
  final int parsed = (r['composeParsed'] as num?)?.toInt() ?? 0;
  final int nMiss = (r['composeMissingFiles'] as num?)?.toInt() ?? 0;
  final List<String> missing = (r['composeMissingIds'] as List<dynamic>? ?? <dynamic>[])
      .map((dynamic e) => e.toString())
      .toList();
  if (nMiss == 0 && total == parsed) {
    return freezeNote +
        '- 输入完整性：`$kComposePath` 声明 $total 条、解析到 $parsed 条，'
        '成片文件**全部存在**。注意这只说明"此刻文件在"，**不等于历史轮次可复算**。';
  }
  return freezeNote +
      '- **输入完整性：$total 条里有 $nMiss 条的成片文件不存在**'
      '（读数对应的文件已被覆盖或删除，**本轮不可复现**）：'
      '${missing.take(15).join('、')}${missing.length > 15 ? ' …' : ''}\n'
      '- 后果：这些条目的读数来自**上一轮当时的文件**，现在既不能重测也不能复核。'
      '出这一条本身不代表判决错，但读者必须知道哪些数字是**不可追溯**的。'
      '**不要拿当前成片目录去重新推导历史轮次的残余**——那会得到一份看着像、其实是假的数字。';
}

/// 成片台 summary 的完整性三件套。
///
/// `crash == 0` **不是**完整性证据：qa-batch 的成片台曾因路径被拼两次，
/// 87/100 静默 `continue`，而 `crash` 照样是 0、`ok` 照样是个好看的数字。
/// 判"跑完了"必须靠 `casesAttempted`/`missing`/`complete` 三件套；
/// 三者缺失即该项**不可判**，不得默认通过。
String _summaryCompleteness(Map<String, dynamic> inputs) {
  final Object? raw = inputs['composeSummary'];
  if (raw is! Map<String, dynamic>) {
    return '- 成片台 summary：**缺失**，`crash == 0` 无从谈起 → 完整性**不可判**。';
  }
  final Map<String, dynamic> s = raw;
  final bool hasTriple = s.containsKey('casesAttempted') &&
      s.containsKey('missing') &&
      s.containsKey('complete');
  final String head = '- 成片台 summary：`crash=${s['crash']}`、`cases=${s['cases']}`、'
      '`ok=${s['ok']}`、`mattingFail=${s['mattingFail']}`、`composeFail=${s['composeFail']}`、'
      '`noFace=${s['noFace']}`。';
  if (!hasTriple) {
    return '$head\n'
        '- **该 summary 缺 `casesAttempted`/`missing`/`complete` 三件套 → '
        '不能作为完整性证据**（`crash == 0` 本身不是证据：静默跳过的运行同样 crash 0）。'
        '本轮改由门禁**自己数条数**（见上一条），不依赖它。'
        '${s['cases'] != s['ok'] ? '另外 `cases=${s['cases']}` 与 `ok=${s['ok']}` 本身就对不上。' : ''}';
  }
  return '$head\n- 三件套齐备，本项可判。';
}

RunResult _gitSync(List<String> args) {
  try {
    final ProcessResult r = Process.runSync('git', args);
    return RunResult(
      ok: true,
      exitCode: r.exitCode,
      stdout: (r.stdout ?? '').toString(),
      stderr: (r.stderr ?? '').toString(),
      timedOut: false,
    );
  } catch (e) {
    return RunResult(
        ok: false, exitCode: -1, stdout: '', stderr: '$e', timedOut: false);
  }
}

/// 扫描区域的**逐区清单** —— 每轮原样打印，**含 0 与"根本没扫"**。
///
/// 存在理由：一份只写"命中 0"的扫描报告，读者分不清两件含义相反的事 ——
/// 「这个区域扫过、干干净净」与「这个区域根本没进扫描范围」。
/// 报告文本一模一样。本项目已经栽过三次同形状的坑：`lib` 域 29 vs 101、
/// `files` 计数相等而集合不同、扫描范围漏掉 `tools/gate`。
///
/// 所以这一节把三件事一起印出来：**扫了哪些区域**（逐区，不是一句"全部"）、
/// **每个族在每个区域各扫了多少个文件、命中多少**（0 也印）、
/// **哪些区域刻意没扫、理由是什么**。
String scanRootsMdSection(Map<String, dynamic>? ac) {
  if (ac == null) {
    return '防作弊巡检未产出 → **区域表无从核对**。'
        '注意：**没有区域表 ≠ 每个区域都扫了**。';
  }
  final Object? evRaw = ac['evidence'];
  if (evRaw is! Map<String, dynamic>) {
    return '巡检产出里没有 `evidence` → **区域表无从核对**（不默认"扫全了"）。';
  }
  final Map<String, dynamic> ev = evRaw;
  final List<dynamic> roots = ev['scan_roots'] as List<dynamic>? ?? <dynamic>[];
  final Map<String, dynamic> excluded =
      ((ev['scan_roots_excluded'] as Map?) ?? <String, dynamic>{})
          .cast<String, dynamic>();
  if (roots.isEmpty && excluded.isEmpty) {
    return '**区域表缺失** → 无法说出哪些区域进了扫描范围。'
        '**不默认"都扫了"** —— 这正是本节要防的那句话。';
  }

  /// 从 `族:区域` 的记录里取 `文件数/命中数`。
  String pair(Object? scans, String key) {
    if (scans is! Map<String, dynamic>) return '**无记录**';
    final Object? s = scans[key];
    if (s is! Map<String, dynamic>) return '**无记录**';
    final int files = (s['files_scanned'] as num?)?.toInt() ?? -1;
    final int hits = (s['hits'] as List<dynamic>? ?? <dynamic>[]).length;
    final bool und = s['undecidable'] == true;
    return '$files 个文件 / $hits 命中${und ? " / **判不了**" : ""}';
  }

  final StringBuffer b = StringBuffer();
  b.writeln('| 区域 | skip（条款 3） | 注释掉的断言（条款 3） | 空 catch（条款 5） |');
  b.writeln('|---|---|---|---|');
  for (final dynamic r in roots) {
    final String d = '$r';
    b.writeln('| `$d` | ${pair(ev['skip_scans'], 'skip:$d')} '
        '| ${pair(ev['commented_assertion_scans'], 'commented_assertion:$d')} '
        '| ${pair(ev['catch_scans'], 'catch:$d')} |');
  }
  b.writeln();
  b.writeln('**刻意不扫的区域（连同理由）** —— 「没扫」与「扫过、0 命中」'
      '在报告里长得一样，所以必须分开写：');
  if (excluded.isEmpty) {
    b.writeln('- （无：本轮声明的"不扫区域"为空表 —— 但这本身要能看见，'
        '空表也要打印）');
  } else {
    for (final String k in excluded.keys) {
      b.writeln('- `$k/`：${excluded[k]}');
    }
  }
  b.writeln();
  b.writeln('**三处扫描循环共用同一个常数 `kScanRoots`**'
      '（`tools/gate/anticheat.dart`）：三份列表只要有一次不同步，'
      '就会出现"条款 3 扫了某区域、条款 5 漏了它"这种没人会发现的覆盖缺口，'
      '而报告里两条都写着"命中 0"。');
  return b.toString();
}

/// AC 摘要里那句"skip/catch 命中多少"必须**从扫描结果推出来**，不能写死。
///
/// 原来这里硬编码"命中 0"——虽然它只在 `clean == true` 时才显示、显示出来时
/// 恰好为真，但它**不携带证据**：读者无法据它复核。现在从 `evidence` 里的
/// 逐目录扫描记录现算，并把"判不了"的目录一起报出来。
String _scanSummary(Map<String, dynamic> ac) {
  final Object? ev = ac['evidence'];
  if (ev is! Map<String, dynamic>) return '无扫描证据';
  final List<String> parts = <String>[];
  int countAll(Object? map) {
    if (map is! Map<String, dynamic>) return 0;
    int n = 0;
    for (final Object v in map.values) {
      if (v is List<dynamic>) n += v.length;
    }
    return n;
  }

  /// 逐族汇总：把"命中数"与"判不了"拆开数，命中数按**当前证据结构**取，
  /// 不再假设每个族只有 `hits` 一个键。
  List<String> badDirs(Object? scans) {
    if (scans is! Map<String, dynamic>) return <String>['无记录'];
    return scans.entries
        .where((MapEntry<String, dynamic> e) =>
            (e.value as Map<String, dynamic>)['undecidable'] == true)
        .map((MapEntry<String, dynamic> e) => e.key)
        .toList();
  }

  String tail(List<String> bad) =>
      bad.isEmpty || bad.first == '无记录' ? '' : '（**判不了：${bad.join("、")}**）';

  // 条款 3 只有 skip 款是"直接扫 + 可能判违规"；注释掉的断言另算；
  // 被放宽的阈值常量是结构性覆盖，**必须在摘要里露出来**，
  // 否则"条款 3 命中 0"会被读成"条款 3 已完整扫描"。
  final int skipHits = countAll(ev['skip_hits']);
  final List<String> skipBad = badDirs(ev['skip_scans']);
  final int skipSelf = countAll(ev['skip_hits_self_reference']);
  final int assertHits = countAll(ev['commented_assertion_hits']);
  final int assertSelf = countAll(ev['commented_assertion_hits_self_reference']);
  final List<String> assertBad = badDirs(ev['commented_assertion_scans']);
  parts.add('条款 3：skip 命中 $skipHits'
      '${skipSelf == 0 ? "" : "（其中 $skipSelf 条落在巡检自身领地，已登记不判违规）"}'
      '${tail(skipBad)}'
      '；注释掉的断言命中 $assertHits'
      '${assertSelf == 0 ? "" : "（其中 $assertSelf 条落在巡检自身领地）"}'
      '${tail(assertBad)}'
      '；**被放宽的阈值常量：无独立扫描器，靠基线 tag diff 结构性覆盖**'
      '（阈值只在 ACCEPTANCE.md 与 tools/gate/ 两处，分别受条款 1、条款 2 保护）');

  // 条款 5：空体与"带注释理由的吞"分开报，两类都必须露出来。
  final int bareHits = countAll(<String, dynamic>{'x': ev['empty_catch_hits']});
  final int commentedHits = countAll(<String, dynamic>{'x': ev['commented_catch_hits']});
  final List<String> catchBad = badDirs(ev['catch_scans']);
  final Object? defn = (ev['catch_scans'] as Map<String, dynamic>?)?['catch:lib'];
  parts.add('条款 5：空 catch 命中 $bareHits（无注释）\+ $commentedHits（体内只有注释）'
      '＝ **共 ${bareHits + commentedHits} 处，一律计违规**'
      '（主会话 2026-09-17 改口径：注释不该决定任何事 —— '
      '"加一句注释就降级"是一条能被扩写的洗白通道。让那几处清白的不是注释，'
      '是它们周围的代码，所以修法是改掉它们，不是给注释体开后门）'
      '${tail(catchBad)}'
      '${defn is Map<String, dynamic> ? "；判据定义：${defn['definition']}" : ""}');
  final List<dynamic> und = (ac['undecidable'] as List<dynamic>? ?? <dynamic>[]);
  if (und.isNotEmpty) {
    parts.add('**巡检自身不可判：${und.join("；")}**');
  }
  return parts.join('；');
}

String _crossCheck(Map<String, dynamic> inputs) {  final Map<String, dynamic> eyeline = inputs['eyeline'] as Map<String, dynamic>? ?? <String, dynamic>{};
  final Map<String, dynamic>? qa = inputs['qaResidual'] as Map<String, dynamic>?;
  if (qa == null) return 'qa-batch 的 out/P0_output_residual.json 不存在，无法交叉复核。';
  final Map<String, Map<String, dynamic>> mine = <String, Map<String, dynamic>>{};
  for (final dynamic r in (eyeline['rows'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> m = r as Map<String, dynamic>;
    mine[m['id'] as String] = m;
  }
  final List<double> diffs = <double>[];
  final Set<String> mineOver = <String>{};
  final Set<String> qaOver = <String>{};
  final Set<String> agreed = <String>{};
  for (final dynamic raw in (qa['items'] as List<dynamic>? ?? <dynamic>[])) {
    final Map<String, dynamic> q = raw as Map<String, dynamic>;
    if (q['specId'] != inputs['spec']) continue;
    final Map<String, dynamic>? m = mine[q['id']];
    final bool qaOk = q['primary_tilt_deg'] != null &&
        q['end_to_end_status'] != 'reliability_mismatch' &&
        q['end_to_end_status'] != 'unmeasured';
    if (m == null || m['ok'] != true || !qaOk) continue;
    final double a = (m['tilt_deg'] as num).toDouble();
    final double bb = (q['primary_tilt_deg'] as num).toDouble();
    diffs.add((a - bb).abs());
    if (a.abs() > kResidualMaxDeg) mineOver.add(q['id'] as String);
    if (bb.abs() > kResidualMaxDeg) qaOver.add(q['id'] as String);
    if (a.abs() <= kResidualMaxDeg && bb.abs() <= kResidualMaxDeg) agreed.add(q['id'] as String);
  }
  if (diffs.isEmpty) return '两条路径没有共同可测样本——无法交叉复核，判定标 MANUAL。';
  diffs.sort();
  final double med = diffs[diffs.length ~/ 2];
  final bool qaSubset = qaOver.difference(mineOver).isEmpty;
  // 第三台量具：SIFT 源图↔成片配准。它给出的是"管线实际转了多少度"，
  // 与眼线量具（直接测成片）独立，且对裁坏/打洞的成片免疫。
  final List<Map<String, dynamic>> samples = buildSamples(inputs);
  final List<double> siftDelta = samples
      .where((Map<String, dynamic> s) => s['sift_delta_vs_record'] != null)
      .map((Map<String, dynamic> s) => (s['sift_delta_vs_record'] as num).toDouble().abs())
      .toList();
  final Set<String> siftOver = samples
      .where((Map<String, dynamic> s) =>
          s['sift_ok'] == true && (s['residual'] as double).abs() > kResidualMaxDeg &&
          s['residualBy'] == 'gate_sift_align')
      .map((Map<String, dynamic> s) => s['id'] as String)
      .toSet();
  final String siftLine = siftDelta.isEmpty
      ? 'SIFT 路径：无可用读数。'
      : 'SIFT 路径：可配准 ${siftDelta.length} 条，'
          '实测施加角与生产记录 |差| 最大 ${siftDelta.reduce(math.max).toStringAsFixed(3)}°；'
          '它测出残余超 ${kResidualMaxDeg}° 的样本 ${siftOver.length} 条'
          '（${siftOver.join("、")}）——其中 c08_d-5 是另两台都量不出来的那条。';
  return '共同可测 ${diffs.length} 条：|差| 中位 ${med.toStringAsFixed(3)}°，最大 ${diffs.last.toStringAsFixed(3)}°。'
      '**原始读数** |成片倾角| > ${kResidualMaxDeg}° 的集合（不是违规计数，违规还要按条件覆盖率口径折算）：'
      'gatekeeper ${mineOver.length} 条 / qa-batch ${qaOver.length} 条，'
      'qa-batch 的集合${qaSubset ? "**是**" : "**不是**"} gatekeeper 的子集'
      '${qaSubset ? "——它报出的每一条超标本量具都独立复现" : "（存在分歧，见下表）"}；'
      '双方一致判定达标的 ${agreed.length} 条。'
      '两条路径的系统性差异约 ${med.toStringAsFixed(2)}°（不同方法：Haar 眼级联 vs YuNet 眼位+暗色圆盘+Radon 共识），'
      '小于判据容差 ${kResidualMaxDeg}° 的 1/3，足以互相印证，不足以单独定案——'
      '故凡两条路径读数相差 > 1° 的样本，判定一律回退到独立第三方证据（生产记录 + 已验证恒等式）。\n\n'
      '$siftLine';
}
