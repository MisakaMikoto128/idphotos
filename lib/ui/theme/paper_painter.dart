/// 纸纹与绒布的程序化绘制。
///
/// RUBRIC R1：纸面要有**纤维感**（随机方向的短纤维 + 斑驳），
/// 绒布要有**绒毛的密集短绒**而不是一块平涂绿。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'noise.dart';
import 'tokens.dart';


/// 画一批边缘柔和的色斑。
///
/// 用径向渐变的圆代替"逐格子画方块"：格子写法在相邻格之间必然出现色阶，
/// 在截图里看起来像块效应，是"平涂假装材质"的典型翻车方式（RUBRIC R1）。
void _paintBlobs(
  Canvas canvas,
  Rect rect, {
  required int seed,
  required double density,
  required double minR,
  required double maxR,
  required Color dark,
  required Color light,
  required double alpha,
}) {
  // 半径按表面短边缩放：同一组常量画在 150px 的小卡片和 800px 的大面板上，
  // 视觉密度才一致（固定半径会让小卡片上出现几块显眼的大斑）。
  final double k = (math.min(rect.width, rect.height) / 320).clamp(0.30, 1.6);
  final int n = (rect.width * rect.height / (density * k * k))
      .clamp(6, 600)
      .floor();
  for (int i = 0; i < n; i++) {
    final double x = rect.left + rect.width * hash2(seed + i, 101);
    final double y = rect.top + rect.height * hash2(seed + i, 103);
    final double r = (minR + (maxR - minR) * hash2(seed + i, 107)) * k;
    final bool isDark = hash2(seed + i, 109) < 0.5;
    final double a = alpha * (0.35 + 0.65 * hash2(seed + i, 113));
    final Color c = isDark ? dark : light;
    canvas.drawCircle(
      Offset(x, y),
      r,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(x, y),
          r,
          <Color>[c.withValues(alpha: a), c.withValues(alpha: 0.0)],
          <double>[0.0, 1.0],
        ),
    );
  }
}

/// 相纸/卡纸表面。
class PaperPainter extends CustomPainter {
  final int seed;

  /// 边缘压暗强度（0 = 不压）。做旧的纸四周会发黄发暗。
  final double edgeDarken;

  const PaperPainter({this.seed = 3, this.edgeDarken = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);

    // 1. 底：paper → paperEdge 的极缓渐变，左上受光
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          <Color>[T.paper, Color.lerp(T.paper, T.paperEdge, 0.45)!],
        ),
    );

    // 2. 斑驳：一堆边缘柔和的色斑，模拟纸浆密度不均。
    //    **不要用"按格子画方块"的写法** —— 相邻格子之间会留下肉眼可见的
    //    棋盘状色阶，截图里像 JPEG 块效应（见 docs/PITFALLS.md）。
    _paintBlobs(
      canvas,
      rect,
      seed: seed * 13,
      density: 2600,
      minR: 14,
      maxR: 46,
      dark: T.paperEdge,
      light: T.paper,
      alpha: 0.30,
    );

    // 3. 纤维：随机方向的极细短线。方向不统一 —— 这正是纸与木的区别。
    final int fibers = (rect.width * rect.height / 260).clamp(20, 1600).floor();
    final Paint fib = Paint()..strokeCap = StrokeCap.round;
    for (int i = 0; i < fibers; i++) {
      final double x = rect.left + rect.width * hash2(seed + i, 11);
      final double y = rect.top + rect.height * hash2(seed + i, 12);
      final double ang = hash2(seed + i, 13) * math.pi * 2;
      final double len = 1.6 + 5.4 * hash2(seed + i, 14);
      final bool dark = hash2(seed + i, 15) > 0.42;
      fib
        ..strokeWidth = 0.55 + 0.35 * hash2(seed + i, 16)
        ..color = (dark ? T.inkFaded : T.paper)
            .withValues(alpha: dark ? 0.10 : 0.30);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + math.cos(ang) * len, y + math.sin(ang) * len),
        fib,
      );
    }

    // 4. 边缘做旧
    if (edgeDarken > 0) {
      final double inset = math.min(rect.width, rect.height) * 0.30;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            rect.center,
            math.max(rect.width, rect.height) * 0.72,
            <Color>[
              T.paperEdge.withValues(alpha: 0.0),
              T.paperEdge.withValues(alpha: 0.55 * edgeDarken),
            ],
            <double>[0.55, 1.0],
          )
          ..blendMode = BlendMode.srcOver,
      );
      // 四边一圈更实的旧痕
      canvas.drawRect(
        rect.deflate(inset * 0.02),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = T.paperEdge.withValues(alpha: 0.8 * edgeDarken),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperPainter old) =>
      old.seed != seed || old.edgeDarken != edgeDarken;
}

/// 台面绒布（区域 B 衬底，DESIGN.md §5）。
class FeltPainter extends CustomPainter {
  final int seed;

  const FeltPainter({this.seed = 5});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);

    final Color deep = Color.lerp(T.feltGreen, T.woodDark, 0.42)!;
    final Color lift = Color.lerp(T.feltGreen, T.creamText, 0.16)!;

    // 1. 底 + 左上受光
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          <Color>[
            Color.lerp(T.feltGreen, lift, 0.35)!,
            T.feltGreen,
            Color.lerp(T.feltGreen, deep, 0.55)!,
          ],
          <double>[0.0, 0.5, 1.0],
        ),
    );

    // 2. 云状起绒：柔边色斑（同样不能用格子方块，会出棋盘格）
    _paintBlobs(
      canvas,
      rect,
      seed: seed * 7,
      density: 3400,
      minR: 22,
      maxR: 70,
      dark: deep,
      light: lift,
      alpha: 0.26,
    );

    // 3. 绒毛：极密的短点，方向略偏（顺毛）
    final int n = (rect.width * rect.height / 42).clamp(40, 9000).floor();
    final Paint nap = Paint()..strokeCap = StrokeCap.round;
    for (int i = 0; i < n; i++) {
      final double x = rect.left + rect.width * hash2(seed + i, 21);
      final double y = rect.top + rect.height * hash2(seed + i, 22);
      final bool up = hash2(seed + i, 23) > 0.5;
      nap
        ..strokeWidth = 0.7
        ..color = (up ? lift : deep).withValues(alpha: up ? 0.12 : 0.16);
      canvas.drawLine(Offset(x, y), Offset(x + 0.5, y + 1.6), nap);
    }

    // 4. 台面暗角
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height).center,
          math.max(rect.width, rect.height) * 0.75,
          <Color>[
            deep.withValues(alpha: 0.0),
            deep.withValues(alpha: 0.45),
          ],
          <double>[0.45, 1.0],
        ),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(FeltPainter old) => old.seed != seed;
}

/// 纸面容器。
class PaperSurface extends StatelessWidget {
  final int seed;
  final double edgeDarken;
  final BorderRadius? radius;
  final Widget? child;

  const PaperSurface({
    super.key,
    this.seed = 3,
    this.edgeDarken = 1.0,
    this.radius,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final Widget painted = RepaintBoundary(
      child: CustomPaint(
        painter: PaperPainter(seed: seed, edgeDarken: edgeDarken),
        isComplex: true,
        willChange: false,
        child: child ?? const SizedBox.expand(),
      ),
    );
    if (radius == null) return painted;
    return ClipRRect(borderRadius: radius!, child: painted);
  }
}

/// 绒布台面。
class FeltSurface extends StatelessWidget {
  final int seed;
  final Widget? child;

  const FeltSurface({super.key, this.seed = 5, this.child});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: FeltPainter(seed: seed),
        isComplex: true,
        willChange: false,
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}
