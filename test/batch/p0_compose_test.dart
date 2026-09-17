// qa-batch：G2B-P0 端到端成片产出（供 Python 侧独立测量眼线残余）。
//
// 走**生产引擎**（不是 Python）在 Windows host 上跑：
//   flutter test test/batch/p0_compose_test.dart
//
// 为什么要这一步：ACCEPTANCE P0 计分口径第 5 条——硬判据一律用**成片端到端
// 残余**（口径无关），`ComposeDiagnostics.straightenDeg` 只作诊断。本文件负责
// 产出成片；眼线残余由 `test/batch/p0_output_residual.py` 用独立 Python 瞳孔法
// 测量，**不在本文件里测**（避免自证循环）。
//
// 规格：主跑 cn_big_1inch（390×567，给瞳孔法留够像素）；
// 另对 5 张 spotlight 样本补跑 cn_1inch（295×413，App 默认规格）与
// visa_us（600×600），用于量化"测量随成片尺度的变化"。
//
// 底色统一 white（对比度高，且是默认底色）。产出：
//   out/P0_anchors/composed/<id>__<specId>.jpg
//   out/P0_compose_items.jsonl
@Timeout(Duration(minutes: 90))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/imaging/compose_engine.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

import 'code_fingerprint.dart';
import 'sha256_util.dart';
import 'p0_cases.dart';

// ---------------------------------------------------------------------------
// 溯源：成片数字必须能钉到**具体代码内容**，而不只是 HEAD。
//
// 本文件与 p0_coverage_test.dart 跑的时候 ml-porting 的估角改动还在工作区未提交，
// 事后主会话又提交了若干 docs-only 的 commit —— 此时若只记 HEAD，会把数字错标到
// 一个与测量无关的 commit 上（实测已发生：evaluatedState 从 b3518ba 漂到 5d4e89e）。
// 因此按**文件内容**（git blob hash）记指纹：内容不变则指纹不变，与提交时序无关。
//
// 实现在 code_fingerprint.dart，由 fingerprint_selftest.dart 驱动**同一份**实现自测。
// ---------------------------------------------------------------------------

String _git(List<String> args) => gitText(args);

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

class _Engine with MattingEngineMixin, ComposeEngineMixin implements IdPhotoEngine {
  @override
  void dispose() => disposeMattingEngine();
}

/// 主规格 + spotlight 补跑规格。
const Map<String, PhotoSpec> kSpecs = {
  'cn_big_1inch': kSpecCnBig1inch,
  'cn_1inch': kSpecCn1inch,
  'visa_us': kSpecVisaUs,
};

/// 同时跑三个规格的样本 id。
const Set<String> kSpotlight = {'p1', 'p2', 'p1_upright', 'p1_d-10', 'c08_d-10'};

