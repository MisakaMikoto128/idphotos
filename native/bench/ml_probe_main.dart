// ml-porting 自用：设备端分段内存探针（4.7 滞留归因）。
//
// 构建运行（与 batch runner 同一套规程）：
//   flutter build apk --release --target=native/bench/ml_probe_main.dart
//   adb install -r ... ; adb shell am start -W --ez enable-impeller false \
//     -n com.muzhao.muzhao/.MainActivity
//   adb logcat -s muzhao.probe
//
// 依次打印 warmUp / 单次 removeBackground / detectFace / compose×6 之后
// 的 /proc/self/status VmRSS，并在每段后留 1.5s 给 GC。输出用于回答：
//   - 模拟器上实际生效的执行提供者；
//   - 抠图、检脸、合成各段的常驻/瞬时增量各占多少。
library;

import 'dart:io';
import 'package:flutter/widgets.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

const kQaDir =
    String.fromEnvironment('QA_DIR', defaultValue: '/data/local/tmp/muzhao_qa_tmp/in');

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

void _log(String tag) {
  final kb = _rssKb();
  debugPrint('PROBE $tag rss=${(kb / 1024).toStringAsFixed(1)}MB',
      wrapWidth: 200);
  // debugPrint 会被节流，直接写 stderr/logcat 同步通道更稳：
  // ignore: avoid_print
  print('PROBE $tag rss=${(kb / 1024).toStringAsFixed(1)}MB');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('start');
  final engine = IdPhotoEngineImpl();
  final t0 = Stopwatch()..start();
  await engine.warmUp();
  _log('warmUp(${t0.elapsedMilliseconds}ms) provider=${engine.mattingProvider}');
  final controller = MuZhaoController(engine);

  // 挑一个有代表性的：4032×3024 PNG（多脸）在 leak 曲线上出现过 528 峰值。
  final dir = Directory(kQaDir);
  File? png;
  File? small;
  await for (final f in dir.list()) {
    if (f is File && f.path.contains('1979d869')) png = f;
    if (f is File && f.path.contains('item_006')) small = f;
  }
  var target = png ?? small;
  if (target == null) {
    await for (final f in dir.list()) {
      if (f is File && !f.path.endsWith('json')) {
        target = f;
        break;
      }
    }
  }
  _log('input=${target!.path.split('/').last}');
  final bytes = await target.readAsBytes();

  final mat = await engine.removeBackground(bytes);
  _log('removeBackground#${mat.width}x${mat.height}');
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  _log('removeBackground+1.5s');

  final face = await engine.detectFace(bytes);
  _log('detectFace found=${face != null}');
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  _log('detectFace+1.5s');

  final spec = controller.currentState.spec;
  for (var i = 0; i < 6; i++) {
    await engine.compose(
        matting: mat,
        spec: spec,
        style: kBuiltInBackgrounds[i % kBuiltInBackgrounds.length],
        face: face);
    _log('compose#${i + 1}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  _log('compose+1.5s');

  // 连跑 5 轮整条链路（新 bytes 实例，模拟批量），看滞留。
  for (var r = 0; r < 5; r++) {
    final b2 = await target.readAsBytes();
    final m2 = await engine.removeBackground(b2);
    await engine.detectFace(b2);
    for (var i = 0; i < 6; i++) {
      await engine.compose(
          matting: m2,
          spec: spec,
          style: kBuiltInBackgrounds[i],
          face: face);
    }
    _log('round#$r');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _log('round#$r+0.8s');
  }
  await Future<void>.delayed(const Duration(seconds: 3));
  _log('end+3s');
  exit(0);
}
