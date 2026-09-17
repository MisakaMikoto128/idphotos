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

  // --- 6. git 不可用 → 指纹必须**不可比**，绝不能"两份都算不出 ⇒ 判等" ---
  //     这是本文件里唯一一条直接对着"门禁会据此放行"的检查。指纹相等是
  //     "这些数字出自当前代码"的**唯一凭据**；若哨兵值能让两份内容不同的代码
  //     算出同一个指纹，这个凭据就是假的，而且**静默通过**（算不出会暴露，
  //     算成相同不会）。所以既验"真实现抛错"，也把"哨兵会怎样伪造相等"演一遍。
  Object? strictErr;
  try {
    gitBlobHashStrict('$kSandbox/绝对不存在的路径.dart');
  } catch (e) {
    strictErr = e;
  }
  _check('6a 真实现：hash-object 算不出 → 抛错，不返回任何哨兵值', strictErr != null,
      '${strictErr.runtimeType}');

  List<String> sentinelHashes(List<String> paths) =>
      paths.map((String _) => 'unknown').toList();
  final realPre = codeFingerprint(root: kSandbox);
  final sentPre = codeFingerprint(root: kSandbox, gitHashes: sentinelHashes);
  wFile.writeAsStringSync(
      '${wFile.readAsStringSync()}\n// 第 6 段：制造一次真实的内容变化\n');
  final realPost = codeFingerprint(root: kSandbox);
  final sentPost = codeFingerprint(root: kSandbox, gitHashes: sentinelHashes);

  // 前提：这两次的内容**确实不同**，否则下面那条负向对照是空转的。
  _check('6b 对照前提：这两次内容确实不同（真实指纹翻了）',
      realPre['fnv1a64'] != realPost['fnv1a64']);
  // 负向对照：同样的两次，只把哈希换成"永远返回哨兵"，指纹立刻**相等** ——
  // 这就是"两个瞎子互相作证"的具体形态。
  _check('6c 负向对照：注入哨兵 → 内容不同的两次得到**同一指纹**',
      sentPre['fnv1a64'] == sentPost['fnv1a64'],
      'sent=${sentPre['fnv1a64']}');
  // 而且这个伪造出来的指纹**长得完全正常**，看不出来历无效 —— 这才是它的危险之处。
  _check('6d 伪造的指纹是个"合法"字符串（看不出来历无效）',
      RegExp(r'^[0-9a-f]{16}$').hasMatch('${sentPre['fnv1a64']}'));

  // --- 7. 算法本身对公开测试向量 ---
  //     为什么不能用"Dart 与 Python 互相比对"代替：那只能证明两边**抄得一样**，
  //     共用同一个错误时照样自洽（本项目已记过这个形态）。公开向量是**独立于本仓库
  //     两个实现之外**的权威，才叫验证。
  //     `'b'` 那条是专门选的：它的哈希最高位为 1，正是旧实现给出带负号 17 字符
  //     （`-509c20b379fe0e5b`）的情形；没有它，这条测试全是正数、钉不住格式。
  const Map<String, String> vectors = <String, String>{
    '': 'cbf29ce484222325',
    'a': 'af63dc4c8601ec8c',
    'foobar': '85944171f73967e8',
    'b': 'af63df4c8601f1a5',
  };
  for (final e in vectors.entries) {
    final got = fnv1a64Hex(e.key);
    _check('7 FNV-1a 64 公开向量 ${e.key.isEmpty ? '(空串)' : '"${e.key}"'}',
        got == e.value, got == e.value ? '' : 'got=$got want=${e.value}');
  }

  // 这里原先还有一段（已删除，与上面的 6 段无关）「6. 没碰真实 lib/」——比较自测前后
  // **真实仓库**的内容指纹。
  // 已删除：它**声明的**是"这个自测没污染 lib/"，**实际测的**却是"整个自测期间
  // 真实 lib/ 对任何人都没变"。两者不等价，它分不清"我写的"和"别人写的"，
  // 于是会因并发的编辑器红、并因编辑器停下而自行转绿 —— 同一命令两次结果不同。
  //
  // 更坏的是它**恰在门禁轮次期间必红**（那时只要有人碰 lib/ 就触发），而那种情况
  // 本轮数字**早已被运行自身的开跑/收尾指纹判为无效**（roundValid=false），
  // 所以这个红是冗余的，只会教人学会"这条红不用管" ——
  // **假红是假绿的镜像，净效果相同：信号不再携带信息。**
  //
  // 而它对自己声称的那件事**一点覆盖率都没增加**：自测的隔离性由构造保证
  // （所有写操作都走 kSandbox 下的路径），且第 1 段已证明沙箱是真实仓库的
  // 逐字节忠实副本。**运行时的作废判定归 roundVerdict，不归对实现的自测。**

  sandbox.deleteSync(recursive: true);
  stdout.writeln('\n${_fail == 0 ? 'FINGERPRINT SELFTEST PASS' : 'FINGERPRINT SELFTEST FAIL ($_fail)'}');
  exit(_fail == 0 ? 0 : 1);
}
