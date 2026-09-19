// ml-porting 自用：BiRefNet 换档的 before/after 对照（不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/birefnet_compare_test.dart
//
// 口径：
//   * BiRefNet = 生产引擎完整链路（removeBackground：decode → 人脸门槛 →
//     birefnetInput → 推理 → sigmoid → cleanMatte → 门槛 → 放大羽化）。
//   * MODNet-1024 = worker 级复刻旧生产链路（modnetInput + 同一套
//     cleanMatte/门槛/放大/羽化函数），模型用保留的
//     assets/models/modnet_portrait_1024_int8.onnx。
//   * 三色底（红 #D9001B / 蓝 #438EDB / 白 #FFFFFF）合成并排，红底最显瑕疵；
//     另附发丝边缘 100%/2× 裁片与全幅 alpha。
//   * cleanMatte 参数 A/B：BiRefNet 红底裁片分别用 (1,0.4)（沿自 MODNet）、
//     (0,0)、(0,0.4) 三组参数产出，供换档后参数去留决策。
//
// 产物：native/bench/out/birefnet_compare/。
@Timeout(Duration(minutes: 120))
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/matting_worker.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

const String _pics = r'C:\Users\liuyu\Pictures';

/// 人像样本（都含可见发丝，覆盖直发/卷发/碎发梢）。
const Map<String, String> _samples = <String, String>{
  'p_1x2': r'1 (2).jpg',
  'p_2': r'2.jpg',
  'p_29': r'29EDA59B982FA8339335D50B00CCD096.jpg',
  'p_wu': r'吴港+通信工程+532128200107160711.jpg',
  'p_bm': r'报名照片.jpg',
};

class _Engine with MattingEngineMixin {}

