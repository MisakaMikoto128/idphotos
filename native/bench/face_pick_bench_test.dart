// multi_face 选脸调试台（ml-porting 自用）。
//
// 跑法：flutter test native/bench/face_pick_bench_test.dart
//
// 对 qa-batch 报问题 4 的三张合影打印全部检出脸（面积、中心偏移、
// 综合得分）与最终选中者，便于核对选脸策略的取舍。
@Timeout(Duration(minutes: 20))
library;

import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

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

class _Engine with MattingEngineMixin {}

void main() {
  final repo = Directory.current.path;
  late _Engine engine;

  setUpAll(() async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = _Engine();
    await engine.warmUp();
  });

  tearDownAll(() => engine.disposeMattingEngine());

  test('multi_face subject choice', () async {
    const files = <String>[
      r'C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png',
      r'C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png',
      r'C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png',
    ];
    for (final path in files) {
      final f = File(path);
      if (!f.existsSync()) {
        stdout.writeln('$path missing');
        continue;
      }
      final face = await engine.detectFace(f.readAsBytesSync());
      final name = path.split('\\').last;
      if (face == null) {
        stdout.writeln('$name: NO FACE');
        continue;
      }
      stdout.writeln('$name: chosen '
          'score=${face.confidence.toStringAsFixed(3)} '
          'box=(${face.box.left.toStringAsFixed(0)},'
          '${face.box.top.toStringAsFixed(0)} '
          '${face.box.width.toStringAsFixed(0)}x'
          '${face.box.height.toStringAsFixed(0)}) '
          'headTop=${face.headTopY.toStringAsFixed(0)} '
          'chin=${face.chinY.toStringAsFixed(0)}');
      expect(face.chinY, greaterThan(face.headTopY));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('sanity: golden portraits still detected', () async {
    final dir = Directory('$repo${Platform.pathSeparator}test'
        '${Platform.pathSeparator}golden${Platform.pathSeparator}src');
    var n = 0;
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final face = await engine.detectFace(f.readAsBytesSync());
      stdout.writeln('${f.path.split(Platform.pathSeparator).last}: '
          '${face == null ? "NO FACE" : face.box.toString()}');
      if (face != null) n++;
    }
    expect(n, 8);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
