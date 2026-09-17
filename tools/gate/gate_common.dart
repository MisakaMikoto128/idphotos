// tools/gate/gate_common.dart
//
// gate 脚本共用的小工具：跑子进程、等待模拟器上线、读取 applicationId、写 JSON 报告。
// 属于 gatekeeper 势力范围，任何其他 agent 不应修改。
//
// 设计原则：任何外部命令找不到 / 超时 / 非零退出，一律如实记录，
// 绝不 catch 后当成"跳过=通过"。调用方负责把 ok=false 映射为 gate 项 FAIL。

import 'dart:convert';
import 'dart:io';

/// 统一的子进程执行结果。
class RunResult {
  final bool ok; // 进程能否被启动（找不到可执行文件时为 false）
  final int exitCode; // 找不到可执行文件时为 -1
  final String stdout;
  final String stderr;
  final bool timedOut;

  RunResult({
    required this.ok,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  bool get success => ok && !timedOut && exitCode == 0;

  /// 截断后的诊断文本，写进 gate JSON 的 actual 字段，避免日志过长。
  String tail({int maxChars = 800}) {
    final combined = 'stdout:\n$stdout\nstderr:\n$stderr';
    if (combined.length <= maxChars) return combined;
    return '...(截断)...\n${combined.substring(combined.length - maxChars)}';
  }
}

/// 跑一个子进程，带超时。找不到命令 / 超时都不抛异常，全部体现在 RunResult 里，
/// 由调用方决定如何映射到 gate 判定。
Future<RunResult> runProcess(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 5),
}) async {
  Process? proc;
  try {
    proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: true,
    );
  } catch (e) {
    return RunResult(ok: false, exitCode: -1, stdout: '', stderr: '启动失败: $e');
  }

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final stdoutSub = proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
  final stderrSub = proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);

  var timedOut = false;
  // 收尾阶段的失败必须**可观测**。这里原来是一个空 catch（带一句"忽略"的注释），
  // 于是 kill 抛异常时既没有痕迹、也不影响任何返回值 —— 正是条款 5 要禁的形态。
  // 现在把原因挂进 stderr，读 RunResult 的人拿得到。
  String killNote = '';
  int exitCode;
  try {
    exitCode = await proc.exitCode.timeout(timeout, onTimeout: () {
      timedOut = true;
      try {
        proc!.kill(ProcessSignal.sigkill);
      } catch (e) {
        killNote = '（kill 失败：${e.runtimeType}: $e —— 进程可能已自行退出；'
            'timedOut 标记不受影响）';
      }
      return -1;
    });
  } finally {
    // 正常退出时流很快关闭；超时被 kill 的情况下也不能让这里无限等待，
    // 所以加一个短超时兜底，避免 gate 脚本被卡死进程拖死。
    await stdoutSub
        .asFuture<void>()
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .catchError((_) {});
    await stderrSub
        .asFuture<void>()
        .timeout(const Duration(seconds: 5), onTimeout: () {})
        .catchError((_) {});
    await stdoutSub.cancel();
    await stderrSub.cancel();
  }

  return RunResult(
    ok: true,
    exitCode: exitCode,
    stdout: stdoutBuf.toString(),
    stderr: stderrBuf.toString() + killNote,
    timedOut: timedOut,
  );
}

/// 等待至少一台 adb 设备进入 `device`（在线可用）状态。
/// 不负责启动模拟器，只负责轮询；启动逻辑由调用方决定（可能已经在跑，或需要 flutter emulators --launch）。
Future<String?> waitForAdbDeviceOnline({
  Duration timeout = const Duration(minutes: 3),
  Duration pollInterval = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final r = await runProcess('adb', ['devices'], timeout: const Duration(seconds: 15));
    if (r.ok) {
      for (final line in r.stdout.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('List of devices')) continue;
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts[1] == 'device') {
          return parts[0];
        }
      }
    }
    await Future.delayed(pollInterval);
  }
  return null;
}

/// 从 android/app/build.gradle(.kts) 里解析 applicationId，用于 adb 操作目标包。
/// 找不到时返回 null（调用方必须显式 FAIL，不许猜一个默认值当真值）。
Future<String?> findApplicationId({String projectRoot = '.'}) async {
  final candidates = [
    File('$projectRoot/android/app/build.gradle'),
    File('$projectRoot/android/app/build.gradle.kts'),
  ];
  final pattern = RegExp(r'''applicationId\s*[=]?\s*["']([a-zA-Z0-9_.]+)["']''');
  for (final f in candidates) {
    if (await f.exists()) {
      final content = await f.readAsString();
      final m = pattern.firstMatch(content);
      if (m != null) return m.group(1);
    }
  }
  return null;
}

/// 写出符合 gate JSON 约定的报告文件。
Future<void> writeGateReport({
  required String outPath,
  required String gateId,
  required List<Map<String, dynamic>> items,
}) async {
  // 安全校验：MANUAL 项绝不允许被标为 pass=true（不许"默认当作通过"）。
  for (final i in items) {
    if (i['manual'] == true && i['pass'] == true) {
      throw StateError(
          'gate 脚本内部错误：${i['id']} 被标记为 manual 却又 pass=true，禁止这种"默认通过"');
    }
  }

  final passed = items.where((i) => i['pass'] == true).length;
  final manual = items.where((i) => i['manual'] == true).length;
  // pass 的定义：所有条目必须 pass=true 才算 gate 通过。
  // MANUAL 项本身 pass 恒为 false（上面已校验），所以只要存在 MANUAL 项，
  // 整个 gate 就不能自动 PASS —— 与 ACCEPTANCE.md「不许默认当作通过」一致。
  final allPass = items.every((i) => i['pass'] == true);
  final report = {
    'gate': gateId,
    'generatedAt': DateTime.now().toIso8601String(),
    'items': items,
    'summary': {
      'total': items.length,
      'passed': passed,
      'manual': manual,
    },
    'pass': allPass,
  };
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
}
