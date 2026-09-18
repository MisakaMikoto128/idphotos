// G4.7 内存 A/B 台（ml-porting 自用）。
//
// 跑法：flutter test native/bench/mem_bench_test.dart
//
// 用 qa-batch 实测 814.6MB 峰值的同一张 4958×7017 扫描件：
//   A = 新路径 engine.removeBackground（头部预扫 + dart:ui 降采样解码）
//   B = 旧路径 runMattingSync（image 包全分辨率解码）
// 每 20ms 采样一次进程 RSS 取峰值，各跑 5 轮取最小增量（压 GC 噪声）。
// 门禁数字仍以 qa-batch 的 dumpsys 为准，这里只做相对比较。
// 注意：旧路径的测量放在顶层函数里——闭包从测试体里捕获 engine 会把
// 未发送的 Future 一起带进 isolate 消息。
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/matting_worker.dart';
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

int _rssNow() => ProcessInfo.currentRss;

/// 旧路径全跑（该扫描件无前景，契约上抛 MattingException——异常也是
/// 全流程之后才抛的，内存照量，这里吞掉只影响测量不受影响）。
MattingPayload _legacyQuiet(Uint8List bytes, int session) {
  try {
    return runMattingSync(bytes, session);
  } on IdPhotoException {
    return MattingPayload(
        TransferableTypedData.fromList(const <Uint8List>[]),
        TransferableTypedData.fromList(const <Uint8List>[]),
        0,
        0);
  }
}

/// 边跑边采样 RSS，返回峰值与起点的最大增量。
Future<int> _peakRssWhile(Future<void> Function() body) async {
  var peak = 0;
  final base = _rssNow();
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final rss = _rssNow();
    if (rss > peak) peak = rss;
  });
  try {
    await body();
  } finally {
    t.cancel();
  }
  return peak - base;
}

/// 旧路径（全分辨率解码）测量。刻意放顶层：Isolate.run 的闭包只能
/// 捕获 [bytes] / [session]，不能沾到测试体的 engine。
Future<int> _measureLegacyPeak(Uint8List bytes, int session, int rounds) async {
  var best = 1 << 62;
  for (var i = 0; i < rounds; i++) {
    // 预热一轮让上一轮的缓冲被 GC 回收，量的是"单次净增量"。
    await Isolate.run(() => _legacyQuiet(bytes, session));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final peak = await _peakRssWhile(
        () => Isolate.run(() => _legacyQuiet(bytes, session)));
    if (peak < best) best = peak;
  }
  return best;
}

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

  test('A/B: big scan memory + timing', () async {
    const path =
        r'C:\Users\liuyu\Pictures\Online Verification Report of Student Record_LIU YUANLIN_00.jpg';
    final f = File(path);
    if (!f.existsSync()) {
      stdout.writeln('scan file missing, skipped');
      return;
    }
    final bytes = f.readAsBytesSync();
    stdout.writeln('file size = ${bytes.length ~/ 1024} KB');

    // 旧路径的独立会话（与引擎互不干扰）。
    final legacySession = ort
        .createSession('${ort.debugModelDirectory}'
            '${Platform.pathSeparator}modnet_portrait_1024_int8.onnx')
        .address;

    // 预热一轮。
    try {
      final sw = Stopwatch()..start();
      await engine.removeBackground(bytes);
      sw.stop();
      stdout.writeln('new path single run elapsed = ${sw.elapsedMilliseconds} ms'
          '（首跑含编译/预热，仅参考）');
    } on IdPhotoException catch (_) {}

    int? newDims;
    final newPeak = await _peakRssWhile(() async {
      try {
        final r = await engine.removeBackground(bytes);
        newDims = r.width * r.height;
      } on IdPhotoException catch (_) {}
    });
    final oldPeak =
        await _measureLegacyPeak(bytes, legacySession, 3);

    String mb(int v) => (v / 1048576).toStringAsFixed(1);
    stdout.writeln('new path: peak +${mb(newPeak)}MB '
        '(working px = ${newDims ?? "?"})');
    stdout.writeln('old path: peak +${mb(oldPeak)}MB (4958x7017 full res)');
    stdout.writeln(
        'new/old peak ratio = ${(newPeak / oldPeak).toStringAsFixed(2)}');
    if (newDims != null) {
      expect(newDims!, lessThanOrEqualTo(2048 * 1448));
    }
    ort.releaseSession(legacySession);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
