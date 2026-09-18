// integration_test/compose_eval_test.dart
//
// G2B 的设备端评测代码。`compose()` 依赖 `dart:ui`（PhotoSpec/Rect 等），plain
// `dart run` 摸不到 dart:ui，必须跑在真机/模拟器的 Flutter 引擎里。
// 本文件只产出原始测量数据（JSON），阈值判定在 `tools/gate/gate_G2B.dart`。
//
// **不依赖 ml-porting 的真实抠图结果**——G2B 只测 imaging 的裁剪/换底/编码几何逻辑，
// 用我自己构造的"合成人像"喂给 compose()：
//   - 画布 1000x1400，中央 300x700 矩形代表人像轮廓，边缘 8px 羽化（渐变 alpha），
//     内部填灰色 (128,128,128)。
//   - 头顶处画一条纯青色 (0,255,255) 标记条，下巴处画一条纯品红 (255,0,255) 标记条。
//     背景（矩形外）填一个和所有内置底色、青色、品红都明显不同的橙棕色，验证
//     compose 是否真的把背景换掉了（如果背景没被替换，输出里会看到这个橙棕色，
//     但本文件目前没有专门断言这一点，只是选色时避免和判定逻辑冲突）。
//   - compose() 之后，在**输出** JPEG 里找青色条/品红条的像素质心，反推
//     头顶/下巴在输出图里的位置，从而算头高比、头顶留白比、水平居中偏差
//     （2B.3/2B.4/2B.5），不依赖真实人脸检测。
//   - 2B.8 摆正：把整块合成画布（含标记条）用 `img.copyRotate` 转 ±15°再喂进去，
//     测输出里标记条的残余倾角。**角度必须落在摆正死区（`kRollDeadZoneDeg` = 10°）
//     之外** —— 否则夹具角与门槛重合，转不转只取决于估角噪声落在门槛哪一侧。
//   - 2B.6/2B.7 溢色：换纯绿/纯品红底（这两个测试专用底色，不是 CONTRACTS 第 5 节
//     的内置底色），在“非背景色”像素里查是否有偏色。
//   - 2B.9 边界安全：把 FaceInfo 摆在画布边缘附近，只检查不抛异常、且输出四边
//     没有整圈纯黑像素。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/api.dart';

import '../tools/gate/compose_check_utils.dart';
import '../tools/gate/jpeg_utils.dart';
import '_generated_compose_harness.dart';

const String kGateTmpDir =
    String.fromEnvironment('GATE_TMP_DIR', defaultValue: '/data/local/tmp/muzhao_gate_tmp');

const int kCanvasW = 1000;
const int kCanvasH = 1400;
const int kRectX0 = 350, kRectX1 = 650; // 轮廓水平范围
const int kRectY0 = 300, kRectY1 = 1000; // 轮廓垂直范围
const int kFeatherPx = 8;
const int kStripeH = 4;

const int kCyanR = 0, kCyanG = 255, kCyanB = 255;
const int kMagentaR = 255, kMagentaG = 0, kMagentaB = 255;
const int kBgFillR = 180, kBgFillG = 120, kBgFillB = 60; // 背景橙棕色

/// 构造合成画布：返回 4 通道 img.Image，alpha 通道兼职当作抠图 mask 用
/// （构造阶段的实现细节，转成 MattingResult 时会拆开成 rgba(a=255) + 独立 alpha）。
img.Image _buildCanvas() {
  final image = img.Image(width: kCanvasW, height: kCanvasH, numChannels: 4);
  for (var y = 0; y < kCanvasH; y++) {
    for (var x = 0; x < kCanvasW; x++) {
      final insideX = x >= kRectX0 - kFeatherPx && x < kRectX1 + kFeatherPx;
      final insideY = y >= kRectY0 - kFeatherPx && y < kRectY1 + kFeatherPx;
      double alpha = 0;
      if (x >= kRectX0 && x < kRectX1 && y >= kRectY0 && y < kRectY1) {
        alpha = 255;
      } else if (insideX && insideY) {
        // 羽化区：到矩形的最短距离线性衰减。
        final dx = x < kRectX0 ? kRectX0 - x : (x >= kRectX1 ? x - kRectX1 + 1 : 0);
        final dy = y < kRectY0 ? kRectY0 - y : (y >= kRectY1 ? y - kRectY1 + 1 : 0);
        final dist = math.sqrt((dx * dx + dy * dy).toDouble());
        alpha = (255 * (1 - (dist / kFeatherPx).clamp(0, 1))).clamp(0, 255).toDouble();
      }
      var r = kBgFillR, g = kBgFillG, b = kBgFillB;
      if (alpha > 0) {
        r = 128;
        g = 128;
        b = 128;
      }
      image.setPixelRgba(x, y, r, g, b, alpha.round());
    }
  }
  // 标记条：只画在轮廓内部（不含羽化区），避免和羽化区混色影响质心测量。
  for (var y = kRectY0; y < kRectY0 + kStripeH; y++) {
    for (var x = kRectX0; x < kRectX1; x++) {
      image.setPixelRgba(x, y, kCyanR, kCyanG, kCyanB, 255);
    }
  }
  for (var y = kRectY0 + 200; y < kRectY0 + 200 + kStripeH; y++) {
    for (var x = kRectX0; x < kRectX1; x++) {
      image.setPixelRgba(x, y, kMagentaR, kMagentaG, kMagentaB, 255);
    }
  }
  return image;
}

