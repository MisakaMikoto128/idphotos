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

/// shell 语法字符。`runInShell: true` 时 Dart **不做任何转义**：
/// 整个命令被拼成一行交给 `cmd.exe /c`，这些字符全部会被 cmd 当成**语法**解释掉。
///
/// 后果不是"报错"，而是"**换个方式执行并给出看起来正常的结果**"——
/// 本项目的原话是「仪表失败时报告更少，而不是看不到」，这里是它的最坏形态：
/// 仪表**报告了一个错误的值**。
///
/// 实证（2026-09-17，就在本仓库）：
/// `git log --name-only --format=@@%h|%s baseline-p6p0..HEAD`
///   → cmd 把 `|` 当管道 → `'%s' is not recognized...` →
///     **exit 255、stdout 空**。而调用方没查 exitCode，于是
///     「条款 1（实现类 agent 越界写考卷）」拿到空列表 → 判**清白**。
///     这条最重要的防作弊条款自写下起就没工作过，每一轮都在报"清白"。
const List<String> kShellSyntaxChars = <String>['|', '&', '>', '<', '^', '%'];

/// 参数里是否含会被 `cmd.exe` 解释掉的字符。
String? shellSyntaxIn(String arg) {
  for (final String c in kShellSyntaxChars) {
    if (arg.contains(c)) return c;
  }
  return null;
}

/// 跑一个子进程，带超时。找不到命令 / 超时都不抛异常，全部体现在 RunResult 里，
/// 由调用方决定如何映射到 gate 判定。
///
/// [runInShell] 默认 `true`（保持既有行为：`flutter`/`adb` 在 Windows 上是
/// `.bat`，没有 shell 就解析不到）。但**开着 shell 时参数不做转义**，
/// 所以任何含 [kShellSyntaxChars] 的参数会被**当场拒绝**，返回一个说明原因的
/// 失败结果 —— 宁可让调用方看见一个明确的错误，也不要它拿到一个被篡改过的执行结果。
/// 需要传含这些字符的参数时，改用 `runInShell: false`。
Future<RunResult> runProcess(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 5),
  bool runInShell = true,
}) async {
  if (runInShell) {
    for (final String a in args) {
      final String? c = shellSyntaxIn(a);
      if (c != null) {
        return RunResult(
          ok: false,
          exitCode: -1,
          stdout: '',
          stderr: '**拒绝执行**：参数 `$a` 含 shell 语法字符 `$c`，而 `runInShell: true` '
              '时 Dart 不转义该参数，它会被 cmd.exe 解释成语法 —— 命令会以**另一种形式**'
              '执行，且往往返回 exit 0 与看似正常的结果。'
              '改用 `runInShell: false`（adb/git 这类把剩余参数原样拼给远端 shell 的'
              '工具，去掉本地 shell 后行为才正确）。',
        );
      }
    }
  }

  Process? proc;
  try {
    proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
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
///
/// **警告：它会返回真机。** 只做设备编排时不要用它，用 [requireEmulatorDevice]。
/// 现存调用点（截至 2026-09-17 未改，见 docs/PITFALLS.md「真机再次被抓进编排」）：
/// `capture_shots.dart`、`collect_metrics.dart`。它们同样可能在真机在线时抓走用户设备。
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

/// 一行 `adb devices` 输出里，若是在线的**模拟器**就返回它的 serial，否则 null。
///
/// **只认 `emulator-` 前缀。** 真机哪怕状态是 `device`、哪怕调试授权正常、哪怕它挂着
/// 本项目的 app，一律返回 null。
///
/// 做成纯函数（不碰 adb）是刻意的：**选择逻辑正是曾经出错的那一部分**，纯函数才能把
/// 各种 `adb devices` 输出逐条喂进 `test/gate/` 验，而不是"跑起来看着对"。
String? emulatorSerialInLine(String line) {
  final String trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('List of devices')) return null;
  final List<String> parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length < 2) return null;
  if (parts[1] != 'device') return null;
  if (!parts[0].startsWith('emulator-')) return null;
  return parts[0];
}

