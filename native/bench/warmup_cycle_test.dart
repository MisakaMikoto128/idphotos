// Dev-only self-test for the ORT session leak fix (`out/REVIEW_G2.md` #8)
// and the env-per-process invariant (`out/REVIEW_G3.md` X5/B1).
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/warmup_cycle_test.dart
//
// 两件事：
//   1. 反复 warmUp → removeBackground → detectFace → dispose，确认每轮
//      推理正常、结果稳定，打印 RSS 供人工核对没有单调爬升；
//   2. warmUp **失败重试**循环（坏模型字节 → 好模型），断言工厂 isolate
//      报告的 OrtEnv native 地址全程不变——env 只在第一次被触碰时创建，
//      重试不再新增（修复前：每次 _loadModels 泄漏一个 native env）。
@Timeout(Duration(minutes: 10))
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
  final goodDir =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';

  test('warmUp -> dispose -> warmUp loop stays usable, no crash', () async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory = goodDir;
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

      await engine.disposeMattingEngine();

      // 再 warm 一次同一个（已 dispose 的）engine 实例，确认幂等重建没有
      // 复用已释放的 session 地址。
      await engine.warmUp();
      final result2 = await engine.removeBackground(bytes);
      expect(result2.alpha.length, result.alpha.length,
          reason: 'cycle $i re-warm result shape');
      await engine.disposeMattingEngine();

      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      stdout.writeln('cycle $i ok, rss=${rss}MB');
    }
  });

  test('warmUp fail -> retry reuses one env (X5/B1 invariant)', () async {
    _preloadHostOnnxRuntime();
    final bytes =
        File('$repo/test/golden/src/g01.jpg').readAsBytesSync();

    // 坏模型目录：同名文件但内容是垃圾字节。createSession 会把 env 单例
    // 拉起来（fromBuffer 的参数求值即 CreateEnv），然后 fromBuffer 才失败
    // ——这正是修复前"每次 _loadModels 泄漏一个 env"的路径。
    final badDir =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'muzhao_bad_models';
    Directory(badDir).createSync(recursive: true);
    for (final name in const <String>[
      'modnet_portrait_1024_int8.onnx',
      'face_yunet_2023mar.onnx',
    ]) {
      File('$badDir${Platform.pathSeparator}$name')
          .writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    }

    var engine = _Engine();
    var envAddress = 0;
    var lastEnv = 0;
    try {
      // 每个 round 用新 engine 实例（模拟一次 App 启动），round 内做
      // 失败 → 失败 → 成功：生产场景的 warmUp 重试正是这个序列。
      for (var round = 0; round < 3; round++) {
        ort.debugModelDirectory = badDir;
        await expectLater(
          engine.warmUp(),
          throwsA(isA<MattingException>()),
          reason: 'round $round fail#1 must fail on garbage model',
        );
        final env1 = engine.debugEnvAddress;
        expect(env1, isNotNull,
            reason: 'round $round: env should exist after failed warmUp');
        if (envAddress == 0) {
          envAddress = env1!;
        } else {
          expect(env1, envAddress,
              reason: 'round $round: failed warmUp must not create a new env');
        }

        await expectLater(
          engine.warmUp(),
          throwsA(isA<MattingException>()),
          reason: 'round $round fail#2 must fail on garbage model',
        );
        expect(engine.debugEnvAddress, envAddress,
            reason: 'round $round: fail#2 must not create a new env');

        ort.debugModelDirectory = goodDir;
        await engine.warmUp();
        expect(engine.debugEnvAddress, envAddress,
            reason: 'round $round: retry must reuse the same env');

        final result = await engine.removeBackground(bytes);
        var fg = 0;
        for (final a in result.alpha) {
          if (a >= 128) fg++;
        }
        expect(fg / result.alpha.length, greaterThan(0.05),
            reason: 'round $round: inference works after retry');
        await engine.disposeMattingEngine();
        lastEnv = envAddress;
        engine = _Engine();
        envAddress = 0;
      }
      final rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      stdout.writeln('fail/retry invariant ok, last env=0x${lastEnv.toRadixString(16)}, rss=${rss}MB');
    } finally {
      ort.debugModelDirectory = goodDir;
      await engine.disposeMattingEngine();
    }
  });
}
