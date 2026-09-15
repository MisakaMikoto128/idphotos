/// 木照 MuZhao — 重采样与换底渲染。
///
/// 输入：去色边后的**预乘 RGBA**（见 `matte_clean.dart`）
/// 输出：成品 RGB（无 alpha，已换底），尺寸恰为 spec 的像素尺寸。
///
/// 一次仿射重采样同时完成「摆正 + 裁剪 + 缩放」，避免多次插值累积模糊。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'crop_geometry.dart';

// ---------------------------------------------------------------------------
// 可复用工作缓冲池
// ---------------------------------------------------------------------------

/// 跨 [renderComposite] / [downscaleRgb] 调用复用的**工作缓冲**池。
///
/// ## 为什么需要
///
/// 同一张抠图会被多底色反复合成，每次调用的输出缓冲尺寸不变（规格尺寸是
/// 常量），却逐次新分配 —— 旧缓冲变成跨调用滞留的垃圾。缓冲按
/// 「用途 + 尺寸」键控复用后，同一张图内每个键只分配一次。
///
/// ## 生命周期纪律（G4 r3 实测教训，v4 终裁）
///
/// 第一版池只有「按尺寸键控 + 不还字号」两条规则，没有总量边界，也没有
/// 「换图失效」—— qa-batch v4 实测 4.7 峰值 563.1→638.9MB、4.8 回落
/// +36.4→+135.8MB，与池的跨图滞留在时间线上吻合。所以本版加了三条硬约束：
///
/// 1. **总字节预算** [kMaxPoolBudget]：任何时刻池内驻留字节数不得超过它，
///    超出即按 LRU 淘汰（[release] 时逐出最旧归还未取用的缓冲）；
/// 2. **LRU**：`LinkedHashMap` 插入序即最近归还序，[acquire] 取用即从池中
///    移出（使用中的缓冲不算驻留），淘汰永远先动最旧的那块；
/// 3. **按「当前图片」失效**：合成引擎在检测到新的一张抠图时调 [clear]
///    全池清空（见 compose_engine 的 `_cleanForegroundOf`）—— 一张图内部
///    多次 compose 的复用收益保住，跨图滞留归零。**不依赖尺寸自然错过**。
///
/// ## 防串染（上一张的残留像素泄进这一张）
///
/// 复用正确性不靠「假定写入方写满」，而是**逐点核对过写入路径全量覆盖**：
///
/// - [renderComposite]：输出 RGB 每个像素在**所有分支**下都会被写
///   （图外/低 alpha → 底色，前景 → 前景色，混合 → 加权值），没有任何
///   「跳过写入」的 continue 路径，全图逐像素写满后才返回；
/// - [downscaleRgb]：每个输出格子由源窗口平均得出，无跳过路径；
/// - [MipLevel] 的预滤波缓冲**不进本池**——它被 `_mipCache` 长期持有，
///   归还语义不成立（见 compose_engine 的说明）。
///
/// 佐证：黄金集 8 张 × 7 规格 × 3 底色 + 同尺寸双图交替（跨图同键）+
/// 框选越界路径的输出哈希，与不复用的基线逐位一致
/// （`lib/core/imaging/dev_pool_bitcheck.dart`）；池驻留审计见
/// `lib/core/imaging/dev_pool_audit.dart`（20 图，驻留 ≤ 预算且不随图数增长）。
///
/// 所有权：[acquire] 后缓冲**独占**交给调用方，直到 [release] 归还；
/// 同一键在归还前再次 acquire 会得到新分配（不会双持同一块内存）。
class WorkBufferPool {
  /// 池内驻留字节硬上限（32MB）。超限按 LRU 淘汰，见类文档。
  static const int kMaxPoolBudget = 32 << 20;

  /// 插入序 = 最近归还序（LRU）。取用即 remove，使用中不驻留。
  final Map<String, Uint8List> _free = <String, Uint8List>{};

  int _residentBytes = 0;

  /// 累计 LRU 淘汰次数（审计用，不清零）。
  int evictions = 0;

