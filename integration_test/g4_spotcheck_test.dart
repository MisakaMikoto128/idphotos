// integration_test/g4_spotcheck_test.dart
//
// G4 的设备端抽查 harness（gatekeeper 所有）。**只产出原始测量数据**
// （binding.reportData → build/integration_response_data.json），阈值判定
// 与"是否与裁判记录一致"全部留在 tools/gate/gate_G4.dart（host 侧）——裁判不下场。
//
// 用途：gate_G4 不只信 qa-batch/adversarial 的汇总 JSON，而是随机抽样后在
// 自己的设备会话里经真实 IdPhotoEngineImpl + MuZhaoController 复跑：
//   - batch 抽查项（category=portrait / non_portrait）：走完整 controller
//     链路 loadImage → ready/error，记录 stage、中文 errorMessage、候选数、
//     候选 JPEG 可解码数。非人像的"像失败而非像成功"就靠这里核实：
//     必须是 error + 中文提示 + 0 候选，不能"神奇地出图"。
//   - adversarial 抽查项（category=adversarial）：同样复跑，落定即算处理过；
//     整个 drive 进程崩溃 = host 侧直接 FAIL；单条 90s 未落定记 unresponsive。
//
// 输入：host `adb push` 的 manifest（$GATE_TMP_DIR/g4_spot/manifest.json），
// 每项 {id, deviceName, sourcePath, category}。文件在 $GATE_TMP_DIR/g4_spot/。
// 附带产出：512×512 抠图计时采样（黄金集 g01 resize，4.6 的 gate 复测数据）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

const String kGateTmpDir = String.fromEnvironment(
  'GATE_TMP_DIR',
  defaultValue: '/data/local/tmp/muzhao_gate_tmp',
);

/// 单条抽查的最长等待。超过 = unresponsive（"无响应"的 gate 复跑口径）。
const Duration kPerItemTimeout = Duration(seconds: 90);

final RegExp _cjk = RegExp(r'[一-鿿]');

Future<AppState> _waitSettled(MuZhaoController c, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  AppState last = c.currentState;
  while (DateTime.now().isBefore(deadline)) {
    last = c.currentState;
    if (last.stage == Stage.ready || last.stage == Stage.error) return last;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return last; // 超时：调用方检查 stage 判 unresponsive
}

Future<Map<String, dynamic>> _runOneItem(Map<String, dynamic> entry) async {
  final deviceFile = File('$kGateTmpDir/g4_spot/${entry['deviceName']}');
  final rec = <String, dynamic>{
    'id': entry['id'],
    'sourcePath': entry['sourcePath'],
    'category': entry['category'],
  };

  Uint8List bytes;
  try {
    bytes = await deviceFile.readAsBytes();
  } catch (e) {
    rec['stage'] = 'input_error';
    rec['unresponsive'] = false;
    rec['error'] = '读输入失败: $e';
    return rec;
  }

  final sw = Stopwatch()..start();
  IdPhotoEngineImpl? engine;
  MuZhaoController? controller;
  Object? uncaught;
  try {
    // 每项独立 engine + controller：一项把引擎状态搞坏不会污染下一项。
    engine = IdPhotoEngineImpl();
    controller = MuZhaoController(engine);
    await controller.loadImage(bytes);
    final settled = await _waitSettled(controller, kPerItemTimeout);
    sw.stop();
    rec['ms'] = sw.elapsedMilliseconds;
    rec['stage'] = settled.stage.name;
    rec['unresponsive'] =
        settled.stage != Stage.ready && settled.stage != Stage.error;
    rec['errorMessage'] = settled.errorMessage;
    rec['chineseError'] = settled.errorMessage != null &&
        _cjk.hasMatch(settled.errorMessage!);
    rec['candidateCount'] = settled.candidates.length;

    // 人像成功态：逐张候选解码（可解码数=0 说明"产出"是坏数据）。
    var decoded = 0;
    for (final c in settled.candidates) {
      try {
        if (img.decodeJpg(c.jpegBytes) != null) decoded++;
      } catch (_) {
        // 解码失败计 0，不让解码异常逃出 harness
      }
    }
    rec['candidatesDecoded'] = decoded;
  } catch (e) {
    sw.stop();
    rec['ms'] = sw.elapsedMilliseconds;
    rec['stage'] = 'uncaught';
    rec['unresponsive'] = false;
    rec['chineseError'] = false;
    rec['candidateCount'] = 0;
    rec['candidatesDecoded'] = 0;
    rec['error'] = '未捕获异常: ${e.runtimeType}: $e';
    uncaught = e;
  } finally {
    try {
      controller?.dispose();
    } catch (_) {// dispose 失败不影响测量记录
    }
    try {
      engine?.dispose();
    } catch (_) {// 同上
    }
  }
  if (uncaught != null) rec['uncaught'] = true;
  return rec;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G4 spot-check evaluation', (tester) async {
    final result = <String, dynamic>{};
    final errors = <String>[];

    // ---- Part 1：抽查复跑 ----
    final manifestFile = File('$kGateTmpDir/g4_spot/manifest.json');
    if (!await manifestFile.exists()) {
      errors.add('host 未 push $kGateTmpDir/g4_spot/manifest.json');
      result['items'] = [];
    } else {
      final manifest =
          (jsonDecode(await manifestFile.readAsString()) as List)
              .whereType<Map<String, dynamic>>()
              .toList();
      final items = <Map<String, dynamic>>[];
      for (final entry in manifest) {
        items.add(await _runOneItem(entry));
      }
      result['items'] = items;
    }

    // ---- Part 2：512×512 计时采样（4.6 的 gate 复测数据）----
    final timingSamplesMs = <int>[];
    final g01File = File('$kGateTmpDir/golden/src/g01.jpg');
    if (!await g01File.exists()) {
      errors.add('host 未 push $kGateTmpDir/golden/src/g01.jpg（512² 计时无输入）');
    } else {
      try {
        final engine = IdPhotoEngineImpl();
        await engine.warmUp();
        final decoded = img.decodeImage(await g01File.readAsBytes());
        if (decoded == null) {
          errors.add('g01.jpg 解码失败，512² 计时无采样');
        } else {
          final resized = img.copyResize(decoded, width: 512, height: 512);
          final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 90));
          for (var i = 0; i < 10; i++) {
            final sw = Stopwatch()..start();
            await engine.removeBackground(jpg);
            sw.stop();
            timingSamplesMs.add(sw.elapsedMilliseconds);
          }
        }
        engine.dispose();
      } catch (e) {
        errors.add('512² 计时采样失败: $e');
      }
    }
    result['timing512SamplesMs'] = timingSamplesMs;
    result['errors'] = errors;

    binding.reportData = result;
  }, timeout: const Timeout(Duration(minutes: 25)));
}
