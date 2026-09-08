// tools/gate/jpeg_utils.dart
//
// 极小化 JFIF APP0 头解析器：只读 Xdensity/Ydensity/units 三个字段，
// **不做完整 JPEG 解码**（DCT/熵解码交给 package:image，这里只手撸最前面几个 marker）。
// 用于 G2B.2：换回 DPI 是否等于 300。
//
// JPEG 文件结构：0xFFD8 (SOI) 后跟一串 marker，每个 marker = 0xFF + 1 字节类型码，
// 若非 standalone marker（0xD0-0xD9, 0x01）则后面跟 2 字节大端长度（含长度自身 2 字节）
// + 数据。JFIF 信息在 APP0 (0xFFE0) 里，数据区结构：
//   'JFIF\0' (5B) + version(2B) + units(1B) + Xdensity(2B BE) + Ydensity(2B BE) + ...
// units: 0=无单位(纵横比) 1=像素/英寸(DPI) 2=像素/厘米

import 'dart:typed_data';

class JfifDensity {
  final int xDensity;
  final int yDensity;
  final int units; // 0/1/2，见上
  const JfifDensity(this.xDensity, this.yDensity, this.units);

  bool get isDpi300 => units == 1 && xDensity == 300 && yDensity == 300;
}

class JfifNotFoundException implements Exception {
  final String message;
  JfifNotFoundException(this.message);
  @override
  String toString() => 'JfifNotFoundException: $message';
}

/// 从 JPEG 字节里找 APP0/JFIF 段，读出密度字段。找不到就抛异常
/// （调用方必须让对应 gate 项显式 FAIL，不许当成"没有=通过"）。
JfifDensity readJfifDensity(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw JfifNotFoundException('不是有效 JPEG（缺 SOI 0xFFD8）');
  }
  var pos = 2;
  while (pos + 4 <= bytes.length) {
    if (bytes[pos] != 0xFF) {
      throw JfifNotFoundException('marker 结构异常，偏移 $pos 处不是 0xFF');
    }
    final marker = bytes[pos + 1];
    // 0xD8 SOI / 0xD9 EOI / 0x01 TEM / 0xD0-0xD7 RSTn 都是 standalone，无长度字段。
    if (marker == 0xD9) {
      break;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (pos + 4 > bytes.length) break;
    final segLen = (bytes[pos + 2] << 8) | bytes[pos + 3]; // 含这 2 字节长度自身
    final segStart = pos + 4;
    if (marker == 0xE0) {
      // APP0
      if (segStart + 12 <= bytes.length &&
          bytes[segStart] == 0x4A && // J
          bytes[segStart + 1] == 0x46 && // F
          bytes[segStart + 2] == 0x49 && // I
          bytes[segStart + 3] == 0x46 && // F
          bytes[segStart + 4] == 0x00) {
        final units = bytes[segStart + 7];
        final xDensity = (bytes[segStart + 8] << 8) | bytes[segStart + 9];
        final yDensity = (bytes[segStart + 10] << 8) | bytes[segStart + 11];
        return JfifDensity(xDensity, yDensity, units);
      }
    }
    if (marker == 0xDA) {
      // SOS：往后是熵编码数据，没有更多 marker 段结构，JFIF 一定在它之前。
      break;
    }
    pos = segStart + segLen - 2;
  }
  throw JfifNotFoundException('未找到 APP0/JFIF 段（图片可能没写 JFIF 密度信息）');
}

/// 构造一个最小合法 JPEG 字节序列（SOI + APP0/JFIF(指定密度) + EOI），仅用于自检，
/// 不是真实可解码图像（没有 SOF/SOS/图像数据），readJfifDensity 只关心 APP0，够用。
Uint8List _buildFakeJpegWithJfif({required int xDensity, required int yDensity, required int units}) {
  final bytes = <int>[];
  bytes.addAll([0xFF, 0xD8]); // SOI
  // APP0
  bytes.addAll([0xFF, 0xE0]);
  final app0Data = <int>[
    0x4A, 0x46, 0x49, 0x46, 0x00, // 'JFIF\0'
    0x01, 0x02, // version 1.2
    units,
    (xDensity >> 8) & 0xFF, xDensity & 0xFF,
    (yDensity >> 8) & 0xFF, yDensity & 0xFF,
    0x00, 0x00, // thumbnail w,h = 0,0
  ];
  final segLen = app0Data.length + 2;
  bytes.addAll([(segLen >> 8) & 0xFF, segLen & 0xFF]);
  bytes.addAll(app0Data);
  bytes.addAll([0xFF, 0xD9]); // EOI
  return Uint8List.fromList(bytes);
}

/// 自检：构造已知密度的假 JPEG 头，验证能原样读回。
List<String> selfTest() {
  final failures = <String>[];
  final fake300 = _buildFakeJpegWithJfif(xDensity: 300, yDensity: 300, units: 1);
  final d300 = readJfifDensity(fake300);
  if (!(d300.xDensity == 300 && d300.yDensity == 300 && d300.units == 1 && d300.isDpi300)) {
    failures.add('300dpi 用例读回错误: x=${d300.xDensity} y=${d300.yDensity} units=${d300.units}');
  }

  final fake72 = _buildFakeJpegWithJfif(xDensity: 72, yDensity: 72, units: 1);
  final d72 = readJfifDensity(fake72);
  if (d72.isDpi300) {
    failures.add('72dpi 用例被误判为 300dpi');
  }

  final fakeAspect = _buildFakeJpegWithJfif(xDensity: 1, yDensity: 1, units: 0);
  final dAspect = readJfifDensity(fakeAspect);
  if (dAspect.isDpi300) {
    failures.add('units=0（无单位）用例被误判为 300dpi');
  }

  return failures;
}

void main() {
  final failures = selfTest();
  if (failures.isEmpty) {
    print('JFIF 密度解析自检：PASS');
  } else {
    print('JFIF 密度解析自检：FAIL');
    for (final f in failures) {
      print('  $f');
    }
  }
}
