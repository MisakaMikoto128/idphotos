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

/// 被测代码范围：抠图 + 成像 + 契约。改动这三个之外的代码不影响本门禁读数。
const List<String> kMeasuredDirs = <String>['lib/core/matting', 'lib/core/imaging'];
const List<String> kMeasuredFiles = <String>['lib/core/api.dart'];

String gitText(List<String> args) {
  try {
    final r = Process.runSync('git', args);
    return (r.stdout as String).trim();
  } catch (_) {
    return 'unknown';
  }
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
/// 走到这里时 `gitText(['hash-object', ...])` 也早已失败，静默降级救不了任何东西。
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
/// 做法：逐个文件比对工作区 blob 与 `HEAD:<path>` 的 blob。全等 → 这份指纹
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
  final uncommitted = <String>[];
  for (final e in hashes.entries) {
    final atHead = _gitOrNull(<String>['rev-parse', 'HEAD:${e.key}']);
    if (atHead != e.value) uncommitted.add(e.key);
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
Map<String, Object?> codeFingerprint({String root = '.', List<String>? extraDirs}) {
  final dirs = <String>[...kMeasuredDirs, ...?extraDirs];
  final paths = <String>[];
  for (final dir in dirs) {
    final d = Directory(_join(root, dir));
    if (!d.existsSync()) continue;
    for (final e in d.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) paths.add(e.path);
    }
  }
  for (final f in kMeasuredFiles) {
    final p = _join(root, f);
    if (File(p).existsSync()) paths.add(p);
  }
  paths.sort();

  final hashes = <String, String>{};
  for (final p in paths) {
    hashes[_relKey(root, p)] = gitText(<String>['hash-object', p]);
  }
  final joined = hashes.entries.map((e) => '${e.key}:${e.value}').join('\n');
  var h = 0xcbf29ce484222325;
  for (final c in joined.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return <String, Object?>{
    'files': hashes.length,
    'fnv1a64': h.toRadixString(16).padLeft(16, '0'),
    'blobHashes': hashes,
    ...commitBinding(hashes),
  };
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
