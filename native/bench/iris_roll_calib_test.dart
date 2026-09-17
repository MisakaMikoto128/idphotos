// ml-porting 自用：瞳孔级眼线估计（P0 歪斜修复）的实测标定与覆盖率回归。
//
// 跑法：
//   flutter test native/bench/iris_roll_calib_test.dart
//
// 三段断言面：
//   A. 真实语料覆盖率：黄金集 8 张 + `C:\Users\liuyu\Pictures\` 顶层全量
//      + 两张用户照片。报告 pupil 成功率、unavailable 清单与原因。
//   B. 注入旋转系列（**符号口径标定**）：把已知角 φ 喂进真实引擎，确认
//      瞳孔估计随 φ 单调、斜率 ≈ 1、符号与旧路径（YuNet 眼线）一致。
//      正负两方向都测——符号反了会让所有照片反向歪，比不改更糟。
//   C. 真值锚点：`1 (2).jpg` 真值 −4.4°、`2.jpg` 真值 −0.22°（imaging
//      三方独立测量，见 out/tmp/roll_repro/），逐条打印误差。
//
// 全部走**真实生产路径**（MattingEngineMixin.detectFace），不复制算法、
// 不写 Python 复刻——复刻出来的对照是假的（PITFALLS 前车之鉴）。
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

/// 旧路径的口径：YuNet 双眼关键点连线（图像左 → 图像右）。
/// 保留它**只作对照**，生产路径已不用（见 iris_roll.dart 头注）。
double? _yunetEyeLine(FaceInfo? f) {
  final Float32List? lm = f?.landmarks;
  if (lm == null || lm.length < 10) return null;
  final bool aLeft = lm[0] < lm[2];
  final double ax = aLeft ? lm[0] : lm[2];
  final double ay = aLeft ? lm[1] : lm[3];
  final double bx = aLeft ? lm[2] : lm[0];
  final double by = aLeft ? lm[3] : lm[1];
  return math.atan2(by - ay, bx - ax) * 180.0 / math.pi;
}

double _eyeDist(FaceInfo? f) {
  final Float32List? lm = f?.landmarks;
  if (lm == null || lm.length < 10) return 0;
  return math.sqrt(math.pow(lm[2] - lm[0], 2) + math.pow(lm[3] - lm[1], 2))
      .toDouble();
}

const List<String> _kGolden =
    <String>['g01', 'g02', 'g03', 'g04', 'g05', 'g06', 'g07', 'g08'];

