/// roll_repro step8: 同一 matting、不同 rollDeg 注入的成片对照。
/// A=roll 0, B=roll est(-3.815), C=roll -10, D=roll +10。
/// 两两之间的内容旋转量用 Python 配准测量（step9）。
/// 运行：flutter test lib/core/imaging/dev_roll_ab.dart
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

FaceInfo _withRoll(FaceInfo f, double roll) {
  return FaceInfo(
    box: f.box,
    chinY: f.chinY,
    headTopY: f.headTopY,
    rollDeg: roll,
    confidence: f.confidence,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FullEngine();
  final outDir = Directory('out/tmp/roll_repro');
  outDir.createSync(recursive: true);

  test('rollDeg 注入对照', () async {
    await engine.warmUp();
    final PhotoSpec spec = specCn1inch;
    final Uint8List src =
        File(r'C:/Users/liuyu/Pictures/2.jpg').readAsBytesSync();
    final FaceInfo? face = await engine.detectFace(src);
    final MattingResult matting = await engine.removeBackground(src);
    // ignore: avoid_print
    print('[ab] est roll=${face!.rollDeg.toStringAsFixed(3)}');

    for (final double roll in <double>[0.0, -10.0, 10.0, face.rollDeg]) {
      final Candidate c = await engine.compose(
        matting: matting,
        spec: spec,
        style: kBgBlue,
        face: _withRoll(face, roll),
      );
      final String tag = roll.toStringAsFixed(3).replaceAll('-', 'm');
      final String fn = '${outDir.path}/ab_p2_roll_$tag.jpg';
      File(fn).writeAsBytesSync(c.jpegBytes);
      final ComposeDiagnostics d = engine.lastDiagnostics!;
      // ignore: avoid_print
      print('[ab] roll=$roll -> $fn straightenDeg='
          '${d.straightenDeg.toStringAsFixed(3)} crop=${d.cropRect}');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
