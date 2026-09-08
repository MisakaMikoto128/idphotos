/// 抠图/检脸链路上的纯 Dart 图像算子。
///
/// 这里所有重采样都刻意与 OpenCV 的实现对齐：黄金集参考 alpha
/// （`test/golden/ref/*.png`）是用 `cv2.resize(..., INTER_AREA)` 做前处理、
/// 再用 `INTER_AREA` 放大回原图生成的。G2A.3–2A.5 逐像素比对这份参考，
/// 所以缩放算法一旦跑偏，指标会直接掉下阈值——不要"顺手"换成别的插值。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../api.dart';

/// 解码后的原图，RGB 紧凑排布（w*h*3），外加一份 RGBA 视图所需的信息。
class DecodedImage {
  DecodedImage(this.rgb, this.width, this.height);

  /// 长度 = width * height * 3，顺序 R,G,B。
  final Uint8List rgb;
  final int width;
  final int height;

  int get pixelCount => width * height;

  /// 展开成契约要求的 RGBA（w*h*4，A 恒 255）。
  Uint8List toRgba() {
    final out = Uint8List(pixelCount * 4);
    for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      out[j] = rgb[i];
      out[j + 1] = rgb[i + 1];
      out[j + 2] = rgb[i + 2];
      out[j + 3] = 255;
    }
    return out;
  }
}

/// 解码任意受支持的图片字节。
///
/// - 解码不出来 → [UnsupportedImageException]
/// - 长边超过 [kMaxImageEdgePx] → [ImageTooLargeException]
///
/// EXIF 方向会被烘焙进像素，这与参考实现 `cv2.imread` 的默认行为一致
/// （OpenCV 自 3.4.1 起默认应用 EXIF orientation）。
DecodedImage decodeToRgb(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const UnsupportedImageException();
  }
  img.Image? decoded;
  Object? failure;
  try {
    decoded = img.decodeImage(bytes);
  } catch (e) {
    // 损坏文件、伪装成图片的文本等都会在这里抛，统一翻译成契约异常。
    failure = e;
  }
  if (decoded == null) {
    // cause 只放字符串：这个异常会穿过 isolate 边界，带上第三方异常对象
    // 有可能不可序列化。
    throw UnsupportedImageException(cause: failure?.toString());
  }
  if (math.max(decoded.width, decoded.height) > kMaxImageEdgePx) {
    throw const ImageTooLargeException();
  }
  if (decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1) {
    decoded = img.bakeOrientation(decoded);
  }
  final w = decoded.width;
  final h = decoded.height;
  if (w <= 0 || h <= 0) {
    throw const UnsupportedImageException();
  }
  // 统一成 8bit 三通道再取字节：源图可能是灰度、带调色板、16bit 或带 alpha。
  if (decoded.numChannels != 3 || decoded.format != img.Format.uint8) {
    decoded = decoded.convert(format: img.Format.uint8, numChannels: 3);
  }
  final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);
  if (rgb.length != w * h * 3) {
    throw const UnsupportedImageException();
  }
  return DecodedImage(rgb, w, h);
}

/// 一维面积重采样的权重表。等价于 OpenCV `INTER_AREA`：
/// 输出像素 j 覆盖源区间 `[j*s, (j+1)*s)`，权重 = 交叠长度 / s。
/// 缩小时是盒式平均，放大时退化为"带过渡的最近邻"，两种情形同一套公式。
class _AreaWeights {
  _AreaWeights(this.start, this.count, this.weights);

  final Int32List start;
  final Int32List count;
  final Float32List weights;

  static _AreaWeights build(int srcLen, int dstLen) {
    final scale = srcLen / dstLen;
    final start = Int32List(dstLen);
    final count = Int32List(dstLen);
    final acc = <double>[];
    for (var j = 0; j < dstLen; j++) {
      final s0 = j * scale;
      final s1 = (j + 1) * scale;
      var i0 = s0.floor();
      var i1 = s1.ceil();
      if (i0 < 0) i0 = 0;
      if (i1 > srcLen) i1 = srcLen;
      if (i1 <= i0) i1 = math.min(i0 + 1, srcLen);
      start[j] = i0;
      count[j] = i1 - i0;
      for (var i = i0; i < i1; i++) {
        final lo = math.max(s0, i.toDouble());
        final hi = math.min(s1, (i + 1).toDouble());
        acc.add(math.max(0.0, hi - lo) / scale);
      }
    }
    return _AreaWeights(start, count, Float32List.fromList(acc));
  }
}

int _roundToByte(double v) {
  // OpenCV saturate_cast<uchar>：四舍五入 + 饱和到 [0,255]。
  final r = v < 0 ? (v - 0.5).ceil() : (v + 0.5).floor();
  if (r < 0) return 0;
  if (r > 255) return 255;
  return r;
}

