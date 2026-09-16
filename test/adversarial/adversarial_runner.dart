// test/adversarial/adversarial_runner.dart
//
// adversarial G4.4 设备端对抗 runner（只测量，不做 PASS/FAIL 判定）。
// 真实引擎 IdPhotoEngineImpl + 真实控制器 MuZhaoController，不加任何 mock。
//
// 运行方式（host 侧）：
//   flutter build apk --debug --target=test/adversarial/adversarial_runner.dart
//   adb install -r ... && am start -W --ez enable-impeller false -n com.muzhao.muzhao/.MainActivity
//
// 输入：kAdvDir/manifest.json（用例表）+ kAdvDir/adv_config.json（本轮跑哪些 id）
// 输出（kAdvOut，host 用 run-as tar 拉回）：
//   adv_items.jsonl   每用例一行（begin/end marker 用于进程死亡归因）
//   artifacts/        成功 compose 的成片 JPEG + EXIF 用例的 alpha PNG
//
// **不吞异常**：所有异常原样记进 JSONL；崩溃由 host 通过 marker 缺失归因。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';

const String kAdvDir = String.fromEnvironment(
  'ADV_DIR',
  defaultValue: '/data/local/tmp/muzhao_adv_tmp/in',
);
String kAdvOut =
    String.fromEnvironment('ADV_OUT', defaultValue: '/data/local/tmp/muzhao_adv_tmp/out');

String kMode = 'cases';
List<String> kCaseIds = const <String>[];

Future<void> applyRuntimeConfig() async {
  final f = File('$kAdvDir/adv_config.json');
  if (!f.existsSync()) return;
  final cfg = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  kMode = (cfg['mode'] as String?) ?? kMode;
  if (cfg['cases'] is List) {
    kCaseIds = (cfg['cases'] as List).map((e) => e as String).toList();
  }
  final outDir = cfg['out_dir'] as String?;
  if (outDir != null && outDir.isNotEmpty) kAdvOut = outDir;
}

Future<void> appendJsonl(String name, Map<String, dynamic> rec) async {
  final f = File('$kAdvOut/$name');
  await f.parent.create(recursive: true);
  await f.writeAsString('${jsonEncode(rec)}\n', mode: FileMode.append, flush: true);
}

Future<void> marker(String name) async {
  final f = File('$kAdvOut/$name');
  await f.parent.create(recursive: true);
  await f.writeAsString('${DateTime.now().millisecondsSinceEpoch}', flush: true);
}

bool hasCjk(String? s) =>
    s != null && s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

Future<T> withTimeout<T>(Future<T> f, int ms, String what) async {
  try {
    return await f.timeout(Duration(milliseconds: ms));
  } on TimeoutException {
    throw AdversarialTimeout(what, ms);
  }
}

class AdversarialTimeout implements Exception {
  AdversarialTimeout(this.what, this.ms);
  final String what;
  final int ms;
  @override
  String toString() => 'TIMEOUT(> ${ms}ms): $what';
}

Future<AppState> waitSettled(MuZhaoController c, {int timeoutMs = 180000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  var last = c.currentState;
  while (DateTime.now().isBefore(deadline)) {
    last = c.currentState;
    if (last.stage == Stage.ready || last.stage == Stage.error) return last;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return last;
}

bool listEq(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// matting rgba → 16x16 灰度剖面（与 host 端 PIL 参考同一口径：分块均值）。
List<int> profile16(Uint8List rgba, int w, int h) {
  final out = List<int>.filled(256, 0);
  final gray = Float64List(w * h);
  for (var i = 0; i < w * h; i++) {
    gray[i] = (rgba[i * 4] * 299 + rgba[i * 4 + 1] * 587 + rgba[i * 4 + 2] * 114) / 1000;
  }
  for (var iy = 0; iy < 16; iy++) {
    for (var ix = 0; ix < 16; ix++) {
      final y0 = iy * h ~/ 16, y1 = (iy + 1) * h ~/ 16;
      final x0 = ix * w ~/ 16, x1 = (ix + 1) * w ~/ 16;
      var s = 0.0;
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          s += gray[y * w + x];
          n++;
        }
      }
      out[iy * 16 + ix] = n == 0 ? 0 : (s / n).round().clamp(0, 255);
    }
  }
  return out;
}

double mad(List<int> a, List<int> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += (a[i] - b[i]).abs();
  }
  return s / a.length;
}

