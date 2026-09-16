// ml-porting 自用：Windows 移植的跨平台数值一致性探针核心。
//
// 同一份代码跑在两处，产出可逐字节比对的原始产物：
//   - Windows 宿主：native/bench/win_port_probe_test.dart（flutter test）
//   - Android 模拟器：native/bench/win_cmp_android_main.dart
//     （flutter build apk --release --target=... 后经 adb 拉回）
//
// 比对口径（两边完全一致才有意义）：
//   * debugForceEp = 'cpu'——Android 默认首选 XNNPACK，Windows 的官方
//     桌面包不含 XNNPACK EP，会把 EP 差异混进数值；两边都钉死纯 CPU EP。
//   * 黄金集 8 张长边 ≤2048 = kEngineMaxEdge，走 image 包解码路径（不进
//     dart:ui 降采样），解码逐位确定，消除平台解码器差异。
//   * 产物：每张黄金图的 alpha sha256 + g01 的原始 alpha 字节 + g01 的
//     FaceInfo 数值 + 512×512 单张耗时。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// crypto 是 onnxruntime/flutter_test 链上的传递依赖，bench 自用。
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

class _Engine with MattingEngineMixin {}

/// [inDir] 是黄金集 src 目录：Windows 宿主默认仓库 test/golden/src；
/// Android 由 host 侧 adb push 后经 --dart-define=WIN_CMP_IN 传入。
/// [outDir] 非 null 时把 g01 原始 alpha 落盘，供跨平台逐字节比对。
///
/// 模型目录：仓库里 `assets/models` 存在（宿主形态）时直接读盘；不存在
/// （Android APK 形态）保持 debugModelDirectory = null，走 rootBundle 落地。
Future<void> runWinCompare({
  required void Function(String line) log,
  String? outDir,
  String? inDir,
  bool includeRobustness = false,
}) async {
  const kWinCmpIn = String.fromEnvironment('WIN_CMP_IN');
  ort.debugForceEp = 'cpu';
  final repo = Directory.current.path;
  final repoModels = Directory('$repo${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}models');
  if (repoModels.existsSync()) {
    ort.debugModelDirectory = repoModels.path;
  }
  final srcDir = Directory(inDir ??
      (kWinCmpIn.isNotEmpty
          ? kWinCmpIn
          : '$repo${Platform.pathSeparator}test'
              '${Platform.pathSeparator}golden${Platform.pathSeparator}src'));
  final files = srcDir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  log('CMP inputs dir=${srcDir.path} n=${files.length}');

  final engine = _Engine();
  var t0 = Stopwatch()..start();
  await engine.warmUp();
  log('CMP warmUpMs=${t0.elapsedMilliseconds} '
      'provider=${engine.mattingProvider} '
      'envAddr=${engine.debugEnvAddress}');

  for (final f in files) {
    final name = f.path.split(Platform.pathSeparator).last.split('.').first;
    final bytes = await f.readAsBytes();

    t0 = Stopwatch()..start();
    final r = await engine.removeBackground(bytes);
    final mattingMs = t0.elapsedMilliseconds;
    final digest = sha256.convert(r.alpha).toString();
    log('CMP alpha $name wh=${r.width}x${r.height} '
        'alphaSha256=$digest mattingMs=$mattingMs');

    if (name == 'g01' && outDir != null) {
      File('$outDir${Platform.pathSeparator}alpha_g01.bin')
          .writeAsBytesSync(r.alpha);
    }

    t0 = Stopwatch()..start();
    final face = await engine.detectFace(bytes);
    final faceMs = t0.elapsedMilliseconds;
    if (face == null) {
      log('CMP face $name null faceMs=$faceMs');
    } else {
      log('CMP face $name '
          'box=${face.box.left.toStringAsFixed(2)},'
          '${face.box.top.toStringAsFixed(2)},'
          '${face.box.width.toStringAsFixed(2)},'
          '${face.box.height.toStringAsFixed(2)} '
          'headTopY=${face.headTopY.toStringAsFixed(2)} '
          'chinY=${face.chinY.toStringAsFixed(2)} '
          'rollDeg=${face.rollDeg.toStringAsFixed(4)} '
          'conf=${face.confidence.toStringAsFixed(6)} faceMs=$faceMs');
    }
  }

  // KPI 口径：512×512 输入的单张耗时（与 G2A.6 / Android 712ms 同口径）。
  final src = img.decodeJpg(
      File('${srcDir.path}${Platform.pathSeparator}g01.jpg')
          .readAsBytesSync())!;
  final square = img.copyResize(src, width: 512, height: 512);
  final bytes512 = Uint8List.fromList(img.encodeJpg(square, quality: 95));
  final samples = <int>[];
  for (var i = 0; i < 12; i++) {
    t0 = Stopwatch()..start();
    await engine.removeBackground(bytes512);
    if (i >= 2) samples.add(t0.elapsedMilliseconds);
  }
  samples.sort();
  log('CMP latency512 n=${samples.length} '
      'median=${samples[samples.length ~/ 2]}ms '
      'max=${samples.last}ms '
      'p95=${samples[(samples.length * 0.95).ceil() - 1]}ms');

  // 非人像优雅失败（仅 Windows 宿主：dataset.json 是本机绝对路径清单）。
  if (includeRobustness) {
    final ds = jsonDecode(await File('$repo${Platform.pathSeparator}test'
                '${Platform.pathSeparator}dataset.json')
            .readAsString()) as Map<String, dynamic>;
    final items = (ds['items'] as List<dynamic>).cast<Map<String, dynamic>>();
    var checked = 0;
    var rejected = 0;
    final violations = <String>[];
    for (final item in items) {
      final cls = item['class'] as String;
      if (cls != 'screenshot' && cls != 'landscape' && cls != 'non_image') {
        continue;
      }
      if (checked >= 8) break;
      final f = File(item['path'] as String);
      if (!f.existsSync()) continue;
      checked++;
      try {
        await engine.removeBackground(f.readAsBytesSync());
        violations.add('accepted non-portrait: ${item['path']}');
      } on IdPhotoException {
        rejected++;
      }
    }
    log('CMP robustness checked=$checked rejected=$rejected '
        'violations=${violations.length} ${violations.take(3).join(' | ')}');
  }

  await engine.disposeMattingEngine();
  log('CMP done');
}
