/// 跑 `dev_selfcheck`（P0.5a 的输入）并**给它钉上代码指纹**。
///
///   dart run test/batch/p0_selfcheck_run.dart
///
/// 为什么需要这个：r1 的判决是**拼起来的**——P0.1a/2/3a/3b 来自当时那份工作树产出的
/// `out/P0_compose_items.jsonl`，而 P0.5a 由 gatekeeper 用**本机当前**工作树编译的
/// `dev_selfcheck` 跑出来。两半来自不同的代码状态，所以 r1 **不是一个对任何单一代码
/// 状态的判决**。
///
/// r2 起执行的新规则：**一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来。**
/// 本文件就是这条规则在 `dev_selfcheck` 这条路径上的落点：开跑/收尾各取一次指纹，
/// 并**与成片台的指纹交叉比对** —— 不一致就直接写明"这两半不是同一版"。
///
/// 判定口径与 `tools/gate/gate_P0.dart` 的 P0.5a 保持一字不差（退出码 0 且 通过 ≥ 9、
/// 失败 = 0），这样本文件的结论可以与该门禁项直接对照。
library;

import 'dart:convert';
import 'dart:io';

import 'code_fingerprint.dart';

const String kSelfcheck = 'lib/core/imaging/dev_selfcheck.dart';

/// 读一个 JSON 对象，**区分"不存在"与"读不出"**。
///
/// 返回 `(status, value, detail)`，status ∈ `{ok, missing, unreadable}`。
///
/// 为什么不写成 `?? <String, Object?>{}`：调用方会据此写下**具体的原因**。
/// 原先两者都返回空对象，于是**文件损坏/读不了**时也照样报
/// "那份成片是本机制加入之前跑的" —— 那句话是编的。而那个空对象长得像一个
/// **合法的空结果**，没有任何一处会报错。
/// **一个哨兵值最危险的时候，就是它长得像一个合法的空结果。**
({String status, Map<String, Object?>? value, String? detail}) _readJson(String p) {
  final f = File(p);
  if (!f.existsSync()) {
    return (status: 'missing', value: null, detail: null);
  }
  try {
    final v = jsonDecode(f.readAsStringSync());
    if (v is! Map<String, Object?>) {
      return (status: 'unreadable', value: null,
          detail: 'JSON 顶层不是对象，而是 ${v.runtimeType}');
    }
    return (status: 'ok', value: v, detail: null);
  } catch (e) {
    return (status: 'unreadable', value: null, detail: '$e');
  }
}

