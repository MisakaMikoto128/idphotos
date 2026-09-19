/// 复古"冲洗中"进度指示（DESIGN.md §5 区域 B）。
///
/// **不用 Material 的圆形转圈**（RUBRIC 致命项 1）。这里画的是显影盘里
/// 一张正在显影的相纸：影像从左往右逐渐浮现，一把黄铜刮板（带刷毛排）
/// 停在显影锋面上。画面下沿留出一段净纸给"冲洗中"三个字——刮板只画在
/// 上部影像区，不再横穿文字行（visual-critic R8）。
///
/// 影像本体是一张豆包生成的扁平半身剪影图（内嵌字节见
/// `dev/placeholder_photo.dart`，米色底即相纸色），按卡片比例 cover 裁切；
/// 宽高比接近方形（美签 600×600）用方版图，其余用竖版图。旧版程序化剪影
/// 在美签下显胖，被用户验收否决。内嵌 + 同步光栅（`rasterGridFor`）而非
/// asset 异步解码的原因：截图流水线的 `pumpAndSettle` 等不到异步解码回调，
/// S4 会截出没有影像的空白相纸（与官方 S2 丢照片同根因），且真机也免去了
/// "先空相纸后跳图"的闪烁。
///
/// 关于动画与截图流水线：`pumpAndSettle()` 会一直等到没有新帧被调度，
/// **任何无限循环动画都会让它超时**。所以循环由 `UiConfig.freezeAnimations`
/// 控制：截图/测试场景把相位钉死在 `frozenPhase`，只有真机运行时才滚动。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dev/placeholder_photo.dart';
import '../state/providers.dart';
import '../theme/paper_painter.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'sync_raster.dart';

/// 规格宽高比大于该值视为方形档（美签 600×600），用方形占位图。
const double kSquareAspectThreshold = 0.9;

/// 按规格宽高比选占位照片字节（竖版/方版）。
Uint8List _placeholderBytes(double aspectRatio) =>
    aspectRatio > kSquareAspectThreshold
        ? placeholderSquareJpg()
        : placeholderPortraitJpg();

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

  /// 占位照片的同步光栅网格（LRU 缓存，首次解码约几十毫秒）。
  late RasterGrid _photo = rasterGridFor(_placeholderBytes(widget.aspectRatio));

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
  void didUpdateWidget(DevelopingPlate oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool wasSquare = oldWidget.aspectRatio > kSquareAspectThreshold;
    final bool isSquare = widget.aspectRatio > kSquareAspectThreshold;
    if (wasSquare != isSquare) {
      _photo = rasterGridFor(_placeholderBytes(widget.aspectRatio));
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
          CustomPaint(painter: _DevelopPainter(phase, _photo)),
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

  /// 占位照片的同步光栅网格（豆包生成的扁平半身剪影，米色底即相纸色）。
  final RasterGrid photo;

  const _DevelopPainter(this.phase, this.photo);

  /// 画面下沿留给"冲洗中"文字的净纸高度占比。
  /// 刮板/剪影/湿痕全部只画在上部影像带里，不进文字行。
  static const double _textBand = 0.24;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    // 影像带：上部 76%，底部留净纸给文字
    final Rect img = Rect.fromLTWH(
      r.left,
      r.top,
      r.width,
      r.height * (1 - _textBand),
    );
    final double x = img.left + img.width * phase;

    // 影像从左往右浮现：整张占位照片按卡片比例 cover 画出来，再用一层横向
    // 渐变把右侧"擦掉"，得到显影锋面柔和推进的效果。硬裁切（clipRect）会在
    // 锋面留下直角边，而且相位靠左时画面上只剩一角影像，看不出在显影什么。
    // 照片米色底即相纸色，未曝光区（PaperSurface）与已曝光区色差刻意保持
    // 很小——相纸本来就是从纸里"长"出影像（visual-critic R8）。
    canvas.saveLayer(img, Paint());
    canvas.clipRect(img);
    // cover：源矩形按整个相纸（含文字带）的比例居中裁，构图与最终成片一致；
    // 文字带部分被 clipRect 挡住，再由下面的纵向渐隐收边。
    final Rect plate = Offset.zero & size;
    final double imgAspect = photo.width / photo.height;
    final double plateAspect = plate.width / plate.height;
    final Rect src = imgAspect > plateAspect
        ? Rect.fromLTWH(
            (photo.width - photo.height * plateAspect) / 2,
            0,
            photo.height * plateAspect,
            photo.height.toDouble(),
          )
        : Rect.fromLTWH(
            0,
            (photo.height - photo.width / plateAspect) / 2,
            photo.width.toDouble(),
            photo.width / plateAspect,
          );
    canvas.save();
    canvas.translate(plate.left, plate.top);
    canvas.scale(plate.width / src.width, plate.height / src.height);
    canvas.translate(-src.left, -src.top);
    canvas.drawVertices(photo.vertices, ui.BlendMode.srcOver, Paint());
    canvas.restore();
    // 横向：显影锋面右侧还是"未曝光"的纸
    canvas.drawRect(
      img,
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
        ).createShader(img),
    );
    // 纵向：向文字带的方向渐隐，避免剪影在影像带下沿被裁出一条硬边
    final Rect fade = Rect.fromLTWH(
      img.left,
      img.top + img.height * 0.62,
      img.width,
      img.height * 0.38,
    );
    canvas.drawRect(
      fade,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[Color(0xFF000000), Color(0x00000000)],
        ).createShader(fade),
    );
    canvas.restore();

    // 显影锋面：一条渐隐的湿痕（只在影像带内）
    final Rect wet = Rect.fromLTWH(x - 14, img.top, 14, img.height);
    canvas.drawRect(
      wet,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            T.paperEdge.withValues(alpha: 0.0),
            T.paperEdge.withValues(alpha: 0.75),
          ],
        ).createShader(wet),
    );

    // 黄铜刮板：竖直黄铜脊 + 拖在后面的刷毛排，横扫显影锋面。
    // 旧版是一根光秃秃的竖杆，静帧读作"渲染杂条"（visual-critic R8）。
    final Rect spine = Rect.fromLTWH(x - 2.5, img.top + 2, 5, img.height - 4);
    canvas.drawRect(
      spine,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const <Color>[T.brassHi, T.brass, T.brassShadow],
        ).createShader(spine),
    );
    canvas.drawRect(
      spine.translate(3, 0),
      Paint()..color = Shade.warmShadowSoft,
    );
    // 脊顶/脊底各一枚小铜帽，端头收口
    canvas.drawRect(
      Rect.fromLTWH(x - 4, img.top + 2, 8, 3),
      Paint()..color = T.brassShadow,
    );
    canvas.drawRect(
      Rect.fromLTWH(x - 4, img.bottom - 5, 8, 3),
      Paint()..color = T.brassShadow,
    );
    // 刷毛排：从脊背向锋面已扫过的一侧伸出的一排短毛
    final Paint bristle = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = T.inkFaded.withValues(alpha: 0.85);
    final int rows = (img.height / 9).floor().clamp(4, 24);
    for (int i = 0; i <= rows; i++) {
      final double by = img.top + 5 + i * (img.height - 10) / rows;
      canvas.drawLine(Offset(x - 3, by), Offset(x - 10, by), bristle);
    }
  }

  @override
  bool shouldRepaint(_DevelopPainter old) =>
      old.phase != phase || old.photo != photo;
}
