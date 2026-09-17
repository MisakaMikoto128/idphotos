// tools/gate/anticheat.dart
//
// 防作弊巡查（ACCEPTANCE.md「防作弊条款」1/3/4/5/6 条的可执行化）。
// 属 gatekeeper 势力范围。任何其他 agent 不应修改本文件。
//
// 第 2 条（gate 脚本 SHA256）因为要跟"上一轮 gatekeeper 自己的记录"比对，
// 放在 gate_P0.dart 里做，不在这里。
//
// 设计原则：**零命中 = 清白**；一旦命中就带文件和责任 agent 名字，
// 不许出现"疑似/可能"这种糊弄措辞，也不许把找不到证据当成没发生。

import 'dart:io';

import 'gate_common.dart';

/// 单条越界变更。
class Violation {
  final String clause;
  final String path;
  final String attribution;
  final String detail;

  Violation(this.clause, this.path, this.attribution, this.detail);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'clause': clause,
        'path': path,
        'attribution': attribution,
        'detail': detail,
      };

  @override
  String toString() => '[$clause] $path ← $attribution：$detail';
}

/// commit subject 前缀 → 责任 agent（角色表见 CLAUDE.md §9）。
///
/// git author 全部是同一个本机账号，**没法靠 %an 归属**，只能靠提交信息前缀。
/// 前缀认不出来时如实写"未知"，不硬猜。
const Map<String, String> kSubjectPrefixOwner = <String, String>{
  'matting': 'ml-porting',
  'ml': 'ml-porting',
  // 全名别名：团队实际写提交信息用的是全名（如 `ml-porting: 瞳孔级眼线估计…`），
  // 少了这几条，真实的提交会被归属成"未知"。归属错了不会漏判
  // （isForbiddenFor 对未知归属**一律从严**），但报告会点名不到人，
  // 而回派指令的价值全在"点名到谁"。
  'ml-porting': 'ml-porting',
  'imaging': 'imaging',
  'ui': 'ui-woodcraft',
  'ui-woodcraft': 'ui-woodcraft',
  'release': 'release',
  'store': 'store-assets',
  'store-assets': 'store-assets',
  'env': 'env-setup',
  'env-setup': 'env-setup',
  'contract': '主会话',
  'gate': 'gatekeeper',
  'gatekeeper': 'gatekeeper',
  'qa': 'qa-batch',
  'qa-batch': 'qa-batch',
  'adversarial': 'adversarial',
  'visual': 'visual-critic',
  'visual-critic': 'visual-critic',
};

String ownerOfSubject(String subject) {
  final int i = subject.indexOf(':');
  if (i < 0) return '未知（提交信息无前缀：$subject）';
  final String prefix = subject.substring(0, i).trim().toLowerCase();
  return kSubjectPrefixOwner[prefix] ?? '未知（前缀 `$prefix` 不在角色表）';
}

/// 实现类 agent 一律不许碰的路径。`test/gate/` 是 gatekeeper 自己的，不在其中。
///
/// [owner] 是变更的归属（commit 前缀映射出来的 agent 名）。裁判类 agent
/// （qa-batch / adversarial / gatekeeper）在自己的 test 子领地里写入是合法的，
/// 不能一刀切 —— 误报会把别人的正常工作判成作弊，和漏报一样有害。
bool isForbiddenFor(String path, String owner) {
  final String p = path.replaceAll('\\', '/');
  if (p == 'docs/ACCEPTANCE.md' || p == 'docs/RUBRIC.md') return true;
  if (p.startsWith('tools/gate/')) return owner != 'gatekeeper';
  if (p.startsWith('test/gate/')) return owner != 'gatekeeper';
  if (p.startsWith('test/')) {
    if (owner == 'qa-batch' &&
        (p.startsWith('test/batch/') ||
            p.startsWith('test/golden/') ||
            p == 'test/dataset.json')) {
      return false;
    }
    if (owner == 'adversarial' && p.startsWith('test/adversarial/')) return false;
    if (owner == 'gatekeeper') return false;
    return true;
  }
  return false;
}

/// 未提交（工作区）改动里，**只有这些路径**对任何 agent 都无条件可疑 ——
/// 它们是"考卷"与"监考工具"，除了 gatekeeper 谁都不该动。
bool isUniversallyProtected(String path) {
  final String p = path.replaceAll('\\', '/');
  return p == 'docs/ACCEPTANCE.md' ||
      p == 'docs/RUBRIC.md' ||
      p.startsWith('tools/gate/') ||
      p.startsWith('test/gate/');
}

