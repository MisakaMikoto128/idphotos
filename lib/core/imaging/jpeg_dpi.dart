/// 木照 MuZhao — JPEG JFIF 分辨率（DPI）写入与回读。
///
/// ## 为什么要手写
///
/// `image: 4.9.2` 的 `JpegEncoder._writeAPP0()` 把 JFIF 头写死成
/// `units = 0（无单位）, Xdensity = 1, Ydensity = 1`，
/// 并且没有任何参数可以改。打印店的排版软件读的就是这个字段，
/// 写 1×1 无单位等于没写 —— 冲印出来的实际尺寸会完全跑偏（G2B.2 专测这条）。
///
/// 所以编码完成后必须直接改字节流里的 APP0 段。
///
/// ## APP0（JFIF）段布局
///
/// ```
/// 偏移(相对段起始)  内容
///  0..1   FF E0            段标记
///  2..3   段长度（含自身 2 字节，不含标记）
///  4..8   'J' 'F' 'I' 'F' 00
///  9..10  版本 major, minor
/// 11      密度单位：0=无单位 1=每英寸 2=每厘米
/// 12..13  Xdensity（大端）
/// 14..15  Ydensity（大端）
/// 16      缩略图宽
/// 17      缩略图高
/// ```
library;

import 'dart:typed_data';

/// JFIF 密度单位：每英寸。
const int kJfifUnitsDpi = 1;

/// 把 [dpi] 写进 [jpeg] 的 JFIF APP0 段。
///
/// - 已有合法 APP0：就地改写 units / Xdensity / Ydensity。
/// - 没有 APP0（理论上不会发生，但编码器换实现就可能）：在 SOI 后插入一段标准
///   18 字节 APP0。
///
/// 返回新的字节序列（可能与入参同一实例，也可能是插入后的新实例）。
/// [jpeg] 不是合法 JPEG（缺 SOI）时原样返回 —— 上层会在自检里发现并报错，
/// 这里不静默吞掉问题，而是由 [readJpegDpi] 回读校验兜底。
Uint8List writeJpegDpi(Uint8List jpeg, int dpi) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
    return jpeg;
  }
  final int app0 = _findApp0(jpeg);
  final int d = dpi < 1 ? 1 : (dpi > 65535 ? 65535 : dpi);
  if (app0 >= 0) {
    jpeg[app0 + 11] = kJfifUnitsDpi;
    jpeg[app0 + 12] = (d >> 8) & 0xFF;
    jpeg[app0 + 13] = d & 0xFF;
    jpeg[app0 + 14] = (d >> 8) & 0xFF;
    jpeg[app0 + 15] = d & 0xFF;
    return jpeg;
  }
  final Uint8List seg = Uint8List.fromList(<int>[
    0xFF, 0xE0, //
    0x00, 0x10, // 长度 16
    0x4A, 0x46, 0x49, 0x46, 0x00, // 'JFIF\0'
    0x01, 0x01, // 版本 1.1
    kJfifUnitsDpi,
    (d >> 8) & 0xFF, d & 0xFF,
    (d >> 8) & 0xFF, d & 0xFF,
    0x00, 0x00, // 无缩略图
  ]);
  final Uint8List out = Uint8List(jpeg.length + seg.length);
  out[0] = 0xFF;
  out[1] = 0xD8;
  out.setRange(2, 2 + seg.length, seg);
  out.setRange(2 + seg.length, out.length, jpeg, 2);
  return out;
}

/// 回读 JFIF APP0 里的 DPI。
///
/// 返回 `[xDpi, yDpi]`；找不到合法 APP0、或单位不是「每英寸」时返回 null。
/// 单位是每厘米（2）时换算成每英寸后返回。
List<int>? readJpegDpi(Uint8List jpeg) {
  final int app0 = _findApp0(jpeg);
  if (app0 < 0) {
    return null;
  }
  final int units = jpeg[app0 + 11];
  final int xd = (jpeg[app0 + 12] << 8) | jpeg[app0 + 13];
  final int yd = (jpeg[app0 + 14] << 8) | jpeg[app0 + 15];
  if (xd == 0 || yd == 0) {
    return null;
  }
  if (units == 1) {
    return <int>[xd, yd];
  }
  if (units == 2) {
    return <int>[(xd * 2.54).round(), (yd * 2.54).round()];
  }
  return null;
}

/// 返回 APP0 段起始偏移（指向 0xFF），找不到返回 -1。
int _findApp0(Uint8List jpeg) {
  if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) {
    return -1;
  }
  int i = 2;
  while (i + 4 <= jpeg.length) {
    if (jpeg[i] != 0xFF) {
      // 标记之间允许填充 0xFF，其它情况说明已进入熵编码数据，停止扫描。
      i++;
      continue;
    }
    int marker = jpeg[i + 1];
    while (marker == 0xFF && i + 2 < jpeg.length) {
      i++;
      marker = jpeg[i + 1];
    }
    if (marker == 0xD8 || marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) {
      return -1; // 进入图像数据，之后不会再有 APP0
    }
    if (i + 4 > jpeg.length) {
      return -1;
    }
    final int len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    if (marker == 0xE0 && len >= 16 && i + 2 + len <= jpeg.length) {
      if (jpeg[i + 4] == 0x4A &&
          jpeg[i + 5] == 0x46 &&
          jpeg[i + 6] == 0x49 &&
          jpeg[i + 7] == 0x46 &&
          jpeg[i + 8] == 0x00) {
        return i;
      }
    }
    if (len < 2) {
      return -1;
    }
    i += 2 + len;
  }
  return -1;
}