void main(List<String> args) {
  final dryRun = args.contains('--dry-run') ||
      (Platform.environment['P0_SELFCHECK_DRYRUN'] == '1');
  final fpStart = codeFingerprint();

  int exitCode;
  String tail;
  if (dryRun) {
    // 自检用：不真的跑 flutter test（在被测代码改到一半时编译它会得到假失败），
    // 只喂一段与真实 gate 尾部同形的文本，验证解析 / 交叉比对 / 落盘这几段。
    exitCode = 0;
    tail = '00:12 +9: All tests passed!';
    stdout.writeln('[dry-run] 跳过 flutter test，用合成尾部验证解析路径');
  } else {
    stdout.writeln('跑 $kSelfcheck ...');
    final r = Process.runSync(
      'flutter',
      <String>['test', kSelfcheck],
      runInShell: true,
    );
    final out = '${r.stdout}\n${r.stderr}';
    exitCode = r.exitCode;
    tail = out.length > 2500 ? out.substring(out.length - 2500) : out;
  }

  // 与 gate_P0.dart 的 P0.5a 同一套解析口径。
  final re = RegExp(r'\+(\d+)(?:\s*-(\d+))?');
  final ms = re.allMatches(tail);
  final last = ms.isEmpty ? null : ms.last;
  final passedN = last == null ? -1 : int.parse(last.group(1)!);
  final failedN = last?.group(2) == null ? 0 : int.parse(last!.group(2)!);
  final pass = exitCode == 0 && passedN >= 9 && failedN == 0;

  final fpEnd = codeFingerprint();
  final verdict = roundVerdict(fpStart, fpEnd);

  // 与成片台交叉比对：这是 r1 出问题的那一刀。
  final compose = _readJson('out/P0_compose_summary.json');
  final cProv =
      (compose.value?['provenance'] as Map?)?.cast<String, Object?>() ?? {};
  final cFp = (cProv['codeFingerprint'] as Map?)?.cast<String, Object?>();
  final cFn = cFp?['fnv1a64'];
  final myFn = fpStart['fnv1a64'];
  String sameState;
  bool? same;
  if (cFn == null) {
    same = null;
    // 三种情况必须分开说。原先"文件不存在"与"解码失败"都走同一句
    // "那份成片是本机制加入之前跑的" —— 文件坏掉时那句话是编的。
    switch (compose.status) {
      case 'missing':
        sameState = '**无法比对**：`out/P0_compose_summary.json` **不存在**。'
            '该文件由成片台产出；缺它说明成片台没跑或产物被清掉了，'
            '**不是**"成片跑在旧代码上"。';
      case 'unreadable':
        sameState = '**无法比对**：`out/P0_compose_summary.json` '
            '**存在但读不出**（${compose.detail}）。'
            '文件损坏与"本机制加入之前跑的产物"是两回事，'
            '**不得**按后者解释，必须先修好读入再判。';
      default:
        sameState = '**无法比对**：文件读到了，但没有 `provenance.codeFingerprint`'
            '（那份成片是本机制加入之前跑的）。'
            '这一点本身就是 r1「两半不同版」的成因。';
    }
  } else if (cFn == myFn) {
    same = true;
    sameState = '一致：dev_selfcheck 与成片台跑在**同一份被测代码内容**上，'
        '本轮判决的两半可以拼。';
  } else {
    same = false;
    sameState = '**不一致**：dev_selfcheck 与成片台来自**不同**的代码内容'
        '（成片=$cFn，本次=$myFn）。按 r2 起的新规则，这两半**不得**拼进同一份判决——'
        '必须重测其中一半。';
  }

  final rec = <String, Object?>{
    'generatedBy': 'qa-batch test/batch/p0_selfcheck_run.dart',
    'target': kSelfcheck,
    'command': 'flutter test $kSelfcheck',
    'dryRun': dryRun,
    'exitCode': exitCode,
    'passed': passedN,
    'failed': failedN,
    'pass': pass,
    'criterion': '与 tools/gate/gate_P0.dart 的 P0.5a 同口径：退出码 0 且 通过 ≥ 9、失败 = 0',
    'tail': tail,
    'codeFingerprint': fpStart,
    'codeFingerprintAtEnd': fpEnd,
    ...verdict,
    'composeFingerprint': cFn,
    'composeSummaryRead': compose.status,
    'composeSummaryReadDetail': compose.detail,
    'sameCodeStateAsCompose': same,
    'sameCodeStateNote': sameState,
    'gitHead': gitText(<String>['rev-parse', '--short', 'HEAD']),
    'workingTreeDirty': gitText(<String>['status', '--porcelain'])
        .replaceAll('\n', ' | '),
  };

  final outPath = dryRun
      ? 'out/P0_selfcheck_provenance.dryrun.json'
      : 'out/P0_selfcheck_provenance.json';
  File(outPath)
      .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(rec));
  stdout.writeln('写了 $outPath');

  stdout.writeln('退出码=$exitCode 通过=$passedN 失败=$failedN pass=$pass');
  stdout.writeln('指纹 ${fpStart['fnv1a64']}（开跑）-> ${fpEnd['fnv1a64']}（收尾）');
  stdout.writeln('roundVerdict: ${verdict['verdict']}');
  stdout.writeln('sameCodeStateAsCompose: $same  $sameState');
  exit(pass && verdict['roundValid'] == true ? 0 : 1);
}
