/// 从字节流的文件头**同步**读出图片像素尺寸（含 EXIF orientation 修正）。
///
/// 全项目唯一的头解析实现（simplify 由 `lib/ui/util/image_size.dart` 与
/// `lib/core/matting/image_header.dart` 的双写合并而来，取两者格式的超集：
/// JPEG SOF+EXIF / PNG / GIF / BMP / WebP(VP8, VP8L, VP8X)）。两处调用方：
///
/// - **UI（`lib/ui/util/image_size.dart`）**：区域 A 的裁剪框几何布局依赖
///   "图片解码完成"这个时序之前就要拿到宽高 —— CONTRACTS §7.1 要求截图
///   场景**确定性**，gatekeeper 的 widget test（G2C.5/2C.6/2C.7）也需要在
///   不解码像素的前提下拿到正确的裁剪框坐标。纯同步、零分配。
/// - **引擎（`lib/core/matting/image_ops.dart`）**：`removeBackground` /
///   `detectFace` 在解码**之前**先拿尺寸——4958×7017 的扫描件如果直接全
///   分辨率解码，RGBA + 中间缓冲会把进程峰值内存顶到 800MB+（G4.7 FAIL）。
///   先读头、超限就按引擎工作分辨率降采样，全程不碰全尺寸像素缓冲。
///
/// 语义口径（两调用方一致）：**返回摆正后的尺寸**。两个解码器（image 包 /
/// dart:ui）都会在解码时烘焙 EXIF orientation，`MattingResult.width/height`、
/// `AppState.suggestedCrop` 与 Flutter 渲染的位图全在摆正后的坐标系里；
/// 头解析若返回 SOF 原始宽高，orientation 5–8 的手机竖拍照整套坐标就错了。
/// 解析不出来时返回 null：UI 退化到默认比例，引擎侧走对应降级/拒绝路径。
/// 不抛异常——任何结构异常都按"解析不出"处理。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 摆正后的像素尺寸。解析失败返回 null（见 [readImageHeaderSize]）。
class ImageHeaderSize {
  const ImageHeaderSize(this.width, this.height, this.orientation);

  /// 摆正后的宽高（orientation 5–8 时已交换）。
  final int width;
  final int height;

  /// 原始 EXIF orientation（1–8；非 JPEG 或无 EXIF 时为 1）。
  final int orientation;
}

/// 解析文件头。不抛异常——任何结构异常都按"解析不出"处理。
ImageHeaderSize? readImageHeaderSize(Uint8List bytes) {
  if (bytes.length < 16) return null;
  final ByteData d = ByteData.sublistView(bytes);

  // PNG: 89 50 4E 47 0D 0A 1A 0A, IHDR 在偏移 16
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    if (bytes.length < 24) return null;
    final w = d.getUint32(16);
    final h = d.getUint32(20);
    if (w <= 0 || h <= 0) return null;
    return ImageHeaderSize(w, h, 1);
  }

  // GIF: 'GIF8', 宽高在偏移 6，小端
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    final w = d.getUint16(6, Endian.little);
    final h = d.getUint16(8, Endian.little);
    if (w <= 0 || h <= 0) return null;
    return ImageHeaderSize(w, h, 1);
  }

  // BMP: 'BM'
  if (bytes[0] == 0x42 && bytes[1] == 0x4D && bytes.length >= 26) {
    final w = d.getInt32(18, Endian.little);
    final h = d.getInt32(22, Endian.little).abs();
    if (w <= 0 || h <= 0) return null;
    return ImageHeaderSize(w, h, 1);
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
    final fourcc = d.getUint32(12, Endian.big);
    int? w, h;
    // 'VP8 '
    if (fourcc == 0x56503820) {
      w = d.getUint16(26, Endian.little) & 0x3FFF;
      h = d.getUint16(28, Endian.little) & 0x3FFF;
    } else if (fourcc == 0x5650384C) {
      // 'VP8L'
      final b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
      w = 1 + (((b1 & 0x3F) << 8) | b0);
      h = 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6));
    } else if (fourcc == 0x56503858) {
      // 'VP8X'
      w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
    }
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return ImageHeaderSize(w, h, 1);
  }

  // JPEG: FF D8，逐段找 SOF0..SOF15（跳过非帧标记），顺带读 APP1/Exif 的
  // Orientation(0x0112)。与 cv2.imread / image 包 / dart:ui 的默认口径一致：
  // 返回摆正后的尺寸。
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    int i = 2;
    int orientation = 1;
    while (i + 3 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final int marker = bytes[i + 1];
      if (marker == 0xFF) {
        // 填充字节
        i++;
        continue;
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        // 无长度字段的标记
        i += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) break; // EOI / SOS
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
        if (w <= 0 || h <= 0) return null;
        return (orientation >= 5 && orientation <= 8)
            ? ImageHeaderSize(h, w, orientation)
            : ImageHeaderSize(w, h, orientation);
      }
      if (marker == 0xE1 && len >= 2) {
        final o = _readExifOrientation(bytes, i + 4, len - 2);
        if (o != null) orientation = o;
      }
      if (len < 2) break;
      i += 2 + len;
    }
  }

  return null;
}

/// 从 APP1 段体（[start] 起 [length] 字节）里读 IFD0 的 Orientation(0x0112)。
/// 不是 Exif 段、或结构不完整时返回 null（调用方保持 orientation=1）。
int? _readExifOrientation(Uint8List bytes, int start, int length) {
  if (start + 8 > bytes.length || length < 8) return null;
  // "Exif\0\0"
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
    // type 3 = SHORT，值内联在 entry 后 4 字节的前 2 字节
    if (d.getUint16(e + 2, endian) != 3) continue;
    final int v = d.getUint16(e + 8, endian);
    return (v >= 1 && v <= 8) ? v : null;
  }
  return null;
}