class Synthetic {
  final MattingResult matting;
  final FaceInfo face;
  const Synthetic(this.matting, this.face);
}

MattingResult _toMattingResult(img.Image image) {
  final w = image.width, h = image.height;
  final rgba = Uint8List(w * h * 4);
  final alpha = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      final idx = (y * w + x);
      rgba[idx * 4] = p.r.toInt();
      rgba[idx * 4 + 1] = p.g.toInt();
      rgba[idx * 4 + 2] = p.b.toInt();
      rgba[idx * 4 + 3] = 255;
      alpha[idx] = p.a.toInt();
    }
  }
  return MattingResult(rgba: rgba, alpha: alpha, width: w, height: h);
}

/// 构造合成输入，rollDeg!=0 时对整张画布做刚体旋转，再从旋转后的画布上
/// 重新量出青色/品红质心作为 chinY/headTopY（不做解析几何推导，直接测量，
/// 保证内部自洽——见文件头注释）。
Synthetic buildSynthetic({double rollDeg = 0}) {
  var canvas = _buildCanvas();
  if (rollDeg != 0) {
    canvas = img.copyRotate(canvas, angle: rollDeg, interpolation: img.Interpolation.linear);
  }
  final headTopMatches = findColorMatches(canvas, kCyanR, kCyanG, kCyanB, tolerance: 30);
  final chinMatches = findColorMatches(canvas, kMagentaR, kMagentaG, kMagentaB, tolerance: 30);
  final headC = centroidOf(headTopMatches);
  final chinC = centroidOf(chinMatches);
  final headTopY = headC?.y ?? kRectY0.toDouble();
  final chinY = chinC?.y ?? (kRectY0 + 200).toDouble();

  final face = FaceInfo(
    box: Rect.fromLTWH(kRectX0.toDouble(), headTopY, (kRectX1 - kRectX0).toDouble(),
        chinY - headTopY),
    chinY: chinY,
    headTopY: headTopY,
    rollDeg: rollDeg,
    confidence: 1.0,
  );
  return Synthetic(_toMattingResult(canvas), face);
}

