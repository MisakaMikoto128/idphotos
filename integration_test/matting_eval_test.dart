// integration_test/matting_eval_test.dart
//
// G2A 的设备端评测代码。onnxruntime 走平台通道，纯 `dart run` 摸不到，
// 必须在真机/模拟器里跑。本文件**只产出原始测量数据**（JSON 写到设备
// 外部存储），阈值判定全部留给 `tools/gate/gate_G2A.dart`（host 侧）——
// 裁判不下场，设备端代码不做 PASS/FAIL 判断，只做测量。
//
// 依赖一个"胶水"类 `GateMattingHarness`（`with MattingEngineMixin`），
// 由 `tools/gate/device_harness_common.dart` 在每轮跑 gate 前扫描
// `lib/core/matting/` 自动生成到 `_generated_matting_harness.dart`。
// 此刻（阶段 2 刚开始）ml-porting 还没交付，生成的文件会 import 不存在的路径，
// 本文件因此编译不过——这是预期状态，见 gatekeeper 报告。
//
// 输入数据（黄金集 + Pictures 全量数据集）通过 `adb push` 送到设备端目录，
// 目录路径用 `--dart-define=GATE_TMP_DIR=...` 从 host 注入，避免设备端代码
// 硬编码 applicationId。
//
// 环带（G2A.5）算法说明：对 ref 二值 mask 做"是否是边界像素"标记
// （与右邻居或下邻居值不同即为边界），再做 5 轮 8-邻域膨胀（Chebyshev 距离近似），
// 得到 ±5px 环带。8-邻域膨胀是 Chebyshev 距离，不是严格欧氏距离，
// 但对"边界带"这种用途足够，且实现和性能都可控。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/api.dart' show FaceInfo;

import '../tools/gate/png_utils.dart';
import '_generated_matting_harness.dart';

const String kGateTmpDir =
    String.fromEnvironment('GATE_TMP_DIR', defaultValue: '/sdcard/muzhao_gate_tmp');

/// 8 邻域一轮膨胀。
List<bool> _dilateOnce(List<bool> mask, int w, int h) {
  final out = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = mask[y * w + x];
      if (!v) {
        for (var dy = -1; dy <= 1 && !v; dy++) {
          for (var dx = -1; dx <= 1 && !v; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            if (mask[ny * w + nx]) v = true;
          }
        }
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

/// 从 ref 二值 mask 算 ±5px 环带（bool 数组，true=在环带内）。
List<bool> _edgeBand(List<bool> refBinary, int w, int h, {int radiusPx = 5}) {
  var boundary = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = refBinary[y * w + x];
      final right = x + 1 < w ? refBinary[y * w + x + 1] : v;
      final down = y + 1 < h ? refBinary[(y + 1) * w + x] : v;
      if (v != right || v != down) boundary[y * w + x] = true;
    }
  }
  for (var i = 0; i < radiusPx; i++) {
    boundary = _dilateOnce(boundary, w, h);
  }
  return boundary;
}

/// 把 ref PNG（灰度或带 alpha）解码成与 [w]x[h] 对齐的二值 mask（>=128 为前景）。
List<bool> _refToBinary(DecodedPng png, int threshold) {
  final out = List<bool>.filled(png.width * png.height, false);
  for (var y = 0; y < png.height; y++) {
    for (var x = 0; x < png.width; x++) {
      out[y * png.width + x] = png.grayOrAlpha(x, y) >= threshold;
    }
  }
  return out;
}

