// ml-porting 自用：瞳孔定位的**目视证据**生成器。
// 对每张图跑生产 detectFace + estimatePupilRoll，把检出的瞳孔中心、瞳孔连线
// （绿）与水平参考线（黄）画到工作分辨率原图上，另存眼睛区域的 2× 放大裁切。
// 判据：绿圈必须落在瞳孔/虹膜上；落在眼睑褶、眉毛、镜框、卧蚕上即为误检。
// 红圈/红线 = YuNet 眼球关键点与眼线，**仅供对照**（它就是 P0 的元凶）。
//
// 输出：native/bench/out/iris_overlay/<name>.full.png / <name>.eye.png
// 跑法：flutter test native/bench/iris_roll_overlay_test.dart
@Timeout(Duration(minutes: 40))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as m;
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/iris_roll.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
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

class _Engine with MattingEngineMixin {
  void dispose() {
    disposeMattingEngine();
  }
}

void _px(img.Image im, int x, int y, int c) {
  if (x < 0 || y < 0 || x >= im.width || y >= im.height) return;
  im.setPixelRgb(x, y, (c >> 16) & 255, (c >> 8) & 255, c & 255);
}

void _line(img.Image im, double x0, double y0, double x1, double y1, int c) {
  final int steps =
      (x1 - x0).abs().toInt() + (y1 - y0).abs().toInt() + 1;
  for (var i = 0; i <= steps; i++) {
    final double t = steps == 0 ? 0.0 : i / steps;
    _px(im, (x0 + (x1 - x0) * t).round(), (y0 + (y1 - y0) * t).round(), c);
  }
}

void _ring(img.Image im, double cx, double cy, double r, int c) {
  for (var a = 0; a < 720; a++) {
    final double t = a * m.pi / 360.0;
    for (double d = r - 1.5; d <= r + 1.5; d += 0.5) {
      _px(im, (cx + d * m.cos(t)).round(), (cy + d * m.sin(t)).round(), c);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _Engine();
  final outDir = Directory('native/bench/out/iris_overlay');
  outDir.createSync(recursive: true);

  test('生成瞳孔定位目视证据', () async {
    await engine.warmUp();
    final List<String> targets = <String>[
      r'C:\Users\liuyu\Pictures\2.jpg',
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      r'C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png',
      r'C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124 (自定义).jpg',
      r'C:\Users\liuyu\Pictures\a.jpg',
      r'C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png',
      r'C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png',
      for (var i = 1; i <= 8; i++) 'test/golden/src/g0$i.jpg',
    ];
    for (final path in targets) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final String base = file.uri.pathSegments.last;
      final Uint8List bytes = file.readAsBytesSync();
      final FaceInfo? face = await engine.detectFace(bytes);
      if (face == null) {
        // ignore: avoid_print
        print('[ovl] $base -> no face');
        continue;
      }
      final DecodedImage im = decodeToRgb(bytes,
          maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      final img.Image canvas = img.Image.fromBytes(
        width: im.width,
        height: im.height,
        bytes: im.rgb.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      );
      final Float32List lm = face.landmarks!;
      final PupilRoll pr = estimatePupilRoll(
        gray: grayPlaneFromRgb(im.rgb, im.width, im.height),
        width: im.width,
        height: im.height,
        eyeAx: lm[0],
        eyeAy: lm[1],
        eyeBx: lm[2],
        eyeBy: lm[3],
      );
      final double yunet = lm[2] > lm[0]
          ? m.atan2(lm[3] - lm[1], lm[2] - lm[0]) * 180 / m.pi
          : m.atan2(lm[1] - lm[3], lm[0] - lm[2]) * 180 / m.pi;
      // 红 = YuNet 眼线（对照），黄 = 过左眼点的水平参考。
      _line(canvas, lm[0], lm[1], lm[2], lm[3], 0xFF0000);
      _line(canvas, lm[0], lm[1], lm[2], lm[1], 0xFFFF00);
      _ring(canvas, lm[0], lm[1], 5, 0xFF0000);
      _ring(canvas, lm[2], lm[3], 5, 0xFF0000);
      if (pr.available) {
        final PupilPoint l = pr.left!;
        final PupilPoint r = pr.right!;
        _line(canvas, l.x, l.y, r.x, r.y, 0x00FF00);
        _line(canvas, l.x, l.y, r.x, l.y, 0xFFFF00);
        _ring(canvas, l.x, l.y, l.diameterPx / 2, 0x00FF00);
        _ring(canvas, r.x, r.y, r.diameterPx / 2, 0x00FF00);
      }
      final String name =
          base.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
      File('${outDir.path}/$name.full.png')
          .writeAsBytesSync(img.encodePng(canvas, level: 3));
      final double ed = pr.available
          ? pr.eyeDistPx
          : (((lm[2] - lm[0]).abs() + (lm[3] - lm[1]).abs()) + 1).toDouble();
      final double cx = (lm[0] + lm[2]) / 2;
      final double cy = (lm[1] + lm[3]) / 2;
      final int x0 = (cx - 1.1 * ed).round().clamp(0, im.width - 2);
      final int x1 = (cx + 1.1 * ed).round().clamp(1, im.width - 1);
      final int y0 = (cy - 0.75 * ed).round().clamp(0, im.height - 2);
      final int y1 = (cy + 0.75 * ed).round().clamp(1, im.height - 1);
      if (x1 > x0 && y1 > y0) {
        final img.Image eye = img.copyCrop(canvas,
            x: x0, y: y0, width: x1 - x0, height: y1 - y0);
        img.Image zoom = img.copyResize(eye,
            width: (eye.width * 2).clamp(1, 1600),
            interpolation: img.Interpolation.linear);
        File('${outDir.path}/$name.eye.png')
            .writeAsBytesSync(img.encodePng(zoom, level: 3));
      }
      // ignore: avoid_print
      print('[ovl] $base yuNet=${yunet.toStringAsFixed(2)} -> $pr');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 40)));
}
