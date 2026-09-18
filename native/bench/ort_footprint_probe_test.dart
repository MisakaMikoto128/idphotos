// ml-porting 自用：ORT 会话/arena 的进程内存足迹探针（Windows host）。
//
// 跑法：flutter test native/bench/ort_footprint_probe_test.dart
//
// G4.7 floor A/B：同一组负载（两个会话 + 黄金集 8 张 + 4958×7017 扫描件），
// A = 会话不带 use_env_allocators（ORT 默认 arena = kNextPowerOf2），
// B = 会话选环境共享分配器（kSameAsRequested），对比：
//   1. 建会话（模型加载+图优化）吃多少；
//   2. 固定负载（9 输入）后 RSS；
//   3. 再 10 轮推理是否继续爬；
//   4. 输出 alpha 是否逐位一致（arena 策略只影响分配，不应影响任何字节）。
// Windows 上没有 dumpsys，用 ProcessInfo.currentRss 近似（相对量足够）。
// 注意：kSameAsRequested=1（任务卡里写的"值 0"是 kNextPowerOf2，
// 头文件 onnxruntime_c_api.h 明确 0=kNextPowerOfTwo, 1=kSameAsRequested）。
@Timeout(Duration(minutes: 15))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/matting/image_ops.dart';
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

int _rss() => ProcessInfo.currentRss;

final List<String> _loadFiles = [
  for (var i = 1; i <= 8; i++)
    '${Directory.current.path}${Platform.pathSeparator}test'
        '${Platform.pathSeparator}golden${Platform.pathSeparator}src'
        '${Platform.pathSeparator}g0$i.jpg',
  // 4958×7017 扫描件（4.7 峰值贡献者）
  'C:${Platform.pathSeparator}Users${Platform.pathSeparator}liuyu'
      '${Platform.pathSeparator}Pictures${Platform.pathSeparator}'
      'Online Verification Report of Student Record_LIU YUANLIN_00.jpg',
];

/// 固定负载：每个输入做一次 512 抠图推理，返回 alpha 输出字节
/// （供 A/B 逐位比对）。
List<Uint8List> _fixedLoad(int matSession) {
  final out = <Uint8List>[];
  for (final p in _loadFiles) {
    final bytes = File(p).readAsBytesSync();
    final image = decodeToRgb(bytes, maxEdge: kEngineMaxEdge);
    final input = modnetInput(
        image.rgb, image.width, image.height, ort.kMattingInputSize);
    final outputs = ort.runFloatInput(
        matSession,
        input,
        <int>[1, 3, ort.kMattingInputSize, ort.kMattingInputSize],
        const <String>[]);
    final v = outputs.first?.value;
    final flat = <double>[];
    void walk(dynamic x) {
      if (x is num) {
        flat.add(x.toDouble());
      } else if (x is List) {
        for (final e in x) {
          walk(e);
        }
      }
    }

    walk(v);
    final b = Uint8List(flat.length);
    for (var i = 0; i < b.length; i++) {
      b[i] = (flat[i] * 255).toInt().clamp(0, 255);
    }
    for (final o in outputs) {
      o?.release();
    }
    out.add(b);
  }
  return out;
}

/// 建两个会话 + 固定负载 + 10 轮交替推理，边跑边报 RSS。
List<Uint8List> _runLoad(String tag) {
  final m0 = _rss();
  final mat = ort.createSession(
      '${ort.debugModelDirectory}${Platform.pathSeparator}'
      'modnet_portrait_1024_int8.onnx');
  final face = ort.createSession(
      '${ort.debugModelDirectory}${Platform.pathSeparator}'
      'face_yunet_2023mar.onnx');
  final m1 = _rss();
  stdout.writeln('[$tag] sessions created: +${(m1 - m0) ~/ 1048576}MB '
      '(provider matting=${mat.provider} face=${face.provider})');

  final outputs = _fixedLoad(mat.address);
  final m2 = _rss();
  stdout.writeln('[$tag] after fixed load (9 inputs): +${(m2 - m1) ~/ 1048576}MB '
      '(abs ${m2 ~/ 1048576}MB)');

  // 交替推理 10 轮看是否继续爬（golden 输入定长，纯 arena 行为观察）。
  final bytes = File(_loadFiles.first).readAsBytesSync();
  final image = decodeToRgb(bytes);
  final input =
      modnetInput(image.rgb, image.width, image.height, ort.kMattingInputSize);
  for (var i = 0; i < 10; i++) {
    final more = ort.runFloatInput(mat.address, input,
        <int>[1, 3, ort.kMattingInputSize, ort.kMattingInputSize], const <String>[]);
    for (final o in more) {
      o?.release();
    }
  }
  final m3 = _rss();
  stdout.writeln('[$tag] after 10 more inferences: +${(m3 - m2) ~/ 1048576}MB '
      '(abs ${m3 ~/ 1048576}MB)');
  ort.releaseSession(mat.address);
  ort.releaseSession(face.address);
  return outputs;
}

void main() {
  _preloadHostOnnxRuntime();
  final repo = Directory.current.path;
  ort.debugModelDirectory =
      '$repo${Platform.pathSeparator}assets${Platform.pathSeparator}models';

  test('ort footprint A/B: default vs kSameAsRequested', () async {
    for (final f in _loadFiles) {
      expect(File(f).existsSync(), isTrue, reason: 'missing input $f');
    }

    // ---- A：默认 arena（kNextPowerOf2，不选环境分配器）----
    ort.debugOptOutEnvAllocator = true;
    expect(ort.applySameAsRequestedArena(), isTrue,
        reason: ort.arenaPolicyError ?? '');
    final outputsA = _runLoad('A:default');

    // ---- B：kSameAsRequested（会话选环境共享分配器）----
    ort.debugOptOutEnvAllocator = false;
    final outputsB = _runLoad('B:sameAsReq');

    // ---- 数值逐位一致 ----
    var mismatch = 0;
    for (var i = 0; i < outputsA.length; i++) {
      final a = outputsA[i];
      final b = outputsB[i];
      if (a.length != b.length) {
        mismatch++;
        continue;
      }
      for (var j = 0; j < a.length; j++) {
        if (a[j] != b[j]) {
          mismatch++;
          break;
        }
      }
    }
    stdout.writeln('bit-exact check: $mismatch/${outputsA.length} '
        'inputs differ');
    expect(mismatch, 0);
  });
}
