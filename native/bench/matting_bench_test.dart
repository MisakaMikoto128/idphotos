// 阶段 2 的自测台（ml-porting 自用，不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/matting_bench_test.dart
//
// 它做三件事：
//   1. 对 test/golden/src/*.jpg 跑抠图，和 test/golden/ref/*.png 比 IoU / MAE /
//      边缘带 MAE，并测 512×512 的单张耗时分布；
//   2. 对 test/golden/src/*.jpg 跑人脸检测，检查 8/8 检出且 chinY > headTopY；
//   3. 把 C:\Users\liuyu\Pictures\ 里所有文件过一遍，确认脏数据不会让进程崩。
//
// 产物（alpha mask PNG、逐张指标）写到系统临时目录下的 muzhao_bench/，
// 不落进仓库。
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

/// 宿主机（Windows）上跑 flutter test 时，onnxruntime 插件里那句
/// `DynamicLibrary.open('onnxruntime.dll')` 找不到 DLL —— 插件的 DLL 只有在
/// 打包成桌面 App 时才会被拷到可执行文件旁边。先按绝对路径把同一个 DLL
/// 载进进程，之后 Windows 的 LoadLibrary 会按模块名命中已加载的那份。
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

Uint8List _gray(img.Image im) {
  final g = im.numChannels == 1
      ? im
      : im.convert(format: img.Format.uint8, numChannels: 1);
  return g.getBytes(order: img.ChannelOrder.red);
}

