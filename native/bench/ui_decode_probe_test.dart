// 一次性探针（ml-porting 自用）：确认 dart:ui 的 instantiateImageCodec
// 对 EXIF orientation 和 targetWidth/targetHeight 的确切语义，决定
// 大图降采样解码路径的坐标公式。结论写进 image_ops.dart 的注释。
//
// 跑法：flutter test native/bench/ui_decode_probe_test.dart
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 造一张 64(w)×128(h) 的 JPEG：顶部 1/4 高的横条是纯红，其余纯蓝。
/// 再手工塞进一个 EXIF APP1 段，orientation=6（逆时针 90°？——按 EXIF 规范
/// 6 = 横拍竖放，查看器应顺时针旋转 90° 摆正，摆正后宽高互换）。
Uint8List makeOrientedJpeg() {
  final im = img.Image(width: 64, height: 128, numChannels: 3);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 64; x++) {
      final red = y < 32;
      im.setPixelRgba(x, y, red ? 255 : 0, 0, red ? 0 : 255, 255);
    }
  }
  final jpg = img.encodeJpg(im, quality: 95);
  // 构造 APP1 EXIF: "Exif\0\0" + TIFF(II,42,IFD0@8) + IFD0{count=1,
  // entry(0x0112, SHORT, count 1, value 6)} + nextIFD=0
  final tiff = BytesBuilder();
  tiff.add([0x49, 0x49]); // II
  tiff.addByte(42); // 0x2A
  tiff.addByte(0);
  tiff.add([0x08, 0x00, 0x00, 0x00]); // IFD0 offset = 8
  tiff.add([0x01, 0x00]); // 1 个 entry
  tiff.add([0x12, 0x01]); // tag 0x0112
  tiff.add([0x03, 0x00]); // type SHORT
  tiff.add([0x01, 0x00, 0x00, 0x00]); // count 1
  tiff.add([0x06, 0x00, 0x00, 0x00]); // value 6（SHORT 内联在前 2 字节）
  tiff.add([0x00, 0x00, 0x00, 0x00]); // next IFD = 0

  final app1Body = BytesBuilder();
  app1Body.add('Exif'.codeUnits);
  app1Body.add([0x00, 0x00]);
  app1Body.add(tiff.toBytes());
  final body = app1Body.toBytes();

  final out = BytesBuilder();
  out.add([0xFF, 0xD8]); // SOI
  out.add([0xFF, 0xE1, body.length >> 8 & 0xFF, body.length & 0xFF]);
  out.add(body);
  // 原始 JPEG 去掉 SOI 后接上（它以 APP0 开头也没关系，APP1 在 SOF 前）
  out.add(jpg.sublist(2));
  return out.toBytes();
}

void main() {
  test('probe: dart:ui EXIF orientation + target dims semantics', () async {
    final bytes = makeOrientedJpeg();

    // image 包（纯 Dart 路径的基准行为）：startDecode 读头，decodeImage 后
    // bakeOrientation 由我们自己调，raw dims 应为 64×128。
    final raw = img.decodeJpg(bytes)!;
    stdout.writeln('image package raw dims: ${raw.width}x${raw.height}');

    // 无 target：看 dart:ui 报告的内在尺寸。
    final codecNoTarget = await ui.instantiateImageCodec(bytes);
    final f0 = await codecNoTarget.getNextFrame();
    stdout.writeln(
        'dart:ui no-target dims: ${f0.image.width}x${f0.image.height}');
    final d0 = await f0.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    // 顶部中心像素（若未 bake：应为红条；若 bake 了：y=0 处是原左侧列→蓝）
    if (d0 != null) {
      final px = Uint8List.view(d0.buffer, d0.offsetInBytes);
      final w = f0.image.width;
      final topCenter = w ~/ 2;
      stdout.writeln('top-center pixel @no-target: '
          'r=${px[topCenter * 4]} g=${px[topCenter * 4 + 1]} '
          'b=${px[topCenter * 4 + 2]}');
      final rightCenter = (w * (f0.image.height ~/ 2) + w - 1) * 4;
      stdout.writeln('right-center pixel @no-target: '
          'r=${px[rightCenter]} g=${px[rightCenter + 1]} '
          'b=${px[rightCenter + 2]}');
    }
    f0.image.dispose();

    // 有 target（降采样路径的真实用法）。
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 64,
    );
    final f1 = await codec.getNextFrame();
    final d1 = await f1.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    stdout.writeln(
        'dart:ui target(32x64) frame dims: ${f1.image.width}x${f1.image.height}'
        ' byteLen=${d1!.lengthInBytes}');
    {
      final px = Uint8List.view(d1.buffer, d1.offsetInBytes);
      final w = f1.image.width;
      final topCenter = w ~/ 2;
      stdout.writeln('top-center pixel @target: '
          'r=${px[topCenter * 4]} g=${px[topCenter * 4 + 1]} '
          'b=${px[topCenter * 4 + 2]}');
      final rightCenter = (w * (f1.image.height ~/ 2) + w - 1) * 4;
      stdout.writeln('right-center pixel @target: '
          'r=${px[rightCenter]} g=${px[rightCenter + 1]} '
          'b=${px[rightCenter + 2]}');
    }
    f1.image.dispose();
    expect(d1, isNotNull);
  });
}
