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

  const RenderedImage({
    required this.rgb,
    required this.width,
    required this.height,
    required this.solidPixels,
  });
}

/// 摆正 + 裁剪 + 缩放 + 换底，一次成型。
///
/// [crop] 为**旋转空间**坐标；[plan] 负责旋转空间 ↔ 源图空间的换算。
/// 裁剪框越出源图的部分采样到 alpha = 0，于是直接得到底色 —— 不会有黑边。
RenderedImage renderComposite({
  required MipLevel mip,
  required int srcWidth,
  required int srcHeight,
  required RotationPlan plan,
  required RectD crop,
  required int outWidth,
  required int outHeight,
  required BackgroundRamp background,
}) {
  final Uint8List out = Uint8List(outWidth * outHeight * 3);
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

  return RenderedImage(
      rgb: out, width: outWidth, height: outHeight, solidPixels: solid);
}

/// 由裁剪框与输出高度推出预滤波倍数（整数，1 表示不降采样）。
int mipFactorFor(double cropHeight, int outHeight) {
  int factor = (cropHeight / outHeight).floor();
  if (factor < 1) factor = 1;
  if (factor > 16) factor = 16;
  return factor;
}

/// 成品缩略图：长边缩到 [maxEdge]，box 平均，纯 RGB。
RenderedImage downscaleRgb(RenderedImage src, int maxEdge) {
  final int longEdge = math.max(src.width, src.height);
  if (longEdge <= maxEdge) {
    return src;
  }
  final double s = maxEdge / longEdge;
  final int dw = math.max(1, (src.width * s).round());
  final int dh = math.max(1, (src.height * s).round());
  final Uint8List out = Uint8List(dw * dh * 3);
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
  return RenderedImage(
      rgb: out, width: dw, height: dh, solidPixels: src.solidPixels);
}
