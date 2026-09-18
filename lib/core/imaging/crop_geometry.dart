/// 木照 MuZhao — 裁剪几何推算（纯数学，不依赖 dart:ui / image 包）。
///
/// 本文件刻意不 import `../api.dart`，因为 api.dart 依赖 `dart:ui`。
/// 把几何计算隔离成纯 Dart 有两个好处：可以用 `dart run` 单独跑，
/// 也便于 gatekeeper 独立复算。
library;

import 'dart:math' as math;
import 'dart:typed_data';

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
/// **10° 是用户 2026-09-17 的产品决定**，不是测量结论：普通拍摄的轻微倾斜
/// 不值得为它重采样，更不值得为它把裁剪框转出原图（越界部分只能填底色，
/// 成片底部会多出一道切口）；只有明显拍歪的照片、以及拍倒的照片才需要摆正。
/// 上限仍是 [kMaxRollDeg] = 30°，故实际摆正只发生在 (10°, 30°] 这一段。
///
/// **代价是明确的，写在这里免得以后有人当它是 bug**：真值在 10° 以内、
/// 但超过旧判据阈值的照片**成片保留原倾角**。例：`Pictures/1 (2).jpg` 真值
/// −4.4°（人脸左右对称性独立实测 −3.4°~−4.4°，与四个估计器一致），在本门槛
/// 下不再被摆正，成片保持 4.4° 倾斜。
///
/// **2026-09-17 已裁定：门槛保持 10°，改判据的适用域。** `docs/ACCEPTANCE.md`
/// 的 G2B-P0 现按死区分两档：死区内（|真值| ≤ 10°）判「引擎不得转动它」
/// （|残余 − 真值| ≤ 1.5°，转正与转歪都算 FAIL），死区外才要求 |残余| ≤ 1.5°；
/// 2B.8 的夹具角从 ±10° 挪到 ±15°（原角度与门槛重合，转不转取决于估角噪声的符号）。
/// **不要靠在这里调数值来让判据好过** —— 10° 是用户的产品决定，不是拟合结果。
///
/// 历史（保留，因为它解释了为什么曾经更窄）：曾是 3°；P0 用户反馈成片可见
/// 歪斜后，用黄金集 g01/g03/g07 人工旋转 ±1–4° 实测收窄到 1°——当时小角度
/// 的真实倾斜完全不修正，是成片可见歪斜的最大单项来源。那条论证在**当时的
/// 产品目标下**成立；现在的目标是"普通照片不要动它"，前提变了，故不再适用。
const double kRollDeadZoneDeg = 10.0;

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

// ---------------------------------------------------------------------------
// 摆正后的头部定位（掩膜精化）
// ---------------------------------------------------------------------------

/// [refineHeadFromMask] 的结果，坐标与输入同处**旋转空间**。
class HeadMaskRefinement {
  /// 是否从掩膜里读到了有效信号。false 时调用方应原样保留检测器的几何。
  final bool valid;

  /// 发顶（掩膜里头部连通前景的最高行）。
  final double hairTopY;

  /// 头部水平中心（上半头部前景质心）。
  final double centerX;

  const HeadMaskRefinement({
    required this.valid,
    required this.hairTopY,
    required this.centerX,
  });
}