// ---------------------------------------------------------------------------
// engine 用例
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> runEngineCase(
    IdPhotoEngineImpl engine, Map<String, dynamic> c, Uint8List bytes) async {
  final rec = <String, dynamic>{};
  final swMat = Stopwatch()..start();
  MattingResult? mat;
  try {
    final m = await withTimeout(engine.removeBackground(bytes), 90000, 'removeBackground');
    mat = m;
    rec['matting_ms'] = swMat.elapsedMilliseconds;
    rec['matting_size'] = '${m.width}x${m.height}';
    rec['src_size'] = '${m.srcWidth}x${m.srcHeight}';
  } catch (e) {
    rec['matting_ms'] = swMat.elapsedMilliseconds;
    rec['matting_error_type'] = e.runtimeType.toString();
    rec['matting_error'] = e.toString();
    if (e is IdPhotoException) {
      rec['matting_message_zh'] = e.messageZh;
      rec['matting_message_cjk'] = hasCjk(e.messageZh);
    }
  }

  if (mat != null) {
    // 方向验证（仅 e 用例带 ref 剖面）
    if (c['ref'] is List) {
      final prof = profile16(mat.rgba, mat.width, mat.height);
      final mads = <double>[
        mad(prof, (c['ref'] as List).cast<int>()),
        mad(prof, (c['ref_r90'] as List).cast<int>()),
        mad(prof, (c['ref_r180'] as List).cast<int>()),
        mad(prof, (c['ref_r270'] as List).cast<int>()),
      ];
      var best = 0;
      for (var i = 1; i < 4; i++) {
        if (mads[i] < mads[best]) best = i;
      }
      rec['orientation_mads'] = mads.map((m) => m.toStringAsFixed(1)).toList();
      rec['orientation_ok'] = best == 0;
      rec['aspect_ok'] = (c['portrait'] as bool)
          ? mat.srcHeight >= mat.srcWidth
          : mat.srcWidth >= mat.srcHeight;
      // EXIF 用例留 alpha 证据
      try {
        final png = img.Image(width: mat.width, height: mat.height);
        for (final p in png) {
          final v = mat.alpha[p.y * mat.width + p.x];
          png.setPixelR(p.x, p.y, v);
        }
        await File('$kAdvOut/artifacts/${c['id']}_alpha.png')
            .create(recursive: true)
            .then((f) => f.writeAsBytes(img.encodePng(png), flush: true));
      } catch (_) {}
    }

    final swFace = Stopwatch()..start();
    try {
      final face = await withTimeout(engine.detectFace(bytes), 45000, 'detectFace');
      rec['face_ms'] = swFace.elapsedMilliseconds;
      rec['face_found'] = face != null;
      if (face != null) {
        rec['face_order_ok'] = face.chinY > face.headTopY;
        rec['face_conf'] = face.confidence;
      }
    } catch (e) {
      rec['face_error_type'] = e.runtimeType.toString();
      rec['face_error'] = e.toString();
    }

    final swComp = Stopwatch()..start();
    try {
      final cand = await withTimeout(
        engine.compose(
            matting: mat, spec: kDefaultSpec, style: kBgWhite, face: null),
        45000,
        'compose',
      );
      rec['compose_ms'] = swComp.elapsedMilliseconds;
      final decoded = img.decodeJpg(cand.jpegBytes);
      rec['compose_decoded'] = decoded != null;
      if (decoded != null) {
        rec['compose_w'] = decoded.width;
        rec['compose_h'] = decoded.height;
        rec['compose_size_ok'] =
            decoded.width == kDefaultSpec.widthPx &&
                decoded.height == kDefaultSpec.heightPx;
      }
      await File('$kAdvOut/artifacts/${c['id']}_cand.jpg')
          .create(recursive: true)
          .then((f) => f.writeAsBytes(cand.jpegBytes, flush: true));
    } catch (e) {
      rec['compose_error_type'] = e.runtimeType.toString();
      rec['compose_error'] = e.toString();
    }
  }
  return rec;
}

