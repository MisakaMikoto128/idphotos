/// 被测代码的**内容指纹**与「本轮数字是否有效」的判定。
///
/// 为什么不是只记 HEAD：P0 第 1 轮跑的时候 ml-porting 的估角改动还在工作区未提交，
/// 事后主会话又提交了若干 docs-only 的 commit。此时若只记 HEAD，会把数字错标到
/// 一个与测量无关的 commit 上（实测已发生：evaluatedState 从 b3518ba 漂到 5d4e89e）。
/// 按**文件内容**（git blob hash）记指纹：内容不变则指纹不变，与提交时序无关。
///
/// 为什么开跑/收尾各取一次：本文件测一轮要几分钟，期间若有人改了 lib/ 下的代码，
/// 只在收尾取指纹就会把"跑完之后"的状态记到"被测代码"头上 —— 与上面同一类事故。
/// 两次不一致即判定本轮数字**失效**，而不是默默贴个标签。
///
/// 抽成独立文件是为了让 `fingerprint_selftest.dart` 驱动**同一份实现**。
/// 自测若复制一份逻辑来测，测的就是复制品，不是真正在跑的那份。
library;

import 'dart:io';

/// 被测代码范围：**由门禁定义**（`tools/gate/`），不是本文件自定。
///
/// - `lib/` 下全部 `.dart`
/// - `test/batch/` 下全部 `.dart` 与 `.py`
/// - 排除路径里含 `__pycache__` 的
///
/// 域比原先的"只看 `lib/core/matting` + `lib/core/imaging` + `lib/core/api.dart`"
/// 宽是**故意的**：测量脚本本身也是"产出这些数的代码"。门禁的校验域里缺任何一条，
/// 该产物一律判 `undecidable`。
///
/// key = 仓库相对路径、正斜杠。两侧（Dart / Python）必须逐字节同域同序，
/// 否则会算出**不同的指纹**，在跨语言比较处表现为假漂移。
const List<String> kMeasuredRoots = <String>['lib', 'test/batch'];
const List<String> kMeasuredExts = <String>['.dart', '.py'];
const String kMeasuredExclude = '__pycache__';


/// 取 git 输出的**宽松**版本，失败时返回 `'unknown'`。
///
/// ⚠ **只可用于"叙述性"字段**（`gitHead`、`workingTreeDirty` 这类给人看的记录）。
/// **绝不可用它去算指纹** —— 见 [gitBlobHashStrict]：这些字符串一旦参与构成指纹，
/// git 失败会让**两个不同的代码状态产生同一个指纹**，而指纹相等正是"这份数出自
/// 当前代码"的唯一凭据。**两个瞎子互相作证。**
/// 另：`'unknown'` 与 `''`（干净）可区分，但**不得读成"没有改动"** —— 来源缺失不等于清白。
String gitText(List<String> args) {
  try {
    final r = Process.runSync('git', args);
    return (r.stdout as String).trim();
  } catch (_) {
    return 'unknown';
  }
}

