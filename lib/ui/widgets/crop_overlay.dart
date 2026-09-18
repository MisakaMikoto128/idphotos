/// 可拖拽裁剪框（DESIGN.md §5 区域 A，本项目交互的核心）。
///
/// 要点：
/// * 8 个控制点（4 角 + 4 边）+ 框内整体拖动；
/// * 恒定锁定当前规格的宽高比（G2C.6，偏差 ≤ 0.5%）——高永远由宽推出；
/// * 每个控制点的**命中区 48×48 逻辑像素**（G2C.5 要求 ≥ 44×44），
///   视觉尺寸比命中区小得多，手指点得中、画面不脏；
/// * 边界钳制（G2C.7）：任何操作后裁剪框都在图片内；
/// * 拖动**实时**更新，不等松手；按住时框边高亮。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import '../util/crop_geometry.dart';

/// 控制点视觉臂长（角）与条长（边）。命中区固定 [kMinHitSize]。
const double _cornerArm = 19;
const double _edgeBar = 26;

class CropOverlay extends ConsumerStatefulWidget {
  /// 原图像素尺寸。
  final Size sourceSize;

  /// 当前裁剪框，原图像素坐标。
  final Rect crop;

  /// 锁定的宽高比（宽 / 高）。
  final double aspectRatio;

  /// 原图字节。null 时只画框（widget test 里不需要真的解码像素）。
  final Uint8List? imageBytes;

  /// 正在按住的控制点 id（[CropHandle.keySuffix]），null = 没在拖。
  final String? activeHandle;

  /// false = 拖拽交互整体禁用（引擎还在冲洗时，审查 X6）。框与把手变淡
  /// 表示暂不可用 —— 此时用户拖出的框会与新图 token 匹配，等 suggestedCrop
  /// 到达时反而被静默覆盖，引擎的自动取景就永远不出现了。
  final bool interactive;

  /// 裁剪框层的旋转角（弧度，Flutter 口径：正 = 顺时针）。**只转框，
  /// 不转照片** —— 引擎取的是与照片呈此相对角的区域再转正，预览与成片
  /// 的相对几何完全一致；0 = 不转（widget 树与旧版逐节点一致）。
  final double frameRotationRad;

  final ValueChanged<Rect> onChanged;
  final ValueChanged<String> onDragStart;
  final VoidCallback onDragEnd;

