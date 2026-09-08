// tools/gate/png_utils.dart
//
// 极小化的纯 Dart PNG 解码器，仅供 gatekeeper 的 gate 脚本使用。
// 不依赖任何 pub 包，只用 dart:io 的 ZLibDecoder 做 inflate。
//
// 支持：bitDepth == 8，colorType 0(灰度)/2(RGB)/4(灰度+alpha)/6(RGBA)，非隔行(interlace=0)。
// 不支持的情况（16bit、调色板、隔行扫描）一律抛 PngUnsupportedException ——
// 调用方必须让对应 gate 项显式 FAIL，不允许静默跳过。
//
// 这是判定用的基础设施，任何 agent 都不应修改本文件（属于 gatekeeper 势力范围）。

import 'dart:io';
import 'dart:typed_data';

class PngUnsupportedException implements Exception {
  final String message;
  PngUnsupportedException(this.message);
  @override
  String toString() => 'PngUnsupportedException: $message';
}

class PngDecodeException implements Exception {
  final String message;
  PngDecodeException(this.message);
  @override
  String toString() => 'PngDecodeException: $message';
}

/// 解码后的 PNG，像素统一按 RGBA (每像素 4 字节，0-255) 存储，
/// 方便调用方统一处理灰度/RGB/带alpha的各种输入。
class DecodedPng {
  final int width;
  final int height;
  final Uint8List rgba; // width*height*4

  DecodedPng(this.width, this.height, this.rgba);

  int _idx(int x, int y) => (y * width + x) * 4;

  int r(int x, int y) => rgba[_idx(x, y)];
  int g(int x, int y) => rgba[_idx(x, y) + 1];
  int b(int x, int y) => rgba[_idx(x, y) + 2];
  int a(int x, int y) => rgba[_idx(x, y) + 3];

  /// 灰度值，若原图有 RGB 差异则取均值。用于把"参考 alpha PNG"当作单通道 mask 读取。
  int grayOrAlpha(int x, int y) {
    final i = _idx(x, y);
    final rr = rgba[i], gg = rgba[i + 1], bb = rgba[i + 2], aa = rgba[i + 3];
    // 若存在真正的 alpha 通道（非全 255），优先用 alpha 作为前景强度；
    // 否则退化为灰度（RGB 均值），适配"参考 mask 是灰度 PNG"的情况。
    if (aa != 255) return aa;
    return ((rr + gg + bb) / 3).round();
  }
}

final List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

