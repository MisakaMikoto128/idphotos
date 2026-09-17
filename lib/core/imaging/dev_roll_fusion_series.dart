/// 木照 MuZhao — 多线融合估角回归系列：8 黄金图 × ±1/2/3/4/6/10° 策略对照。
///
/// 运行（项目根目录）：
/// ```
/// flutter test lib/core/imaging/dev_roll_fusion_series.dart
/// ```
///
/// 残差口径沿用上一轮（dev_roll_probe2 / PITFALLS）：T0(图) = φ=0 时解码器
/// 眼线 rollDeg 基线，残差 = T0 + φ − applied。它量的是**系列一致性**（估角
/// 随注入角的变化），不是绝对精度——黄金图没有独立真值（g01 即用户 p2，
/// 眼线基线 −3.86 而真值 0，正是被诊断的损坏样本）。
///
/// 对照策略（全部死区 1°，与生产 planRotation 一致）：
/// - A_eye      旧路径：解码器眼线（对照基线）
/// - B_fused    新生产路径：roll_fusion.dart（眼为主 + 共识门 0.5 内平均嘴线）
/// - C_mouth    ml-porting 假设之一：纯嘴线
/// - D_median3  三线（含鼻轴）等权中位
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// flutter_test 是 dev_dependency；本文件是开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/imaging/roll_fusion.dart';

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

class _FaceEngine with MattingEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

const List<double> kAngles = <double>[
  0, 1, -1, 2, -2, 3, -3, 4, -4, 6, -6, 10, -10,
];

const List<String> kPhotos = <String>[
  'g01', 'g02', 'g03', 'g04', 'g05', 'g06', 'g07', 'g08',
];

const double kDeadZone = 1.0;

double applyPolicy(double est) => est.abs() > kDeadZone ? est : 0.0;

double xPairDeg(Float32List lm, int i, int j) {
  final double ax = lm[i], ay = lm[i + 1], bx = lm[j], by = lm[j + 1];
  final double dx = bx - ax, dy = by - ay;
  if (dx == 0 && dy == 0) return double.nan;
  return math.atan2(dy, dx) * 180.0 / math.pi;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FaceEngine();

  test('8 图 × 13 角策略对照系列', () async {
    await engine.warmUp();
    // 策略 → [maxAbsResid, sumAbsResid, n]；另按图输出明细。
    final Map<String, List<double>> stats = <String, List<double>>{};
    for (final p in const ['A_eye', 'B_fused', 'C_mouth', 'D_median3']) {
      stats[p] = <double>[0, 0, 0];
    }
    final Map<String, List<double>> perPhoto = <String, List<double>>{};
    for (final p in stats.keys) {
      perPhoto[p] = <double>[0, 0]; // max, sum
    }

    for (final name in kPhotos) {
      // perPhoto 是按图统计，进图前先清零（否则跨图累计，g04 起全是假数）。
      for (final p in perPhoto.keys) {
        perPhoto[p]![0] = 0;
        perPhoto[p]![1] = 0;
      }
      final bytes = File('test/golden/src/$name.jpg').readAsBytesSync();
      final FaceInfo? base = await engine.detectFace(bytes);
      final double t0 = base?.rollDeg ?? double.nan;
      final Float32List? baseLm = base?.landmarks;
      double baseMouth = double.nan;
      if (baseLm != null && baseLm.length >= 10) {
        baseMouth = baseLm[8] > baseLm[6]
            ? xPairDeg(baseLm, 6, 8)
            : xPairDeg(baseLm, 8, 6);
      }
      // ignore: avoid_print
      print('[$name] T0(eye)=${t0.toStringAsFixed(3)} '
          'mouth0=${baseMouth.toStringAsFixed(3)}');

      for (final phi in kAngles) {
        Uint8List inBytes;
        if (phi == 0) {
          inBytes = bytes;
        } else {
          final img.Image rot = img.copyRotate(
            img.decodeJpg(bytes)!,
            angle: phi,
            interpolation: img.Interpolation.cubic,
          );
          inBytes = Uint8List.fromList(img.encodeJpg(rot, quality: 95));
        }
        final FaceInfo? f = await engine.detectFace(inBytes);
        if (f == null || f.landmarks == null || f.landmarks!.length < 10) {
          // ignore: avoid_print
          print('[series] $name phi=$phi detect=null or no landmarks, skip');
          continue;
        }
        final Float32List lm = f.landmarks!;
        final double eye = f.rollDeg;
        final double mouth = lm[8] > lm[6]
            ? xPairDeg(lm, 6, 8)
            : xPairDeg(lm, 8, 6);
        final double midX = (lm[0] + lm[2]) / 2.0;
        final double midY = (lm[1] + lm[3]) / 2.0;
        final double noseA =
            math.atan2(lm[5] - midY, lm[4] - midX) * 180 / math.pi - 90.0;
        final double trueTilt = t0 + phi;

        final double aEye = applyPolicy(eye);
        final RollFusion fus = fuseRollDeg(
          landmarks: lm,
          legacyRollDeg: eye,
        );
        final double bFused = applyPolicy(fus.rollDeg);
        final double cMouth = applyPolicy(mouth);
        final List<double> three = <double>[eye, mouth, noseA]
            .where((v) => v.isFinite)
            .toList()
          ..sort();
        final double dMedian3 =
            three.isEmpty ? double.nan : three[three.length ~/ 2];
        final double dAppl = dMedian3.isFinite ? applyPolicy(dMedian3) : aEye;

        final List<double> applied = <double>[aEye, bFused, cMouth, dAppl];
        final List<String> keys = stats.keys.toList();
        for (int i = 0; i < keys.length; i++) {
          final double resid = trueTilt - applied[i];
          final List<double> s = stats[keys[i]]!;
          s[0] = math.max(s[0], resid.abs());
          s[1] += resid.abs();
          s[2] += 1;
          perPhoto[keys[i]]![0] =
              math.max(perPhoto[keys[i]]![0], resid.abs());
          perPhoto[keys[i]]![1] += resid.abs();
        }
        // ignore: avoid_print
        print('[series] $name phi=$phi '
            'eye=${eye.toStringAsFixed(2)} mouth=${mouth.toStringAsFixed(2)} '
            'nose=${noseA.toStringAsFixed(2)} fused=${fus.rollDeg.toStringAsFixed(2)}(${fus.source}) '
            'residA=${(trueTilt - applied[0]).toStringAsFixed(2)} '
            'residB=${(trueTilt - applied[1]).toStringAsFixed(2)}');
      }
      // ignore: avoid_print
      print('[perPhoto] $name '
          'A max=${perPhoto['A_eye']![0].toStringAsFixed(2)} '
          'mean=${(perPhoto['A_eye']![1] / 13).toStringAsFixed(2)} | '
          'B max=${perPhoto['B_fused']![0].toStringAsFixed(2)} '
          'mean=${(perPhoto['B_fused']![1] / 13).toStringAsFixed(2)}');
    }

    // ignore: avoid_print
    for (final e in stats.entries) {
      // ignore: avoid_print
      print('[STATS] ${e.key} maxAbsResid=${e.value[0].toStringAsFixed(3)} '
          'meanAbsResid=${(e.value[1] / math.max(1, e.value[2].toInt()))
              .toStringAsFixed(3)} n=${e.value[2].toInt()}');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
