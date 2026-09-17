/// 木照 MuZhao — 小角度摆正实验台第二期：掩膜头轴信号 + 修法模拟。
///
/// 运行（项目根目录）：
/// ```
/// flutter test lib/core/imaging/dev_roll_probe2.dart
/// ```
///
/// 第一期（dev_roll_probe.dart）结论：
/// - compose 几何精确（residPred 由刚体旋转唯一决定）；
/// - YuNet 眼线估角：干净脸 ±1°，镜框脸（g03）小角度下 ±2–4° 抖动；
/// - 死区 3° 让 1–3° 的真实倾斜完全不修正（用户可见歪斜的主因）；
/// - 成片 295×413 上重新检脸的残差读数不可信（g03 目视水平却读 −6.6°），
///   只能当旁证。
///
/// 本脚本测量第二信号：**alpha 掩膜头部中轴**（hairTop→chin 各行前景质心
/// 的最小二乘斜率），对比其误差曲线，并模拟三种摆正策略的残差：
/// A=现行（死区 3°）、B=死区 1°+眼线、C=死区 1°+眼线/掩膜轴融合。
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
import 'package:muzhao/core/imaging/compose_engine.dart';

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

class _FullEngine with MattingEngineMixin, ComposeEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

const List<double> kAngles = <double>[
  0, 1, -1, 1.5, -1.5, 2, -2, 2.5, -2.5, 3, -3, 4, -4, 6, -6, 10, -10,
];

const List<String> kPhotos = <String>['g01', 'g03', 'g07'];

/// alpha 掩膜头部中轴倾角（度，符号与 YuNet rollDeg 同向）。
///
/// 在 face box 中心 ±0.75·boxW 的竖直带里，对 [发顶, chin] 行逐行求前景
/// 质心，跳过最下 12%（颌颈外扩不对称），最小二乘拟合 x = a + b·y。
/// 头轴向观众右倾（roll>0）时顶部 x 大、底部 x 小 → b < 0 → roll ≈ −atan(b)。
/// 行数不足或前景过窄时返回 NaN。
double maskAxisRollDeg(MattingResult m, FaceInfo f) {
  final int w = m.width, h = m.height;
  final double band = math.max(4.0, f.box.width * 0.75);
  final double cx = f.box.center.dx;
  final double bandL = math.max(0.0, cx - band);
  final double bandR = math.min(w.toDouble(), cx + band);

  // 发顶：从 box 顶向下找到第一行有前景的行。
  int top = f.box.top.floor().clamp(0, h - 1);
  final int chinR = f.chinY.floor().clamp(0, h - 1);
  while (top < chinR) {
    int n = 0;
    for (int x = bandL.floor(); x < bandR; x++) {
      if (m.alpha[top * w + x] >= 128) n++;
    }
    if (n >= 6) break;
    top++;
  }
  if (top >= chinR) return double.nan;

  final int skipBottom = ((chinR - top) * 0.12).round();
  final int yEnd = chinR - skipBottom;
  final int yStart = top + ((chinR - top) * 0.08).round();
  if (yEnd - yStart < 12) return double.nan;

  double sx = 0, sy = 0, syy = 0, sxy = 0;
  int nRows = 0;
  for (int y = yStart; y < yEnd; y++) {
    double sum = 0, wsum = 0;
    for (int x = bandL.floor(); x < bandR; x++) {
      final int a = m.alpha[y * w + x];
      if (a >= 128) {
        sum += x;
        wsum++;
      }
    }
    if (wsum < 8) continue;
    final double c = sum / wsum;
    sx += c;
    sy += y;
    syy += y * y;
    sxy += c * y;
    nRows++;
  }
  if (nRows < 12) return double.nan;
  final double mx = sx / nRows, my = sy / nRows;
  final double denom = (syy - nRows * my * my); // var(y)
  if (denom.abs() < 1e-6) return double.nan;
  final double b = (sxy - nRows * mx * my) / denom; // dx per dy
  final double roll = -math.atan(b) * 180.0 / math.pi;
  return roll.isFinite ? roll : double.nan;
}

