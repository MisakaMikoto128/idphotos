// 一次性探针：image 包 decodeJpg 是否 bake EXIF orientation。
// 跑法：flutter test native/bench/image_pkg_exif_probe_test.dart
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List makeBaseJpeg(int width, int height) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final red = y < height ~/ 4;
      im.setPixelRgba(x, y, red ? 255 : 0, 0, red ? 0 : 255, 255);
    }
  }
  return img.encodeJpg(im, quality: 95);
}

Uint8List spliceExifOrientation6(Uint8List jpg) {
  final tiff = BytesBuilder()
    ..add([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    ..add([0x01, 0x00]) // 1 entry
    ..add([0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00])
    ..add([0x00, 0x00, 0x00, 0x00]);
  final body = BytesBuilder()
    ..add('Exif'.codeUnits)
    ..add([0x00, 0x00])
    ..add(tiff.toBytes());
  final b = body.toBytes();
  final out = BytesBuilder()
    ..add([0xFF, 0xD8])
    ..add([0xFF, 0xE1, b.length >> 8 & 0xFF, b.length & 0xFF])
    ..add(b)
    ..add(jpg.sublist(2));
  return out.toBytes();
}

void main() {
  test('probe: image package decodeJpg EXIF behavior', () {
    final base = makeBaseJpeg(64, 128);
    final decBase = img.decodeJpg(base)!;
    stdout.writeln('base (no EXIF): ${decBase.width}x${decBase.height} '
        'exif.orientation=${decBase.exif.imageIfd.orientation}');

    final spliced = spliceExifOrientation6(base);
    final decSpliced = img.decodeJpg(spliced)!;
    stdout.writeln('spliced (orientation=6): ${decSpliced.width}x'
        '${decSpliced.height} '
        'exif.orientation=${decSpliced.exif.imageIfd.orientation}');

    // 像素验证：orientation 6 摆正后，原顶部红条应出现在右侧。
    if (decSpliced.exif.imageIfd.hasOrientation) {
      final baked = img.bakeOrientation(decSpliced);
      stdout.writeln('after bakeOrientation: ${baked.width}x${baked.height}');
      final px = baked.getPixel(0, baked.height ~/ 2); // 左中
      stdout.writeln('left-center pixel after bake: '
          'r=${px.r} g=${px.g} b=${px.b}');
      final px2 = baked.getPixel(baked.width - 1, baked.height ~/ 2); // 右中
      stdout.writeln('right-center pixel after bake: '
          'r=${px2.r} g=${px2.g} b=${px2.b}');
    }
    expect(decBase, isNotNull);
  });
}
