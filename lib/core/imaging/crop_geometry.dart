/// 木照 MuZhao — 裁剪几何推算（纯数学，不依赖 dart:ui / image 包）。
///
/// 本文件刻意不 import `../api.dart`，因为 api.dart 依赖 `dart:ui`。
/// 把几何计算隔离成纯 Dart 有两个好处：可以用 `dart run` 单独跑，
/// 也便于 gatekeeper 独立复算。
library;

import 'dart:math' as math;

/// 双精度矩形（left, top, width, height）。与 `dart:ui` 的 `Rect` 同语义，
/// 但不引入 Flutter 依赖。
class RectD {
  final double left;
  final double top;
  final double width;
  final double height;

  const RectD(this.left, this.top, this.width, this.height);

  const RectD.fromLTRB(this.left, this.top, double right, double bottom)
      : width = right - left,
        height = bottom - top;

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2.0;
  double get centerY => top + height / 2.0;

  @override
  String toString() => 'RectD(${left.toStringAsFixed(2)}, '
      '${top.toStringAsFixed(2)}, ${width.toStringAsFixed(2)}, '
      '${height.toStringAsFixed(2)})';
}

/// 旋转摆正计划。
///
/// 约定：图像坐标系 x 向右、y 向下。`rollDeg` 为正表示头向右倾。
///
/// 定义「旋转空间」= 把原图整体摆正后的虚拟画布。两个空间的换算：
///
/// ```
/// p_src = C_src + R(θ) · (p_rot − C_rot)
/// p_rot = C_rot + R(−θ) · (p_src − C_src)
/// R(θ) = [[cosθ, −sinθ], [sinθ, cosθ]]
/// ```
///
/// 取 θ = rollDeg 时，源图中沿头部倾斜轴的方向在旋转空间里变成竖直方向，
/// 即完成摆正。
class RotationPlan {
  /// 是否真的要旋转。`|rollDeg| <= deadZoneDeg` 时为 false（恒等变换）。
  final bool enabled;

  /// θ，弧度。enabled 为 false 时恒为 0。
  final double angleRad;

  /// 源图尺寸。
  final int srcWidth;
  final int srcHeight;

  /// 旋转画布尺寸（源图四角变换后的包围盒）。
  final double rotWidth;
  final double rotHeight;

  const RotationPlan({
    required this.enabled,
    required this.angleRad,
    required this.srcWidth,
    required this.srcHeight,
    required this.rotWidth,
    required this.rotHeight,
  });

  double get _srcCx => srcWidth / 2.0;
  double get _srcCy => srcHeight / 2.0;
  double get _rotCx => rotWidth / 2.0;
  double get _rotCy => rotHeight / 2.0;

  /// 摆正角度（度）。旋转空间相对源图转过的角度。
  double get angleDeg => angleRad * 180.0 / math.pi;

  /// 旋转空间 → 源图空间。结果写入长度 ≥ 2 的 [out]，避免逐点分配对象。
  void toSource(double xr, double yr, List<double> out) {
    if (!enabled) {
      out[0] = xr;
      out[1] = yr;
      return;
    }
    final double c = math.cos(angleRad);
    final double s = math.sin(angleRad);
    final double dx = xr - _rotCx;
    final double dy = yr - _rotCy;
    out[0] = _srcCx + c * dx - s * dy;
    out[1] = _srcCy + s * dx + c * dy;
  }

  /// 源图空间 → 旋转空间。
  void toRotated(double xs, double ys, List<double> out) {
    if (!enabled) {
      out[0] = xs;
      out[1] = ys;
      return;
    }
    final double c = math.cos(-angleRad);
    final double s = math.sin(-angleRad);
    final double dx = xs - _srcCx;
    final double dy = ys - _srcCy;
    out[0] = _rotCx + c * dx - s * dy;
    out[1] = _rotCy + s * dx + c * dy;
  }
}

/// 摆正死区：面内旋转角绝对值不超过这个度数就不旋转。
///
/// 旋转必然带来一次重采样，小角度旋转得不偿失；契约要求 ±3°。
const double kRollDeadZoneDeg = 3.0;

/// 摆正角上限。超过这个角度多半是人脸检测抽风（或者本来就不是正脸），
/// 强行摆正会把画面转得面目全非，因此钳制。
const double kMaxRollDeg = 30.0;

