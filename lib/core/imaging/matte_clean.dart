/// 木照 MuZhao — 去色边（decontamination）。
///
/// ## 为什么必须做
///
/// 抠图给出的 alpha 是软边。原图里一个边缘像素观测到的颜色其实是
///
/// ```
/// C = a·F + (1 − a)·B_orig
/// ```
///
/// 其中 `B_orig` 是**拍摄时的原背景色**。如果直接拿 `C` 当前景色去合成
///
/// ```
/// out = C·a + B_new·(1 − a)
/// ```
///
/// 就等于把 `(1 − a)·B_orig` 这一份原背景色留在了成片里。蓝底照片换白底后
/// 人物边缘会挂一圈青绿，就是这么来的（G2B.6 / G2B.7 用纯绿、纯品红这种
/// 极端底色专门放大这个缺陷）。
///
/// 正确做法是先把真前景色 `F` 反解出来（unpremultiply）：
///
/// ```
/// F = (C − (1 − a)·B_orig) / a
/// ```
///
/// 难点在于 `B_orig` 未知。本文件用 **push-pull 推挽插值**从确定背景区
/// （alpha 很低的像素）向前景边缘外推出一张平滑的背景估计图，再逐像素反解。
/// 背景估计跑在低分辨率网格上（长边 192），因为真实证件照的背景本来就是
/// 低频的，低分辨率足够且极快。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mem_ledger.dart';

/// alpha 低于此值的像素视为「确定背景」，用来喂 push-pull 的种子。
const double kBgSeedAlpha = 0.10;

/// alpha 高于此值的像素视为「确定前景」，无需反解（F = C）。
const double kFgSolidAlpha = 0.98;

/// alpha 高于此值的像素用作「局部实心前景色」的种子，喂给同一套推挽插值。
const double kFgSeedAlpha = 0.90;

/// 色度去溢上限：一次最多抹掉「背景色度 − 前景色度」这个向量的多大比例。
///
/// 见 [decontaminate] 里的说明。设成 1.0 会在 alpha 严重偏大时把边缘颜色
/// 整个拉成局部前景色，过于激进；0.6 足以压掉紫边又不会吃掉真实的边缘颜色。
const double kMaxChromaDespill = 0.6;

/// 背景估计网格长边像素数。
const int kBgGridMaxDim = 192;

/// 背景估计图。存储在低分辨率网格上，按需双线性采样到全分辨率。
class BackgroundEstimate {
  final int gridWidth;
  final int gridHeight;
  final Float32List r;
  final Float32List g;
  final Float32List b;
  final int srcWidth;
  final int srcHeight;

  /// 本图全部层级的字节占用（记账用，见 mem_ledger.dart）。
  final int ledgerBytes;

  BackgroundEstimate({
    required this.gridWidth,
    required this.gridHeight,
    required this.r,
    required this.g,
    required this.b,
    required this.srcWidth,
    required this.srcHeight,
    this.ledgerBytes = 0,
  });

  /// 在源图像素坐标 (x, y) 处双线性采样，结果写入 [out]（长度 ≥ 3，0–255）。
  void sampleAt(int x, int y, Float32List out) {
    final double gx = (x + 0.5) * gridWidth / srcWidth - 0.5;
    final double gy = (y + 0.5) * gridHeight / srcHeight - 0.5;
    final int x0 = gx.floor();
    final int y0 = gy.floor();
    final double fx = gx - x0;
    final double fy = gy - y0;
    final int x0c = x0.clamp(0, gridWidth - 1);
    final int x1c = (x0 + 1).clamp(0, gridWidth - 1);
    final int y0c = y0.clamp(0, gridHeight - 1);
    final int y1c = (y0 + 1).clamp(0, gridHeight - 1);
    final int i00 = y0c * gridWidth + x0c;
    final int i01 = y0c * gridWidth + x1c;
    final int i10 = y1c * gridWidth + x0c;
    final int i11 = y1c * gridWidth + x1c;
    final double w00 = (1 - fx) * (1 - fy);
    final double w01 = fx * (1 - fy);
    final double w10 = (1 - fx) * fy;
    final double w11 = fx * fy;
    out[0] = r[i00] * w00 + r[i01] * w01 + r[i10] * w10 + r[i11] * w11;
    out[1] = g[i00] * w00 + g[i01] * w01 + g[i10] * w10 + g[i11] * w11;
    out[2] = b[i00] * w00 + b[i01] * w01 + b[i10] * w10 + b[i11] * w11;
  }
}

