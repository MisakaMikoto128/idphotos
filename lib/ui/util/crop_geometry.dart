/// 裁剪框几何运算。**纯函数，不依赖 widget**，便于单独验证。
///
/// 三条硬约束（G2C.6 / G2C.7）：
/// 1. 任何一次操作之后，`rect.width / rect.height` 必须等于 `spec.aspectRatio`
///    （偏差 ≤ 0.5%）——所以高恒由宽推出，**绝不各自钳制两条边**；
/// 2. 结果必须完全落在图片范围内；
/// 3. 越界时先缩放再平移，而不是把某条边"截断"（截断会破坏宽高比）。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show Alignment;

/// 8 个控制点 + 整体拖动。
enum CropHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
  move;

  bool get isCorner =>
      this == topLeft ||
      this == topRight ||
      this == bottomLeft ||
      this == bottomRight;

  bool get isEdge =>
      this == top || this == bottom || this == left || this == right;

  /// CONTRACTS §7.2 规定的稳定 Key 后缀。
  String get keySuffix => switch (this) {
        CropHandle.topLeft => 'tl',
        CropHandle.topRight => 'tr',
        CropHandle.bottomLeft => 'bl',
        CropHandle.bottomRight => 'br',
        CropHandle.top => 't',
        CropHandle.bottom => 'b',
        CropHandle.left => 'l',
        CropHandle.right => 'r',
        CropHandle.move => 'box',
      };

  /// 该控制点在框内的相对位置（0..1）。
  Alignment get alignment => switch (this) {
        CropHandle.topLeft => Alignment.topLeft,
        CropHandle.topRight => Alignment.topRight,
        CropHandle.bottomLeft => Alignment.bottomLeft,
        CropHandle.bottomRight => Alignment.bottomRight,
        CropHandle.top => Alignment.topCenter,
        CropHandle.bottom => Alignment.bottomCenter,
        CropHandle.left => Alignment.centerLeft,
        CropHandle.right => Alignment.centerRight,
        CropHandle.move => Alignment.center,
      };
}

/// 8 个控制点，按 CONTRACTS §7.2 的顺序。
const List<CropHandle> kResizeHandles = <CropHandle>[
  CropHandle.topLeft,
  CropHandle.topRight,
  CropHandle.bottomLeft,
  CropHandle.bottomRight,
  CropHandle.top,
  CropHandle.bottom,
  CropHandle.left,
  CropHandle.right,
];

abstract final class CropMath {
  /// `BoxFit.contain`：把 [src] 等比放进 [viewport]，返回图片在 viewport
  /// 坐标系中的显示矩形。
  static Rect fitContain(Size src, Rect viewport) {
    if (src.width <= 0 || src.height <= 0 || viewport.isEmpty) {
      return viewport;
    }
    final double scale = math.min(
      viewport.width / src.width,
      viewport.height / src.height,
    );
    final double w = src.width * scale;
    final double h = src.height * scale;
    return Rect.fromLTWH(
      viewport.left + (viewport.width - w) / 2,
      viewport.top + (viewport.height - h) / 2,
      w,
      h,
    );
  }

  /// 图片内、锁定 [aspect] 的最大内接框，居中并按 [inset] 略微收进。
  ///
  /// 竖构图的证件照通常取偏上的位置（人头在上），所以纵向重心放在 0.42 而非 0.5。
  static Rect defaultCrop(Size src, double aspect, {double inset = 0.92}) {
    final Rect bounds = Offset.zero & src;
    double w = src.width * inset;
    double h = w / aspect;
    if (h > src.height * inset) {
      h = src.height * inset;
      w = h * aspect;
    }
    final double cx = src.width / 2;
    final double cy = src.height * 0.46;
    Rect r = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    return translateIntoBounds(r, bounds);
  }

  /// 只平移、不缩放地把 [r] 挪进 [bounds]。前提是 [r] 不大于 [bounds]。
  static Rect translateIntoBounds(Rect r, Rect bounds) {
    double dx = 0;
    double dy = 0;
    if (r.left < bounds.left) dx = bounds.left - r.left;
    if (r.right + dx > bounds.right) dx = bounds.right - r.right;
    if (r.top < bounds.top) dy = bounds.top - r.top;
    if (r.bottom + dy > bounds.bottom) dy = bounds.bottom - r.bottom;
    return r.shift(Offset(dx, dy));
  }

  /// 保宽高比地把 [r] 收进 [bounds]（先缩再挪）。
  static Rect fitIntoBounds(Rect r, Rect bounds, double aspect) {
    double w = r.width;
    double h = w / aspect;
    if (w > bounds.width) {
      w = bounds.width;
      h = w / aspect;
    }
    if (h > bounds.height) {
      h = bounds.height;
      w = h * aspect;
    }
    final Rect scaled =
        Rect.fromCenter(center: r.center, width: w, height: h);
    return translateIntoBounds(scaled, bounds);
  }

