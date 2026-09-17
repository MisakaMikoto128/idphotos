// test/batch/batch_runner.dart
//
// qa-batch G4 设备端批量回归 runner（阶段 4）。
// **测量代码，不做阈值判定** —— 判定由 host 侧 test/batch/merge_results.py 与
// gatekeeper 的 gate 脚本完成（裁判不下场）。
//
// 运行方式（host 侧）：
//   flutter build apk --debug --target=test/batch/batch_runner.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -W --ez enable-impeller false -n com.muzhao.muzhao/.MainActivity
//   （不 runApp，不渲染真实 UI；--ez enable-impeller false 按 PITFALLS 固化）
//
// 配置经 dart-define 注入：
//   QA_MODE      batch | leak | perf
//   QA_FROM/QA_TO batch 模式的条目下标区间 [from, to]，分块跑、JSONL 增量落盘
//   QA_DIR       设备端输入目录（manifest.json + item_NNN.ext）
//   QA_OUT       设备端输出目录（host 需先 mkdir + chmod 777，见 PITFALLS）
//   QA_ARTIFACTS 额外保存对比网格素材的条目下标（逗号分隔）
//
// 输出（全部落在 QA_OUT，host adb pull 回收）：
//   batch_items.jsonl  每条目一行：engine 分步计时 + controller 端到端语义
//   leak_items.jsonl   leak 模式 20 连跑的单张耗时
//   perf_ms.json       perf 模式 512x512 抠图逐次耗时
//   markers：leak_begin / leak_end / done_<mode> 供 host 侧轮询切分内存曲线
//
// 不吞异常：任何异常都原样记录进 JSONL（error 字段），不是 catch 掉就算过。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

const String kQaDir = String.fromEnvironment(
  'QA_DIR',
  defaultValue: '/data/local/tmp/muzhao_qa_tmp/in',
);
String kQaOut = String.fromEnvironment(
  'QA_OUT',
  defaultValue: '/data/local/tmp/muzhao_qa_tmp/out',
);
const String kModeDef = String.fromEnvironment('QA_MODE', defaultValue: 'batch');
const int kFromDef = int.fromEnvironment('QA_FROM', defaultValue: 0);
const int kToDef = int.fromEnvironment('QA_TO', defaultValue: 999999);
const String kArtifactsRawDef =
    String.fromEnvironment('QA_ARTIFACTS', defaultValue: '');
const int kPerfNDef = int.fromEnvironment('QA_PERF_N', defaultValue: 25);
const int kLeakRoundsDef = int.fromEnvironment('QA_LEAK_ROUNDS', defaultValue: 20);

// 运行期配置（qa_config.json）优先于 dart-define：一次构建可分块/换模式跑，
// 规避 Windows 增量 assembleDebug 产出损坏 APK 的坑（见 PITFALLS）。
String kMode = kModeDef;
int kFrom = kFromDef;
int kTo = kToDef;
int kPerfN = kPerfNDef;
int kLeakRounds = kLeakRoundsDef;
String kArtifactsRaw = kArtifactsRawDef;

void applyRuntimeConfig() {
  final f = File('$kQaDir/qa_config.json');
  if (!f.existsSync()) return;
  final cfg = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  kMode = (cfg['mode'] as String?) ?? kMode;
  kFrom = (cfg['from'] as int?) ?? kFrom;
  kTo = (cfg['to'] as int?) ?? kTo;
  kPerfN = (cfg['perf_n'] as int?) ?? kPerfN;
  kLeakRounds = (cfg['leak_rounds'] as int?) ?? kLeakRounds;
  // 输出目录可被配置覆盖：/data/local/tmp 对 untrusted_app 是只读的
  // （SELinux 拒写，即使 chmod 777），输出必须落 App 私有 cache。
  final outDir = cfg['out_dir'] as String?;
  if (outDir != null && outDir.isNotEmpty) kQaOut = outDir;
  final arts = cfg['artifacts'];
  if (arts is List) kArtifactsRaw = arts.join(',');
}

