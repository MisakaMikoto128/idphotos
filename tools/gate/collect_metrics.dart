// tools/gate/collect_metrics.dart
//
// 内存/耗时采集流水线（G1.7 生命线）。阶段 1 App 还没有真实功能，
// "单步耗时"先用冷启动到首帧耗时代替，把 adb 采集机制打通；
// 阶段 4 由 qa-batch 在此机制之上采集真实抠图耗时（那是 qa-batch 的 out/metrics_*，
// 本文件只产出 out/gate_metrics.json，刻意改名避免和 qa-batch 的产物撞车）。
//
// 可独立运行：
//   dart run tools/gate/collect_metrics.dart
// 也可被 gate_G1.dart 以库的形式直接调用 runCollectMetrics()。
//
// 势力范围：gatekeeper。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';

const String kMetricsOutPath = 'out/gate_metrics.json';

class MetricsResult {
  final bool success;
  final int? coldStartMs;
  final int? peakMemoryKb;
  final String? packageId;
  final String? error;
  final String log;

  MetricsResult({
    required this.success,
    required this.log,
    this.coldStartMs,
    this.peakMemoryKb,
    this.packageId,
    this.error,
  });
}

Future<MetricsResult> runCollectMetrics({String projectRoot = '.'}) async {
  final log = StringBuffer();

  final packageId = await findApplicationId(projectRoot: projectRoot);
  if (packageId == null) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      error: '无法从 android/app/build.gradle(.kts) 解析 applicationId'
          '（项目可能还未 flutter create，等待 env-setup/主会话完成脚手架）',
    );
  }
  log.writeln('applicationId=$packageId');

  // **只认 emulator-***：本函数随后要 `adb install` 并 `am start` ——
  // 真机在线时，那是在**用户的手机上装东西**（见 docs/PITFALLS.md「真机再次被抓进编排」）。
  final String deviceId;
  try {
    deviceId = await requireEmulatorDevice(wait: const Duration(minutes: 3));
  } on StateError catch (e) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      packageId: packageId,
      error: '没有可用模拟器（只认 emulator-*，真机一律不碰）：${e.message}',
    );
  }
  log.writeln('设备已上线: $deviceId');

  // 安装 APK：`flutter build apk --debug` 只产出 apk 文件，不会自动装到当前在线的模拟器上。
  // 第一轮曾在这里漏掉安装步骤，导致 `am start -W` 报 "Activity class ... does not exist"
  // （已记入 docs/PITFALLS.md）。这里显式装一次，装不上就直接 FAIL，不猜测原因。
  final apkFile = File('$projectRoot/build/app/outputs/flutter-apk/app-debug.apk');
  if (!await apkFile.exists()) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      packageId: packageId,
      error: '找不到 ${apkFile.path}，需要先跑一次 `flutter build apk --debug`（G1.1）产出 apk',
    );
  }
  final install = await runProcess(
    'adb',
    ['-s', deviceId, 'install', '-r', apkFile.path],
    timeout: const Duration(minutes: 3),
  );
  log.writeln('adb install -r 退出码=${install.exitCode}');
  log.writeln(install.tail());
  if (!install.success) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      packageId: packageId,
      error: 'adb install 失败，无法继续测冷启动: ${install.tail(maxChars: 300)}',
    );
  }

  // 冷启动：先强杀，再用 am start -W 测 TotalTime。
  await runProcess('adb', ['-s', deviceId, 'shell', 'am', 'force-stop', packageId],
      timeout: const Duration(seconds: 15));

  final startResult = await runProcess(
    'adb',
    ['-s', deviceId, 'shell', 'am', 'start', '-W', '-n', '$packageId/.MainActivity'],
    timeout: const Duration(seconds: 30),
  );
  log.writeln('am start -W 退出码=${startResult.exitCode}');
  log.writeln(startResult.tail());

  int? coldStartMs;
  if (startResult.ok) {
    final m = RegExp(r'TotalTime:\s*(\d+)').firstMatch(startResult.stdout);
    if (m != null) {
      coldStartMs = int.tryParse(m.group(1)!);
    }
  }

  if (coldStartMs == null) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      packageId: packageId,
      error: '未能从 `am start -W` 输出解析到 TotalTime'
          '（可能 MainActivity 名称不是默认值，或 App 尚不存在/未安装）',
    );
  }

  // 峰值内存：启动后短时间内多次采样 dumpsys meminfo 的 TOTAL（KB），取最大值。
  int? peakMemoryKb;
  for (var i = 0; i < 5; i++) {
    final mem = await runProcess(
      'adb',
      ['-s', deviceId, 'shell', 'dumpsys', 'meminfo', packageId],
      timeout: const Duration(seconds: 15),
    );
    if (mem.ok) {
      final m = RegExp(r'TOTAL[A-Z\s]*:?\s+(\d+)').firstMatch(mem.stdout);
      if (m != null) {
        final v = int.tryParse(m.group(1)!);
        if (v != null && (peakMemoryKb == null || v > peakMemoryKb)) {
          peakMemoryKb = v;
        }
      }
    }
    await Future.delayed(const Duration(milliseconds: 800));
  }

  if (peakMemoryKb == null) {
    return MetricsResult(
      success: false,
      log: log.toString(),
      packageId: packageId,
      coldStartMs: coldStartMs,
      error: '未能从 `dumpsys meminfo` 解析到 TOTAL 内存值',
    );
  }

  log.writeln('coldStartMs=$coldStartMs peakMemoryKb=$peakMemoryKb');

  final report = {
    'generatedAt': DateTime.now().toIso8601String(),
    'packageId': packageId,
    'coldStartMs': coldStartMs,
    'peakMemoryKb': peakMemoryKb,
    'note': '阶段1：coldStartMs 代表冷启动到首帧耗时（占位单步耗时），'
        '非阶段4要求的抠图 p95 耗时；后者由 qa-batch 在真实功能就绪后另行采集。',
  };
  final outFile = File(kMetricsOutPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));

  return MetricsResult(
    success: true,
    log: log.toString(),
    coldStartMs: coldStartMs,
    peakMemoryKb: peakMemoryKb,
    packageId: packageId,
  );
}

Future<void> main(List<String> args) async {
  final result = await runCollectMetrics();
  stdout.writeln(result.log);
  if (!result.success) {
    stderr.writeln('采集失败: ${result.error}');
  }
  exit(result.success ? 0 : 1);
}
