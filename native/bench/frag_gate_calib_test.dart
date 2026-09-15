// ml-porting 自用：4.3 碎片化门槛校准数据采集。
//
// 跑法：flutter test native/bench/frag_gate_calib_test.dart
//
// 对 out/gate_G4_batch_ref.json 里的全部 80 项 + 黄金集 8 张，按生产管线
// （decodeToRgb maxEdge 2048 → modnetInput → ORT → 512 alpha）取 alpha，
// 统计：
//   - fg_ratio        前景占比（alpha>=128）
//   - mid_ratio       alpha 处于 64..191 的"不确定带"占比
//   - n_comp / lg_fg / lg_img / lg_top
//       膨胀 dilate_px 轮 3x3 后做连通域：组件数（面积≥16），
//       最大组件的原前景像素占全部前景比（lg_fg）、占整图比（lg_img）、
//       最大组件外接框长边（lg_top，对角线长）。
//   - faces / f_conf / f_area / f_in_lg
//       YuNet 在工作分辨率上检脸：数量 / 最高置信度 / 主脸面积比 /
//       主脸中心是否落在最大连通域内。
// 每项一行 JSON 打到 stdout，供阈值校准。只读测量，不改任何生产代码。
@Timeout(Duration(minutes: 40))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart' show IdPhotoException;
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/matting/ort_runtime.dart'
    show kFaceInputSize, kMattingInputSize;
import 'package:muzhao/core/matting/yunet_decoder.dart';

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

const int kSize = kMattingInputSize;

Uint8List _matteToBytes(dynamic value) {
  final out = Uint8List(kSize * kSize);
  var i = 0;
  void walk(dynamic v) {
    if (v is num) {
      var b = (v * 255).toInt();
      if (b < 0) b = 0;
      if (b > 255) b = 255;
      out[i++] = b;
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  return out;
}

/// 3x3 八邻域膨胀，迭代 [r] 轮。
Uint8List dilate8(Uint8List bin, int w, int h, int r) {
  var cur = bin;
  for (var it = 0; it < r; it++) {
    final next = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final y0 = y > 0 ? y - 1 : 0;
      final y1 = y < h - 1 ? y + 1 : h - 1;
      for (var x = 0; x < w; x++) {
        final x0 = x > 0 ? x - 1 : 0;
        final x1 = x < w - 1 ? x + 1 : w - 1;
        var v = 0;
        for (var yy = y0; yy <= y1 && v == 0; yy++) {
          final base = yy * w;
          for (var xx = x0; xx <= x1; xx++) {
            if (cur[base + xx] != 0) {
              v = 255;
              break;
            }
          }
        }
        next[y * w + x] = v;
      }
    }
    cur = next;
  }
  return cur;
}

class CompStats {
  CompStats(
      this.nComp, this.lgFg, this.lgImg, this.lgTop, this.compFgOf, this.sizes);
  final int nComp;
  final double lgFg; // 最大组件的原前景质量 / 总前景
  final double lgImg; // 最大组件膨胀面积 / 整图
  final double lgTop; // 最大组件外接框对角线 / 512
  final Int32List compFgOf; // 每个原前景像素所属组件（-1=背景）
  final List<int> sizes; // 每组件原前景像素数（降序）
}

CompStats _componentsSimple(Uint8List dil, Uint8List fg, int w, int h) {
  final label = Int32List(w * h);
  final stack = Int32List(w * h);
  var nComp = 0;
  final compFg = <int>[];
  final compArea = <int>[];
  final compMinX = <int>[];
  final compMinY = <int>[];
  final compMaxX = <int>[];
  final compMaxY = <int>[];
  for (var seed = 0; seed < w * h; seed++) {
    if (dil[seed] == 0 || label[seed] != 0) continue;
    nComp++;
    var sp = 0;
    stack[sp++] = seed;
    label[seed] = nComp;
    var area = 0;
    var fgMass = 0;
    var mnx = w, mny = h, mxx = 0, mxy = 0;
    while (sp > 0) {
      final p = stack[--sp];
      area++;
      if (fg[p] != 0) fgMass++;
      final y = p ~/ w, x = p % w;
      if (x < mnx) mnx = x;
      if (x > mxx) mxx = x;
      if (y < mny) mny = y;
      if (y > mxy) mxy = y;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          final q = yy * w + xx;
          if (dil[q] != 0 && label[q] == 0) {
            label[q] = nComp;
            stack[sp++] = q;
          }
        }
      }
    }
    compFg.add(fgMass);
    compArea.add(area);
    compMinX.add(mnx);
    compMinY.add(mny);
    compMaxX.add(mxx);
    compMaxY.add(mxy);
  }
  // 只保留膨胀面积 >= 16 的组件
  final order = List<int>.generate(nComp, (i) => i)
      .where((i) => compArea[i] >= 16)
      .toList();
  final totalFg = compFg.fold<int>(0, (a, b) => a + b);
  order.sort((a, b) => compFg[b].compareTo(compFg[a]));
  final compFgOf = Int32List(w * h);
  for (var p = 0; p < w * h; p++) {
    final l = label[p];
    compFgOf[p] = l == 0 ? -1 : l - 1;
  }
  if (order.isEmpty) {
    return CompStats(0, 0, 0, 0, compFgOf, const <int>[]);
  }
  final best = order.first;
  final diag = math.sqrt(((compMaxX[best] - compMinX[best]) *
          (compMaxX[best] - compMinX[best]) +
      (compMaxY[best] - compMinY[best]) *
          (compMaxY[best] - compMinY[best])).toDouble());
  return CompStats(
    order.length,
    totalFg == 0 ? 0 : compFg[best] / totalFg,
    compArea[best] / (w * h),
    diag / math.sqrt((w * w + h * h).toDouble()),
    compFgOf,
    order.map((i) => compFg[i]).toList()..sort((a, b) => b.compareTo(a)),
  );
}

