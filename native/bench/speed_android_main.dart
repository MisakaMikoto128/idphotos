// 抠图提速专项：Android（模拟器 x86_64）延迟探针。ml-porting 自用，不是门禁。
//
// 跑法（Windows，仓库根目录；换 --target 必须先 flutter clean，见
// PITFALLS「Windows 增量构建保留旧入口点」）：
//   gradlew --stop                       （防内存挤爆，PITFALLS 有案）
//   flutter emulators --launch Pixel_3a_API_34_extension_level_7_x86_64
//   adb -s emulator-5554 shell mkdir -p /data/local/tmp/speed_in
//   adb -s emulator-5554 push test/golden/src/g01.jpg /data/local/tmp/speed_in/
//   flutter clean && set MUZHAO_EXTRA_ABIS=x86_64&& flutter build apk --release ^
//     --target=native/bench/speed_android_main.dart
//   adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-release.apk
//   adb -s emulator-5554 shell am start -W -n com.muzhao.muzhao/.MainActivity
//   adb -s emulator-5554 logcat -d | findstr SPEED
//
// 口径：与 G2A.6 同夹具——g01.jpg 重采样到 512×512（quality 95）后走完整
// removeBackground 管线，2 次预热 + 20 次计时，报 median/p95/min。
// 附 ORT 版本字符串与实际 EP，排除"以为换了运行时其实没换"的事故。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

// path_provider 是 onnxruntime 插件的传递依赖（win_cmp 同款用法）。
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

class _Engine with MattingEngineMixin {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  void log(String line) {
    // ignore: avoid_print
    print('SPEED $line');
  }

  // 排障开关：/data/local/tmp/speed_in/force_ep 里写 cpu / xnnpack / nnapi
  // 则强制单 EP（运行期读取，改 EP 不用重编 APK）；文件不存在走默认降级链。
  // 另一文件 flags 支持逐行键值：arena=same_as_requested / no_cpu_arena=1 /
  // no_mem_pattern=1（内存政策 A/B，跑内存 cliff 用）。
  const kInDir = String.fromEnvironment('SPEED_IN',
      defaultValue: '/data/local/tmp/speed_in');
  final epFile = File('$kInDir${Platform.pathSeparator}force_ep');
  if (epFile.existsSync()) {
    final ep = epFile.readAsStringSync().trim();
    if (ep.isNotEmpty) {
      ort.debugForceEp = ep;
      log('forceEp=$ep');
    }
  }
  final flagsFile = File('$kInDir${Platform.pathSeparator}flags');
  if (flagsFile.existsSync()) {
    for (final line in flagsFile.readAsLinesSync()) {
      final t = line.trim();
      if (t == 'arena=same_as_requested') {
        final ok = ort.applySameAsRequestedArena();
        log('flag arena=same_as_requested ready=$ok err=${ort.arenaPolicyError}');
      } else if (t == 'no_cpu_arena=1') {
        ort.debugDisableCpuMemArena = true;
        log('flag no_cpu_arena=1');
      } else if (t == 'no_mem_pattern=1') {
        ort.debugDisableMemPattern = true;
        log('flag no_mem_pattern=1');
      } else if (t == 'disable_prepacking=1') {
        ort.debugDisablePrepacking = true;
        log('flag disable_prepacking=1');
      }
    }
  }
  final src = File('$kInDir${Platform.pathSeparator}g01.jpg');
  if (!src.existsSync()) {
    log('FATAL missing input: ${src.path}');
    exit(2);
  }
  final decoded = img.decodeJpg(src.readAsBytesSync())!;
  final square = img.copyResize(decoded, width: 512, height: 512);
  final bytes = Uint8List.fromList(img.encodeJpg(square, quality: 95));

  final engine = _Engine();
  final sw = Stopwatch()..start();
  await engine.warmUp();
  log('warmUpMs=${sw.elapsedMilliseconds} '
      'provider=${engine.mattingProvider} ort=${ort.ortVersionString()}');

  // quick 文件存在时只跑 2+6（内存 cliff 试探），否则 2+20。
  final quick = File('$kInDir${Platform.pathSeparator}quick').existsSync();
  final total = quick ? 8 : 22;
  final samples = <int>[];
  for (var i = 0; i < total; i++) {
    sw.reset();
    sw.start();
    try {
      await engine.removeBackground(bytes);
    } on Exception catch (e) {
      // IdPhotoException.toString 不带 cause，排障必须单独打出来。
      final cause = e is IdPhotoException ? e.cause : null;
      log('RUN$i FAILED: $e cause=$cause');
      exit(3);
    }
    sw.stop();
    if (i >= 2) samples.add(sw.elapsedMilliseconds);
  }
  samples.sort();
  final p95 = samples[(samples.length * 0.95).ceil() - 1];
  log('latency n=${samples.length} median=${samples[samples.length ~/ 2]}ms '
      'p95=${p95}ms min=${samples.first}ms max=${samples.last}ms');

  // 落盘一份结果，logcat 被冲掉也能拉回。
  final support = await getApplicationSupportDirectory();
  File('${support.path}${Platform.pathSeparator}speed_result.txt')
      .writeAsStringSync('provider=${engine.mattingProvider} '
          'ort=${ort.ortVersionString()} '
          'median=${samples[samples.length ~/ 2]} p95=$p95 '
          'min=${samples.first}\n');
  await engine.disposeMattingEngine();
  log('done');
  exit(0);
}
