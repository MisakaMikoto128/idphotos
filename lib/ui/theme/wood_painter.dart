/// 木纹程序化绘制。
///
/// DESIGN.md §2 允许用 `CustomPainter` 代替贴图（体积为 0、可缩放）。
/// RUBRIC R1 要求木纹**有方向性和层次**，不是一层均匀噪点；
/// 致命项 3 要求全 App 木纹**方向与尺度一致** —— 因此：
///
/// * 纹理方向恒为**竖直**（[kGrainScale] 是唯一的横向节距，全 App 共用）；
/// * 每块木料只用 `seed` 改变年轮相位，不改方向、不改尺度；
/// * 层次自下而上共 5 层：底色渐变 → 宽窄区色带 → 年轮明暗对线 → 弦切山形纹
///   → 导管孔（棕眼）→ 左上光照扫光。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'noise.dart';
import 'tokens.dart';

/// 全 App 统一的年轮节距（逻辑像素）。**任何木质表面都用这个值**，
/// 改了会让不同区域的木纹尺度不一致（RUBRIC 致命项 3）。
const double kGrainScale = 22.0;

/// 木料的明暗调门。三档都由 DESIGN.md §1 的三个木色 token 线性插值得到，
/// 不引入新色值。
enum WoodTone {
  /// 最深，用于外框、区域间的结构件。
  dark,

  /// 主背景。
  base,

  /// 较亮，用于抽屉面板、抬起的构件。
  light,
}

/// 一块木料的绘制参数。
@immutable
class WoodSpec {
  final WoodTone tone;
  final int seed;

  /// 是否绘制弦切山形纹（大面积木板才有；细木条上画会显脏）。
  final bool figure;

  const WoodSpec({
    this.tone = WoodTone.base,
    this.seed = 7,
    this.figure = true,
  });
}

/// 木纹画笔。
class WoodPainter extends CustomPainter {
  final WoodSpec spec;

  /// 本块木料在全局坐标系中的位置。传入后，相邻木件的年轮不会在拼接处突变。
  final Offset origin;

  const WoodPainter(this.spec, {this.origin = Offset.zero});

  Color get _mid => switch (spec.tone) {
        WoodTone.dark => Color.lerp(T.woodBase, T.woodDark, 0.62)!,
        WoodTone.base => T.woodBase,
        WoodTone.light => Color.lerp(T.woodBase, T.woodLight, 0.34)!,
      };

