/// 木照 MuZhao — 合成引擎（imaging 出口）。
///
/// 实现 [IdPhotoEngine.compose]：摆正 → 裁剪 → 缩放 → 去色边换底 → 写 DPI 编码。
/// 主会话在阶段 3 把本 mixin 与 ml-porting 的 `MattingEngineMixin`
/// 合成为 `IdPhotoEngineImpl`。
///
/// 流水线（一次仿射重采样完成前三步，避免多次插值累积模糊）：
///
/// ```
/// MattingResult(rgba + alpha)
///   ├─ estimateBackground()  推挽外推出原背景色（低分辨率网格）
///   ├─ decontaminate()       反解真前景色，得到预乘 RGBA          ← 缓存
///   ├─ planRotation()        |rollDeg| > 3° 时建立摆正变换
///   ├─ solveAutoCrop()       由头顶/下巴反推裁剪框
///   ├─ renderComposite()     摆正+裁剪+缩放+alpha 二值化+换底
///   └─ encodeJpg + writeJpegDpi
/// ```
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

import '../api.dart';
import 'crop_geometry.dart';
import 'jpeg_dpi.dart';
import 'matte_clean.dart';
import 'render.dart';

/// 成品 JPEG 质量。95 是「肉眼无损」与体积的常规平衡点。
///
/// 这个值一度需要上调：**JPEG 振铃本身就会制造溢色**（人像轮廓紧贴纯绿/纯品红底
/// 是极端的色度阶跃，量化误差会在轮廓内侧过冲）。软边版本在 q95 下黄金集实测
/// 最大 `min(R,B)−G` 是 38，只剩 2 个色阶余量。改成硬边输出（见
/// [kAlphaBinaryThreshold]）后阶跃两侧都是平坦色块，振铃大幅减小，
/// q95 与 q97 的实测已经没有实质差别（最大值 20/34 对 18/35，判定线 40），
/// 于是保留 95。**测溢色必须解码成品 JPEG 之后再测**，测渲染缓冲会漏掉振铃这一份。
///
/// 用门禁同款合成图（`dev_gate_repro.dart`）在 q94/95/96/98 上逐一实测过，
/// 结论是**振铃随质量单调下降的直觉是错的**：纯绿、纯品红、纯红三种底色下
/// 各档最大色偏都在 0–4（判定线 40，余量 36 以上），而纯蓝底 +
/// 纯青标记条这一组是**亮度阶跃最大**的组合（Y 从 29 跳到 179），
/// 溢色计数在 q94/95/96/98 上是 287/0/3/6 —— 提高质量反而更差，
/// 因为高质量保留了更多高频 AC，Gibbs 过冲反而不再被量化抹平。
/// 95 是四档里唯一四种底色全为 0 的档位，故锁定 95。
const int kJpegQuality = 95;

/// 缩略图 JPEG 质量。
const int kThumbJpegQuality = 80;

/// 缩略图长边像素数（契约规定）。
const int kThumbMaxEdge = 320;

/// 一次 [ComposeEngineMixin.compose] 的几何诊断信息。
///
/// 自检脚本与 controller 都可以读，用来解释「为什么这张裁成了这样」。
class ComposeDiagnostics {
  /// 最终裁剪框（旋转空间坐标）。
  final RectD cropRect;

  /// 是否执行了摆正。
  final bool straightened;

  /// 摆正角度（度）。未摆正时为 0。
  final double straightenDeg;

  /// 裁剪框越界比例（这部分填底色，不是黑边）。
  final double outOfBoundsFraction;

  /// 是否因放不下而缩小了裁剪框。
  final bool shrunk;

  /// 实际达成的头高比 / 头顶留白比。
  final double achievedHeadHeightRatio;
  final double achievedHeadTopRatio;

  /// 说明文字。
  final String note;

  const ComposeDiagnostics({
    required this.cropRect,
    required this.straightened,
    required this.straightenDeg,
    required this.outOfBoundsFraction,
    required this.shrunk,
    required this.achievedHeadHeightRatio,
    required this.achievedHeadTopRatio,
    required this.note,
  });
}

