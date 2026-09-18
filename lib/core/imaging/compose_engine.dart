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
///   ├─ planRotation()        |rollDeg| > kRollDeadZoneDeg 时建立摆正变换
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

  /// 渲染输出缓冲池（成品 RGB / 缩略图 RGB，键控「用途 + 尺寸」）。
  ///
  /// 一张图的多次合成里，输出缓冲尺寸只取决于规格（常量），复用后同一张图
  /// 内每个键只分配一次。**生命周期（G4 r3 教训，v4 终裁 4.7/4.8 恶化）**：
  /// 池带 32MB 总预算 + LRU 淘汰，且**换图即清空**（见 [_cleanForegroundOf]）
  /// —— 图内复用保住，跨图滞留归零，不依赖尺寸自然错过。预滤波
  /// （[MipLevel]）缓冲**刻意不进池**：它被 [_mipCache] 长期持有，
  /// 「归还后再发出」的语义不成立，其复用已由 mip 缓存本身承担。
  final WorkBufferPool _renderPool = WorkBufferPool();

  /// JPEG 编码画布缓存，键 `宽 x 高`。
  ///
  /// `img.Image.fromBytes` 会把输入像素**逐行拷贝**进画布（image 4.9.2
  /// image.dart 的 fromBytes 实现），每次编码白付一份 w×h×3。画布与尺寸
  /// 一一对应且编码器只读不写（_calculateYUV 经 getPixel 只读，4 通道才
  /// 会走 alpha 合成分支，本画布 3 通道），缓存后同一尺寸只拷一次，
  /// 之后每次编码把成片 RGB 整块 setRange 进画布 —— 字节不变，编码结果
  /// 逐位一致。
  ///
  /// 生命周期：画布内容在每次编码前被**全量覆盖**，跨图持有在字节上惰性；
  /// 但按「当前图片失效」纪律，换图时一并清空（[_cleanForegroundOf]），
  /// 每张图重建一次的成本只有一次 w×h×3 拷贝。
  final Map<String, img.Image> _encodeCanvas = <String, img.Image>{};

  /// JPEG 编码器实例缓存，键为质量档。
  ///
  /// image 4.9.2 的 JpegEncoder 构造函数要建两张 65535 槽的霍夫曼码表
  /// （_bitCode/_category，各 0.5MB 指针）加量化/DCT 表，每次 encodeJpg
  /// 新建实例等于每次编码白付 ~1MB 纯垃圾 —— 42 次合成 × 每次两档编码，
  /// 这是 compose 路径单笔最大的重复分配。实例跨 encode 复用是安全的：
  /// encode() 只读这些表，编码期状态（位缓冲等）在 encode 开头自复位，
  /// 输出只由 quality 与画布像素决定。
  final Map<int, img.JpegEncoder> _jpegEncoders = <int, img.JpegEncoder>{};

  /// 掩膜头部几何精化缓存（键：抠图对象 + 摆正角 + 人脸几何）。
  /// 同一张抠图会被 7 规格 × 6 底色反复合成，全图带状扫描算一次就够。
  MattingResult? _refineKey;
  double _refineAngle = double.nan;
  double _refineAnchor = double.nan;
  double _refineTop = double.nan;
  double _refineChin = double.nan;
  double _refineBoxW = double.nan;
  HeadMaskRefinement? _refineValue;

  /// 掩膜头部几何精化（发顶/下巴/水平中心），结果按输入缓存。
  HeadMaskRefinement _headRefinementFor(
    MattingResult m,
    RotationPlan plan,
    double anchorX,
    double headTopY,
    double chinY,
    double faceBoxWidth,
  ) {
    final HeadMaskRefinement? hit = _refineValue;
    if (hit != null &&
        identical(_refineKey, m) &&
        _refineAngle == plan.angleRad &&
        _refineAnchor == anchorX &&
        _refineTop == headTopY &&
        _refineChin == chinY &&
        _refineBoxW == faceBoxWidth) {
      return hit;
    }
    final HeadMaskRefinement r = refineHeadFromMask(
      alpha: m.alpha,
      width: m.width,
      height: m.height,
      plan: plan,
      anchorX: anchorX,
      headTopY: headTopY,
      chinY: chinY,
      faceBoxWidth: faceBoxWidth,
    );
    _refineKey = m;
    _refineAngle = plan.angleRad;
    _refineAnchor = anchorX;
    _refineTop = headTopY;
    _refineChin = chinY;
    _refineBoxW = faceBoxWidth;
    _refineValue = r;
    return r;
  }

  /// 最近一次 [compose] 的几何诊断，供自检与调试读取。
  ComposeDiagnostics? lastDiagnostics;

  // ---- 池占用审计（dev_pool_audit.dart / ml_release_memcheck 侧读取）----

  /// 渲染缓冲池当前驻留字节数（不含使用中的缓冲）。
  int get poolResidencyBytes => _renderPool.residencyBytes;

  /// 渲染缓冲池当前驻留键数。
  int get poolResidentEntries => _renderPool.residentEntries;

  /// 渲染缓冲池累计 LRU 淘汰次数。
  int get poolEvictions => _renderPool.evictions;

  /// 编码画布缓存当前条目数。
  int get encodeCanvasEntries => _encodeCanvas.length;

  /// 池驻留硬预算（字节）。
  static int get poolBudgetBytes => WorkBufferPool.kMaxPoolBudget;

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

    // 摆正角**无条件**取 [FaceInfo.rollDeg]，不做任何二次仲裁。
    //
    // 语义（阶段 6 P0 二次收紧）：`rollDeg` 是「待施加的摆正角」，引擎测不出
    // 时必须给 0.0（"放弃摆正"），由 ml-porting 决定信任度。imaging 侧曾落过
    // 一层「眼线为主 + 嘴线共识门」的多线融合覆盖（roll_fusion.dart），实测
    // 三条线同源于同一组 YuNet 眼睑关键点、强相关，104 组系列对照差 ±0.02°
    // （噪声级），救不回任何一张真实照片 —— 已删除，见 PITFALLS。
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
      workBuffers: _renderPool,
    );

    final Uint8List jpeg =
        _encodeRgbJpeg(full, quality: kJpegQuality, dpi: s.dpi);
    final RenderedImage thumb = downscaleRgb(full, kThumbMaxEdge,
        workBuffers: _renderPool);
    final Uint8List thumbJpeg =
        _encodeRgbJpeg(thumb, quality: kThumbJpegQuality, dpi: s.dpi);

    // 编码完成（缩略图是只读 full 得出的，也已完成）才把缓冲还给池。
    // 缩略图长边不足 320 时 downscaleRgb 返回 full 本身——release 幂等
    //（归还后缓冲与池解绑，重复调用无操作），无条件归还即可。
    full.release();
    thumb.release();

    return Candidate(style: style, jpegBytes: jpeg, thumbBytes: thumbJpeg);
  }

  /// 自动推算的裁剪框，**源图像素坐标**，用作 `AppState.suggestedCrop`。
  ///
  /// 注意：这里刻意不含摆正——UI 上的裁剪框是画在原图上的，必须是轴对齐矩形。
  /// [compose] 内部若判定需要摆正（`|rollDeg| > kRollDeadZoneDeg`，见
  /// `crop_geometry.dart`：10.0°，用户 2026-09-17 的产品决定），
  /// 成片会比这个框略微转正，属于预期行为。
  @override
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
    // ---- 换图边界：全量失效 ----
    // 新的一张抠图到达（对象身份变化）。按「当前图片失效」纪律，把渲染
    // 输出池与编码画布全部清空 —— 一张图内部多次 compose 的复用收益在
    // 上一张已兑现，跨图一个字节都不留（G4 r3：池不还字号是 4.7/4.8
    // 恶化的时间线主嫌）。mip 缓存同理（键是倍数，内容随图变）。
    _cacheKey = m;
    _cacheValue = null; // 先置空，防下方抛异常时留下旧图脏缓存
    _mipCache.clear();
    _renderPool.clear();
    _encodeCanvas.clear();
    final CleanForeground clean = decontaminate(
      rgba: m.rgba,
      alpha: m.alpha,
      width: m.width,
      height: m.height,
    );
    _cacheValue = clean;
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

  /// 引擎内缓存版 JPEG 编码：编码画布与编码器实例跨调用复用
  /// （见 [_encodeCanvas] / [_jpegEncoders] 的文档）。输出与"每次新建
  /// 画布 + 编码器"的朴素路径**逐位一致**——画布里的像素与朴素路径每次
  /// 新拷进去的完全相同，编码器输出只由 quality 与画布像素决定。
  Uint8List _encodeRgbJpeg(RenderedImage image,
      {required int quality, required int dpi}) {
    final String key = '${image.width} x ${image.height}';
    img.Image? canvas = _encodeCanvas[key];
    if (canvas == null) {
      canvas = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: image.rgb.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      _encodeCanvas[key] = canvas;
    } else {
      // 画布数据恰好 w×h×3（fromBytes 以 rowStride == dataStride 逐行满拷），
      // 长度按 image.rgb 钳制，防御包实现引入行填充。
      final Uint8List dst =
          Uint8List.view(canvas.data!.buffer, 0, image.rgb.length);
      dst.setRange(0, dst.length, image.rgb);
    }
    final img.JpegEncoder encoder = _jpegEncoders.putIfAbsent(
        quality, () => img.JpegEncoder(quality: quality));
    final Uint8List bytes =
        encoder.encode(canvas, chroma: img.JpegChroma.yuv444);
    return writeJpegDpi(bytes, dpi);
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
      final RectD inRot = _mapCropToRotated(cropOverride, plan);
      final RectD fitted = normalizeToAspect(
        rect: inRot,
        aspectRatio: spec.aspectRatio,
        canvasWidth: cw,
        canvasHeight: ch,
      );
      final double oob = outOfBoundsFraction(fitted, cw, ch);
      return CropSolution(
        rect: fitted,
        outOfBoundsFraction: oob,
        shrunk: false,
        achievedHeadHeightRatio: 0.0,
        achievedHeadTopRatio: 0.0,
        note: oob <= 1e-6
            ? '使用用户框选的裁剪区域'
            : '使用用户框选的裁剪区域，摆正后有 '
                '${(oob * 100).toStringAsFixed(1)}% 转出画布，按 alpha=0 填底色',
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
    double chinYr;
    double faceCxr;
    double headH = face.headHeightPx;
    final double faceBoxW = face.box.width;

    if (!plan.enabled) {
      // 不摆正：源图坐标即旋转空间坐标，直接用。
      headTopYr = face.headTopY;
      chinYr = face.chinY;
      faceCxr = face.box.center.dx;
    } else {
      // 摆正：`headTopY` 是**投影到竖直方向**的量，摆正后头轴转正，
      // 真实头高恢复为 headTopY→chin 的斜边长度，需除以 cosθ。
      final double cosA = math.cos(plan.angleRad).abs();
      if (cosA > 1e-3) {
        headH = headH / cosA;
      }

      // 人脸框的 x 不可靠（见 refineHeadFromMask 的文档）：先把人脸框中心
      // 映进旋转空间当锚点，掩膜精化（下面）会在锚点附近量出头部真实
      // 水平中心 Xc，再按仿射逆关系解出「源图 y 恰为 face.headTopY」的
      // 那条旋转空间行 Yt：
      //
      //   srcY = srcCy + sinθ·(Xc − rotCx) + cosθ·(Yt − rotCy) = headTopY
      //   ⇒ Yt = rotCy + (headTopY − srcCy − sinθ·(Xc − rotCx)) / cosθ
      //
      // θ 只出现在 sinθ·Δx 与 cosθ 里，正负角完全对称，不会再出现
      // 「−10° 完美、+10° 头顶被裁掉」这种单侧偏差。
      plan.toRotated(face.box.center.dx, face.box.center.dy, p);
      final double anchorX = p[0];
      final double sinA = math.sin(plan.angleRad);
      final double srcCy = plan.srcHeight / 2.0;
      final double rotCx = plan.rotWidth / 2.0;
      final double rotCy = plan.rotHeight / 2.0;
      headTopYr = rotCy +
          (face.headTopY - srcCy - sinA * (anchorX - rotCx)) /
              math.cos(plan.angleRad);
      chinYr = headTopYr + headH;
      faceCxr = anchorX;
    }

    // ---- 掩膜精化：headTopY 是人体测量学推算值，不是量出来的 ----
    // 头后仰大笑或检测框肥大时，推算头顶会掉进脸里（G4 1979d869：检测头顶
    // 957、真实发顶 420，成片发际被齐齐裁掉）。用 alpha 剪影向上量出真实
    // 发顶（只允许向上修，不允许往下压），水平中心换成分带质心。
    // 掩膜对不上（头顶附近无前景）时原样保留检测器几何。
    final HeadMaskRefinement ref = _headRefinementFor(
        matting, plan, faceCxr, headTopYr, chinYr, faceBoxW);
    if (ref.valid) {
      if (ref.hairTopY < headTopYr) {
        headTopYr = ref.hairTopY;
      }
      faceCxr = ref.centerX;
    }

    return solveAutoCrop(
      canvasWidth: cw,
      canvasHeight: ch,
      aspectRatio: spec.aspectRatio,
      headTopY: headTopYr,
      chinY: chinYr,
      faceCenterX: faceCxr,
      headTopRatio: spec.headTopRatio,
      headHeightRatio: spec.headHeightRatio,
    );
  }

  /// 把用户框选的矩形（源图坐标）搬进旋转空间，**尺寸原样保留**。
  ///
  /// ## 为什么不能取四角的轴对齐外接框（AABB）
  ///
  /// 用户框选表达的是两件事：**取哪块内容**（中心）和**主体多大**（尺寸）。
  /// 摆正只是把画面转正，不该改变后者。可 AABB 恒大于原矩形：
  ///
  /// ```
  /// W' = w·cosθ + h·sinθ,  H' = w·sinθ + h·cosθ
  /// θ=10°、295×413  →  362×458，[normalizeToAspect] 再撑到 362×507
  /// ```
  ///
  /// 裁剪框大了 22.7%，缩放到同样的 295×413 成品后，主体就只剩用户框选的
  /// 81.5%。更糟的是**用户无法纠正**：框得更紧，AABB 依然按同一比例放大，
  /// 只是基数变小。这是静默的、单向的、不可逆的构图篡改。
  ///
  /// 正确做法是把框**整体反旋转**：中心用 [RotationPlan.toRotated] 映射，
  /// 宽高原样带过去。这等价于「拿用户框的那个窗口，绕自己的中心转 −θ」，
  /// 是刚体变换，面积与主体尺度精确守恒（保留比例 100%）。
  /// 代价是窗口的四个角在源图里会探出用户框之外 —— 若探到图外，
  /// 那部分按 alpha=0 填底色，与自动取景路径的越界策略一致（见 [solveAutoCrop]），
  /// 不会出现黑边（G2B.9）。这部分占比据实写进 [CropSolution.outOfBoundsFraction]。
  ///
  /// 摆正角受 [kMaxRollDeg]=30° 钳制，不会出现宽高需要互换的情况。
  RectD _mapCropToRotated(Rect r, RotationPlan plan) {
    if (!plan.enabled) {
      return RectD(r.left, r.top, r.width, r.height);
    }
    final List<double> p = <double>[0.0, 0.0];
    plan.toRotated(r.center.dx, r.center.dy, p);
    return RectD(
        p[0] - r.width / 2.0, p[1] - r.height / 2.0, r.width, r.height);
  }
}
