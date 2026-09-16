// integration_test/g4_memcheck_test.dart
//
// G4 的设备端内存复测 harness（gatekeeper 所有）。**只产出原始测量数据**，
// 判定（≤450MB / 20 张后回落基线+80MB）留在 tools/gate/gate_G4.dart。
//
// 时序（host 侧采样脚本依赖这个节奏，改时序要同步改 gate_G4._memcheckWithSampling）：
//   1. loadImage(g01) 等落定（预热，模型/首帧成本在这里消化）
//   2. 空闲 14s         ← host 基线窗：churn 起点前 14s 内采样点取中位
//   3. churn：连续 loadImage 同一张图 20 次，每次等落定
//   4. 空闲 12s         ← host 收尾窗：after = 末尾 12s 采样点中位；峰值 = 全程最大
//   5. report churnDone=true
//
// 另附设备侧自证：读 /proc/self/status 的 VmRSS/VmHWM（churn 前后各一次），
// 与 host 的 dumpsys PSS 口径互为印证。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

const String kGateTmpDir = String.fromEnvironment(
  'GATE_TMP_DIR',
  defaultValue: '/data/local/tmp/muzhao_gate_tmp',
);

const int kChurnCount = 20;

Future<AppState> _waitSettled(MuZhaoController c, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  AppState last = c.currentState;
  while (DateTime.now().isBefore(deadline)) {
    last = c.currentState;
    if (last.stage == Stage.ready || last.stage == Stage.error) return last;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return last;
}

Map<String, int>? _readProcStatus() {
  try {
    final text = File('/proc/self/status').readAsStringSync();
    int? field(String name) {
      final m = RegExp('$name\\s*:\\s*(\\d+)').firstMatch(text);
      return m == null ? null : int.parse(m.group(1)!);
    }

    final rss = field('VmRSS');
    final hwm = field('VmHWM');
    if (rss == null || hwm == null) return null;
    return {'vmRssKb': rss, 'vmHwmKb': hwm};
  } catch (_) {
    return null; // /proc 不可读时由 host 侧 dumpsys 单独作证
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G4 memory churn evaluation', (tester) async {
    final result = <String, dynamic>{};
    final errors = <String>[];

    final g01File = File('$kGateTmpDir/golden/src/g01.jpg');
    if (!await g01File.exists()) {
      errors.add('host 未 push $kGateTmpDir/golden/src/g01.jpg');
      result['errors'] = errors;
      binding.reportData = result;
      return;
    }
    final bytes = await g01File.readAsBytes();

    final engine = IdPhotoEngineImpl();
    final controller = MuZhaoController(engine);
    try {
      // 1. 预热。
      await controller.loadImage(bytes);
      final warmed = await _waitSettled(controller, const Duration(minutes: 5));
      result['warmStage'] = warmed.stage.name;
      if (warmed.stage != Stage.ready && warmed.stage != Stage.error) {
        errors.add('预热未落定（stage=${warmed.stage.name}），内存数据不可信');
      }

      // 2. 基线空闲窗（14s：host 侧 dumpsys 采样节奏 ~1.7-2.2s/点，14s 保证
      //    基线窗内有 ≥6 个稳态采样点，且不会被预热爬坡段污染——host 用
      //    churnItemsMs 反推 churn 起点再回退本窗口取中位，见 gate_G4.dart）。
      result['procBeforeChurn'] = _readProcStatus();
      await Future<void>.delayed(const Duration(seconds: 14));

      // 3. churn 20 张。
      final itemsMs = <int>[];
      var unresponsive = 0;
      for (var i = 0; i < kChurnCount; i++) {
        final sw = Stopwatch()..start();
        await controller.loadImage(bytes);
        final settled = await _waitSettled(controller, const Duration(minutes: 2));
        sw.stop();
        itemsMs.add(sw.elapsedMilliseconds);
        if (settled.stage != Stage.ready && settled.stage != Stage.error) {
          unresponsive++;
        }
      }
      result['churnItemsMs'] = itemsMs;
      result['churnUnresponsive'] = unresponsive;

      // 4. 收尾空闲窗。
      await Future<void>.delayed(const Duration(seconds: 12));
      result['procAfterChurn'] = _readProcStatus();

      result['churnDone'] = true;
      result['churnCount'] = kChurnCount;
    } catch (e) {
      errors.add('churn 过程异常: ${e.runtimeType}: $e');
      result['churnDone'] = false;
    } finally {
      try {
        controller.dispose();
      } catch (_) {// 忽略
      }
      try {
        engine.dispose();
      } catch (_) {// 忽略
      }
    }

    result['errors'] = errors;
    binding.reportData = result;
  }, timeout: const Timeout(Duration(minutes: 20)));
}