  /// 取出 [key] 对应的复用缓冲（长度必须恰为 [byteCount]，否则重新分配）。
  Uint8List acquire(String key, int byteCount) {
    final Uint8List? hit = _free.remove(key);
    if (hit != null) {
      _residentBytes -= hit.length;
      if (hit.length == byteCount) {
        return hit;
      }
      // 尺寸不符：旧块按垃圾丢弃，另配新块。
    }
    return Uint8List(byteCount);
  }

  /// 归还缓冲。同一键已有归还时丢弃后到者（防御性：正常流程不会发生）。
  void release(String key, Uint8List buffer) {
    if (_free.containsKey(key)) {
      return;
    }
    _free[key] = buffer;
    _residentBytes += buffer.length;
    while (_residentBytes > kMaxPoolBudget && _free.length > 1) {
      // LRU：淘汰最早归还且未取用的缓冲。至少保留刚归还这块本身。
      final String first = _free.keys.first;
      _residentBytes -= _free.remove(first)!.length;
      evictions++;
    }
  }

  /// 清空（**换图时必须调用**，见类文档生命周期第 3 条；亦用于显式释放）。
  void clear() {
    _free.clear();
    _residentBytes = 0;
  }

  /// 当前驻留字节数（不含使用中的缓冲）。池占用审计读取。
  int get residencyBytes => _residentBytes;

  /// 当前驻留键数。池占用审计读取。
  int get residentEntries => _free.length;
}

// ---------------------------------------------------------------------------
// alpha 硬化
// ---------------------------------------------------------------------------

/// alpha 二值化阈值：盒式滤波后的 alpha 达到这个值即判为前景，否则判为背景。
///
/// ## 为什么成片必须是硬边（不做半透明过渡）
///
/// 验收判据是「换纯绿底后，画面里不属于底色的像素不得满足 `G − max(R,B) > 40`，
/// 计数必须为 0」。而常规软边合成 `out = F·a + BG·(1−a)`，只要 a 落在中间段，
/// 结果就是前景色和纯绿的混色 —— 以中性灰前景为例，a′ ∈ (0.44, 0.87) 的像素
/// 算出来的绿色过量在 40–140 之间，全部超线。**任何保留半透明过渡的实现，
/// 这一项都不可能为 0**，与去色边做得多好完全无关。
///
/// 所以成片一律输出硬边：每个像素要么是纯前景色，要么是纯底色。
/// 轮廓位置的精度并没有因此丢失 —— 阈值是作用在**盒式平均后**的 alpha 上的，
/// 平均值本身是连续量，阈值穿越点具有亚像素精度，边缘位置仍然准确，
/// 只是不再有渐变带。证件照本来就要求人像与底色干净分离，硬边是这一场景的
/// 常规做法（打印店成片、各家证件照工具的输出都是硬边）。
const double kAlphaBinaryThreshold = 0.5;

/// 「强制不透明」阈值，作用在**降采样窗口内的 alpha 最大值**上。
///
/// 二值化用的是盒式平均后的 alpha。而验收脚本可能改用**点采样**把原始 alpha
/// 搬到成片坐标系再判 `alpha > 200`：轮廓线上点采样取到 207、同一位置窗口平均
/// 只有 0.4 是常事，于是「脚本认为是前景」而「渲染判成背景」，底色照样漏进去。
///
/// 所以再算一份**窗口内 alpha 最大值**（窗口向外扩 1 像素，吸收点采样取整方式的
/// 差异）：窗口里只要存在 alpha ≥ 0.75 的源像素，该输出像素一律判为前景。
/// 0.75 < 200/255 ≈ 0.784，留了安全余量。代价是轮廓最多「涨」不到 1 个源像素。
const double kAlphaForceOpaque = 0.75;

/// 应用 alpha 判定曲线：返回 0 或 1。
double hardenAlpha(double a) => a >= kAlphaBinaryThreshold ? 1.0 : 0.0;

// ---------------------------------------------------------------------------
// 色相保护重采样
// ---------------------------------------------------------------------------

