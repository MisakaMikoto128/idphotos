// ml-porting 自用：G4.3 门槛修改后的全量数据集回归（生产路径，Windows host）。
//
// 跑法：flutter test native/bench/dataset_gate_regress_test.dart
//
// 对 out/gate_G4_batch_ref.json 的 80 项 + 黄金集 8 张，按 controller 的
// 调用顺序（removeBackground → detectFace 同一 bytes 实例）走生产引擎，
// 逐项记录结果：成功 / 拒绝（异常类型）。预期：
//   - golden 8 + portrait 11 + multi_face 3 = 14 张人像全部成功；
//   - 其余全部抛契约异常（MattingException 为主），进程零崩溃。
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
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

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  ort.debugModelDirectory =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';
  final engine = _Engine();

  setUpAll(() => engine.warmUp());
  tearDownAll(() => engine.disposeMattingEngine());

  test('dataset regression via production engine', () async {
    final cases = <String, Map<String, String>>{};
    for (var i = 1; i <= 8; i++) {
      cases['golden_g0$i'] = {
        'path':
            '$repo${Platform.pathSeparator}test${Platform.pathSeparator}golden'
            '${Platform.pathSeparator}src${Platform.pathSeparator}g0$i.jpg',
        'class': 'golden',
      };
    }
    final ref = File('$repo${Platform.pathSeparator}out'
            '${Platform.pathSeparator}gate_G4_batch_ref.json')
        .readAsStringSync();
    final items = (jsonDecode(ref) as Map<String, dynamic>)['items'] as List;
    final seen = <String>{};
    for (final it in items) {
      final m = it as Map<String, dynamic>;
      final p = m['sourcePath'] as String;
      if (!seen.add(p)) continue;
      cases['b_${m['class']}_${seen.length}'] = {
        'path': p,
        'class': m['class'] as String,
      };
    }

    var okPortraits = 0;
    var failPortraits = 0;
    var rejected = 0;
    var unexpected = 0;
    final lines = <String>[];
    cases.forEach((id, c) async {});
    for (final entry in cases.entries) {
      final f = File(entry.value['path']!);
      final rec = <String, dynamic>{'id': entry.key};
      if (!f.existsSync()) {
        rec['outcome'] = 'missing';
        lines.add(jsonEncode(rec));
        continue;
      }
      Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        rec['outcome'] = 'read_error';
        lines.add(jsonEncode(rec));
        continue;
      }
      // controller 同序：removeBackground → detectFace（同实例，应命中缓存）
      try {
        final m = await engine.removeBackground(bytes);
        final face = await engine.detectFace(bytes);
        rec['outcome'] = 'success';
        rec['face'] = face != null;
        rec['matting_dims'] = '${m.width}x${m.height}';
        if (entry.value['class'] == 'golden' ||
            entry.value['class'] == 'portrait' ||
            entry.value['class'] == 'multi_face') {
          okPortraits++;
        } else {
          // 非人像却成功 = 伪成功
          rec['unexpected'] = true;
          unexpected++;
        }
      } on IdPhotoException catch (e) {
        rec['outcome'] = 'rejected';
        rec['exc'] = e.runtimeType.toString();
        rec['zh'] = e.messageZh;
        if (entry.value['class'] == 'golden' ||
            entry.value['class'] == 'portrait' ||
            entry.value['class'] == 'multi_face') {
          rec['unexpected'] = true;
          unexpected++;
          failPortraits++;
        } else {
          rejected++;
        }
      } catch (e) {
        rec['outcome'] = 'CRASH';
        rec['err'] = e.toString();
        unexpected++;
      }
      lines.add(jsonEncode(rec));
      stdout.writeln(jsonEncode(rec));
    }
    File('$repo${Platform.pathSeparator}out${Platform.pathSeparator}'
            'dataset_gate_regress.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
    stdout.writeln('SUMMARY portraits_ok=$okPortraits portraits_fail='
        '$failPortraits nonportrait_rejected=$rejected '
        'unexpected=$unexpected total=${cases.length}');
    expect(unexpected, 0, reason: '伪成功/人像误杀/进程崩溃 必须为 0');
  }, timeout: const Timeout(Duration(minutes: 55)));
}
