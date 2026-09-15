// ml-porting 自用：ORT 会话/arena 的进程内存足迹探针（Windows host）。
//
// 跑法：flutter test native/bench/ort_footprint_probe_test.dart
//
// 回答三个问题：
//   1. 建会话（模型加载+图优化）吃多少；
//   2. 第一次推理（arena 扩到峰值）涨多少，之后是否只增不减；
//   3. 512 抠图 + 640 检脸交替跑 10 轮，足迹是否继续爬。
// Windows 上没有 dumpsys，用 ProcessInfo.currentRss + GlobalMemoryStatus
// 式的 RSS 采样近似（相对量足够回答上面三问）。
@Timeout(Duration(minutes: 15))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/matting/ort_runtime.dart' show kMattingInputSize;

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

int _rss() => ProcessInfo.currentRss;

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  ort.debugModelDirectory =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';

  test('ort footprint probe', () async {
    final m0 = _rss();
    final mat = ort.createSession(
        '${ort.debugModelDirectory}${Platform.pathSeparator}'
        'modnet_portrait_int8.onnx');
    final face = ort.createSession(
        '${ort.debugModelDirectory}${Platform.pathSeparator}'
        'face_yunet_2023mar.onnx');
    final m1 = _rss();
    stdout.writeln('sessions created: +${(m1 - m0) ~/ 1048576}MB '
        '(provider matting=${mat.provider} face=${face.provider})');

    final bytes = File(
            '$repo${Platform.pathSeparator}test${Platform.pathSeparator}golden'
            '${Platform.pathSeparator}src${Platform.pathSeparator}g01.jpg')
        .readAsBytesSync();
    final image = decodeToRgb(bytes);

    int inferMat() {
      final input =
          modnetInput(image.rgb, image.width, image.height, kMattingInputSize);
      final outputs = ort.runFloatInput(mat.address, input,
          <int>[1, 3, kMattingInputSize, kMattingInputSize], const <String>[]);
      var sum = 0;
      for (final o in outputs) {
        final v = o?.value;
        if (v is List) {
          sum += v.length;
        }
        o?.release();
      }
      return sum;
    }

    final m2 = _rss();
    inferMat();
    final m3 = _rss();
    stdout.writeln('first 512 inference: +${(m3 - m2) ~/ 1048576}MB');
    for (var i = 0; i < 10; i++) {
      inferMat();
      if (i == 4) {
        stdout.writeln('after 5 more: +${(_rss() - m3) ~/ 1048576}MB');
      }
    }
    final m4 = _rss();
    stdout.writeln('after 10 more: +${(m4 - m3) ~/ 1048576}MB');
    stdout.writeln('total after all: +${(m4 - m0) ~/ 1048576}MB');
    ort.releaseSession(mat.address);
    ort.releaseSession(face.address);
  });
}
