/// 黄铜标尺条（DESIGN.md §5 区域 A 顶部）。
///
/// 刻着当前规格名与像素尺寸，例如 `一寸 · 295×413`；右端一个铜旋钮，
/// 点击弹出规格抽屉。尺身上蚀刻真实的刻度线 —— 这是"标尺"而不是"按钮条"。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/api.dart';
import '../theme/brass.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'metal.dart';
import 'press_effect.dart';

class SpecRuler extends StatelessWidget {
  final PhotoSpec spec;
  final VoidCallback onTap;
  final double height;

  const SpecRuler({
    super.key,
    required this.spec,
    required this.onTap,
    this.height = 40,
  });

  @override
  Widget build(BuildContext context) {
    return PressSurface(
      key: const Key('spec_ruler'),
      onTap: onTap,
      sink: 1,
      semanticLabel: '当前规格 ${spec.nameZh}，轻触更换',
      builder: (BuildContext context, bool pressed) {
        return SizedBox(
          height: height,
          child: MetalPlate(
            finish: MetalFinish.brass,
            radius: Shape.buttonBorder,
            pressed: pressed,
            seed: 5,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                const Positioned.fill(child: CustomPaint(painter: _TickPainter())),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                  child: Row(
                    children: <Widget>[
                      EngravedText(
                        spec.nameZh,
                        style: Type.subtitle(T.inkBrown),
                        relief: T.brassHi,
                        maxLines: 1,
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 1,
                        height: 16,
                        color: T.brassShadow.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: EngravedText(
                          '${spec.widthPx}×${spec.heightPx}  ·  '
                          '${spec.widthMm}×${spec.heightMm}mm',
                          style: Type.captionStrong(T.inkBrown),
                          relief: T.brassHi,
                          align: TextAlign.left,
                          maxLines: 1,
                        ),
                      ),
                      const _Knob(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 尺身刻度：底边一排蚀刻线，每 5 格加长。
class _TickPainter extends CustomPainter {
  const _TickPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..strokeWidth = 1;
    final Paint hi = Paint()..strokeWidth = 1;
    int i = 0;
    for (double x = 6; x < size.width - 6; x += 6) {
      final bool major = i % 5 == 0;
      final double len = major ? 8.0 : 4.5;
      p.color = T.brassShadow.withValues(alpha: major ? 0.85 : 0.5);
      hi.color = T.brassHi.withValues(alpha: major ? 0.5 : 0.3);
      canvas.drawLine(
          Offset(x, size.height - 2), Offset(x, size.height - 2 - len), p);
      canvas.drawLine(Offset(x + 1, size.height - 2),
          Offset(x + 1, size.height - 2 - len), hi);
      i++;
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => false;
}

/// 右端的铜旋钮，暗示"可以拧一下换规格"。
class _Knob extends StatelessWidget {
  const _Knob();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: CustomPaint(painter: const _KnobPainter()),
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    const double r = 11;
    canvas.drawCircle(
        c + const Offset(0.8, 1.4), r, Paint()..color = Shade.warmShadow);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const <Color>[T.brassHi, T.brass, T.brassShadow],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // 滚花：一圈短齿
    final Paint knurl = Paint()
      ..strokeWidth = 1.2
      ..color = T.brassShadow.withValues(alpha: 0.7);
    for (int i = 0; i < 16; i++) {
      final double a = i * math.pi * 2 / 16;
      final Offset d = Offset(
        r * 0.72 * math.cos(a),
        r * 0.72 * math.sin(a),
      );
      final Offset d2 =
          Offset(r * 0.98 * math.cos(a), r * 0.98 * math.sin(a));
      canvas.drawLine(c + d, c + d2, knurl);
    }
    canvas.drawCircle(
      c,
      r * 0.55,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
          colors: const <Color>[T.brassHi, T.brass],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.55)),
    );
    // 指针刻线，指向下方（"往下拉出抽屉"）
    canvas.drawLine(
      c + const Offset(0, 2),
      c + const Offset(0, 7),
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = T.brassShadow,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) => false;
}