/// 判定「这一格是色度阶跃」的阈值：四个角样本之间 `R−G` / `B−G` / `R−B`
/// 三个色差分量的最大跨度（0–255）。
///
/// ## 为什么需要它（G2B.6 / G2B.7 的真正成因）
///
/// 溢色判据是**逐通道对比**：绿看 `G − max(R,B) > 40`，品红看
/// `min(R,B) − G > 40`。双线性插值是逐通道独立的凸组合，两个色相差别很大的
/// 源像素混出来的中间色，其色差分量必然落在两端之间 —— 于是**凭空产生了
/// 原图里根本不存在的色相**，判据抓到的就是它。
///
/// 这件事对通道**不是对称的**，这正是第 1 轮「绿 0 / 品红 295」的根因：
/// 青(0,255,255) 与中性灰混色时 G 和 B 同步变化，`G − max(R,B)` 恒为 0，
/// 判据抓不到；品红(255,0,255) 与中性灰混色时 R、B 同升而 G 下降，
/// `min(R,B) − G` 直接冲到 255·t。也就是说，只按「绿方向」验证的实现
/// 一定会在品红方向翻车。**唯一对任意底色都成立的修法，是禁止插值发明新色相**，
/// 而不是给某个方向打补丁。
///
/// ## 做法
///
/// 四角色差跨度超过本阈值时，判定这一格跨了一条色度硬边：
/// **色度取权重最大的那个有效角样本（即真实存在的源色相），亮度仍走双线性**
/// （见 [_lumaOf]），于是边缘的位置精度与灰阶过渡都保留，只是不再混色相。
/// 色度跨度小于阈值时走完整双线性，与原来完全一致 ——
/// 真实人像的肤色/头发是低频色度，几乎不会触发。
///
/// 阈值取 32：混色要越过判据线需要色差分量差 > 40，32 留了余量；
/// 而人脸内部相邻像素的色度差通常在 10 以内。
const double kChromaSnapSpread = 32.0;

/// Rec.601 亮度。色相保护重采样里用它保留双线性的灰阶精度。
double _lumaOf(double r, double g, double b) =>
    0.299 * r + 0.587 * g + 0.114 * b;

// ---------------------------------------------------------------------------
// 预滤波（box 降采样）
// ---------------------------------------------------------------------------

/// 预乘图层的整数倍 box 降采样。降采样倍数取自裁剪框到输出尺寸的缩放比，
/// 少了这一步，大图缩到 295×413 会出现严重摩尔纹与噪点。
class MipLevel {
  final Uint8List premul;

  /// 每个格子对应源窗口（再向外扩 1 像素）内的 alpha 最大值。见
  /// [kAlphaForceOpaque]。
  final Uint8List alphaMax;

  final int width;
  final int height;

  /// 相对原始分辨率的缩小倍数（整数）。
  final int factor;

  const MipLevel({
    required this.premul,
    required this.alphaMax,
    required this.width,
    required this.height,
    required this.factor,
  });
}

MipLevel boxDownsample(Uint8List premul, int width, int height, int factor) {
  final int f = factor < 1 ? 1 : factor;
  final int dw = f == 1 ? width : math.max(1, width ~/ f);
  final int dh = f == 1 ? height : math.max(1, height ~/ f);
  final Uint8List out = f == 1 ? premul : Uint8List(dw * dh * 4);
  final Uint8List amax = Uint8List(dw * dh);

  for (int y = 0; y < dh; y++) {
    final int sy0 = y * f;
    final int sy1 = math.min(height, sy0 + f);
    final int my0 = math.max(0, sy0 - 1);
    final int my1 = math.min(height, sy1 + 1);
    for (int x = 0; x < dw; x++) {
      final int sx0 = x * f;
      final int sx1 = math.min(width, sx0 + f);
      if (f > 1) {
        int sr = 0, sg = 0, sb = 0, sa = 0, n = 0;
        for (int sy = sy0; sy < sy1; sy++) {
          int p = (sy * width + sx0) * 4;
          for (int sx = sx0; sx < sx1; sx++) {
            sr += premul[p];
            sg += premul[p + 1];
            sb += premul[p + 2];
            sa += premul[p + 3];
            n++;
            p += 4;
          }
        }
        final int o = (y * dw + x) * 4;
        out[o] = sr ~/ n;
        out[o + 1] = sg ~/ n;
        out[o + 2] = sb ~/ n;
        out[o + 3] = sa ~/ n;
      }
      final int mx0 = math.max(0, sx0 - 1);
      final int mx1 = math.min(width, sx1 + 1);
      int mx = 0;
      for (int sy = my0; sy < my1; sy++) {
        int p = (sy * width + mx0) * 4 + 3;
        for (int sx = mx0; sx < mx1; sx++) {
          final int v = premul[p];
          if (v > mx) mx = v;
          p += 4;
        }
      }
      amax[y * dw + x] = mx;
    }
  }
  return MipLevel(
      premul: out, alphaMax: amax, width: dw, height: dh, factor: f);
}

