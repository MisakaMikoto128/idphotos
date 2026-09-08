// tools/gate/capture_shots.dart
//
// 截图流水线驱动脚本。封装：
//   启动/确认 AVD 在线 → flutter drive (integration_test) → 校验产出
//   → 若 flutter drive 失败，降级用 adb exec-out screencap 兜底（并标记 degraded）。
//
// 阶段 2 起扩成两次 `flutter drive`：
//   - 主 AVD（Pixel_3a_API_34...）跑 SHOT_MODE=main，产出 S1-S6。
//   - 小屏 AVD（MuZhao_Small）跑 SHOT_MODE=small，产出 S2_small/S5_small。
// `runCaptureShots()` 保留给 G1.6（只需要"流水线能不能跑通"，跑主 AVD 一次即可）；
// `runFullShotsPipeline()` 是 G2C.1 用的，两台都跑，凑齐 8 张。
//
// flutter_driver 的 `integrationDriver()` 会把 `binding.reportData` 自动写到
// `build/integration_response_data.json`（Flutter SDK 自带机制，不是我们自己发明的）。
// 里面是 shots_test.dart 记录的稳定 Key 矩形，`runFullShotsPipeline()` 把两次跑的结果
// 合并写到 `out/shots/_rects.json`，供 gate_G2C.dart 的调色板/纯黑白检测排除照片区域用。
//
// 可独立运行：
//   dart run tools/gate/capture_shots.dart [--full]
// 也可被 gate_G1.dart / gate_G2C.dart 以库的形式直接调用。
//
// 势力范围：gatekeeper。任何实现类 agent 不应修改本文件。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';
import 'png_utils.dart';

const String kMainAvd = 'Pixel_3a_API_34_extension_level_7_x86_64';
const String kSmallAvd = 'MuZhao_Small';
const String kShotsDir = 'out/shots';
const String kResponseDataPath = 'build/integration_response_data.json';

class CaptureResult {
  final bool success;
  final bool degraded;
  final List<String> shotFiles; // 相对路径
  final String? error;
  final String log;

  CaptureResult({
    required this.success,
    required this.degraded,
    required this.shotFiles,
    required this.log,
    this.error,
  });
}

Future<void> _clearShotsDir() async {
  final dir = Directory(kShotsDir);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);
}

Future<String?> _ensureDeviceOnline(String avdId, Duration bootTimeout, StringBuffer log) async {
  var deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 5));
  if (deviceId != null) return deviceId;
  log.writeln('没有在线设备，尝试启动模拟器 $avdId ...');
  final launch = await runProcess('flutter', ['emulators', '--launch', avdId],
      timeout: const Duration(seconds: 30));
  log.writeln('flutter emulators --launch 退出码=${launch.exitCode}');
  if (!launch.ok) return null;
  deviceId = await waitForAdbDeviceOnline(timeout: bootTimeout);
  return deviceId;
}

/// G1.6 用：只需要证明流水线能跑通、能落盘至少 1 张非纯黑 PNG。跑主 AVD 一次。
Future<CaptureResult> runCaptureShots({
  String avdId = kMainAvd,
  Duration bootTimeout = const Duration(minutes: 3),
  Duration driveTimeout = const Duration(minutes: 6),
}) async {
  final log = StringBuffer();
  await _clearShotsDir();

  final deviceId = await _ensureDeviceOnline(avdId, bootTimeout, log);
  if (deviceId == null) {
    return _fallback(log, error: '模拟器未能在超时内上线，触发 adb 截图兜底');
  }
  log.writeln('设备已上线: $deviceId');

  final args = [
    'drive',
    '--driver=test_driver/integration_test_driver.dart',
    '--target=integration_test/shots_test.dart',
    '-d',
    deviceId,
  ];
  final drive = await runProcess('flutter', args, timeout: driveTimeout);
  log.writeln('flutter drive 退出码=${drive.exitCode} timedOut=${drive.timedOut}');
  log.writeln(drive.tail());
  if (!drive.success) {
    return _fallback(log, error: 'flutter drive 失败/超时，触发 adb 截图兜底');
  }

  final validated = await _validateShots();
  if (validated.isEmpty) {
    return _fallback(log, error: 'flutter drive 声称成功但 out/shots 下没有有效截图，触发兜底');
  }

  log.writeln('校验通过的截图: ${validated.join(', ')}');
  return CaptureResult(success: true, degraded: false, shotFiles: validated, log: log.toString());
}