void main() {
  _preloadHostOnnxRuntime();
  // 开跑前先钉一次被测代码的内容指纹。收尾时会再取一次并比对：本文件跑一轮
  // 要几分钟，若期间有人改了 lib/ 下的代码，只在收尾取指纹就会把"跑完之后"
  // 的状态记到"被测代码"头上 —— 这正是上一轮 evaluatedState 错标 commit 的
  // 同类事故。两次不一致即判定本轮数字失效，而不是默默贴个标签。
  final fpStart = codeFingerprint();
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  ort.debugModelDirectory = '$repo${sep}assets${sep}models';
  final engine = _Engine();
  final outDir = Directory('$repo${sep}out${sep}P0_anchors${sep}composed');

  setUpAll(() async {
    await engine.warmUp();
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
  });
  tearDownAll(() => engine.disposeMattingEngine());

  test('P0 end-to-end composed outputs', () async {
    final truth = jsonDecode(
        File('$repo${sep}out${sep}P0_truth.json').readAsStringSync())
        as Map<String, dynamic>;

    // 清单构造与**路径口径统一**见 p0_cases.dart —— 那里记录了"绝对路径被拼两次、
    // 87 条夹具静默消失"的事故，以及为什么必须抽出来给检查脚本复用。
    final cases = <String, P0Case>{};
    for (final c in buildCases(truth, repo: repo, sep: sep)) {
      cases[c.id] = c;
    }

    // 常设前置检查（硬性）：清单里**每一条**都必须解析到真实文件，否则**不开跑**。
    // 理由见 p0_cases.dart 记录的事故：87 条夹具曾因路径被拼两次而静默 continue，
    // 整轮 exit 0、crash:0、summary 祥和，而 P0.2/P0.3 是在**零样本**上判定的。
    // 3 秒的前置检查换掉一次 17 分钟的零样本运行；`p0_resolve_check.dart` 是同一份
    // 判据的独立入口，这里再挡一道是为了"忘了先跑检查"时也不会白烧一轮。
    final unresolved = cases.values.where((c) => !File(c.path).existsSync()).toList();
    if (unresolved.isNotEmpty) {
      fail('样本解析前置检查未通过：${unresolved.length}/${cases.length} 条解析不到文件，'
          '本轮不得开跑。\n'
          '${unresolved.take(5).map((c) => '  [${c.corpus}] ${c.id} -> ${c.path}').join('\n')}\n'
          '先跑 `dart run test/batch/p0_resolve_check.dart` 定位。');
    }

    final lines = <String>[];
    final coveredIds = <String>{};
    var nOk = 0, nMattingFail = 0, nComposeFail = 0, nNoFace = 0, nCrash = 0;
    var nMissing = 0;

    // 预期产出数 = 输入 id × 该 id 的规格数（spotlight 跑 3 个规格）。
    // **必须推导，不能抄 `cases`** —— 同一张图跨规格会产出多条，所以好轮次里
    // ok(110) ≠ cases(100)。拿 `ok == cases` 判完整会把好轮次误判成失效。
    var expectedOutputs = 0;
    for (final id in cases.keys) {
      expectedOutputs += kSpotlight.contains(id) ? 3 : 1;
    }

    for (final entry in cases.entries) {
      final id = entry.key;
      final info = entry.value;
      final path = info.path;
      final f = File(path);
      if (!f.existsSync()) {
        nMissing++;
        lines.add(jsonEncode(<String, Object?>{
          'id': id, 'path': path.replaceAll(sep, '/'), 'outcome': 'missing',
        }));
        continue;
      }
      final specs = kSpotlight.contains(id)
          ? <String>['cn_big_1inch', 'cn_1inch', 'visa_us']
          : <String>['cn_big_1inch'];
      coveredIds.add(id);

      final bytes = await f.readAsBytes();
      // 喂给引擎的**就是这些字节**。两个测量台各自造夹具时插值/缩放路径不同，
      // 尺寸相同也不代表同源（c04/c05 就恰好同尺寸），所以「同一张图」只能以
      // 内容哈希为准，不以文件名或尺寸为准。
      final inputSha = sha256Hex(bytes);
      MattingResult matting;
      try {
        matting = await engine.removeBackground(bytes);
      } catch (e) {
        nMattingFail++;
        lines.add(jsonEncode(<String, Object?>{
          'id': id,
          'path': path.replaceAll(sep, '/'),
          'inputSha256': inputSha,
          'corpus': info.corpus,
          'synthetic': info.synthetic,
          'truthTiltDeg': info.truthTiltDeg,
          'outcome': 'matting_fail',
          'err': e.toString(),
        }));
        continue;
      }
      FaceInfo? face;
      try {
        face = await engine.detectFace(bytes);
      } catch (e) {
        face = null;
      }
      if (face == null) nNoFace++;

      for (final specId in specs) {
        final rec = <String, Object?>{
          'id': id,
          'path': path.replaceAll(sep, '/'),
          'inputSha256': inputSha,
          'corpus': info.corpus,
          'synthetic': info.synthetic,
          'truthTiltDeg': info.truthTiltDeg,
          'specId': specId,
          'rollSource': face?.rollSource.name ?? 'no_face',
          'faceRollDeg': face?.rollDeg,
          'faceConfidence': face?.confidence,
        };
        try {
          final cand = await engine.compose(
            matting: matting,
            spec: kSpecs[specId]!,
            style: kBgWhite,
            face: face,
          );
          final d = engine.lastDiagnostics;
          final name = '${id}__$specId.jpg';
          File('${outDir.path}${sep}$name').writeAsBytesSync(cand.jpegBytes);
          rec['outcome'] = 'ok';
          rec['composed'] = 'out/P0_anchors/composed/$name';
          if (d != null) {
            rec['straightenDeg'] = d.straightenDeg;
            rec['straightened'] = d.straightened;
            rec['outOfBoundsFraction'] = d.outOfBoundsFraction;
            rec['achievedHeadHeightRatio'] = d.achievedHeadHeightRatio;
            rec['note'] = d.note;
          }
          nOk++;
        } catch (e) {
          rec['outcome'] = 'compose_fail';
          rec['err'] = e.toString();
          if (e is IdPhotoException) {
            rec['zh'] = e.messageZh;
          }
          nComposeFail++;
        }
        lines.add(jsonEncode(rec));
        stdout.writeln(jsonEncode(rec));
      }
    }

    final String itemsPath = '$repo${sep}out${sep}P0_compose_items.jsonl';
    File(itemsPath).writeAsStringSync('${lines.join('\n')}\n');
    // 逐行 jsonl 自己没有 provenance，而下游（p0_finalize_v1 的覆盖率违规名单）
    // 直接读它。**"同一个 run 写的所以应该没问题"是推断，不是记录** ——
    // 这里把落盘后的字节摘要记进 summary，让那个绑定可被机器核对：
    // 摘要对不上 ⇒ 这份 jsonl 不是本次跑出来的，整块读数作废。
    final String itemsSha256 = sha256Hex(File(itemsPath).readAsBytesSync());
    final fpEnd = codeFingerprint();
    final summary = <String, Object?>{
      'generatedBy': 'qa-batch test/batch/p0_compose_test.dart',
      'note': '生产引擎产成片（white 底）；眼线残余由 p0_output_residual.py 独立测量',
      'cases': cases.length,
      'casesAttempted': coveredIds.length,
      'expectedOutputs': expectedOutputs,
      'missing': nMissing,
      'complete': nMissing == 0 && nOk == expectedOutputs,
      'completeNote': '完整性 = **missing == 0 且 ok == expectedOutputs**（两条缺一不可）。'
          '注意 ok 与 cases **本来就不相等**：cases 是去重后的输入 id 数，'
          'ok 是成片条数（同一张图跨规格产出多条）。'
          '`crash == 0` 是**必要但远不充分**的条件——它只说明"没抛异常"，'
          '一份只跑了 17/100 的轮次同样能报出 crash=0。',
      'ok': nOk,
      'mattingFail': nMattingFail,
      'composeFail': nComposeFail,
      'noFace': nNoFace,
      'crash': nCrash,
      'primarySpec': 'cn_big_1inch',
      'spotlightSpecs': <String>['cn_big_1inch', 'cn_1inch', 'visa_us'],
      'provenance': <String, Object?>{
        'gitHead': _git(<String>['rev-parse', '--short', 'HEAD']),
        'workingTreeDirty':
            _git(<String>['status', '--porcelain']).replaceAll('\n', ' | '),
        'codeFingerprint': fpStart,
        'codeFingerprintAtEnd': fpEnd,
        'itemsFile': 'out/P0_compose_items.jsonl',
        'itemsSha256': itemsSha256,
        'itemsBindingNote':
            '`itemsSha256` 是落盘后对 `out/P0_compose_items.jsonl` 字节取的摘要。'
            '该 jsonl **自身不含 provenance**，下游读它时必须拿这个摘要复核 —— '
            '对不上说明它不属于本次运行，**不得当成当轮数据**。',
        ...roundVerdict(fpStart, fpEnd),
        'stableNote': '两次指纹不一致 = 本轮数字**失效**（跑的过程中被测代码被改过），'
            '不得据此判定；一致则这些数字可钉到该指纹对应的代码内容上。',
      },
    };
    File('$repo${sep}out${sep}P0_compose_summary.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
    stdout.writeln('SUMMARY ${jsonEncode(summary)}');
  }, timeout: const Timeout(Duration(minutes: 85)));
}