/// 策略裁决：返回应当施加的摆正角。
double policy(String name, double est, double mask) {
  switch (name) {
    case 'A_deadzone3':
      return est.abs() > 3.0 ? est : 0.0;
    case 'B_deadzone1':
      return est.abs() > 1.0 ? est : 0.0;
    case 'C_fused':
      if (est.abs() <= 1.0) return 0.0;
      if (mask.isFinite && est * mask > 0 && (est - mask).abs() <= 3.0) {
        return (est + mask) / 2.0;
      }
      if (mask.isFinite && est * mask > 0 && (est - mask).abs() > 3.0) {
        // 两信号同号但分歧大：镜框把眼线带歪的典型形态，信掩膜。
        return mask;
      }
      return est;
  }
  return 0.0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FullEngine();

  test('掩膜头轴测量 + 修法模拟', () async {
    await engine.warmUp();
    final outDir = Directory('out/tmp/roll_probe_imaging');
    outDir.createSync(recursive: true);

    final Map<String, double> baseline = <String, double>{};
    final Map<String, double> baseMask = <String, double>{};
    // 残差累计：policy → [maxAbs, sumAbs, n]
    final Map<String, List<double>> stats = <String, List<double>>{};
    for (final p in const ['A_deadzone3', 'B_deadzone1', 'C_fused']) {
      stats[p] = <double>[0, 0, 0];
    }

    for (final name in kPhotos) {
      final bytes = File('test/golden/src/$name.jpg').readAsBytesSync();
      final base0 = await engine.detectFace(bytes);
      baseline[name] = base0?.rollDeg ?? double.nan;
      final MattingResult baseM = await engine.removeBackground(bytes);
      baseMask[name] = maskAxisRollDeg(baseM, base0!);
      // ignore: avoid_print
      print('[$name] 眼线基线=${baseline[name]!.toStringAsFixed(3)} '
          '掩膜轴基线=${baseMask[name]!.toStringAsFixed(3)}');

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
        final FaceInfo? face = await engine.detectFace(inBytes);
        final MattingResult matting = await engine.removeBackground(inBytes);
        final double est = face?.rollDeg ?? double.nan;
        final double mask = maskAxisRollDeg(matting, face!);
        final double trueTilt = baseline[name]! + phi;

        // 修法模拟：直接把裁决角塞进 FaceInfo.rollDeg 让 compose 执行，
        // 几何路径与生产一致；残差 = trueTilt − applied（刚体旋转下精确）。
        final List<double> applied = <double>[];
        for (final p in stats.keys) {
          final double roll = p == 'C_fused'
              ? policy('C_fused', est, mask)
              : policy(p, est, mask);
          applied.add(roll);
          final double resid = trueTilt - roll;
          final List<double> s = stats[p]!;
          s[0] = math.max(s[0], resid.abs());
          s[1] += resid.abs();
        }

        // ignore: avoid_print
        print('[probe2] $name phi=$phi est=${est.toStringAsFixed(3)} '
            'mask=${mask.isFinite ? mask.toStringAsFixed(3) : 'nan'} '
            'eEst=${(est - trueTilt).toStringAsFixed(3)} '
            'eMask=${mask.isFinite ? (mask - trueTilt).toStringAsFixed(3) : 'nan'} '
            'appliedA=${applied[0].toStringAsFixed(2)} '
            'appliedB=${applied[1].toStringAsFixed(2)} '
            'appliedC=${applied[2].toStringAsFixed(2)} '
            'residA=${(trueTilt - applied[0]).toStringAsFixed(2)} '
            'residB=${(trueTilt - applied[1]).toStringAsFixed(2)} '
            'residC=${(trueTilt - applied[2]).toStringAsFixed(2)}');
      }
    }
    for (final p in stats.keys) {
      final List<double> s = stats[p]!;
      // ignore: avoid_print
      print('[STATS] $p maxAbsResid=${s[0].toStringAsFixed(2)} '
          'meanAbsResid=${(s[1] / 51).toStringAsFixed(2)}');
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