/// `git hash-object` 的**严格批量**版本：一次进程取回全部 blob 哈希，
/// **返回值顺序与入参一一对应**。算不出来就抛，**绝不返回哨兵值**。
///
/// 为什么批量：被测集现在是 `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`
/// （约 100 个文件）。逐个 spawn 会让**每次**取指纹付约 100 次进程创建，而自测一轮
/// 要调十几次 —— 实测一轮 Dart 自测超过 5 分钟。批量后是 1 次。
///
/// 形式是 **argv 多路径**（`git hash-object f1 f2 …`），不是 `--stdin-paths`：
/// `Process.runSync` **没有 stdin 参数**（只有 async 的 `Process.start` 能写 stdin，
/// 而本文件的调用方全是同步的）。实测 `--stdin-paths` 还**不接受反斜杠路径**
/// （报 `could not open '.\lib\core\api.dart'`），argv 形式两种斜杠都行。
/// 按命令行长度分块，规避 Windows 约 32k 的 argv 上限。
///
/// 注意：**git 在有文件读不到时仍会为读得到的文件打印哈希**，只是 exit 非 0。
/// 所以"退出码 + 条数"两个条件必须**同时**查，只查其中一个会把部分失败读成成功。
///
/// 为什么必须抛而不是降级：指纹是由这些 blob 哈希拼出来的。若 git 失败时两边都
/// 得到同一个哨兵字符串（例如 `'unknown'`），那么**两份内容不同的代码会算出同一个
/// 指纹** —— 门禁据此断定"这份数出自当前代码"，而它实际什么都没证明。
/// 这比"算不出指纹"危险得多：**算不出会暴露，算成相同会静默通过。**
/// 门禁口径同此：`blobHashes` 出现 `''`/`'unknown'` 一律判 `undecidable`。
List<String> gitBlobHashesStrict(List<String> paths) {
  if (paths.isEmpty) return <String>[];
  final out = <String>[];
  const int kMaxArgvChars = 20000;
  var i = 0;
  while (i < paths.length) {
    final chunk = <String>[];
    var chars = 0;
    while (i < paths.length &&
        (chunk.isEmpty || chars + paths[i].length < kMaxArgvChars)) {
      chunk.add(paths[i]);
      chars += paths[i].length + 1;
      i++;
    }
    final r = Process.runSync('git', <String>['hash-object', ...chunk]);
    final lines = (r.stdout as String)
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    if (r.exitCode != 0 || lines.length != chunk.length) {
      throw StateError(
        'git hash-object 失败（exit ${r.exitCode}）：'
        '要 ${chunk.length} 个哈希，得到 ${lines.length} 个（本批首个路径 '
        '${chunk.first}）。\n'
        '被测代码指纹算不出来 ⇒ 本轮"这些数字出自哪份代码"无从判定。\n'
        '**不要**在这里退化成哨兵值：那会让两份算不出的指纹互相判等，\n'
        '把"无法自证"伪装成"已自证"。\n'
        'stderr: ${r.stderr}',
      );
    }
    out.addAll(lines);
  }
  return out;
}

/// 单文件版，走同一个批量实现（语义完全一致），供自测与零星调用。
String gitBlobHashStrict(String path) => gitBlobHashesStrict(<String>[path]).single;

/// `HEAD` 的整棵树：路径（正斜杠，仓库相对）→ blob。一次进程。
///
/// 逐文件用 `git rev-parse HEAD:<path>` 也要 ~100 次进程创建，与哈希那批同理。
/// 语义不变：**不在该提交里的文件**在 map 里查不到（返回 null），上层判为未提交。
Map<String, String> _headTreeBlobs() {
  final r = Process.runSync('git', <String>['ls-tree', '-r', 'HEAD']);
  if (r.exitCode != 0) {
    throw StateError('git ls-tree -r HEAD 失败（exit ${r.exitCode}）：${r.stderr}');
  }
  final m = <String, String>{};
  for (final String line in (r.stdout as String).split('\n')) {
    if (line.trim().isEmpty) continue;
    final int tab = line.indexOf('\t');
    if (tab < 0) continue;
    final String meta = line.substring(0, tab).trim();
    final String path = line.substring(tab + 1);
    final List<String> parts = meta.split(' ');
    if (parts.length < 3) continue;
    m[path] = parts.last;
  }
  return m;
}

/// 取 git 输出；git 正常跑完但非 0 退出时返回 null。
///
/// 与 [gitText] 的区别：后者把"命令非 0"和"起不了进程"都压成 `'unknown'`。
/// 而 `git rev-parse HEAD:<path>` 在"该文件不在这个提交里"时**预期内**地非 0 ——
/// 这正是 [commitBinding] 要识别的情形，压成 `'unknown'` 就分不出来了。
///
/// **刻意不包 try/catch。** 起不了 git 是环境故障，必须炸出来；若降级成 null，
/// 上层会报"取不到 HEAD"，**把所有指纹的提交绑定静默置空还附一句错误解释** ——
/// 这正是本项目反复记的那个形态（仪表看不见对象时说了"没有"）。
String? _gitOrNull(List<String> args) {
  final r = Process.runSync('git', args);
  if (r.exitCode != 0) return null;
  return (r.stdout as String).trim();
}