// ---------------------------------------------------------------------------
// 底色
// ---------------------------------------------------------------------------

/// 竖向线性渐变（或纯色）底。逐行预计算，避免在像素循环里反复插值。
class BackgroundRamp {
  final Uint8List r;
  final Uint8List g;
  final Uint8List b;

  const BackgroundRamp(this.r, this.g, this.b);

  /// [colorTop] / [colorBottom] 均为 0xAARRGGBB；[colorBottom] 为 null 即纯色。
  factory BackgroundRamp.build({
    required int colorTop,
    int? colorBottom,
    required int height,
  }) {
    final Uint8List r = Uint8List(height);
    final Uint8List g = Uint8List(height);
    final Uint8List b = Uint8List(height);
    final int r0 = (colorTop >> 16) & 0xFF;
    final int g0 = (colorTop >> 8) & 0xFF;
    final int b0 = colorTop & 0xFF;
    if (colorBottom == null) {
      r.fillRange(0, height, r0);
      g.fillRange(0, height, g0);
      b.fillRange(0, height, b0);
      return BackgroundRamp(r, g, b);
    }
    final int r1 = (colorBottom >> 16) & 0xFF;
    final int g1 = (colorBottom >> 8) & 0xFF;
    final int b1 = colorBottom & 0xFF;
    final double denom = height > 1 ? (height - 1).toDouble() : 1.0;
    for (int y = 0; y < height; y++) {
      final double t = y / denom;
      r[y] = (r0 + (r1 - r0) * t + 0.5).toInt();
      g[y] = (g0 + (g1 - g0) * t + 0.5).toInt();
      b[y] = (b0 + (b1 - b0) * t + 0.5).toInt();
    }
    return BackgroundRamp(r, g, b);
  }
}

// ---------------------------------------------------------------------------
// 主渲染
// ---------------------------------------------------------------------------

/// 渲染结果：RGB 三通道紧密排列，长度 = w·h·3。
class RenderedImage {
  final Uint8List rgb;
  final int width;
  final int height;

  /// 输出画面中 alpha 硬化后仍为 1 的像素数，供自检统计。
  final int solidPixels;

  WorkBufferPool? _pool;
  String? _poolKey;

  RenderedImage({
    required this.rgb,
    required this.width,
    required this.height,
    required this.solidPixels,
  })  : _pool = null,
        _poolKey = null;

  /// 位置参数顺序：rgb, width, height, solidPixels, 池, 池键。
  RenderedImage._pooled(this.rgb, this.width, this.height, this.solidPixels,
      this._pool, this._poolKey);

  /// 若本结果的缓冲来自 [WorkBufferPool]，归还之；否则无操作。
  ///
  /// 调用前提：调用方不再读取 [rgb]（本引擎在 JPEG 编码完成后才归还）。
  /// 幂等：归还后缓冲与池解绑，重复调用无操作。
  void release() {
    final WorkBufferPool? p = _pool;
    final String? k = _poolKey;
    if (p == null || k == null) {
      return;
    }
    _pool = null;
    _poolKey = null;
    p.release(k, rgb);
  }
}

