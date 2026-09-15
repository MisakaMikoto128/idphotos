/// 木照 MuZhao — compose 路径大缓冲记账（开发期工装，不进发布逻辑）。
///
/// ## 用途
///
/// G4 r5 的 4.7 归因：+65.6MB 瞬态（Private Other）发生在 compose 段，但
/// memdump 的细粒度行看不到单一来源。本工装在 compose 全链路每个 >4MB 级的
/// 分配点挂一个 [ImagingLedger.alloc]/[ImagingLedger.free]，按 tag 记账，
/// 回答三个问题：
///
/// 1. **谁**：每个 tag 的分配点（源码位置见各 hook 处注释）；
/// 2. **多大**：精确字节数（w×h×通道数的解析值，非采样估计）；
/// 3. **存续期**：`live` 曲线 —— 行级/块级（strip 内一次合成就释放）还是
///    整项（从首次合成活到换图失效）。
///
/// ## 纪律
///
/// - `enabled` 默认 false，生产路径只有一次布尔判断，行为零影响；
/// - hook 只记字节数，**不持有缓冲引用**（绝不能把待释放的内存钉住）；
/// - alloc/free 必须成对出现在同一条代码路径上；漏 free 只会让账本说谎，
///   不会影响像素（这也是它敢进发布文件的原因）。
///
/// 消费方：`dev_compose_memprofile.dart`（host 内存剖面）；
/// `dev_pool_audit.dart` 继续负责 WorkBufferPool 驻留审计，两者口径不同。
library;

/// 大缓冲记账本。见文件文档。
class ImagingLedger {
  ImagingLedger._();

  /// 是否记账。默认关闭；剖面工具打开，跑完自行关闭。
  static bool enabled = false;

  static final Map<String, int> _live = <String, int>{};
  static final Map<String, int> _peak = <String, int>{};
  static final Map<String, int> _allocs = <String, int>{};

  static int _liveTotal = 0;
  static int _peakTotal = 0;

  /// 记一笔分配。
  static void alloc(String tag, int bytes) {
    if (!enabled) {
      return;
    }
    _live[tag] = (_live[tag] ?? 0) + bytes;
    _allocs[tag] = (_allocs[tag] ?? 0) + 1;
    if (_live[tag]! > (_peak[tag] ?? 0)) {
      _peak[tag] = _live[tag]!;
    }
    _liveTotal += bytes;
    if (_liveTotal > _peakTotal) {
      _peakTotal = _liveTotal;
    }
  }

  /// 记一笔释放（或转入不再计入的存续状态，如进池驻留）。
  static void free(String tag, int bytes) {
    if (!enabled) {
      return;
    }
    _live[tag] = (_live[tag] ?? 0) - bytes;
    _liveTotal -= bytes;
  }

  /// 清账（每轮剖面开始前调用）。
  static void reset() {
    _live.clear();
    _peak.clear();
    _allocs.clear();
    _liveTotal = 0;
    _peakTotal = 0;
  }

  /// 当前在账字节数。
  static int get liveTotal => _liveTotal;

  /// 累计峰值字节数（所有 tag 之和的峰值，非各 tag 峰值简单相加）。
  static int get peakTotal => _peakTotal;

  /// 各 tag：当前在账 / 峰值 / 分配次数。
  static Map<String, List<int>> snapshot() {
    final Map<String, List<int>> out = <String, List<int>>{};
    for (final String tag in _peak.keys) {
      out[tag] = <int>[_live[tag] ?? 0, _peak[tag] ?? 0, _allocs[tag] ?? 0];
    }
    return out;
  }

  /// 人类可读报表（live / peak / 次数），按 peak 降序。
  static String report() {
    final StringBuffer b = StringBuffer();
    b.writeln('ledger live=$_liveTotal peak=$_peakTotal');
    final List<MapEntry<String, List<int>>> rows = snapshot().entries.toList()
      ..sort((a, b) => b.value[1].compareTo(a.value[1]));
    for (final MapEntry<String, List<int>> e in rows) {
      b.writeln(
        '  ${e.key.padRight(28)} '
        'live=${e.value[0]} peak=${e.value[1]} n=${e.value[2]}',
      );
    }
    return b.toString();
  }
}