/// MODNet 旧口径：`(matte*255)` 向零截断（无 sigmoid）。
Uint8List _matteBytesModnet(dynamic value, int size) {
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

/// MODNet-1024 旧生产链路的复刻（与 BiRefNet 唯一差异 = 模型与前/后处理
/// 口径；去斑/门槛/放大/羽化全部共用生产函数）。
(Uint8List, int) _modnetAlpha(DecodedImage image, int sessionAddress) {
  const size = ort.kMattingInputSize;
  final input = modnetInput(image.rgb, image.width, image.height, size);
  final sw = Stopwatch()..start();
  final outputs = ort.runFloatInput(
      sessionAddress, input, <int>[1, 3, size, size], const <String>[]);
  Uint8List small;
  try {
    small = _matteBytesModnet(outputs.first?.value, size);
  } finally {
    for (final o in outputs) {
      o?.release();
    }
  }
  final inferMs = sw.elapsedMilliseconds;
  small = cleanMatte(small, size);
  ensureCoherentSubject(small, size: size);
  var alpha = areaResampleGray(small, size, size, image.width, image.height);
  final upscale = (image.width + image.height) / (2.0 * size);
  final sigma = featherSigmaFor(upscale);
  if (sigma > 0) {
    alpha = featherGray(alpha, image.width, image.height, sigma);
  }
  return (alpha, inferMs);
}

/// BiRefNet 模型尺度 alpha 的 cleanMatte 参数 A/B 变体（供参数去留决策）。
/// 输入是生产引擎返回的工作分辨率 alpha —— 无法回推模型尺度，所以这里
/// 直接复刻生产后处理链（birefnetInput → 推理 → sigmoid → 参数化
/// cleanMatte → 放大 → 羽化）。
Uint8List _birefnetAlphaVariant(DecodedImage image, int sessionAddress,
    int medianPasses, double smoothSigma) {
  const size = ort.kMattingInputSize;
  final input = birefnetInput(image.rgb, image.width, image.height, size);
  final outputs = ort.runFloatInput(
      sessionAddress, input, <int>[1, 3, size, size], const <String>[]);
  dynamic value;
  try {
    value = outputs.first?.value;
    // sigmoid + 向零截断，与生产 _matteToBytes 同口径。
    final small = Uint8List(size * size);
    var i = 0;
    void walk(dynamic v) {
      if (v is num) {
        final p = 1.0 / (1.0 + math.exp(-v.toDouble()));
        var b = (p * 255).toInt();
        if (b < 0) b = 0;
        if (b > 255) b = 255;
        small[i++] = b;
      } else if (v is List) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(value);
    var s = cleanMatte(small, size,
        medianPasses: medianPasses, smoothSigma: smoothSigma);
    var alpha =
        areaResampleGray(s, size, size, image.width, image.height);
    final upscale = (image.width + image.height) / (2.0 * size);
    final sigma = featherSigmaFor(upscale);
    if (sigma > 0) {
      alpha = featherGray(alpha, image.width, image.height, sigma);
    }
    return alpha;
  } finally {
    for (final o in outputs) {
      o?.release();
    }
  }
}

img.Image _composite(Uint8List rgb, Uint8List alpha, int w, int h,
    int cr, int cg, int cb) {
  final out = img.Image(width: w, height: h, numChannels: 3);
  for (var i = 0, j = 0; i < w * h; i++, j += 3) {
    final a = alpha[i];
    final inv = 255 - a;
    out.setPixelRgb(
      i % w,
      i ~/ w,
      (rgb[j] * a + cr * inv) ~/ 255,
      (rgb[j + 1] * a + cg * inv) ~/ 255,
      (rgb[j + 2] * a + cb * inv) ~/ 255,
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

img.Image _downscale(img.Image src, int maxEdge) {
  final long = math.max(src.width, src.height);
  if (long <= maxEdge) return src;
  final s = maxEdge / long;
  return img.copyResize(src,
      width: (src.width * s).round(),
      height: (src.height * s).round(),
      interpolation: img.Interpolation.average);
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory(
      '$repo${Platform.pathSeparator}native${Platform.pathSeparator}bench'
      '${Platform.pathSeparator}out${Platform.pathSeparator}birefnet_compare')
    ..createSync(recursive: true);
  final modnetModel =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models'
      '${Platform.pathSeparator}modnet_portrait_1024_int8.onnx';
  final birefnetModel =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models'
      '${Platform.pathSeparator}birefnet_lite_1024_int8.onnx';
  final faceModel =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models'
      '${Platform.pathSeparator}face_yunet_2023mar.onnx';
  late int sessModnet, sessBirefnet, sessFace;
  late _Engine engine;

  setUpAll(() async {
    ort.ensureOrtRuntimeLoaded();
    sessModnet = ort.createSession(modnetModel).address;
    sessBirefnet = ort.createSession(birefnetModel).address;
    sessFace = ort.createSession(faceModel, threads: 2).address;
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = _Engine();
    await engine.warmUp();
    stdout.writeln('out = ${outDir.path}');
  });

  tearDownAll(() async {
    ort.releaseSession(sessModnet);
    ort.releaseSession(sessBirefnet);
    ort.releaseSession(sessFace);
    await engine.disposeMattingEngine();
  });

  test('MODNet vs BiRefNet 三色底并排 + 发丝裁片', () async {
    // 底色与 docs/CONTRACTS.md §5 一致。
    const bgs = <String, (int, int, int)>{
      'red': (0xD9, 0x00, 0x1B),
      'blue': (0x43, 0x8E, 0xDB),
      'white': (0xFF, 0xFF, 0xFF),
    };
    for (final e in _samples.entries) {
      final path = '$_pics${Platform.pathSeparator}${e.value}';
      final f = File(path);
      if (!f.existsSync()) {
        stdout.writeln('${e.key}: MISSING $path');
        continue;
      }
      final bytes = f.readAsBytesSync();
      // 与生产兜底路径同口径解码（大图压到 kBigImageWorkEdge 工作长边）。
      final image = decodeToRgb(bytes,
          maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      final w = image.width, h = image.height;

      // MODNet：worker 级旧链路。
      final swM = Stopwatch()..start();
      final (alphaM, msM) = _modnetAlpha(image, sessModnet);
      // BiRefNet：生产引擎完整链路（含人脸门槛）。
      final swB = Stopwatch()..start();
      final r = await engine.removeBackground(bytes);
      final msB = swB.elapsedMilliseconds;
      swM.stop();
      // 引擎工作分辨率与本 bench 解码口径一致性检查（≤2048 的图应逐位一致；
      // 大图走 dart:ui 降采样，只比尺寸）。
      if (r.width != w || r.height != h) {
        stdout.writeln(
            '${e.key}: engine ${r.width}x${r.height} vs bench ${w}x$h （大图降采样口径差，alpha 各自合成）');
      }
      final alphaB = r.alpha;
      final bw = r.width, bh = r.height;
      final rgbB = Uint8List(bw * bh * 3);
      for (var i = 0, j = 0, o = 0; i < bw * bh; i++, j += 3, o += 4) {
        rgbB[j] = r.rgba[o];
        rgbB[j + 1] = r.rgba[o + 1];
        rgbB[j + 2] = r.rgba[o + 2];
      }
      stdout.writeln('${e.key} ${w}x$h: modnet infer=${msM}ms, '
          'birefnet engine e2e=${msB}ms');

      // 三色底全幅并排（降到长边 900 便于查看）：上排 MODNet，下排 BiRefNet。
      final rowM = <img.Image>[];
      final rowB = <img.Image>[];
      for (final bg in bgs.entries) {
        rowM.add(_composite(image.rgb, alphaM, w, h,
            bg.value.$1, bg.value.$2, bg.value.$3));
        rowB.add(_composite(rgbB, alphaB, bw, bh,
            bg.value.$1, bg.value.$2, bg.value.$3));
      }
      final strip = <img.Image>[
        for (var i = 0; i < rowM.length; i++)
          _hstack(<img.Image>[
            _downscale(rowM[i], 900),
            _downscale(rowB[i], 900),
          ]),
      ];
      for (var i = 0; i < bgs.length; i++) {
        File('${outDir.path}${Platform.pathSeparator}'
                '${e.key}_${bgs.keys.elementAt(i)}_modnet_vs_birefnet.png')
            .writeAsBytesSync(img.encodePng(strip[i]));
      }

      // 发丝边缘裁片（100% + 2×）：[源图 | MODNet 红底 | BiRefNet 红底]。
      final face = runFaceFromRgb(image, sessFace);
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
        srcImg.setPixelRgb(
            i % w, i ~/ w, image.rgb[j], image.rgb[j + 1], image.rgb[j + 2]);
      }
      final redM = _composite(image.rgb, alphaM, w, h, 0xD9, 0x00, 0x1B);

      // BiRefNet alpha 若与 bench 解码同尺寸，直接裁；不同尺寸（大图降采样
      // 口径差）则跳过裁片，全幅并排图仍可看。
      if (bw == w && bh == h) {
        final redB = _composite(rgbB, alphaB, w, h, 0xD9, 0x00, 0x1B);
        final crops = <img.Image>[cropOf(srcImg), cropOf(redM), cropOf(redB)];
        File('${outDir.path}${Platform.pathSeparator}${e.key}_edge_100pct.png')
            .writeAsBytesSync(img.encodePng(_hstack(crops)));
        File('${outDir.path}${Platform.pathSeparator}${e.key}_edge_2x.png')
            .writeAsBytesSync(img.encodePng(
                _hstack(crops.map((c) => _zoom(c, 2)).toList())));
      }
      File('${outDir.path}${Platform.pathSeparator}${e.key}_alpha_modnet.png')
          .writeAsBytesSync(img.encodePng(_toGray(alphaM, w, h)));
      File('${outDir.path}${Platform.pathSeparator}${e.key}_alpha_birefnet.png')
          .writeAsBytesSync(img.encodePng(_toGray(alphaB, bw, bh)));
    }
  }, timeout: const Timeout(Duration(minutes: 90)));

  test('BiRefNet cleanMatte 参数 A/B（红底发丝裁片）', () async {
    const variants = <(String, int, double)>[
      ('med1_sig04', 1, 0.4), // 沿自 MODNet 的现参数
      ('med0_sig00', 0, 0.0),
      ('med0_sig04', 0, 0.4),
    ];
    for (final e in _samples.entries) {
      final path = '$_pics${Platform.pathSeparator}${e.value}';
      final f = File(path);
      if (!f.existsSync()) continue;
      final image = decodeToRgb(f.readAsBytesSync(),
          maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      final w = image.width, h = image.height;
      final face = runFaceFromRgb(image, sessFace);
      const ez = 320;
      final fx = face?.box.left ?? w / 4;
      final fy = face?.box.top ?? h / 8;
      final fw = face?.box.width ?? w / 2;
      final fh = face?.box.height ?? h / 4;
      final ex = (fx + fw / 2 - ez / 2)
          .round()
          .clamp(0, w - ez > 0 ? w - ez : 0);
      final ey =
          (fy - 0.35 * fh).round().clamp(0, h - ez > 0 ? h - ez : 0);
      final crops = <img.Image>[];
      for (final v in variants) {
        final alpha =
            _birefnetAlphaVariant(image, sessBirefnet, v.$2, v.$3);
        final red = _composite(image.rgb, alpha, w, h, 0xD9, 0x00, 0x1B);
        final c = img.Image(width: ez, height: ez, numChannels: 3);
        for (var y = 0; y < ez; y++) {
          for (var x = 0; x < ez; x++) {
            c.setPixel(x, y, red.getPixel(ex + x, ey + y));
          }
        }
        crops.add(c);
      }
      File('${outDir.path}${Platform.pathSeparator}'
              '${e.key}_cleanmatte_ab_2x.png')
          .writeAsBytesSync(img.encodePng(
              _hstack(crops.map((c) => _zoom(c, 2)).toList())));
      stdout.writeln('${e.key}: cleanMatte A/B done');
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}