Set<int> get kArtifactIdx => kArtifactsRaw.isEmpty
    ? <int>{}
    : kArtifactsRaw.split(',').map((s) => int.parse(s.trim())).toSet();

Future<void> appendJsonl(String name, Map<String, dynamic> rec) async {
  var line = jsonEncode(rec);
  // 文件写入保留（debug 包可用）；release 真机通道走 logcat（见 qaLog）。
  try {
    final f = File('$kQaOut/$name');
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  } catch (e) {
    // 外部目录 FUSE 拒写等场景：文件通道失效不阻断，qaLog 仍带出全量数据。
    // 但**失败原因必须可观测** —— 数据本身已由 qaLog 带出，丢的是"为什么没落盘"，
    // 把它并进载荷而不是丢掉。
    line = jsonEncode(<String, dynamic>{...rec, 'file_write_error': '$e'});
  }
  qaLog(name, line);
}

int _qaSeq = 0;

/// logcat 传输通道：release 真机上 run-as 与外部目录都不可靠，
/// 改把 marker/JSONL 打到 logcat（flutter tag），host 侧 `logcat -d` 解析。
/// 长负载分块（logd 单条 ~4KB 上限），host 按 (name, rid) 重组。
/// 注：按 UTF-16 码元切分可能切在代理对中间，但 host 端按序拼接后再
/// jsonDecode，无损。
void qaLog(String name, String payload) {
  _qaSeq++;
  final rid = _qaSeq; // 进程内单调：彻底避免同毫秒 rid 碰撞导致重组错乱
  final n = (payload.length / 3000).ceil();
  for (var i = 0; i < n; i++) {
    final end = (i + 1) * 3000 > payload.length
        ? payload.length
        : (i + 1) * 3000;
    print('QA_JSONL|$name|$rid|$i/$n|${payload.substring(i * 3000, end)}');
  }
}

Future<void> marker(String name) async {
  print('QA_MARKER|$name');
  final int ts = DateTime.now().millisecondsSinceEpoch;
  try {
    await File('$kQaOut/$name').writeAsString('$ts', flush: true);
  } catch (e) {
    // 这一处与上面两处不同：文件写失败时时间戳**没有别的通道**。
    // `merge_results.py` 的 leak 切分只读文件内容（`int(open(p).read())`），不看 logcat，
    // 文件缺失 → beg/end 为 None → leak_r*.json 里 baseline/delta 写成 null。
    // 所以不能吞：把 ts 与原因打到 logcat，至少可据以重建切点。
    // **不要**改成往 `QA_MARKER` 行上追加 ts —— `run_realdevice.py` 按第一个 '|'
    // 之后全部当 name，追加会让 `wait_marker('leak_begin')` 永不命中。
    print('QA_MARKER_FILE_FAIL|$name|$ts|$e');
  }
}

