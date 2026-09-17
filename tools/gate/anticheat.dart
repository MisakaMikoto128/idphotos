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
  // 主会话的几种前缀。主会话是 CLAUDE.md §4 里 `docs/ACCEPTANCE.md` 与
  // `docs/RUBRIC.md` 的**唯一写入者**，它写法典是本职，不是越界。
  'acceptance': '主会话',
  'api': '主会话',
  'docs': '主会话',
  'build': '主会话',
  'gitignore': '主会话',
  'pitfalls': '主会话',
  // P0 阶段的落地前缀。它下面的提交**跨领地**：同一个提交里既有
  // `tools/gate/**`（gatekeeper 的）又有 `test/batch/**`（qa-batch 的）——
  // "p0: 提交 P0 门禁与测量台"就是这样一条。
  // 单个前缀无法逐文件归对主，这里归给 gatekeeper，配套地让
  // `test/` 下的越界判定只针对**实现类** agent（见 isForbiddenFor）。
  'p0': 'gatekeeper',
};

String ownerOfSubject(String subject) {
  final int i = subject.indexOf(':');
  if (i < 0) return '未知（提交信息无前缀：$subject）';
  String prefix = subject.substring(0, i).trim().toLowerCase();
  // `gate(P0):` / `gate(G4):` 这类带括号限定的前缀：先剥掉括号再查表。
  // 不剥的话 `gate(p0)` 查不到 → 归属成"未知" → 撞上"未知一律从严" →
  // **把门禁自己的提交判成条款 1 违规**。判据误报的害处与漏报相同：
  // 它会把"每一轮都是红的"变成常态，于是没人再认真看这一栏。
  final int paren = prefix.indexOf('(');
  if (paren > 0) prefix = prefix.substring(0, paren).trim();
  return kSubjectPrefixOwner[prefix] ?? '未知（前缀 `$prefix` 不在角色表）';
}

/// 实现类 agent：**干活的人**。条款 1 就是冲它们来的 ——
/// 自己给自己出考卷（改 `test/`）、自己改监考工具（`tools/gate/`）、
/// 自己改法典（`docs/ACCEPTANCE.md`），三种都必须是 FAIL。
const Set<String> kImplementationAgents = <String>{
  'ml-porting',
  'imaging',
  'ui-woodcraft',
  'release',
  'store-assets',
  'env-setup',
};

