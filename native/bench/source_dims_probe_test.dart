// 坐标链验证（ml-porting 自用）：大图 removeBackground 返回的
// sourceWidth/sourceHeight 必须是原图（摆正后）尺寸，且未降采样时为 null。
// 跑法：flutter test native/bench/source_dims_probe_test.dart
@Timeout(Duration(minutes: 20))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('downsampled image reports source dims; small image reports null',
      () async {
    // 大图 (2880x4982, portrait, 有人脸)。
    final big = File(r'C:\Users\liuyu\Pictures\1 (2).jpg');
    if (big.existsSync()) {
      final r = await engine.removeBackground(big.readAsBytesSync());
      stdout.writeln('big: result=${r.width}x${r.height} '
          'src=${r.srcWidth}x${r.srcHeight} '
          '(fields: ${r.sourceWidth}x${r.sourceHeight})');
      expect(r.width, 1184, reason: '工作分辨率长边 2048');
      expect(r.height, 2048);
      expect(r.sourceWidth, 2880);
      expect(r.sourceHeight, 4982);
      final face = await engine.detectFace(big.readAsBytesSync());
      expect(face, isNotNull, reason: 'portrait 大图必须仍检出人脸');
      // 人脸坐标应在工作分辨率空间内（与 MattingResult 同坐标系）。
      expect(face!.box.right, lessThanOrEqualTo(r.width));
      expect(face.box.bottom, lessThanOrEqualTo(r.height));
      expect(face.chinY, lessThanOrEqualTo(r.height.toDouble()));
    }

    // 小图（黄金集 g01，≤2048）：sourceWidth 必须为 null = 未降采样。
    final small = File('$repo${Platform.pathSeparator}test'
        '${Platform.pathSeparator}golden${Platform.pathSeparator}src'
        '${Platform.pathSeparator}g01.jpg');
    final r2 = await engine.removeBackground(small.readAsBytesSync());
    stdout.writeln('small: result=${r2.width}x${r2.height} '
        'sourceWidth=${r2.sourceWidth} (期望 null)');
    expect(r2.sourceWidth, isNull);
    expect(r2.sourceHeight, isNull);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