/// 轮询直到 controller 进入 ready / error。
Future<AppState> waitSettled(MuZhaoController c, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  var last = c.currentState;
  while (DateTime.now().isBefore(deadline)) {
    last = c.currentState;
    if (last.stage == Stage.ready || last.stage == Stage.error) return last;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return last;
}

/// alpha 数组按 stride 分块平均，降采样为灰度 PNG 字节（对比网格素材）。
Uint8List downscaleAlphaPng(Uint8List alpha, int w, int h, int maxSide) {
  final stride =
      math.max(1, (math.max(w, h) / maxSide).ceil());
  final sw = (w / stride).ceil();
  final sh = (h / stride).ceil();
  final image = img.Image(width: sw, height: sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      var sum = 0;
      var n = 0;
      for (var dy = 0; dy < stride; dy++) {
        final sy = y * stride + dy;
        if (sy >= h) break;
        for (var dx = 0; dx < stride; dx++) {
          final sx = x * stride + dx;
          if (sx >= w) break;
          sum += alpha[sy * w + sx];
          n++;
        }
      }
      final v = n == 0 ? 0 : (sum / n).round().clamp(0, 255);
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// 前景占比（alpha>=128 的比例，步长 4 采样）。
double foregroundRatio(Uint8List alpha, int w, int h) {
  var fg = 0;
  var n = 0;
  for (var y = 0; y < h; y += 4) {
    for (var x = 0; x < w; x += 4) {
      if (alpha[y * w + x] >= 128) fg++;
      n++;
    }
  }
  return n == 0 ? 0 : fg / n;
}

bool hasCjk(String? s) =>
    s != null && s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

class ManifestItem {
  final int i;
  final String path;
  final String file;
  final String cls;
  const ManifestItem(this.i, this.path, this.file, this.cls);

  factory ManifestItem.fromJson(Map<String, dynamic> j) => ManifestItem(
      j['i'] as int, j['path'] as String, j['file'] as String, j['class'] as String);
}

Future<void> runBatch(IdPhotoEngineImpl engine, MuZhaoController controller,
    List<ManifestItem> items) async {
  final spec = controller.currentState.spec;
  for (final it in items) {
    final rec = <String, dynamic>{
      'i': it.i,
      'path': it.path,
      'class': it.cls,
      'device_file': it.file,
    };
    await appendJsonl('batch_items.jsonl', {
      'event': 'begin',
      'i': it.i,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    final t0 = DateTime.now();
    try {
      final bytes =
          await File('$kQaDir/${it.file}').readAsBytes();
      rec['file_bytes'] = bytes.length;

      // ---- 引擎分步计时（matting / face / compose 1 规格 x 1 底色）----
      final eng = <String, dynamic>{};
      final swMat = Stopwatch()..start();
      MattingResult? mat;
      try {
        mat = await engine.removeBackground(bytes);
        eng['matting_ms'] = swMat.elapsedMilliseconds;
        eng['matting_size'] = '${mat.width}x${mat.height}';
        eng['fg_ratio'] =
            foregroundRatio(mat.alpha, mat.width, mat.height);
      } catch (e, st) {
        eng['matting_ms'] = swMat.elapsedMilliseconds;
        eng['matting_error'] = e.toString();
        eng['matting_error_type'] = e.runtimeType.toString();
        if (e is IdPhotoException) eng['message_zh'] = e.messageZh;
        eng['matting_stack_head'] = st.toString().split('\n').take(4).join(' | ');
      }

      FaceInfo? face;
      if (mat != null) {
        final swFace = Stopwatch()..start();
        try {
          face = await engine.detectFace(bytes);
          eng['face_ms'] = swFace.elapsedMilliseconds;
          eng['face_found'] = face != null;
          if (face != null) {
            eng['face_conf'] = face.confidence;
            eng['face_order_ok'] = face.chinY > face.headTopY;
          }
        } catch (e) {
          eng['face_ms'] = swFace.elapsedMilliseconds;
          eng['face_error'] = e.toString();
        }

        final swComp = Stopwatch()..start();
        try {
          final cand = await engine.compose(
              matting: mat, spec: spec, style: kBgWhite, face: face);
          eng['compose_ms'] = swComp.elapsedMilliseconds;
          eng['compose_bytes'] = cand.jpegBytes.length;
          final decoded = img.decodeJpg(cand.jpegBytes);
          eng['compose_decoded'] = decoded != null;
          if (decoded != null) {
            eng['compose_w'] = decoded.width;
            eng['compose_h'] = decoded.height;
          }
        } catch (e) {
          eng['compose_ms'] = swComp.elapsedMilliseconds;
          eng['compose_error'] = e.toString();
        }
      }
      rec['engine'] = eng;

      // ---- controller 端到端语义（messageZh 通路）----
      final ctrl = <String, dynamic>{};
      final swLoad = Stopwatch()..start();
      await controller.loadImage(bytes);
      final s = await waitSettled(controller, const Duration(minutes: 10));
      swLoad.stop();
      ctrl['load_ms'] = swLoad.elapsedMilliseconds;
      ctrl['stage'] = s.stage.name;
      ctrl['error_message'] = s.errorMessage;
      ctrl['error_message_cjk'] = hasCjk(s.errorMessage);
      ctrl['candidates'] = s.candidates.length;
      if (s.candidates.isNotEmpty) {
        final c0 = s.candidates.first.jpegBytes;
        final decoded = img.decodeJpg(c0);
        ctrl['cand0_decoded'] = decoded != null;
        ctrl['cand0_w'] = decoded?.width;
        ctrl['cand0_h'] = decoded?.height;
        ctrl['cand0_bytes'] = c0.length;
        ctrl['cand0_size_ok'] =
            decoded != null &&
                decoded.width == spec.widthPx &&
                decoded.height == spec.heightPx;
      }
      ctrl['suggested_crop'] = s.suggestedCrop == null
          ? null
          : [s.suggestedCrop!.left, s.suggestedCrop!.top,
             s.suggestedCrop!.width, s.suggestedCrop!.height];
      rec['controller'] = ctrl;

      // ---- 结果分类（供 host 汇总，不在设备端下 PASS/FAIL 结论）----
      String result;
      final c = ctrl;
      if (c['stage'] == 'ready' &&
          (c['candidates'] as int) > 0 &&
          c['cand0_decoded'] == true &&
          c['cand0_size_ok'] == true) {
        result = 'success';
      } else if (c['stage'] == 'error' && c['error_message_cjk'] == true) {
        result = 'graceful_error';
      } else if (c['stage'] == 'ready' && c['error_message'] != null) {
        result = 'noface_hint';
      } else if (c['stage'] == 'error') {
        result = 'unlocalized_error';
      } else {
        result = 'unexpected';
      }
      rec['result'] = result;
      rec['weird'] = result != 'success' &&
          (c['candidates'] as int) > 0 &&
          (it.cls != 'portrait' && it.cls != 'multi_face');
      rec['total_ms'] = DateTime.now().difference(t0).inMilliseconds;

      // ---- 对比网格素材：全部人像类 + 指定下标 ----
      if ((it.cls == 'portrait' || it.cls == 'multi_face' ||
              kArtifactIdx.contains(it.i)) &&
          s.candidates.isNotEmpty) {
        try {
          for (final cand in s.candidates) {
            await File('$kQaOut/artifacts/a${it.i}_${cand.style.id}.jpg')
                .create(recursive: true)
                .then((f) => f.writeAsBytes(cand.jpegBytes, flush: true));
          }
          final m = mat ??
              await engine.removeBackground(bytes);
          final png = downscaleAlphaPng(m.alpha, m.width, m.height, 360);
          await File('$kQaOut/artifacts/a${it.i}_alpha.png')
              .create(recursive: true)
              .then((f) => f.writeAsBytes(png, flush: true));
        } catch (e) {
          rec['artifact_error'] = e.toString();
        }
      }
    } catch (e, st) {
      rec['result'] = 'harness_exception';
      rec['error'] = e.toString();
      rec['stack_head'] = st.toString().split('\n').take(4).join(' | ');
      rec['total_ms'] = DateTime.now().difference(t0).inMilliseconds;
    }
    rec['t_done'] = DateTime.now().millisecondsSinceEpoch;
    await appendJsonl('batch_items.jsonl', {'event': 'item', 'rec': rec});
  }
}

/// G4.8：连续 20 张人像，中间 sleep，host 侧 dumpsys 采样内存曲线。
Future<void> runLeak(IdPhotoEngineImpl engine, MuZhaoController controller,
    List<ManifestItem> items) async {
  // 预热 1 张，让模型/缓存进入稳态，再取基线。
  final warm = items.first;
  await controller
      .loadImage(await File('$kQaDir/${warm.file}').readAsBytes());
  await waitSettled(controller, const Duration(minutes: 10));
  await Future<void>.delayed(const Duration(seconds: 5));
  await marker('leak_begin');

  for (var r = 0; r < kLeakRounds; r++) {
    final it = items[r % items.length];
    final sw = Stopwatch()..start();
    await controller
        .loadImage(await File('$kQaDir/${it.file}').readAsBytes());
    final s = await waitSettled(controller, const Duration(minutes: 10));
    sw.stop();
    await appendJsonl('leak_items.jsonl', {
      'round': r,
      'path': it.path,
      'class': it.cls,
      'load_ms': sw.elapsedMilliseconds,
      'stage': s.stage.name,
      'candidates': s.candidates.length,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    await Future<void>.delayed(const Duration(milliseconds: 2500));
  }
  await marker('leak_end');
  // 留 15s 给 host 采"回落"读数，再退出进程。
  await Future<void>.delayed(const Duration(seconds: 15));
}

/// G4.6：512x512 抠图 p95 采样。
Future<void> runPerf(IdPhotoEngineImpl engine) async {
  final input = File('$kQaDir/perf_512.jpg');
  if (!await input.exists()) {
    await appendJsonl('perf_ms.json', {'error': 'perf_512.jpg 不存在'});
    return;
  }
  final bytes = await input.readAsBytes();
  // 2 次预热不计入。
  for (var i = 0; i < 2; i++) {
    await engine.removeBackground(bytes);
  }
  final ms = <int>[];
  for (var i = 0; i < kPerfN; i++) {
    final sw = Stopwatch()..start();
    await engine.removeBackground(bytes);
    ms.add(sw.elapsedMilliseconds);
  }
  final perf = <String, dynamic>{
    'input': input.path,
    'n': ms.length,
    'ms': ms,
  };
  try {
    await File('$kQaOut/perf_ms.json').writeAsString(
        jsonEncode(perf),
        flush: true);
  } catch (e) {
    // 文件通道失效不阻断，qaLog 仍带出全量数据；但失败原因必须可观测
    perf['file_write_error'] = '$e';
  }
  qaLog('perf_ms.json', jsonEncode(perf));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  applyRuntimeConfig();
  // 真机通道：release 包不可调试（run-as 拒绝），输出目录改在应用自有外部
  // 目录（App 免权限可写、adb shell 可读）。目录必须由 App 自己建（create
  // recursive），shell 建的会带 shell 属主，App 可能写不进。
  try {
    await Directory(kQaOut).create(recursive: true);
  } catch (e) {
    // 不吞：打到 logcat（flutter tag），后续每条 JSONL 写失败也会各自暴露
    print('QA_OUT_CREATE_FAIL: $kQaOut -> $e');
  }
  await marker('qa_started_$kMode');
  final engine = IdPhotoEngineImpl();
  try {
    await engine.warmUp();
    final manifest = jsonDecode(
            await File('$kQaDir/manifest.json').readAsString())
        as Map<String, dynamic>;
    final all = (manifest['items'] as List)
        .map((j) => ManifestItem.fromJson(j as Map<String, dynamic>))
        .toList();
    final controller = MuZhaoController(engine);

    switch (kMode) {
      case 'batch':
        final items =
            all.where((it) => it.i >= kFrom && it.i <= kTo).toList()
              ..sort((a, b) => a.i.compareTo(b.i));
        await runBatch(engine, controller, items);
        break;
      case 'leak':
        final items = all
            .where((it) => it.cls == 'portrait' || it.cls == 'multi_face')
            .toList();
        await runLeak(engine, controller, items);
        break;
      case 'perf':
        await runPerf(engine);
        break;
      default:
        await appendJsonl('qa_errors.jsonl', {'error': '未知 QA_MODE=$kMode'});
    }
  } catch (e, st) {
    await appendJsonl('qa_errors.jsonl', {
      'mode': kMode,
      'error': e.toString(),
      'stack': st.toString().split('\n').take(6).join(' | '),
    });
  }
  await marker('done_$kMode');
  exit(0);
}
