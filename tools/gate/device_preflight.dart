/// 设备预检：**证明模拟器真的能起来，且真机被正确忽略。**
///
/// ## 为什么要有这个文件
///
/// 2026-09-17，主机上唯一的 adb 设备是**用户真机 vivo X21A**（`5bc6e093`）。
/// `gate_G2B.dart:91` 的 `waitForAdbDeviceOnline(...) ?? await _launchAndWait()`
/// 因为"已经有设备在线"而**短路**，模拟器压根没启动，`flutter drive` 直接把 APK
/// 装向真机；真机拒绝无人值守安装，三轮各 ~191s 撞穿 10 分钟预算，产出
/// 9/9 `pass=false, manual=false` —— 与"真的 9 项退化"**完全同形**。
///
/// 修完之后，"能不能拿到模拟器"这件事必须**在开跑前被证明**，而不是等到
/// 一轮 100 分钟的设备会话跑完、从产物里反推。**没证明就开跑 = 重演那一幕。**
///
/// 本工具跑的就是生产路径（`requireEmulatorDevice` + `launchMainAvd`），
/// 不另写一套 —— 否则证明的是"另一套能跑"，不是"要跑的那套能跑"。
///
/// ## 判据（三条都过才 exit 0）
/// 1. 真机在线时，被选中的必须是 `emulator-*`，**不是**真机；
/// 2. 选中的模拟器 `sys.boot_completed == 1`（出现在 `adb devices` 里 ≠ 能用）；
/// 3. 拿不到模拟器时**抛** `StateError`，不静默返回（此路径由 `requireEmulatorDevice` 保证，
///    本工具只在失败时如实记 exit 1）。
///
/// 运行：`dart run tools/gate/device_preflight.dart`
/// 日志：`out/GATE_device_preflight.log`（含模拟器控制台日志路径）
library;

import 'dart:io';

import 'gate_common.dart';

/// 同时写 stdout 与日志文件。
class _Tee {
  _Tee(this._file) {
    _file.writeAsStringSync('');
  }
  final File _file;
  void call(String line) {
    stdout.writeln(line);
    _file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }
}

Future<void> main(List<String> args) async {
  final _Tee out = _Tee(File('out/GATE_device_preflight.log'));
  out('设备预检 —— ${DateTime.now().toIso8601String()}');
  out('主机：${Platform.operatingSystem} / ${Platform.localHostname}');

  // ---- 开跑前的现场 ----
  final RunResult before = await runProcess('adb', <String>['devices', '-l'],
      timeout: const Duration(seconds: 15));
  out('');
  out('== 预检前的 adb devices -l ==');
  for (final String l in before.stdout.trim().split('\n')) {
    out('  $l');
  }

  // ---- 走生产路径拿设备 ----
  out('');
  out('== requireEmulatorDevice（只认 emulator-*，拿不到就抛）==');
  // 日志写在**本 agent 自己的** out/GATE_* 下。`out/tmp/` 是 visual-critic 的地盘，
  // gatekeeper 往那里写就是越界 —— 与我们对实现类 agent 的判据是同一条。
  const String consoleLog = 'out/GATE_device_preflight_emu_console.log';
  String? serial;
  try {
    serial = await requireEmulatorDevice(
      wait: const Duration(seconds: 5),
      bootTimeout: const Duration(minutes: 8),
      onMissing: () async {
        out('  没有现成的模拟器，调用 launchMainAvd 启动 $kMainAvd …');
        final bool ok = await launchMainAvd(
          consoleLogPath: consoleLog,
          log: (String s) => out('  [emu] $s'),
        );
        out('  launchMainAvd => $ok（控制台日志 $consoleLog）');
        return ok;
      },
    );
  } on StateError catch (e) {
    out('');
    out('**预检 FAIL**：requireEmulatorDevice 抛出 StateError ——');
    out('  ${e.message}');
    out('');
    out('结论：**没有可用模拟器，任何设备侧 gate 都不得开跑。**');
    exit(1);
  }

  // ---- 判据 1：选中的不是真机 ----
  final RunResult after = await runProcess('adb', <String>['devices'],
      timeout: const Duration(seconds: 15));
  final List<String> nonEmulators = <String>[];
  for (final String line in after.stdout.split('\n')) {
    final List<String> p = line.trim().split(RegExp(r'\s+'));
    if (p.length >= 2 && p[1] == 'device' && !p[0].startsWith('emulator-')) {
      nonEmulators.add(p[0]);
    }
  }
  final bool pickedEmulator = serial != null && serial.startsWith('emulator-');
  out('');
  out('== 判据 1：真机在线时被选中的是谁 ==');
  out('  当前在线的真机（应被无视）：'
      '${nonEmulators.isEmpty ? '（无）' : nonEmulators.join(', ')}');
  out('  requireEmulatorDevice 返回：$serial');
  out('  ${pickedEmulator ? 'PASS' : '**FAIL**'} —— '
      '${pickedEmulator ? '选中的是模拟器' : '选中的不是 emulator-*！'}');
  if (nonEmulators.contains(serial)) {
    out('  **FAIL**：返回的就是真机 $serial —— 这是本次事故本身。');
    exit(1);
  }

  // ---- 判据 2：boot 完成 ----
  final RunResult boot = await runProcess(
      'adb', <String>['-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
      timeout: const Duration(seconds: 20));
  final RunResult wm = await runProcess(
      'adb', <String>['-s', serial, 'shell', 'wm', 'size'],
      timeout: const Duration(seconds: 20));
  final RunResult chr = await runProcess(
      'adb', <String>['-s', serial, 'shell', 'getprop', 'ro.build.characteristics'],
      timeout: const Duration(seconds: 20));
  final bool booted = boot.ok && boot.stdout.trim() == '1';
  out('');
  out('== 判据 2：这台模拟器真的能用吗 ==');
  out('  sys.boot_completed = ${boot.stdout.trim()}（期望 1）');
  out('  wm size            = ${wm.stdout.trim()}');
  out('  ro.build.characteristics = ${chr.stdout.trim()}（期望含 emulator）');
  out('  ${booted ? 'PASS' : '**FAIL**'}');

  final bool ok = pickedEmulator && booted;
  out('');
  out(ok ? '**预检 PASS**：模拟器可用（$serial），真机被正确忽略。'
         : '**预检 FAIL**：见上。');
  exit(ok ? 0 : 1);
}
