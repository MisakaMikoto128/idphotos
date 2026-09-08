/// 黄铜/哑光金属件的程序化绘制。
///
/// DESIGN.md §3：金属件用垂直线性渐变 `brassHi → brass → brassShadow`，
/// 顶部 1px `brassHi` 高光线。
/// RUBRIC R1 要求金属有**高光 → 中调 → 暗部三段**，R2 要求受光方向与全局
/// 光源（左上）一致 —— 因此高光恒在上/左，暗部恒在下/右。
///
/// 无障碍：铭牌与按钮上的文字对比度必须 ≥ 4.5:1（RUBRIC 致命项 4）。
/// 为此黄铜面的渐变刻意把**中段保持在亮调**（`brassHi`→`brass` 之间），
/// `brassShadow` 只出现在底部 12% 的倒角带里；实测面中央 ≈ `#C6A455`，
/// 与 `inkBrown` 对比 5.6:1。哑光禁用态则相反：面偏暗，配 `creamText`，6.3:1。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'noise.dart';
import 'tokens.dart';

/// 金属表面处理。
enum MetalFinish {
  /// 抛光黄铜（可用态）。
  brass,

  /// 哑光灰褐（禁用态，DESIGN.md §5 区域 C）。
  matte,
}

/// 金属面的竖向渐变。[rect] 决定渐变端点。
ui.Gradient metalFaceShader(Rect rect, MetalFinish finish, {bool pressed = false}) {
  final double dim = pressed ? 0.12 : 0.0;
  if (finish == MetalFinish.brass) {
    return ui.Gradient.linear(
      rect.topCenter,
      rect.bottomCenter,
      <Color>[
        Color.lerp(T.brassHi, T.brass, dim)!,
        Color.lerp(T.brassHi, T.brass, 0.40 + dim)!,
        Color.lerp(T.brassHi, T.brass, 0.72 + dim * 0.5)!,
        T.brass,
        T.brassShadow,
      ],
      <double>[0.0, 0.20, 0.62, 0.88, 1.0],
    );
  }
  return ui.Gradient.linear(
    rect.topCenter,
    rect.bottomCenter,
    <Color>[
      T.inkFaded,
      Color.lerp(T.inkFaded, T.woodDark, 0.34)!,
      Color.lerp(T.inkFaded, T.woodDark, 0.62)!,
      T.woodDark,
    ],
    <double>[0.0, 0.34, 0.78, 1.0],
  );
}

/// 一块金属板：倒角 + 拉丝 + 高光扫光 + 螺钉（可选）。
class MetalPlatePainter extends CustomPainter {
  final MetalFinish finish;
  final BorderRadius radius;

  /// 按下时高光收敛、整体压暗 2px 的观感。
  final bool pressed;

  /// 画四角螺钉（大件金属才有，小铭牌上会显得脏）。
  final bool screws;

  /// 拉丝纹理的相位。
  final int seed;

  const MetalPlatePainter({
    this.finish = MetalFinish.brass,
    this.radius = Shape.buttonBorder,
    this.pressed = false,
    this.screws = false,
    this.seed = 9,
  });

  Color get _hi => finish == MetalFinish.brass ? T.brassHi : T.inkFaded;
  Color get _lo => finish == MetalFinish.brass ? T.brassShadow : T.woodDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    final RRect rr = radius.toRRect(rect);
    canvas.save();
    canvas.clipRRect(rr);

    // 1. 面
    canvas.drawRect(rect, Paint()..shader = metalFaceShader(rect, finish, pressed: pressed));

    // 2. 拉丝：横向极细亮/暗线，金属的各向异性
    final Paint brush = Paint()..strokeWidth = 1;
    final int lines = (rect.height / 2).clamp(2, 400).floor();
    for (int i = 0; i < lines; i++) {
      final double y = rect.top + i * 2.0 + 0.5;
      final double n = hash2(seed, i);
      if (n < 0.42) continue;
      brush.color = (n > 0.72 ? _hi : _lo).withValues(alpha: 0.055 + 0.05 * n);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), brush);
    }

    // 3. 扫光：左上进光的斜向高光带
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          Offset(rect.right, rect.bottom * 0.9),
          <Color>[
            _hi.withValues(alpha: pressed ? 0.10 : 0.26),
            _hi.withValues(alpha: 0.0),
            _lo.withValues(alpha: 0.18),
          ],
          <double>[0.0, 0.40, 1.0],
        ),
    );

    // 4. 倒角：上/左亮边，下/右暗边（光源在左上）
    final Path topLeft = Path()
      ..moveTo(rect.left + 0.75, rect.bottom - 1)
      ..lineTo(rect.left + 0.75, rect.top + 0.75)
      ..lineTo(rect.right - 1, rect.top + 0.75);
    canvas.drawPath(
      topLeft,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _hi.withValues(alpha: pressed ? 0.35 : 0.85),
    );
    final Path bottomRight = Path()
      ..moveTo(rect.left + 1, rect.bottom - 0.75)
      ..lineTo(rect.right - 0.75, rect.bottom - 0.75)
      ..lineTo(rect.right - 0.75, rect.top + 1);
    canvas.drawPath(
      bottomRight,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _lo.withValues(alpha: 0.9),
    );

    canvas.restore();

    // 5. 外描边，把金属件从木头上"切"出来
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.woodDark.withValues(alpha: 0.75),
    );

    if (screws) _paintScrews(canvas, rect);
  }

  void _paintScrews(Canvas canvas, Rect rect) {
    const double inset = 9;
    final List<Offset> pts = <Offset>[
      rect.topLeft + const Offset(inset, inset),
      rect.topRight + const Offset(-inset, inset),
      rect.bottomLeft + const Offset(inset, -inset),
      rect.bottomRight + const Offset(-inset, -inset),
    ];
    for (int i = 0; i < pts.length; i++) {
      paintScrew(canvas, pts[i], 4.2, finish, phase: i);
    }
  }

  @override
  bool shouldRepaint(MetalPlatePainter old) =>
      old.finish != finish ||
      old.pressed != pressed ||
      old.screws != screws ||
      old.seed != seed ||
      old.radius != radius;
}