/// 用 alpha 掩膜复核检测器给出的头部几何：把发顶和水平中心校到真实剪影上。
///
/// ## 为什么需要它（G4 真实缺陷的直接根因）
///
/// `FaceInfo.headTopY` 是**人体测量学推算值**（眼–嘴距离 × 系数，见
/// yunet_decoder），不是量出来的。它在真实照片上会大幅偏离真实发际：
///
/// - 捧腹大笑、头后仰的人脸：透视压缩让眼–嘴距离 d 缩水，
///   `headTopY = eyeY − 1.89·d` 落到眉弓甚至眼镜的高度；
/// - 检测框异常肥大（把脖子/上胸框进「脸」）时，推算头顶随之掉进脸里，
///   兜底夹紧（`min(推算值, 框顶)`）救不了推算值本身偏低的情况。
///
/// 按这样的 headTopY 排版，`top = headTopY − 0.09H` 会把整个画幅压低
/// 半个额头，成片**发际被齐齐裁掉**（G4 `1979d869` 实测：检测头顶 957、
/// 真实发顶 420，成片眼镜贴着上边缘）。
///
/// 两处测量都来自摆正后的真实剪影：
///
/// - **发顶**：从检测头顶出发，沿头部竖直轴向上走，允许 ≤ gapMax
///   （约 0.02·头高）行的稀疏缺口（蓬松发梢），走到头为止。
///   发丝再乱也是连通的前景，比任何系数推算都可靠。
/// - **水平中心**：发顶往下 0.5 倍头高内的前景质心，
///   比 G2B 旧版的全宽行中点探针更抗同画面其他人干扰。
///
/// **下巴不修正**：MODNet 的 alpha 把头颈躯干连成整块，宽度剖面里不存在
/// 可靠的颌颈收窄信号（G4 四张真实设备 alpha 实测），按剖面修下巴只会把
/// 好图改坏。下巴只随头身比推导（chinY − hairTopY 反推画幅高）。
///
/// 所有扫描都限制在头部附近的**竖直带**里（[anchorX] ± 0.75 倍脸框宽），
/// 合影里邻人的头不会污染信号（G4 `1979d869` 五人合影实测有效）。
///
/// 坐标均为**旋转空间**；[plan] 未启用时即源图空间，退化为逐点直查。
HeadMaskRefinement refineHeadFromMask({
  required Uint8List alpha,
  required int width,
  required int height,
  required RotationPlan plan,
  required double anchorX,
  required double headTopY,
  required double chinY,
  required double faceBoxWidth,
  int alphaThreshold = 128,
}) {
  final double detHeadH = chinY - headTopY;
  if (width <= 0 ||
      height <= 0 ||
      alpha.length < width * height ||
      !detHeadH.isFinite ||
      detHeadH <= 1 ||
      !anchorX.isFinite) {
    return HeadMaskRefinement(
        valid: false, hairTopY: headTopY, centerX: anchorX);
  }

  final double c = math.cos(plan.angleRad);
  final double s = math.sin(plan.angleRad);
  final double srcCx = plan.srcWidth / 2.0;
  final double srcCy = plan.srcHeight / 2.0;
  final double rotCx = plan.rotWidth / 2.0;
  final double rotCy = plan.rotHeight / 2.0;

  // 旋转空间 → 源图，取样 alpha（越界按 0）。带内逐点采样，
  // 行数 × 带宽 ≈ 1.7·headH × 1.5·boxW，最坏 ~2e6 次，几十毫秒级。
  bool isFg(double xr, double yr) {
    if (!plan.enabled) {
      final int x = xr.floor();
      final int y = yr.floor();
      if (x < 0 || y < 0 || x >= width || y >= height) {
        return false;
      }
      return alpha[y * width + x] >= alphaThreshold;
    }
    final double dx = xr - rotCx;
    final double dy = yr - rotCy;
    final double xs = srcCx + c * dx - s * dy;
    final double ys = srcCy + s * dx + c * dy;
    final int x = xs.floor();
    final int y = ys.floor();
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return false;
    }
    return alpha[y * width + x] >= alphaThreshold;
  }

  final double band = math.max(4.0, faceBoxWidth * 0.75);
  final double bandL = math.max(0.0, anchorX - band);
  final double bandR = math.min(plan.rotWidth.toDouble(), anchorX + band);

  int rowCount(int y) {
    int n = 0;
    for (double x = bandL; x < bandR; x += 1.0) {
      if (isFg(x, y.toDouble())) {
        n++;
      }
    }
    return n;
  }

  // ---- 发顶：从检测头顶向上走，容忍稀疏缺口 ----
  // 先锚定：检测头顶若悬在空里（估算偏高），向下最多 0.15·headH 找到头部。
  double start = headTopY;
  final double maxAnchor = headTopY + detHeadH * 0.15;
  while (start < maxAnchor && rowCount(start.floor()) == 0) {
    start += 1.0;
  }
  if (rowCount(start.floor()) == 0) {
    // 头顶附近整段无前景：掩膜与此处人脸对不上，保守返回原几何。
    return HeadMaskRefinement(
        valid: false, hairTopY: headTopY, centerX: anchorX);
  }
  final int gapMax = math.max(4, (detHeadH * 0.02).round());
  int emptyRun = 0;
  double hairTop = start;
  final double upLimit =
      math.max(0.0, headTopY - detHeadH * 1.2);
  for (double y = start; y >= upLimit; y -= 1.0) {
    if (rowCount(y.floor()) > 0) {
      hairTop = y;
      emptyRun = 0;
    } else {
      emptyRun++;
      if (emptyRun > gapMax) {
        break;
      }
    }
  }

  // ---- 水平中心：发顶往下 0.5·headH 内的前景质心 ----
  double sumX = 0.0;
  int sumN = 0;
  final double cxBottom = math.min(
      plan.rotHeight.toDouble(), hairTop + detHeadH * 0.5);
  for (double y = hairTop; y < cxBottom; y += 1.0) {
    for (double x = bandL; x < bandR; x += 1.0) {
      if (isFg(x, y)) {
        sumX += x;
        sumN++;
      }
    }
  }
  final double centerX = sumN > 0 ? sumX / sumN : anchorX;

  // ---- 下巴：不做掩膜修正，原样保留检测值 ----
  // 曾试图从宽度剖面找「脸颊宽—脖子窄—肩宽」的收窄点当地下巴，用 G4 四张
  // 真实设备的 alpha 实测后放弃：MODNet 的 alpha 把头、颈、躯干连成一个
  // 整块，脖子的收窄要么不存在、要么被衣物轮廓盖住，剖面里出现的「变窄」
  // 全在脸颊中部（眼镜/发型噪声），按它修下巴只会把好图改坏。下巴出错
  // （检测框肥大吞掉脖子）只能靠 ml-porting 把框修对。

  return HeadMaskRefinement(
      valid: true, hairTopY: hairTop, centerX: centerX);
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
/// ## 越界策略（G4 复核后修订）
///
/// 四条边统一处理：**画幅按头身比先定死，越出的部分一律按 alpha=0 填底色**，
/// 越界总面积不超过 [maxOutOfBounds] 就直接用。
///
/// 早期版本对底边做了硬约束（「底边压回画布内，不许凭空补肩」）。G4 真实数据
/// （摄像头横图、人脸贴近图片底边）证明那是错的：底边压回会把整个画幅上移，
/// 下巴被推到画面下缘（实测成片里下巴落在 0.98 倍画高处，贴边即裁）、
/// 头顶留白从 0.09 膨胀到 0.36 —— 构图彻底失效。而底边越界的代价只是
/// 「画面最下方一条平色」：当下巴贴近图片底边时，画面里本来就没有肩部内容
/// 可言，向下越界填底色、头部几何精确达标，是明显更好的取舍。谁也不该在
/// 「下巴贴边」和「胸口以下平色」之间选前者。
///
/// 1. **理想框**：四边越界（含底边）面积 ≤ [maxOutOfBounds] 就用，
///    头身比、头顶留白、水平居中全部精确达标。
/// 2. **放不下**（越界比例超限，常见于头部特写贴角）：以头顶点和人脸水平中心
///    为**锚点**等比缩小 —— 锚点不动，头顶留白比保持不变，头在画面里的相对
///    位置不变，只是头变大了（此时 [shrunk] = true，[note] 里写明偏离量）。
///    旧版在这里把框钳回画布，钳完锚点就丢了，头顶留白随钳制量漂移。
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

  // ---- 第 1 档：理想框（四边均可越界，越界部分填底色） ----
  final double top = headTopY - headTopRatio * h;
  final double left = faceCenterX - w / 2.0;

  RectD rect = RectD(left, top, w, h);
  double oob = outOfBoundsFraction(rect, canvasWidth, canvasHeight);

  if (oob <= maxOutOfBounds) {
    return CropSolution(
      rect: rect,
      outOfBoundsFraction: oob,
      shrunk: false,
      achievedHeadHeightRatio: headH / h,
      achievedHeadTopRatio: (headTopY - top) / h,
      note: oob <= 1e-6
          ? '裁剪框完全在图内'
          : '裁剪框越界 ${(oob * 100).toStringAsFixed(1)}%（越出部分按 alpha=0 填底色）',
    );
  }

  // ---- 第 2 档：以头顶点与人脸水平中心为锚点等比缩小 ----
  // 头顶留白比与水平居中在缩放过程中不变，头身比偏离目标（头变大）。
  // 从理想尺寸往下找第一个越界达标的尺寸；找不到就取画布内能放下的最大值。
  final double fitScale = math.min(canvasWidth / w, canvasHeight / h);
  double? bestScale;
  for (double s = fitScale; s < 1.0; s += math.max(0.01, fitScale * 0.05)) {
    final double sh = h * s;
    final double sw = w * s;
    final RectD r = RectD(faceCenterX - sw / 2.0, headTopY - headTopRatio * sh,
        sw, sh);
    if (outOfBoundsFraction(r, canvasWidth, canvasHeight) <= maxOutOfBounds) {
      bestScale = s;
      break;
    }
  }
  final double scale = bestScale ?? math.min(fitScale, 1.0);
  w = w * scale;
  h = h * scale;
  // 锚点放在头顶与脸上：上边缘 = headTopY − headTopRatio·h（不钳制，
  // 越界填底色）；水平方向以人脸中心为轴。若钳回画布反而会把头推离锚点。
  double left2 = faceCenterX - w / 2.0;
  double top2 = headTopY - headTopRatio * h;
  // 最后的兜底：人脸中心本身贴在画布边上时（脸有一半在图外），
  // 锚点缩放也放不下 —— 此时按画布内最大框钳制，保住「不崩、有产出」，
  // 构图上接受脸被裁。脸完全在图外不是几何问题，是选脸问题（ml-porting）。
  left2 = left2.clamp(-w * 0.25, math.max(-w * 0.25, canvasWidth - w * 0.75))
      .toDouble();
  top2 = top2.clamp(-h * 0.75, math.max(-h * 0.75, canvasHeight - h * 0.25))
      .toDouble();
  rect = RectD(left2, top2, w, h);
  oob = outOfBoundsFraction(rect, canvasWidth, canvasHeight);

  final double achievedHead = headH / h;
  return CropSolution(
    rect: rect,
    outOfBoundsFraction: oob,
    shrunk: true,
    achievedHeadHeightRatio: achievedHead,
    achievedHeadTopRatio: (headTopY - top2) / h,
    note: '人脸过于贴边/过大，已按头顶锚点缩到越界 ≤ '
        '${(maxOutOfBounds * 100).toStringAsFixed(0)}%：'
        '头高比 ${achievedHead.toStringAsFixed(3)}（目标 '
        '${headHeightRatio.toStringAsFixed(3)}），'
        '越界 ${(oob * 100).toStringAsFixed(1)}% 填底色',
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

/// 矩形越出画布的面积占比。0 表示完全落在画布内，1 表示完全在画布外。
///
/// 越界部分在合成时按 alpha = 0 处理（直接填底色），所以它不是错误，
/// 只是诊断信息 —— [CropSolution.outOfBoundsFraction] 与用户框选路径都用它。
double outOfBoundsFraction(RectD r, double cw, double ch) {
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
