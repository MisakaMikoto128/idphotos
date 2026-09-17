// qa-batch：G2B-P0.4 覆盖率基线（RollSource 分布）。
//
// 走**生产引擎**（不是 Python），在 Windows host 上跑：
//   flutter test test/batch/p0_coverage_test.dart
//
// 语料：test/dataset.json 全量 + 黄金集 8 + P0 真值锚点，去重后逐个
// removeBackground → detectFace（与 controller 同序、同 bytes 实例）。
// 逐条记录 face 是否检出、rollDeg、rollSource、confidence。
//
// 产出 out/P0_coverage_pre.json。当前 ml-porting 的瞳孔估角未落地，
// 本文件即"修前基线"；落地后重跑同一条命令得到"修后"，两者直接对比。
//
// 本文件只测量，不做任何阈值判定（判定归 gatekeeper）。
@Timeout(Duration(minutes: 90))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

import 'code_fingerprint.dart';
import 'sha256_util.dart';

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

class _Engine with MattingEngineMixin {}

void main() {
  _preloadHostOnnxRuntime();
  // 与成片台同一套溯源：开跑/收尾各取一次被测代码内容指纹。
  // r1 的判决是**拼起来的**（成片来自一份工作树、dev_selfcheck 来自另一份），
  // r2 起的规则是「一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来」，
  // 所以覆盖率台也必须自带指纹，好让 gatekeeper 能核"这几份是不是同一版"。
  final fpStart = codeFingerprint();
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  ort.debugModelDirectory = '$repo${sep}assets${sep}models';
  final engine = _Engine();

  setUpAll(() => engine.warmUp());
  tearDownAll(() => engine.disposeMattingEngine());

  test('P0.4 RollSource coverage baseline', () async {
    final cases = <String, Map<String, String>>{};

    // 1) Pictures 全量（冻结数据集）
    final ds = jsonDecode(File('$repo${sep}test${sep}dataset.json')
        .readAsStringSync()) as Map<String, dynamic>;
    for (final it in ds['items'] as List) {
      final m = it as Map<String, dynamic>;
      cases['ds_${m['class']}_${cases.length}'] = {
        'path': (m['path'] as String).replaceAll('/', sep),
        'class': m['class'] as String,
        'corpus': 'pictures',
      };
    }
    // 2) 黄金集
    for (var i = 1; i <= 8; i++) {
      cases['golden_g0$i'] = {
        'path': '$repo${sep}test${sep}golden${sep}src${sep}g0$i.jpg',
        'class': 'golden',
        'corpus': 'golden',
      };
    }
    // 3) P0 真值锚点（含 straight + 回正合成样本 + 全部旋转夹具）
    final truth = jsonDecode(
        File('$repo${sep}out${sep}P0_truth.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final key in <String>['anchors', 'straight', 'uprightSynthetic']) {
      for (final a in (truth[key] as List? ?? <dynamic>[])) {
        final m = a as Map<String, dynamic>;
        cases['anchor_${m['id']}'] = {
          'path': (m['path'] as String).replaceAll('/', sep),
          'class': 'anchor',
          // corpus 原样保留 'anchor'（含 uprightSynthetic），r1↔r2 结构可比。
          // 竖直样本另用正交字段 synthetic 判别 —— 原因见 p0_cases.dart 的 P0Case。
          'corpus': 'anchor',
          'synthetic': key == 'uprightSynthetic' ? 'upright' : '',
          'trueTiltDeg': '${m['trueRollDeg']}',
          'expectedEngineRollDeg': '${m['trueRollDeg']}',
        };
      }
    }
    for (final a in (truth['rotated'] as List? ?? <dynamic>[])) {
      final m = a as Map<String, dynamic>;
      cases['rot_${m['id']}'] = {
        'path': (m['path'] as String).replaceAll('/', sep),
        'class': 'fixture',
        'corpus': 'rotated',
        'synthetic': 'rotated',
        'deltaDeg': '${m['deltaDeg']}',
        'trueTiltDeg': '${m['expectedTiltDeg']}',
        'expectedEngineRollDeg': '${m['expectedEngineRollDeg']}',
      };
    }

    // 常设前置检查（硬性）：清单里每一条都必须解析到真实文件，否则不开跑。
    final unresolved =
        cases.entries.where((e) => !File(e.value['path']!).existsSync()).toList();
    if (unresolved.isNotEmpty) {
      fail('样本解析前置检查未通过：${unresolved.length}/${cases.length} 条解析不到文件，'
          '本轮不得开跑。\n'
          '${unresolved.take(5).map((e) => '  ${e.key} -> ${e.value['path']}').join('\n')}');
    }

    final lines = <String>[];
    final bySource = <String, int>{};
    final byCorpus = <String, Map<String, int>>{};
    final bySynthetic = <String, Map<String, int>>{};
    var nFace = 0, nNull = 0, nRejected = 0, nCrash = 0, nMissing = 0;

    for (final entry in cases.entries) {
      final path = entry.value['path']!;
      final rec = <String, dynamic>{
        'id': entry.key,
        'path': path.replaceAll(sep, '/'),
        'class': entry.value['class'],
        'corpus': entry.value['corpus'],
      };
      for (final k in <String>['trueTiltDeg', 'expectedEngineRollDeg', 'deltaDeg']) {
        final v = entry.value[k];
        if (v != null) rec[k] = double.parse(v);
      }
      final f = File(path);
      if (!f.existsSync()) {
        rec['outcome'] = 'missing';
        nMissing++;
        lines.add(jsonEncode(rec));
        continue;
      }
      Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (e) {
        rec['outcome'] = 'read_error';
        rec['err'] = e.toString();
        nMissing++;
        lines.add(jsonEncode(rec));
        continue;
      }
      try {
        await engine.removeBackground(bytes);
      } catch (e) {
        // 抠图失败不等于估角失败；照常尝试 detectFace，但记下
        rec['matting'] = 'rejected:${e.runtimeType}';
      }
      try {
        final face = await engine.detectFace(bytes);
        if (face == null) {
          rec['outcome'] = 'no_face';
          rec['rollSource'] = 'none';
          nNull++;
        } else {
          rec['outcome'] = 'face';
          rec['rollDeg'] = face.rollDeg;
          rec['rollSource'] = face.rollSource.name;
          rec['confidence'] = face.confidence;
          rec['hasLandmarks'] = face.landmarks != null;
          rec['box'] = <double>[face.box.left, face.box.top, face.box.right,
              face.box.bottom];
          nFace++;
        }
      } on IdPhotoException catch (e) {
        rec['outcome'] = 'rejected';
        rec['exc'] = e.runtimeType.toString();
        rec['zh'] = e.messageZh;
        nRejected++;
      } catch (e) {
        rec['outcome'] = 'CRASH';
        rec['err'] = e.toString();
        nCrash++;
      }
      final src = rec['rollSource'] as String? ?? 'none';
      bySource[src] = (bySource[src] ?? 0) + 1;
      final corpus = entry.value['corpus']!;
      byCorpus.putIfAbsent(corpus, () => <String, int>{});
      byCorpus[corpus]![src] = (byCorpus[corpus]![src] ?? 0) + 1;
      // P0.2 取样本用这个，不用 byCorpus——corpus 把竖直样本并进了 'anchor'。
      // 口径与成片台一致：**始终带这个键**，值为 "upright" / "rotated" / null。
      // （不要"不适用就省略键"——同一个概念两种表示正是这一路反复踩的坑。）
      final syn = entry.value['synthetic'];
      final synOrNull = (syn == null || syn.isEmpty) ? null : syn;
      rec['synthetic'] = synOrNull;
      if (synOrNull != null) {
        bySynthetic.putIfAbsent(synOrNull, () => <String, int>{});
        bySynthetic[synOrNull]![src] = (bySynthetic[synOrNull]![src] ?? 0) + 1;
      }
      lines.add(jsonEncode(rec));
      stdout.writeln(jsonEncode(rec));
    }

    // 先落盘 jsonl 再取摘要再写 summary：摘要必须描述**盘上那份字节**，
    // 不能描述"我打算写的内容"。
    final String coverageItemsPath =
        '$repo${sep}out${sep}P0_coverage_items.jsonl';
    File(coverageItemsPath).writeAsStringSync('${lines.join('\n')}\n');
    final String coverageItemsSha256 =
        sha256Hex(File(coverageItemsPath).readAsBytesSync());
    final fpEnd = codeFingerprint();
    final summary = <String, dynamic>{
      'generatedBy': 'qa-batch test/batch/p0_coverage_test.dart',
      'note': '生产引擎（Windows host）实测；rollSource 分布 + 逐项 rollDeg。'
          '本文件为 **修后（ml-porting 瞳孔估角已落地）** 版本，'
          '修前基线见 out/P0_coverage_pre.json。',
      'phase': 'postfix',
      'gitCommit': _gitHead(),
      'workingTreeDirty': _dirtyMatting(),
      'total': cases.length,
      'expectedOutputs': cases.length, // 每 case 恰好一行，不跨规格
      'produced': lines.length,
      'complete': nMissing == 0 && lines.length == cases.length,
      'completeNote': '完整性 = **missing == 0 且 produced == expectedOutputs**。'
          '`crash == 0` 只是"没抛异常"，**必要但远不充分**——'
          '一份把输入静默跳过的轮次同样能报出 crash=0。',
      'faceDetected': nFace,
      'noFace': nNull,
      'rejected': nRejected,
      'crash': nCrash,
      'missing': nMissing,
      'rollSourceDistribution': bySource,
      'byCorpus': byCorpus,
      'bySynthetic': bySynthetic,
      'syntheticNote': 'P0.2 的竖直样本集请用 bySynthetic["upright"]，**不要用 byCorpus**——'
          'corpus 把 uprightSynthetic 并进了 anchor（为保持 r1↔r2 结构可比而刻意不改）。',
      'provenance': <String, Object?>{
        'codeFingerprint': fpStart,
        'codeFingerprintAtEnd': fpEnd,
        'itemsFile': 'out/P0_coverage_items.jsonl',
        'itemsSha256': coverageItemsSha256,
        'itemsBindingNote':
            '`itemsSha256` 是落盘后对 `out/P0_coverage_items.jsonl` 字节取的摘要。'
            '该 jsonl **自身不含 provenance**，下游读它时必须拿这个摘要复核 —— '
            '对不上说明它不属于本次运行，**不得当成当轮数据**。',
        ...roundVerdict(fpStart, fpEnd),
      },
    };
    File('$repo${sep}out${sep}P0_coverage_post.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
    stdout.writeln('SUMMARY ${jsonEncode(summary)}');
  }, timeout: const Timeout(Duration(minutes: 85)));
}

/// 取 git 输出；**非 0 退出与起不了进程都返回 `'unknown'`**。
///
/// `Process.runSync` 只在**起不了进程**时抛异常；git 能启动但退出码非 0 时它
/// **不抛**，返回 exitCode≠0 + 空 stdout。若只看 stdout，那种失败会得到 `''`
/// —— 与"干净"**逐字符相同**，于是"仪表看不见对象"被读成"对象清白"。
/// 这个形状在本项目已出现三次（`_commit_binding`、`gitBlobHashStrict`、
/// 以及这里的 `dirty`），所以退出码必须单独查。
///
/// 注意 `'unknown'` **不得读成"没有改动"**：来源缺失不等于清白。
String _git(String arg) {
  try {
    final r = Process.runSync('git', <String>['status', '--porcelain', arg]);
    if (r.exitCode != 0) return 'unknown';
    return (r.stdout as String).trim().replaceAll('\n', ' | ');
  } catch (_) {
    return 'unknown';
  }
}

String _gitHead() {
  try {
    final r = Process.runSync('git', <String>['rev-parse', '--short', 'HEAD']);
    if (r.exitCode != 0) return 'unknown';
    final String s = (r.stdout as String).trim();
    return s.isEmpty ? 'unknown' : s;
  } catch (_) {
    return 'unknown';
  }
}

/// ml-porting 的估角改动是否还在工作区未提交 —— 覆盖率数字必须能追溯到具体状态。
/// 返回值 `''` 才表示干净；`'unknown'` 表示**取不到**，不是"干净"。
String _dirtyMatting() => _git('lib/core/matting/');
