// integration_test/e2e_eval_test.dart
//
// G3 端到端评测（阶段 3 出口）。**设备端测量代码**：只产出原始测量数据
// （binding.reportData → build/integration_response_data.json），阈值判定
// 全部留在 tools/gate/gate_G3.dart（裁判不下场）。
//
// 与 G2A/G2B 的单 mixin 评测不同，本文件走**真实装配**：
//   - `IdPhotoEngineImpl`（真实 onnxruntime 推理 + 真实合成，不用任何 harness 桩）
//   - `MuZhaoController`（接线层编排：loadImage → 检脸 → 自动框选 → setSpec 逐规格重合成）
//
// 流程：
//   1. 读 host `adb push` 到 $GATE_TMP_DIR/golden/src/g01.jpg 的黄金集第一张
//   2. controller.loadImage → 等 Stage.ready
//   3. 7 个内置规格逐一 setSpec → 等 ready → 每规格收 6 底色候选 = 42 张
//   4. 每张候选解码测 width/height + JFIF DPI（3.2 的 2B.1/2B.2 原始数据）
//   5. controller.save(候选) → 记录落盘路径/存在性/可解码性（3.3 原始数据）
//   6. 引擎侧对同一张图再推理一次，7 规格各合成纯绿/纯白两份，
//      做"绿底减白底基线校正"的溢色计数（3.2 的 2B.6 原始数据）
//
// 2B.6 在真实照片上的口径（与 G2B 合成人像的绝对计数不同，见 imaging 在
// docs/PITFALLS.md 的踩坑记录——真实人像自带绿色衣物会造成绝对计数的假阳性）：
//   前景区域 = 绿底成片中"非近纯绿"像素（与 G2B 官方评测同口径的背景排除）；
//   每像素溢色量 = (G−max(R,B))_绿底 − (G−max(R,B))_白底 > 40 计 1。
//   白底成片同 crop 同几何（compose 对相同入参确定性输出，两份尺寸必须一致，
//   不一致直接记 error），逐像素相减后"被摄者天然的颜色"被消掉，
//   只剩真正由绿底渗进前景的成分 —— 这是"溢色 = 底色渗进前景"的忠实实现。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

import '../tools/gate/jpeg_utils.dart';

const String kGateTmpDir = String.fromEnvironment(
  'GATE_TMP_DIR',
  defaultValue: '/data/local/tmp/muzhao_gate_tmp',
);

/// 2B.6 用的测试底色：纯绿（不是 CONTRACTS 第 5 节的内置底色）。
const BackgroundStyle kTestGreen =
    BackgroundStyle(id: '_test_green', nameZh: '测试绿', colorTop: 0xFF00FF00);

