// tools/gate/capture_shots.dart
//
// 截图流水线驱动脚本（G1.6 生命线）。封装：
//   启动/确认 AVD 在线 → flutter drive (integration_test) → 校验产出
//   → 若 flutter drive 失败，降级用 adb exec-out screencap 兜底（并标记 degraded）。
//
// 可独立运行：
//   dart run tools/gate/capture_shots.dart [--avd <id>] [--device <serial>]
// 也可被 gate_G1.dart 以库的形式直接调用 runCaptureShots()。
//
// 势力范围：gatekeeper。任何实现类 agent 不应修改本文件。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';
import 'png_utils.dart';

const String kDefaultAvd = 'Pixel_3a_API_34_extension_level_7_x86_64';
const String kShotsDir = 'out/shots';

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

/// 清空 out/shots/（capture-shots skill 规定：每轮先清空，避免上一轮残留冒充本轮结果）。
Future<void> _clearShotsDir() async {
  final dir = Directory(kShotsDir);
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);
}

Future<CaptureResult> runCaptureShots({
  String avdId = kDefaultAvd,
  Duration bootTimeout = const Duration(minutes: 3),
  Duration driveTimeout = const Duration(minutes: 6),
}) async {
  final log = StringBuffer();
  await _clearShotsDir();

  // 1. 确认设备在线，不在线则尝试启动指定 AVD。
  String? deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 5));
  if (deviceId == null) {
    log.writeln('没有在线设备，尝试启动模拟器 $avdId ...');
    final launch = await runProcess(
      'flutter',
      ['emulators', '--launch', avdId],
      timeout: const Duration(seconds: 30),
    );
    log.writeln('flutter emulators --launch 退出码=${launch.exitCode}');
    if (!launch.ok) {
      return CaptureResult(
        success: false,
        degraded: false,
        shotFiles: const [],
        log: log.toString(),
        error: 'flutter 命令不可用或启动模拟器失败: ${launch.stderr}',
      );
    }
    deviceId = await waitForAdbDeviceOnline(timeout: bootTimeout);
  }

  if (deviceId == null) {
    log.writeln('等待设备上线超时（${bootTimeout.inSeconds}s）');
    return _fallback(log, error: '模拟器未能在超时内上线，触发 adb 截图兜底');
  }
  log.writeln('设备已上线: $deviceId');

  // 2. 跑 integration_test 截图流水线。
  final driveArgs = [
    'drive',
    '--driver=test_driver/integration_test_driver.dart',
    '--target=integration_test/shots_test.dart',
    '-d',
    deviceId,
  ];
  final drive = await runProcess('flutter', driveArgs, timeout: driveTimeout);
  log.writeln('flutter drive 退出码=${drive.exitCode} timedOut=${drive.timedOut}');
  log.writeln(drive.tail());

  if (!drive.success) {
    return _fallback(log, error: 'flutter drive 失败/超时，触发 adb 截图兜底');
  }

  // 3. 校验产出：out/shots 下至少 1 张非纯黑 PNG。
  final validated = await _validateShots();
  if (validated.isEmpty) {
    return _fallback(log, error: 'flutter drive 声称成功但 out/shots 下没有有效截图，触发兜底');
  }

  log.writeln('校验通过的截图: ${validated.join(', ')}');
  return CaptureResult(
    success: true,
    degraded: false,
    shotFiles: validated,
    log: log.toString(),
  );
}

/// 兜底：adb exec-out screencap -p。必须标记 degraded=true。
Future<CaptureResult> _fallback(StringBuffer log, {required String error}) async {
  log.writeln('--- 兜底流程 ---');
  final deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 10));
  if (deviceId == null) {
    return CaptureResult(
      success: false,
      degraded: true,
      shotFiles: const [],
      log: log.toString(),
      error: '$error；且兜底时设备也不在线',
    );
  }

  final dir = Directory(kShotsDir);
  await dir.create(recursive: true);
  final outFile = File('$kShotsDir/S1_fallback_adb.png');

  // adb exec-out 必须用二进制方式接收，Process.run 的 stdout 需按 raw bytes 处理。
  try {
    final proc = await Process.start('adb', ['-s', deviceId, 'exec-out', 'screencap', '-p']);
    final bytes = <int>[];
    await for (final chunk in proc.stdout) {
      bytes.addAll(chunk);
    }
    final exitCode = await proc.exitCode;
    if (exitCode != 0 || bytes.isEmpty) {
      return CaptureResult(
        success: false,
        degraded: true,
        shotFiles: const [],
        log: log.toString(),
        error: '$error；adb screencap 退出码=$exitCode 或空数据',
      );
    }
    await outFile.writeAsBytes(bytes, flush: true);
  } catch (e) {
    return CaptureResult(
      success: false,
      degraded: true,
      shotFiles: const [],
      log: log.toString(),
      error: '$error；adb screencap 异常: $e',
    );
  }

  final validated = await _validateShots();
  if (validated.isEmpty) {
    return CaptureResult(
      success: false,
      degraded: true,
      shotFiles: const [],
      log: log.toString(),
      error: '$error；adb screencap 落盘后仍未通过校验（可能纯黑或解码失败）',
    );
  }

  log.writeln('兜底截图校验通过: ${validated.join(', ')}（degraded=true）');
  return CaptureResult(
    success: true,
    degraded: true,
    shotFiles: validated,
    log: log.toString(),
  );
}

/// 校验 out/shots/ 下的 PNG：存在、非 0 字节、中心采样非纯黑。
/// 返回通过校验的文件名列表（相对 out/shots/）。
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
      // 解码失败的文件不计入有效截图，但不抛出中断整个校验流程。
      stderr.writeln('警告: ${entity.path} PNG 解码失败: $e');
    }
  }
  return result;
}

Future<void> main(List<String> args) async {
  String avd = kDefaultAvd;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--avd' && i + 1 < args.length) avd = args[i + 1];
  }

  final result = await runCaptureShots(avdId: avd);
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