/// G2C.1 用：主 AVD 跑 S1-S6，小屏 AVD 跑 S2_small/S5_small，凑齐 8 张。
/// 两次 flutter drive 之间不清空 out/shots（第二次是追加）。
/// 合并两次的 `binding.reportData` 矩形到 out/shots/_rects.json。
Future<CaptureResult> runFullShotsPipeline({
  String mainAvd = kMainAvd,
  String smallAvd = kSmallAvd,
  Duration bootTimeout = const Duration(minutes: 3),
  Duration driveTimeout = const Duration(minutes: 8),
}) async {
  final log = StringBuffer();
  await _clearShotsDir();
  final mergedRects = <String, dynamic>{};

  // 主 AVD：S1-S6
  final mainDevice = await _ensureDeviceOnline(mainAvd, bootTimeout, log);
  if (mainDevice == null) {
    return _fallback(log, error: '主 AVD ($mainAvd) 未能上线，触发 adb 截图兜底（只能兜底出 1 张，凑不齐 8 张）');
  }
  final mainDrive = await runProcess(
    'flutter',
    [
      'drive',
      '--driver=test_driver/integration_test_driver.dart',
      '--target=integration_test/shots_test.dart',
      '-d',
      mainDevice,
    ],
    timeout: driveTimeout,
  );
  log.writeln('[主AVD] flutter drive 退出码=${mainDrive.exitCode} timedOut=${mainDrive.timedOut}');
  log.writeln(mainDrive.tail());
  if (!mainDrive.success) {
    return _fallback(log, error: '主 AVD flutter drive 失败/超时，触发 adb 截图兜底');
  }
  await _mergeResponseRects(mergedRects, log);

  // 小屏 AVD：S2_small/S5_small
  final smallDevice = await _ensureDeviceOnline(smallAvd, bootTimeout, log);
  if (smallDevice == null) {
    log.writeln('警告: 小屏 AVD ($smallAvd) 未能上线，S2_small/S5_small 缺失（不触发兜底，因为主 6 张已经拿到）');
  } else {
    final smallDrive = await runProcess(
      'flutter',
      [
        'drive',
        '--driver=test_driver/integration_test_driver.dart',
        '--target=integration_test/shots_test.dart',
        '-d',
        smallDevice,
        '--dart-define=SHOT_MODE=small',
      ],
      timeout: driveTimeout,
    );
    log.writeln('[小屏AVD] flutter drive 退出码=${smallDrive.exitCode} timedOut=${smallDrive.timedOut}');
    log.writeln(smallDrive.tail());
    if (smallDrive.success) {
      await _mergeResponseRects(mergedRects, log);
    } else {
      log.writeln('警告: 小屏 AVD flutter drive 失败，S2_small/S5_small 缺失');
    }
  }

  final rectsFile = File('$kShotsDir/_rects.json');
  await rectsFile.writeAsString(jsonEncode(mergedRects));

  final validated = await _validateShots();
  log.writeln('最终校验通过的截图 (${validated.length}张): ${validated.join(', ')}');
  return CaptureResult(
    success: validated.isNotEmpty,
    degraded: false,
    shotFiles: validated,
    log: log.toString(),
    error: validated.length < 8 ? '只拿到 ${validated.length}/8 张，见 log' : null,
  );
}

Future<void> _mergeResponseRects(Map<String, dynamic> merged, StringBuffer log) async {
  final f = File(kResponseDataPath);
  if (!await f.exists()) {
    log.writeln('警告: $kResponseDataPath 不存在，rects 数据缺失（不影响截图本身，只影响 2C.2/2C.4 的照片区域排除）');
    return;
  }
  try {
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final rects = data['rects'] as Map<String, dynamic>?;
    if (rects != null) merged.addAll(rects);
  } catch (e) {
    log.writeln('警告: 解析 $kResponseDataPath 失败: $e');
  }
}

Future<CaptureResult> _fallback(StringBuffer log, {required String error}) async {
  log.writeln('--- 兜底流程 ---');
  final deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 10));
  if (deviceId == null) {
    return CaptureResult(
        success: false, degraded: true, shotFiles: const [], log: log.toString(),
        error: '$error；且兜底时设备也不在线');
  }

  final dir = Directory(kShotsDir);
  await dir.create(recursive: true);
  final outFile = File('$kShotsDir/S1_fallback_adb.png');

  try {
    final proc = await Process.start('adb', ['-s', deviceId, 'exec-out', 'screencap', '-p']);
    final bytes = <int>[];
    await for (final chunk in proc.stdout) {
      bytes.addAll(chunk);
    }
    final exitCode = await proc.exitCode;
    if (exitCode != 0 || bytes.isEmpty) {
      return CaptureResult(
          success: false, degraded: true, shotFiles: const [], log: log.toString(),
          error: '$error；adb screencap 退出码=$exitCode 或空数据');
    }
    await outFile.writeAsBytes(bytes, flush: true);
  } catch (e) {
    return CaptureResult(
        success: false, degraded: true, shotFiles: const [], log: log.toString(),
        error: '$error；adb screencap 异常: $e');
  }

  final validated = await _validateShots();
  if (validated.isEmpty) {
    return CaptureResult(
        success: false, degraded: true, shotFiles: const [], log: log.toString(),
        error: '$error；adb screencap 落盘后仍未通过校验（可能纯黑或解码失败）');
  }

  log.writeln('兜底截图校验通过: ${validated.join(', ')}（degraded=true）');
  return CaptureResult(success: true, degraded: true, shotFiles: validated, log: log.toString());
}

Future<List<String>> _validateShots() async {
  final dir = Directory(kShotsDir);
  if (!await dir.exists()) return [];
  final result = <String>[];
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.png')) continue;
    final bytes = await entity.readAsBytes();
    if (bytes.isEmpty) continue;
    try {
      final png = decodePng(bytes);
      if (!isCenterAllBlack(png)) {
        result.add(entity.uri.pathSegments.last);
      }
    } catch (e) {
      stderr.writeln('警告: ${entity.path} PNG 解码失败: $e');
    }
  }
  return result;
}

Future<void> main(List<String> args) async {
  final full = args.contains('--full');
  final result = full ? await runFullShotsPipeline() : await runCaptureShots();
  stdout.writeln(result.log);
  final summary = {
    'success': result.success,
    'degraded': result.degraded,
    'shotFiles': result.shotFiles,
    'error': result.error,
  };
  stdout.writeln('CAPTURE_RESULT_JSON:${jsonEncode(summary)}');
  exit(result.success ? 0 : 1);
}
