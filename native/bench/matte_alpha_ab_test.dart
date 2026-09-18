// ml-porting 诊断：alpha 后处理变体对**最终成片**的影响 A/B（不是门禁）。
//
// 跑法：
//   python native/bench/alpha_variant_gen.py
//   flutter test native/bench/matte_alpha_ab_test.dart
//
// 每个变体都走同一条真实 render 路径（engine.compose），只换 alpha。
// 产物：native/bench/out/ab_<name>.png
//   上排 = 一寸白底成片；下排 = 头顶 3× 放大（看轮廓锯齿/台阶/缺角）。
// 面板顺序 = _variants。
@Timeout(Duration(minutes: 60))
library;

import 'dart:ffi';
import 'dart:io';
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
  'p_1x2': r'1 (2).jpg',
  'p_wu': r'吴港+通信工程+532128200107160711.jpg',
};

/// 面板顺序，与 alpha_variant_gen.py 的产物一一对应。
const List<String> _variants = <String>['512','bil','bic'];

Uint8List _grayOf(File f) {
  final im = img.decodePng(f.readAsBytesSync())!;
  final g = im.numChannels == 1
      ? im
      : im.convert(format: img.Format.uint8, numChannels: 1);
  return Uint8List.fromList(g.getBytes(order: img.ChannelOrder.red));
}

img.Image _zoom(img.Image src, int x0, int y0, int w, int h, int f) {
  final out =
      img.Image(width: w * f, height: h * f, numChannels: src.numChannels);
  for (var y = 0; y < h * f; y++) {
    for (var x = 0; x < w * f; x++) {
      out.setPixel(
          x,
          y,
          src.getPixel((x0 + x ~/ f).clamp(0, src.width - 1),
              (y0 + y ~/ f).clamp(0, src.height - 1)));
    }
  }
  return out;
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory('$repo${Platform.pathSeparator}native'
      '${Platform.pathSeparator}bench${Platform.pathSeparator}out');
  late IdPhotoEngineImpl engine;

  setUpAll(() async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = IdPhotoEngineImpl();
    await engine.warmUp();
  });

  tearDownAll(() => engine.disposeMattingEngine());

  test('alpha 后处理变体 A/B', () async {
    for (final e in _samples.entries) {
      final f = File('$_pics${Platform.pathSeparator}${e.value}');
      if (!f.existsSync()) continue;
      final bytes = f.readAsBytesSync();
      final MattingResult m;
      try {
        m = await engine.removeBackground(bytes);
      } on IdPhotoException {
        continue;
      }
      final face = await engine.detectFace(bytes);

      final panels = <img.Image>[];
      final names = <String>[];
      // 先放引擎**当前**自产的 alpha（改了代码就是"改后"），再放磁盘上的
      // 参考变体（av_*_512 是"改前"口径：未清理的 INTER_AREA 放大）。
      final variantsToRender = <String, Uint8List>{'ENGINE': m.alpha};
      for (final v in _variants) {
        final af = File('${outDir.path}${Platform.pathSeparator}'
            'av_${e.key}_$v.png');
        if (!af.existsSync()) {
          stdout.writeln('${e.key}/$v MISSING');
          continue;
        }
        final a = _grayOf(af);
        if (a.length != m.width * m.height) {
          stdout.writeln('${e.key}/$v SIZE ${a.length} vs ${m.width * m.height}');
          continue;
        }
        variantsToRender[v] = a;
      }
      for (final e2 in variantsToRender.entries) {
        final res = MattingResult(
            rgba: m.rgba,
            alpha: e2.value,
            width: m.width,
            height: m.height,
            sourceWidth: m.sourceWidth,
            sourceHeight: m.sourceHeight);
        final c = await engine.compose(
            matting: res, spec: kSpecCn1inch, style: kBgWhite, face: face);
        panels.add(img.decodeJpg(c.jpegBytes)!);
        names.add(e2.key);
      }
      if (panels.isEmpty) continue;
      const pw = 295, ph = 413;
      final sheet = img.Image(
          width: pw * panels.length, height: ph * 2, numChannels: 3);
      for (var k = 0; k < panels.length; k++) {
        for (var y = 0; y < ph; y++) {
          for (var x = 0; x < pw; x++) {
            sheet.setPixel(k * pw + x, y, panels[k].getPixel(x, y));
          }
        }
        // 头顶 3× 放大，再按最近邻压进 ph 高度（保留下采样后的锯齿）
        final z = _zoom(panels[k], 55, 10, 190, 190, 3);
        for (var y = 0; y < ph; y++) {
          final sy = (y * z.height / ph).floor().clamp(0, z.height - 1);
          for (var x = 0; x < pw; x++) {
            sheet.setPixel(k * pw + x, ph + y, z.getPixel(x, sy));
          }
        }
      }
      File('${outDir.path}${Platform.pathSeparator}ab_${e.key}.png')
          .writeAsBytesSync(img.encodePng(sheet));
      stdout.writeln('${e.key} panels=${names.join(",")}');
    }
  }, timeout: const Timeout(Duration(minutes: 50)));
}