/// 归属未提交改动：git 说不了是谁写的，只能靠历史提示 + 如实标注。
///
/// 绝不硬猜一个 agent 名字按在别人头上：猜错的代价是冤枉一个没做错事的 agent，
/// 比"未定位"差得多。
String attributeWorktree(String path) {
  final ProcessResult r = Process.runSync(
    'git',
    <String>['log', '-1', '--format=%s', '--', path],
    runInShell: true,
  );
  if (r.exitCode == 0) {
    final String s = (r.stdout as String).trim();
    if (s.isNotEmpty) {
      return '未提交（该文件最近一次提交：${ownerOfSubject(s)}「${s.split('\n').first}」）';
    }
  }
  return '未提交（新文件，git 无历史，待认领）';
}

/// git 子进程的一次调用（失败不抛，交给调用方映射为 FAIL）。
Future<RunResult> git(List<String> args) =>
    runProcess('git', args, timeout: const Duration(seconds: 60));

/// 完整巡查。
///
/// [baseline] 阶段基线 tag；[prevHashes] 上一轮 gatekeeper 记录的脚本哈希；
/// [selfTouched] gatekeeper 本轮**自报**改动的路径（豁免条款 1/2，且会在报告里
/// 逐条列出来接受复核——自报清单本身是可审计的，偷偷改才是作弊）。
Future<Map<String, dynamic>> patrol({
  required String baseline,
  required Map<String, String> currentHashes,
  Map<String, String>? prevHashes,
  required int goldenSrcCount,
  required int goldenRefCount,
  int? prevGoldenSrcCount,
  int? prevGoldenRefCount,
  Set<String> selfTouched = const <String>{},
}) async {
  final List<Violation> violations = <Violation>[];
  final Map<String, dynamic> evidence = <String, dynamic>{};
  final Set<String> self = selfTouched
      .map((String p) => p.replaceAll('\\', '/'))
      .toSet();
  evidence['gatekeeper_self_touched'] = self.toList()..sort();

  // ---- 条款 1：实现类 agent 越界写 test/ tools/gate/ ACCEPTANCE/RUBRIC ----
  final RunResult logR = await git([
    'log',
    '--name-only',
    '--format=@@%h|%s',
    '$baseline..HEAD',
  ]);
  final Map<String, String> pathOwners = <String, String>{};
  String subject = '';
  for (final String line in logR.stdout.split('\n')) {
    final String t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('@@')) {
      subject = t.substring(2).split('|').skip(1).join('|');
      continue;
    }
    pathOwners[t.replaceAll('\\', '/')] = ownerOfSubject(subject);
  }
  evidence['committed_changes'] = pathOwners.keys.toList()..sort();
  for (final MapEntry<String, String> e in pathOwners.entries) {
    if (self.contains(e.key)) continue;
    if (isForbiddenFor(e.key, e.value)) {
      violations.add(Violation(
        '1',
        e.key,
        e.value,
        '基线 $baseline 之后被提交修改（$baseline..HEAD）',
      ));
    }
  }

  // ---- 工作区（未提交）变更 ----
  final RunResult st = await git(['status', '--porcelain=v1', '-uall']);
  final List<Map<String, dynamic>> worktree = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> judgeOwned = <Map<String, dynamic>>[];
  for (final String line in st.stdout.split('\n')) {
    if (line.trim().isEmpty) continue;
    final String status = line.substring(0, 2);
    String path = line.substring(2).trim();
    if (path.contains(' -> ')) path = path.split(' -> ').last;
    path = path.replaceAll('"', '').replaceAll('\\', '/');
    // out/ 是共享输出目录（CLAUDE.md §4），不参与越界判定。
    if (path.startsWith('out/')) continue;
    final bool untouched = self.contains(path);
    worktree.add(<String, dynamic>{
      'status': status,
      'path': path,
      'gatekeeper_self_touched': untouched,
    });
    if (untouched) continue;
    if (isUniversallyProtected(path)) {
      violations.add(Violation(
        '1',
        path,
        attributeWorktree(path),
        '未提交改动了"考卷/监考工具"（状态=$status），且不在 gatekeeper 本轮自报清单里',
      ));
    } else if (path.startsWith('test/')) {
      // 裁判类 agent 在自己的 test 子领地里干活是本职，不能用"碰 test/ 即 FAIL"
      // 一刀切（那会把 qa-batch/adversarial 每轮的正常工作都判成作弊 ——
      // 误报和漏报一样有害）。这里只做**登记**，不计违规；真正该拦的
      // 「实现类 agent 碰 test/」在已提交变更那一条里靠提交前缀归属来判。
      judgeOwned.add(<String, dynamic>{
        'status': status,
        'path': path,
        'note': 'test/ 下未提交改动，需对应裁判自认（qa-batch: test/batch, test/golden, '
            'test/dataset.json；adversarial: test/adversarial）',
      });
    }
  }
  evidence['worktree_changes'] = worktree;
  evidence['worktree_test_changes_pending_claim'] = judgeOwned;

  // ---- 条款 3：skip / @Skip / 注释掉的断言 ----
  final Map<String, List<String>> skipHits = <String, List<String>>{};
  for (final String dir in <String>['lib', 'test', 'tools/gate', 'integration_test']) {
    final RunResult r = await runProcess(
      'grep',
      ['-rn', '-E', r'skip:|@Skip|@skip', dir],
      timeout: const Duration(seconds: 60),
    );
    final List<String> lines = r.stdout
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isNotEmpty) skipHits[dir] = lines;
  }
  evidence['skip_hits'] = skipHits;
  for (final MapEntry<String, List<String>> e in skipHits.entries) {
    violations.add(Violation('3', e.key, '未定位', '命中 skip/@Skip：${e.value.first}'));
  }

  // ---- 条款 5：catch-all 空吞异常 ----
  final Map<String, List<String>> catchHits = <String, List<String>>{};
  for (final String dir in <String>['lib', 'test']) {
    final RunResult r = await runProcess(
      'grep',
      ['-rn', '-E', r'catch\s*\(\s*[A-Za-z_]*\s*\)\s*\{\s*\}', dir],
      timeout: const Duration(seconds: 60),
    );
    final List<String> lines = r.stdout
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isNotEmpty) catchHits[dir] = lines;
  }
  evidence['empty_catch_hits'] = catchHits;
  for (final MapEntry<String, List<String>> e in catchHits.entries) {
    violations.add(Violation('5', e.key, '未定位', '空 catch 吞异常：${e.value.first}'));
  }

  // ---- 条款 4：黄金集不得减少 ----
  evidence['golden_src_count'] = goldenSrcCount;
  evidence['golden_ref_count'] = goldenRefCount;
  evidence['prev_golden_src_count'] = prevGoldenSrcCount;
  evidence['prev_golden_ref_count'] = prevGoldenRefCount;
  if (prevGoldenSrcCount != null && goldenSrcCount < prevGoldenSrcCount) {
    violations.add(Violation(
      '4',
      'test/golden/src',
      '未定位',
      '黄金集数量从 $prevGoldenSrcCount 减到 $goldenSrcCount',
    ));
  }
  if (prevGoldenRefCount != null && goldenRefCount < prevGoldenRefCount) {
    violations.add(Violation(
      '4',
      'test/golden/ref',
      '未定位',
      '参考 alpha 数量从 $prevGoldenRefCount 减到 $goldenRefCount',
    ));
  }
  if (goldenSrcCount < 8 || goldenRefCount < 8) {
    violations.add(Violation(
      '4',
      'test/golden',
      '未定位',
      '黄金集低于 ACCEPTANCE G1.3/G1.4 要求的 8 张（src=$goldenSrcCount ref=$goldenRefCount）',
    ));
  }

  // ---- 条款 2：gate 脚本 SHA256 ----
  final List<String> hashDiffs = <String>[];
  if (prevHashes == null || prevHashes.isEmpty) {
    evidence['hash_note'] = '首轮无 out/hashes_prev.txt 基线，本轮建立（条款 2 首轮不判 FAIL）';
  } else {
    for (final MapEntry<String, String> e in currentHashes.entries) {
      if (self.contains(e.key)) continue; // gatekeeper 自报的本轮改动
      final String? prev = prevHashes[e.key];
      if (prev != null && prev != e.value) {
        hashDiffs.add('${e.key}: $prev → ${e.value}');
      }
    }
    for (final String k in prevHashes.keys) {
      if (!currentHashes.containsKey(k) && !self.contains(k)) {
        hashDiffs.add('$k: 上一轮存在，本轮消失');
      }
    }
  }
  evidence['hash_diffs'] = hashDiffs;

  return <String, dynamic>{
    'baseline': baseline,
    'violations': violations.map((Violation v) => v.toJson()).toList(),
    'clean': violations.isEmpty,
    'evidence': evidence,
  };
}

/// 统计目录下符合条件的文件数（黄金集用）。
int countFiles(String dir, {Set<String>? extensions}) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return 0;
  int n = 0;
  for (final FileSystemEntity e in d.listSync()) {
    if (e is! File) continue;
    if (extensions == null) {
      n++;
      continue;
    }
    final String lower = e.path.toLowerCase();
    if (extensions.any(lower.endsWith)) n++;
  }
  return n;
}
