// ml-porting 自用：G4 r3 4.7 探针——大图瞬态归因 + 修复前后 A/B。
//
// 构建运行（与 batch runner 同一套规程；换 --target 前必须 flutter clean，
// 见 PITFALLS「Windows 增量构建保留旧入口点」）：
//   flutter clean && flutter build apk --release --target=native/bench/ml_probe3_main.dart
//   adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-release.apk
//   adb -s emulator-5554 shell am start -W --ez enable-impeller false \
//     -n com.muzhao.muzhao/.MainActivity
//   adb -s emulator-5554 logcat -d -s flutter | grep PROBE3
//
// 输入（QA_DIR 下，文件名钉死，内容按 magic 嗅探与扩展名无关）：
//   mf.png   = 1979d869c783fcc849d4e05b81eb809e.png（4032×3024 multi_face）
//   pt1.jpg  = 29EDA59B982FA8339335D50B00CCD096.jpg（大图人像）
//   pt2.jpg  = 1 (2).jpg（2880×4982 大图人像）
//
// 回答四个问题（每个答案一行 PROBE3 日志）：
//   P1  旧路径（r7 HEAD 的 2048 工作分辨率 + rgba 进 worker + worker 转
//       rgb + worker 内跑人脸门槛）在 removeBackground 单步的瞬态峰值——
//       A/B 的"改前"基准；
//   P2  新路径（引擎 removeBackground：1536 工作分辨率 + 宿主预计算模型
//       输入，worker 只收 8MB Float32）单步瞬态峰值；
//   P3  新路径下 controller 全回合（removeBackground+detectFace+compose×6）
//       瞬态峰值——量化 compose 段份额（若大头在此，归因要转给 imaging）；
//   P4  churn 模拟：3 张大图轮换 12 回合、回合间 sleep 2.5s（与真机 leak
//       相位同构），50ms 采样，输出每回合峰/谷与进程 VmHWM。
//
// 采样口径：每回合重读文件（生产/批量 runner 每回合都是新 bytes 实例，
// 人脸门槛每回合真跑，不吃单槽缓存）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';
import 'package:muzhao/core/matting/flutter_decode.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/matting_worker.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

const kQaDir = String.fromEnvironment(
    'QA_DIR', defaultValue: '/data/local/tmp/muzhao_qa_tmp/in');

int _rssKb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]);
      }
    }
  } catch (_) {}
  return -1;
}

int _hwmKb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmHWM:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]);
      }
    }
  } catch (_) {}
  return -1;
}

void _log(String tag) {
  // ignore: avoid_print
  print('PROBE3 $tag rss=${(_rssKb() / 1024).toStringAsFixed(1)}'
      'MB hwm=${(_hwmKb() / 1024).toStringAsFixed(1)}MB');
}

/// 边跑边采样 RSS，返回相对起点的峰值增量（KB）。
Future<int> _peakKbWhile(Future<void> Function() body,
    {Duration step = const Duration(milliseconds: 20)}) async {
  var peak = 0;
  final base = _rssKb();
  final t = Timer.periodic(step, (_) {
    final v = _rssKb();
    if (v > peak) peak = v;
  });
  try {
    await body();
  } finally {
    t.cancel();
  }
  return peak - base;
}

Future<void> _settle([int ms = 800]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
}

// ---------------------------------------------------------------------------
// P1：旧路径复刻（r7 HEAD 行为）。刻意不调引擎方法，在探针里按 HEAD 的
// 实现重走一遍：2048 工作分辨率 + rgba 整份拷进 worker + worker 内
// rgbaToDecoded + worker 内跑 YuNet 门槛。runMattingAlphaOnly /
// rgbaToDecoded 都是现行公共实现，逐位复刻。
// ---------------------------------------------------------------------------