/// 实现类 agent 一律不许碰的路径。`test/gate/` 是 gatekeeper 自己的，不在其中。
///
/// [owner] 是变更的归属（commit 前缀映射出来的 agent 名）。裁判类 agent
/// （qa-batch / adversarial / gatekeeper）在自己的 test 子领地里写入是合法的，
/// 不能一刀切 —— 误报会把别人的正常工作判成作弊，和漏报一样有害。
bool isForbiddenFor(String path, String owner) {
  final String p = path.replaceAll('\\', '/');
  final bool impl = kImplementationAgents.contains(owner) ||
      owner.startsWith('未知'); // 归属不明一律从严，见下
  if (p == 'docs/ACCEPTANCE.md' || p == 'docs/RUBRIC.md') {
    // 只有主会话能写法典（CLAUDE.md §4「唯一写入者」）。
    // 实现类改它 = 直接 FAIL（条款 1 原文点名了这四个）；
    // 裁判类也不许 —— 改法典的人就不再中立了。
    return owner != '主会话';
  }
  // 监考工具与门禁自己的考卷：只有 gatekeeper 能碰。这一条不放松。
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
    // **只对实现类 agent 判违规。**
    //
    // 条款 1 的原文就是"**实现类 agent** 写入了 test/…"，靶子从来是
    // "自己给自己出考卷"。此前这里写的是"剩下的归属一律 true"，
    // 于是一条**跨领地**的提交（如 `p0: 提交 P0 门禁与测量台`，
    // 同一个提交里既有 tools/gate 又有 test/batch）会让 qa-batch 的正经产物
    // 顶着 gatekeeper 的归属被判违规 —— 20 多处假阳性。
    // 假阳性的害处与漏报相同：整栏长红，就没人再认真看它。
    //
    // 归属不明（`未知…`）仍然从严：那是"说不上来谁写的"，
    // 与"确认是裁判写的"是两回事。
    return impl;
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
  // 同 `git()`：`--format=%s` 里的 `%` 会被 cmd 当变量展开前缀，
  // 开着 shell 时这颗参数同样不可靠。runInShell: false 才是原样传参。
  final ProcessResult r = Process.runSync(
    'git',
    <String>['log', '-1', '--format=%s', '--', path],
    runInShell: false,
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
///
/// **`runInShell: false` 不是风格问题，是正确性问题。** 本函数的调用方传的
/// `--format=@@%h|%s` 含 `|`；开着 shell 时 cmd.exe 把它当管道，
/// git 以 exit 255、stdout 空收场，而调用方拿到空列表会判"无越界 = 清白"。
/// 条款 1 因此静默失效了很久。git 是 `.exe`，不需要 shell。
Future<RunResult> git(List<String> args) => runProcess(
      'git',
      args,
      runInShell: false,
      timeout: const Duration(seconds: 60),
    );

/// 空 catch 的模式。**跨行**（`catch (e) {` 换行 `}`）必须也匹配。
///
/// `[\s\S]*?` 而不是 `\s*`：让"花括号之间除了空白什么都没有"这件事
/// 能跨过换行，同时用惰性量词避免吃掉后面的代码。
/// 用 `*?`＋单独校验括号内是否只有空白，比 `{0,80}?` 更稳：
/// 后者会给攻击者一个"塞 81 个空格就隐形"的窗口。
const String kEmptyCatchPattern = r'catch\s*\(\s*[A-Za-z_]*\s*\)\s*\{\s*\}';

/// 判据的分母（真值文件）。与 `gate_P0.dart` 的 `kTruthPath` 同值——
/// 这里重复写一次，是为了让 `anticheat.dart` 不反向依赖 `gate_P0.dart`。
const String kTruthPathForEvidence = 'out/P0_truth.json';

/// 被扫描的源码扩展名。**显式列出并在报告里回显**——
/// "我扫了什么"和"我什么都没找到"必须分得开。
const Set<String> kScannedExtensions = <String>{
  '.dart',
  '.kt',
  '.gradle',
  '.kts',
  '.xml',
  '.yaml',
  '.yml',
  '.json',
  '.md',
  '.txt',
};

/// 巡检工具自己的地盘。条款 3/5 的命中落在这里时**登记但不判违规**。
///
/// 理由：扫描器扫不了自己。`tools/gate/anticheat.dart` 里必然写着
/// `skip:`、`@Skip`、`catch` 这些**模式常量本身**，`test/gate/anticheat_test.dart`
/// 里必然摆着 `catch (_) {}` 这种**正例夹具**——它们不是"测试被跳过"，
/// 是"仪表被照进了镜子"。一刀切会把这两处每轮都判成违规，那是噪声；
/// 而噪声和漏报一样有害，会训练人忽略告警。
///
/// **这条路堵不死人**：这两个目录本就只有 gatekeeper 能写
/// （`isForbiddenFor` 对任何非 gatekeeper 的归属都返回 true，认不出的归属也从严），
/// 别人往里写已经先被条款 1 拦下。这里的命中仍会**逐条列进报告**，
/// 只是不计违规——**登记而隐去**才是作弊，**登记并公开**不是。
bool isScannerSelfTerritory(String path) {
  final String p = path.replaceAll('\\', '/');
  return p.startsWith('tools/gate/') || p.startsWith('test/gate/');
}

/// 从 `path:line: snippet` 形式的命中行里取回路径。
/// 取不到时原样返回整行——**不返回空串**，免得把"认不出路径"变成"路径为空"
/// 而被 `isScannerSelfTerritory('')` 判成非自身领地后误报。
String hitPath(String hit) {
  final RegExpMatch? m = RegExp(r'^(.*?):\d+:').firstMatch(hit);
  return m == null ? hit : m.group(1)!;
}

/// 递归列出待扫描文件，顺序稳定（可复现），跳过构建产物与隐藏目录。
List<File> _sourceFiles(String dir) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return <File>[];
  final List<File> out = <File>[];
  for (final FileSystemEntity e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final String p = e.path.replaceAll('\\', '/');
    if (p.contains('/.dart_tool/') ||
        p.contains('/build/') ||
        p.contains('/.git/') ||
        p.contains('/__pycache__/')) {
      continue;
    }
    final int dot = p.lastIndexOf('.');
    if (dot < 0) continue;
    if (!kScannedExtensions.contains(p.substring(dot).toLowerCase())) continue;
    out.add(e);
  }
  out.sort((File a, File b) => a.path.compareTo(b.path));
  return out;
}

/// 扫一个目录，返回 {hits, files_scanned, unreadable, disagreements,
/// undecidable, why, engine}。
///
/// **为什么不用外部 grep**（2026-09-17 实测，血泪）：本机从 Dart 起 `grep`
/// 子进程时，Windows 会在参数传递途中吃掉 `\` `{` `}` `,` ——
/// 模式 `catch\s*\(\s*[A-Za-z_]*\s*\)\s*\{[\s\S]{0,80}?\}`
/// 到达 grep 时变成 `catchs*(s*[A-Za-z_]*s*)s*{[sS]80?}`，
/// 于是 grep 报 exit 2（`No such file or directory`）；
/// `-P` 还会因为 locale 直接拒跑；`skip:|@Skip|@skip` 里的 `|` 被 shell 当管道，
/// 报 `'Skip' is not recognized`、exit 255。
/// 上一轮（r1）的条款 3/5 证据就是这个状态：**扫描从未真正跑过**，
/// 而报告里写的是"命中 0"。所以现在改成**纯 Dart 正则**，不经过任何外部进程、
/// 任何 shell、任何 locale。Dart 的 RegExp 原生支持 `[\s\S]` 与跨行匹配。
///
/// **两个引擎**取并集并互相校验：
///  - A：`RegExp` 逐文件全文匹配（能跨行）；
///  - B：字面量预筛（`prefilter`），必须是 A 的**可靠超集**。
/// A 命中而 B 没筛出来的文件 = 两个引擎打架 ⇒ [undecidable]，
/// 由调用方在 AC 里显式报"不可判"，**不许当成清白**。
Future<Map<String, dynamic>> scanDir(
  String dir, {
  required RegExp pattern,
  required List<String> prefilter,
}) async {
  final List<String> hits = <String>[];
  final List<String> unreadable = <String>[];
  final List<String> disagreements = <String>[];
  int scanned = 0;

  for (final File f in _sourceFiles(dir)) {
    final String p = f.path.replaceAll('\\', '/');
    String src;
    try {
      src = await f.readAsString();
    } catch (e) {
      unreadable.add('$p: $e');
      continue;
    }
    scanned++;

    bool literal = false;
    for (final String lit in prefilter) {
      if (src.contains(lit)) {
        literal = true;
        break;
      }
    }

    for (final RegExpMatch m in pattern.allMatches(src)) {
      if (!literal) {
        disagreements.add('$p: 正则命中但字面量预筛未筛出（$prefilter）');
        break;
      }
      int line = 1;
      for (int i = 0; i < m.start && i < src.length; i++) {
        if (src.codeUnitAt(i) == 0x0A) line++;
      }
      final String snippet = src
          .substring(m.start, m.end)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      hits.add('$p:$line: $snippet');
    }
  }

  final bool undecidable = unreadable.isNotEmpty || disagreements.isNotEmpty;
  return <String, dynamic>{
    'hits': hits..sort(),
    'files_scanned': scanned,
    'unreadable': unreadable,
    'disagreements': disagreements,
    'undecidable': undecidable,
    'why': <String>[
      if (unreadable.isNotEmpty) '有文件读不出来（${unreadable.length} 个）',
      if (disagreements.isNotEmpty) '两个扫描引擎结论打架（${disagreements.length} 处）',
    ].join('；'),
    'engine': 'dart-regexp(全量) ∪ 字面量预筛(超集校验)',
  };
}

/// 把「注释」与「字符串字面量」的**内容**替换成空格，长度与换行保持不变。
///
/// 目的：让"找 `catch` 并配平括号"只看到**真正的代码**。不这么做的话，
/// `/// } catch (_) {}` 这种文档注释里的示例、以及字符串里的 `"catch (e) {}"`
/// 都会被当成真代码。长度不变 → 偏移量仍能映射回原文；换行不变 → 行号仍准。
/// [commentSpansOut] 非空时，把**注释**的字符区间（原文下标，`[start, end)`）追加进去。
/// 条款 3 第三款要用它：判「注释掉的断言」必须只看**注释里**的文字，否则
/// `expect(hits.contains('// expect(...)'), true)` 这种"真断言里带着注释样字符串"
/// 会被误判成「注释掉的断言」。
String maskNonCode(String src, {List<List<int>>? commentSpansOut}) {
  final List<int> out = src.codeUnits.toList();
  void blank(int from, int to) {
    for (int k = from; k < to && k < out.length; k++) {
      if (out[k] != 0x0A && out[k] != 0x0D) out[k] = 0x20;
    }
  }

  bool identAt(int k) {
    if (k < 0 || k >= src.length) return false;
    final int c = src.codeUnitAt(k);
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F ||
        c == 0x24;
  }

  int i = 0;
  while (i < src.length) {
    final String c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      int j = i + 2;
      while (j < src.length && src[j] != '\n') j++;
      blank(i, j);
      commentSpansOut?.add(<int>[i, j]);
      i = j;
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      int j = i + 2;
      while (j + 1 < src.length && !(src[j] == '*' && src[j + 1] == '/')) j++;
      j = j + 1 < src.length ? j + 2 : src.length;
      blank(i, j);
      commentSpansOut?.add(<int>[i, j]);
      i = j;
    } else if (c == "'" || c == '"') {
      // raw string（`r'...'` / `r"..."`）里的反斜杠不是转义。
      final bool raw = i > 0 && (src[i - 1] == 'r' || src[i - 1] == 'R') && !identAt(i - 2);
      final String delim = src.startsWith(c * 3, i) ? c * 3 : c;
      int j = i + delim.length;
      while (j < src.length) {
        if (!raw && !delim.contains(c * 3) && src[j] == '\\') {
          j += 2;
          continue;
        }
        if (src.startsWith(delim, j)) {
          j += delim.length;
          break;
        }
        j++;
      }
      blank(i, j);
      i = j;
    } else {
      i++;
    }
  }
  return String.fromCharCodes(out);
}

