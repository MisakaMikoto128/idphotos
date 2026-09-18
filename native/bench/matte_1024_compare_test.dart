// ml-porting 自用：MODNet 输入 512² → 1024² 换档的 before/after 对照（不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/matte_1024_compare_test.dart
//
// 同一张解码后的图分别走"旧 512 管线"与"新 1024 管线"（两条只在模型输入
// 尺寸上不同：去斑/平滑/碎片门槛/羽化全部走生产代码，随 kMattingInputSize
// 参数化），按人脸框取发梢边缘裁片，**原生像素（100% 视角）**并排：
// [源图 | 512 红底 | 1024 红底]，另附 2× 最近邻放大版与两张全幅 alpha。
//
// 512 旧模型由量化脚本复现（不在 assets 里）：
//   .venv_ref/Scripts/python.exe native/quantize/build_matting_model.py \
//     --size 512 --out out/tmp/modnet_portrait_512_int8.onnx
//
// 产物目录：out/tmp/matte_1024_compare/。
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/matting_worker.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

const String _pics = r'C:\Users\liuyu\Pictures';

/// 人像样本（对照用，都是已知有人脸的图——本探针绕过人脸门槛，
/// 只比"模型输入尺寸"这一个变量）。
const Map<String, String> _samples = <String, String>{
  'p_1x2': r'1 (2).jpg', // 2880×4982 大图，触发 kBigImageWorkEdge=1536 降采样
  'p_2': r'2.jpg', // 蓝底白衬衫，发梢细碎（512 时代发际线锯齿的实证样本）
  'p_29': r'29EDA59B982FA8339335D50B00CCD096.jpg', // 蓝底白衬衫，半身
};

class _Engine with MattingEngineMixin {}

Uint8List _matteBytes(dynamic value, int size) {
  final out = Uint8List(size * size);
  var i = 0;
  void walk(dynamic v) {
    if (v is num) {
      var b = (v * 255).toInt();
      if (b < 0) b = 0;
      if (b > 255) b = 255;
      out[i++] = b;
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  if (i != out.length) {
    throw StateError('matte length $i != ${out.length}');
  }
  return out;
}

/// 生产后处理链路的复刻：推理 → 模型尺度去斑+平滑 → 前景/碎片门槛 →
/// 面积放大回工作分辨率 → 按放大倍率羽化。全部调生产函数，
/// 唯一变量是 [size]（模型输入边长）。返回 (alpha, 推理毫秒)。
(Uint8List, int) _alphaPipeline(
    DecodedImage image, int sessionAddress, int size) {
  final input = modnetInput(image.rgb, image.width, image.height, size);
  final sw = Stopwatch()..start();
  final outputs = ort.runFloatInput(
      sessionAddress, input, <int>[1, 3, size, size], const <String>[]);
  Uint8List small;
  try {
    small = _matteBytes(outputs.first?.value, size);
  } finally {
    for (final o in outputs) {
      o?.release();
    }
  }
  final inferMs = sw.elapsedMilliseconds;
  small = cleanMatte(small, size);
  var foreground = 0;
  for (var i = 0; i < small.length; i++) {
    if (small[i] >= 128) foreground++;
  }
  if (foreground < small.length * kMinForegroundRatio) {
    throw const MattingException();
  }
  ensureCoherentSubject(small, size: size);
  var alpha =
      areaResampleGray(small, size, size, image.width, image.height);
  final upscale = (image.width + image.height) / (2.0 * size);
  final sigma = featherSigmaFor(upscale);
  if (sigma > 0) {
    alpha = featherGray(alpha, image.width, image.height, sigma);
  }
  return (alpha, inferMs);
}

img.Image _compositeRed(Uint8List rgb, Uint8List alpha, int w, int h) {
  final out = img.Image(width: w, height: h, numChannels: 3);
  for (var i = 0, j = 0; i < w * h; i++, j += 3) {
    final a = alpha[i];
    final inv = 255 - a;
    out.setPixelRgb(
      i % w,
      i ~/ w,
      (rgb[j] * a + 0xD9 * inv) ~/ 255,
      (rgb[j + 1] * a + 0x00 * inv) ~/ 255,
      (rgb[j + 2] * a + 0x1B * inv) ~/ 255,
    );
  }
  return out;
}

img.Image _toGray(Uint8List gray, int w, int h) {
  final im = img.Image(width: w, height: h, numChannels: 1);
  im.getBytes(order: img.ChannelOrder.red).setAll(0, gray);
  return im;
}

img.Image _zoom(img.Image src, int f) {
  final out = img.Image(
      width: src.width * f, height: src.height * f, numChannels: 3);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      out.setPixel(x, y, src.getPixel(x ~/ f, y ~/ f));
    }
  }
  return out;
}

