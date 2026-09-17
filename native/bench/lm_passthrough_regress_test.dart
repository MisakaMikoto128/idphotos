// ml-porting 自用：P0 歪斜修复接力第一棒的回归验证。
//
// 跑法：flutter test native/bench/lm_passthrough_regress_test.dart
//
// 两个断言面：
//  1. 黄金集 8/8 的 detectFace 返回非空 landmarks（Float32List 长度 10），
//     且 5 个点都落在人脸框中心 ± 对角线范围内（工作分辨率坐标）。
//  2. matting 回归：黄金集 8 张 removeBackground 的 alpha 逐位 sha256
//     写入 out/lm_passthrough_alpha.jsonl —— 解码改动前后各跑一次比对，
//     确认 IoU/MAE 口径逐位不变。
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/api.dart';
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

class _Engine with MattingEngineMixin {}

/// flutter_test VM 里没有 dart:crypto，逐位回归用 64 位 FNV-1a 就够。
String _fnv1a(Uint8List b) {
  var h = 0xcbf29ce484222325;
  for (final v in b) {
    h ^= v;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  ort.debugModelDirectory =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
  final engine = _Engine();

  setUpAll(() => engine.warmUp());
  tearDownAll(() => engine.disposeMattingEngine());

  test('golden 8: landmarks passthrough + matting alpha hash', () async {
    final lines = <String>[];
    var lmOk = 0;
    for (var i = 1; i <= 8; i++) {
      final id = 'g0$i';
      final f = File('$repo${Platform.pathSeparator}test'
          '${Platform.pathSeparator}golden${Platform.pathSeparator}src'
          '${Platform.pathSeparator}$id.jpg');
      final bytes = await f.readAsBytes();
      // 顺序与 controller 一致：先 removeBackground（同实例命中缓存）。
      final m = await engine.removeBackground(bytes);
      final alphaHash = _fnv1a(m.alpha);
      final face = await engine.detectFace(bytes);
      final rec = <String, dynamic>{'id': id, 'alpha_sha256': alphaHash};
      if (face == null) {
        rec['face'] = null;
      } else {
        final lm = face.landmarks;
        rec['lm_null'] = lm == null;
        if (lm != null) {
          rec['lm_len'] = lm.length;
          // 校验：5 个点都落在 box 中心 ± 对角线内。
          final b = face.box;
          final cx = b.center.dx;
          final cy = b.center.dy;
          final r = math.sqrt(b.width * b.width + b.height * b.height);
          var inside = true;
          final pts = <List<double>>[];
          for (var k = 0; k < 5; k++) {
            final px = lm[k * 2];
            final py = lm[k * 2 + 1];
            pts.add([px, py]);
            final d = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
            if (!(d <= r + 1e-6)) inside = false;
          }
          rec['lm_in_box'] = inside;
          rec['lm'] = pts;
          rec['box'] = [b.left, b.top, b.width, b.height];
          rec['rollDeg'] = face.rollDeg;
          if (lm.length == 10 && inside) lmOk++;
        }
      }
      lines.add(jsonEncode(rec));
      stdout.writeln(jsonEncode(rec));
    }
    File('$repo${Platform.pathSeparator}out${Platform.pathSeparator}'
            'lm_passthrough_alpha.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
    stdout.writeln('SUMMARY landmarks_ok=$lmOk/8');
    expect(lmOk, 8, reason: '黄金集 8/8 landmarks 非空且落点合理');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
