// ③ QDQ 全量化 A/B 精度探针（ml-porting 自用，不是门禁）。
//
// 主会话 2026-09-19 授权口径：QDQ 的价值不在 PC 提速，在 Android 能不能跑；
// 精度把关 = 黄金集 8 张全量 IoU + 红底发丝裁片对比图，数字和图都进报告。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/qdq_ab_test.dart
//
// 单进程两阶段：先现役模型（assets/models）跑 8 张，dispose 后切
// speed_ab/models_qdq_smoke 再跑 8 张。debugModelDirectory 在宿主 isolate
// 读取（resolveModelPath），阶段间切换安全；EP 钉死 cpu 消变量。
//
// 产物（native/bench/out/speed_ab/qdq_ab/）：
//   red_{name}_{cur,qdq}.png   整图红底合成
//   hair_{name}_{ref,cur,qdq}.png  发丝裁片（窗口由 ref 边缘带顶簇决定，三图同窗）
//   hair_{name}_row.png        ref|cur|qdq 横向拼接（白缝分隔）
//   qdq_ab_report.txt          逐张 IoU/MAE/edgeMAE 与差值 + 峰值 RSS
@Timeout(Duration(minutes: 90))
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

class _Engine with MattingEngineMixin {}

class _Pass {
  _Pass(this.alpha, this.width, this.height);
  final Uint8List alpha;
  final int width;
  final int height;
}

Uint8List _gray(img.Image im) {
  final g = im.numChannels == 1
      ? im
      : im.convert(format: img.Format.uint8, numChannels: 1);
  return g.getBytes(order: img.ChannelOrder.red);
}

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

/// 红底合成：fg.rgb*a + 红*(1-a)。
img.Image _compositeRed(Uint8List rgba, Uint8List alpha, int w, int h) {
  final out = img.Image(width: w, height: h, numChannels: 3);
  final px = out.getBytes(order: img.ChannelOrder.rgb);
  for (var i = 0; i < w * h; i++) {
    final a = alpha[i] / 255.0;
    px[i * 3] = (rgba[i * 4] * a + 255 * (1 - a)).round();
    px[i * 3 + 1] = (rgba[i * 4 + 1] * a).round();
    px[i * 3 + 2] = (rgba[i * 4 + 2] * a).round();
  }
  return out;
}

/// 发丝裁窗：ref 二值边缘带（dilate^erode，r=5）里 y 最小的 15% 像素的
/// 外接框，向外扩 40px，边长封顶 512。三图（ref/cur/qdq）共用同一窗口。
({int x, int y, int w, int h}) _hairWindow(Uint8List ref, int w, int h) {
  final bin = Uint8List(w * h);
  for (var i = 0; i < ref.length; i++) {
    bin[i] = ref[i] >= 128 ? 1 : 0;
  }
  final dil = _morph(bin, w, h, 5, true);
  final ero = _morph(bin, w, h, 5, false);
  final ys = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (dil[y * w + x] != ero[y * w + x]) ys.add(y);
    }
  }
  if (ys.isEmpty) {
    return (x: 0, y: 0, w: math.min(w, 512), h: math.min(h, 512));
  }
  ys.sort();
  final cut = ys[math.max(0, (ys.length * 0.15).floor() - 1)];
  var x0 = w, x1 = 0, y0 = h, y1 = 0;
  for (var y = 0; y <= cut && y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (dil[y * w + x] != ero[y * w + x]) {
        x0 = math.min(x0, x);
        x1 = math.max(x1, x);
        y0 = math.min(y0, y);
        y1 = math.max(y1, y);
      }
    }
  }
  const margin = 40;
  x0 = math.max(0, x0 - margin);
  y0 = math.max(0, y0 - margin);
  x1 = math.min(w - 1, x1 + margin);
  y1 = math.min(h - 1, y1 + margin);
  var cw = x1 - x0 + 1, ch = y1 - y0 + 1;
  if (cw > 512) {
    x0 += (cw - 512) ~/ 2;
    cw = 512;
  }
  if (ch > 512) {
    y0 += (ch - 512) ~/ 2;
    ch = 512;
  }
  return (x: x0, y: y0, w: cw, h: ch);
}

img.Image _crop(img.Image src, ({int x, int y, int w, int h}) r) =>
    img.copyCrop(src, x: r.x, y: r.y, width: r.w, height: r.h);

img.Image _stitchRow(List<img.Image> parts) {
  const sep = 4;
  final w = parts.fold<int>(0, (s, p) => s + p.width) + sep * (parts.length - 1);
  final h = parts.fold<int>(0, (s, p) => math.max(s, p.height));
  final out = img.Image(width: w, height: h, numChannels: 3);
  img.fill(out, color: img.ColorRgb8(255, 255, 255));
  var x = 0;
  for (final p in parts) {
    img.compositeImage(out, p, dstX: x);
    x += p.width + sep;
  }
  return out;
}

Future<Map<String, _Pass>> _runPass(String modelDir) async {
  ort.debugModelDirectory = modelDir;
  final engine = _Engine();
  await engine.warmUp();
  final out = <String, _Pass>{};
  try {
    final files = Directory('test/golden/src').listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last.split('.').first;
      final r = await engine.removeBackground(f.readAsBytesSync());
      out[name] = _Pass(r.alpha, r.width, r.height);
      stdout.writeln('  [$modelDir] $name done');
    }
  } finally {
    await engine.disposeMattingEngine();
  }
  return out;
}