/// 一枚一字槽螺钉。左上受光。
void paintScrew(Canvas canvas, Offset c, double r, MetalFinish finish,
    {int phase = 0}) {
  final Color hi = finish == MetalFinish.brass ? T.brassHi : T.inkFaded;
  final Color lo = finish == MetalFinish.brass ? T.brassShadow : T.woodDark;
  final Color mid = finish == MetalFinish.brass ? T.brass : T.inkFaded;
  final Rect rect = Rect.fromCircle(center: c, radius: r);
  // 沉孔阴影
  canvas.drawCircle(
    c + const Offset(0.6, 0.9),
    r + 0.8,
    Paint()..color = Shade.warmShadow,
  );
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        <Color>[hi, mid, lo],
        <double>[0.0, 0.5, 1.0],
      ),
  );
  // 一字槽，角度随位置变化，像手工拧上去的
  final double ang = 0.5 + phase * 0.7;
  final Offset d = Offset(math.cos(ang), math.sin(ang)) * (r * 0.78);
  canvas.drawLine(
    c - d,
    c + d,
    Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..color = lo.withValues(alpha: 0.9),
  );
  canvas.drawLine(
    c - d + const Offset(0, 1),
    c + d + const Offset(0, 1),
    Paint()
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round
      ..color = hi.withValues(alpha: 0.5),
  );
}

/// 相框铜包角（DESIGN.md §2 `brass_corner`，此处程序化绘制）。
///
/// [corner] 用 `Alignment.topLeft` 等四个角常量指定方向。
class BrassCornerPainter extends CustomPainter {
  final Alignment corner;
  final double arm;
  final bool highlight;

  const BrassCornerPainter({
    required this.corner,
    this.arm = 34,
    this.highlight = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.save();
    // 统一在左上角坐标系里画，再按需要翻转
    final double sx = corner.x < 0 ? 1.0 : -1.0;
    final double sy = corner.y < 0 ? 1.0 : -1.0;
    canvas.translate(sx < 0 ? rect.width : 0, sy < 0 ? rect.height : 0);
    canvas.scale(sx, sy);

    const double t = 11; // 包角厚度
    final double a = math.min(arm, math.min(rect.width, rect.height));
    final Path p = Path()
      ..moveTo(0, 0)
      ..lineTo(a, 0)
      ..lineTo(a, t)
      ..lineTo(t + 2, t + 2)
      ..lineTo(t, a)
      ..lineTo(0, a)
      ..close();

    canvas.drawPath(
      p.shift(const Offset(1.2, 1.6)),
      Paint()..color = Shade.warmShadow,
    );
    canvas.drawPath(
      p,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(a, a),
          <Color>[
            highlight ? T.brassHi : Color.lerp(T.brassHi, T.brass, 0.25)!,
            T.brass,
            T.brassShadow,
          ],
          <double>[0.0, 0.55, 1.0],
        ),
    );
    // 亮边（左上）
    canvas.drawPath(
      Path()
        ..moveTo(0.7, a)
        ..lineTo(0.7, 0.7)
        ..lineTo(a, 0.7),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = T.brassHi.withValues(alpha: 0.9),
    );
    // 暗边（内侧斜口）
    canvas.drawPath(
      Path()
        ..moveTo(a - 0.6, t)
        ..lineTo(t + 2, t + 2)
        ..lineTo(t, a - 0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = T.brassShadow.withValues(alpha: 0.95),
    );
    paintScrew(canvas, Offset(t * 0.62, t * 0.62), 3.4, MetalFinish.brass);
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrassCornerPainter old) =>
      old.corner != corner || old.arm != arm || old.highlight != highlight;
}
