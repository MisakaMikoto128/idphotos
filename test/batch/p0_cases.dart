/// 从 `out/P0_truth.json` 构建成片台要跑的样本清单，并**统一路径口径**。
///
/// 存在的理由：truth 文件里各语料的 path 格式**并不统一**——`anchors`/`straight`
/// 一直是绝对路径，`uprightSynthetic`/`rotated` 在 v0 里是仓库相对路径、在 v1
/// （`p0_finalize_v1.py` 重建）里变成了绝对路径。旧代码对后两者无条件拼 `$repo`
/// 前缀，碰上 v1 就把绝对路径又拼了一遍，得到
/// `.../idPhotos/C:/Users/.../idPhotos/out/P0_anchors/p1_upright.png`。
///
/// 后果不是报错而是**静默**：87 条夹具全部落进 `missing` 分支 `continue` 掉，
/// P0.2 / P0.3a / P0.3b 会在**零样本**上"跑完"，summary 里 `crash:0` 一片祥和。
/// 这正是 ACCEPTANCE 条款 7「样本不得静默消失」禁止的那类失败。
///
/// 抽成独立文件是为了让 `p0_resolve_check.dart` 能用**同一份实现**、
/// 不花 17 分钟就能验证"全部样本都解析得到"。
library;

class P0Case {
  final String id;
  final String path;
  final double truthTiltDeg;
  final String corpus;

  const P0Case(this.id, this.path, this.truthTiltDeg, this.corpus);

  /// **正交**于 [corpus] 的来源判别字段，专供 P0.2 取样本。
  ///
  /// 为什么不复用 `corpus`：覆盖率台把 `uprightSynthetic` 也归进 `corpus: 'anchor'`
  /// （键名 `anchor_${id}`），所以 `byCorpus` **分不出 P0.2 的竖直样本**。
  /// 但改 `corpus` 会让 r1↔r2 的分布结构无端变形，在差分里造出一堆**并非代码变化**的
  /// "变化"，违反"判决输入不得混入非被测变化"。所以原字段保持不动，另加这一个。
  ///
  /// 根因是**用一个为别的目的造的字段去判另一件事**：`corpus` 回答的是"这张图属于
  /// 哪批素材"，P0.2 问的是"它是不是合成竖直样本"。和 `ok == cases` 是同一类错误。
  String? get synthetic => switch (corpus) {
        'uprightSynthetic' => 'upright',
        'rotated' => 'rotated',
        _ => null,
      };
}

/// 已是绝对路径则原样用，否则相对 **[repo]**（仓库根，不是 cwd）解析。
String resolvePath(String p, String repo, String sep) {
  final q = p.replaceAll('/', sep);
  if (q.length > 1 && q[1] == ':') return q; // Windows 盘符
  if (q.startsWith(sep)) return q; // POSIX 绝对
  return '$repo$sep$q';
}

/// 按 truth 文件里的四个语料构造成片台清单。
/// **顺序即优先级**：同 id 后写覆盖先写，与旧实现的 `add()` 语义一致。
List<P0Case> buildCases(Map<String, dynamic> truth,
    {required String repo, required String sep}) {
  final out = <P0Case>[];
  void take(String corpus, String truthKey, String field) {
    for (final a in (truth[truthKey] as List? ?? const <dynamic>[])) {
      final m = a as Map<String, dynamic>;
      out.add(P0Case(
        m['id'] as String,
        resolvePath(m['path'] as String, repo, sep),
        (m[field] as num).toDouble(),
        corpus,
      ));
    }
  }

  take('anchor', 'anchors', 'trueRollDeg');
  take('straight', 'straight', 'trueRollDeg');
  take('uprightSynthetic', 'uprightSynthetic', 'trueRollDeg');
  take('rotated', 'rotated', 'expectedTiltDeg');
  return out;
}