int _skipWs(String s, int i) {
  while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
    i++;
  }
  return i;
}

/// 从 `s[open]`（应为 [o]）出发配平到配对的 [c]，返回其下标；配不平返回 -1。
/// 调用前必须已经过 [maskNonCode]，否则字符串/注释里的括号会干扰配平。
int matchBracket(String s, int open, String o, String c) {
  if (open >= s.length || s[open] != o) return -1;
  int depth = 0;
  for (int i = open; i < s.length; i++) {
    if (s[i] == o) depth++;
    if (s[i] == c) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 一处 catch 站点。 [body] 是**原文**里的体内文本（注释保留）。
class CatchSite {
  final int offset;
  final String body;
  CatchSite(this.offset, this.body);
}

/// 找出所有**体内没有任何语句**的 `catch`。
///
/// 为什么必须是状态机而不是正则：条款 5 的正文是"通过 catch-all 吞异常
/// （`catch (_) {}` 空实现）"，而**"空"这件事正则表达不了**。上一版用
/// `catch\s*\(...\)\s*\{\s*\}`，只认空白，于是
///     } catch (_) {
///       // 换下一个候选。
///     }
/// 和 `catch (_) { ; }` 全都漏掉 —— `lib/` 里正好有 2 处注释体漏网。
/// **判据是条款的严格子集，就等于悄悄放行了一个子集**，和"空 stdout 当成零命中"
/// 是同一个病，只差一层。
///
/// 这里剥掉注释与字符串后配平括号：体内除了空白和 `;` 什么都没有 ⇒ 空实现。
List<CatchSite> emptyCatchSites(String src) {
  final String masked = maskNonCode(src);
  final List<CatchSite> out = <CatchSite>[];
  for (final RegExpMatch m in RegExp(r'\bcatch\b').allMatches(masked)) {
    int i = _skipWs(masked, m.end);
    if (i >= masked.length || masked[i] != '(') continue;
    final int cp = matchBracket(masked, i, '(', ')');
    if (cp < 0) continue;
    i = _skipWs(masked, cp + 1);
    if (i >= masked.length || masked[i] != '{') continue;
    final int cb = matchBracket(masked, i, '{', '}');
    if (cb < 0) continue;
    if (masked.substring(i + 1, cb).replaceAll(';', '').trim().isNotEmpty) continue;
    out.add(CatchSite(m.start, src.substring(i + 1, cb).trim()));
  }
  return out;
}

/// 体内是否带**说明**（注释）。带注释的吞异常与光秃秃的 `catch (_) {}` 分开登记：
/// 前者至少留下了作者自述的理由，后者什么也没有。
bool catchBodyHasReason(String body) => body.contains('//') || body.contains('/*');

/// 条款 5 的**定罪规则**，抽成纯函数是为了它能被自测直接驱动。
///
/// 规则一句话：**任何空 catch 都计违规，带不带注释完全一样。**
/// 抽出来不是为了复用，是因为上一版的规则（注释体降级为"登记"）藏在 `patrol` 的
/// 循环里，只能靠读代码确认 —— 而"注释体到底算不算"恰恰是那条规则的全部内容。
/// 一个无法被单独构造用例检验的规则，改错了没人会知道。
List<Violation> emptyCatchViolations(List<String> bare, List<String> commented) {
  final List<Violation> out = <Violation>[];
  for (final String h in bare) {
    out.add(Violation('5', hitPath(h), '未定位', '空 catch 吞异常：$h'));
  }
  for (final String h in commented) {
    out.add(Violation(
      '5',
      hitPath(h),
      '未定位',
      '空 catch 吞异常（体内只有注释，**不再因此降级**）：$h',
    ));
  }
  return out;
}

/// 扫空 catch。两个引擎互相校验：
///  - A：状态机 [emptyCatchSites]（**权威**，覆盖注释体 / `;` 体）；
///  - B：正则 [kEmptyCatchPattern]（只认空白体，是 A 的**真子集**）。
/// A ⊇ B 是设计约束，一旦 B 命中而 A 没命中就说明状态机漏了 ⇒ [undecidable]。
///
/// 返回 {empty_body_hits, commented_body_hits, files_scanned, undecidable, why,
/// definition}。两类命中**都全量登记**；只有前者自动计违规（见 patrol）。
Future<Map<String, dynamic>> scanEmptyCatches(String dir) async {
  final List<String> bare = <String>[];
  final List<String> commented = <String>[];
  final List<String> disagreement = <String>[];
  final List<String> unreadable = <String>[];
  final RegExp regexEngine = RegExp(kEmptyCatchPattern);
  int scanned = 0;

  for (final File f in _sourceFiles(dir)) {
    final String p = f.path.replaceAll('\\', '/');
    String src;
    try {
      src = await f.readAsString();
    } catch (e) {
      unreadable.add('$p: $e');
      continue;
    }
    scanned++;
    final List<CatchSite> sites = emptyCatchSites(src);
    int lineOf(int off) {
      int line = 1;
      for (int i = 0; i < off && i < src.length; i++) {
        if (src.codeUnitAt(i) == 0x0A) line++;
      }
      return line;
    }

    final Set<int> machineOffsets = <int>{};
    for (final CatchSite s in sites) {
      machineOffsets.add(s.offset);
      final String body = s.body.replaceAll(RegExp(r'\s+'), ' ').trim();
      final String rendered = body.isEmpty
          ? '$p:${lineOf(s.offset)}: catch (_) { }'
          : '$p:${lineOf(s.offset)}: catch (_) { $body }'
              '${body.length > 120 ? ' …' : ''}';
      if (catchBodyHasReason(s.body)) {
        commented.add(rendered);
      } else {
        bare.add(rendered);
      }
    }

    // 引擎 B 的超集校验：正则命中的位置状态机必须也命中。
    final String masked = maskNonCode(src);
    for (final RegExpMatch m in regexEngine.allMatches(masked)) {
      final bool covered = machineOffsets.any((int o) => (o - m.start).abs() < 200);
      if (!covered) {
        disagreement.add('$p:${lineOf(m.start)}: 正则命中但状态机未命中（状态机可能漏判）');
      }
    }
  }

  final bool undecidable = unreadable.isNotEmpty || disagreement.isNotEmpty;
  return <String, dynamic>{
    'empty_body_hits': bare..sort(),
    'commented_body_hits': commented..sort(),
    'files_scanned': scanned,
    'unreadable': unreadable,
    'disagreements': disagreement,
    'undecidable': undecidable,
    'why': <String>[
      if (unreadable.isNotEmpty) '有文件读不出来（${unreadable.length} 个）',
      if (disagreement.isNotEmpty) '两个引擎结论打架（${disagreement.length} 处）',
    ].join('；'),
    'engine': '状态机(权威) ⊇ 正则(空白体子集)',
    'definition': '体内剥掉注释与字符串后，除空白与 `;` 外没有任何语句 ⇒ 空实现。'
        '**含注释体与 `catch (_) { ; }`**，不是只认 `{}`。',
    'conviction': '`empty_body_hits` 与 `commented_body_hits` **两类一律计违规**，'
        '分类只进报告、不改变定罪。加注释不构成减免。',
  };
}

/// 条款 3 第三款「注释掉的断言」的直接扫描。
///
/// 只认**注释里、且以断言调用开头**的那一行（`// expect(`、`// await expect(`…）。
/// 判据必须落在**注释区间**上，不能拿整行原文去匹配 —— 否则
/// `expect(hits.contains('// expect(...)'), true)` 这种"真断言里带着注释样字符串"
/// 会被误判成「注释掉的断言」（第一版就是这么错的，自己误报了自己 4 处）。
/// 反过来，散文里顺带提到的 `expect` 不算 —— 误报和漏报一样有害。
final RegExp kCommentedAssertionLine =
    RegExp(r'^(await\s+)?(expect|assert|test|verify|checks?)\s*\(');

/// 扫「注释掉的断言」。返回与 [scanDir] 同形。
Future<Map<String, dynamic>> scanCommentedAssertions(String dir) async {
  final List<String> hits = <String>[];
  final List<String> unreadable = <String>[];
  int scanned = 0;
  for (final File f in _sourceFiles(dir)) {
    final String p = f.path.replaceAll('\\', '/');
    String src;
    try {
      src = await f.readAsString();
    } catch (e) {
      unreadable.add('$p: $e');
      continue;
    }
    scanned++;
    final List<List<int>> spans = <List<int>>[];
    maskNonCode(src, commentSpansOut: spans);
    for (final List<int> sp in spans) {
      int baseLine = 1;
      for (int i = 0; i < sp[0] && i < src.length; i++) {
        if (src.codeUnitAt(i) == 0x0A) baseLine++;
      }
      final List<String> lines = src.substring(sp[0], sp[1]).split('\n');
      for (int i = 0; i < lines.length; i++) {
        String t = lines[i].trim();
        // 剥掉注释标记：`//`、`/*`、`*/`、行首的 `*`。
        while (t.isNotEmpty && (t[0] == '/' || t[0] == '*')) {
          t = t.substring(1).trim();
        }
        if (kCommentedAssertionLine.hasMatch(t)) {
          hits.add('$p:${baseLine + i}: ${lines[i].trim()}');
        }
      }
    }
  }
  return <String, dynamic>{
    'hits': hits..sort(),
    'files_scanned': scanned,
    'unreadable': unreadable,
    'disagreements': <String>[],
    'undecidable': unreadable.isNotEmpty,
    'why': unreadable.isEmpty ? '' : '有文件读不出来（${unreadable.length} 个）',
    'engine': 'dart-regexp(仅在注释区间内匹配)',
    'definition': '**注释里**以断言调用开头的那一行（`//`、`/* */` 皆算）；'
        '真断言里的字符串、散文里提到的 expect 都不算。',
  };
}

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
  List<String> unhashable = const <String>[],
  List<String> judgmentInputDrift = const <String>[],
  String judgmentInputNote = '',
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
  // **取不到 ≠ 没有。** 这段以前不查 exitCode：`git log` 因为参数被 cmd 吃掉而以
  // exit 255、空 stdout 收场时，下面的解析得到的是一张空表，条款 1 于是判**清白** ——
  // 最重要的那条防作弊检查自写下起就没工作过，每一轮都在报"清白"。
  // 所以：命令失败 ⇒ 这条查不了 ⇒ **判不可判**，绝不当成"没查到违规"。
  if (!logR.success) {
    violations.add(Violation(
      '1',
      '$baseline..HEAD',
      '未定位',
      '**条款 1 无法执行**：`git log` 未成功（exitCode=${logR.exitCode}，'
          'timedOut=${logR.timedOut}）。取不到 ≠ 没有越界 —— 本条判"不可判"，'
          '不得当作清白。诊断：${logR.tail(maxChars: 300)}',
    ));
  }
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
  final List<String> undecidable = <String>[];
  // **两个族各用一个 map。**共用同一个 Map 实例会让 `skip_scans` 和
  // `catch_scans` 变成同一个对象，JSON 序列化出来两份内容一样、
  // 且互相把对方的条目算进自己的命中数（r1 再生成时就踩了这个）。
  final Map<String, dynamic> skipScans = <String, dynamic>{};
  final Map<String, List<String>> skipHits = <String, List<String>>{};
  for (final String dir in <String>['lib', 'test', 'tools/gate', 'integration_test']) {
    final Map<String, dynamic> s = await scanDir(
      dir,
      pattern: RegExp(r'skip:|@Skip|@skip'),
      prefilter: const <String>['skip:', '@Skip', '@skip'],
    );
    skipScans['skip:$dir'] = s;
    if (s['undecidable'] == true) undecidable.add('条款 3 @ $dir');
    final List<String> lines = (s['hits'] as List<dynamic>).cast<String>();
    if (lines.isNotEmpty) skipHits[dir] = lines;
  }
  evidence['skip_scans'] = skipScans;
  evidence['skip_hits'] = skipHits;
  final Map<String, List<String>> skipSelf = <String, List<String>>{};
  for (final MapEntry<String, List<String>> e in skipHits.entries) {
    for (final String h in e.value) {
      if (isScannerSelfTerritory(hitPath(h))) {
        skipSelf.putIfAbsent(hitPath(h), () => <String>[]).add(h);
      } else {
        violations.add(Violation('3', hitPath(h), '未定位', '命中 skip/@Skip：$h'));
      }
    }
  }
  evidence['skip_hits_self_reference'] = skipSelf;

  // 条款 3 的**第三款**「注释掉的断言」：直接扫，不靠 diff 兜。
  final Map<String, dynamic> assertScans = <String, dynamic>{};
  final Map<String, List<String>> assertHits = <String, List<String>>{};
  for (final String dir in <String>['lib', 'test', 'tools/gate', 'integration_test']) {
    final Map<String, dynamic> s = await scanCommentedAssertions(dir);
    assertScans['commented_assertion:$dir'] = s;
    if (s['undecidable'] == true) undecidable.add('条款 3(注释掉的断言) @ $dir');
    final List<String> lines2 = (s['hits'] as List<dynamic>).cast<String>();
    if (lines2.isNotEmpty) assertHits[dir] = lines2;
  }
  evidence['commented_assertion_scans'] = assertScans;
  evidence['commented_assertion_hits'] = assertHits;
  final Map<String, List<String>> assertSelf = <String, List<String>>{};
  for (final MapEntry<String, List<String>> e in assertHits.entries) {
    for (final String h in e.value) {
      if (isScannerSelfTerritory(hitPath(h))) {
        assertSelf.putIfAbsent(hitPath(h), () => <String>[]).add(h);
      } else {
        violations.add(Violation('3', hitPath(h), '未定位', '注释掉的断言：$h'));
      }
    }
  }
  evidence['commented_assertion_hits_self_reference'] = assertSelf;

  // 条款 3 的**第四款**「被放宽的阈值常量」：**没有独立扫描器，是结构性覆盖**。
  // 如实写明覆盖方式，免得报告读起来像"条款 3 已被完整扫描"。
  evidence['clause3_coverage'] = <String, dynamic>{
    'skip_token': '直接扫描（skip: / @Skip / @skip）',
    'commented_assertion': '直接扫描（仅在注释区间内匹配 ${kCommentedAssertionLine.pattern}）',
    'relaxed_thresholds': '**结构性覆盖，无独立扫描器**：'
        '本项目的阈值常量只存在于两处 —— `docs/ACCEPTANCE.md`（防作弊条款 1 绝对保护，'
        '任何 agent 改动即 FAIL）与 `tools/gate/`（条款 2 SHA256 逐轮比对）。'
        '二者任一被改都会在条款 1 或条款 2 上现形，故不另设扫描；'
        '**但这不等于"扫过了"**——若将来阈值常量被挪到第三处，本条覆盖即失效。',
  };

  // ---- 条款 5：catch-all 空吞异常 ----
  //
  // 判据是**状态机**（`emptyCatchSites`），不是正则：正则表达不了"空"。
  // 上一版用 `catch\s*\(...\)\s*\{\s*\}` 只认空白体，把
  //     } catch (_) { // 理由 }
  // 和 `catch (_) { ; }` 全漏掉 —— `lib/` 里正好漏了 2 处注释体。
  // **判据是条款的严格子集，等于悄悄放行了一个子集。**
  //
  // 第二版按"体内有没有注释"分成两类：无说明的自动定罪、带注释的只登记。
  // **主会话 2026-09-17 改口径，这一版再改**：注释不该决定任何事。
  //   · "加一句注释就把自动定罪降级为登记"是一条**能被扩写的洗白通道**，
  //     而豁免表比常数危险得多；
  //   · 让那 5 处生产代码清白的**不是注释，是它们周围的代码**（错误从返回值
  //     或紧随其后的语句透出去）。既然真正的判据是"失败可否观测"，
  //     注释就**不是语义差别**，不该拿来当判别器。
  //   · 正确修法是**把那几处改掉**（改完条款 5 不再需要任何豁免），不是给注释体
  //     开后门。
  // 现在：**任何空 catch，带不带注释，一律自动定罪，没有洗白通道。**
  // 两类仍然分列登记（`empty_body_hits` / `commented_body_hits`），
  // 但那只是**报告里的分类**，不再影响是否计违规。
  //
  // 扫描范围同时**扩到 `tools/gate/` 与 `integration_test/`**：
  // 上一版只扫 `lib/` 与 `test/`，于是**巡检自己领地里的空 catch 结构性隐形**。
  // 门禁不能对自己网开一面 —— 那正是"判据是条款的严格子集"的另一种写法。
  final Map<String, dynamic> catchScans = <String, dynamic>{};
  final List<String> catchBare = <String>[];
  final List<String> catchCommented = <String>[];
  for (final String dir in <String>['lib', 'test', 'tools/gate', 'integration_test']) {
    final Map<String, dynamic> s = await scanEmptyCatches(dir);
    catchScans['catch:$dir'] = s;
    if (s['undecidable'] == true) undecidable.add('条款 5 @ $dir');
    catchBare.addAll((s['empty_body_hits'] as List<dynamic>).cast<String>());
    catchCommented.addAll((s['commented_body_hits'] as List<dynamic>).cast<String>());
  }
  evidence['catch_scans'] = catchScans;
  evidence['empty_catch_hits'] = catchBare..sort();
  evidence['commented_catch_hits'] = catchCommented..sort();
  violations.addAll(emptyCatchViolations(catchBare, catchCommented));
  // 保留这一栏只为**可读性**：让报告读者一眼看出哪些曾经靠注释"洗过"。
  // 它**不影响**上面的定罪 —— `commented_catch_hits` 与 `empty_catch_hits`
  // 里的每一条都已经在上面的循环里计过违规了。
  evidence['commented_catch_registered'] = <String>[
    '（**本栏只作分类展示，不改变定罪**：带注释的空 catch 与不带注释的一样计违规。）',
    ...catchCommented,
  ];

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
  //
  // 「哈希表里缺项」的处置，**明写在这里**，免得将来各自解释：
  //  - 上一轮在、本轮**消失**，且不在 gatekeeper 自报清单里 → 记 diff（原样保留）；
  //  - 本轮**算不出哈希**（文件读不出来）→ 进 `unhashable`，**不从表里悄悄消失**，
  //    并在 AC 条目里报"不可判"。上一版就是这里静默少报：
  //    `if (s != null) h[p] = s;` 让算不出来的文件直接蒸发。
  final List<String> hashDiffs = <String>[];
  evidence['unhashable'] = unhashable;
  if (unhashable.isNotEmpty) {
    for (final String p in unhashable) {
      undecidable.add('条款 2：$p 算不出哈希（本轮的哈希表里没有它）');
    }
    violations.add(Violation(
      '2',
      unhashable.first,
      '未定位',
      '有 ${unhashable.length} 个受钉文件算不出哈希：${unhashable.take(5).join("、")}'
          '——不判"清白"，改判"不可判"',
    ));
  }
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

  // ---- 条款 2 补：判据的**输入**（真值文件）不许被改 ----
  //
  // 哈希表管的是"考卷"；真值文件是**判据的分母**，此前进不了任何检查。
  // 这里判的不是整文件哈希，而是**数值叶逐叶比对**：
  // 合法的表述订正（整文件哈希变、数值一个没动）登记为豁免；
  // **数值动了一个就判 FAIL**。
  evidence['judgment_input_note'] = judgmentInputNote;
  evidence['judgment_input_numeric_changes'] = judgmentInputDrift;
  if (judgmentInputDrift.isNotEmpty) {
    violations.add(Violation(
      '2',
      kTruthPathForEvidence,
      '未定位',
      '判据分母（真值）相对基线被改：${judgmentInputDrift.take(5).join("；")}'
          '${judgmentInputDrift.length > 5 ? " …共 ${judgmentInputDrift.length} 处" : ""}',
    ));
  }

  return <String, dynamic>{
    'baseline': baseline,
    'violations': violations.map((Violation v) => v.toJson()).toList(),
    'clean': violations.isEmpty,
    // 巡检自己有没有判不了的地方。非空时**不得**当清白——由 AC 条目
    // 显式报"不可判"。这是本轮反复出现的同一形态的最后一处：
    // 仪表看不见对象时，必须说"我看不见"，而不是说"没有"。
    'undecidable': undecidable,
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
