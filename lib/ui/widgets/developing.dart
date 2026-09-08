/// 复古"冲洗中"进度指示（DESIGN.md §5 区域 B）。
///
/// **不用 Material 的圆形转圈**（RUBRIC 致命项 1）。这里画的是显影盘里
/// 一张正在显影的相纸：影像从左往右逐渐浮现，一根黄铜刮刀停在显影锋面上。
///
/// 关于动画与截图流水线：`pumpAndSettle()` 会一直等到没有新帧被调度，
/// **任何无限循环动画都会让它超时**。所以循环由 `UiConfig.freezeAnimations`
/// 控制：截图/测试场景把相位钉死在 `frozenPhase`，只有真机运行时才滚动。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/paper_painter.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// 半身人像剪影。候选缩略图占位、显影动画都用它，保证造型一致。
void paintPortraitSilhouette(Canvas canvas, Rect r, Color color) {
  final double w = r.width;
  final double h = r.height;
  final Paint p = Paint()..color = color;
  // 肩
  final Path shoulders = Path()
    ..moveTo(r.left + w * 0.06, r.bottom)
    ..cubicTo(
      r.left + w * 0.12,
      r.top + h * 0.66,
      r.left + w * 0.30,
      r.top + h * 0.58,
      r.left + w * 0.50,
      r.top + h * 0.58,
    )
    ..cubicTo(
      r.left + w * 0.70,
      r.top + h * 0.58,
      r.left + w * 0.88,
      r.top + h * 0.66,
      r.left + w * 0.94,
      r.bottom,
    )
    ..close();
  canvas.drawPath(shoulders, p);
  // 颈
  canvas.drawRect(
    Rect.fromLTWH(r.left + w * 0.42, r.top + h * 0.44, w * 0.16, h * 0.18),
    p,
  );
  // 头
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(r.left + w * 0.5, r.top + h * 0.30),
      width: w * 0.40,
      height: h * 0.36,
    ),
    p,
  );
}

/// 正在显影的相纸。
class DevelopingPlate extends ConsumerStatefulWidget {
  /// 长宽比（宽/高），与当前规格一致。
  final double aspectRatio;

  const DevelopingPlate({super.key, required this.aspectRatio});

  @override
  ConsumerState<DevelopingPlate> createState() => _DevelopingPlateState();
}

class _DevelopingPlateState extends ConsumerState<DevelopingPlate>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  double _frozenPhase = 0.38;

  @override
  void initState() {
    super.initState();
    // UiConfig 在一次运行内不变，initState 里读一次即可，避免在 build 里
    // 创建/销毁 AnimationController。
    final UiConfig cfg = ref.read(uiConfigProvider);
    _frozenPhase = cfg.frozenPhase;
    if (!cfg.freezeAnimations) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1600),
      )..repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? ctrl = _ctrl;
    if (ctrl == null) return _plate(_frozenPhase);
    return AnimatedBuilder(
      animation: ctrl,
      builder: (BuildContext context, Widget? _) => _plate(ctrl.value),
    );
  }

  Widget _plate(double phase) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const PaperSurface(seed: 33, edgeDarken: 0.9),
          CustomPaint(painter: _DevelopPainter(phase)),
          Align(
            alignment: const Alignment(0, 0.82),
            child: Text('冲洗中', style: Type.caption(T.inkBrown)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }
}

class _DevelopPainter extends CustomPainter {
  final double phase;

  const _DevelopPainter(this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    final double x = r.left + r.width * phase;

    // 影像从左往右浮现：整张剪影都画出来，再用一层横向渐变把右侧"擦掉"，
    // 得到显影锋面柔和推进的效果。硬裁切（clipRect）会在锋面留下直角边，
    // 而且相位靠左时画面上只剩一角剪影，看不出在显影什么。
    canvas.saveLayer(r, Paint());
    paintPortraitSilhouette(
      canvas,
      r.deflate(math.min(r.width, r.height) * 0.08),
      T.inkFaded.withValues(alpha: 0.60),
    );
    canvas.drawRect(
      r,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const <Color>[
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x00000000),
          ],
          stops: <double>[
            0.0,
            (phase - 0.12).clamp(0.0, 1.0),
            (phase + 0.30).clamp(0.02, 1.0),
          ],
        ).createShader(r),
    );
    canvas.restore();

    // 显影锋面：一条渐隐的湿痕
    canvas.drawRect(
      Rect.fromLTWH(x - 14, r.top, 14, r.height),
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            T.paperEdge.withValues(alpha: 0.0),
            T.paperEdge.withValues(alpha: 0.75),
          ],
        ).createShader(Rect.fromLTWH(x - 14, r.top, 14, r.height)),
    );

    // 黄铜刮刀
    final Rect blade = Rect.fromLTWH(x - 2.5, r.top, 5, r.height);
    canvas.drawRect(
      blade,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const <Color>[T.brassHi, T.brass, T.brassShadow],
        ).createShader(blade),
    );
    canvas.drawRect(
      blade.translate(3, 0),
      Paint()..color = Shade.warmShadowSoft,
    );
  }

  @override
  bool shouldRepaint(_DevelopPainter old) => old.phase != phase;
}
