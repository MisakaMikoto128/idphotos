// ml-porting 自用：G4.7 双杠杆设备端探针（arena 策略 A/B + 解码瞬态归因）。
//
// 构建运行（与 batch runner 同一套规程；换 --target 前必须 flutter clean，
// 见 PITFALLS「Windows 增量构建保留旧入口点」）：
//   flutter clean && flutter build apk --release --target=native/bench/ml_probe2_main.dart
//   adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-release.apk
//   adb -s emulator-5554 shell am start -W --ez enable-impeller false \
//     -n com.muzhao.muzhao/.MainActivity
//   adb -s emulator-5554 logcat -d -s flutter | grep PROBE2
//
// 回答四个问题（每个答案一行 PROBE2 日志，供报告引用）：
//   P1  dart:ui 降采样解码对 orientation=6 是否真的摆正（主 isolate）；
//   P2  dart:ui 解码能否在后台 isolate（Isolate.run）里跑；
//   P3  arena A/B：kNextPowerOf2（默认） vs kSameAsRequested 的
//       warmUp floor 与单张 4032×3024 抠图瞬态峰值；
//   P4  image 包全解码兜底路径（decodeToRgb maxEdge）的瞬态峰值——
//       r4 的 +65.6MB "全分辨率解码" 假说是否成立。
// 输入：QA_DIR（默认 /data/local/tmp/muzhao_qa_tmp/in）下的 1979d869*.png
// （实为 JPEG）与 4958×7017 扫描件；缺失时跳过对应段（打印 MISSING）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/matting/flutter_decode.dart';
import 'package:muzhao/core/matting/image_ops.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

const kQaDir = String.fromEnvironment(
    'QA_DIR', defaultValue: '/data/local/tmp/muzhao_qa_tmp/in');

int _rssKb() {
  try {
    for (final line in File('/proc/self/status').readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        return int.parse(line.split(RegExp(r'\s+'))[1]);
      }
    }
  } catch (_) {}
  return -1;
}

void _log(String tag) {
  final kb = _rssKb();
  // ignore: avoid_print
  print('PROBE2 $tag rss=${(kb / 1024).toStringAsFixed(1)}MB');
}

/// 边跑边采样 RSS，返回相对起点的峰值增量（KB）。
Future<int> _peakKbWhile(Future<void> Function() body) async {
  var peak = 0;
  final base = _rssKb();
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final v = _rssKb();
    if (v > peak) peak = v;
  });
  try {
    await body();
  } finally {
    t.cancel();
  }
  return peak - base;
}

// ---------------------------------------------------------------------------
// P1/P2：orientation=6 样张（手法抄 image_pkg_exif_probe_test.dart）
// ---------------------------------------------------------------------------

Uint8List _makeBaseJpeg(int width, int height) {
  final im = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final red = y < height ~/ 4;
      im.setPixelRgba(x, y, red ? 255 : 0, 0, red ? 0 : 255, 255);
    }
  }
  return img.encodeJpg(im, quality: 95);
}

