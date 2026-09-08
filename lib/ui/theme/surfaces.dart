/// 复合材质构件：木质面板、倒角、刻字/浮雕文字。
///
/// DESIGN.md §3：所有木质面板用双层边框 —— 外 1px `woodDark`，内 1px `woodLight`
/// （模拟倒角）。这里在此基础上按全局光源（左上）调制：上/左的内边亮，
/// 下/右的内边暗，否则倒角会显得"两侧一样亮"，穿帮（RUBRIC R2）。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import 'tokens.dart';
import 'typography.dart';
import 'wood_painter.dart';

/// 双层倒角边框。画在内容之上（`foregroundPainter`）。
class BevelPainter extends CustomPainter {
  final BorderRadius radius;

  /// true = 凸起（上/左亮），false = 凹陷（上/左暗）。
  final bool raised;

  final Color light;
  final Color dark;
  final double strength;

  const BevelPainter({
    this.radius = Shape.panelBorder,
    this.raised = true,
    this.light = T.woodLight,
    this.dark = T.woodDark,
    this.strength = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    final Color tl = raised ? light : dark;
    final Color br = raised ? dark : light;

    // 外框：1px woodDark，把构件从底上切出来
    canvas.drawRRect(
      radius.toRRect(rect).deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark.withValues(alpha: 0.92 * strength),
    );

    // 内框：分上/左与下/右两段
    final Rect inner = rect.deflate(1.5);
    final double r = (radius.topLeft.x - 1.5).clamp(0.0, 999.0);
    canvas.save();
    canvas.clipRRect(
        BorderRadius.circular(r + 1).toRRect(rect.deflate(1.0)));
    canvas.drawPath(
      Path()
        ..moveTo(inner.left, inner.bottom - r)
        ..lineTo(inner.left, inner.top + r)
        ..arcToPoint(Offset(inner.left + r, inner.top),
            radius: Radius.circular(r))
        ..lineTo(inner.right - r, inner.top),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = tl.withValues(alpha: 0.85 * strength),
    );
    canvas.drawPath(
      Path()
        ..moveTo(inner.left + r, inner.bottom)
        ..lineTo(inner.right - r, inner.bottom)
        ..arcToPoint(Offset(inner.right, inner.bottom - r),
            radius: Radius.circular(r))
        ..lineTo(inner.right, inner.top + r),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = br.withValues(alpha: 0.75 * strength),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(BevelPainter old) =>
      old.radius != radius ||
      old.raised != raised ||
      old.light != light ||
      old.dark != dark ||
      old.strength != strength;
}

/// 木质面板：木纹 + 双层倒角 + 暖色投影。App 里所有"一块木头"都用它。
class WoodPanel extends StatelessWidget {
  final WoodSpec spec;
  final Offset grainOrigin;
  final BorderRadius radius;
  final EdgeInsetsGeometry? padding;
  final bool raised;
  final bool shadow;
  final Widget? child;

  const WoodPanel({
    super.key,
    this.spec = const WoodSpec(),
    this.grainOrigin = Offset.zero,
    this.radius = Shape.panelBorder,
    this.padding,
    this.raised = true,
    this.shadow = true,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = ClipRRect(
      borderRadius: radius,
      child: CustomPaint(
        painter: WoodPainter(spec, origin: grainOrigin),
        foregroundPainter: BevelPainter(radius: radius, raised: raised),
        isComplex: true,
        willChange: false,
        child: padding == null
            ? (child ?? const SizedBox.expand())
            : Padding(padding: padding!, child: child ?? const SizedBox()),
      ),
    );
    content = RepaintBoundary(child: content);
    if (!shadow) return content;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: Shade.lifted),
      child: content,
    );
  }
}

/// 刻字：深色字 + 下方 1px 亮线（阳刻/浮雕），或反过来（阴刻）。
///
/// 这是复古金属件上文字的关键细节；纯平文字会立刻显出"现代 App"的味道
/// （RUBRIC R4）。
class EngravedText extends StatelessWidget {
  final String text;
  final TextStyle style;

  /// 浮雕高光色（凸起时在字下方，凹陷时在字上方）。
  final Color relief;

  /// true = 阳刻（字凸起），false = 阴刻（字凹进去）。
  final bool raised;

  final TextAlign align;
  final int? maxLines;

  const EngravedText(
    this.text, {
    super.key,
    required this.style,
    this.relief = T.brassHi,
    this.raised = true,
    this.align = TextAlign.center,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final Offset off = raised ? const Offset(0, 1) : const Offset(0, -1);
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Transform.translate(
          offset: off,
          child: Text(
            text,
            style: style.copyWith(color: relief.withValues(alpha: 0.55)),
            textAlign: align,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
          ),
        ),
        Text(
          text,
          style: style,
          textAlign: align,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 一条木纹分隔线（区域之间的物理接缝，RUBRIC R5 要求区域可辨）。
class SeamDivider extends StatelessWidget {
  final double height;

  const SeamDivider({super.key, this.height = 7});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(painter: const _SeamPainter()),
    );
  }
}

class _SeamPainter extends CustomPainter {
  const _SeamPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = T.woodDark);
    canvas.drawLine(
      Offset(r.left, r.top + 0.5),
      Offset(r.right, r.top + 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = T.woodLight.withValues(alpha: 0.35),
    );
    canvas.drawLine(
      Offset(r.left, r.bottom - 0.5),
      Offset(r.right, r.bottom - 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = T.woodLight.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(_SeamPainter old) => false;
}

/// 纸条便签上的一行小字（保存成功反馈用）。
TextStyle get slipTextStyle => Type.small(T.inkBrown);