/// 扫一遍 `adb devices`，**只认 `emulator-*`**；没有就返回 null。
///
/// 私有：调用方只准走 [requireEmulatorDevice]。那条路**拿不到 null、也拿不到真机** ——
/// 这是"钉死 emulator-*"这条规则的**唯一一份实现**，不要再在别处复制这段解析。
Future<String?> _findEmulator({
  required Duration timeout,
  required Duration pollInterval,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (true) {
    final RunResult r =
        await runProcess('adb', <String>['devices'], timeout: const Duration(seconds: 15));
    if (r.ok) {
      for (final String line in r.stdout.split('\n')) {
        final String? id = emulatorSerialInLine(line);
        if (id != null) return id;
      }
    }
    if (!DateTime.now().isBefore(deadline)) return null;
    await Future<void>.delayed(pollInterval);
  }
}

/// 模拟器是否已经 boot 完成（`sys.boot_completed == 1`）。
///
/// 刚 launch 出来的模拟器"出现在 `adb devices` 里" ≠ "能用"。不等这一步就会在半启动的
/// 设备上跑测试，失败信息会指向被测代码而不是设备 —— 那是最贵的一种误导。
Future<bool> _bootCompleted(String serial) async {
  final RunResult r = await runProcess(
      'adb', <String>['-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
      timeout: const Duration(seconds: 15));
  return r.ok && r.stdout.trim() == '1';
}

/// adb 当前在线的**非模拟器**设备（真机）。仅用于诊断消息，绝不用于挑选。
Future<List<String>> _onlineNonEmulators() async {
  final RunResult r =
      await runProcess('adb', <String>['devices'], timeout: const Duration(seconds: 15));
  final List<String> out = <String>[];
  if (!r.ok) return out;
  for (final String line in r.stdout.split('\n')) {
    final String t = line.trim();
    if (t.isEmpty || t.startsWith('List of devices')) continue;
    final List<String> p = t.split(RegExp(r'\s+'));
    if (p.length >= 2 && p[1] == 'device' && !p[0].startsWith('emulator-')) {
      out.add(p[0]);
    }
  }
  return out;
}

/// 设备编排的**唯一入口**：要一台模拟器，拿不到就**抛**。
///
/// **不返回 null，也不退回真机**，两者都是刻意的：
/// - 返回 null 会给调用方留一个"顺手继续"的口子 —— 静默跳过、或退回真机；
/// - 退回真机曾经真的发生过：2026-09-17 G2A/G2B 把用户真机 `5bc6e093`（vivo X21A）
///   抓去装 APK，装不上，三轮各 ~191s 撞穿预算，产出 9/9 `pass=false, manual=false`
///   —— 与"真的 9 项退化"**完全同形**。
///
/// 抛错不可忽略，是断言。
///
/// [wait]：先等这么久，看有没有现成的模拟器。
/// [onMissing]：等不到时调用方在这里启动自己的模拟器；返回 true = 已发起，请再等一轮。
/// [bootTimeout]：`onMissing` 之后最多再等这么久。
///
/// 两轮都拿不到 ⇒ 抛 [StateError]，消息里列出**当前在线却被拒绝的真机**（便于诊断，
/// 并写明拒绝理由）。
Future<String> requireEmulatorDevice({
  Duration wait = const Duration(seconds: 5),
  Duration bootTimeout = const Duration(minutes: 3),
  Future<bool> Function()? onMissing,
}) async {
  const Duration kPoll = Duration(seconds: 5);
  final String? preexisting = await _findEmulator(timeout: wait, pollInterval: kPoll);
  if (preexisting != null) return preexisting;

  if (onMissing != null && await onMissing()) {
    final DateTime deadline = DateTime.now().add(bootTimeout);
    while (true) {
      final String? id = await _findEmulator(timeout: Duration.zero, pollInterval: kPoll);
      if (id != null && await _bootCompleted(id)) return id;
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(kPoll);
    }
  }

  final List<String> others = await _onlineNonEmulators();
  throw StateError(
    '拿不到模拟器：没有 emulator-* 在线（只认 emulator-*，真机一律不碰）。'
    '${others.isEmpty ? '当前也没有其它在线设备。' : '当前在线但被拒绝使用的真机：'
        '${others.join(', ')} —— 用户铁律「真机不要碰」，任何 gate 不得在其上安装或运行。'}',
  );
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
