/// roll_repro step3: YuNet 估角尺度敏感性——把用户两张源图缩到不同尺寸再检脸。
/// 运行：flutter test lib/core/imaging/dev_roll_scale.dart
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
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _Engine();

  test('估角尺度敏感性', () async {
    await engine.warmUp();
    for (final e in <String, String>{
      'p1': r'C:/Users/liuyu/Pictures/1 (2).jpg',
      'p2': r'C:/Users/liuyu/Pictures/2.jpg',
    }.entries) {
      final Uint8List src = File(e.value).readAsBytesSync();
      final img.Image base = img.decodeJpg(src)!;
      for (final double f in const [1.0, 0.75, 0.5, 0.35, 0.25, 0.15]) {
        final img.Image scaled = f == 1.0
            ? base
            : img.copyResize(base, width: (base.width * f).round());
        final Uint8List bytes =
            Uint8List.fromList(img.encodeJpg(scaled, quality: 95));
        final FaceInfo? face = await engine.detectFace(bytes);
        if (face == null) {
          // ignore: avoid_print
          print('[scale] ${e.key} f=$f size=${scaled.width}x${scaled.height} '
              'NO FACE');
          continue;
        }
        // ignore: avoid_print
        print('[scale] ${e.key} f=$f size=${scaled.width}x${scaled.height} '
            'roll=${face.rollDeg.toStringAsFixed(3)} '
            'conf=${face.confidence.toStringAsFixed(3)} '
            'boxW=${face.box.width.toStringAsFixed(1)} '
            'eyeY=${((face.chinY - (face.chinY - face.headTopY) / 3.5 * 1.61)).toStringAsFixed(1)}');
      }
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
