/// 字体：Noto Serif SC 子集。
///
/// DESIGN.md §4 要求中文用宋体系（Noto Serif SC），字重仅 400 / 700，
/// 且 G2C.8 要求 `assets/fonts/` 总计 ≤ 400 KB —— 全量 CJK 字体 10 MB+，
/// 因此仓库里只放**子集**。
///
/// ## 子集的产生方式（可复现，全程离线）
///
/// 源文件是本机系统自带的 `C:\Windows\Fonts\NotoSerifSC-VF.ttf`（Google Noto，
/// SIL OFL 1.1，可自由再分发），**没有联网下载**。用本机已装的 fontTools
/// 先把可变字体在 `wght=400` / `wght=700` 上实例化，再按 [coveredCharset]
/// 做 `pyftsubset`，产出：
///
/// * `assets/fonts/NotoSerifSC-Subset-Regular.ttf`
/// * `assets/fonts/NotoSerifSC-Subset-Bold.ttf`
///
/// [coveredCharset] 是由 `lib/ui/dev/charset_scan.dart` 从 **`lib/` 全部**
/// 字符串字面量（含插值内文案）里抽取后再加常用标点得到的，**新增界面文案时
/// 必须重新跑该扫描器并重新子集化**，否则会出豆腐块（RUBRIC 致命项 6）。
///
/// ## 为什么用 [FontLoader] 而不是 pubspec 的 `fonts:` 段
///
/// `pubspec.yaml` 归主会话独占（CLAUDE.md §7.5），ui-woodcraft 不能自行加
/// `fonts:` 声明。`assets/fonts/` 已被声明为资源目录，所以这里在启动时用
/// `FontLoader` 从 `rootBundle` 注册同名字体族，效果等价。
/// 已在报告里请求主会话补上 `fonts:` 段，补上后本文件的加载逻辑仍然幂等安全。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 字体加载状态。字体就绪后 `value` 变为 true，UI 监听它重建一次。
final ValueNotifier<bool> muZhaoFontsReady = ValueNotifier<bool>(false);

/// 数字与英文（尺寸标注）也用同一族衬线体：DESIGN.md §4 要求"等宽衬线或
/// Courier-like"，本机离线可得的开源等宽衬线体不存在，改用 Noto Serif SC 的
/// 拉丁字形 + `letterSpacing` 模拟打字机间距，避免引入来源不明的字体文件。
abstract final class MuZhaoFonts {
  static const String family = 'MuZhaoSerif';

  static const String _regularAsset =
      'assets/fonts/NotoSerifSC-Subset-Regular.ttf';
  static const String _boldAsset = 'assets/fonts/NotoSerifSC-Subset-Bold.ttf';

  static Future<void>? _pending;

  /// 幂等：多次调用只加载一次。
  static Future<void> ensureLoaded() {
    return _pending ??= _load();
  }

  /// 加载失败的原因（资源被裁剪、测试环境无 asset bundle 等）。
  /// 非 null 时界面降级到系统衬线体，不影响功能。
  static Object? loadError;

  static Future<void> _load() async {
    try {
      final FontLoader loader = FontLoader(family)
        ..addFont(rootBundle.load(_regularAsset))
        ..addFont(rootBundle.load(_boldAsset));
      await loader.load();
      muZhaoFontsReady.value = true;
    } on Object catch (e) {
      // 不吞异常：记下原因，界面用 fontFamilyFallback 降级到系统衬线。
      loadError = e;
      debugPrint('MuZhaoFonts: 子集字体加载失败，降级到系统衬线体 — $e');
    }
  }

  /// 子集覆盖的**非 ASCII**字符，共 384 个；此外还包含全部 ASCII 可见字符
  /// U+0020–U+007E，合计 479 个。
  ///
  /// 这份清单由 `lib/ui/dev/charset_scan.dart`（真正的 Dart 字符串字面量
  /// 扫描器，能正确处理插值 / 转义 / 三引号 / 原始字符串）对 **`lib/` 全部
  /// 源码**自动汇总得到 —— 新增界面文案后必须重新跑一遍
  /// `dart run lib/ui/dev/charset_scan.dart` 并同步这里，否则新字会变成
  /// 豆腐块（RUBRIC 致命项 6）。跑完记得用 fontTools 重新子集化。
  ///
  /// 已知例外：U+21B3（↳）在 Noto Serif SC 源字体里就没有这个字形，离线无法
  /// 补上；它只出现在 `lib/core/imaging/dev_selfcheck.dart` 的控制台日志里，
  /// UI 从不渲染，运行期也不会走到字体回退，故保留在字符表中不作为缺字。
  static const String coveredCharset =
      '°±·×–—‘’“”…←→↳−≈、。《》一七上下不与两个中串为主乘了二于些'
      '人从件但住体何余使例供侧保信候值偏像允先入全共关其内册再写冲几出分判到前剪力'
      '加动勿化区单占卡原去反发取受变口可台合同后向否吧含呀品哦啦嗯四回围图在场域填'
      '处备外多大太失头好子字存守安完定实宽寂寞寸对小少尺居差已布常平应底度开异式张'
      '归当录形径待心总恒息想慢成截户手打扫找抛抠抱拖择持按挑换探接描提摄摆支收改效'
      '数整文新旋无时明是景暂更最有望期木未本机权条来松极析标根格框检次款歉正死残段'
      '比毫水没法注洗浅测消深渐渗溢灰点照片独献现理用画界留略白的盖目相看真知矩码确'
      '社禁离种程稍立端符等签米系素红级纯线细绝统继续绿缩缺据置美者肤能脚脸自色范蓝行'
      '表衬被裁覆见规角解触计认记许设访试误说请读调贡败质贴超越路身转轮轻载输边过运'
      '这退选逐造道部里量金针锁错长门闭问阈阶降限集青非面顶项颜验高黄黑！％（），：'
      '；？￥　';
}

/// 在子树挂载时触发一次字体加载。
///
/// **不阻塞首帧** —— 首帧用系统衬线兜底渲染（Android 自带 Noto CJK，
/// 不会出豆腐块），字体就绪后引擎会广播 `fontsChange` 并自动重排全部文本，
/// 无需手动 `setState`。这样截图流水线的 `pumpAndSettle()` 不会因为等一个
/// Future 而截到空白帧。
class FontGate extends StatefulWidget {
  final Widget child;

  const FontGate({super.key, required this.child});

  @override
  State<FontGate> createState() => _FontGateState();
}

class _FontGateState extends State<FontGate> {
  @override
  void initState() {
    super.initState();
    MuZhaoFonts.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