  const CropOverlay({
    super.key,
    required this.sourceSize,
    required this.crop,
    required this.aspectRatio,
    required this.imageBytes,
    required this.activeHandle,
    this.interactive = true,
    this.frameRotationRad = 0.0,
    required this.onChanged,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  ConsumerState<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends ConsumerState<CropOverlay> {
  final GlobalKey _stackKey = GlobalKey();

  Rect _startCrop = Rect.zero;
  Offset _startLocal = Offset.zero;

  Offset _toLocal(Offset global) {
    final RenderObject? ro = _stackKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      Offset p = ro.globalToLocal(global);
      if (widget.frameRotationRad != 0) {
        // 框层在旋转的 Transform 里，手势收到的是屏幕坐标；先落到
        // 外层 Stack 坐标，再反旋回框层坐标（Transform 的逆变换）。
        final Offset c = Offset(ro.size.width / 2, ro.size.height / 2);
        final double a = -widget.frameRotationRad;
        final double cosA = math.cos(a), sinA = math.sin(a);
        final Offset d = p - c;
        p = c + Offset(cosA * d.dx - sinA * d.dy, sinA * d.dx + cosA * d.dy);
      }
      return p;
    }
    return global;
  }

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.interactive;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final Rect viewport =
            Offset.zero & Size(c.maxWidth, c.maxHeight);
        final Rect display = CropMath.fitContain(widget.sourceSize, viewport);
        final Rect bounds = Offset.zero & widget.sourceSize;
        final double scale = display.width <= 0 || widget.sourceSize.width <= 0
            ? 1.0
            : display.width / widget.sourceSize.width;
        final Rect cropView =
            CropMath.srcToView(widget.crop, display, widget.sourceSize);
        // 显示上不小于 72 逻辑像素，换算回原图像素
        final double minWidthSrc = math.min(
          bounds.width,
          72 / (scale <= 0 ? 1 : scale),
        );
        // 照片渲染器由单一注入点决定（审查 A4）：真机 Image.memory，
        // 截图/测试场景 SyncRaster。
        final PhotoRasterBuilder raster = ref.watch(photoRasterProvider);

        void applyResize(CropHandle h, Offset globalPos) {
          final Offset local = _toLocal(globalPos);
          final Offset ptr =
              CropMath.viewToSrc(local, display, widget.sourceSize);
          widget.onChanged(CropMath.resize(
            current: _startCrop,
            handle: h,
            pointer: ptr,
            aspect: widget.aspectRatio,
            bounds: bounds,
            minWidth: minWidthSrc,
          ));
        }

        // 框层：框线 + 三分线 + 角标 + 把手 + 拖拽热区。旋转时整体转、
        // 照片层不动 —— 与引擎"取相对角区域再转正"的几何一致。
        final List<Widget> frameLayers = <Widget>[
          // 压暗 + 框线 + 三分线 + 角标
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CropChromePainter(
                  display: display,
                  crop: cropView,
                  active: widget.activeHandle != null,
                  dimmed: !interactive,
                ),
              ),
            ),
          ),
          // 框内整体拖动
          Positioned.fromRect(
            rect: cropView,
            child: IgnorePointer(
              // 冲洗中禁拖（审查 X6）：这时拖出的框会把 suggestedCrop
              // 顶掉，引擎的自动取景永远不出现。
              ignoring: !interactive,
              child: GestureDetector(
                key: const Key('crop_box'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (DragStartDetails d) {
                  _startCrop = widget.crop;
                  _startLocal = _toLocal(d.globalPosition);
                  widget.onDragStart(CropHandle.move.keySuffix);
                },
                onPanUpdate: (DragUpdateDetails d) {
                  final Offset local = _toLocal(d.globalPosition);
                  final Offset deltaSrc =
                      (local - _startLocal) / (scale <= 0 ? 1 : scale);
                  widget.onChanged(
                      CropMath.move(_startCrop, deltaSrc, bounds));
                },
                onPanEnd: (_) => widget.onDragEnd(),
                onPanCancel: widget.onDragEnd,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // 8 个控制点
          for (final CropHandle h in kResizeHandles)
            _handlePositioned(
              handle: h,
              cropView: cropView,
              viewport: viewport,
              interactive: interactive,
              onStart: (DragStartDetails d) {
                _startCrop = widget.crop;
                _startLocal = _toLocal(d.globalPosition);
                widget.onDragStart(h.keySuffix);
              },
              onUpdate: (DragUpdateDetails d) =>
                  applyResize(h, d.globalPosition),
              onEnd: widget.onDragEnd,
              active: widget.activeHandle == h.keySuffix,
            ),
        ];

        return Stack(
          key: _stackKey,
          fit: StackFit.expand,
          children: <Widget>[
            // 照片本体。这个矩形 = BoxFit.contain 之后照片真正铺满的区域，
            // 比裁剪框大（框外的照片只是被 Shade.scrim 压暗，并没有消失）。
            // CONTRACTS §7.2 的 `photo_display` 就指它：G2C.2/2C.4 靠它把照片
            // 像素从色卡比对里剔除，G2C.7 靠它判裁剪框有没有跑到照片外面。
            // 即使 imageBytes 为 null（widget test 不解码像素）也保留这个
            // Positioned，否则 Key 时有时无，测试会静默跳过而不是报错。
            // **照片层永不旋转**（用户 2026-09-17：角度微调时照片不动）。
            Positioned.fromRect(
              key: const Key('photo_display'),
              rect: display,
              child: widget.imageBytes == null
                  ? const SizedBox.expand()
                  : raster(widget.imageBytes!, BoxFit.fill),
            ),
            if (widget.frameRotationRad == 0)
              ...frameLayers
            else
              Positioned.fill(
                child: Transform.rotate(
                  angle: widget.frameRotationRad,
                  child: Stack(fit: StackFit.expand, children: frameLayers),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _handlePositioned({
    required CropHandle handle,
    required Rect cropView,
    required Rect viewport,
    required bool interactive,
    required void Function(DragStartDetails) onStart,
    required void Function(DragUpdateDetails) onUpdate,
    required VoidCallback onEnd,
    required bool active,
  }) {
    final Alignment a = handle.alignment;
    final double cx = cropView.left + (a.x + 1) / 2 * cropView.width;
    final double cy = cropView.top + (a.y + 1) / 2 * cropView.height;
    // 命中区恒为 kMinHitSize×kMinHitSize（G2C.5），但当裁剪框贴到照片边缘时
    // 要把它整体推回可视区内 —— 否则一半热区落在 Stack 之外，手指点不到，
    // "尺寸达标但实际点不中"是这类控件最常见的假合规。
    final double left = (cx - kMinHitSize / 2)
        .clamp(viewport.left, math.max(viewport.left, viewport.right - kMinHitSize));
    final double top = (cy - kMinHitSize / 2)
        .clamp(viewport.top, math.max(viewport.top, viewport.bottom - kMinHitSize));
    return Positioned(
      left: left,
      top: top,
      width: kMinHitSize,
      height: kMinHitSize,
      child: IgnorePointer(
        // 冲洗中把手一起禁用（审查 X6）
        ignoring: !interactive,
        child: Opacity(
          // 不可用态整体变淡示意；仍是铜色系，不引入新的黑白
          opacity: interactive ? 1 : 0.45,
          child: GestureDetector(
            key: Key('crop_handle_${handle.keySuffix}'),
            behavior: HitTestBehavior.opaque,
            onPanStart: onStart,
            onPanUpdate: onUpdate,
            onPanEnd: (_) => onEnd(),
            onPanCancel: onEnd,
            child: CustomPaint(
              size: const Size(kMinHitSize, kMinHitSize),
              painter: _HandlePainter(
                handle: handle,
                active: active,
                // 命中区可能被推回可视区内，角标仍要画在裁剪框真正的角上
                anchor: Offset(cx - left, cy - top),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 压暗、框线、三分线、角标。
class _CropChromePainter extends CustomPainter {
  final Rect display;
  final Rect crop;
  final bool active;

  /// true = 拖拽交互被禁用（冲洗中），框线整体降淡示意。
  final bool dimmed;

  const _CropChromePainter({
    required this.display,
    required this.crop,
    required this.active,
    this.dimmed = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 只压暗照片范围内、裁剪框之外的部分（DESIGN.md §5：0x99241609）
    final Path outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(display),
      Path()..addRect(crop),
    );
    canvas.drawPath(outside, Paint()..color = Shade.scrim);

    // 三分线
    final Paint thirds = Paint()
      ..strokeWidth = 1
      ..color = T.creamText.withValues(alpha: 0.30);
    for (int i = 1; i <= 2; i++) {
      final double x = crop.left + crop.width * i / 3;
      final double y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), thirds);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), thirds);
    }

    // 框线：2px brassHi 实线；按住时加粗并补一圈暗托，形成"被捏住"的重量感。
    // 禁用态（dimmed）整组降淡，表示"暂不可拖"。
    final double frameAlpha = dimmed ? 0.45 : 1.0;
    if (active) {
      canvas.drawRect(
        crop.inflate(2.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = T.brassShadow.withValues(alpha: 0.75 * frameAlpha),
      );
    }
    canvas.drawRect(
      crop,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 3 : 2
        ..color = T.brassHi
            .withValues(alpha: (active ? 1.0 : 0.92) * frameAlpha),
    );
    // 内侧一条暗线，让框在浅色照片上也看得见（RUBRIC R7 对比度）
    canvas.drawRect(
      crop.deflate(active ? 2.0 : 1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.woodDark.withValues(alpha: 0.55 * frameAlpha),
    );

    // 四角 L 形铜角标由 _HandlePainter 画（它同时是命中区），
    // 这里**不要再画一遍** —— 两层叠在一起会让角部糊成一团。
  }

  @override
  bool shouldRepaint(_CropChromePainter old) =>
      old.display != display ||
      old.crop != crop ||
      old.active != active ||
      old.dimmed != dimmed;
}

/// 单个控制点的视觉。命中区 48×48，画出来的只有中间一小块。
class _HandlePainter extends CustomPainter {
  final CropHandle handle;
  final bool active;

  /// 裁剪框上该控制点的真实位置（本画笔的局部坐标）。
  final Offset anchor;

  const _HandlePainter({
    required this.handle,
    required this.active,
    required this.anchor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = anchor;
    final Paint metal = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = active ? 5.0 : 4.0
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, size.height),
        active
            ? const <Color>[T.brassHi, T.brassHi, T.brass]
            : const <Color>[T.brassHi, T.brass, T.brassShadow],
        const <double>[0.0, 0.5, 1.0],
      );
    final Paint shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (active ? 5.0 : 4.0) + 2.5
      ..color = Shade.warmShadow;

    if (handle.isCorner) {
      final double sx = handle.alignment.x < 0 ? 1 : -1;
      final double sy = handle.alignment.y < 0 ? 1 : -1;
      // L 形角标的直角点就压在裁剪框的角上，两条臂朝框内延伸
      final Offset p = c;
      for (final Paint paint in <Paint>[shadow, metal]) {
        final Offset o = identical(paint, shadow)
            ? const Offset(0.8, 1.2)
            : Offset.zero;
        canvas.drawLine(p + o, p + o + Offset(_cornerArm * sx, 0), paint);
        canvas.drawLine(p + o, p + o + Offset(0, _cornerArm * sy), paint);
      }
      return;
    }

    // 边控制点：一根短铜条，方向与所在边垂直的那条边平行
    final bool horizontal =
        handle == CropHandle.top || handle == CropHandle.bottom;
    final Offset half =
        horizontal ? const Offset(_edgeBar / 2, 0) : const Offset(0, _edgeBar / 2);
    canvas.drawLine(c - half + const Offset(0.8, 1.2),
        c + half + const Offset(0.8, 1.2), shadow);
    canvas.drawLine(c - half, c + half, metal);
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.handle != handle || old.active != active || old.anchor != anchor;
}
