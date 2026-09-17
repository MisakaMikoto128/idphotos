/// 木照 MuZhao — P0 歪斜修复第三棒实验台：YuNet 五关键点三线测角基线。
///
/// 运行（项目根目录）：
/// ```
/// flutter test lib/core/imaging/dev_lm_fusion_probe.dart
/// ```
///
/// 对用户两张源图（p1=`1 (2).jpg` 真值 −5.5±1.5、p2=`2.jpg` 真值 0±0.5，
/// 见 `out/tmp/roll_repro/p*_truth.json` 与 PITFALLS 二次归因）与黄金集
/// g01–g08，dump `FaceInfo.landmarks` 并计算三条候选线（全部按 x 从小到大
/// 定向后取 atan2，符号口径与 YuNet rollDeg 一致：正=头向观众右倾）：
///
/// - 眼线：关键点对 0–3
/// - 嘴线：关键点对 6–9
/// - 鼻轴：鼻尖(4) 相对两眼中点(0,3 中点) 的方向角 − 90°
///
/// 输出 JSON 落盘 `out/tmp/roll_repro/lm_fusion_baseline.json`，供权重校准。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// flutter_test 是 dev_dependency；本文件是开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
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

class _FaceEngine with MattingEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

/// 点对按 x 定向的 atan2 角（度）。与 yunet_decoder 的 rollDeg 同符号口径。
double pairAngleDeg(double x1, double y1, double x2, double y2) {
  final double ax = x1, ay = y1, bx = x2, by = y2;
  final double dx = bx - ax, dy = by - ay;
  return math.atan2(dy, dx) * 180.0 / math.pi;
}

/// 三线测角。返回 null 表示 landmarks 缺失或退化（两点重合）。
Map<String, double>? threeLineDeg(FaceInfo f) {
  final Float32List? lm = f.landmarks;
  if (lm == null || lm.length < 10) return null;
  // 眼对 0-3，按 x 定向
  final double ex1 = lm[0], ey1 = lm[1], ex2 = lm[2], ey2 = lm[3];
  final double eyeA = ex2 > ex1
      ? pairAngleDeg(ex1, ey1, ex2, ey2)
      : pairAngleDeg(ex2, ey2, ex1, ey1);
  // 嘴对 6-9，按 x 定向
  final double mx1 = lm[6], my1 = lm[7], mx2 = lm[8], my2 = lm[9];
  final double mouthA = mx2 > mx1
      ? pairAngleDeg(mx1, my1, mx2, my2)
      : pairAngleDeg(mx2, my2, mx1, my1);
  // 鼻轴：两眼中点 → 鼻尖；竖直向下为 0 roll，轴角 − 90°
  final double midX = (ex1 + ex2) / 2.0, midY = (ey1 + ey2) / 2.0;
  final double nx = lm[4], ny = lm[5];
  final double noseA = pairAngleDeg(midX, midY, nx, ny) - 90.0;
  // 眼距（一致性/尺度参考）与嘴宽
  final double eyeDist = math.sqrt((ex2 - ex1) * (ex2 - ex1) +
      (ey2 - ey1) * (ey2 - ey1));
  final double mouthW = math.sqrt((mx2 - mx1) * (mx2 - mx1) +
      (my2 - my1) * (my2 - my1));
  return <String, double>{
    'eye': eyeA,
    'mouth': mouthA,
    'nose': noseA,
    'eyeDist': eyeDist,
    'mouthW': mouthW,
  };
}

const Map<String, String> kUserSources = <String, String>{
  'p1': r'C:/Users/liuyu/Pictures/1 (2).jpg',
  'p2': r'C:/Users/liuyu/Pictures/2.jpg',
};

const List<String> kGolden = <String>[
  'g01', 'g02', 'g03', 'g04', 'g05', 'g06', 'g07', 'g08',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _FaceEngine();

  test('五关键点三线基线 dump', () async {
    await engine.warmUp();
    final Map<String, dynamic> report = <String, dynamic>{};

    Future<void> scan(String tag, Uint8List bytes) async {
      final FaceInfo? f = await engine.detectFace(bytes);
      if (f == null) {
        report[tag] = <String, dynamic>{'face': null};
        // ignore: avoid_print
        print('[$tag] detectFace=null');
        return;
      }
      final Map<String, double>? t = threeLineDeg(f);
      final Float32List? lm = f.landmarks;
      // ignore: avoid_print
      print('[$tag] rollDeg=${f.rollDeg.toStringAsFixed(3)} '
          'conf=${f.confidence.toStringAsFixed(3)} '
          'eye=${t?['eye']?.toStringAsFixed(3)} '
          'mouth=${t?['mouth']?.toStringAsFixed(3)} '
          'nose=${t?['nose']?.toStringAsFixed(3)} '
          'eyeDist=${t?['eyeDist']?.toStringAsFixed(1)} '
          'mouthW=${t?['mouthW']?.toStringAsFixed(1)} '
          'kps=[${lm == null ? 'null' : lm.map((v) => v.toStringAsFixed(1)).join(',')}]');
      report[tag] = <String, dynamic>{
        'face': <String, dynamic>{
          'rollDeg': f.rollDeg,
          'confidence': f.confidence,
          'box': <double>[
            f.box.left, f.box.top, f.box.width, f.box.height],
          'headTopY': f.headTopY,
          'chinY': f.chinY,
        },
        'lines': t,
        'kps': lm?.toList(),
      };
    }

    for (final e in kUserSources.entries) {
      await scan(e.key, File(e.value).readAsBytesSync());
    }
    for (final g in kGolden) {
      await scan(g, File('test/golden/src/$g.jpg').readAsBytesSync());
    }

    final File out = File('out/tmp/roll_repro/lm_fusion_baseline.json');
    out.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
    // ignore: avoid_print
    print('baseline -> ${out.path}');
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