const List<double> _kAngles = <double>[
  0, 1, -1, 2, -2, 3, -3, 4, -4, 6, -6, 10, -10,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _Engine();

  setUpAll(() => engine.warmUp());
  tearDownAll(() => engine.disposeMattingEngine());

  test('A. 真实语料瞳孔估计覆盖率', () async {
    final List<String> rows = <String>[];
    final List<String> unavailable = <String>[];
    final List<double> pupilAngles = <double>[];
    var n = 0;
    var nFace = 0;
    var nPupil = 0;
    final sw = Stopwatch()..start();

    Future<void> probe(String label, Uint8List bytes) async {
      n++;
      FaceInfo? f;
      try {
        f = await engine.detectFace(bytes);
      } on IdPhotoException catch (e) {
        rows.add('$label | EDGE ${e.runtimeType}');
        return;
      }
      if (f == null) {
        rows.add('$label | no-face');
        return;
      }
      nFace++;
      final double? yu = _yunetEyeLine(f);
      if (f.rollSource == RollSource.pupil) {
        nPupil++;
        pupilAngles.add(f.rollDeg);
        rows.add('$label | pupil roll=${f.rollDeg.toStringAsFixed(2)} '
            'yunet=${yu?.toStringAsFixed(2)} ed=${_eyeDist(f).toStringAsFixed(0)} '
            'conf=${f.confidence.toStringAsFixed(2)}');
      } else {
        unavailable.add('$label | ${f.rollSource.name} '
            'yunet=${yu?.toStringAsFixed(2)} ed=${_eyeDist(f).toStringAsFixed(0)}');
      }
    }

    for (final id in _kGolden) {
      await probe('golden/$id',
          File('test/golden/src/$id.jpg').readAsBytesSync());
    }
    final dir = Directory(r'C:\Users\liuyu\Pictures');
    if (dir.existsSync()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((File f) {
            final p = f.path.toLowerCase();
            return p.endsWith('.jpg') ||
                p.endsWith('.jpeg') ||
                p.endsWith('.png') ||
                p.endsWith('.webp');
          })
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
      for (final f in files) {
        await probe('pics/${f.uri.pathSegments.last}', f.readAsBytesSync());
      }
    }

    // ignore: avoid_print
    print('[A] ---- 逐图 ----');
    for (final r in rows) {
      // ignore: avoid_print
      print('[A] $r');
    }
    // ignore: avoid_print
    print('[A] ---- unavailable ----');
    for (final r in unavailable) {
      // ignore: avoid_print
      print('[A] UNAVAIL $r');
    }
    pupilAngles.sort();
    // ignore: avoid_print
    print('[A] files=$n withFace=$nFace pupil=$nPupil '
        'unavailable=${unavailable.length} '
        'pupilRate(over faces)='
        '${(nPupil / math.max(1, nFace) * 100).toStringAsFixed(1)}% '
        'medianRoll=${pupilAngles.isEmpty ? '-' : pupilAngles[pupilAngles.length ~/ 2].toStringAsFixed(2)} '
        'elapsed=${sw.elapsedMilliseconds}ms');
  });

  test('B. 注入旋转系列：符号与线性度标定', () async {
    final List<String> srcs = <String>[
      for (final g in _kGolden) 'test/golden/src/$g.jpg',
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      r'C:\Users\liuyu\Pictures\2.jpg',
    ];
    for (final path in srcs) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = file.readAsBytesSync();
      final String tag = file.uri.pathSegments.last;
      double? base;
      double? baseYu;
      final List<String> deltas = <String>[];
      for (final double phi in _kAngles) {
        Uint8List inBytes;
        if (phi == 0) {
          inBytes = bytes;
        } else {
          final img.Image? decoded = img.decodeImage(bytes);
          if (decoded == null) break;
          inBytes = Uint8List.fromList(img.encodeJpg(
            img.copyRotate(decoded,
                angle: phi, interpolation: img.Interpolation.cubic),
            quality: 95,
          ));
        }
        final FaceInfo? f = await engine.detectFace(inBytes);
        final double? yu = _yunetEyeLine(f);
        if (phi == 0) {
          base = f?.rollSource == RollSource.pupil ? f?.rollDeg : null;
          baseYu = yu;
        }
        // ignore: avoid_print
        print('[B] $tag phi=$phi roll=${f?.rollDeg.toStringAsFixed(2)} '
            'src=${f?.rollSource.name} yunet=${yu?.toStringAsFixed(2)} '
            'Δpupil=${(f != null && f.rollSource == RollSource.pupil && base != null) ? (f.rollDeg - base).toStringAsFixed(2) : '-'} '
            'Δyunet=${(yu != null && baseYu != null) ? (yu - baseYu).toStringAsFixed(2) : '-'}');
        deltas.add('');
      }
    }
  });

  test('C. 真值锚点', () async {
    // imaging 三方独立测量（out/tmp/roll_repro/p1_truth.json / p2_truth.json）。
    const Map<String, double> truth = <String, double>{
      r'C:\Users\liuyu\Pictures\1 (2).jpg': -4.4,
      r'C:\Users\liuyu\Pictures\2.jpg': -0.22,
    };
    for (final e in truth.entries) {
      final File f = File(e.key);
      if (!f.existsSync()) continue;
      final FaceInfo? fi = await engine.detectFace(f.readAsBytesSync());
      final double? yu = _yunetEyeLine(fi);
      final double truthVal = e.value;
      final String got = fi != null && fi.rollSource == RollSource.pupil
          ? fi.rollDeg.toStringAsFixed(2)
          : 'unavailable';
      final String err = fi != null && fi.rollSource == RollSource.pupil
          ? (fi.rollDeg - truthVal).abs().toStringAsFixed(2)
          : '-';
      // ignore: avoid_print
      print('[C] ${f.uri.pathSegments.last} truth=$truthVal '
          'pupil=$got |err|=$err yunet=${yu?.toStringAsFixed(2)} '
          'yunetErr=${yu == null ? '-' : (yu - truthVal).abs().toStringAsFixed(2)}');
    }
  });

  test('D. 门禁锚点夹具：旋转等变与绝对精度', () async {
    // 用**门禁自己冻结的夹具**（out/P0_anchors/，78 张旋转件 + 13 锚点，
    // 角度经 cv2 像素级配准确认到 ≤0.015°，见 out/P0_truth.json 的
    // fixtureGeoVerification）跑生产 detectFace。这直接回答 ACCEPTANCE P0.3
    // 的「Δ ∈ {±3,±5,±10}° 斜率 ∈ [0.85,1.15]、无方向性衰减」。
    final File truthFile = File('out/P0_truth.json');
    if (!truthFile.existsSync()) {
      // ignore: avoid_print
      print('[D] out/P0_truth.json 不存在，跳过');
      return;
    }
    final Map<String, dynamic> truth =
        jsonDecode(truthFile.readAsStringSync()) as Map<String, dynamic>;
    final List<dynamic> anchors =
        (truth['anchors'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> rotated =
        (truth['rotated'] as List<dynamic>?) ?? <dynamic>[];

    double? slopeOf(List<double> xs, List<double> ys) {
      final int n = xs.length;
      if (n < 3) return null;
      final double sx = xs.reduce((a, b) => a + b);
      final double sy = ys.reduce((a, b) => a + b);
      final double sxx = xs.map((v) => v * v).reduce((a, b) => a + b);
      final double sxy = List<double>.generate(n, (i) => xs[i] * ys[i])
          .reduce((a, b) => a + b);
      final double den = n * sxx - sx * sx;
      if (den == 0) return null;
      return (n * sxy - sx * sy) / den;
    }

    double worstAbs = 0;
    String worstTag = '-';
    final List<String> badSlope = <String>[];
    for (final dynamic a in anchors) {
      final Map<String, dynamic> anc = a as Map<String, dynamic>;
      final String id = anc['id'] as String;
      final double anchorTruth = (anc['trueRollDeg'] as num).toDouble();
      final List<double> deltas = <double>[0];
      final List<double> ests = <double>[];
      final File base = File('out/P0_anchors/$id.png');
      if (!base.existsSync()) continue;
      final FaceInfo? bf = await engine.detectFace(base.readAsBytesSync());
      ests.add(bf?.rollSource == RollSource.pupil ? bf!.rollDeg : double.nan);
      for (final dynamic r in rotated) {
        final Map<String, dynamic> rot = r as Map<String, dynamic>;
        if (rot['src'] != id) continue;
        final double d = (rot['deltaDeg'] as num).toDouble();
        final File f = File(rot['path'] as String);
        if (!f.existsSync()) continue;
        final FaceInfo? ff = await engine.detectFace(f.readAsBytesSync());
        final double exp = (rot['expectedTiltDeg'] as num).toDouble();
        final bool got = ff?.rollSource == RollSource.pupil;
        final double err = got ? (ff!.rollDeg - exp).abs() : -1;
        if (err > worstAbs) {
          worstAbs = err;
          worstTag = '${id}_d$d';
        }
        // ignore: avoid_print
        print('[D] ${id}_d$d exp=$exp '
            'est=${got ? ff!.rollDeg.toStringAsFixed(2) : 'unavail'} '
            'err=${err < 0 ? '-' : err.toStringAsFixed(2)}');
        if (got) {
          deltas.add(d);
          ests.add(ff!.rollDeg);
        }
      }
      if (ests.length < 4) {
        // ignore: avoid_print
        print('[D] $id too few pupil estimates (${ests.length})');
        continue;
      }
      final List<double> xs = <double>[];
      final List<double> ys = <double>[];
      final List<double> xp = <double>[], yp = <double>[];
      final List<double> xm = <double>[], ym = <double>[];
      for (var i = 0; i < ests.length; i++) {
        if (ests[i].isNaN) continue;
        xs.add(deltas[i]);
        ys.add(ests[i]);
        if (deltas[i] >= 0) {
          xp.add(deltas[i]);
          yp.add(ests[i]);
        } else {
          xm.add(-deltas[i]);
          ym.add(ests[i]);
        }
      }
      final double? sAll = slopeOf(xs, ys);
      final double? sPlus = slopeOf(xp, yp);
      final double? sMinus = slopeOf(xm, ym);
      final bool ok = sAll != null &&
          sAll.abs() >= 0.85 &&
          sAll.abs() <= 1.15 &&
          sPlus != null &&
          sPlus.abs() >= 0.85 &&
          sPlus.abs() <= 1.15 &&
          sMinus != null &&
          sMinus.abs() >= 0.85 &&
          sMinus.abs() <= 1.15;
      if (!ok) badSlope.add(id);
      // ignore: avoid_print
      print('[D] $id truth=$anchorTruth n=${ests.length} '
          'slope=${sAll?.toStringAsFixed(3)} '
          '+side=${sPlus?.toStringAsFixed(3)} '
          '−side=${sMinus?.toStringAsFixed(3)} ${ok ? 'OK' : 'SLOPE-OUT'}');
    }
    // ignore: avoid_print
    print('[D] worstAbsErr=$worstAbs ($worstTag) '
        'slopeOutOfRange=[${badSlope.join(',')}]');
  });

  test('E. 瞳孔估计单张耗时', () async {
    final List<String> paths = <String>[
      for (final g in _kGolden) 'test/golden/src/$g.jpg',
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      r'C:\Users\liuyu\Pictures\2.jpg',
      r'C:\Users\liuyu\Pictures\a.jpg',
      r'C:\Users\liuyu\Pictures\报名照片.jpg',
    ];
    final List<double> ms = <double>[];
    for (final path in paths) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = file.readAsBytesSync();
      final FaceInfo? face = await engine.detectFace(bytes);
      if (face == null || face.landmarks == null) continue;
      final DecodedImage im = decodeToRgb(bytes,
          maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      final Uint8List gray = grayPlaneFromRgb(im.rgb, im.width, im.height);
      final Float32List lm = face.landmarks!;
      // 预热一次，再连测 5 次取中位（首轮含 JIT 与页错误）。
      estimatePupilRoll(
          gray: gray,
          width: im.width,
          height: im.height,
          eyeAx: lm[0],
          eyeAy: lm[1],
          eyeBx: lm[2],
          eyeBy: lm[3]);
      final List<double> runs = <double>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        estimatePupilRoll(
            gray: gray,
            width: im.width,
            height: im.height,
            eyeAx: lm[0],
            eyeAy: lm[1],
            eyeBx: lm[2],
            eyeBy: lm[3]);
        runs.add(sw.elapsedMicroseconds / 1000.0);
      }
      runs.sort();
      ms.add(runs[runs.length ~/ 2]);
      // ignore: avoid_print
      print('[E] ${file.uri.pathSegments.last} ${im.width}x${im.height} '
          'median=${runs[runs.length ~/ 2].toStringAsFixed(1)}ms '
          'min=${runs.first.toStringAsFixed(1)}ms');
    }
    ms.sort();
    // ignore: avoid_print
    print('[E] n=${ms.length} median=${ms[ms.length ~/ 2].toStringAsFixed(1)}ms '
        'max=${ms.last.toStringAsFixed(1)}ms');
  });

  // 判决稳定性：真实用户照片的缩放、JPEG 量化、轻微噪点都会提供与"换一个
  // 夹具"同量级的扰动。qa-batch 报过同一夹具在两个测量台上判决相反
  // （内存旋转台 unavailable / 落盘夹具 pupil，像素 MAE 19.29），gatekeeper
  // 也报过 c06 在 d−5 与 d−3 之间判决跳变。**稳定比准更重要**——本次事故
  // 就是"自信但错"，而一个一碰就翻的实现即使平均误差好看也会线上翻车。
  test('F. 判决稳定性：轻微扰动下的可用性与角度', () async {
    final List<String> srcs = <String>[
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      r'C:\Users\liuyu\Pictures\2.jpg',
      'test/golden/src/g01.jpg',
      'test/golden/src/g05.jpg',
      'test/golden/src/g07.jpg',
    ];
    var stable = 0, total = 0;
    for (final path in srcs) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      final Uint8List bytes = f.readAsBytesSync();
      final img.Image? src = img.decodeImage(bytes);
      if (src == null) continue;
      // (标签, 字节, 期望 rollDeg 相对基准的偏移)
      final List<(String, Uint8List, double)> variants =
          <(String, Uint8List, double)>[
        ('base', bytes, 0.0),
        ('jpg85', Uint8List.fromList(img.encodeJpg(src, quality: 85)), 0.0),
        (
          'scale0.98',
          Uint8List.fromList(img.encodeJpg(
              img.copyResize(src,
                  width: (src.width * 0.98).round(),
                  interpolation: img.Interpolation.cubic),
              quality: 92)),
          0.0
        ),
        (
          'scale1.02',
          Uint8List.fromList(img.encodeJpg(
              img.copyResize(src,
                  width: (src.width * 1.02).round(),
                  interpolation: img.Interpolation.cubic),
              quality: 92)),
          0.0
        ),
        (
          'rot+0.3',
          Uint8List.fromList(img.encodeJpg(
              img.copyRotate(src, angle: 0.3, interpolation: img.Interpolation.cubic),
              quality: 92)),
          0.3
        ),
        (
          'rot-0.3',
          Uint8List.fromList(img.encodeJpg(
              img.copyRotate(src, angle: -0.3, interpolation: img.Interpolation.cubic),
              quality: 92)),
          -0.3
        ),
      ];
      double? base;
      final List<double> dev = <double>[];
      final List<String> miss = <String>[];
      final List<String> line = <String>[];
      for (final (String tag, Uint8List b, double shift) in variants) {
        final FaceInfo? fi = await engine.detectFace(b);
        final bool ok = fi != null && fi.rollSource == RollSource.pupil;
        if (tag == 'base') base = ok ? fi!.rollDeg : null;
        final double? v = ok ? fi!.rollDeg : null;
        if (!ok) miss.add(tag);
        if (ok && base != null) dev.add((v! - base) - shift);
        line.add('$tag=${ok ? v!.toStringAsFixed(2) : 'unavail'}');
      }
      total++;
      // 判据：全部可用，且相对基准的偏移（扣掉注入的 shift）≤0.5°。
      final bool okAll = miss.isEmpty && dev.every((double d) => d.abs() <= 0.5);
      if (okAll) stable++;
      // ignore: avoid_print
      print('[F] ${f.uri.pathSegments.last} ${okAll ? 'STABLE' : 'UNSTABLE'} '
          '${line.join(' ')}'
          '${dev.isEmpty ? '' : ' maxDev=${dev.map((e) => e.abs()).reduce(math.max).toStringAsFixed(2)}'}'
          '${miss.isEmpty ? '' : ' UNAVAIL=[${miss.join(',')}]'}');
    }
    // ignore: avoid_print
    print('[F] stable=$stable/$total');
  });
}