Future<Map<String, dynamic>> _evalOneGolden(
  GateMattingHarness harness,
  String stem,
  Uint8List srcBytes,
  DecodedPng refPng,
) async {
  final sw = Stopwatch()..start();
  final matting = await harness.removeBackground(srcBytes);
  sw.stop();

  if (matting.width != refPng.width || matting.height != refPng.height) {
    return {
      'error': '预测尺寸(${matting.width}x${matting.height}) 与参考('
          '${refPng.width}x${refPng.height}) 不一致，无法逐像素比对',
      'timeMs': sw.elapsedMilliseconds,
    };
  }

  final w = matting.width, h = matting.height;
  final refBinary = _refToBinary(refPng, 128);
  final band = _edgeBand(refBinary, w, h, radiusPx: 5);

  var interArea = 0, unionArea = 0;
  double sumAbsDiff = 0;
  double bandSumAbsDiff = 0;
  var bandCount = 0;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      final predBin = matting.alpha[idx] >= 128;
      final refBin = refBinary[idx];
      if (predBin && refBin) interArea++;
      if (predBin || refBin) unionArea++;

      final predNorm = matting.alpha[idx] / 255.0;
      final refNorm = refPng.grayOrAlpha(x, y) / 255.0;
      final diff = (predNorm - refNorm).abs();
      sumAbsDiff += diff;
      if (band[idx]) {
        bandSumAbsDiff += diff;
        bandCount++;
      }
    }
  }

  final iou = unionArea == 0 ? 1.0 : interArea / unionArea;
  final mae = sumAbsDiff / (w * h);
  final edgeMae = bandCount == 0 ? 0.0 : bandSumAbsDiff / bandCount;

  FaceInfo? face;
  Object? faceError;
  try {
    face = await harness.detectFace(srcBytes);
  } catch (e) {
    faceError = e;
  }

  return {
    'iou': iou,
    'mae': mae,
    'edgeMae': edgeMae,
    'timeMs': sw.elapsedMilliseconds,
    'faceDetected': face != null,
    'chinY': face?.chinY,
    'headTopY': face?.headTopY,
    'faceError': faceError?.toString(),
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G2A matting evaluation', (tester) async {
    final harness = GateMattingHarness();
    await harness.warmUp();

    final result = <String, dynamic>{};
    final errors = <String>[];

    // ---- 黄金集：2A.3/2A.4/2A.5/2A.8 ----
    final srcDir = Directory('$kGateTmpDir/golden/src');
    final refDir = Directory('$kGateTmpDir/golden/ref');
    final goldenResults = <String, dynamic>{};
    if (await srcDir.exists() && await refDir.exists()) {
      final srcFiles = await srcDir.list().where((e) => e.path.endsWith('.jpg')).toList();
      srcFiles.sort((a, b) => a.path.compareTo(b.path));
      for (final f in srcFiles) {
        final backslash = String.fromCharCode(92);
        final name = f.path.replaceAll(backslash, '/').split('/').last;
        final stem = name.substring(0, name.length - 4);
        final refFile = File('${refDir.path}/$stem.png');
        if (!await refFile.exists()) {
          errors.add('golden $stem 缺少参考文件');
          continue;
        }
        try {
          final srcBytes = await File(f.path).readAsBytes();
          final refBytes = await refFile.readAsBytes();
          final refPng = decodePng(refBytes);
          goldenResults[stem] = await _evalOneGolden(harness, stem, srcBytes, refPng);
        } catch (e) {
          goldenResults[stem] = {'error': e.toString()};
        }
      }
    } else {
      errors.add('设备上没有 $kGateTmpDir/golden，host 侧没有 adb push 黄金集');
    }
    result['golden'] = goldenResults;

    // ---- 2A.6：512x512 耗时 p95（用黄金集图片各 resize 一次，重复采样） ----
    final timingSamplesMs = <int>[];
    if (await srcDir.exists()) {
      final srcFiles = await srcDir.list().where((e) => e.path.endsWith('.jpg')).toList();
      for (final f in srcFiles) {
        try {
          final bytes = await File(f.path).readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded == null) continue;
          final resized = img.copyResize(decoded, width: 512, height: 512);
          final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 90));
          for (var i = 0; i < 3; i++) {
            final sw = Stopwatch()..start();
            await harness.removeBackground(jpg);
            sw.stop();
            timingSamplesMs.add(sw.elapsedMilliseconds);
          }
        } catch (e) {
          errors.add('512x512 计时用例失败: $e');
        }
      }
    }
    result['timing512SamplesMs'] = timingSamplesMs;

    // ---- 2A.7：全量数据集鲁棒性 ----
    final datasetDir = Directory('$kGateTmpDir/dataset');
    final manifestFile = File('$kGateTmpDir/dataset_manifest.json');
    final datasetResults = <Map<String, dynamic>>[];
    if (await datasetDir.exists() && await manifestFile.exists()) {
      final manifest = jsonDecode(await manifestFile.readAsString()) as List<dynamic>;
      for (final item in manifest) {
        final m = item as Map<String, dynamic>;
        final deviceFile = File('${datasetDir.path}/${m['deviceName']}');
        final entry = <String, dynamic>{
          'sourcePath': m['sourcePath'],
          'category': m['category'],
        };
        if (!await deviceFile.exists()) {
          entry['skipped'] = 'push 缺失';
          datasetResults.add(entry);
          continue;
        }
        Uint8List bytes;
        try {
          bytes = await deviceFile.readAsBytes();
        } catch (e) {
          entry['skipped'] = '读取失败: $e';
          datasetResults.add(entry);
          continue;
        }

        try {
          final face = await harness.detectFace(bytes);
          entry['detectFaceOutcome'] = face == null ? 'null' : 'face';
        } catch (e) {
          entry['detectFaceOutcome'] = 'exception:${e.runtimeType}';
        }

        try {
          await harness.removeBackground(bytes);
          entry['mattingOutcome'] = 'ok';
        } catch (e) {
          entry['mattingOutcome'] = 'exception:${e.runtimeType}';
        }

        datasetResults.add(entry);
      }
    } else {
      errors.add('设备上没有 $kGateTmpDir/dataset 或 manifest，host 侧没有 push 数据集');
    }
    result['dataset'] = datasetResults;
    result['errors'] = errors;

    final outFile = File('$kGateTmpDir/g2a_results.json');
    await outFile.parent.create(recursive: true);
    await outFile.writeAsString(jsonEncode(result));

    // 本文件不做阈值判断，只要能跑完写出文件就算"设备端流程成功"。
    expect(await outFile.exists(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