/// 把被测集**绑定到一个 commit**。
///
/// 为什么指纹本身不够：按内容记的指纹能回答"变了没有"，回答不了"**这是哪个版本的代码**"。
/// 工作区有未提交改动时，指纹描述的是一个**在历史里根本不存在的状态** ——
/// 实测：ml-porting 未提交的估角改动把 fnv 从 `5ba549780700fba9` 变成
/// `00a9fa55f822f55e`，后者在任何 commit 里都找不到。此时若下游只比 fnv，
/// 它会发现"不一致"，但说不出"测量时跑的是哪份代码"，也就无法判 `undecidable`。
///
/// 做法：比对工作区 blob 与 `HEAD` 那棵树里的 blob。全等 → 这份指纹
/// **就是** `headCommit` 的代码；有差异 → 列出具体哪些文件没有对应提交。
///
/// 刻意**不改**参与 FNV 的字符串：改了会让本次改动前后记录的 `fnv1a64` 不可比，
/// 把一次纯溯源增强变成一次假漂移。绑定信息一律作为**兄弟字段**携带。
Map<String, Object?> commitBinding(Map<String, String> hashes) {
  final head = _gitOrNull(<String>['rev-parse', 'HEAD']);
  if (head == null || head.isEmpty) {
    // git 正常跑完（exit 0）却给不出 HEAD 才会走到这里（空仓库等）。
    // 起不了 git 由 `_gitOrNull` 直接抛，不降级成本分支。
    return <String, Object?>{
      'headCommit': null,
      'allCommitted': null,
      'uncommittedMeasuredFiles': <String>[],
      'commitBindingNote': 'git 正常退出但给不出 HEAD，无法绑定提交。',
    };
  }
  final tree = _headTreeBlobs();
  final uncommitted = <String>[];
  for (final e in hashes.entries) {
    if (tree[e.key] != e.value) uncommitted.add(e.key);
  }
  uncommitted.sort();
  return <String, Object?>{
    'headCommit': head,
    'allCommitted': uncommitted.isEmpty,
    'uncommittedMeasuredFiles': uncommitted,
    'commitBindingNote': uncommitted.isEmpty
        ? '被测集全部文件与该提交一致：本指纹即 $head 的代码。'
        : '被测集有 ${uncommitted.length} 个文件与 $head 不一致：'
              '本指纹描述的**不是任何提交**，只可用于内容比对。',
  };
}

String _join(String root, String rel) {
  final sep = Platform.pathSeparator;
  final base = root.endsWith(sep) || root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  return '$base$sep${rel.replaceAll('/', sep)}';
}

String _relKey(String root, String full) {
  final f = full.replaceAll('\\', '/');
  final b = root.replaceAll('\\', '/').replaceAll(RegExp(r'/$'), '');
  if (b == '.' || b.isEmpty) return f.replaceAll(RegExp(r'^\./'), '');
  return f.startsWith('$b/') ? f.substring(b.length + 1) : f;
}

/// [root] 下的被测代码内容指纹。默认 root='.'（仓库根）。
/// 传别的 root 是为了让自测能在沙箱副本上跑同一份实现。
///
/// [gitHashes] 只在自测里注入，用来**模拟 git 不可用**，从而证明"算不出指纹"时不会
/// 退化成"两份指纹相等"。生产调用一律走默认的 [gitBlobHashesStrict]。
///
/// ⚠ **排序用的是规范键（仓库相对、正斜杠），不是 `e.path`。** 这两者今天同序是
/// **运气**：`/`(0x2F) 与 `\`(0x5C) 相对字母的大小关系**相反**，所以
/// `lib/ui/x.dart` 与 `lib/uiA.dart` 在两种键下的先后**正好翻转** ——
/// 一旦域里出现"目录名是另一文件名前缀"的组合，拼接串不同 ⇒ FNV 不同 ⇒
/// 与 `code_fingerprint.py`（同口径）以及门禁（排正斜杠相对路径）**跨实现误判**。
/// 同 `toRadixString(16)` 那条一样，**当前值恰好落在两种写法一致的区间**，
/// 所以它不会自己暴露。第 8 段自测专门造了这对形状把它钉住。
Map<String, Object?> codeFingerprint({
  String root = '.',
  List<String> Function(List<String> paths) gitHashes = gitBlobHashesStrict,
}) {
  // 先算规范键，**再按规范键排序**；绝对路径只是取哈希时要用的入参，
  // 它带着 OS 分隔符，**不参与定序、也不进 joined**。
  final relToAbs = <String, String>{};
  for (final dir in kMeasuredRoots) {
    final d = Directory(_join(root, dir));
    if (!d.existsSync()) continue;
    for (final e in d.listSync(recursive: true)) {
      if (e is! File) continue;
      final norm = e.path.replaceAll('\\', '/');
      if (norm.contains(kMeasuredExclude)) continue;
      if (!kMeasuredExts.any(norm.endsWith)) continue;
      final String rel = _relKey(root, e.path);
      if (relToAbs.containsKey(rel)) {
        // 同一个规范键对应两个物理文件 ⇒ 无论选哪个都会**静默**丢掉一条，
        // 而"少记一个文件 = 那个文件改了也不响"。宁可炸。
        throw StateError('规范键重复：$rel 同时对应 ${relToAbs[rel]} 与 ${e.path}');
      }
      relToAbs[rel] = e.path;
    }
  }
  final rels = relToAbs.keys.toList()..sort();
  final paths = rels.map((String r) => relToAbs[r]!).toList();

  final blobs = gitHashes(paths);
  if (blobs.length != paths.length) {
    throw StateError('gitHashes 返回 ${blobs.length} 个哈希，但有 ${paths.length} 个文件；'
        '数目对不上时按序配对会**静默错位**，故直接判失败。');
  }
  final hashes = <String, String>{};
  for (var i = 0; i < paths.length; i++) {
    hashes[rels[i]] = blobs[i];
  }
  final joined = hashes.entries.map((e) => '${e.key}:${e.value}').join('\n');
  return <String, Object?>{
    'files': hashes.length,
    'fnv1a64': fnv1a64Hex(joined),
    'blobHashes': hashes,
    ...commitBinding(hashes),
  };
}