Future<void> runOldPath(
    Uint8List bytes, int session, int faceSession) async {
  final plan = planWorkingSize(bytes);
  if (plan == null) {
    throw StateError('P1 plan null');
  }
  // A/B 的"改前"必须钉在 2048 档（HEAD 行为），与当前代码的 1536 档无关。
  final long = plan.sourceWidth >= plan.sourceHeight
      ? plan.sourceWidth
      : plan.sourceHeight;
  final WorkingSizePlan p;
  if (long <= 2048) {
    p = plan;
  } else {
    final s = 2048 / long;
    p = WorkingSizePlan(
      (plan.sourceWidth * s).round().clamp(1, 2048),
      (plan.sourceHeight * s).round().clamp(1, 2048),
      plan.sourceWidth,
      plan.sourceHeight,
    );
  }
  final decoded = await decodeDownsampledUi(bytes, p.width, p.height);
  if (decoded == null) {
    // ignore: avoid_print
    print('PROBE3 P1 ui_decode=null');
    return;
  }
  final r = decoded.rgba;
  // HEAD 逐位复刻：rgba 整份进 worker，worker 内转 rgb、跑门槛、推理。
  await Isolate.run(() {
    return runMattingAlphaOnly(
      rgbaToDecoded(r, p.width, p.height,
          sourceWidth: p.sourceWidth, sourceHeight: p.sourceHeight),
      session,
      faceSessionAddress: faceSession,
    );
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('start');

  final inputs = <String, File>{};
  for (final n in const ['mf.png', 'pt1.jpg', 'pt2.jpg']) {
    final f = File('$kQaDir/$n');
    if (f.existsSync()) inputs[n] = f;
  }
  _log('inputs ${inputs.keys.toList().join(',')}');
  if (inputs.isEmpty) {
    // ignore: avoid_print
    print('PROBE3 MISSING all inputs');
    exit(0);
  }

  final engine = IdPhotoEngineImpl();
  await engine.warmUp();
  _log('warmUp provider=${engine.mattingProvider}');

  final controller = MuZhaoController(engine);

  Future<void> waitSettled() async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final s = controller.currentState;
      if (s.stage == Stage.ready || s.stage == Stage.error) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // P1 需要独立的会话地址；OrtEnv 每进程一次，直接 createSession 与引擎
  // 会话共享 env。模型文件经 resolveModelPath 从 assets 落地。
  final mattingPath = await ort.resolveModelPath(ort.kMattingModelAsset);
  final facePath = await ort.resolveModelPath(ort.kFaceModelAsset);
  final mattingSession = ort.createSession(mattingPath);
  final faceSession = ort.createSession(facePath, threads: 2);

  for (final e in inputs.entries) {
    // P1：旧路径（2048 + rgba 进 worker）
    await runOldPath(
        await e.value.readAsBytes(), mattingSession.address, faceSession.address);
    await _settle();
    var best = 1 << 40;
    for (var i = 0; i < 3; i++) {
      final b = await e.value.readAsBytes();
      final p = await _peakKbWhile(
          () => runOldPath(b, mattingSession.address, faceSession.address));
      if (p < best) best = p;
      await _settle();
    }
    // ignore: avoid_print
    print('PROBE3 P1 ${e.key} oldpath_peak=+${(best / 1024).toStringAsFixed(1)}MB'
        ' input=${(await e.value.length()) ~/ 1024}KB');

    // P2：新路径（引擎 removeBackground），每回合新 bytes 实例（真跑门槛）
    await engine.removeBackground(await e.value.readAsBytes());
    await _settle();
    best = 1 << 40;
    for (var i = 0; i < 3; i++) {
      final b = await e.value.readAsBytes();
      final p =
          await _peakKbWhile(() => engine.removeBackground(b));
      if (p < best) best = p;
      await _settle();
    }
    // ignore: avoid_print
    print('PROBE3 P2 ${e.key} newpath_peak=+${(best / 1024).toStringAsFixed(1)}MB');

    // P3：controller 全回合（removeBackground + detectFace + compose×6）
    await controller.loadImage(await e.value.readAsBytes());
    await waitSettled();
    await _settle();
    best = 1 << 40;
    for (var i = 0; i < 3; i++) {
      final b = await e.value.readAsBytes();
      final p = await _peakKbWhile(() async {
        await controller.loadImage(b);
        await waitSettled();
      }, step: const Duration(milliseconds: 50));
      if (p < best) best = p;
      await _settle();
    }
    // ignore: avoid_print
    print('PROBE3 P3 ${e.key} full_round_peak=+${(best / 1024).toStringAsFixed(1)}MB');
  }

  // P4：churn 模拟（真机 leak 相位同构：轮换 12 回合，回合间 2.5s）
  _log('P4 churn begin');
  final order = inputs.keys.toList();
  for (var r = 0; r < 12; r++) {
    final name = order[r % order.length];
    final b = await inputs[name]!.readAsBytes();
    final t0 = DateTime.now();
    final p = await _peakKbWhile(() async {
      await controller.loadImage(b);
      await waitSettled();
    }, step: const Duration(milliseconds: 50));
    // ignore: avoid_print
    print('PROBE3 P4 round=$r item=$name peak=+${(p / 1024).toStringAsFixed(1)}MB'
        ' abs=${(_rssKb() / 1024).toStringAsFixed(1)}MB'
        ' ms=${DateTime.now().difference(t0).inMilliseconds}');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
  }
  _log('P4 churn end');
  engine.dispose();
  await _settle(1500);
  _log('end');
  exit(0);
}
