// qa-batch：Pictures 全量 alpha 扫描（判断"抠图把脸挖空"是不是独立于摆正的真实缺陷）。
//
//   flutter test test/batch/p0_alpha_scan_test.dart
//
// 背景：P0 端到端残余里发现 c08 家族的成片上眼睛被 alpha=0 覆盖。需要判定
// 这是"夹具/旋转"引入的，还是**未旋转的真实照片本来就有**——后者是独立于摆正的
// 用户可见缺陷（脸上一个洞）。
//
// ⚠️ 必须用**干净原图**。out/P0_anchors/<id>.png 里 anchor 那批是画了测量线的
// overlay（c08.png 951KB vs 原图 158KB），拿它去抠图得到的 alpha 不作数。
//
// 只落 alpha（+ manifest），不做判定；判定在 p0_alpha_holes.py。
// 产出：out/P0_alpha_scan/<slug>_alpha.png、out/P0_alpha_scan/manifest.jsonl
@Timeout(Duration(minutes: 60))
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

/// team-lead 点名的两张干净原图 + c08 夹具家族（**干净**，无 overlay）作对照组。
/// 只有 c08 的**未旋转**原图有洞才是独立事故；夹具上有洞则说明是旋转诱导的。
const List<String> kExtra = <String>[
  r'C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg',
  r'C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_21_Pro.jpg',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d+3.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d+5.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d+10.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d-3.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d-5.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_d-10.png',
  r'C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\P0_anchors\c08_upright.png',
];

String _slug(String p) {
  final s = p.replaceAll('\\', '/').split('/').last;
  return s.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  final sep = Platform.pathSeparator;
  ort.debugModelDirectory = '$repo${sep}assets${sep}models';
  final engine = _Engine();
  final outDir = Directory('$repo${sep}out${sep}P0_alpha_scan');

  setUpAll(() async {
    await engine.warmUp();
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
  });
  tearDownAll(() => engine.disposeMattingEngine());

  test('alpha scan over Pictures + named originals', () async {
    final ds = jsonDecode(
        File('$repo${sep}test${sep}dataset.json').readAsStringSync())
        as Map<String, dynamic>;
    final paths = <String>[];
    for (final it in ds['items'] as List) {
      paths.add((it as Map<String, dynamic>)['path'] as String);
    }
    for (final p in kExtra) {
      if (!paths.contains(p)) paths.add(p);
    }

    final lines = <String>[];
    var ok = 0, fail = 0;
    for (final raw in paths) {
      final path = raw.replaceAll('/', sep);
      final rec = <String, Object?>{'path': raw.replaceAll('\\', '/')};
      final f = File(path);
      if (!f.existsSync()) {
        rec['outcome'] = 'missing';
        lines.add(jsonEncode(rec));
        continue;
      }
      try {
        final bytes = await f.readAsBytes();
        final m = await engine.removeBackground(bytes);
        final slug = _slug(raw);
        rec['outcome'] = 'ok';
        rec['slug'] = slug;
        rec['workW'] = m.width;
        rec['workH'] = m.height;
        rec['srcW'] = m.srcWidth;
        rec['srcH'] = m.srcHeight;
        // 原始（未做 EXIF 转置）像素尺寸，供 Python 侧算坐标换算系数
        final dec = img.decodeImage(bytes);
        rec['fileW'] = dec?.width;
        rec['fileH'] = dec?.height;
        rec['exifOrientation'] =
            (dec != null && dec.exif.imageIfd.hasOrientation)
                ? dec.exif.imageIfd.orientation
                : 1;
        final a = img.Image.fromBytes(
            width: m.width,
            height: m.height,
            bytes: Uint8List.fromList(m.alpha).buffer,
            numChannels: 1);
        File('${outDir.path}${sep}${slug}_alpha.png')
            .writeAsBytesSync(img.encodePng(a));
        ok++;

        // 对 team-lead 点名的两张额外出洋红合成片作肉眼证据
        if (kExtra.contains(raw)) {
          final face = await engine.detectFace(await f.readAsBytes());
          final cand = await engine.compose(
            matting: m,
            spec: kSpecCnBig1inch,
            style: const BackgroundStyle(
                id: 'magenta', nameZh: '洋红', colorTop: 0xFFFF00FF),
            face: face,
          );
          File('${outDir.path}${sep}${slug}_magenta.jpg')
              .writeAsBytesSync(cand.jpegBytes);
          rec['rollSource'] = face?.rollSource.name;
          rec['rollDeg'] = face?.rollDeg;
          rec['straightenDeg'] = engine.lastDiagnostics?.straightenDeg;
        }
      } catch (e) {
        rec['outcome'] = 'fail';
        rec['err'] = e.toString();
        if (e is IdPhotoException) rec['zh'] = e.messageZh;
        fail++;
      }
      lines.add(jsonEncode(rec));
    }
    File('${outDir.path}${sep}manifest.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
    stdout.writeln('SUMMARY ok=$ok fail=$fail total=${paths.length}');
  }, timeout: const Timeout(Duration(minutes: 55)));
}
