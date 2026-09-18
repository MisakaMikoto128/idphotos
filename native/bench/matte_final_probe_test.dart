// ml-porting 自用：**成片**质量肉眼探针（不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/matte_final_probe_test.dart
//
// 走真实引擎（IdPhotoEngineImpl，含 imaging 的 compose），把
// C:\Users\liuyu\Pictures\ 里的人像出成用户真正看到的候选 JPEG
// （一寸 295×413 @300dpi，白/蓝/红三底），再拼一张 [原图 | 白 | 蓝 | 红]
// 对照图 + 一张边缘放大图，写到系统临时目录/muzhao_final/。
//
// 目的：抠图侧的 alpha 在 compose 里会被**硬化成 0/1**（render.dart），
// 所以肉眼看软边探针会得出错误结论——必须看硬化后的真成片。
@Timeout(Duration(minutes: 60))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/engine_impl.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

void _preloadHostOnnxRuntime() {
  if (!Platform.isWindows) return;
  final home = Platform.environment['LOCALAPPDATA'];
  if (home == null) return;
  final dir = Directory('$home\\Pub\\Cache\\hosted\\pub.dev');
  if (!dir.existsSync()) return;
  for (final e in dir.listSync()) {
    final name = e.path.split(Platform.pathSeparator).last;
    if (e is Directory && name.startsWith('onnxruntime-')) {
      final dll = File('${e.path}\\windows\\onnxruntime.dll');
      if (dll.existsSync()) {
        DynamicLibrary.open(dll.path);
        return;
      }
    }
  }
}

const String _pics = r'C:\Users\liuyu\Pictures';

const Map<String, String> _samples = <String, String>{
  'p_2': r'2.jpg',
  'p_29': r'29EDA59B982FA8339335D50B00CCD096.jpg',
  'p_8d': r'8D861A29F86CE7464865EFEB3C9B4124.jpg',
  'p_a': r'a.jpg',
  'p_wu': r'吴港+通信工程+532128200107160711.jpg',
  'p_bm': r'报名照片.jpg',
  'p_1x2': r'1 (2).jpg',
};

img.Image _decode(Uint8List jpeg) => img.decodeJpg(jpeg)!;

/// 3× 最近邻放大，看锯齿/台阶/发丝。
img.Image _zoom(img.Image src, int x0, int y0, int w, int h, int f) {
  final out = img.Image(width: w * f, height: h * f, numChannels: src.numChannels);
  for (var y = 0; y < h * f; y++) {
    for (var x = 0; x < w * f; x++) {
      out.setPixel(x, y, src.getPixel(
          (x0 + x ~/ f).clamp(0, src.width - 1),
          (y0 + y ~/ f).clamp(0, src.height - 1)));
    }
  }
  return out;
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}muzhao_final')
    ..createSync(recursive: true);
  late IdPhotoEngineImpl engine;

  setUpAll(() async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = IdPhotoEngineImpl();
    await engine.warmUp();
    stdout.writeln('out = ${outDir.path}');
  });

  tearDownAll(() => engine.disposeMattingEngine());

  test('成片肉眼探针', () async {
    for (final e in _samples.entries) {
      final path = '$_pics${Platform.pathSeparator}${e.value}';
      final f = File(path);
      if (!f.existsSync()) {
        stdout.writeln('${e.key}: MISSING');
        continue;
      }
      final bytes = f.readAsBytesSync();
      final MattingResult m;
      try {
        m = await engine.removeBackground(bytes);
      } on IdPhotoException catch (ex) {
        stdout.writeln('${e.key}: REJECT ${ex.runtimeType}');
        continue;
      }
      final face = await engine.detectFace(bytes);
      final cands = <Candidate>[];
      for (final bg in <BackgroundStyle>[kBgWhite, kBgBlue, kBgRed]) {
        cands.add(await engine.compose(
            matting: m, spec: kSpecCn1inch, style: bg, face: face));
      }
      // 拼图：原图（缩到同高）+ 三张成片
      final srcImg = _decode(img.encodeJpg(
          _srcFromRgba(m).convert(numChannels: 3)));
      final parts = <img.Image>[
        _fit(srcImg, 413),
        for (final c in cands) _decode(c.jpegBytes),
      ];
      final W = parts.fold<int>(0, (a, b) => a + b.width);
      final sheet = img.Image(width: W, height: 413, numChannels: 3);
      var ox = 0;
      for (final p in parts) {
        for (var y = 0; y < 413 && y < p.height; y++) {
          for (var x = 0; x < p.width; x++) {
            sheet.setPixel(ox + x, y, p.getPixel(x, y));
          }
        }
        ox += p.width;
      }
      File('${outDir.path}${Platform.pathSeparator}${e.key}_final.png')
          .writeAsBytesSync(img.encodePng(sheet));

      // 头顶发丝 + 肩线两处放大（成片坐标）
      final edgeSheet = img.Image(
          width: 3 * 160 * 3, height: 160 * 3, numChannels: 3);
      var k = 0;
      for (final c in cands) {
        final im = _decode(c.jpegBytes);
        final z = _zoom(im, 60, 20, 160, 160, 3); // 头顶
        for (var y = 0; y < z.height; y++) {
          for (var x = 0; x < z.width; x++) {
            edgeSheet.setPixel(k * 480 + x, y, z.getPixel(x, y));
          }
        }
        k++;
      }
      File('${outDir.path}${Platform.pathSeparator}${e.key}_top.png')
          .writeAsBytesSync(img.encodePng(edgeSheet));

      stdout.writeln('${e.key} matte=${m.width}x${m.height} '
          'face=${face == null ? 'null' : '${face.box.width.toStringAsFixed(0)}x${face.box.height.toStringAsFixed(0)}'}');
    }
  }, timeout: const Timeout(Duration(minutes: 50)));
}

img.Image _srcFromRgba(MattingResult m) {
  final out = img.Image(width: m.width, height: m.height, numChannels: 3);
  for (var i = 0, j = 0; i < m.width * m.height; i++, j += 4) {
    out.setPixelRgb(
        i % m.width, i ~/ m.width, m.rgba[j], m.rgba[j + 1], m.rgba[j + 2]);
  }
  return out;
}

img.Image _fit(img.Image src, int h) {
  final s = h / src.height;
  return img.copyResize(src,
      width: math.max(1, (src.width * s).round()), height: h);
}