/// 生成旋转计划。
RotationPlan planRotation({
  required int srcWidth,
  required int srcHeight,
  required double rollDeg,
  double deadZoneDeg = kRollDeadZoneDeg,
}) {
  double roll = rollDeg;
  if (!roll.isFinite) {
    roll = 0.0;
  }
  roll = roll.clamp(-kMaxRollDeg, kMaxRollDeg).toDouble();
  if (roll.abs() <= deadZoneDeg) {
    return RotationPlan(
      enabled: false,
      angleRad: 0.0,
      srcWidth: srcWidth,
      srcHeight: srcHeight,
      rotWidth: srcWidth.toDouble(),
      rotHeight: srcHeight.toDouble(),
    );
  }
  final double rad = roll * math.pi / 180.0;
  final double c = math.cos(rad).abs();
  final double s = math.sin(rad).abs();
  final double rw = srcWidth * c + srcHeight * s;
  final double rh = srcWidth * s + srcHeight * c;
  return RotationPlan(
    enabled: true,
    angleRad: rad,
    srcWidth: srcWidth,
    srcHeight: srcHeight,
    rotWidth: rw,
    rotHeight: rh,
  );
}

/// 裁剪推算结果。
class CropSolution {
  /// 裁剪框，**旋转空间**坐标。可能越出画布（见 [outOfBoundsFraction]）。
  final RectD rect;

  /// 越界面积占裁剪框面积的比例。0 表示完全落在画布内。
  ///
  /// 越界部分在合成时按 alpha = 0 处理，直接填底色 —— 不会出现黑边（G2B.9）。
  final double outOfBoundsFraction;

  /// 是否为了塞进画布而缩小了裁剪框（此时头身比无法完全达标）。
  final bool shrunk;

  /// 实际达成的头高比。理想情况等于 spec.headHeightRatio。
  final double achievedHeadHeightRatio;

  /// 实际达成的头顶留白比。
  final double achievedHeadTopRatio;

  /// 人类可读的说明，写进自检报告用。
  final String note;

  const CropSolution({
    required this.rect,
    required this.outOfBoundsFraction,
    required this.shrunk,
    required this.achievedHeadHeightRatio,
    required this.achievedHeadTopRatio,
    required this.note,
  });
}

/// 由人脸几何反推裁剪框。
///
/// 输入坐标全部是**旋转空间**坐标（调用方先用 [RotationPlan.toRotated] 换算好）。
///
/// 推导：
/// ```
/// 头高 headH = chinY − headTopY                （已知，旋转不改变长度）
/// 画面总高 H = headH / spec.headHeightRatio     （反推）
/// 画面总宽 W = H × spec.aspectRatio
/// 上边缘   top  = headTopY − spec.headTopRatio × H
/// 左边缘   left = faceCenterX − W / 2
/// ```
///
/// ## 越界策略
///
/// 这是 G2B.9 的核心。三档处理，优先保住头身比：
///
/// 1. **下边界硬约束**：裁剪框底边不得超过画布底边。人像下半身之外没有内容，
///    补底色会把肩膀凭空截断，非常难看。超了就整体上移。
/// 2. **上 / 左 / 右 可以越界**：这些方向越出去的部分原本就是背景，
///    合成时按 alpha=0 填底色，观感与真实背景一致。所以头顶留白和水平居中
///    可以无条件达标，不需要牺牲比例。
/// 3. **实在放不下**（画面总高 > 画布高，且上移后头顶留白仍无法满足，
///    或越界比例超过 [maxOutOfBounds]）：等比缩小到能放下的最大框，
///    此时 [shrunk] = true，头身比会偏离目标，[note] 里写明偏离量。
CropSolution solveAutoCrop({
  required double canvasWidth,
  required double canvasHeight,
  required double aspectRatio,
  required double headTopY,
  required double chinY,
  required double faceCenterX,
  required double headTopRatio,
  required double headHeightRatio,
  double maxOutOfBounds = 0.45,
}) {
  final double headH = chinY - headTopY;
  if (!headH.isFinite || headH <= 0.5 || !aspectRatio.isFinite ||
      aspectRatio <= 0) {
    final RectD r = centeredMaxRect(canvasWidth, canvasHeight, aspectRatio);
    return CropSolution(
      rect: r,
      outOfBoundsFraction: 0.0,
      shrunk: true,
      achievedHeadHeightRatio: 0.0,
      achievedHeadTopRatio: 0.0,
      note: '头高无效（chinY 未大于 headTopY），退化为居中最大内接框',
    );
  }

  double h = headH / headHeightRatio;
  double w = h * aspectRatio;

  // ---- 第 1 档：理想框 ----
  double top = headTopY - headTopRatio * h;
  double left = faceCenterX - w / 2.0;

  // 下边界硬约束：底边压回画布内（允许 top 变负）。
  if (top + h > canvasHeight) {
    top = canvasHeight - h;
  }
  // 顶边也不该越出太多：如果整框比画布还高，top 必为负，这是允许的。
  // 但若 top > 0 且底边有余量，保持原值即可。

  RectD rect = RectD(left, top, w, h);
  double oob = _outOfBoundsFraction(rect, canvasWidth, canvasHeight);

  if (oob <= maxOutOfBounds) {
    return CropSolution(
      rect: rect,
      outOfBoundsFraction: oob,
      shrunk: false,
      achievedHeadHeightRatio: headH / h,
      achievedHeadTopRatio: (headTopY - top) / h,
      note: oob <= 1e-6
          ? '裁剪框完全在图内'
          : '裁剪框向上/两侧越界 ${(oob * 100).toStringAsFixed(1)}%，'
              '越界区域按 alpha=0 填底色',
    );
  }

  // ---- 第 3 档：等比缩小到能放下的最大框 ----
  final double scale = math.min(canvasWidth / w, canvasHeight / h);
  w = w * scale;
  h = h * scale;
  top = headTopY - headTopRatio * h;
  left = faceCenterX - w / 2.0;
  left = left.clamp(0.0, math.max(0.0, canvasWidth - w)).toDouble();
  top = top.clamp(0.0, math.max(0.0, canvasHeight - h)).toDouble();
  rect = RectD(left, top, w, h);
  oob = _outOfBoundsFraction(rect, canvasWidth, canvasHeight);

  final double achievedHead = headH / h;
  return CropSolution(
    rect: rect,
    outOfBoundsFraction: oob,
    shrunk: true,
    achievedHeadHeightRatio: achievedHead,
    achievedHeadTopRatio: (headTopY - top) / h,
    note: '人脸过于贴边/过大，裁剪框已缩到画布内最大尺寸：'
        '头高比 ${achievedHead.toStringAsFixed(3)}（目标 '
        '${headHeightRatio.toStringAsFixed(3)}）',
  );
}