/// 面积重采样 RGB 图到 `dstW x dstH`，返回 uint8 RGB。
///
/// 先横向再纵向，中间量保持 double；最后一步才量化回 uint8 ——
/// 与 OpenCV 一致（模型前处理拿到的是 uint8）。
Uint8List areaResampleRgb(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  final wx = _AreaWeights.build(srcW, dstW);
  final wy = _AreaWeights.build(srcH, dstH);
  // 中间缓冲：srcH 行 x dstW 列 x 3 通道
  final tmp = Float32List(srcH * dstW * 3);
  for (var y = 0; y < srcH; y++) {
    final rowBase = y * srcW * 3;
    final outBase = y * dstW * 3;
    var wi = 0;
    for (var j = 0; j < dstW; j++) {
      var r = 0.0, g = 0.0, b = 0.0;
      final i0 = wx.start[j];
      final n = wx.count[j];
      for (var k = 0; k < n; k++) {
        final w = wx.weights[wi + k];
        final p = rowBase + (i0 + k) * 3;
        r += src[p] * w;
        g += src[p + 1] * w;
        b += src[p + 2] * w;
      }
      wi += n;
      final o = outBase + j * 3;
      tmp[o] = r;
      tmp[o + 1] = g;
      tmp[o + 2] = b;
    }
  }
  final out = Uint8List(dstW * dstH * 3);
  var wi = 0;
  for (var y = 0; y < dstH; y++) {
    final i0 = wy.start[y];
    final n = wy.count[y];
    final outBase = y * dstW * 3;
    for (var j = 0; j < dstW; j++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = 0; k < n; k++) {
        final w = wy.weights[wi + k];
        final p = (i0 + k) * dstW * 3 + j * 3;
        r += tmp[p] * w;
        g += tmp[p + 1] * w;
        b += tmp[p + 2] * w;
      }
      final o = outBase + j * 3;
      out[o] = _roundToByte(r);
      out[o + 1] = _roundToByte(g);
      out[o + 2] = _roundToByte(b);
    }
    wi += n;
  }
  return out;
}

/// 单通道面积重采样（alpha 用）。
Uint8List areaResampleGray(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  final wx = _AreaWeights.build(srcW, dstW);
  final wy = _AreaWeights.build(srcH, dstH);
  final tmp = Float32List(srcH * dstW);
  for (var y = 0; y < srcH; y++) {
    final rowBase = y * srcW;
    final outBase = y * dstW;
    var wi = 0;
    for (var j = 0; j < dstW; j++) {
      var v = 0.0;
      final i0 = wx.start[j];
      final n = wx.count[j];
      for (var k = 0; k < n; k++) {
        v += src[rowBase + i0 + k] * wx.weights[wi + k];
      }
      wi += n;
      tmp[outBase + j] = v;
    }
  }
  final out = Uint8List(dstW * dstH);
  var wi = 0;
  for (var y = 0; y < dstH; y++) {
    final i0 = wy.start[y];
    final n = wy.count[y];
    final outBase = y * dstW;
    for (var j = 0; j < dstW; j++) {
      var v = 0.0;
      for (var k = 0; k < n; k++) {
        v += tmp[(i0 + k) * dstW + j] * wy.weights[wi + k];
      }
      out[outBase + j] = _roundToByte(v);
    }
    wi += n;
  }
  return out;
}

/// 就地高斯羽化（可分离核）。仅在放大倍率很小、边缘还偏硬时才调用。
Uint8List featherGray(Uint8List src, int w, int h, double sigma) {
  if (sigma <= 0) return src;
  final radius = math.max(1, (sigma * 3).ceil());
  final k = Float32List(radius * 2 + 1);
  var sum = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final v = math.exp(-(i * i) / (2 * sigma * sigma));
    k[i + radius] = v;
    sum += v;
  }
  for (var i = 0; i < k.length; i++) {
    k[i] = k[i] / sum;
  }
  final tmp = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      var v = 0.0;
      for (var i = -radius; i <= radius; i++) {
        final xx = (x + i).clamp(0, w - 1);
        v += src[base + xx] * k[i + radius];
      }
      tmp[base + x] = v;
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      var v = 0.0;
      for (var i = -radius; i <= radius; i++) {
        final yy = (y + i).clamp(0, h - 1);
        v += tmp[yy * w + x] * k[i + radius];
      }
      out[base + x] = _roundToByte(v);
    }
  }
  return out;
}

/// MODNet 前处理：RGB → 512×512 → BGR、NCHW、`(x/255 - 0.5) / 0.5`。
///
/// 通道顺序是 **BGR**：参考实现用 `cv2.imread` 读图后直接喂给模型，
/// 黄金集参考 alpha 就是在 BGR 下产生的，换成 RGB 会得到不同的 mask。
Float32List modnetInput(Uint8List rgb, int w, int h, int size) {
  final resized = areaResampleRgb(rgb, w, h, size, size);
  final out = Float32List(3 * size * size);
  final plane = size * size;
  for (var i = 0, p = 0; p < plane; i += 3, p++) {
    out[p] = (resized[i + 2] / 255.0 - 0.5) / 0.5; // B
    out[plane + p] = (resized[i + 1] / 255.0 - 0.5) / 0.5; // G
    out[2 * plane + p] = (resized[i] / 255.0 - 0.5) / 0.5; // R
  }
  return out;
}

/// YuNet 前处理结果：等比缩放 + 右下角补 0 的 640×640 BGR NCHW（不做归一化）。
class LetterboxInput {
  LetterboxInput(this.data, this.scale);

  final Float32List data;

  /// 原图坐标 = 模型坐标 / scale。
  final double scale;
}

LetterboxInput yunetInput(Uint8List rgb, int w, int h, int size) {
  final scale = math.min(size / w, size / h);
  var nw = (w * scale).round().clamp(1, size);
  var nh = (h * scale).round().clamp(1, size);
  final resized = areaResampleRgb(rgb, w, h, nw, nh);
  final plane = size * size;
  final out = Float32List(3 * plane);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final s = (y * nw + x) * 3;
      final d = y * size + x;
      out[d] = resized[s + 2].toDouble(); // B
      out[plane + d] = resized[s + 1].toDouble(); // G
      out[2 * plane + d] = resized[s].toDouble(); // R
    }
  }
  return LetterboxInput(out, scale);
}