class _Level {
  final int w;
  final int h;
  final Float32List r;
  final Float32List g;
  final Float32List b;
  final Float32List wt;
  _Level(this.w, this.h)
    : r = Float32List(w * h),
      g = Float32List(w * h),
      b = Float32List(w * h),
      wt = Float32List(w * h);
}

/// 从 alpha 很低的像素出发，推挽外推出整幅背景估计。
BackgroundEstimate estimateBackground({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  int gridMaxDim = kBgGridMaxDim,
}) => _pushPullField(
  rgba: rgba,
  alpha: alpha,
  width: width,
  height: height,
  gridMaxDim: gridMaxDim,
  seedBelow: true,
  seedAlpha: (kBgSeedAlpha * 255).round(),
);

/// 同一套推挽插值，种子换成「确定前景」像素，得到一张平滑的
/// **局部实心前景色**图。用于色度去溢：它回答「这个边缘像素附近，
/// 真正的人像本体是什么颜色」。
BackgroundEstimate estimateSolidForeground({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  int gridMaxDim = kBgGridMaxDim,
}) => _pushPullField(
  rgba: rgba,
  alpha: alpha,
  width: width,
  height: height,
  gridMaxDim: gridMaxDim,
  seedBelow: false,
  seedAlpha: (kFgSeedAlpha * 255).round(),
);

