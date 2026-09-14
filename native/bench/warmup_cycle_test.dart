// Dev-only self-test for the ORT session leak fix (`out/REVIEW_G2.md` #8).
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/warmup_cycle_test.dart
//
// 只做一件事：反复 warmUp → removeBackground → detectFace → dispose，
// 确认每一轮都能正常推理（没有 use-after-free）、结果稳定（没有悄悄用旧
// session），并打印宿主进程 RSS 走势供人工核对没有单调爬升。
@Timeout(Duration(minutes: 10))
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

  test('warmUp -> dispose -> warmUp loop stays usable, no crash', () async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    final bytes =
        File('$repo/test/golden/src/g01.jpg').readAsBytesSync();

    const cycles = 6;
    for (var i = 0; i < cycles; i++) {
      final engine = _Engine();
      await engine.warmUp();
      expect(engine.mattingProvider, isNotNull, reason: 'cycle $i warmUp');

      final result = await engine.removeBackground(bytes);
      var fg = 0;
      for (final a in result.alpha) {
        if (a >= 128) fg++;
      }
      final ratio = fg / result.alpha.length;
      expect(ratio, greaterThan(0.05), reason: 'cycle $i mask looks empty');

      final face = await engine.detectFace(bytes);
      expect(face, isNotNull, reason: 'cycle $i face');

      engine.disposeMattingEngine();

      // 再 warm 一次同一个（已 dispose 的）engine 实例，确认幂等重建没有
      // 复用已释放的 session 地址。
      await engine.warmUp();
      final result2 = await engine.removeBackground(bytes);
      expect(result2.alpha.length, result.alpha.length,
          reason: 'cycle $i re-warm result shape');
      engine.disposeMattingEngine();

      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      stdout.writeln('cycle $i ok, rss=${rss}MB');
    }
  });
}