  Color get _lo => Color.lerp(_mid, T.woodDark, 0.55)!;
  Color get _hi => Color.lerp(_mid, T.woodLight, 0.62)!;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);

    _paintBase(canvas, rect);
    _paintTonalBands(canvas, rect);
    if (spec.figure) _paintFigure(canvas, rect);
    _paintRings(canvas, rect);
    _paintPores(canvas, rect);
    _paintLight(canvas, rect);

    canvas.restore();
  }

  /// 第 1 层：底色。竖直方向轻微渐变，模拟木板受光不均。
  void _paintBase(Canvas canvas, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomLeft,
          <Color>[
            Color.lerp(_mid, T.woodLight, 0.10)!,
            _mid,
            Color.lerp(_mid, T.woodDark, 0.16)!,
          ],
          <double>[0.0, 0.55, 1.0],
        ),
    );
  }

  /// 第 2 层：宽窄区色带。低频、沿 x 缓慢起伏，让整块板有"早材/晚材"的分区，
  /// 而不是一片均匀底色。
  ///
  /// 实现上用**一个多停靠点的横向渐变**而不是一根根画竖条 —— 画竖条会在
  /// 相邻条之间留下肉眼可见的色阶（第一版就是这么翻车的，见 PITFALLS）。
  void _paintTonalBands(Canvas canvas, Rect rect) {
    const int stops = 48;
    final List<Color> colors = <Color>[];
    final List<double> pos = <double>[];
    for (int i = 0; i <= stops; i++) {
      final double t = i / stops;
      final double gx = (rect.left + rect.width * t + origin.dx) /
          (kGrainScale * 5.5);
      final double k = (fbm1(gx, spec.seed * 31 + 5, octaves: 3) - 0.5) * 2;
      final Color c = k < 0
          ? Color.lerp(_mid, _lo, -k * 0.55)!
          : Color.lerp(_mid, _hi, k * 0.40)!;
      colors.add(c.withValues(alpha: 0.62));
      pos.add(t);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
            rect.topLeft, rect.topRight, colors, pos),
    );
  }

  /// 第 3 层：弦切山形纹（cathedral figure）。
  /// 这是"看起来像真木头"最关键的一层 —— 均匀噪点永远画不出这个。
  void _paintFigure(Canvas canvas, Rect rect) {
    final int n = 3 + (hash1(spec.seed * 17) * 3).floor();
    for (int f = 0; f < n; f++) {
      final double cx =
          rect.left + rect.width * hash1(spec.seed * 101 + f * 37);
      final double baseY =
          rect.top + rect.height * (0.15 + 0.8 * hash1(spec.seed * 53 + f * 91));
      final double dir = hash1(spec.seed * 71 + f) < 0.5 ? -1.0 : 1.0;
      final double h0 = rect.height * (0.18 + 0.30 * hash1(spec.seed * 13 + f));
      const int arcs = 7;
      for (int a = 0; a < arcs; a++) {
        final double t = a / (arcs - 1);
        final double w = kGrainScale * (0.7 + 2.9 * t);
        final double h = h0 * (0.45 + 0.95 * t);
        final Path path = Path()
          ..moveTo(cx - w, baseY)
          ..quadraticBezierTo(cx - w * 0.62, baseY + dir * h * 1.30, cx,
              baseY + dir * h * 1.34)
          ..quadraticBezierTo(
              cx + w * 0.62, baseY + dir * h * 1.30, cx + w, baseY);
        final bool darkLine = a.isEven;
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = darkLine ? 2.2 : 1.3
            ..strokeCap = StrokeCap.round
            ..color = (darkLine ? _lo : _hi)
                .withValues(alpha: darkLine ? 0.42 : 0.24),
        );
      }
    }
  }

  /// 第 4 层：年轮。竖直走向的明暗对线 —— 每条深线右侧紧跟一条浅线，
  /// 这是木材"早材—晚材"交界的真实特征，也是方向性的来源。
  void _paintRings(Canvas canvas, Rect rect) {
    final double firstX =
        rect.left - (origin.dx % kGrainScale) - kGrainScale * 2;
    final int count = (rect.width / kGrainScale).ceil() + 4;
    final double sampleStep = math.max(4.0, rect.height / 90);

    for (int k = 0; k < count; k++) {
      final double jitter = (hash1(spec.seed * 401 + k) - 0.5) * kGrainScale * 0.7;
      final double x0 = firstX + k * kGrainScale + jitter;
      final int lineSeed = spec.seed * 733 + k * 17;
      // 摆幅：年轮沿板长缓慢蜿蜒，不是直线
      final double amp = kGrainScale * (0.30 + 0.55 * hash1(lineSeed + 3));
      final double waveLen = rect.height * (0.35 + 0.5 * hash1(lineSeed + 11));
      final double strength = 0.35 + 0.65 * hash1(lineSeed + 23);

      final Path dark = Path();
      final Path light = Path();
      for (double y = rect.top - sampleStep;
          y <= rect.bottom + sampleStep;
          y += sampleStep) {
        final double gy = (y + origin.dy) / waveLen;
        final double dx = amp * fbm1c(gy, lineSeed, octaves: 3);
        final double x = x0 + dx;
        if (y <= rect.top - sampleStep + 0.001) {
          dark.moveTo(x, y);
          light.moveTo(x + 2.1, y);
        } else {
          dark.lineTo(x, y);
          light.lineTo(x + 2.1, y);
        }
      }
      canvas.drawPath(
        light,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = _hi.withValues(alpha: 0.22 * strength),
      );
      canvas.drawPath(
        dark,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9 + 1.9 * strength
          ..color = _lo.withValues(alpha: 0.50 * strength),
      );
    }
  }

  /// 第 5 层：导管孔（棕眼）。极短的竖直划痕，给表面颗粒感。
  void _paintPores(Canvas canvas, Rect rect) {
    final int n = (rect.width * rect.height / 520).clamp(24, 1600).floor();
    final Paint p = Paint()..strokeCap = StrokeCap.round;
    for (int i = 0; i < n; i++) {
      final double x = rect.left + rect.width * hash2(spec.seed + i, 1);
      final double y = rect.top + rect.height * hash2(spec.seed + i, 2);
      final double len = 2 + 9 * hash2(spec.seed + i, 3);
      final double a = 0.07 + 0.18 * hash2(spec.seed + i, 4);
      p
        ..strokeWidth = 0.6 + 0.7 * hash2(spec.seed + i, 5)
        ..color = _lo.withValues(alpha: a);
      canvas.drawLine(Offset(x, y), Offset(x + 0.4, y + len), p);
    }
  }

  /// 第 6 层：左上光照（[kLightDir]）。全 App 光源方向一致（RUBRIC R2）。
  void _paintLight(Canvas canvas, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          <Color>[
            T.woodLight.withValues(alpha: 0.13),
            T.woodLight.withValues(alpha: 0.0),
            T.woodDark.withValues(alpha: 0.16),
          ],
          <double>[0.0, 0.45, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(WoodPainter old) =>
      old.spec.tone != spec.tone ||
      old.spec.seed != spec.seed ||
      old.spec.figure != spec.figure ||
      old.origin != origin;
}

/// 一块木料表面。内部带 `RepaintBoundary`，纹理只栅格化一次。
class WoodSurface extends StatelessWidget {
  final WoodSpec spec;
  final Offset origin;
  final BorderRadius? radius;
  final Widget? child;

  const WoodSurface({
    super.key,
    this.spec = const WoodSpec(),
    this.origin = Offset.zero,
    this.radius,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final Widget painted = RepaintBoundary(
      child: CustomPaint(
        painter: WoodPainter(spec, origin: origin),
        isComplex: true,
        willChange: false,
        child: child ?? const SizedBox.expand(),
      ),
    );
    if (radius == null) return painted;
    return ClipRRect(borderRadius: radius!, child: painted);
  }
}
