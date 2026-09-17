// qa-batch 诊断：把生产 removeBackground 的 alpha / rgba 直接落盘，
// 用于判断"成片脸上的白洞"是 **alpha 有洞** 还是 **合成/裁剪引入**。
//
//   flutter test test/batch/p0_alpha_dump_test.dart
//
// 产出 out/P0_anchors/alpha/<id>_alpha.png 与 <id>_rgba.png。
// 本文件只落盘原始引擎输出，不做任何判定。
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/imaging/compose_engine.dart';
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

class _Engine with MattingEngineMixin, ComposeEngineMixin implements IdPhotoEngine {
  @override
  void dispose() => disposeMattingEngine();
}

const List<String> kIds = <String>[
  'c08',
  'c08_d-10',
  'c08_upright',
  'c04_d-10',
  'c11_d-10',
];

/// 「裸 id」那批（c01..c12/p1/p2）在 `out/P0_anchors/<id>.png` 里是
/// `p0_measure.py` 画的测量 overlay —— `save_overlay` 会画 5 条贯穿画面中心的
/// 整条直线，**不是干净图**。喂进 `removeBackground` 会改变抠图结果，于是
/// `out/P0_anchors/alpha/<id>_magenta.jpg` 与未画的同一张图不可比
/// （曾导致 `P0_output_residual.json` 里 `c08`（`corpus: anchor`）报 `alphaHole: true`，
/// 与 `P0_alpha_holes.json`"未旋转真实照片无洞"的结论相左）。
/// 未旋转对照必须取原始照片，故从 truth 的 `anchors`/`straight` 里取 path。
Map<String, String> _cleanSource(String repo, String sep) {
  final out = <String, String>{};
  final f = File('$repo${sep}out${sep}P0_truth.json');
  if (!f.existsSync()) return out;
  final t = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  for (final key in <String>['anchors', 'straight']) {
    for (final dynamic a in (t[key] as List<dynamic>? ?? <dynamic>[])) {
      final m = a as Map<String, dynamic>;
      out[m['id'] as String] = (m['path'] as String).replaceAll('/', sep);
    }
  }
  return out;
}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  ort.debugModelDirectory = '$repo${sep}assets${sep}models';
  final engine = _Engine();
  final outDir = Directory('$repo${sep}out${sep}P0_anchors${sep}alpha');

  setUpAll(() async {
    await engine.warmUp();
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
  });
  tearDownAll(() => engine.disposeMattingEngine());

  test('dump alpha / rgba for white-hole triage', () async {
    final clean = _cleanSource(repo, sep);
    for (final id in kIds) {
      final p = clean[id] ?? '$repo${sep}out${sep}P0_anchors${sep}$id.png';
      final f = File(p);
      if (!f.existsSync()) {
        stdout.writeln('MISSING $id <- $p');
        continue;
      }
      stdout.writeln('SRC $id <- $p');
      try {
        final m = await engine.removeBackground(await f.readAsBytes());
        final a = img.Image.fromBytes(
            width: m.width,
            height: m.height,
            bytes: Uint8List.fromList(m.alpha).buffer,
            numChannels: 1);
        File('${outDir.path}${sep}${id}_alpha.png')
            .writeAsBytesSync(img.encodePng(a));
        final rgba = img.Image.fromBytes(
            width: m.width, height: m.height, bytes: m.rgba.buffer);
        File('${outDir.path}${sep}${id}_rgba.png')
            .writeAsBytesSync(img.encodePng(rgba));
        var zero = 0, mid = 0;
        for (final v in m.alpha) {
          if (v == 0) zero++;
          if (v > 0 && v < 255) mid++;
        }
        stdout.writeln('OK $id alpha ${m.width}x${m.height} '
            'work=${m.width}x${m.height} src=${m.srcWidth}x${m.srcHeight} '
            'zero=${(zero / m.alpha.length * 100).toStringAsFixed(2)}% '
            'soft=${(mid / m.alpha.length * 100).toStringAsFixed(2)}%');

        // 洋红底重合成：alpha=0 处会变成 #FF00FF。脸上的白斑若变洋红
        // → 是 alpha 空洞；若仍是白 → 是 rgba 内容问题。这是判定性的。
        final face = await engine.detectFace(await f.readAsBytes());
        final cand = await engine.compose(
          matting: m,
          spec: kSpecCnBig1inch,
          style: const BackgroundStyle(
              id: 'magenta', nameZh: '洋红', colorTop: 0xFFFF00FF),
          face: face,
        );
        File('${outDir.path}${sep}${id}_magenta.jpg')
            .writeAsBytesSync(cand.jpegBytes);
        stdout.writeln('   magenta composed, straightenDeg='
            '${engine.lastDiagnostics?.straightenDeg}');
      } catch (e) {
        stdout.writeln('FAIL $id ${e.runtimeType}: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 25)));
}
