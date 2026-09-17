/// 木照 MuZhao — 小角度摆正实验台（imaging 自检，不进发布路径）。
///
/// 运行（项目根目录）：
/// ```
/// flutter test lib/core/imaging/dev_roll_probe.dart
/// ```
///
/// P0 用户反馈：Windows 真实照片成片有可见歪斜（怀疑摆正矫枉过正）。
/// G2B.8 只测了 ±6/±10°，本脚本对黄金集正面照人工旋转 ±1–4° 小角度，
/// 跑完整管线（YuNet 检测 → MODNet 抠图 → compose 摆正），量：
///
/// 1. 估角误差 e(φ) = rollEst(φ) − rollEst(0) − φ（YuNet 眼线角随真值的偏差）；
/// 2. 残差预测 = rollEst(0) + φ − applied（applied 为死区裁决后的摆正角）；
/// 3. 残差实测 = 对成片 JPEG 重新检脸的 rollDeg（295×413 上眼距 ~60px，
///    单像素抖动 ≈ 0.95°，是测量噪声地板，只做旁证）。
///
/// 产物（逐角度成片 PNG）写 out/tmp/roll_probe_imaging/。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// flutter_test 是 dev_dependency；本文件是开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/imaging/compose_engine.dart';

/// 宿主机 flutter test 的 DLL 预载（与 native/bench 同款做法）。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter test 没有 path_provider 的应用目录，直接读仓库里的模型。
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FullEngine();

  test('小角度摆正实验', () async {
    try {
      await engine.warmUp();
    } on IdPhotoException catch (e) {
      // ignore: avoid_print
      print('warmUp 失败 cause=${e.cause}');
      rethrow;
    }
    final outDir = Directory('out/tmp/roll_probe_imaging');
    outDir.createSync(recursive: true);

    // 每张照片先量自然倾角基线。
    final Map<String, double> baseline = <String, double>{};

    for (final name in kPhotos) {
      final bytes =
          File('test/golden/src/$name.jpg').readAsBytesSync();
      final base0 = await engine.detectFace(bytes);
      baseline[name] = base0?.rollDeg ?? double.nan;
      // ignore: avoid_print
      print('[$name] 自然倾角基线 roll0='
          '${baseline[name]!.toStringAsFixed(3)}  '
          'conf=${base0?.confidence.toStringAsFixed(3)}');

      // 死区外的符号校准：用 ±10° 的大角度确认 copyRotate 正角在 YuNet
      // 约定下是正还是负。
      double sign = 1.0;
      for (final double cal in const <double>[10.0]) {
        final rot = img.copyRotate(
          img.decodeJpg(bytes)!,
          angle: cal,
          interpolation: img.Interpolation.cubic,
        );
        final rb = Uint8List.fromList(img.encodeJpg(rot, quality: 95));
        final f = await engine.detectFace(rb);
        final est = f?.rollDeg ?? double.nan;
        if ((est - baseline[name]!).abs() > 3) {
          sign = (est - baseline[name]!) > 0 ? 1.0 : -1.0;
        }
      }
      // ignore: avoid_print
      print('[$name] copyRotate 符号校准 s=$sign');

      // ignore: avoid_print
      print('[$name] phi, rollEst, e(φ)=est-roll0-s·phi, applied, '
          'resid_pred, resid_meas');
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
        final double est = face?.rollDeg ?? double.nan;
        final MattingResult matting =
            await engine.removeBackground(inBytes);
        final Candidate c = await engine.compose(
          matting: matting,
          spec: kSpecCn1inch,
          style: kBgWhite,
          face: face,
        );
        final FaceInfo? outFace = await engine.detectFace(c.jpegBytes);
        // applied 取生产路径的真实摆正角（lastDiagnostics），不在这里私设
        // 死区阈值——那会测不到 planRotation 的实际行为。
        final double applied = engine.lastDiagnostics!.straightenDeg;
        final double trueTilt = baseline[name]! + sign * phi;
        final double e = est - baseline[name]! - sign * phi;
        final double residPred = trueTilt - applied;
        final double residMeas = outFace?.rollDeg ?? double.nan;
        // ignore: avoid_print
        print('[probe] $name phi=$phi est=${est.toStringAsFixed(3)} '
            'e=${e.toStringAsFixed(3)} applied=${applied.toStringAsFixed(3)} '
            'residPred=${residPred.toStringAsFixed(3)} '
            'residMeas=${residMeas.toStringAsFixed(3)}');
        File('${outDir.path}/${name}_phi${phi.toStringAsFixed(1)}.png')
            .writeAsBytesSync(img.encodePng(img.decodeJpg(c.jpegBytes)!));
      }
    }
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
