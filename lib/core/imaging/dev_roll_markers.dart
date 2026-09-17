/// roll_repro step7: 标记点 + 虹膜质心 — 生产 compose 几何端到端验证。
/// 运行：flutter test lib/core/imaging/dev_roll_markers.dart
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/imaging/compose_engine.dart';
import 'package:muzhao/core/imaging/crop_geometry.dart';
import 'package:muzhao/core/specs/photo_specs.dart';

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

class _FullEngine with MattingEngineMixin, ComposeEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FullEngine();
  final outDir = Directory('out/tmp/roll_repro');
  outDir.createSync(recursive: true);

  test('标记点落点预测 + 生产路径验证', () async {
    await engine.warmUp();
    final PhotoSpec spec = specCn1inch;

    // ---- p2：蓝底证件照 ----
    final Uint8List src =
        File(r'C:/Users/liuyu/Pictures/2.jpg').readAsBytesSync();
    final FaceInfo? face0 = await engine.detectFace(src);
    // ignore: avoid_print
    print('[p2] face0 roll=${face0!.rollDeg.toStringAsFixed(3)}');

    // 衬衫上画 3 个青色 5px 圆点（源图坐标，落在人物前景里）
    final img.Image im = img.decodeJpg(src)!;
    const List<List<int>> dots = <List<int>>[
      [430, 1330],
      [560, 1345],
      [700, 1315],
    ];
    for (final List<int> d in dots) {
      for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
          if (dx * dx + dy * dy <= 4) {
            im.setPixelRgba(d[0] + dx, d[1] + dy, 0, 255, 255, 255);
          }
        }
      }
    }
    final Uint8List marked =
        Uint8List.fromList(img.encodeJpg(im, quality: 97));
    File('${outDir.path}/p2_marked_src.png').writeAsBytesSync(
        img.encodePng(img.decodeJpg(marked)!));

    final FaceInfo? faceM = await engine.detectFace(marked);
    // ignore: avoid_print
    print('[p2] faceM roll=${faceM!.rollDeg.toStringAsFixed(3)} '
        '(marked, should be ~same)');
    final MattingResult matting = await engine.removeBackground(marked);

    final Candidate c = await engine.compose(
      matting: matting,
      spec: spec,
      style: kBgBlue,
      face: faceM,
    );
    File('${outDir.path}/p2_marked_blue.jpg')
        .writeAsBytesSync(c.jpegBytes);
    final ComposeDiagnostics diag = engine.lastDiagnostics!;
    // ignore: avoid_print
    print('[p2] straightenDeg=${diag.straightenDeg.toStringAsFixed(3)} '
        'crop=${diag.cropRect}');

    // 解析预测标记落点（与生产同一几何库）
    final RotationPlan plan = planRotation(
      srcWidth: matting.width,
      srcHeight: matting.height,
      rollDeg: faceM.rollDeg,
    );
    final List<double> p = <double>[0, 0];
    for (final List<int> d in dots) {
      plan.toRotated(d[0].toDouble(), d[1].toDouble(), p);
      final double ox = (p[0] - diag.cropRect.left) /
          diag.cropRect.width *
          spec.widthPx;
      final double oy = (p[1] - diag.cropRect.top) /
          diag.cropRect.height *
          spec.heightPx;
      // ignore: avoid_print
      print('[p2] dot src=(${d[0]},${d[1]}) -> rotSpace='
          '(${p[0].toStringAsFixed(1)},${p[1].toStringAsFixed(1)}) -> '
          'out=(${ox.toStringAsFixed(1)},${oy.toStringAsFixed(1)})');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