/// FNV-1a 64 的十六进制，**无符号、16 字符小写**。抽出来是为了让它能被
/// **公开测试向量**钉住（见 `fingerprint_selftest.dart` 第 7 段）——那是独立于
/// 本仓库两个实现之外的权威，比"Dart 与 Python 互相比对"硬（后者只证明两边抄得一样）。
///
/// 为什么格式化要绕 BigInt：Dart 的 int 是**有符号** 64 位，乘法溢出按补码回绕 ——
/// 这正好等价于无符号 64 位回绕，所以循环里**不需要**也没法再用一个掩码
/// （`& 0xFFFFFFFFFFFFFFFF` 在 Dart 里就是个 `-1`，是**空操作**；曾经那么写，
/// 看着像在维持无符号语义，其实什么都没做）。
/// 但**输出**必须显式转无符号：`h` 为负时 `toRadixString(16)` 给出**带负号的
/// 17 字符**（如 `-2f828fcfb4faf34e`），而 Python 侧 `format(h, "016x")` 给的是
/// 无符号 16 字符（如 `d07d70304b050cb2`）。同一哈希的两种写法，**约一半的输入
/// 会对不上**；而 `_measured_state()` 正是拿 Dart 写的指纹与 Python 现算的指纹做
/// **跨语言**比较，会在 ~50% 的代码状态下误报 `undecidable`，白烧一轮。
/// （`int.toUnsigned(64)` 不管用，实测原样返回负数。）
///
/// ⚠ 已知边界（**登记未改**，非 ASCII 路径才触发）：这里按 UTF-16 `codeUnits`
/// 迭代，Python 侧按 UTF-8 字节迭代。本仓库被测集路径全为 ASCII，两者一致；
/// 若将来 `lib/` 下出现非 ASCII 文件名的 `.dart`，两侧会算出不同的指纹。
String fnv1a64Hex(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h ^= c;
    h = h * 0x100000001b3;
  }
  return BigInt.from(h).toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// 比较开跑/收尾两次指纹，给出本轮是否有效。
/// 除了一致性，还列出**具体变了哪些文件** —— 只报 true/false 无法排查。
Map<String, Object?> roundVerdict(
  Map<String, Object?> start,
  Map<String, Object?> end,
) {
  final a = (start['blobHashes'] as Map).cast<String, String>();
  final b = (end['blobHashes'] as Map).cast<String, String>();
  final changed = <String>[];
  for (final k in {...a.keys, ...b.keys}) {
    if (a[k] != b[k]) changed.add(k);
  }
  changed.sort();
  final stable = start['fnv1a64'] == end['fnv1a64'];
  return <String, Object?>{
    'codeStableDuringRun': stable,
    'roundValid': stable,
    'changedFiles': changed,
    'verdict': stable
        ? '有效：被测代码在开跑到收尾之间未变，本读数可钉到该指纹。'
        : '**失效**：跑的过程中被测代码被改过（见 changedFiles），'
              '本读数不属于任何一个稳定的代码版本，不得用作门禁判据。',
  };
}