Uint8List _spliceExifOrientation6(Uint8List jpg) {
  final tiff = BytesBuilder()
    ..add([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    ..add([0x01, 0x00])
    ..add([
      0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 //
    ])
    ..add([0x00, 0x00, 0x00, 0x00]);
  final body = BytesBuilder()
    ..add('Exif'.codeUnits)
    ..add([0x00, 0x00])
    ..add(tiff.toBytes());
  final b = body.toBytes();
  final out = BytesBuilder()
    ..add([0xFF, 0xD8])
    ..add([0xFF, 0xE1, b.length >> 8 & 0xFF, b.length & 0xFF])
    ..add(b)
    ..add(jpg.sublist(2));
  return out.toBytes();
}

/// 摆正后（orientation 6 = 原顶边转到右侧）：右带应为红，左带应为蓝。
String _judgeRotated(UiDecodeResult r) {
  final w = r.width;
  final h = r.height;
  String redBand() {
    var red = 0;
    var blue = 0;
    for (var y = 0; y < h; y++) {
      for (var x = w * 3 ~/ 4; x < w; x++) {
        final o = (y * w + x) * 4;
        if (r.rgba[o] > 200 && r.rgba[o + 2] < 60) {
          red++;
        } else if (r.rgba[o + 2] > 200 && r.rgba[o] < 60) {
          blue++;
        }
      }
    }
    return red > blue ? 'red' : (blue > red ? 'blue' : 'mixed');
  }

  return 'right=${redBand()}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('start');

  // 找输入
  File? bigPng; // 4032×3024（实为 JPEG 的 .png）
  File? scan; // 4958×7017 扫描件
  final dir = Directory(kQaDir);
  if (dir.existsSync()) {
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final n = f.path.split('/').last;
      if (n.startsWith('1979d869')) bigPng = f;
      if (n.contains('Online')) scan = f;
    }
  }
  _log('inputs png=${bigPng != null} scan=${scan != null}');

  // ---- P1：主 isolate 的 dart:ui orientation=6 摆正 ----
  final spliced = _spliceExifOrientation6(_makeBaseJpeg(64, 128));
  // 摆正后 128×64（宽高互换）
  final r1 = await decodeDownsampledUi(spliced, 128, 64);
  if (r1 == null) {
    // ignore: avoid_print
    print('PROBE2 P1 dart_ui_rotated=FAIL decode_null');
  } else {
    // ignore: avoid_print
    print('PROBE2 P1 dart_ui_rotated=OK dims=${r1.width}x${r1.height} '
        '${_judgeRotated(r1)}');
  }

  // ---- P2：后台 isolate 里 dart:ui 解码 ----
  try {
    final r2 = await Isolate.run(() async {
      final s = _spliceExifOrientation6(_makeBaseJpeg(64, 128));
      return decodeDownsampledUi(s, 128, 64);
    });
    // ignore: avoid_print
    print('PROBE2 P2 dart_ui_in_isolate=${r2 == null ? "FAIL_decode_null" : "OK dims=${r2.width}x${r2.height} ${_judgeRotated(r2)}"}');
  } catch (e) {
    // ignore: avoid_print
    print('PROBE2 P2 dart_ui_in_isolate=THROW ${e.runtimeType}: $e');
  }

  // ---- P3：arena 归因矩阵（崩溃顺序敏感，按风险从低到高排）----
  // 每个变体单独一个进程跑（config 选 variant）：
  //   A0：插件建会话 + 不注册分配器 —— 基准（当前 head 的 release 行为）
  //   A ：FFI 建会话 + 不注册分配器 —— 消掉"FFI 建会话"变量
  //   C ：FFI 建会话 + 注册 + 只用 CPU EP —— arena(kSameAsRequested) + CPU
  //   B ：FFI 建会话 + 注册 + XNNPACK —— 实测在此 SIGSEGV
  // probe_config.json {"variant":"A0"} 选单跑；缺省跑全部（崩溃即止）。
  final pngBytes = await bigPng?.readAsBytes();
  final scanBytes = await scan?.readAsBytes();

  Future<void> runVariant(String tag, String? forceEp) async {
    ort.debugForceEp = forceEp;
    var engine = _Engine();
    await engine.warmUp();
    _log('$tag warmUp provider=${engine.mattingProvider} '
        'arenaNote=${ort.arenaPolicyError ?? "ok"}');
    if (pngBytes != null) {
      final swAll = Stopwatch()..start();
      await _safe(() => engine.removeBackground(pngBytes));
      swAll.stop();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      var best = 1 << 40;
      final times = <int>[];
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        final p = await _peakKbWhile(() async {
          await _safe(() => engine.removeBackground(pngBytes));
        });
        sw.stop();
        times.add(sw.elapsedMilliseconds);
        if (p < best) best = p;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // ignore: avoid_print
      print('PROBE2 P3-$tag removeBackground4032 peak=+${(best / 1024).toStringAsFixed(1)}MB '
          'ms=${times.join("/")}(warmup ${swAll.elapsedMilliseconds})');
    }
    if (scanBytes != null) {
      await _safe(() => engine.removeBackground(scanBytes));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      var best = 1 << 40;
      for (var i = 0; i < 2; i++) {
        final p = await _peakKbWhile(() async {
          await _safe(() => engine.removeBackground(scanBytes));
        });
        if (p < best) best = p;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // ignore: avoid_print
      print('PROBE2 P3-$tag removeBackgroundSCAN peak=+${(best / 1024).toStringAsFixed(1)}MB');
    }
    _log('$tag after loads');
    await engine.disposeMattingEngine();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    _log('$tag disposed');
  }

  final variantFile = File('$kQaDir/probe_config.json');
  final variant = variantFile.existsSync()
      ? (RegExp(r'"variant"\s*:\s*"([A-Z0-9]+)"')
              .firstMatch(variantFile.readAsStringSync())
              ?.group(1) ??
          'ALL')
      : 'ALL';
  _log('variant=$variant');

  if (variant == 'P' || variant == 'ALL') {
    // 生产路径冒烟：所有 bench 开关保持默认（FFI 建会话、无 arena 政策）。
    ort.debugSkipEnvAllocatorRegistration = false;
    await runVariant('P_prod_default', null);
    ort.debugSkipEnvAllocatorRegistration = false;
  }

  if (variant == 'A0' || variant == 'ALL') {
    ort.debugUsePluginSessionCreation = true;
    ort.debugSkipEnvAllocatorRegistration = true;
    await runVariant('A0_plugin', null);
    ort.debugUsePluginSessionCreation = false;
  }
  if (variant == 'A' || variant == 'ALL') {
    ort.debugSkipEnvAllocatorRegistration = true;
    await runVariant('A_ffi_default', null);
    ort.debugSkipEnvAllocatorRegistration = false;
  }
  if (variant == 'C' || variant == 'ALL') {
    await runVariant('C_arena_cpu', 'cpu');
  }
  if (variant == 'P4' || variant == 'ALL') {
    // P4：image 包全解码兜底路径的瞬态（isolate 内 decode → 立即降采样）
    if (pngBytes != null || scanBytes != null) {
      final b = pngBytes ?? scanBytes!;
      await Isolate.run(() => decodeToRgb(b, maxEdge: kEngineMaxEdge));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      var best = 1 << 40;
      for (var i = 0; i < 3; i++) {
        final p = await _peakKbWhile(
            () => Isolate.run(() => decodeToRgb(b, maxEdge: kEngineMaxEdge)));
        if (p < best) best = p;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // ignore: avoid_print
      print('PROBE2 P4 imagepkg_fallback_decode peak=+${(best / 1024).toStringAsFixed(1)}MB input=${b.length ~/ 1024}KB');
    }
  }
  if (variant == 'D' || variant == 'ALL') {
    // 注册但不选入（xnnpack）：区分"注册本身毒化 XNNPACK 会话"与"选入共享 arena"
    ort.debugSkipEnvAllocatorRegistration = false;
    ort.debugOptOutEnvAllocator = true;
    await runVariant('D_reg_noopin_xnnpack', null);
    ort.debugOptOutEnvAllocator = false;
    ort.debugSkipEnvAllocatorRegistration = true;
  }
  if (variant == 'E' || variant == 'ALL') {
    // xnnpack + 无 arena（DisableCpuMemArena）：floor 压缩的替代杠杆
    ort.debugSkipEnvAllocatorRegistration = true;
    ort.debugDisableCpuMemArena = true;
    await runVariant('E_noarena_xnnpack', null);
    ort.debugDisableCpuMemArena = false;
    ort.debugSkipEnvAllocatorRegistration = true;
  }
  if (variant == 'B' || variant == 'ALL') {
    await runVariant('B_arena_xnnpack', 'xnnpack');
  }
  ort.debugForceEp = null;

  _log('end');
  exit(0);
}

class _Engine with MattingEngineMixin {}

Future<void> _safe(Future<void> Function() f) async {
  try {
    await f();
  } catch (_) {
    // 测量内存，不关心业务结果（NoFace/Matting 异常都是路径走完后才抛）。
  }
}