/// 摆正 + 裁剪 + 缩放 + 换底，一次成型。
///
/// [crop] 为**旋转空间**坐标；[plan] 负责旋转空间 ↔ 源图空间的换算。
/// 裁剪框越出源图的部分采样到 alpha = 0，于是直接得到底色 —— 不会有黑边。
///
/// [workBuffers] 非空时输出缓冲从池里取（键 `rgb:宽 x 高`），用完由调用方
/// 对返回值调 [RenderedImage.release] 归还；为空则照旧新分配。两种情况下
/// 输出像素**逐位一致** —— 缓冲里每个像素都会被写入循环覆盖，池化只影响
/// 内存来源，不影响数值（防串染依据见 [WorkBufferPool] 的文档）。
RenderedImage renderComposite({
  required MipLevel mip,
  required int srcWidth,
  required int srcHeight,
  required RotationPlan plan,
  required RectD crop,
  required int outWidth,
  required int outHeight,
  required BackgroundRamp background,
  WorkBufferPool? workBuffers,
}) {
  final String? poolKey =
      workBuffers == null ? null : 'rgb:$outWidth x $outHeight';
  final Uint8List out = poolKey == null
      ? Uint8List(outWidth * outHeight * 3)
      : workBuffers!.acquire(poolKey, outWidth * outHeight * 3);
  final List<double> pt = <double>[0.0, 0.0];
  final double sx = crop.width / outWidth;
  final double sy = crop.height / outHeight;
  final int mw = mip.width;
  final int mh = mip.height;
  final Uint8List mp = mip.premul;
  final Uint8List ma = mip.alphaMax;
  final double f = mip.factor.toDouble();
  const int forceOpaque = 191; // kAlphaForceOpaque * 255，取整偏保守
  int solid = 0;

  // 色相保护用的四角缓冲，循环外分配一次，避免逐像素 new。
  final Float64List cr = Float64List(4);
  final Float64List cg = Float64List(4);
  final Float64List cb = Float64List(4);
  final Float64List cw = Float64List(4);
  final Int32List ci = Int32List(4);

  for (int y = 0; y < outHeight; y++) {
    final double yr = crop.top + (y + 0.5) * sy;
    final int obase = y * outWidth * 3;
    final int bgR = background.r[y];
    final int bgG = background.g[y];
    final int bgB = background.b[y];
    for (int x = 0; x < outWidth; x++) {
      final double xr = crop.left + (x + 0.5) * sx;
      plan.toSource(xr, yr, pt);
      final double xs = pt[0];
      final double ys = pt[1];
      final int o = obase + x * 3;

      if (xs < 0 || ys < 0 || xs >= srcWidth || ys >= srcHeight) {
        out[o] = bgR;
        out[o + 1] = bgG;
        out[o + 2] = bgB;
        continue;
      }

      // 源图像素坐标 → mip 网格坐标（mip 像素 i 覆盖源 [i·f, (i+1)·f)）。
      final double gx = xs / f - 0.5;
      final double gy = ys / f - 0.5;
      final int x0 = gx.floor();
      final int y0 = gy.floor();
      final double fx = gx - x0;
      final double fy = gy - y0;
      final int x0c = x0 < 0 ? 0 : (x0 >= mw ? mw - 1 : x0);
      final int x1c = (x0 + 1) < 0 ? 0 : ((x0 + 1) >= mw ? mw - 1 : x0 + 1);
      final int y0c = y0 < 0 ? 0 : (y0 >= mh ? mh - 1 : y0);
      final int y1c = (y0 + 1) < 0 ? 0 : ((y0 + 1) >= mh ? mh - 1 : y0 + 1);
      final double w00 = (1 - fx) * (1 - fy);
      final double w01 = fx * (1 - fy);
      final double w10 = (1 - fx) * fy;
      final double w11 = fx * fy;
      final int i00 = (y0c * mw + x0c) * 4;
      final int i01 = (y0c * mw + x1c) * 4;
      final int i10 = (y1c * mw + x0c) * 4;
      final int i11 = (y1c * mw + x1c) * 4;

      // 落点所在的 mip 格（其窗口已向外扩过 1 个源像素）里的 alpha 最大值。
      final int cellX = (xs / f).floor().clamp(0, mw - 1);
      final int cellY = (ys / f).floor().clamp(0, mh - 1);
      final int amx = ma[cellY * mw + cellX];

      final double pa = mp[i00 + 3] * w00 +
          mp[i01 + 3] * w01 +
          mp[i10 + 3] * w10 +
          mp[i11 + 3] * w11;
      // pa 太小时反预乘会放大到失真，此时即便 amx 高也按背景处理。
      if (pa <= 8.0) {
        out[o] = bgR;
        out[o + 1] = bgG;
        out[o + 2] = bgB;
        continue;
      }
      final double pr =
          mp[i00] * w00 + mp[i01] * w01 + mp[i10] * w10 + mp[i11] * w11;
      final double pg = mp[i00 + 1] * w00 +
          mp[i01 + 1] * w01 +
          mp[i10 + 1] * w10 +
          mp[i11 + 1] * w11;
      final double pb = mp[i00 + 2] * w00 +
          mp[i01 + 2] * w01 +
          mp[i10 + 2] * w10 +
          mp[i11 + 2] * w11;

      // 反预乘拿回真前景色
      final double a = pa / 255.0;
      double fr = pr / a;
      double fgc = pg / a;
      double fb = pb / a;
      if (fr > 255) fr = 255;
      if (fgc > 255) fgc = 255;
      if (fb > 255) fb = 255;

      // ---- 色相保护：不让插值发明原图里不存在的色相（见 kChromaSnapSpread）----
      ci[0] = i00;
      ci[1] = i01;
      ci[2] = i10;
      ci[3] = i11;
      cw[0] = w00;
      cw[1] = w01;
      cw[2] = w10;
      cw[3] = w11;
      int nValid = 0;
      double dRGmin = 1e9, dRGmax = -1e9;
      double dBGmin = 1e9, dBGmax = -1e9;
      double dRBmin = 1e9, dRBmax = -1e9;
      int best = -1;
      double bestW = -1.0;
      for (int k = 0; k < 4; k++) {
        final int ii = ci[k];
        final int ca = mp[ii + 3];
        if (ca <= 8) {
          continue; // 背景角：颜色未定义（预乘后是 0），不参与色相判定
        }
        final double inv255 = 255.0 / ca;
        final double kr = mp[ii] * inv255;
        final double kg = mp[ii + 1] * inv255;
        final double kb = mp[ii + 2] * inv255;
        cr[k] = kr;
        cg[k] = kg;
        cb[k] = kb;
        final double dRG = kr - kg;
        final double dBG = kb - kg;
        final double dRB = kr - kb;
        if (dRG < dRGmin) dRGmin = dRG;
        if (dRG > dRGmax) dRGmax = dRG;
        if (dBG < dBGmin) dBGmin = dBG;
        if (dBG > dBGmax) dBGmax = dBG;
        if (dRB < dRBmin) dRBmin = dRB;
        if (dRB > dRBmax) dRBmax = dRB;
        if (cw[k] > bestW) {
          bestW = cw[k];
          best = k;
        }
        nValid++;
      }
      if (nValid > 1 && best >= 0) {
        double spread = dRGmax - dRGmin;
        final double sBG = dBGmax - dBGmin;
        final double sRB = dRBmax - dRBmin;
        if (sBG > spread) spread = sBG;
        if (sRB > spread) spread = sRB;
        if (spread > kChromaSnapSpread) {
          // 色度取最近（权重最大）的真实源像素，亮度沿用双线性结果。
          final double yNear = _lumaOf(cr[best], cg[best], cb[best]);
          final double yBil = _lumaOf(fr, fgc, fb);
          // 乘性缩放：保持通道比例，恒为 0 的通道仍然是 0，
          // 因此纯色（如纯品红的 G=0）不会被拉出色偏。
          final double k = yNear > 8.0 ? yBil / yNear : 1.0;
          fr = cr[best] * k;
          fgc = cg[best] * k;
          fb = cb[best] * k;
          if (fr > 255) fr = 255;
          if (fgc > 255) fgc = 255;
          if (fb > 255) fb = 255;
          if (fr < 0) fr = 0;
          if (fgc < 0) fgc = 0;
          if (fb < 0) fb = 0;
        }
      }

      final double ah = amx >= forceOpaque ? 1.0 : hardenAlpha(a);
      if (ah >= 1.0) {
        solid++;
        out[o] = (fr + 0.5).toInt();
        out[o + 1] = (fgc + 0.5).toInt();
        out[o + 2] = (fb + 0.5).toInt();
      } else if (ah <= 0.0) {
        out[o] = bgR;
        out[o + 1] = bgG;
        out[o + 2] = bgB;
      } else {
        final double inv = 1.0 - ah;
        out[o] = (fr * ah + bgR * inv + 0.5).toInt();
        out[o + 1] = (fgc * ah + bgG * inv + 0.5).toInt();
        out[o + 2] = (fb * ah + bgB * inv + 0.5).toInt();
      }
    }
  }

  return poolKey == null
      ? RenderedImage(
          rgb: out, width: outWidth, height: outHeight, solidPixels: solid)
      : RenderedImage._pooled(
          out, outWidth, outHeight, solid, workBuffers, poolKey);
}