Future<Map<String, dynamic>> measureOne(
    Uint8List bytes, int mattingSession, int faceSession) async {
  final rec = <String, dynamic>{};
  DecodedImage image;
  try {
    image = decodeToRgb(bytes, maxEdge: kEngineMaxEdge);
  } on IdPhotoException catch (e) {
    rec['decode'] = e.runtimeType.toString();
    return rec;
  }
  rec['w'] = image.width;
  rec['h'] = image.height;

  final input = modnetInput(image.rgb, image.width, image.height, kSize);
  final outputs = ort.runFloatInput(
      mattingSession, input, <int>[1, 3, kSize, kSize], const <String>[]);
  final alpha512 = _matteToBytes(outputs.first!.value);
  for (final o in outputs) {
    o?.release();
  }

  final fg = Uint8List(kSize * kSize);
  var fgCount = 0, midCount = 0;
  for (var i = 0; i < alpha512.length; i++) {
    final v = alpha512[i];
    if (v >= 128) {
      fg[i] = 255;
      fgCount++;
    } else if (v >= 64) {
      midCount++;
    }
  }
  rec['fg_ratio'] = fgCount / alpha512.length;
  rec['mid_ratio'] = midCount / alpha512.length;

  for (final r in <int>[2, 4, 6]) {
    final dil = dilate8(fg, kSize, kSize, r);
    final st = _componentsSimple(dil, fg, kSize, kSize);
    rec['d$r'] = <String, dynamic>{
      'n_comp': st.nComp,
      'lg_fg': double.parse(st.lgFg.toStringAsFixed(4)),
      'lg_img': double.parse(st.lgImg.toStringAsFixed(4)),
      'lg_top': double.parse(st.lgTop.toStringAsFixed(4)),
      'sizes_head': st.sizes.take(8).toList(),
    };
  }

  // 人脸（生产同口径：pickSubjectFace + 面积比过滤）
  final li = yunetInput(image.rgb, image.width, image.height, kFaceInputSize);
  final fouts = ort.runFloatInput(
      faceSession,
      li.data,
      <int>[1, 3, kFaceInputSize, kFaceInputSize],
      kYunetOutputNames);
  final raw = <RawFace>[];
  try {
    for (var i = 0; i < kYunetStrides.length; i++) {
      raw.addAll(decodeStride(
          kYunetStrides[i],
          kFaceInputSize,
          _flatten(fouts[i]?.value),
          _flatten(fouts[3 + i]?.value),
          _flatten(fouts[6 + i]?.value),
          _flatten(fouts[9 + i]?.value)));
    }
  } finally {
    for (final o in fouts) {
      o?.release();
    }
  }
  final kept = nonMaxSuppression(raw);
  rec['faces'] = kept.length;
  if (kept.isNotEmpty) {
    final subject = pickSubjectFace(kept, image.width, image.height);
    final face = toFaceInfo(subject, li.scale, image.width, image.height);
    rec['f_conf'] = double.parse(face.confidence.toStringAsFixed(3));
    rec['f_area'] = double.parse(
        (face.box.width * face.box.height / (image.width * image.height))
            .toStringAsFixed(4));
    // 主脸中心在 512 alpha 坐标里是否落在前景上
    final fx = (face.box.center.dx / image.width * kSize).floor().clamp(0, kSize - 1);
    final fy = (face.box.center.dy / image.height * kSize)
        .floor()
        .clamp(0, kSize - 1);
    rec['face_on_fg'] = fg[fy * kSize + fx] != 0;
  }
  return rec;
}

