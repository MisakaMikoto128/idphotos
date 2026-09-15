// 一次性探针：打印合影里 NMS 后的全部检出脸（选脸策略调参用）。
// 跑法：flutter test native/bench/face_all_probe_test.dart
@Timeout(Duration(minutes: 20))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/matting/image_ops.dart';

import 'package:onnxruntime/onnxruntime.dart' show OrtValue;
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/matting/yunet_decoder.dart';

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

Future<int?> _faceSession() async {
  ort.debugModelDirectory = '${Directory.current.path}'
      '${Platform.pathSeparator}assets${Platform.pathSeparator}models';
  final h = ort.createSession(
      '${ort.debugModelDirectory}${Platform.pathSeparator}'
      'face_yunet_2023mar.onnx',
      threads: 2);
  return h.address;
}

List<OrtValue?> _run(int session, Float32List input) => ort.runFloatInput(
    session, input, const <int>[1, 3, ort.kFaceInputSize, ort.kFaceInputSize],
    kYunetOutputNames);

List<double> _flatten(dynamic value) {
  final out = <double>[];
  void walk(dynamic v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }
  walk(value);
  return out;
}

void main() {
  test('all faces in group photos', () async {
    _preloadHostOnnxRuntime();
    final session = (await _faceSession())!;
    const files = <String>[
      r'C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png',
      r'C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png',
      r'C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png',
    ];
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      final image = decodeToRgb(bytes);
      final input = yunetInput(
          image.rgb, image.width, image.height, ort.kFaceInputSize);
      final outputs = _run(session, input.data);
      final raw = <RawFace>[];
      try {
        for (var i = 0; i < kYunetStrides.length; i++) {
          raw.addAll(decodeStride(
            kYunetStrides[i],
            ort.kFaceInputSize,
            _flatten(outputs[i]?.value),
            _flatten(outputs[3 + i]?.value),
            _flatten(outputs[6 + i]?.value),
            _flatten(outputs[9 + i]?.value),
          ));
        }
      } finally {
        for (final o in outputs) {
          o?.release();
        }
      }
      final kept = nonMaxSuppression(raw);
      stdout.writeln('${path.split(Platform.pathSeparator).last} '
          '(${image.width}x${image.height}) center='
          '(${(image.width / 2).toStringAsFixed(0)},'
          '${(image.height / 2).toStringAsFixed(0)})');
      final sorted = List<RawFace>.from(kept)
        ..sort((a, b) => b.area.compareTo(a.area));
      final halfDiag =
          math.sqrt(image.width * image.width + image.height * image.height) /
              2;
      for (final f in sorted) {
        final cx = f.x + f.w / 2;
        final cy = f.y + f.h / 2;
        final distNorm = math.sqrt(
                math.pow(cx - image.width / 2, 2) +
                    math.pow(cy - image.height / 2, 2)) /
            halfDiag;
        final areaRatio = f.area / (image.width * image.height);
        stdout.writeln('  score=${f.score.toStringAsFixed(3)} '
            'box=(${f.x.toStringAsFixed(0)},${f.y.toStringAsFixed(0)} '
            '${f.w.toStringAsFixed(0)}x${f.h.toStringAsFixed(0)}) '
            'center=(${cx.toStringAsFixed(0)},${cy.toStringAsFixed(0)}) '
            'areaRatio=${areaRatio.toStringAsFixed(4)} '
            'distNorm=${distNorm.toStringAsFixed(3)} '
            'score0.5=${(f.area * (1 - 0.5 * distNorm)).toStringAsFixed(0)} '
            'passRatio=${areaRatio >= kMinFaceAreaRatio}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