BackgroundEstimate _pushPullField({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  required int gridMaxDim,
  required bool seedBelow,
  required int seedAlpha,
}) {
  final int longEdge = math.max(width, height);
  final double s = longEdge <= gridMaxDim ? 1.0 : gridMaxDim / longEdge;
  final int gw = math.max(1, (width * s).round());
  final int gh = math.max(1, (height * s).round());

  final _Level base = _Level(gw, gh);
  final Float32List cnt = Float32List(gw * gh);

  final int seed = seedAlpha;
  double fbR = 0, fbG = 0, fbB = 0, fbN = 0;

  for (int y = 0; y < height; y++) {
    final int gy = math.min(gh - 1, y * gh ~/ height);
    final int rowA = y * width;
    final int rowP = rowA * 4;
    final int gRow = gy * gw;
    for (int x = 0; x < width; x++) {
      final int av = alpha[rowA + x];
      if (seedBelow ? av > seed : av < seed) {
        continue;
      }
      final int gx = math.min(gw - 1, x * gw ~/ width);
      final int gi = gRow + gx;
      final int p = rowP + x * 4;
      final double pr = rgba[p].toDouble();
      final double pg = rgba[p + 1].toDouble();
      final double pb = rgba[p + 2].toDouble();
      base.r[gi] += pr;
      base.g[gi] += pg;
      base.b[gi] += pb;
      cnt[gi] += 1.0;
      fbR += pr;
      fbG += pg;
      fbB += pb;
      fbN += 1.0;
    }
  }

  for (int i = 0; i < cnt.length; i++) {
    final double c = cnt[i];
    if (c > 0) {
      base.r[i] /= c;
      base.g[i] /= c;
      base.b[i] /= c;
      base.wt[i] = 1.0;
    }
  }

  // 整幅图完全没有背景像素（罕见：alpha 全 255）——回退到中性灰，
  // 此时 (1 − a) 恒为 0，反解本来也不会动任何像素。
  final double fallbackR = fbN > 0 ? fbR / fbN : 128.0;
  final double fallbackG = fbN > 0 ? fbG / fbN : 128.0;
  final double fallbackB = fbN > 0 ? fbB / fbN : 128.0;

  // ---- push：逐级下采样，权重即「已知程度」----
  final List<_Level> levels = <_Level>[base];
  int levelBytes = base.r.length * 16 + cnt.length * 4; // r/g/b/wt + cnt
  while (levels.last.w > 1 || levels.last.h > 1) {
    final _Level c = levels.last;
    final int pw = math.max(1, (c.w + 1) >> 1);
    final int ph = math.max(1, (c.h + 1) >> 1);
    final _Level p = _Level(pw, ph);
    levelBytes += pw * ph * 16;
    for (int y = 0; y < ph; y++) {
      for (int x = 0; x < pw; x++) {
        double sr = 0, sg = 0, sb = 0, sw = 0;
        int n = 0;
        for (int dy = 0; dy < 2; dy++) {
          final int cy = y * 2 + dy;
          if (cy >= c.h) continue;
          for (int dx = 0; dx < 2; dx++) {
            final int cx = x * 2 + dx;
            if (cx >= c.w) continue;
            final int ci = cy * c.w + cx;
            final double cw = c.wt[ci];
            n++;
            sw += cw;
            sr += c.r[ci] * cw;
            sg += c.g[ci] * cw;
            sb += c.b[ci] * cw;
          }
        }
        final int pi = y * pw + x;
        if (sw > 0) {
          p.r[pi] = sr / sw;
          p.g[pi] = sg / sw;
          p.b[pi] = sb / sw;
        }
        p.wt[pi] = n > 0 ? (sw / n).clamp(0.0, 1.0).toDouble() : 0.0;
      }
    }
    levels.add(p);
  }

  // ---- pull：自顶向下补洞 ----
  final _Level top = levels.last;
  for (int i = 0; i < top.wt.length; i++) {
    if (top.wt[i] <= 0) {
      top.r[i] = fallbackR;
      top.g[i] = fallbackG;
      top.b[i] = fallbackB;
    }
    top.wt[i] = 1.0;
  }
  for (int li = levels.length - 2; li >= 0; li--) {
    final _Level c = levels[li];
    final _Level p = levels[li + 1];
    for (int y = 0; y < c.h; y++) {
      for (int x = 0; x < c.w; x++) {
        final int ci = y * c.w + x;
        final double w = c.wt[ci];
        if (w >= 1.0) continue;
        final double px = (x - 0.5) / 2.0;
        final double py = (y - 0.5) / 2.0;
        final int px0 = px.floor();
        final int py0 = py.floor();
        final double fx = px - px0;
        final double fy = py - py0;
        final int ax = px0.clamp(0, p.w - 1);
        final int bx = (px0 + 1).clamp(0, p.w - 1);
        final int ay = py0.clamp(0, p.h - 1);
        final int by = (py0 + 1).clamp(0, p.h - 1);
        final double w00 = (1 - fx) * (1 - fy);
        final double w01 = fx * (1 - fy);
        final double w10 = (1 - fx) * fy;
        final double w11 = fx * fy;
        final int i00 = ay * p.w + ax;
        final int i01 = ay * p.w + bx;
        final int i10 = by * p.w + ax;
        final int i11 = by * p.w + bx;
        final double pr =
            p.r[i00] * w00 + p.r[i01] * w01 + p.r[i10] * w10 + p.r[i11] * w11;
        final double pg =
            p.g[i00] * w00 + p.g[i01] * w01 + p.g[i10] * w10 + p.g[i11] * w11;
        final double pb =
            p.b[i00] * w00 + p.b[i01] * w01 + p.b[i10] * w10 + p.b[i11] * w11;
        c.r[ci] = c.r[ci] * w + pr * (1 - w);
        c.g[ci] = c.g[ci] * w + pg * (1 - w);
        c.b[ci] = c.b[ci] * w + pb * (1 - w);
        c.wt[ci] = 1.0;
      }
    }
  }

  return BackgroundEstimate(
    gridWidth: gw,
    gridHeight: gh,
    r: base.r,
    g: base.g,
    b: base.b,
    srcWidth: width,
    srcHeight: height,
    ledgerBytes: levelBytes,
  );
}

/// 推挽字段（背景估计 + 局部实心前景估计）。
///
/// 两个字段都跑在长边 192 的低分辨率网格上，与全图尺寸无关 —— 这是去色边
/// 链路里**唯一**必须整图扫描的部分，但产物只有 ~1–2MB。拿到字段后，
/// 去色边的逐像素反解就是纯行内函数（见 [decontaminateRows]），可以按行带
/// 流式执行，全尺寸 premul 缓冲不再需要整项存续。
class CleanFields {
  final BackgroundEstimate background;
  final BackgroundEstimate solidForeground;

  const CleanFields({required this.background, required this.solidForeground});

  /// 两个字段的字节占用（记账用）。
  int get ledgerBytes => background.ledgerBytes + solidForeground.ledgerBytes;
}

/// 一次性算好去色边需要的两个推挽字段（各整图扫描一遍）。
CleanFields estimateCleanFields({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  int gridMaxDim = kBgGridMaxDim,
}) => CleanFields(
  background: _pushPullField(
    rgba: rgba,
    alpha: alpha,
    width: width,
    height: height,
    gridMaxDim: gridMaxDim,
    seedBelow: true,
    seedAlpha: (kBgSeedAlpha * 255).round(),
  ),
  solidForeground: _pushPullField(
    rgba: rgba,
    alpha: alpha,
    width: width,
    height: height,
    gridMaxDim: gridMaxDim,
    seedBelow: false,
    seedAlpha: (kFgSeedAlpha * 255).round(),
  ),
);