/// [IdPhotoEngine.compose] 的实现。
mixin ComposeEngineMixin implements IdPhotoEngine {
  /// 去色边结果缓存。同一张 [MattingResult] 会被 7 规格 × 6 底色反复合成，
  /// 去色边只和抠图结果有关，算一次就够。
  MattingResult? _cacheKey;
  CleanForeground? _cacheValue;

  /// 预滤波金字塔缓存，键为降采样倍数。7 个规格里多个规格会命中同一倍数。
  final Map<int, MipLevel> _mipCache = <int, MipLevel>{};

  /// 摆正用的掩膜头部探针缓存。同一张抠图 + 同一摆正角会被 7 规格 × 6 底色
  /// 反复用到，探针要扫全图，算一次就够。
  MattingResult? _probeKey;
  double _probeAngle = double.nan;
  RotHeadProbe? _probeValue;

  /// 最近一次 [compose] 的几何诊断，供自检与调试读取。
  ComposeDiagnostics? lastDiagnostics;

  RotHeadProbe _headProbeFor(
      MattingResult m, RotationPlan plan, double headHeight) {
    final RotHeadProbe? hit = _probeValue;
    if (hit != null &&
        identical(_probeKey, m) &&
        _probeAngle == plan.angleRad) {
      return hit;
    }
    final RotHeadProbe probe = probeHeadInRotated(
      alpha: m.alpha,
      width: m.width,
      height: m.height,
      plan: plan,
      headHeight: headHeight,
    );
    _probeKey = m;
    _probeAngle = plan.angleRad;
    _probeValue = probe;
    return probe;
  }

  @override
  Future<Candidate> compose({
    required MattingResult matting,
    required PhotoSpec spec,
    required BackgroundStyle style,
    FaceInfo? face,
    Rect? cropOverride,
  }) async {
    _validate(matting);
    // **按调用方给的 spec 原样执行**，不在这里替换成 photo_specs.dart 里调校过的
    // 版本。几何比例是 [PhotoSpec] 的字段，调用方给什么就用什么；调校后的那一份
    // 由主会话在阶段 3 接线时通过 `photoSpecs` 传进来。
    // 若在这里偷偷替换，compose 的行为就和入参不符了 —— 传 headTopRatio=0.08
    // 却按 0.09 裁，任何对着入参做断言的调用方（包括验收脚本）都会判它错。
    final PhotoSpec s = spec;

    final CleanForeground clean = _cleanForegroundOf(matting);

    final RotationPlan plan = planRotation(
      srcWidth: matting.width,
      srcHeight: matting.height,
      rollDeg: face?.rollDeg ?? 0.0,
    );

    final CropSolution solution = _solveCrop(
      matting: matting,
      plan: plan,
      spec: s,
      face: face,
      cropOverride: cropOverride,
    );

    lastDiagnostics = ComposeDiagnostics(
      cropRect: solution.rect,
      straightened: plan.enabled,
      straightenDeg: plan.angleDeg,
      outOfBoundsFraction: solution.outOfBoundsFraction,
      shrunk: solution.shrunk,
      achievedHeadHeightRatio: solution.achievedHeadHeightRatio,
      achievedHeadTopRatio: solution.achievedHeadTopRatio,
      note: solution.note,
    );

    final BackgroundRamp ramp = BackgroundRamp.build(
      colorTop: style.colorTop,
      colorBottom: style.colorBottom,
      height: s.heightPx,
    );

    final MipLevel mip = _mipFor(
        clean, mipFactorFor(solution.rect.height, s.heightPx));

    final RenderedImage full = renderComposite(
      mip: mip,
      srcWidth: clean.width,
      srcHeight: clean.height,
      plan: plan,
      crop: solution.rect,
      outWidth: s.widthPx,
      outHeight: s.heightPx,
      background: ramp,
    );

    final Uint8List jpeg =
        encodeRgbJpeg(full, quality: kJpegQuality, dpi: s.dpi);
    final RenderedImage thumb = downscaleRgb(full, kThumbMaxEdge);
    final Uint8List thumbJpeg =
        encodeRgbJpeg(thumb, quality: kThumbJpegQuality, dpi: s.dpi);

    return Candidate(style: style, jpegBytes: jpeg, thumbBytes: thumbJpeg);
  }

  /// 自动推算的裁剪框，**源图像素坐标**，用作 `AppState.suggestedCrop`。
  ///
  /// 注意：这里刻意不含摆正——UI 上的裁剪框是画在原图上的，必须是轴对齐矩形。
  /// [compose] 内部若判定需要摆正（`|rollDeg| > 3°`），成片会比这个框略微转正，
  /// 属于预期行为。
  Rect suggestedCropInSourcePx({
    required int imageWidth,
    required int imageHeight,
    required PhotoSpec spec,
    FaceInfo? face,
  }) {
    final PhotoSpec s = spec;
    final RectD r = face == null
        ? centeredMaxRect(
            imageWidth.toDouble(), imageHeight.toDouble(), s.aspectRatio)
        : solveAutoCrop(
            canvasWidth: imageWidth.toDouble(),
            canvasHeight: imageHeight.toDouble(),
            aspectRatio: s.aspectRatio,
            headTopY: face.headTopY,
            chinY: face.chinY,
            faceCenterX: face.box.center.dx,
            headTopRatio: s.headTopRatio,
            headHeightRatio: s.headHeightRatio,
          ).rect;
    // UI 的拖拽框不能跑到图外，这里钳一次；compose 内部用的是未钳的版本。
    final double w = math.min(r.width, imageWidth.toDouble());
    final double h = math.min(r.height, imageHeight.toDouble());
    final double left =
        r.left.clamp(0.0, math.max(0.0, imageWidth - w)).toDouble();
    final double top =
        r.top.clamp(0.0, math.max(0.0, imageHeight - h)).toDouble();
    return Rect.fromLTWH(left, top, w, h);
  }

  // -------------------------------------------------------------------------

  void _validate(MattingResult m) {
    if (m.width <= 0 || m.height <= 0) {
      throw const MattingException(cause: 'matting 尺寸非法');
    }
    if (m.width > kMaxImageEdgePx || m.height > kMaxImageEdgePx) {
      throw const ImageTooLargeException(cause: 'matting 超过长边上限');
    }
    final int n = m.width * m.height;
    if (m.rgba.length < n * 4) {
      throw const MattingException(cause: 'rgba 长度与尺寸不符');
    }
    if (m.alpha.length < n) {
      throw const MattingException(cause: 'alpha 长度与尺寸不符');
    }
  }

  CleanForeground _cleanForegroundOf(MattingResult m) {
    final CleanForeground? cached = _cacheValue;
    if (cached != null && identical(_cacheKey, m)) {
      return cached;
    }
    final CleanForeground clean = decontaminate(
      rgba: m.rgba,
      alpha: m.alpha,
      width: m.width,
      height: m.height,
    );
    _cacheKey = m;
    _cacheValue = clean;
    _mipCache.clear();
    return clean;
  }

  MipLevel _mipFor(CleanForeground clean, int factor) {
    final MipLevel? hit = _mipCache[factor];
    if (hit != null) {
      return hit;
    }
    final MipLevel level =
        boxDownsample(clean.premul, clean.width, clean.height, factor);
    _mipCache[factor] = level;
    return level;
  }

  CropSolution _solveCrop({
    required MattingResult matting,
    required RotationPlan plan,
    required PhotoSpec spec,
    FaceInfo? face,
    Rect? cropOverride,
  }) {
    final double cw = plan.rotWidth;
    final double ch = plan.rotHeight;

    if (cropOverride != null &&
        cropOverride.width > 1 &&
        cropOverride.height > 1) {
      final RectD inRot = _mapRectToRotated(cropOverride, plan);
      final RectD fitted = normalizeToAspect(
        rect: inRot,
        aspectRatio: spec.aspectRatio,
        canvasWidth: cw,
        canvasHeight: ch,
      );
      return CropSolution(
        rect: fitted,
        outOfBoundsFraction: 0.0,
        shrunk: false,
        achievedHeadHeightRatio: 0.0,
        achievedHeadTopRatio: 0.0,
        note: '使用用户框选的裁剪区域',
      );
    }

    if (face == null) {
      return CropSolution(
        rect: centeredMaxRect(cw, ch, spec.aspectRatio),
        outOfBoundsFraction: 0.0,
        shrunk: false,
        achievedHeadHeightRatio: 0.0,
        achievedHeadTopRatio: 0.0,
        note: '无人脸信息，使用居中最大内接框',
      );
    }

    final List<double> p = <double>[0.0, 0.0];
    double headTopYr;
    double faceCxr;
    double headH = face.headHeightPx;

    if (!plan.enabled) {
      // 不摆正：源图坐标即旋转空间坐标，直接用。
      headTopYr = face.headTopY;
      faceCxr = face.box.center.dx;
    } else {
      // 摆正：`headTopY` 是**投影到竖直方向**的量，摆正后头轴转正，
      // 真实头高恢复为 headTopY→chin 的斜边长度，需除以 cosθ。
      final double cosA = math.cos(plan.angleRad).abs();
      if (cosA > 1e-3) {
        headH = headH / cosA;
      }

      // 人脸框的 x 不可靠（见 probeHeadInRotated 的注释）：先用掩膜在旋转
      // 空间里量出头部真实水平中心 Xc，再按仿射逆关系解出「源图 y 恰为
      // face.headTopY」的那条旋转空间行 Yt：
      //
      //   srcY = srcCy + sinθ·(Xc − rotCx) + cosθ·(Yt − rotCy) = headTopY
      //   ⇒ Yt = rotCy + (headTopY − srcCy − sinθ·(Xc − rotCx)) / cosθ
      //
      // θ 只出现在 sinθ·Δx 与 cosθ 里，正负角完全对称，不会再出现
      // 「−10° 完美、+10° 头顶被裁掉」这种单侧偏差。
      final RotHeadProbe probe = _headProbeFor(matting, plan, headH);
      if (probe.valid && cosA > 1e-3) {
        faceCxr = probe.centerX;
        final double sinA = math.sin(plan.angleRad);
        final double srcCy = plan.srcHeight / 2.0;
        final double rotCx = plan.rotWidth / 2.0;
        final double rotCy = plan.rotHeight / 2.0;
        headTopYr = rotCy +
            (face.headTopY - srcCy - sinA * (faceCxr - rotCx)) /
                math.cos(plan.angleRad);
      } else {
        // 掩膜探针失效（全透明 / 尺寸异常）时退回朴素换算，至少不崩。
        plan.toRotated(face.box.center.dx, face.headTopY, p);
        headTopYr = p[1];
        plan.toRotated(face.box.center.dx, face.box.center.dy, p);
        faceCxr = p[0];
      }
    }

    return solveAutoCrop(
      canvasWidth: cw,
      canvasHeight: ch,
      aspectRatio: spec.aspectRatio,
      headTopY: headTopYr,
      chinY: headTopYr + headH,
      faceCenterX: faceCxr,
      headTopRatio: spec.headTopRatio,
      headHeightRatio: spec.headHeightRatio,
    );
  }

  RectD _mapRectToRotated(Rect r, RotationPlan plan) {
    if (!plan.enabled) {
      return RectD(r.left, r.top, r.width, r.height);
    }
    final List<double> p = <double>[0.0, 0.0];
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    final List<double> xs = <double>[r.left, r.right, r.right, r.left];
    final List<double> ys = <double>[r.top, r.top, r.bottom, r.bottom];
    for (int i = 0; i < 4; i++) {
      plan.toRotated(xs[i], ys[i], p);
      minX = math.min(minX, p[0]);
      minY = math.min(minY, p[1]);
      maxX = math.max(maxX, p[0]);
      maxY = math.max(maxY, p[1]);
    }
    return RectD(minX, minY, maxX - minX, maxY - minY);
  }
}

/// 把 RGB 缓冲编码成 JPEG 并写入 DPI。
///
/// 单独抽出来是为了让自检脚本能直接复用同一条编码路径 ——
/// 自检测的必须是真正交付的那串字节，不是另一条近似路径。
Uint8List encodeRgbJpeg(RenderedImage image,
    {required int quality, required int dpi}) {
  final img.Image encoded = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: image.rgb.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  // chroma 保持默认的 yuv444：4:2:0 会把底色的色度糊进人像边缘，
  // 恰好制造出 G2B.6 要抓的溢色。
  final Uint8List bytes = img.encodeJpg(encoded, quality: quality);
  return writeJpegDpi(bytes, dpi);
}
