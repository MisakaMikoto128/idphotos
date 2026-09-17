/// `code_fingerprint.dart` 的自测。
///
///   dart run test/batch/fingerprint_selftest.dart
///
/// 存在的理由：指纹机制有个软肋 —— 它只有在**真的会翻**的时候才算数。
/// 一个永远返回"两次相同"的实现，看起来完全正常，却会把"跑到一半代码被改"
/// 的轮次标成有效。所以必须有正例：**开跑后改文件 → 必须报失效**。
///
/// 本自测驱动 `code_fingerprint.dart` 的同一份实现（不是复制品），
/// 但把 root 指向 `out/P0_selftest_tmp/` 下的副本 —— 绝不修改真实 `lib/`。
library;

import 'dart:io';

import 'code_fingerprint.dart';

const String kSandbox = 'out/P0_selftest_tmp/repo';
const String kIncidentFile = 'lib/core/matting/iris_roll.dart';

int _fail = 0;

void _check(String name, bool ok, [String detail = '']) {
  stdout.writeln('${ok ? '  ok  ' : ' FAIL '} $name${detail.isEmpty ? '' : '  -- $detail'}');
  if (!ok) _fail++;
}

void _copyTree(String srcRoot, String dstRoot, Iterable<String> rels) {
  for (final rel in rels) {
    final dst = File('${dstRoot.replaceAll('/', Platform.pathSeparator)}'
        '${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(File('${srcRoot.replaceAll('/', Platform.pathSeparator)}'
            '${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}')
        .readAsBytesSync());
  }
}

Future<void> main() async {
  stdout.writeln('== code_fingerprint 自测 ==\n');

  final sandbox = Directory(kSandbox);
  if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  sandbox.createSync(recursive: true);

  // --- 0. 真实仓库的基准指纹，自测前后都取一次，用于证明"没碰真实 lib/" ---
  final realBefore = codeFingerprint();
  final realFiles = (realBefore['blobHashes'] as Map).keys.cast<String>().toList();
  stdout.writeln('[0] 真实仓库被测集: ${realBefore['files']} 文件, fnv=${realBefore['fnv1a64']}');
  _check('被测集覆盖事故文件 $kIncidentFile', realFiles.contains(kIncidentFile));
  _check('被测集非空且包含 api.dart', realFiles.contains('lib/core/api.dart'));

  // --- 1. 沙箱副本必须与真实仓库逐字节一致（证明后面测的是同一批内容）---
  _copyTree('.', kSandbox, realFiles);
  final sandCopy = codeFingerprint(root: kSandbox);
  _check('沙箱副本指纹 == 真实仓库指纹（逐文件 blob 一致）',
      sandCopy['fnv1a64'] == realBefore['fnv1a64'],
      'sand=${sandCopy['fnv1a64']} real=${realBefore['fnv1a64']}');

  // --- 2. 反例对照：跑一轮**不改**任何文件 → 必须报"有效" ---
  //     没有这条，第 3 条"报失效"就可能是实现永远报失效。
  final cStart = codeFingerprint(root: kSandbox);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final cEnd = codeFingerprint(root: kSandbox);
  final cVerdict = roundVerdict(cStart, cEnd);
  _check('对照：不改文件 → codeStableDuringRun=true',
      cVerdict['codeStableDuringRun'] == true);
  _check('对照：不改文件 → roundValid=true', cVerdict['roundValid'] == true);
  _check('对照：不改文件 → changedFiles 为空',
      (cVerdict['changedFiles'] as List).isEmpty);
  _check('对照：判定文案含"有效"', '${cVerdict['verdict']}'.contains('有效'));

  // --- 3. 正例（本次要验的那条）：开跑后改文件 → 必须报**失效** ---
  //     严格照被测场景的时序：先取开跑指纹 → 时间流逝 → 期间改文件 → 收尾指纹。
  final pStart = codeFingerprint(root: kSandbox);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final incident = File('$kSandbox\\${kIncidentFile.replaceAll('/', Platform.pathSeparator)}');
  incident.writeAsStringSync(
      '${incident.readAsStringSync()}\n// 自测注入：模拟开跑后有人改了估角代码\n');
  final pEnd = codeFingerprint(root: kSandbox);
  final pVerdict = roundVerdict(pStart, pEnd);

  _check('正例：开跑后改文件 → codeStableDuringRun=false',
      pVerdict['codeStableDuringRun'] == false);
  _check('正例：开跑后改文件 → roundValid=false', pVerdict['roundValid'] == false);
  _check('正例：能指认具体是哪个文件变了',
      (pVerdict['changedFiles'] as List).length == 1 &&
          (pVerdict['changedFiles'] as List).first == kIncidentFile,
      '${pVerdict['changedFiles']}');
  _check('正例：判定文案含"失效"', '${pVerdict['verdict']}'.contains('失效'));
  _check('正例：文案点名了变更文件',
      '${pVerdict['verdict']}'.contains('changedFiles'));

  // --- 4. 灵敏度下界：只加一个字节也要翻 ---
  final wBefore = codeFingerprint(root: kSandbox);
  final wFile = File('$kSandbox\\${kIncidentFile.replaceAll('/', Platform.pathSeparator)}');
  final bytes = wFile.readAsBytesSync().toList();
  bytes.add(10); // 单个换行字节
  wFile.writeAsBytesSync(bytes);
  final wAfter = codeFingerprint(root: kSandbox);
  _check('灵敏度：仅多 1 字节也必须改变指纹',
      roundVerdict(wBefore, wAfter)['codeStableDuringRun'] == false);

  // --- 5. 刻意不翻的情形：只改 mtime、不动内容 → **不应**判失效 ---
  //     指纹按内容记，不是按修改时间。这条防的是"误报失效"把好轮次废掉。
  final tBefore = codeFingerprint(root: kSandbox);
  wFile.setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
  final tAfter = codeFingerprint(root: kSandbox);
  _check('不误报：只 touch 不改内容 → 仍判有效',
      roundVerdict(tBefore, tAfter)['codeStableDuringRun'] == true);

  // --- 6. 没碰真实 lib/ ---
  final realAfter = codeFingerprint();
  _check('真实仓库被测集自测前后未变（自测未污染 lib/）',
      realAfter['fnv1a64'] == realBefore['fnv1a64'],
      'before=${realBefore['fnv1a64']} after=${realAfter['fnv1a64']}');

  sandbox.deleteSync(recursive: true);
  stdout.writeln('\n${_fail == 0 ? 'FINGERPRINT SELFTEST PASS' : 'FINGERPRINT SELFTEST FAIL ($_fail)'}');
  exit(_fail == 0 ? 0 : 1);
}