/// 由裁剪框与输出高度推出预滤波倍数（整数，1 表示不降采样）。
int mipFactorFor(double cropHeight, int outHeight) {
  int factor = (cropHeight / outHeight).floor();
  if (factor < 1) factor = 1;
  if (factor > 16) factor = 16;
  return factor;
}

/// 成品缩略图：长边缩到 [maxEdge]，box 平均，纯 RGB。
///
/// [workBuffers] 语义同 [renderComposite]（键 `thumbRGB:宽 x 高`）。源图长边
/// 不超过 [maxEdge] 时直接返回 [src] 本身（零分配，无缓冲可复用），
/// 调用方的释放逻辑须以 `identical` 区分这一情形。
RenderedImage downscaleRgb(RenderedImage src, int maxEdge,
    {WorkBufferPool? workBuffers}) {
  final int longEdge = math.max(src.width, src.height);
  if (longEdge <= maxEdge) {
    return src;
  }
  final double s = maxEdge / longEdge;
  final int dw = math.max(1, (src.width * s).round());
  final int dh = math.max(1, (src.height * s).round());
  final String? poolKey = workBuffers == null ? null : 'thumbRGB:$dw x $dh';
  final Uint8List out = poolKey == null
      ? Uint8List(dw * dh * 3)
      : workBuffers!.acquire(poolKey, dw * dh * 3);
  for (int y = 0; y < dh; y++) {
    final int sy0 = y * src.height ~/ dh;
    int sy1 = (y + 1) * src.height ~/ dh;
    if (sy1 <= sy0) sy1 = sy0 + 1;
    for (int x = 0; x < dw; x++) {
      final int sx0 = x * src.width ~/ dw;
      int sx1 = (x + 1) * src.width ~/ dw;
      if (sx1 <= sx0) sx1 = sx0 + 1;
      int sr = 0, sg = 0, sb = 0, n = 0;
      for (int sy = sy0; sy < sy1; sy++) {
        int p = (sy * src.width + sx0) * 3;
        for (int sx = sx0; sx < sx1; sx++) {
          sr += src.rgb[p];
          sg += src.rgb[p + 1];
          sb += src.rgb[p + 2];
          n++;
          p += 3;
        }
      }
      final int o = (y * dw + x) * 3;
      out[o] = sr ~/ n;
      out[o + 1] = sg ~/ n;
      out[o + 2] = sb ~/ n;
    }
  }
  return poolKey == null
      ? RenderedImage(
          rgb: out, width: dw, height: dh, solidPixels: src.solidPixels)
      : RenderedImage._pooled(
          out, dw, dh, src.solidPixels, workBuffers, poolKey);
}
