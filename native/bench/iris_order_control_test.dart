// ml-porting 自用：**次序不变性对照的对照**。
//
// 起因：G 段那条"打乱候选后输出必须逐条相同"跑在真实引擎上，报 0/124 差异。
// 但引擎把瞳孔估计放在 `Isolate.run` 里，全局开关默认不跨 isolate——一个
// "没接线"的对照和一个"真的不变"的对照，报出来是同一个 0。要区分二者，
// 必须有一个**已知会变红**的正向对照。
//
// 这个文件绕开 isolate：直接调生产函数 `estimatePupilRoll`，四种配置在同一
// isolate 内跑同一份灰度平面与同一组种子，逐条比较：
//   plain            生产规则
//   shuffle          生产规则 + 打乱候选
//   greedy           改造前的贪心分组（且不排序，故意做成依赖次序）
//   greedy+shuffle   同上 + 打乱
// 判读：
//   · greedy vs greedy+shuffle **必须**有差异，否则说明打乱这条路本身没生效，
//     plain vs shuffle 的 0 也就没有证据力；
//   · plain vs shuffle 的差异数才是"生产规则与次序无关"的实测支持。
//
// 跑法：flutter test native/bench/iris_order_control_test.dart
@Timeout(Duration(minutes: 40))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/iris_roll.dart';
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

class _Engine with MattingEngineMixin {
  void dispose() {
    disposeMattingEngine();
  }
}

String _fmt(PupilRoll r) =>
    r.available ? r.rollDeg.toStringAsFixed(9) : 'unavail(${r.reason})';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';
  _preloadHostOnnxRuntime();
  final engine = _Engine();

  test('次序对照：直接调生产函数，四配置逐条比对', () async {
    await engine.warmUp();
    // 目标面尽量宽：门禁夹具（含被旋转过的）+ 真实语料。样本太窄的话
    // "0 差异"什么也说明不了。
    final List<String> targets = <String>[
      r'C:\Users\liuyu\Pictures\2.jpg',
      r'C:\Users\liuyu\Pictures\1 (2).jpg',
      for (var i = 1; i <= 8; i++) 'test/golden/src/g0$i.jpg',
    ];
    final File truthFile = File('out/P0_truth.json');
    if (truthFile.existsSync()) {
      final Map<String, dynamic> truth =
          jsonDecode(truthFile.readAsStringSync()) as Map<String, dynamic>;
      for (final dynamic a
          in (truth['anchors'] as List<dynamic>?) ?? <dynamic>[]) {
        // 用原图 path，不用 out/P0_anchors/<id>.png（那是缩略 evidence）。
        final File f = File((a as Map<String, dynamic>)['path'] as String);
        if (f.existsSync()) targets.add(f.path);
      }
      for (final dynamic r
          in (truth['rotated'] as List<dynamic>?) ?? <dynamic>[]) {
        final File f = File((r as Map<String, dynamic>)['path'] as String);
        if (f.existsSync()) targets.add(f.path);
      }
    }
    final Directory pics = Directory(r'C:\Users\liuyu\Pictures');
    if (pics.existsSync()) {
      final List<File> ps = pics
          .listSync()
          .whereType<File>()
          .where((File f) {
            final String q = f.path.toLowerCase();
            return q.endsWith('.jpg') ||
                q.endsWith('.jpeg') ||
                q.endsWith('.png') ||
                q.endsWith('.webp');
          })
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
      for (final File f in ps) {
        targets.add(f.path);
      }
    }

    var n = 0;
    var dPlainShuffle = 0, dGreedy = 0, dGreedyShuffle = 0;
    var plainAvail = 0, greedyAvail = 0;
    final List<String> samples = <String>[];

    for (final path in targets) {
      final File file = File(path);
      if (!file.existsSync()) continue;
      final Uint8List bytes = file.readAsBytesSync();
      final FaceInfo? face = await engine.detectFace(bytes);
      if (face == null) continue;
      final DecodedImage im;
      try {
        im = decodeToRgb(bytes,
            maxEdge: kEngineMaxEdge, targetEdge: kBigImageWorkEdge);
      } catch (_) {
        continue;
      }
      final Uint8List gray = grayPlaneFromRgb(im.rgb, im.width, im.height);
      final Float32List lm = face.landmarks!;

      PupilRoll run({bool shuffle = false, bool greedy = false}) {
        debugShuffleCandidates = shuffle;
        debugGreedyGrouping = greedy;
        final PupilRoll r = estimatePupilRoll(
          gray: gray,
          width: im.width,
          height: im.height,
          eyeAx: lm[0],
          eyeAy: lm[1],
          eyeBx: lm[2],
          eyeBy: lm[3],
        );
        debugShuffleCandidates = false;
        debugGreedyGrouping = false;
        return r;
      }

      final PupilRoll a = run();
      final PupilRoll b = run(shuffle: true);
      final PupilRoll c = run(greedy: true);
      final PupilRoll d = run(greedy: true, shuffle: true);

      n++;
      final String tag = file.uri.pathSegments.last;
      if (_fmt(a) != _fmt(b)) dPlainShuffle++;
      if (_fmt(a) != _fmt(c)) dGreedy++;
      if (_fmt(c) != _fmt(d)) {
        dGreedyShuffle++;
        if (samples.length < 5) samples.add('$tag ${_fmt(c)} -> ${_fmt(d)}');
      }
      if (a.available) plainAvail++;
      if (c.available) greedyAvail++;
      if (_fmt(a) != _fmt(b) || _fmt(c) != _fmt(d)) {
        // ignore: avoid_print
        print('[O] $tag plain=${_fmt(a)} shuffle=${_fmt(b)} '
            'greedy=${_fmt(c)} greedyShuffle=${_fmt(d)}');
      }
    }

    // ignore: avoid_print
    print('[O] n=$n 可用 plain=$plainAvail greedy=$greedyAvail');
    // ignore: avoid_print
    print('[O] 生产规则 打乱前后不同 $dPlainShuffle / $n '
        '${dPlainShuffle == 0 ? '（次序无关）' : '（★依赖次序）'}');
    // ignore: avoid_print
    print('[O] 正向对照 贪心打乱前后不同 $dGreedyShuffle / $n '
        '${dGreedyShuffle == 0 ? '★对照无检测力，上面的 0 不作数' : '（对照有效）'}');
    // ignore: avoid_print
    print('[O] 旁证 贪心 vs 生产规则不同 $dGreedy / $n；样例 ${samples.join(' | ')}');
    await engine.disposeMattingEngine();
  }, timeout: const Timeout(Duration(minutes: 40)));
}
