/// 从字节流的文件头**同步**读出图片像素尺寸。
///
/// 为什么不用 `decodeImageFromList`：那是异步的，会让裁剪框的几何布局依赖
/// "图片解码完成"这个时序。CONTRACTS §7.1 要求截图场景**确定性**，
/// gatekeeper 的 widget test（G2C.5/2C.6/2C.7）也需要在不解码像素的前提下
/// 就能拿到正确的裁剪框坐标。因此这里只解析文件头，纯同步、零分配。
///
/// `AppState` 只给了 `sourceImage` 字节和 `suggestedCrop`（原图像素坐标），
/// 没有给宽高；UI 必须自己算出来才能把原图坐标映射到屏幕坐标。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 解析结果。解析不出来时返回 null，调用方退化到默认比例。
class PixelSize {
  final int width;
  final int height;

  const PixelSize(this.width, this.height);

  double get aspectRatio => width / height;

  @override
  bool operator ==(Object other) =>
      other is PixelSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// 支持 JPEG / PNG / GIF / BMP / WebP(VP8, VP8L, VP8X)。
PixelSize? readImageSize(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final ByteData d = ByteData.sublistView(bytes);

  // PNG: 89 50 4E 47 0D 0A 1A 0A, IHDR 在偏移 16
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    if (bytes.length < 24) return null;
    return PixelSize(d.getUint32(16), d.getUint32(20));
  }

  // GIF: 'GIF8', 宽高在偏移 6，小端
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    return PixelSize(
        d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
  }

  // BMP: 'BM'
  if (bytes[0] == 0x42 && bytes[1] == 0x4D && bytes.length >= 26) {
    final int w = d.getInt32(18, Endian.little);
    final int h = d.getInt32(22, Endian.little).abs();
    if (w > 0 && h > 0) return PixelSize(w, h);
    return null;
  }

  // WebP: 'RIFF' .... 'WEBP'
  if (bytes.length >= 30 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    final int fourcc = d.getUint32(12, Endian.big);
    // 'VP8 '
    if (fourcc == 0x56503820) {
      return PixelSize(d.getUint16(26, Endian.little) & 0x3FFF,
          d.getUint16(28, Endian.little) & 0x3FFF);
    }
    // 'VP8L'
    if (fourcc == 0x5650384C) {
      final int b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
      final int w = 1 + (((b1 & 0x3F) << 8) | b0);
      final int h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
      return PixelSize(w, h);
    }
    // 'VP8X'
    if (fourcc == 0x56503858) {
      final int w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      final int h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      return PixelSize(w, h);
    }
    return null;
  }

  // JPEG: FF D8，然后逐段找 SOF0..SOF15（跳过 SOF4/SOF8/SOF12 这些非帧标记），
  // 沿途顺带记下 APP1/Exif 里的 Orientation。
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    int i = 2;
    int orientation = 1;
    while (i + 3 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final int marker = bytes[i + 1];
      // 填充字节
      if (marker == 0xFF) {
        i++;
        continue;
      }
      // 无长度字段的标记
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) break; // EOI / SOS：再往后是熵编码数据
      if (i + 3 >= bytes.length) break;
      final int len = (bytes[i + 2] << 8) | bytes[i + 3];
      final bool isSof = (marker >= 0xC0 && marker <= 0xCF) &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 9 >= bytes.length) break;
        final int h = (bytes[i + 5] << 8) | bytes[i + 6];
        final int w = (bytes[i + 7] << 8) | bytes[i + 8];
        if (w > 0 && h > 0) return applyOrientation(PixelSize(w, h), orientation);
        break;
      }
      if (marker == 0xE1 && len >= 2) {
        final int? o = _readExifOrientation(bytes, i + 4, len - 2);
        if (o != null) orientation = o;
      }
      if (len < 2) break;
      i += 2 + len;
    }
  }

  return null;
}

/// EXIF orientation 值 5/6/7/8 表示图像被旋转了 90°，**摆正后宽高互换**。
///
/// 引擎侧 `decodeToRgb()` 显式调了 `img.bakeOrientation`，所以
/// `MattingResult.width/height` 和 `AppState.suggestedCrop` 全都在**摆正后**的
/// 坐标系里；Flutter 的 `Image.memory` 渲染的也是摆正后的位图。UI 若按 SOF 头的
/// 原始宽高建立坐标系，一张 orientation=6 的手机竖拍照就会用 4000×3000 去解读
/// 一个 3000×4000 空间里的建议框，再把转置空间里的矩形回传给 `setCrop` ——
/// 取景整个是错的。所以这里统一口径：**readImageSize 返回摆正后的尺寸**。
PixelSize applyOrientation(PixelSize raw, int orientation) =>
    (orientation >= 5 && orientation <= 8)
        ? PixelSize(raw.height, raw.width)
        : raw;

/// 从 APP1 段体（[start] 起 [length] 字节）里读 IFD0 的 Orientation(0x0112)。
/// 不是 Exif 段、或结构不完整时返回 null（调用方保持 orientation=1）。
int? _readExifOrientation(Uint8List bytes, int start, int length) {
  // "Exif\0\0"
  if (start + 8 > bytes.length || length < 8) return null;
  if (bytes[start] != 0x45 ||
      bytes[start + 1] != 0x78 ||
      bytes[start + 2] != 0x69 ||
      bytes[start + 3] != 0x66 ||
      bytes[start + 4] != 0x00) {
    return null;
  }
  final int tiff = start + 6;
  final int end = math.min(start + length, bytes.length);
  if (tiff + 8 > end) return null;

  final int bom = (bytes[tiff] << 8) | bytes[tiff + 1];
  final Endian endian;
  if (bom == 0x4949) {
    endian = Endian.little; // 'II'
  } else if (bom == 0x4D4D) {
    endian = Endian.big; // 'MM'
  } else {
    return null;
  }
  final ByteData d = ByteData.sublistView(bytes);
  if (d.getUint16(tiff + 2, endian) != 0x002A) return null;

  final int ifd0 = tiff + d.getUint32(tiff + 4, endian);
  if (ifd0 + 2 > end || ifd0 < tiff) return null;
  final int count = d.getUint16(ifd0, endian);
  for (int k = 0; k < count; k++) {
    final int e = ifd0 + 2 + k * 12;
    if (e + 12 > end) break;
    if (d.getUint16(e, endian) != 0x0112) continue;
    // type 3 = SHORT（值直接内联在 entry 的后 4 字节里，取前 2 字节）
    if (d.getUint16(e + 2, endian) != 3) continue;
    final int v = d.getUint16(e + 8, endian);
    return (v >= 1 && v <= 8) ? v : null;
  }
  return null;
}