void main() {
  setUpAll(() {
    ort.debugForceEp = 'cpu'; // Windows 官方包只有 CPU EP，钉死消变量
    ort.ensureOrtRuntimeLoaded();
    stdout.writeln('ORT version = ${ort.ortVersionString()} '
        'from ${ort.ortLoadedFrom}');
  });

  test('QDQ vs current: golden IoU + red hair crops', () async {
    final sep = Platform.pathSeparator;
    final outDir = Directory('native${sep}bench${sep}out${sep}speed_ab${sep}qdq_ab')
      ..createSync(recursive: true);
    final report = StringBuffer();
    void log(String s) {
      stdout.writeln(s);
      report.writeln(s);
    }

    log('ORT ${ort.ortVersionString()} from ${ort.ortLoadedFrom}');
    final curDir = '${Directory.current.path}${sep}assets${sep}models';
    final qdqDir = '${Directory.current.path}${sep}native${sep}bench${sep}out'
        '${sep}speed_ab${sep}models_qdq_smoke';

    final rssBase = ProcessInfo.maxRss ~/ (1024 * 1024);
    final cur = await _runPass(curDir);
    final rssCur = ProcessInfo.maxRss ~/ (1024 * 1024);
    final qdq = await _runPass(qdqDir);
    final rssQdq = ProcessInfo.maxRss ~/ (1024 * 1024);

    var minDelta = 1.0, maxDelta = -1.0;
    for (final name in cur.keys) {
      final c = cur[name]!;
      final q = qdq[name]!;
      final refImg = img.decodePng(
          File('test${sep}golden${sep}ref$sep$name.png').readAsBytesSync())!;
      final ref = _gray(refImg);
      final mc = _compare(c.alpha, ref, c.width, c.height);
      final mq = _compare(q.alpha, ref, q.width, q.height);
      final dIou = mq.iou - mc.iou;
      minDelta = math.min(minDelta, dIou);
      maxDelta = math.max(maxDelta, dIou);
      log('$name cur IoU=${mc.iou.toStringAsFixed(4)} '
          'MAE=${mc.mae.toStringAsFixed(4)} '
          'edgeMAE=${mc.edgeMae.toStringAsFixed(4)} | '
          'qdq IoU=${mq.iou.toStringAsFixed(4)} '
          'MAE=${mq.mae.toStringAsFixed(4)} '
          'edgeMAE=${mq.edgeMae.toStringAsFixed(4)} | '
          'dIoU=${dIou.toStringAsFixed(4)}');

      // 红底合成 + 发丝裁片（ref 用同窗口的 ref-alpha 合成做对照基准）。
      final srcBytes = File('test${sep}golden${sep}src$sep$name.jpg')
          .readAsBytesSync();
      var srcImg = img.decodeJpg(srcBytes)!;
      if (srcImg.width != c.width || srcImg.height != c.height) {
        // 长边 >2048 的输入会被引擎降采样（黄金集当前都 ≤2048，双保险）。
        srcImg = img.copyResize(srcImg, width: c.width, height: c.height);
      }
      final rgba = Uint8List(c.width * c.height * 4);
      final sp = srcImg.getBytes(order: img.ChannelOrder.rgb);
      for (var i = 0; i < c.width * c.height; i++) {
        rgba[i * 4] = sp[i * 3];
        rgba[i * 4 + 1] = sp[i * 3 + 1];
        rgba[i * 4 + 2] = sp[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
      }
      final redCur = _compositeRed(rgba, c.alpha, c.width, c.height);
      final redQdq = _compositeRed(rgba, q.alpha, c.width, c.height);
      final redRef = _compositeRed(rgba, ref, c.width, c.height);
      File('${outDir.path}${sep}red_${name}_cur.png')
          .writeAsBytesSync(img.encodePng(redCur));
      File('${outDir.path}${sep}red_${name}_qdq.png')
          .writeAsBytesSync(img.encodePng(redQdq));

      final win = _hairWindow(ref, c.width, c.height);
      final cr = _crop(redRef, win);
      final cc = _crop(redCur, win);
      final cq = _crop(redQdq, win);
      File('${outDir.path}${sep}hair_${name}_ref.png')
          .writeAsBytesSync(img.encodePng(cr));
      File('${outDir.path}${sep}hair_${name}_cur.png')
          .writeAsBytesSync(img.encodePng(cc));
      File('${outDir.path}${sep}hair_${name}_qdq.png')
          .writeAsBytesSync(img.encodePng(cq));
      File('${outDir.path}${sep}hair_${name}_row.png')
          .writeAsBytesSync(img.encodePng(_stitchRow(<img.Image>[cr, cc, cq])));
    }
    log('SUMMARY dIoU min=${minDelta.toStringAsFixed(4)} '
        'max=${maxDelta.toStringAsFixed(4)}');
    log('SUMMARY peakRssMb base=$rssBase afterCur=$rssCur afterQdq=$rssQdq');
    File('${outDir.path}${sep}qdq_ab_report.txt')
        .writeAsStringSync(report.toString());
  });
}