Map<String, dynamic> _measureOutput(Uint8List jpegBytes, PhotoSpec spec) {
  final decoded = img.decodeJpg(jpegBytes);
  if (decoded == null) {
    return {'error': '输出 JPEG 解码失败'};
  }
  JfifDensity? density;
  try {
    density = readJfifDensity(jpegBytes);
  } catch (e) {
    density = null;
  }

  final headMatches = findColorMatches(decoded, kCyanR, kCyanG, kCyanB, tolerance: 60);
  final chinMatches = findColorMatches(decoded, kMagentaR, kMagentaG, kMagentaB, tolerance: 60);
  final headC = centroidOf(headMatches);
  final chinC = centroidOf(chinMatches);

  return {
    'width': decoded.width,
    'height': decoded.height,
    'xDensity': density?.xDensity,
    'yDensity': density?.yDensity,
    'densityUnits': density?.units,
    'headTopYOut': headC?.y,
    'chinYOut': chinC?.y,
    'headCenterXOut': headC?.x,
    'chinCenterXOut': chinC?.x,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G2B compose evaluation', (tester) async {
    final harness = GateComposeHarness();
    final result = <String, dynamic>{};
    final errors = <String>[];

    // ---- 2B.1/2B.2/2B.3/2B.4/2B.5：7 个规格逐一 ----
    final specResults = <String, dynamic>{};
    final synthetic = buildSynthetic();
    for (final spec in kBuiltInSpecs) {
      try {
        final candidate = await harness.compose(
          matting: synthetic.matting,
          spec: spec,
          style: kBgWhite,
          face: synthetic.face,
          cropOverride: null,
        );
        final measured = _measureOutput(candidate.jpegBytes, spec);
        measured['expectedWidthPx'] = spec.widthPx;
        measured['expectedHeightPx'] = spec.heightPx;
        measured['expectedHeadTopRatio'] = spec.headTopRatio;
        measured['expectedHeadHeightRatio'] = spec.headHeightRatio;
        specResults[spec.id] = measured;
      } catch (e) {
        specResults[spec.id] = {'error': e.toString()};
      }
    }
    result['specs'] = specResults;

    // ---- 2B.6/2B.7：换纯绿/纯品红底，查溢色 ----
    final spillResults = <String, dynamic>{};
    const testGreen = BackgroundStyle(id: '_test_green', nameZh: '测试绿', colorTop: 0xFF00FF00);
    const testMagenta =
        BackgroundStyle(id: '_test_magenta', nameZh: '测试品红', colorTop: 0xFFFF00FF);
    try {
      final greenCandidate = await harness.compose(
        matting: synthetic.matting,
        spec: kSpecCn1inch,
        style: testGreen,
        face: synthetic.face,
        cropOverride: null,
      );
      final decoded = img.decodeJpg(greenCandidate.jpegBytes);
      var greenSpillCount = 0;
      if (decoded != null) {
        for (var y = 0; y < decoded.height; y++) {
          for (var x = 0; x < decoded.width; x++) {
            final p = decoded.getPixel(x, y);
            final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
            // 排除接近纯绿背景本身的像素，只在"非背景"（前景/边缘）区域查溢色。
            final isNearPureGreen = g > 200 && r < 100 && b < 100;
            if (!isNearPureGreen && (g - math.max(r, b)) > 40) {
              greenSpillCount++;
            }
          }
        }
      }
      spillResults['greenSpillCount'] = greenSpillCount;
    } catch (e) {
      spillResults['greenError'] = e.toString();
    }
    try {
      final magentaCandidate = await harness.compose(
        matting: synthetic.matting,
        spec: kSpecCn1inch,
        style: testMagenta,
        face: synthetic.face,
        cropOverride: null,
      );
      final decoded = img.decodeJpg(magentaCandidate.jpegBytes);
      var magentaSpillCount = 0;
      if (decoded != null) {
        for (var y = 0; y < decoded.height; y++) {
          for (var x = 0; x < decoded.width; x++) {
            final p = decoded.getPixel(x, y);
            final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
            final isNearPureMagenta = r > 200 && b > 200 && g < 100;
            if (!isNearPureMagenta && (math.min(r, b) - g) > 40) {
              magentaSpillCount++;
            }
          }
        }
      }
      spillResults['magentaSpillCount'] = magentaSpillCount;
    } catch (e) {
      spillResults['magentaError'] = e.toString();
    }
    result['spill'] = spillResults;

    // ---- 2B.8：摆正残差（±15°，须在 10° 死区外） ----
    final rollResults = <String, dynamic>{};
    for (final rollDeg in [15.0, -15.0]) {
      try {
        final rotatedSynthetic = buildSynthetic(rollDeg: rollDeg);
        final candidate = await harness.compose(
          matting: rotatedSynthetic.matting,
          spec: kSpecCn1inch,
          style: kBgWhite,
          face: rotatedSynthetic.face,
          cropOverride: null,
        );
        final decoded = img.decodeJpg(candidate.jpegBytes);
        if (decoded == null) {
          rollResults['$rollDeg'] = {'error': '输出解码失败'};
          continue;
        }
        final headMatches = findColorMatches(decoded, kCyanR, kCyanG, kCyanB, tolerance: 60);
        final residual = tiltAngleDeg(headMatches);
        rollResults['$rollDeg'] = {'residualDeg': residual};
      } catch (e) {
        rollResults['$rollDeg'] = {'error': e.toString()};
      }
    }
    result['roll'] = rollResults;

    // ---- 2B.9：边界安全 ----
    final edgeResult = <String, dynamic>{};
    try {
      final edgeCanvas = _buildCanvas();
      // 直接构造一个贴着左上角的合成图（不用旋转），headTop/chin 强行摆到 (2, 2)/(50,50) 附近。
      final edgeMatting = _toMattingResult(edgeCanvas);
      final edgeFace = const FaceInfo(
        box: Rect.fromLTWH(0, 0, 40, 50),
        chinY: 50,
        headTopY: 2,
        rollDeg: 0,
        confidence: 1.0,
      );
      final candidate = await harness.compose(
        matting: edgeMatting,
        spec: kSpecCn1inch,
        style: kBgWhite,
        face: edgeFace,
        cropOverride: null,
      );
      final decoded = img.decodeJpg(candidate.jpegBytes);
      edgeResult['threw'] = false;
      if (decoded != null) {
        var blackBorderPixels = 0;
        var borderTotal = 0;
        for (var x = 0; x < decoded.width; x++) {
          for (final y in [0, decoded.height - 1]) {
            borderTotal++;
            final p = decoded.getPixel(x, y);
            if (p.r.toInt() == 0 && p.g.toInt() == 0 && p.b.toInt() == 0) blackBorderPixels++;
          }
        }
        for (var y = 0; y < decoded.height; y++) {
          for (final x in [0, decoded.width - 1]) {
            borderTotal++;
            final p = decoded.getPixel(x, y);
            if (p.r.toInt() == 0 && p.g.toInt() == 0 && p.b.toInt() == 0) blackBorderPixels++;
          }
        }
        edgeResult['blackBorderRatio'] = borderTotal == 0 ? 0 : blackBorderPixels / borderTotal;
      }
    } catch (e) {
      edgeResult['threw'] = true;
      edgeResult['error'] = e.toString();
    }
    result['edgeSafety'] = edgeResult;

    result['errors'] = errors;

    // 走 flutter_driver 的 VM service 通道带回 host，见
    // integration_test/matting_eval_test.dart 头部注释和 docs/PITFALLS.md
    // 的 scoped storage 写权限踩坑记录。必须用 `flutter drive` 跑本文件。
    binding.reportData = result;
  }, timeout: const Timeout(Duration(minutes: 10)));
}