// ---------------------------------------------------------------------------
// sequence 用例
// ---------------------------------------------------------------------------

Future<void> settleOk(MuZhaoController c, List<Map<String, dynamic>> steps,
    String name,
    {Uint8List? expectSource}) async {
  final s = await waitSettled(c);
  final step = <String, dynamic>{
    '$name\_stage': s.stage.name,
    '$name\_err': s.errorMessage,
    '$name\_cands': s.candidates.length,
  };
  if (expectSource != null) {
    step['${name}_src_ok'] = listEq(s.sourceImage, expectSource);
  }
  if (s.candidates.isNotEmpty) {
    final d = img.decodeJpg(s.candidates.first.jpegBytes);
    step['${name}_cand0_decoded'] = d != null;
    step['${name}_cand0_wh'] = d == null ? null : '${d.width}x${d.height}';
  }
  steps.add(step);
}

Future<Map<String, dynamic>> runSeqCase(
    IdPhotoEngineImpl engine, MuZhaoController ctl, String id) async {
  final rec = <String, dynamic>{};
  final steps = <Map<String, dynamic>>[];
  rec['steps'] = steps;
  final aBytes = await File('$kAdvDir/g01.jpg').readAsBytes();
  final bBytes = await File('$kAdvDir/g02.jpg').readAsBytes();
  final corrupt = await File('$kAdvDir/m02_text_as_jpg.jpg').readAsBytes();
  final zero = await File('$kAdvDir/m01_zero_byte.jpg').readAsBytes();

  Future<void> guard(String name, Future<void> Function() body) async {
    final sw = Stopwatch()..start();
    try {
      await body();
      steps.add({'step': name, 'ms': sw.elapsedMilliseconds});
    } catch (e) {
      steps.add({
        'step': name,
        'ms': sw.elapsedMilliseconds,
        'exception_type': e.runtimeType.toString(),
        'exception': e.toString(),
      });
    }
  }

  switch (id) {
    case 'q01_load_during_load':
      await guard('race', () async {
        final f1 = ctl.loadImage(aBytes);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final f2 = ctl.loadImage(bBytes);
        await f1;
        await f2;
        await settleOk(ctl, steps, 'final', expectSource: bBytes);
      });

    case 'q02_spec_during_matting':
      await guard('race', () async {
        final f1 = ctl.loadImage(aBytes);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctl.setSpec(kSpecVisaUs);
        await f1;
        final s = await waitSettled(ctl);
        steps.add({
          'final_stage': s.stage.name,
          'final_spec': s.spec.id,
          'final_cands': s.candidates.length,
          'final_err': s.errorMessage,
        });
        if (s.candidates.isNotEmpty) {
          final d = img.decodeJpg(s.candidates.first.jpegBytes);
          steps.add({'cand0_wh': d == null ? null : '${d.width}x${d.height}'});
        }
      });

    case 'q03_crop_during_load':
      await guard('race', () async {
        await ctl.loadImage(aBytes);
        final s0 = await waitSettled(ctl);
        steps.add({'after_load_a': s0.stage.name});
        final f2 = ctl.loadImage(bBytes);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        ctl.setCrop(const Rect.fromLTWH(120, 180, 240, 320));
        await f2;
        await settleOk(ctl, steps, 'final', expectSource: bBytes);
      });

    case 'q04_rapid_spec7':
      await guard('rapid_spec', () async {
        await ctl.loadImage(aBytes);
        await waitSettled(ctl);
        for (final sp in kBuiltInSpecs) {
          ctl.setSpec(sp); // 不等待，连续切换
        }
        final s = await waitSettled(ctl);
        steps.add({
          'final_stage': s.stage.name,
          'final_spec': s.spec.id,
          'final_cands': s.candidates.length,
        });
        if (s.candidates.isNotEmpty) {
          final d = img.decodeJpg(s.candidates.first.jpegBytes);
          steps.add({'cand0_wh': d == null ? null : '${d.width}x${d.height}'});
        }
      });

    case 'q05_extreme_crops':
      await guard('extreme_crops', () async {
        await ctl.loadImage(aBytes);
        await waitSettled(ctl);
        final rects = <Rect>[
          const Rect.fromLTWH(0, 0, 1, 1),
          const Rect.fromLTWH(0, 0, 1080, 1415),
          const Rect.fromLTWH(-500, -500, 400, 400),
          const Rect.fromLTWH(0, 0, 3000, 3000),
          const Rect.fromLTRB(500, 500, 100, 100), // 反向
          Rect.zero,
          const Rect.fromLTWH(1079, 1414, 1, 1),
          const Rect.fromLTWH(1080, 1415, 100, 100), // 完全在图外
        ];
        for (var i = 0; i < rects.length; i++) {
          ctl.setCrop(rects[i]);
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        final s = await waitSettled(ctl);
        steps.add({
          'final_stage': s.stage.name,
          'final_err': s.errorMessage,
          'final_cands': s.candidates.length,
        });
        if (s.candidates.isNotEmpty) {
          final d = img.decodeJpg(s.candidates.first.jpegBytes);
          steps.add({'cand0_decoded': d != null});
        }
      });

    case 'q06_save_x20':
      await guard('save20', () async {
        await ctl.loadImage(aBytes);
        final s = await waitSettled(ctl);
        if (s.candidates.isEmpty) {
          steps.add({'skip': 'no candidates'});
          return;
        }
        final results = await List.generate(20, (_) => ctl.save(s.candidates.first))
            .wait; // 并发连点
        // 参照真值：候选本身的解码尺寸（控制器当前 spec 可能不是默认 295x413）
        final ref = img.decodeJpg(s.candidates.first.jpegBytes);
        final detail = <Map<String, dynamic>>[];
        var okN = 0, errN = 0;
        final paths = results.toList();
        for (var i = 0; i < paths.length; i++) {
          final d = <String, dynamic>{'i': i, 'path': paths[i].split('/').last};
          try {
            final f = File(paths[i]);
            final exists = await f.exists();
            Uint8List? bytes;
            if (exists) bytes = await f.readAsBytes();
            final decoded = bytes == null ? null : img.decodeJpg(bytes);
            d['exists'] = exists;
            d['bytes'] = bytes?.length;
            d['decoded'] = decoded != null;
            d['decoded_wh'] = decoded == null ? null : '${decoded.width}x${decoded.height}';
            d['size_ok'] = decoded != null && ref != null &&
                decoded.width == ref.width && decoded.height == ref.height;
            if (exists && decoded != null && d['size_ok'] == true) {
              okN++;
              await f.delete();
            } else {
              errN++;
            }
          } catch (e) {
            errN++;
            d['error'] = e.toString();
          }
          detail.add(d);
        }
        steps.add({
          'save_ok': okN,
          'save_bad': errN,
          'distinct_paths': paths.toSet().length,
          'ref_wh': ref == null ? null : '${ref.width}x${ref.height}',
          'detail': detail,
        });
      });

    case 'q07_corrupt_then_valid':
      await guard('race', () async {
        final f1 = ctl.loadImage(corrupt);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final f2 = ctl.loadImage(aBytes);
        await f1;
        await f2;
        await settleOk(ctl, steps, 'final', expectSource: aBytes);
      });

    case 'q08_valid_corrupt_recover':
      await guard('recover', () async {
        await ctl.loadImage(aBytes);
        await settleOk(ctl, steps, 'a', expectSource: aBytes);
        await ctl.loadImage(zero);
        final sErr = await waitSettled(ctl);
        steps.add({
          'err_stage': sErr.stage.name,
          'err_msg': sErr.errorMessage,
          'err_msg_cjk': hasCjk(sErr.errorMessage),
        });
        await ctl.loadImage(bBytes);
        await settleOk(ctl, steps, 'recover', expectSource: bBytes);
      });

    case 'q09_stress_30':
      await guard('stress30', () async {
        final pool = <String>[
          'g01.jpg', 'g02.jpg', 'c04_noisy_portrait.jpg', 'c10_grayscale.jpg',
          'c11_pale_portrait.jpg', 'c05_group.jpg', 'c06_upside_down.jpg',
          'c07_half_face_edge.jpg',
        ];
        final loads = <Map<String, dynamic>>[];
        var readyN = 0, errN = 0;
        final swAll = Stopwatch()..start();
        for (var i = 0; i < 30; i++) {
          final fn = pool[i % pool.length];
          final b = await File('$kAdvDir/$fn').readAsBytes();
          final sw = Stopwatch()..start();
          await ctl.loadImage(b);
          final s = await waitSettled(ctl, timeoutMs: 120000);
          sw.stop();
          s.stage == Stage.ready ? readyN++ : errN++;
          loads.add({'i': i, 'file': fn, 'ms': sw.elapsedMilliseconds, 'stage': s.stage.name});
        }
        swAll.stop();
        steps.add({
          'loads': loads,
          'ready': readyN,
          'err': errN,
          'total_ms': swAll.elapsedMilliseconds,
        });
      });
  }
  return rec;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await applyRuntimeConfig();
  await marker('adv_started');
  final manifest =
      jsonDecode(await File('$kAdvDir/manifest.json').readAsString())
          as Map<String, dynamic>;
  final all = <String, Map<String, dynamic>>{
    for (final c in (manifest['cases'] as List))
      (c as Map<String, dynamic>)['id'] as String: c,
  };
  final ids = kCaseIds;
  await appendJsonl('adv_items.jsonl',
      {'event': 'plan', 'cases': ids, 'out': kAdvOut});

  final engine = IdPhotoEngineImpl();
  try {
    await withTimeout(engine.warmUp(), 120000, 'warmUp');
  } catch (e, st) {
    await appendJsonl('adv_items.jsonl', {
      'event': 'warmup_fail',
      'error': e.toString(),
      'stack': st.toString().split('\n').take(6).join(' | '),
    });
    await marker('done_cases');
    exit(0);
  }
  final ctl = MuZhaoController(engine);

  for (final id in ids) {
    await marker('begin_$id');
    final sw = Stopwatch()..start();
    final rec = <String, dynamic>{'id': id};
    try {
      final c = all[id];
      if (c == null && !id.startsWith('q')) {
        rec['result'] = 'unknown_case';
      } else if (c == null || c['kind'] != 'engine') {
        // q**：controller/引擎时序用例，逻辑写死在 runSeqCase，不进 manifest
        rec.addAll(await runSeqCase(engine, ctl, id));
        rec['result'] = 'done';
      } else {
        final bytes = await File('$kAdvDir/${c['file']}').readAsBytes();
        rec['file'] = c['file'];
        rec['file_bytes'] = bytes.length;
        rec['expect'] = c['expect'];
        rec.addAll(await runEngineCase(engine, c, bytes));
        rec['result'] = 'done';
      }
    } catch (e, st) {
      rec['result'] = 'harness_exception';
      rec['error_type'] = e.runtimeType.toString();
      rec['error'] = e.toString();
      rec['stack_head'] = st.toString().split('\n').take(5).join(' | ');
    }
    rec['total_ms'] = sw.elapsedMilliseconds;
    rec['no_response_over_5s'] = sw.elapsedMilliseconds > 5000;
    await appendJsonl('adv_items.jsonl', {'event': 'item', 'rec': rec});
    await marker('end_$id');
  }
  await marker('done_cases');
  exit(0);
}