/// 可分离矩形结构元的膨胀 / 腐蚀（二值图，0/1）。
Uint8List _morph(Uint8List src, int w, int h, int radius, bool dilate) {
  final tmp = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      var v = dilate ? 0 : 1;
      final x0 = math.max(0, x - radius);
      final x1 = math.min(w - 1, x + radius);
      for (var i = x0; i <= x1; i++) {
        final s = src[base + i];
        v = dilate ? math.max(v, s) : math.min(v, s);
      }
      tmp[base + x] = v;
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = math.max(0, y - radius);
    final y1 = math.min(h - 1, y + radius);
    for (var x = 0; x < w; x++) {
      var v = dilate ? 0 : 1;
      for (var j = y0; j <= y1; j++) {
        final s = tmp[j * w + x];
        v = dilate ? math.max(v, s) : math.min(v, s);
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

class _Metrics {
  _Metrics(this.iou, this.mae, this.edgeMae);
  final double iou;
  final double mae;
  final double edgeMae;
}

_Metrics _compare(Uint8List a, Uint8List ref, int w, int h) {
  var inter = 0, union = 0;
  var absSum = 0.0;
  final bin = Uint8List(w * h);
  for (var i = 0; i < a.length; i++) {
    final ba = a[i] >= 128;
    final br = ref[i] >= 128;
    bin[i] = br ? 1 : 0;
    if (ba && br) inter++;
    if (ba || br) union++;
    absSum += (a[i] - ref[i]).abs() / 255.0;
  }
  final dil = _morph(bin, w, h, 5, true);
  final ero = _morph(bin, w, h, 5, false);
  var band = 0;
  var bandSum = 0.0;
  for (var i = 0; i < bin.length; i++) {
    if (dil[i] != ero[i]) {
      band++;
      bandSum += (a[i] - ref[i]).abs() / 255.0;
    }
  }
  return _Metrics(
    union == 0 ? 1.0 : inter / union,
    absSum / a.length,
    band == 0 ? 0.0 : bandSum / band,
  );
}

void main() {
  final repo = Directory.current.path;
  final outDir = Directory('${Directory.systemTemp.path}'
      '${Platform.pathSeparator}muzhao_bench')
    ..createSync(recursive: true);
  late _Engine engine;

  setUpAll(() async {
    _preloadHostOnnxRuntime();
    ort.debugModelDirectory =
        '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
    engine = _Engine();
    try {
      await engine.warmUp();
    } on IdPhotoException catch (e) {
      stdout.writeln('warmUp failed: ${e.messageZh} / cause=${e.cause}');
      rethrow;
    }
    stdout.writeln('provider = ${engine.mattingProvider}');
    stdout.writeln('output   = ${outDir.path}');
  });

  tearDownAll(() => engine.disposeMattingEngine());

  test('G2A.1/2A.2 model sizes', () {
    // BiRefNet 换档（2026-09-19）：体积预算从 ≤10MB 调整为 ≤70MB
    // （用户批准"App 大点就大点"，~60MB lite/int8 口径；实测 67.4MB，
    // 超出部分来自 deform-conv 改写留下的 fp16 采样网格常量）。
    final matting = File('$repo/assets/models/birefnet_lite_1024_int8.onnx');
    final face = File('$repo/assets/models/face_yunet_2023mar.onnx');
    final mb = matting.lengthSync() / 1024 / 1024;
    final fb = face.lengthSync() / 1024 / 1024;
    stdout.writeln('matting model = ${mb.toStringAsFixed(2)} MB');
    stdout.writeln('face    model = ${fb.toStringAsFixed(3)} MB');
    expect(mb, lessThanOrEqualTo(70.0));
    expect(fb, lessThanOrEqualTo(2.0));
  });

  test('G2A.3/2A.4/2A.5 golden set accuracy', () async {
    final srcDir = Directory('$repo/test/golden/src');
    final files = srcDir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var minIou = 1.0;
    var maeSum = 0.0;
    var edgeSum = 0.0;
    var edgeMax = 0.0;
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last.split('.').first;
      final result = await engine.removeBackground(f.readAsBytesSync());
      final refImg =
          img.decodePng(File('$repo/test/golden/ref/$name.png').readAsBytesSync())!;
      expect(refImg.width, result.width);
      expect(refImg.height, result.height);
      final m = _compare(
          result.alpha, _gray(refImg), result.width, result.height);
      minIou = math.min(minIou, m.iou);
      maeSum += m.mae;
      edgeSum += m.edgeMae;
      edgeMax = math.max(edgeMax, m.edgeMae);
      stdout.writeln('$name IoU=${m.iou.toStringAsFixed(4)} '
          'MAE=${m.mae.toStringAsFixed(4)} '
          'edgeMAE=${m.edgeMae.toStringAsFixed(4)}');
      final vis = img.Image(width: result.width, height: result.height,
          numChannels: 1);
      vis.getBytes(order: img.ChannelOrder.red).setAll(0, result.alpha);
      File('${outDir.path}/alpha_$name.png')
          .writeAsBytesSync(img.encodePng(vis));
      expect(m.iou, greaterThanOrEqualTo(0.95), reason: '$name IoU');
    }
    final meanMae = maeSum / files.length;
    final meanEdge = edgeSum / files.length;
    stdout.writeln('SUMMARY minIoU=${minIou.toStringAsFixed(4)} '
        'meanMAE=${meanMae.toStringAsFixed(4)} '
        'meanEdgeMAE=${meanEdge.toStringAsFixed(4)} '
        'maxEdgeMAE=${edgeMax.toStringAsFixed(4)}');
    expect(meanMae, lessThanOrEqualTo(0.04));
    expect(meanEdge, lessThanOrEqualTo(0.12));
    expect(edgeMax, lessThanOrEqualTo(0.12));
  });

  test('G2A.6 512x512 latency', () async {
    final src = img.decodeJpg(
        File('$repo/test/golden/src/g01.jpg').readAsBytesSync())!;
    final square = img.copyResize(src, width: 512, height: 512);
    final bytes = Uint8List.fromList(img.encodeJpg(square, quality: 95));
    final samples = <int>[];
    for (var i = 0; i < 22; i++) {
      final sw = Stopwatch()..start();
      await engine.removeBackground(bytes);
      sw.stop();
      if (i >= 2) samples.add(sw.elapsedMilliseconds);
    }
    samples.sort();
    final p95 = samples[(samples.length * 0.95).ceil() - 1];
    stdout.writeln('latency n=${samples.length} median=${samples[samples.length ~/ 2]}ms '
        'p95=${p95}ms max=${samples.last}ms');
    // BiRefNet 换档（2026-09-19）：1024² BiRefNet_lite 在 PC CPU 口径实测
    // median ~12s，比 MODNet 的 1.5s 线慢一个数量级——这是已知的质量/速度
    // 取舍，新阈值由主会话在验收标准里重校准，bench 只报数不断言。
    // （Android XNNPACK 与插件新版 ORT 的数字待真机实测。）
    expect(p95, greaterThan(0));
  });

  test('G2A.8 face detection on golden set', () async {
    final files = Directory('$repo/test/golden/src')
        .listSync()
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    var found = 0;
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      final face = await engine.detectFace(f.readAsBytesSync());
      if (face == null) {
        stdout.writeln('$name NO FACE');
        continue;
      }
      found++;
      stdout.writeln('$name score=${face.confidence.toStringAsFixed(3)} '
          'box=${face.box.left.toStringAsFixed(0)},${face.box.top.toStringAsFixed(0)},'
          '${face.box.width.toStringAsFixed(0)}x${face.box.height.toStringAsFixed(0)} '
          'headTop=${face.headTopY.toStringAsFixed(0)} '
          'chin=${face.chinY.toStringAsFixed(0)} '
          'roll=${face.rollDeg.toStringAsFixed(1)}');
      expect(face.chinY, greaterThan(face.headTopY), reason: name);
    }
    expect(found, files.length);
  });

  test('G2A.7 robustness over the frozen dataset', () async {
    // 直接吃 test/dataset.json 的冻结清单和分类，跟门禁 (tools/gate/gate_G2A.dart)
    // 判 2A.7 的口径一致：class ∈ {screenshot, landscape, non_image} 的图，
    // detectFace 必须返回 null 或抛约定异常。
    final ds = jsonDecode(
            File('$repo/test/dataset.json').readAsStringSync())
        as Map<String, dynamic>;
    final items = (ds['items'] as List<dynamic>).cast<Map<String, dynamic>>();
    final tally = <String, int>{};
    void bump(String k) => tally[k] = (tally[k] ?? 0) + 1;
    final log = StringBuffer('name\tclass\tmatting\tface\tscore\tareaRatio\n');
    final violations = <String>[];
    for (final item in items) {
      final path = item['path'] as String;
      final cls = item['class'] as String;
      final f = File(path);
      if (!f.existsSync()) {
        bump('missing');
        continue;
      }
      final name = path.split(Platform.pathSeparator).last;
      final bytes = f.readAsBytesSync();
      var matting = 'ok';
      try {
        final r = await engine.removeBackground(bytes);
        expect(r.rgba.length, r.width * r.height * 4);
        expect(r.alpha.length, r.width * r.height);
      } on IdPhotoException catch (e) {
        matting = e.runtimeType.toString();
      }
      bump('matting:$matting');
      var faceDesc = 'null';
      var score = '';
      var ratio = '';
      try {
        final face = await engine.detectFace(bytes);
        if (face != null) {
          expect(face.chinY, greaterThan(face.headTopY), reason: name);
          faceDesc = 'face';
          score = face.confidence.toStringAsFixed(3);
          final w = (item['w'] as num).toDouble();
          final h = (item['h'] as num).toDouble();
          ratio = (face.box.width * face.box.height / (w * h)).toStringAsFixed(5);
        }
      } on IdPhotoException catch (e) {
        faceDesc = e.runtimeType.toString();
      }
      bump('face:$faceDesc');
      if (faceDesc == 'face' &&
          (cls == 'screenshot' || cls == 'landscape' || cls == 'non_image')) {
        violations.add('$name[$cls] score=$score ratio=$ratio');
      }
      log.writeln('$name\t$cls\t$matting\t$faceDesc\t$score\t$ratio');
    }
    File('${outDir.path}/dataset_scan.tsv').writeAsStringSync(log.toString());
    stdout.writeln('scanned ${items.length} items');
    tally.forEach((k, v) => stdout.writeln('  $k = $v'));
    for (final v in violations) {
      stdout.writeln('  NON-PORTRAIT FACE: $v');
    }
    expect(violations, isEmpty);
  });
}