List<double> _flatten(dynamic value) {
  final out = <double>[];
  void walk(dynamic v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  return out;
}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  ort.debugModelDirectory =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
  final matting = ort
      .createSession(
          '${ort.debugModelDirectory}${Platform.pathSeparator}'
          'modnet_portrait_int8.onnx')
      .address;
  final face = ort
      .createSession(
          '${ort.debugModelDirectory}${Platform.pathSeparator}'
          'face_yunet_2023mar.onnx')
      .address;

  final cases = <String, String>{};
  // 黄金集
  for (var i = 1; i <= 8; i++) {
    cases['golden_g0$i'] =
        '$repo${Platform.pathSeparator}test${Platform.pathSeparator}golden'
        '${Platform.pathSeparator}src${Platform.pathSeparator}g0$i.jpg';
  }
  // 批量 80 项
  final ref = File(
          '$repo${Platform.pathSeparator}out${Platform.pathSeparator}'
          'gate_G4_batch_ref.json')
      .readAsStringSync();
  final refJson = jsonDecode(ref) as Map<String, dynamic>;
  final seen = <String>{};
  var idx = 0;
  for (final it in refJson['items'] as List) {
    final m = it as Map<String, dynamic>;
    final p = m['sourcePath'] as String;
    if (seen.contains(p)) continue;
    seen.add(p);
    final cls = m['class'] as String;
    final outcome = m['outcome'] as String;
    cases['batch_${idx.toString().padLeft(2, '0')}_${cls}_$outcome'] = p;
    idx++;
  }

  final lines = <String>[];
  test('collect fragmentation calibration data', () async {
    for (final entry in cases.entries) {
      final f = File(entry.value);
      final rec = <String, dynamic>{'id': entry.key};
      if (!f.existsSync()) {
        rec['decode'] = 'missing';
        continue;
      }
      Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        rec['decode'] = 'read_error';
        continue;
      }
      rec['bytes'] = bytes.length;
      try {
        rec.addAll(await measureOne(bytes, matting, face));
      } on IdPhotoException catch (e) {
        rec['decode'] = e.runtimeType.toString();
      } catch (e) {
        rec['error'] = e.toString();
      }
      final line = jsonEncode(rec);
      lines.add(line);
      stdout.writeln(line);
    }
    File('$repo${Platform.pathSeparator}out${Platform.pathSeparator}'
            'frag_calib_raw.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
    // 写在 out/ 仅为本 agent 校准工件；正式判据代码不引用该文件。
  }, timeout: const Timeout(Duration(minutes: 35)));
}
