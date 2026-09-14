/// 纸纹与绒布的程序化绘制。
///
/// RUBRIC R1：纸面要有**纤维感**（随机方向的短纤维 + 斑驳），
/// 绒布要有**绒毛的密集短绒**而不是一块平涂绿。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:typed_data';
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

    // 3. 纤维截面噪点：像素级的明暗斑点。RUBRIC R1 要求绒布有颗粒——
    //    只有第 2 步的大色斑时，60×60 局部亮度 std 仅 ~1.1，肉眼看到的是
    //    "平滑喷渐变"而不是织物（visual-critic 两轮实测）。
    //    约束：
    //    * 斑点颜色只能从绒布基色向 woodDark / creamText 两个方向 lerp，
    //      合成后每像素偏离基色的亮度 ~±10，不会出现接近 #000/#FFF 的像素
    //      （G2C.4 纯黑纯白预算），与最近色卡 token 的 ΔE00 仍远小于 12
    //      （G2C.2 色卡覆盖率）；
    //    * 第 5 步的径向暗角画在噪点**之后**，大尺度明暗（左上受光）不被破坏，
    //      局部 std 达标的同时保留整体光影（RUBRIC R2）。
    //    用 drawPoints 一次提交全部斑点：逐笔 drawRect 在 ~1080×820 的台面上
    //    要发 15 万+ 次调用，drawPoints 只发 2 次（明/暗各一支笔）。
    final int spkN = (rect.width * rect.height / 4.5).clamp(120, 300000).floor();
    final Color spkDark = Color.lerp(T.feltGreen, T.woodDark, 0.75)!;
    final Float32List spkLight = Float32List(spkN * 2);
    final Float32List spkDeep = Float32List(spkN * 2);
    int nL = 0;
    int nD = 0;
    for (int i = 0; i < spkN; i++) {
      final Float32List arr =
          hash2(seed + i, 31) > 0.55 ? spkLight : spkDeep;
      final int o = (identical(arr, spkLight) ? nL : nD) * 2;
      arr[o] = rect.left + rect.width * hash2(seed + i, 33);
      arr[o + 1] = rect.top + rect.height * hash2(seed + i, 37);
      if (identical(arr, spkLight)) {
        nL++;
      } else {
        nD++;
      }
    }
    _paintSpecks(canvas, spkLight, nL, lift, 0.46);
    _paintSpecks(canvas, spkDeep, nD, spkDark, 0.56);

    // 4. 绒毛：密集的短绒，方向略偏（顺毛）。同样批量提交。
    final int napN = (rect.width * rect.height / 42).clamp(40, 9000).floor();
    final Float32List napUp = Float32List(napN * 4);
    final Float32List napDn = Float32List(napN * 4);
    int nU = 0;
    int nDn = 0;
    for (int i = 0; i < napN; i++) {
      final bool isUp = hash2(seed + i, 23) > 0.5;
      final Float32List arr = isUp ? napUp : napDn;
      final int o = (isUp ? nU : nDn) * 4;
      final double x = rect.left + rect.width * hash2(seed + i, 21);
      final double y = rect.top + rect.height * hash2(seed + i, 22);
      arr[o] = x;
      arr[o + 1] = y;
      arr[o + 2] = x + 0.5;
      arr[o + 3] = y + 1.2 + 1.4 * hash2(seed + i, 41);
      if (isUp) {
        nU++;
      } else {
        nDn++;
      }
    }
    _paintNap(canvas, napUp, nU, lift, 0.20);
    _paintNap(canvas, napDn, nDn, deep, 0.24);

    // 5. 台面暗角
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

/// 一支笔批量画 [count] 个圆点（坐标在 [pts] 前 `count*2` 个元素里）。
/// 绒布噪点/绒毛的全部几何在 [FeltPainter.paint] 里一次算完，每种颜色只发
/// **一次** `drawPoints` —— 这是数量级层面的性能差别，不是微优化。
void _paintSpecks(
  Canvas canvas,
  Float32List pts,
  int count,
  Color color,
  double alpha,
) {
  if (count == 0) return;
  canvas.drawRawPoints(
    ui.PointMode.points,
    Float32List.sublistView(pts, 0, count * 2),
    Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3
      ..color = color.withValues(alpha: alpha),
  );
}

/// 一支笔批量画 [count] 条短线段（每条 2 个端点，`count*4` 个元素）。
void _paintNap(
  Canvas canvas,
  Float32List pts,
  int count,
  Color color,
  double alpha,
) {
  if (count == 0) return;
  canvas.drawRawPoints(
    ui.PointMode.lines,
    Float32List.sublistView(pts, 0, count * 4),
    Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.8
      ..color = color.withValues(alpha: alpha),
  );
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