/// 画布内居中的最大内接矩形（保持 [aspectRatio]）。无人脸时的兜底裁剪。
RectD centeredMaxRect(
    double canvasWidth, double canvasHeight, double aspectRatio) {
  final double ar = (aspectRatio.isFinite && aspectRatio > 0)
      ? aspectRatio
      : canvasWidth / canvasHeight;
  double w = canvasWidth;
  double h = w / ar;
  if (h > canvasHeight) {
    h = canvasHeight;
    w = h * ar;
  }
  return RectD((canvasWidth - w) / 2.0, (canvasHeight - h) / 2.0, w, h);
}

/// 把用户框选的矩形规整到目标宽高比。
///
/// 保持中心不变，把「不够长」的那一边撑开。撑出画布也没关系 ——
/// 越界部分按 alpha=0 填底色。但底边同样受硬约束，会整体上移。
RectD normalizeToAspect({
  required RectD rect,
  required double aspectRatio,
  required double canvasWidth,
  required double canvasHeight,
}) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) {
    return rect;
  }
  double w = rect.width;
  double h = rect.height;
  if (w <= 0 || h <= 0) {
    return centeredMaxRect(canvasWidth, canvasHeight, aspectRatio);
  }
  final double cur = w / h;
  if (cur > aspectRatio) {
    h = w / aspectRatio; // 太宽 → 撑高
  } else if (cur < aspectRatio) {
    w = h * aspectRatio; // 太高 → 撑宽
  }
  double left = rect.centerX - w / 2.0;
  double top = rect.centerY - h / 2.0;
  if (top + h > canvasHeight) {
    top = canvasHeight - h;
  }
  return RectD(left, top, w, h);
}

double _outOfBoundsFraction(RectD r, double cw, double ch) {
  final double ix0 = math.max(r.left, 0.0);
  final double iy0 = math.max(r.top, 0.0);
  final double ix1 = math.min(r.right, cw);
  final double iy1 = math.min(r.bottom, ch);
  final double inside =
      math.max(0.0, ix1 - ix0) * math.max(0.0, iy1 - iy0);
  final double total = r.width * r.height;
  if (total <= 0) {
    return 1.0;
  }
  return (1.0 - inside / total).clamp(0.0, 1.0).toDouble();
}