/// 去色边后的图层：**预乘 RGBA**（R·a, G·a, B·a, a），长度 = w·h·4。
///
/// 之所以直接存预乘：后续的降采样与双线性重采样只有在预乘空间里做才是正确的，
/// 否则透明区域的黑色会被插值带进边缘（经典的黑边成因，G2B.9）。
class CleanForeground {
  final Uint8List premul;
  final int width;
  final int height;

  const CleanForeground({
    required this.premul,
    required this.width,
    required this.height,
  });
}

/// 去色边主过程（整图版，保留给自检工装与降级路径）。
///
/// 对每个像素：
/// - `a >= kFgSolidAlpha`：实心前景，F = C；
/// - `a <= 极小`：完全背景，F 不重要（预乘后恒为 0）；
/// - 其余：`F = clamp((C − (1 − a)·B) / a)`，B 取自 [estimateBackground]。
///
/// 反解会把误差放大 1/a 倍，因此结果一律钳到 0–255；这既避免溢出，
/// 也天然抑制了背景估计不准时的过冲。
///
/// **生产路径不再走这里**：整图 premul 输出是 w×h×4 的整项存续大缓冲
/// （G4 r5 归因：compose 段 +65.6MB 瞬态的大头）。compose 现在用
/// [estimateCleanFields] + [decontaminateRows] 按行带流式喂给区域预滤波
/// （见 render.dart 的 [buildRegionMip]），全尺寸缓冲不再存在。两条路径
/// 的逐像素数学完全一致（本函数就是 [decontaminateRows] 的全行循环）。
CleanForeground decontaminate({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  BackgroundEstimate? background,
}) {
  final CleanFields fields = background == null
      ? estimateCleanFields(
          rgba: rgba,
          alpha: alpha,
          width: width,
          height: height,
        )
      : CleanFields(
          background: background,
          solidForeground: estimateSolidForeground(
            rgba: rgba,
            alpha: alpha,
            width: width,
            height: height,
          ),
        );
  final Uint8List out = Uint8List(width * height * 4);
  // 记账：整图版才有的整项存续缓冲；流式路径（decontaminateRows）没有它。
  ImagingLedger.alloc('clean.premul', out.length);
  decontaminateRows(
    rgba: rgba,
    alpha: alpha,
    width: width,
    height: height,
    fields: fields,
    y0: 0,
    y1: height,
    out: out,
  );
  return CleanForeground(premul: out, width: width, height: height);
}