DecodedPng decodePng(Uint8List bytes) {
  if (bytes.length < 8) {
    throw PngDecodeException('文件过短，不是有效 PNG');
  }
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) {
      throw PngDecodeException('PNG 签名不匹配');
    }
  }

  int width = 0;
  int height = 0;
  int bitDepth = 0;
  int colorType = 0;
  int interlace = 0;
  final idatChunks = <int>[];

  var offset = 8;
  final bd = ByteData.sublistView(bytes);

  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) break;
    final length = bd.getUint32(offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    if (dataEnd > bytes.length) {
      throw PngDecodeException('PNG chunk 长度越界: $type');
    }

    if (type == 'IHDR') {
      width = bd.getUint32(dataStart);
      height = bd.getUint32(dataStart + 4);
      bitDepth = bytes[dataStart + 8];
      colorType = bytes[dataStart + 9];
      interlace = bytes[dataStart + 12];
    } else if (type == 'IDAT') {
      idatChunks.addAll(bytes.sublist(dataStart, dataEnd));
    } else if (type == 'IEND') {
      break;
    }

    offset = dataEnd + 4; // skip CRC
  }

  if (width == 0 || height == 0) {
    throw PngDecodeException('缺少 IHDR 或宽高为 0');
  }
  if (bitDepth != 8) {
    throw PngUnsupportedException('仅支持 bitDepth=8，实测 $bitDepth');
  }
  if (interlace != 0) {
    throw PngUnsupportedException('不支持隔行扫描 (Adam7) PNG');
  }

  int channels;
  switch (colorType) {
    case 0:
      channels = 1;
      break;
    case 2:
      channels = 3;
      break;
    case 4:
      channels = 2;
      break;
    case 6:
      channels = 4;
      break;
    default:
      throw PngUnsupportedException('不支持 colorType=$colorType（可能是调色板图）');
  }

  final raw = _inflate(Uint8List.fromList(idatChunks));

  final bytesPerPixel = channels; // bitDepth 8 => 1 byte/channel
  final stride = width * bytesPerPixel;
  final expectedRawLen = (stride + 1) * height; // 每行前面有 1 字节 filter type
  if (raw.length < expectedRawLen) {
    throw PngDecodeException(
        'inflate 后数据长度不足：期望>=$expectedRawLen，实际${raw.length}');
  }

  final unfiltered = Uint8List(stride * height);
  var rawPos = 0;
  var prevRowStart = -1;
  for (var y = 0; y < height; y++) {
    final filterType = raw[rawPos];
    rawPos += 1;
    final rowStart = y * stride;
    for (var x = 0; x < stride; x++) {
      final raw_ = raw[rawPos + x];
      final a = x >= bytesPerPixel ? unfiltered[rowStart + x - bytesPerPixel] : 0;
      final b = prevRowStart >= 0 ? unfiltered[prevRowStart + x] : 0;
      final c = (prevRowStart >= 0 && x >= bytesPerPixel)
          ? unfiltered[prevRowStart + x - bytesPerPixel]
          : 0;
      int value;
      switch (filterType) {
        case 0:
          value = raw_;
          break;
        case 1:
          value = (raw_ + a) & 0xFF;
          break;
        case 2:
          value = (raw_ + b) & 0xFF;
          break;
        case 3:
          value = (raw_ + ((a + b) >> 1)) & 0xFF;
          break;
        case 4:
          value = (raw_ + _paeth(a, b, c)) & 0xFF;
          break;
        default:
          throw PngDecodeException('未知 filter type: $filterType (行 $y)');
      }
      unfiltered[rowStart + x] = value;
    }
    rawPos += stride;
    prevRowStart = rowStart;
  }

  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final rowStart = y * stride;
    for (var x = 0; x < width; x++) {
      final pIn = rowStart + x * bytesPerPixel;
      final pOut = (y * width + x) * 4;
      switch (channels) {
        case 1:
          final v = unfiltered[pIn];
          rgba[pOut] = v;
          rgba[pOut + 1] = v;
          rgba[pOut + 2] = v;
          rgba[pOut + 3] = 255;
          break;
        case 2:
          final v = unfiltered[pIn];
          final a = unfiltered[pIn + 1];
          rgba[pOut] = v;
          rgba[pOut + 1] = v;
          rgba[pOut + 2] = v;
          rgba[pOut + 3] = a;
          break;
        case 3:
          rgba[pOut] = unfiltered[pIn];
          rgba[pOut + 1] = unfiltered[pIn + 1];
          rgba[pOut + 2] = unfiltered[pIn + 2];
          rgba[pOut + 3] = 255;
          break;
        case 4:
          rgba[pOut] = unfiltered[pIn];
          rgba[pOut + 1] = unfiltered[pIn + 1];
          rgba[pOut + 2] = unfiltered[pIn + 2];
          rgba[pOut + 3] = unfiltered[pIn + 3];
          break;
      }
    }
  }

  return DecodedPng(width, height, rgba);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

Uint8List _inflate(Uint8List zlibData) {
  try {
    final decoder = ZLibDecoder();
    // dart:io 的 ZLibDecoder 是 Converter<List<int>, List<int>>，用 convert()，
    // 不是 decodeBytes()（那个方法不存在，写错了会在真机上直接 NoSuchMethodError）。
    final result = decoder.convert(zlibData);
    return Uint8List.fromList(result);
  } catch (e) {
    throw PngDecodeException('zlib inflate 失败: $e');
  }
}

/// 计算"前景占比"：value(gray 或 alpha) >= threshold 视为前景。
/// 用于 G1.5（参考 alpha 有效性）与 G2A.3（IoU 前置）等。
double foregroundRatio(DecodedPng png, {int threshold = 128}) {
  var fg = 0;
  final total = png.width * png.height;
  for (var y = 0; y < png.height; y++) {
    for (var x = 0; x < png.width; x++) {
      if (png.grayOrAlpha(x, y) >= threshold) fg++;
    }
  }
  return fg / total;
}

/// 采样图像中心 [sampleSide]x[sampleSide] 像素（默认约 100 像素，取 10x10），
/// 判断是否全部为纯黑 #000000（RGB 全 0，忽略 alpha）。
/// capture-shots skill 规定：全黑视为截图流水线失败（黑屏/未渲染）。
bool isCenterAllBlack(DecodedPng png, {int sampleSide = 10}) {
  final cx = png.width ~/ 2;
  final cy = png.height ~/ 2;
  final half = sampleSide ~/ 2;
  var sampled = 0;
  var blackCount = 0;
  for (var dy = -half; dy < half; dy++) {
    for (var dx = -half; dx < half; dx++) {
      final x = cx + dx;
      final y = cy + dy;
      if (x < 0 || y < 0 || x >= png.width || y >= png.height) continue;
      sampled++;
      if (png.r(x, y) == 0 && png.g(x, y) == 0 && png.b(x, y) == 0) {
        blackCount++;
      }
    }
  }
  if (sampled == 0) return true; // 图片过小，视为异常/失败
  return blackCount == sampled;
}
