// ml-porting 自用：瞳孔估计调参探针。直接调**生产函数** estimatePupilRoll，
// 打出两只眼窗内的全部候选与拒绝原因（见 iris_roll.dart 的 _findPupil）。
// 灰度平面走生产解码路径 decodeToRgb（同一 maxEdge/targetEdge），
// 种子用 FaceInfo.landmarks（已是工作分辨率坐标）。
//
// 跑法：flutter test native/bench/iris_roll_debug_test.dart
@Timeout(Duration(minutes: 40))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _Engine();

  test('瞳孔候选明细', () async {
    await engine.warmUp();
    final List<String> targets = <String>[
      r'C:\Users\liuyu\Pictures\2.jpg',
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      r'C:\Users\liuyu\Pictures\报名照片.jpg',
      r'C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg',
      for (var i = 1; i <= 8; i++) 'test/golden/src/g0$i.jpg',
    ];
    // 可选：native/bench/out/dbg_targets.txt 每行一个绝对路径，优先使用。
    final File extra = File('native/bench/out/dbg_targets.txt');
    if (extra.existsSync()) {
      targets
        ..clear()
        ..addAll(extra
            .readAsLinesSync()
            .map((String l) => l.trim())
            .where((String l) => l.isNotEmpty));
    }
    for (final path in targets) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = file.readAsBytesSync();
      final FaceInfo? face = await engine.detectFace(bytes);
      if (face == null) {
        // ignore: avoid_print
        print('[dbg] $path -> no face');
        continue;
      }
      final DecodedImage im;
      try {
        im = decodeToRgb(bytes,
            maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      } catch (e) {
        // ignore: avoid_print
        print('[dbg] $path -> decode failed $e');
        continue;
      }
      final Uint8List gray = grayPlaneFromRgb(im.rgb, im.width, im.height);
      final Float32List lm = face.landmarks!;
      final List<String> trace = <String>[];
      final PupilRoll pr = estimatePupilRoll(
        gray: gray,
        width: im.width,
        height: im.height,
        eyeAx: lm[0],
        eyeAy: lm[1],
        eyeBx: lm[2],
        eyeBy: lm[3],
        trace: trace,
      );
      for (final t in trace) {
        // ignore: avoid_print
        print('[trc] ${file.uri.pathSegments.last} $t');
      }
      // ignore: avoid_print
      print('[dbg] ${file.uri.pathSegments.last} work=${im.width}x${im.height} '
          'faceRoll=${face.rollDeg.toStringAsFixed(2)} '
          'src=${face.rollSource.name} -> $pr');
      if (pr.available) {
        // ignore: avoid_print
        print('[dbg]    L=${pr.left}');
        // ignore: avoid_print
        print('[dbg]    R=${pr.right}');
      }
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 40)));
}