/// 去色边的**行带版**：把源行 `[y0, y1)` 反解成预乘 RGBA，写入 [out]
/// （布局与整图版相同，但第 y0 行写在 out 的偏移 0 处；`out` 长度必须
/// ≥ (y1−y0)·width·4）。
///
/// 逐像素数学与 [decontaminate] 完全一致（同一段代码）：每个输出像素只依赖
/// **同一行**的输入像素与两个全局字段（[CleanFields]，与行无关），因此
/// 任意行带划分下输出逐位相同 —— 这是行带流式可行性的依据。
void decontaminateRows({
  required Uint8List rgba,
  required Uint8List alpha,
  required int width,
  required int height,
  required CleanFields fields,
  required int y0,
  required int y1,
  required Uint8List out,
}) {
  final BackgroundEstimate bg = fields.background;
  final BackgroundEstimate fgField = fields.solidForeground;
  final Float32List bgc = Float32List(3);
  final Float32List fgc = Float32List(3);
  const double solid = kFgSolidAlpha;

  for (int y = y0; y < y1; y++) {
    final int rowA = y * width;
    final int rowP = rowA * 4;
    final int outRow = (y - y0) * width * 4;
    for (int x = 0; x < width; x++) {
      final int ai = rowA + x;
      final int av = alpha[ai];
      final int p = rowP + x * 4;
      final int o = outRow + x * 4;
      if (av == 0) {
        // 预乘后整像素为 0。**四个通道都必须写**：行带缓冲是跨单元格行
        // 复用的，只写 alpha 会把上一行的 RGB 残留泄进 box 平均
        // （整图版整缓冲 fresh 时恰为 0，掩盖了这个约定——区域流式版首跑
        // 就撞上，g03/g06 的 mip 平均值被污染）。
        out[o] = 0;
        out[o + 1] = 0;
        out[o + 2] = 0;
        out[o + 3] = 0;
        continue;
      }
      final double a = av / 255.0;
      double fr = rgba[p].toDouble();
      double fg = rgba[p + 1].toDouble();
      double fb = rgba[p + 2].toDouble();
      if (a < solid) {
        bg.sampleAt(x, y, bgc);
        final double inv = (1.0 - a) / a;
        fr = (fr / a) - bgc[0] * inv;
        fg = (fg / a) - bgc[1] * inv;
        fb = (fb / a) - bgc[2] * inv;
        if (fr < 0) {
          fr = 0;
        } else if (fr > 255) {
          fr = 255;
        }
        if (fg < 0) {
          fg = 0;
        } else if (fg > 255) {
          fg = 255;
        }
        if (fb < 0) {
          fb = 0;
        } else if (fb > 255) {
          fb = 255;
        }

        // ---- 色度去溢 ----
        //
        // 上面的反解假设 alpha 是准的。真实抠图模型在轮廓上常常把 alpha 估**大**
        // （黄金集 g05 实测：某边缘像素参考 alpha = 234，按颜色反推真值约 150），
        // 于是 (1 − a)·B 减得不够，残留的背景色调仍留在 F 里 —— 表现为
        // 青底人像边缘挂一圈紫。这一份残留按比例缩放是修不掉的，必须直接按颜色修。
        //
        // 做法：把「F 相对局部实心前景色 F0 的偏差」投影到「背景色度 − 前景色度」
        // 方向上，减掉这个分量。**只动色度、不动亮度**（投影向量的亮度分量恒为 0），
        // 因此边缘上真实的明暗过渡、发丝的暗部都不会被改亮或改暗，
        // 被抹掉的只有「偏向背景颜色」的那一份色偏。
        fgField.sampleAt(x, y, fgc);
        final double yB = 0.299 * bgc[0] + 0.587 * bgc[1] + 0.114 * bgc[2];
        final double yF0 = 0.299 * fgc[0] + 0.587 * fgc[1] + 0.114 * fgc[2];
        final double yF = 0.299 * fr + 0.587 * fg + 0.114 * fb;
        final double dx = (bgc[0] - yB) - (fgc[0] - yF0);
        final double dy = (bgc[1] - yB) - (fgc[1] - yF0);
        final double dz = (bgc[2] - yB) - (fgc[2] - yF0);
        final double den = dx * dx + dy * dy + dz * dz;
        if (den > 1.0) {
          final double rx = (fr - yF) - (fgc[0] - yF0);
          final double ry = (fg - yF) - (fgc[1] - yF0);
          final double rz = (fb - yF) - (fgc[2] - yF0);
          double t = (rx * dx + ry * dy + rz * dz) / den;
          if (t > 0) {
            if (t > kMaxChromaDespill) {
              t = kMaxChromaDespill;
            }
            fr = (fr - t * dx).clamp(0.0, 255.0);
            fg = (fg - t * dy).clamp(0.0, 255.0);
            fb = (fb - t * dz).clamp(0.0, 255.0);
          }
        }

        // ---- 低 alpha 处向局部前景色回落 ----
        //
        // 反解把误差放大 1/a 倍：a=0.5 时观测噪声、背景估计偏差都会被放大一倍，
        // F 很容易被顶到 0 或 255 的轨道上，成片边缘就会冒出饱和度极高的杂色点
        // （黄金集 g04 实测过一个 min(R,B)−G 冲到 41 的像素，源图同位置只有 29）。
        // alpha 越低，反解越不可信，就越应该相信「附近实心前景是什么颜色」。
        // 权重取 (1−a)²：a=0.9 时几乎不动（0.01），a=0.5 时回落四分之一。
        final double wt = (1.0 - a) * (1.0 - a);
        if (wt > 0.001) {
          final double keep = 1.0 - wt;
          fr = fr * keep + fgc[0] * wt;
          fg = fg * keep + fgc[1] * wt;
          fb = fb * keep + fgc[2] * wt;
        }
      }
      out[o] = (fr * a + 0.5).toInt();
      out[o + 1] = (fg * a + 0.5).toInt();
      out[o + 2] = (fb * a + 0.5).toInt();
      out[o + 3] = av;
    }
  }
}
