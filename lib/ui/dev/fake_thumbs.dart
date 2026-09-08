/// 生成"看起来像成品证件照"的占位缩略图（仅开发/截图用）。
///
/// 阶段 2 抠图与合成引擎还没接上，但候选区如果只铺 6 块纯色，视觉评审无法判断
/// 相框、铭牌、选中态在真实内容下的表现。这里对内置样张做一次**极简的色度抠像**：
/// 取四角像素的均值当作原始背景色，离它足够远的像素判为前景保留，够近的换成
/// 该候选的底色。样张本身就是蓝底证件照，这个办法足够以假乱真。
///
/// 这是**开发脚手架**，不是产品逻辑 —— 真正的抠图由 `ml-porting` 的模型完成，
/// 阶段 3 接线后本文件不再参与出图。
///
/// **确定性**：不用随机数，同样的输入永远得到同样的字节。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/api.dart';
import 'sample_photo.dart';

img.Image? _decoded;

img.Image? _sample() => _decoded ??= img.decodeJpg(sampleSourceJpeg());

/// 取四角 6% 见方的区域求均值，作为原背景色估计。
List<double> _estimateBackground(img.Image im) {
  final int bw = math.max(3, (im.width * 0.06).round());
  final int bh = math.max(3, (im.height * 0.06).round());
  double r = 0, g = 0, b = 0;
  int n = 0;
  void sample(int x0, int y0) {
    for (int y = y0; y < y0 + bh; y++) {
      for (int x = x0; x < x0 + bw; x++) {
        final img.Pixel p = im.getPixel(x, y);
        r += p.r.toDouble();
        g += p.g.toDouble();
        b += p.b.toDouble();
        n++;
      }
    }
  }

  sample(0, 0);
  sample(im.width - bw, 0);
  sample(0, im.height ~/ 3);
  sample(im.width - bw, im.height ~/ 3);
  return <double>[r / n, g / n, b / n];
}

/// 可分离盒式模糊，用来羽化抠像边缘。
void _blur(Float32List m, int w, int h, int r) {
  final Float32List tmp = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    final int row = y * w;
    double sum = 0;
    for (int x = -r; x <= r; x++) {
      sum += m[row + x.clamp(0, w - 1)];
    }
    for (int x = 0; x < w; x++) {
      tmp[row + x] = sum / (2 * r + 1);
      sum -= m[row + (x - r).clamp(0, w - 1)];
      sum += m[row + (x + r + 1).clamp(0, w - 1)];
    }
  }
  for (int x = 0; x < w; x++) {
    double sum = 0;
    for (int y = -r; y <= r; y++) {
      sum += tmp[y.clamp(0, h - 1) * w + x];
    }
    for (int y = 0; y < h; y++) {
      m[y * w + x] = sum / (2 * r + 1);
      sum -= tmp[(y - r).clamp(0, h - 1) * w + x];
      sum += tmp[(y + r + 1).clamp(0, h - 1) * w + x];
    }
  }
}

/// 按规格裁剪样张，换上 [style] 的底色，编码成 JPEG。
///
/// [longEdge] 320 与 CONTRACTS 里 `Candidate.thumbBytes` 的约定一致。
Uint8List renderFakeCandidate({
  required PhotoSpec spec,
  required BackgroundStyle style,
  int longEdge = 320,
}) {
  final double ar = spec.aspectRatio;
  final int outH = ar >= 1 ? (longEdge / ar).round() : longEdge;
  final int outW = ar >= 1 ? longEdge : (longEdge * ar).round();

  final img.Image? src = _sample();
  if (src == null) {
    return _solid(outW, outH, style);
  }

  // 按目标比例裁剪，纵向重心偏上（保住头顶）
  int cw = src.width;
  int ch = (cw / ar).round();
  if (ch > src.height) {
    ch = src.height;
    cw = (ch * ar).round();
  }
  final int cx = ((src.width - cw) / 2).round();
  final int cy = ((src.height - ch) * 0.10).round();
  final img.Image cropped =
      img.copyCrop(src, x: cx, y: cy, width: cw, height: ch);
  final img.Image photo = img.copyResize(
    cropped,
    width: outW,
    height: outH,
    interpolation: img.Interpolation.cubic,
  );

  // 色度抠像：离原背景色越远越算前景
  final List<double> bgRef = _estimateBackground(photo);
  final Float32List alpha = Float32List(outW * outH);
  for (int y = 0; y < outH; y++) {
    for (int x = 0; x < outW; x++) {
      final img.Pixel p = photo.getPixel(x, y);
      final double dr = p.r - bgRef[0];
      final double dg = p.g - bgRef[1];
      final double db = p.b - bgRef[2];
      final double d = math.sqrt(dr * dr + dg * dg + db * db);
      alpha[y * outW + x] = ((d - 34) / 40).clamp(0.0, 1.0);
    }
  }
  _blur(alpha, outW, outH, math.max(1, (outW / 260).round()));

  final img.Image out = img.Image(width: outW, height: outH, numChannels: 3);
  final int topArgb = style.colorTop;
  final int botArgb = style.colorBottom ?? style.colorTop;
  final double tr = ((topArgb >> 16) & 0xFF).toDouble();
  final double tg = ((topArgb >> 8) & 0xFF).toDouble();
  final double tb = (topArgb & 0xFF).toDouble();
  final double br = ((botArgb >> 16) & 0xFF).toDouble();
  final double bg2 = ((botArgb >> 8) & 0xFF).toDouble();
  final double bb = (botArgb & 0xFF).toDouble();

  for (int y = 0; y < outH; y++) {
    final double t = outH <= 1 ? 0 : y / (outH - 1);
    final double bgR = tr + (br - tr) * t;
    final double bgG = tg + (bg2 - tg) * t;
    final double bgB = tb + (bb - tb) * t;
    for (int x = 0; x < outW; x++) {
      final double a = alpha[y * outW + x];
      final img.Pixel p = photo.getPixel(x, y);
      // 去溢色：背景残留的蓝会在边缘泛出来，按 alpha 往新底色方向拉回
      out.setPixelRgb(
        x,
        y,
        (p.r * a + bgR * (1 - a)).round().clamp(0, 255),
        (p.g * a + bgG * (1 - a)).round().clamp(0, 255),
        (p.b * a + bgB * (1 - a)).round().clamp(0, 255),
      );
    }
  }
  return img.encodeJpg(out, quality: 88);
}

Uint8List _solid(int w, int h, BackgroundStyle style) {
  final img.Image out = img.Image(width: w, height: h, numChannels: 3);
  img.fill(
    out,
    color: img.ColorRgb8(
      (style.colorTop >> 16) & 0xFF,
      (style.colorTop >> 8) & 0xFF,
      style.colorTop & 0xFF,
    ),
  );
  return img.encodeJpg(out, quality: 88);
}
