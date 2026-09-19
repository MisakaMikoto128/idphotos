// 双模型抠图档位（db778aa 契约）自测台，ml-porting 自用，不是门禁。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/dual_quality_bench_test.dart
//
// 验证三件事：
//   1. fast（MODNet）/ fine（BiRefNet）两档各跑一张黄金集图，报延迟
//      （fast 含 2 次预热 + 5 次计时；fine 懒加载后 1 次预热 + 3 次计时）；
//   2. 两档各出一张 alpha PNG 到 native/bench/out/，且不是全黑/全白；
//   3. fine 档懒加载失败后引擎不钉死（由 warmUp/重试成法保证，此处只验证
//      两档在同一引擎实例上可先后调用、互不换错会话——若 fine 档内部错用
//      fast 会话，输出会与 fast 档逐位相同，比对即可抓出）。
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

class _Engine with MattingEngineMixin {}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory('$repo${Platform.pathSeparator}native'
      '${Platform.pathSeparator}bench${Platform.pathSeparator}out')
    ..createSync(recursive: true);
  late _Engine engine;

  setUpAll(() async {
    ort.ensureOrtRuntimeLoaded();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = _Engine();
    await engine.warmUp();
    stdout.writeln('fast provider = ${engine.mattingProvider}');
    stdout.writeln('ORT version   = ${ort.ortVersionString()}');
    stdout.writeln('ORT loaded    = ${ort.ortLoadedFrom}');
  });

  tearDownAll(() => engine.disposeMattingEngine());

  Future<({MattingResult r, int ms})> timed(Uint8List bytes,
      MattingQuality q) async {
    final sw = Stopwatch()..start();
    final r = await engine.removeBackground(bytes, quality: q);
    sw.stop();
    return (r: r, ms: sw.elapsedMilliseconds);
  }

  void saveAlpha(MattingResult r, String name) {
    final vis =
        img.Image(width: r.width, height: r.height, numChannels: 1);
    vis.getBytes(order: img.ChannelOrder.red).setAll(0, r.alpha);
    File('${outDir.path}${Platform.pathSeparator}$name.png')
        .writeAsBytesSync(img.encodePng(vis));
  }

  void expectNotDegenerate(Uint8List alpha, String tag) {
    var lo = 0, hi = 0;
    for (final v in alpha) {
      if (v < 16) lo++;
      if (v > 240) hi++;
    }
    final n = alpha.length;
    stdout.writeln('$tag alpha: lo=${(lo / n * 100).toStringAsFixed(1)}% '
        'hi=${(hi / n * 100).toStringAsFixed(1)}%');
    expect(lo, lessThan(n * 0.99), reason: '$tag alpha 几乎全黑');
    expect(hi, lessThan(n * 0.99), reason: '$tag alpha 几乎全白');
  }

  test('fast/fine dual-quality latency + alpha sanity', () async {
    final bytes = File('$repo${Platform.pathSeparator}test'
            '${Platform.pathSeparator}golden${Platform.pathSeparator}src'
            '${Platform.pathSeparator}g01.jpg')
        .readAsBytesSync();

    // fast 档：2 次预热 + 5 次计时。
    for (var i = 0; i < 2; i++) {
      await engine.removeBackground(bytes);
    }
    final fastTimes = <int>[];
    MattingResult? fastResult;
    for (var i = 0; i < 5; i++) {
      final t = await timed(bytes, MattingQuality.fast);
      fastTimes.add(t.ms);
      fastResult = t.r;
    }
    fastTimes.sort();
    stdout.writeln(
        'fast (MODNet)  ms: $fastTimes  median=${fastTimes[2]}');

    // fine 档：首次调用含懒加载（单独计时），之后 1 次预热 + 3 次计时。
    final swLoad = Stopwatch()..start();
    await engine.removeBackground(bytes, quality: MattingQuality.fine);
    swLoad.stop();
    stdout.writeln('fine first call (incl. lazy load): ${swLoad.elapsedMilliseconds} ms');
    stdout.writeln('fine provider = ${engine.fineMattingProvider}');
    final fineTimes = <int>[];
    MattingResult? fineResult;
    for (var i = 0; i < 3; i++) {
      final t = await timed(bytes, MattingQuality.fine);
      fineTimes.add(t.ms);
      fineResult = t.r;
    }
    fineTimes.sort();
    stdout.writeln('fine (BiRefNet) ms: $fineTimes  median=${fineTimes[1]}');

    final fr = fastResult!, nr = fineResult!;
    expect(fr.width, nr.width);
    expect(fr.height, nr.height);
    saveAlpha(fr, 'dual_g01_fast_alpha');
    saveAlpha(nr, 'dual_g01_fine_alpha');
    expectNotDegenerate(fr.alpha, 'fast');
    expectNotDegenerate(nr.alpha, 'fine');

    // 两档若错用同一会话/同一前处理，输出会逐位相同——抓出来。
    var diff = 0;
    for (var i = 0; i < fr.alpha.length; i++) {
      if (fr.alpha[i] != nr.alpha[i]) diff++;
    }
    stdout.writeln('fast vs fine alpha diff pixels: '
        '${(diff / fr.alpha.length * 100).toStringAsFixed(1)}%');
    expect(diff, greaterThan(0), reason: '两档输出逐位相同，疑似档位分流没生效');

    // 换档后 fast 档仍走 fast 会话（fine 常驻不应污染 fast）。
    final again = await timed(bytes, MattingQuality.fast);
    expectNotDegenerate(again.r.alpha, 'fast-after-fine');
    stdout.writeln('fast after fine: ${again.ms} ms');
  });
}
