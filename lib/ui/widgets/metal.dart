/// 金属构件的 widget 封装：铜板、铭牌、包角。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import '../theme/brass.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// 一块金属板。
class MetalPlate extends StatelessWidget {
  final MetalFinish finish;
  final BorderRadius radius;
  final bool pressed;
  final bool screws;
  final bool shadow;
  final int seed;
  final EdgeInsetsGeometry? padding;
  final Widget? child;

  const MetalPlate({
    super.key,
    this.finish = MetalFinish.brass,
    this.radius = Shape.buttonBorder,
    this.pressed = false,
    this.screws = false,
    this.shadow = true,
    this.seed = 9,
    this.padding,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = CustomPaint(
      painter: MetalPlatePainter(
        finish: finish,
        radius: radius,
        pressed: pressed,
        screws: screws,
        seed: seed,
      ),
      isComplex: true,
      willChange: false,
      child: padding == null
          ? (child ?? const SizedBox.expand())
          : Padding(padding: padding!, child: child ?? const SizedBox()),
    );
    content = RepaintBoundary(child: content);
    if (!shadow) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: pressed ? Shade.pressed : Shade.lifted,
      ),
      child: content,
    );
  }
}

/// 黄铜铭牌：候选相框下方刻底色名的那一小块（DESIGN.md §5 区域 B）。
///
/// 文字用 [T.inkBrown] 刻在亮调铜面上，实测对比度约 5.6:1，满足无障碍红线。
class Nameplate extends StatelessWidget {
  final String text;

  /// 选中态：整块铭牌提亮。
  final bool highlighted;

  final double height;

  const Nameplate({
    super.key,
    required this.text,
    this.highlighted = false,
    this.height = 26,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MetalPlate(
            finish: MetalFinish.brass,
            radius: const BorderRadius.all(Radius.circular(3)),
            shadow: false,
            seed: text.hashCode & 0xFF,
          ),
          if (!highlighted)
            // 未选中只压一层很薄的暗。实测再重一点（0x33）铜面平均亮度会掉到
            // L≈0.277，与 inkBrown 的对比度只有 4.20:1，低于无障碍红线 4.5:1
            // （RUBRIC 致命项 4）。0x1A 时是 5.03:1。
            const DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(3)),
                color: Color(0x1A241609),
              ),
            ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: EngravedText(
                text,
                style: Type.plate(T.inkBrown),
                relief: T.brassHi,
                maxLines: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 相框四角的铜包角。
class BrassCorners extends StatelessWidget {
  final double arm;
  final bool highlight;
  final Widget child;

  const BrassCorners({
    super.key,
    this.arm = 30,
    this.highlight = false,
    required this.child,
  });

  Widget _corner(Alignment a) => Align(
        alignment: a,
        child: SizedBox(
          width: arm + 4,
          height: arm + 4,
          child: CustomPaint(
            painter: BrassCornerPainter(
                corner: a, arm: arm, highlight: highlight),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        Positioned.fill(child: _corner(Alignment.topLeft)),
        Positioned.fill(child: _corner(Alignment.topRight)),
        Positioned.fill(child: _corner(Alignment.bottomLeft)),
        Positioned.fill(child: _corner(Alignment.bottomRight)),
      ],
    );
  }
}