  /// 整体拖动：只平移，宽高比天然保持。
  static Rect move(Rect current, Offset delta, Rect bounds) =>
      translateIntoBounds(current.shift(delta), bounds);

  /// 拖拽某个控制点。
  ///
  /// [pointer] 是指针在**原图像素坐标**里的位置，[minWidth] 是允许的最小框宽
  /// （同样是原图像素）。返回的矩形保证：宽高比 == [aspect]，且完全在 [bounds] 内。
  static Rect resize({
    required Rect current,
    required CropHandle handle,
    required Offset pointer,
    required double aspect,
    required Rect bounds,
    required double minWidth,
  }) {
    if (handle == CropHandle.move) return current;

    final double maxW = math.min(bounds.width, bounds.height * aspect);
    final double lo = math.min(minWidth, maxW);

    if (handle.isCorner) {
      // 对角固定
      final Offset anchor = switch (handle) {
        CropHandle.topLeft => current.bottomRight,
        CropHandle.topRight => current.bottomLeft,
        CropHandle.bottomLeft => current.topRight,
        CropHandle.bottomRight => current.topLeft,
        _ => current.center,
      };
      final bool growLeft =
          handle == CropHandle.topLeft || handle == CropHandle.bottomLeft;
      final bool growUp =
          handle == CropHandle.topLeft || handle == CropHandle.topRight;

      // 取横向/纵向两个诉求里更大的那个，手感上"跟手"
      final double wantW = (pointer.dx - anchor.dx).abs();
      final double wantH = (pointer.dy - anchor.dy).abs();
      double w = math.max(wantW, wantH * aspect);

      final double availX =
          growLeft ? anchor.dx - bounds.left : bounds.right - anchor.dx;
      final double availY =
          growUp ? anchor.dy - bounds.top : bounds.bottom - anchor.dy;
      final double hi = math.max(lo, math.min(availX, availY * aspect));
      w = w.clamp(lo, hi);
      final double h = w / aspect;

      final double left = growLeft ? anchor.dx - w : anchor.dx;
      final double top = growUp ? anchor.dy - h : anchor.dy;
      return Rect.fromLTWH(left, top, w, h);
    }

    // 边控制点：对边固定，另一轴保持中心，越界时整体平移而不是截断
    switch (handle) {
      case CropHandle.right:
      case CropHandle.left:
        final double fixedX =
            handle == CropHandle.right ? current.left : current.right;
        final double avail = handle == CropHandle.right
            ? bounds.right - fixedX
            : fixedX - bounds.left;
        final double hi = math.max(lo, math.min(avail, maxW));
        final double w = (handle == CropHandle.right
                ? pointer.dx - fixedX
                : fixedX - pointer.dx)
            .clamp(lo, hi);
        final double h = w / aspect;
        final double left = handle == CropHandle.right ? fixedX : fixedX - w;
        final Rect r = Rect.fromLTWH(left, current.center.dy - h / 2, w, h);
        return translateIntoBounds(r, bounds);
      case CropHandle.bottom:
      case CropHandle.top:
        final double fixedY =
            handle == CropHandle.bottom ? current.top : current.bottom;
        final double availY = handle == CropHandle.bottom
            ? bounds.bottom - fixedY
            : fixedY - bounds.top;
        final double hi = math.max(lo, math.min(availY * aspect, maxW));
        final double wantH = handle == CropHandle.bottom
            ? pointer.dy - fixedY
            : fixedY - pointer.dy;
        final double w = (wantH * aspect).clamp(lo, hi);
        final double h = w / aspect;
        final double top = handle == CropHandle.bottom ? fixedY : fixedY - h;
        final Rect r = Rect.fromLTWH(current.center.dx - w / 2, top, w, h);
        return translateIntoBounds(r, bounds);
      default:
        return current;
    }
  }

  /// 原图坐标 → 显示坐标。
  static Rect srcToView(Rect r, Rect display, Size src) {
    if (src.width <= 0 || src.height <= 0) return display;
    final double sx = display.width / src.width;
    final double sy = display.height / src.height;
    return Rect.fromLTRB(
      display.left + r.left * sx,
      display.top + r.top * sy,
      display.left + r.right * sx,
      display.top + r.bottom * sy,
    );
  }

  /// 显示坐标 → 原图坐标。
  static Offset viewToSrc(Offset p, Rect display, Size src) {
    if (display.isEmpty) return Offset.zero;
    return Offset(
      (p.dx - display.left) * src.width / display.width,
      (p.dy - display.top) * src.height / display.height,
    );
  }
}