img.Image _hstack(List<img.Image> parts) {
  final w = parts.fold<int>(0, (a, p) => a + p.width);
  final h = parts.fold<int>(0, (a, p) => math.max(a, p.height));
  final out = img.Image(width: w, height: h, numChannels: 3);
  var ox = 0;
  for (final p in parts) {
    for (var y = 0; y < p.height; y++) {
      for (var x = 0; x < p.width; x++) {
        out.setPixel(ox + x, y, p.getPixel(x, y));
      }
    }
    ox += p.width;
  }
  return out;
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory(
      '$repo${Platform.pathSeparator}out${Platform.pathSeparator}tmp'
      '${Platform.pathSeparator}matte_1024_compare')
    ..createSync(recursive: true);
  final model512 =
      '$repo${Platform.pathSeparator}out${Platform.pathSeparator}tmp'
      '${Platform.pathSeparator}modnet_portrait_512_int8.onnx';
  final model1024 =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models'
      '${Platform.pathSeparator}modnet_portrait_1024_int8.onnx';
  late int sess512, sess1024, sessFace;
  late _Engine engine;

  setUpAll(() {
    ort.ensureOrtRuntimeLoaded();
    sess512 = ort.createSession(model512).address;
    sess1024 = ort.createSession(model1024).address;
    sessFace = ort
        .createSession(
            '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models'
            '${Platform.pathSeparator}face_yunet_2023mar.onnx',
            threads: 2)
        .address;
    engine = _Engine();
    stdout.writeln('out = ${outDir.path}');
  });

  tearDownAll(() {
    ort.releaseSession(sess512);
    ort.releaseSession(sess1024);
    ort.releaseSession(sessFace);
  });

  test('512 vs 1024 发梢边缘对照', () async {
    for (final e in _samples.entries) {
      final path = '$_pics${Platform.pathSeparator}${e.value}';
      final f = File(path);
      if (!f.existsSync()) {
        stdout.writeln('${e.key}: MISSING $path');
        continue;
      }
      // 与生产兜底路径同口径解码（大图压到 kBigImageWorkEdge 工作长边）。
      final image = decodeToRgb(f.readAsBytesSync(),
          maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      final (alpha512, ms512) = _alphaPipeline(image, sess512, 512);
      final (alpha1024, ms1024) = _alphaPipeline(image, sess1024, 1024);
      final face = runFaceFromRgb(image, sessFace);
      stdout.writeln('${e.key} ${image.width}x${image.height} '
          'infer: 512=${ms512}ms 1024=${ms1024}ms '
          'face=${face == null ? "none" : "ok"}');

      // 发梢边缘裁片：人脸框上方/两侧是发丝最碎的区域（100% 原生像素）。
      final w = image.width, h = image.height;
      const ez = 320;
      final fx = face?.box.left ?? w / 4;
      final fy = face?.box.top ?? h / 8;
      final fw = face?.box.width ?? w / 2;
      final fh = face?.box.height ?? h / 4;
      final maxX = w - ez > 0 ? w - ez : 0;
      final maxY = h - ez > 0 ? h - ez : 0;
      final ex = (fx + fw / 2 - ez / 2).round().clamp(0, maxX);
      final ey = (fy - 0.35 * fh).round().clamp(0, maxY);

      img.Image cropOf(img.Image src) {
        final c = img.Image(width: ez, height: ez, numChannels: 3);
        for (var y = 0; y < ez; y++) {
          for (var x = 0; x < ez; x++) {
            c.setPixel(x, y, src.getPixel(ex + x, ey + y));
          }
        }
        return c;
      }

      final srcImg = img.Image(width: w, height: h, numChannels: 3);
      for (var i = 0, j = 0; i < w * h; i++, j += 3) {
        srcImg.setPixelRgb(i % w, i ~/ w, image.rgb[j], image.rgb[j + 1],
            image.rgb[j + 2]);
      }
      final red512 = _compositeRed(image.rgb, alpha512, w, h);
      final red1024 = _compositeRed(image.rgb, alpha1024, w, h);
      final crops = <img.Image>[
        cropOf(srcImg),
        cropOf(red512),
        cropOf(red1024)
      ];
      File('${outDir.path}${Platform.pathSeparator}${e.key}_edge_100pct.png')
          .writeAsBytesSync(img.encodePng(_hstack(crops)));
      File('${outDir.path}${Platform.pathSeparator}${e.key}_edge_2x.png')
          .writeAsBytesSync(
              img.encodePng(_hstack(crops.map((c) => _zoom(c, 2)).toList())));
      File('${outDir.path}${Platform.pathSeparator}${e.key}_alpha512.png')
          .writeAsBytesSync(img.encodePng(_toGray(alpha512, w, h)));
      File('${outDir.path}${Platform.pathSeparator}${e.key}_alpha1024.png')
          .writeAsBytesSync(img.encodePng(_toGray(alpha1024, w, h)));
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('非人像在 1024 口径下仍优雅拒绝', () async {
    // 人脸门槛走生产引擎（1024 模型已在 warmUp 加载）。只验证"抛契约异常
    // 而不是崩溃/伪成功"，不验证具体异常类型（人脸门槛与碎片门槛谁先触发
    // 都有可能）。
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    await engine.warmUp();
    for (final name in const <String>[
      r'Globe_High.png',
      r'QQ截图20230115131411.jpg',
    ]) {
      final f = File('$_pics${Platform.pathSeparator}$name');
      if (!f.existsSync()) continue;
      try {
        await engine.removeBackground(f.readAsBytesSync());
        stdout.writeln('nonportrait $name: UNEXPECTED SUCCESS');
        fail('non-portrait should be rejected: $name');
      } on IdPhotoException catch (e) {
        stdout.writeln('nonportrait $name: rejected ${e.runtimeType}');
      }
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