/// 轮询直到 controller 进入 ready / error，或超时。
/// integration_test 用 LiveTestWidgetsFlutterBinding，真实时间真实 Timer，
/// controller 的 300ms 去抖计时器会自然触发，直接轮询即可。
Future<AppState> _waitSettled(MuZhaoController c, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  var last = c.currentState;
  while (DateTime.now().isBefore(deadline)) {
    last = c.currentState;
    if (last.stage == Stage.ready || last.stage == Stage.error) return last;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return last; // 超时：调用方检查 stage 自己定论
}

/// 解码一张候选 JPEG 并测尺寸 + JFIF DPI。不抛异常，失败记 error。
Map<String, dynamic> _measureCandidate(Uint8List jpegBytes) {
  final out = <String, dynamic>{'byteLen': jpegBytes.length};
  final decoded = img.decodeJpg(jpegBytes);
  if (decoded == null) {
    out['decoded'] = false;
    return out;
  }
  out['decoded'] = true;
  out['width'] = decoded.width;
  out['height'] = decoded.height;
  JfifDensity? density;
  try {
    density = readJfifDensity(jpegBytes);
  } catch (e) {
    out['densityError'] = e.toString();
  }
  if (density != null) {
    out['xDensity'] = density.xDensity;
    out['yDensity'] = density.yDensity;
    out['units'] = density.units;
  }
  return out;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G3 e2e evaluation', (tester) async {
    final result = <String, dynamic>{};
    final errors = <String>[];

    // ---- 输入：黄金集第一张 ----
    final src = File('$kGateTmpDir/golden/src/g01.jpg');
    if (!await src.exists()) {
      errors.add('输入不存在: ${src.path}（host 未 adb push 黄金集）');
      result['errors'] = errors;
      binding.reportData = result;
      return;
    }
    final g01 = await src.readAsBytes();
    result['input'] = {'path': src.path, 'byteLen': g01.length};

    // ---- Part 1：controller 端到端（3.1 / 3.2 尺寸与 DPI / 3.3 保存）----
    final engine = IdPhotoEngineImpl();
    final controller = MuZhaoController(engine);
    try {
      final swLoad = Stopwatch()..start();
      await controller.loadImage(g01);
      final loaded = await _waitSettled(controller, const Duration(minutes: 12));
      swLoad.stop();
      result['loadImage'] = {
        'ms': swLoad.elapsedMilliseconds,
        'stage': loaded.stage.name,
        'errorMessage': loaded.errorMessage,
        'candidateCount': loaded.candidates.length,
        'suggestedCrop': loaded.suggestedCrop == null
            ? null
            : {
                'left': loaded.suggestedCrop!.left,
                'top': loaded.suggestedCrop!.top,
                'width': loaded.suggestedCrop!.width,
                'height': loaded.suggestedCrop!.height,
              },
      };

      // ---- 7 规格 × 6 底色 = 42 张 ----
      final specResults = <String, dynamic>{};
      var produced = 0;
      for (final spec in kBuiltInSpecs) {
        AppState s;
        final sw = Stopwatch()..start();
        if (controller.currentState.spec.id != spec.id) {
          controller.setSpec(spec);
          s = await _waitSettled(controller, const Duration(minutes: 8));
        } else {
          // loadImage 的默认规格就是这个：候选已就绪，直接采集。
          s = controller.currentState;
        }
        sw.stop();

        final candidateList = <Map<String, dynamic>>[];
        for (final c in s.candidates) {
          candidateList.add(_measureCandidate(c.jpegBytes));
        }
        produced += s.candidates.length;
        specResults[spec.id] = {
          'stage': s.stage.name,
          'errorMessage': s.errorMessage,
          'recomposeMs': sw.elapsedMilliseconds,
          'styleIds': s.candidates.map((c) => c.style.id).toList(),
          'candidates': candidateList,
        };
      }
      result['specs'] = specResults;
      result['producedCount'] = produced;

      // ---- 3.3 保存（对最后一个就绪规格的第一个候选）----
      final readyState = controller.currentState;
      if (readyState.candidates.isNotEmpty) {
        final swSave = Stopwatch()..start();
        try {
          final path = await controller.save(readyState.candidates.first);
          swSave.stop();
          final f = File(path);
          final exists = await f.exists();
          final saveInfo = <String, dynamic>{
            'path': path,
            'exists': exists,
            'saveMs': swSave.elapsedMilliseconds,
          };
          if (exists) {
            final bytes = await f.readAsBytes();
            saveInfo['byteLen'] = bytes.length;
            final decoded = img.decodeJpg(bytes);
            saveInfo['decoded'] = decoded != null;
            if (decoded != null) {
              saveInfo['decodedWidth'] = decoded.width;
              saveInfo['decodedHeight'] = decoded.height;
            }
          }
          result['save'] = saveInfo;
        } catch (e) {
          result['save'] = {
            'path': null,
            'error': e.toString(),
            'saveMs': swSave.elapsedMilliseconds,
          };
        }
      } else {
        result['save'] = {'error': '没有可保存的候选（前面环节未产出）'};
      }
    } catch (e) {
      errors.add('controller 端到端流程异常: $e');
    }

    // ---- Part 2：引擎侧绿底溢色（3.2 的 2B.6 原始数据）----
    try {
      final swMat = Stopwatch()..start();
      final mat = await engine.removeBackground(g01);
      swMat.stop();
      final face = await engine.detectFace(g01);
      result['engineSide'] = {
        'removeBackgroundMs': swMat.elapsedMilliseconds,
        'mattingSize': '${mat.width}x${mat.height}',
        'faceDetected': face != null,
        'chinY': face?.chinY,
        'headTopY': face?.headTopY,
      };

      final spillResults = <String, dynamic>{};
      for (final spec in kBuiltInSpecs) {
        final rec = <String, dynamic>{};
        try {
          final green = await engine.compose(
              matting: mat, spec: spec, style: kTestGreen, face: face);
          final white = await engine.compose(
              matting: mat, spec: spec, style: kBgWhite, face: face);
          final dg = img.decodeJpg(green.jpegBytes);
          final dw = img.decodeJpg(white.jpegBytes);
          if (dg == null || dw == null) {
            rec['error'] = '绿/白成片解码失败(green=${dg != null}, white=${dw != null})';
          } else if (dg.width != dw.width || dg.height != dw.height) {
            rec['error'] =
                '绿/白成片尺寸不一致: ${dg.width}x${dg.height} vs ${dw.width}x${dw.height}';
          } else {
            var count = 0;
            var foregroundSampled = 0;
            for (var y = 0; y < dg.height; y++) {
              for (var x = 0; x < dg.width; x++) {
                final pg = dg.getPixel(x, y);
                final gr = pg.r.toInt(), gg = pg.g.toInt(), gb = pg.b.toInt();
                // 与 G2B 官方评测同口径的背景排除：接近纯绿底本身的像素不算。
                final isNearPureGreen = gg > 200 && gr < 100 && gb < 100;
                if (isNearPureGreen) continue;
                foregroundSampled++;
                final pw = dw.getPixel(x, y);
                final excessGreen = (gg - math.max(gr, gb)) -
                    (pw.g.toInt() - math.max(pw.r.toInt(), pw.b.toInt()));
                if (excessGreen > 40) count++;
              }
            }
            rec['spillCount'] = count;
            rec['foregroundSampled'] = foregroundSampled;
            rec['size'] = '${dg.width}x${dg.height}';
          }
        } catch (e) {
          rec['error'] = e.toString();
        }
        spillResults[spec.id] = rec;
      }
      result['greenSpill'] = spillResults;
    } catch (e) {
      errors.add('引擎侧溢色评测异常: $e');
    }

    result['errors'] = errors;
    binding.reportData = result;
  }, timeout: const Timeout(Duration(minutes: 30)));
}
