// tools/gate/gate_G3.dart
//
// G3 — 端到端贯通（阶段 3 出口）。对应 docs/ACCEPTANCE.md 3.1-3.4。
//
// 架构同 G2A/G2B：真实引擎依赖平台通道（onnxruntime）与 dart:ui，
// 实际跑链路的代码在 integration_test/e2e_eval_test.dart，用 `flutter drive`
// 在模拟器里执行；本文件负责编排 + 阈值判定：
//
//   1) 起模拟器（host GPU 驱动栈损坏期间必须 -no-window -gpu guest
//      -feature -Vulkan，见 docs/PITFALLS.md；一次只起一台，用完 kill）
//   2) `flutter clean` 后由 flutter drive 做全量 debug 构建（Windows 增量
//      assembleDebug 产出损坏 APK，见 docs/PITFALLS.md，故不跳过 clean）
//   3) adb push 黄金集第一张 → drive e2e_eval_test.dart → 回收测量数据
//   4) 判 3.1（42 张产出）/ 3.2（2B.1 尺寸 + 2B.2 DPI + 2B.6 绿底溢色）
//      / 3.3（保存落盘可解码 + run-as 交叉验证）
//   5) 3.4 冷启动：**判定口径 = Dart main() → 真实工作台首帧**（探针
//      integration_test/coldstart_probe_test.dart，profile(AOT)+Skia），
//      3 轮取中位数 ≤ 2000ms。进程级 release(AOT) `am start -W` TotalTime
//      仍测量、仍记录，但 2026-09-14 人工授权修订 ACCEPTANCE 后只进报告作
//      参考、不参与 pass/fail —— 本机软渲染环境的进程/引擎启动段地板 ~6s
//      （G1 骨架基线 5988ms），与接线层无关。
//      必须带 intent extra `--ez enable-impeller false`（Skia 渲染）：本开发机
//      宿主 GPU 驱动栈损坏（docs/PITFALLS.md），任何用 Impeller GLES 渲染真实
//      UI 的 App 都会把 qemu 宿主进程直接杀死 —— release/profile 直启秒死、
//      debug main.dart 启动 ~45s 内死，已 5 次复现（2 台 AVD / 2 种客户机内存，
//      无 WER、无 minidump）。这是 flutter 工具链在 drive/run 时注入同一开关的
//      官方途径（android_device.dart:662-667 实证），G2 截图流水线一直如此。
//      TotalTime 3 轮取中位数记录进报告参考字段；判定用探针 mainToFrameMs
//      3 轮取中位数；另以 mResumedActivity + 截图非纯黑交叉验证"到可交互"。
//      拆分证据：integration_test/coldstart_probe_test.dart 在 profile(AOT)+Skia
//      下量得真实工作台 Dart 侧 build+layout+栅格仅 ~0.5s，TotalTime 的大头是
//      进程/引擎启动段 —— 与 G1 骨架 App 同口径 5988ms 的环境基线一致。
//
// 阈值解释（对照 ACCEPTANCE 原文的解读，供主会话核对）：
// - 3.2 的"通过 2B.6"：2B.6 原文是"换底到纯绿后 alpha>200 前景区域内
//   G−max(R,B)>40 计数=0"。真实照片的成片 JPEG 里没有 alpha，且被摄者
//   天然绿色（衣物）会造成绝对计数假阳性（imaging 在 docs/PITFALLS.md 有
//   实测记录），故设备端用"绿底成片 vs 白底成片逐像素基线校正"实现
//   "底色渗进前景"的定义：前景=非近纯绿像素，溢色=(G−max(R,B))_绿−
//   (G−max(R,B))_白 > 40 计 1，7 个规格全部 = 0 才算通过。
// - 3.1 同时校验 42 张候选的底色 id 与顺序符合 CONTRACTS 第 5 节锁定顺序。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gate_common.dart';
import 'device_harness_common.dart';
import 'gate_G2B.dart' show kContractSpecsPx;
import 'png_utils.dart';

const String kMainAvd = 'Pixel_3a_API_34_extension_level_7_x86_64';
const String kDeviceGateDir = '/data/local/tmp/muzhao_gate_tmp';
const String kResponseDataPath = 'build/integration_response_data.json';

/// CONTRACTS 第 5 节锁定的候选顺序。
const List<String> kExpectedStyleOrder = [
  'white', 'blue', 'red', 'deep_blue', 'gray', 'blue_gradient',
];

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G3.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final log = StringBuffer();
  final items = <Map<String, dynamic>>[];

  // ---- release 构建（不依赖模拟器，先做，避免 Gradle 与 qemu 抢内存）----
  final packageId = await findApplicationId();
  final prebuilt = packageId != null && await _buildRelease(log);

  // ---- 设备 ----
  final deviceId = await _ensureDeviceOnline(log);
  if (deviceId == null) {
    _addAllFail(items, '模拟器未能上线（含 boot_completed 等待超时）');
    if (prebuilt) {
      items.add(_fail34('模拟器未能上线，无法安装测量'));
    } else {
      items.add(_fail34('release 构建或 applicationId 解析失败'));
    }
    await _finish(outPath, items, deviceId: null);
    return;
  }
  log.writeln('设备已上线: $deviceId');

  // ---- 3.4 冷启动先跑（释放构建 + 3 轮启动 ≈ 几分钟，先落袋；
  //      端到端 drive 最耗时，放后面，降低"模拟器中途死掉全盘皆输"的风险）----
  items.add(prebuilt
      ? await _judge34(deviceId, log)
      : _fail34('release 构建未完成，跳过冷启动测量'));

  // ---- 3.1 / 3.2 / 3.3：端到端 drive ----
  final e2eData = await _runE2eDrive(deviceId, log);
  if (e2eData == null) {
    _addAllFail(items, '端到端评测（flutter drive e2e_eval_test.dart）失败/超时'
        '或没有产出 $kResponseDataPath，详见 out/gate_G3_run.log');
  } else {
    items.addAll(_judge31(e2eData));
    items.addAll(_judge32(e2eData));
    items.add(await _judge33(e2eData, deviceId));
  }

  await _killEmulator(deviceId, log);

  final logFile = File('out/gate_G3_run.log');
  await logFile.parent.create(recursive: true);
  await logFile.writeAsString(log.toString());

  await _finish(outPath, items, deviceId: deviceId);
}

Future<void> _finish(String outPath, List<Map<String, dynamic>> items,
    {String? deviceId}) async {
  await writeGateReport(outPath: outPath, gateId: 'G3', items: items);
  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G3 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  exit(allPass ? 0 : 1);
}

void _addAllFail(List<Map<String, dynamic>> items, String reason) {
  const specs = [
    ['3.1', '真实照片跑通全链路：黄金集第一张 → 42 张全部产出'],
    ['3.2', '42 张全部通过 2B.1 尺寸 / 2B.2 DPI / 2B.6 绿底溢色'],
    ['3.3', '保存：落盘路径存在且文件可被重新解码'],
  ];
  for (final s in specs) {
    items.add({
      'id': s[0],
      'description': s[1],
      'expected': '见 ACCEPTANCE.md',
      'actual': reason,
      'pass': false,
      'manual': false,
    });
  }
}

// ---------------------------------------------------------------------------
// 设备管理
// ---------------------------------------------------------------------------

Future<String?> _ensureDeviceOnline(StringBuffer log) async {
  var deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 5));
  if (deviceId != null) return deviceId;

  // 先释放 Gradle daemon 内存（host 内存紧张曾挤崩 AVD）。
  final gradleStop = await runProcess('gradlew', ['--stop'],
      workingDirectory: 'android', timeout: const Duration(minutes: 2));
  log.writeln('gradlew --stop 退出码=${gradleStop.exitCode}');

  log.writeln('没有在线设备，按本机 GPU 驱动现状用安全参数启动模拟器 $kMainAvd ...');
  try {
    // 控制台输出捕获到文件：上一轮执行 qemu 无 crash dump 消失，死因无从查起。
    // 不用 detached（detach 后 stdout 丢失），改由本进程托管 stdout/stderr 落盘；
    // gate 结束前会 adb emu kill 收尾。
    final consoleSink =
        File('out/GATE_emu_console.log').openWrite(mode: FileMode.write);
    final proc = await Process.start(
      'emulator',
      [
        '-avd', kMainAvd,
        '-no-snapshot', // 全量冷启动，避开旧快照状态（前几轮用过 -no-snapshot-save 会加载旧快照）
        '-no-boot-anim',
        '-no-window',
        '-gpu', 'guest',
        '-feature', '-Vulkan',
      ],
      runInShell: true,
    );
    proc.stdout.transform(utf8.decoder).listen(consoleSink.write);
    proc.stderr.transform(utf8.decoder).listen(consoleSink.write);
    unawaited(proc.exitCode.then((_) => consoleSink.close()));
    log.writeln('emulator 已启动（控制台输出 → out/GATE_emu_console.log）');
  } catch (e) {
    log.writeln('emulator 启动失败: $e');
    return null;
  }
  deviceId = await waitForAdbDeviceOnline(timeout: const Duration(minutes: 5));
  if (deviceId == null) return null;

  // 等 Android 侧 boot_completed，避免 drive 撞上半开机状态。
  final bootDeadline = DateTime.now().add(const Duration(minutes: 4));
  while (DateTime.now().isBefore(bootDeadline)) {
    final r = await runProcess(
        'adb', ['-s', deviceId, 'shell', 'getprop', 'sys.boot_completed'],
        timeout: const Duration(seconds: 15));
    if (r.ok && r.stdout.trim() == '1') {
      log.writeln('sys.boot_completed=1');
      return deviceId;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  log.writeln('警告: boot_completed 4 分钟内未置 1，继续尝试');
  return deviceId;
}

Future<void> _killEmulator(String serial, StringBuffer log) async {
  await runProcess('adb', ['-s', serial, 'emu', 'kill'],
      timeout: const Duration(seconds: 15));
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final r = await runProcess('adb', ['devices'], timeout: const Duration(seconds: 15));
    final stillThere = r.ok &&
        r.stdout.split('\n').any((l) {
          final p = l.trim().split(RegExp(r'\s+'));
          return p.isNotEmpty && p[0] == serial;
        });
    if (!stillThere) {
      log.writeln('$serial 已从 adb devices 消失');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  log.writeln('警告: $serial 60s 内未从 adb devices 消失');
}

// ---------------------------------------------------------------------------
// 3.1 / 3.2 / 3.3
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>?> _runE2eDrive(String deviceId, StringBuffer log) async {
  final prep = await prepareDeviceGateDir(deviceId, kDeviceGateDir);
  if (!prep.success) {
    log.writeln('设备端建目录/放权限失败: ${prep.tail(maxChars: 300)}');
    return null;
  }
  final push = await adbPush(
      deviceId, 'test/golden/src/g01.jpg', '$kDeviceGateDir/golden/src/g01.jpg');
  if (!push.success) {
    log.writeln('adb push 黄金集失败: ${push.tail(maxChars: 300)}');
    return null;
  }

  // 全量构建由 flutter drive 在 clean 后自行完成（见文件头注释）。
  final clean = await runProcess('flutter', ['clean'], timeout: const Duration(minutes: 5));
  log.writeln('flutter clean 退出码=${clean.exitCode}');

  final responseFile = File(kResponseDataPath);
  if (await responseFile.exists()) await responseFile.delete();

  final driveRun = await runProcess(
    'flutter',
    [
      'drive',
      // host GPU 损坏期间 Impeller GLES 在软渲染下会带走 qemu（PITFALLS），
      // 统一退回 Skia，纯 deprecation 警告。
      '--no-enable-impeller',
      '--driver=test_driver/integration_test_driver.dart',
      '--target=integration_test/e2e_eval_test.dart',
      '-d',
      deviceId,
      '--dart-define=GATE_TMP_DIR=$kDeviceGateDir',
    ],
    timeout: const Duration(minutes: 45),
  );
  log.writeln('flutter drive e2e 退出码=${driveRun.exitCode} timedOut=${driveRun.timedOut}');
  log.writeln(driveRun.tail(maxChars: 3000));
  if (!driveRun.success || !await responseFile.exists()) return null;

  try {
    return jsonDecode(await responseFile.readAsString()) as Map<String, dynamic>;
  } catch (e) {
    log.writeln('解析 $kResponseDataPath 失败: $e');
    return null;
  }
}

List<Map<String, dynamic>> _judge31(Map<String, dynamic> data) {
  final specs = (data['specs'] as Map<String, dynamic>?) ?? {};
  final errors = (data['errors'] as List<dynamic>?) ?? [];
  final issues = <String>[];
  var decodedCount = 0;

  if (errors.isNotEmpty) issues.add('设备端流程错误: ${errors.join('; ')}');
  final load = (data['loadImage'] as Map<String, dynamic>?) ?? {};
  if (load['stage'] != 'ready') {
    issues.add('loadImage 未到 ready（stage=${load['stage']}, '
        'errorMessage=${load['errorMessage']}）');
  }

  for (final specId in kContractSpecsPx.keys) {
    final rec = specs[specId] as Map<String, dynamic>?;
    if (rec == null) {
      issues.add('$specId(规格结果缺失)');
      continue;
    }
    if (rec['stage'] != 'ready') {
      issues.add('$specId(stage=${rec['stage']}, error=${rec['errorMessage']})');
    }
    final styleIds = (rec['styleIds'] as List<dynamic>?) ?? [];
    if (styleIds.toString() != kExpectedStyleOrder.toString()) {
      issues.add('$specId(候选底色顺序错误: $styleIds)');
    }
    for (final c in (rec['candidates'] as List<dynamic>?) ?? []) {
      final m = c as Map<String, dynamic>;
      if (m['decoded'] == true) {
        decodedCount++;
      } else {
        issues.add('$specId/${m['styleId']}(JPEG 解码失败)');
      }
    }
  }

  return [
    {
      'id': '3.1',
      'description': '真实照片跑通全链路：黄金集第一张，真实 IdPhotoEngineImpl + '
          'MuZhaoController，7 规格 × 6 底色 = 42 张全部产出（含底色 id 与 CONTRACTS '
          '第 5 节锁定顺序一致）',
      'expected': '42/42 张产出且全部可解码',
      'actual': issues.isEmpty
          ? '42/42 张产出（可解码 $decodedCount 张；loadImage '
              '${load['ms']}ms，逐规格重合成见 out/gate_G3.json）'
          : '产出可解码 $decodedCount/42 张；问题: ${issues.join('; ')}',
      'pass': decodedCount == 42 && issues.isEmpty,
      'manual': false,
    }
  ];
}

List<Map<String, dynamic>> _judge32(Map<String, dynamic> data) {
  final specs = (data['specs'] as Map<String, dynamic>?) ?? {};
  final dimFails = <String>[];
  final dpiFails = <String>[];
  var measured = 0;

  for (final entry in specs.entries) {
    final specId = entry.key;
    final contract = kContractSpecsPx[specId];
    for (final c in (entry.value as Map<String, dynamic>)['candidates'] ?? []) {
      final m = c as Map<String, dynamic>;
      measured++;
      if (contract == null) {
        dimFails.add('$specId(不在 CONTRACTS 规格表内)');
        continue;
      }
      if (m['width'] != contract['w'] || m['height'] != contract['h']) {
        dimFails.add('$specId/${m['styleId']}(实测 ${m['width']}x${m['height']}，'
            '期望 ${contract['w']}x${contract['h']})');
      }
      if (m['xDensity'] != 300 || m['yDensity'] != 300 || m['units'] != 1) {
        dpiFails.add('$specId/${m['styleId']}(x=${m['xDensity']} y=${m['yDensity']} '
            'units=${m['units']} ${m['densityError'] ?? ''})');
      }
    }
  }

  final spill = (data['greenSpill'] as Map<String, dynamic>?) ?? {};
  final spillFails = <String>[];
  for (final specId in kContractSpecsPx.keys) {
    final rec = spill[specId] as Map<String, dynamic>?;
    if (rec == null) {
      spillFails.add('$specId(无溢色测量数据)');
      continue;
    }
    if (rec['error'] != null) {
      spillFails.add('$specId(${rec['error']})');
    } else if (rec['spillCount'] != 0) {
      spillFails.add('$specId(溢色 ${rec['spillCount']} 像素)');
    }
  }

  return [
    {
      'id': '3.2',
      'description': '42 张产出合法性：2B.1 像素尺寸精确匹配 CONTRACTS 第 4 节 + '
          '2B.2 JFIF DPI 回读=300 + 2B.6 绿底溢色=0（真实照片采用"绿底减白底逐像素'
          '基线校正"口径，见文件头注释）',
      'expected': '42/42 尺寸精确 + 42/42 DPI=300 + 7/7 规格绿底溢色=0',
      'actual': '测量候选 $measured 张；尺寸不达标 ${dimFails.isEmpty ? '无' : dimFails.join(', ')}；'
          'DPI 不达标 ${dpiFails.isEmpty ? '无' : dpiFails.join(', ')}；'
          '溢色不达标 ${spillFails.isEmpty ? '无' : spillFails.join(', ')}',
      'pass': measured == 42 && dimFails.isEmpty && dpiFails.isEmpty && spillFails.isEmpty,
      'manual': false,
    }
  ];
}

Future<Map<String, dynamic>> _judge33(Map<String, dynamic> data, String deviceId) async {
  final save = (data['save'] as Map<String, dynamic>?) ?? {};
  final path = save['path'] as String?;
  final exists = save['exists'] == true;
  final decoded = save['decoded'] == true;
  final threw = save['error'] != null;

  // host 侧 run-as 交叉验证：私有目录 host 摸不到，但 debug 包可 run-as。
  String runAsNote = '未执行';
  if (path != null && exists) {
    final packageId = await findApplicationId();
    if (packageId == null) {
      runAsNote = '无法解析 applicationId，跳过（仅设备端验证）';
    } else {
      final baseName = path.split('/').last;
      final ls = await runProcess(
          'adb', ['-s', deviceId, 'shell', 'run-as', packageId, 'ls', '-l', 'cache'],
          timeout: const Duration(seconds: 20));
      if (ls.success && ls.stdout.contains(baseName)) {
        runAsNote = 'run-as 交叉验证命中: cache/$baseName';
      } else if (ls.success) {
        runAsNote = 'run-as cache 目录中未找到 $baseName（与设备端验证矛盾）';
      } else {
        runAsNote = 'run-as 不可用（${ls.tail(maxChars: 120)}），仅设备端验证';
      }
    }
  }

  return {
    'id': '3.3',
    'description': '保存：controller.save() 落盘路径存在且文件可被重新解码（'
        '真实 controller，含 Gal 写相册链路）',
    'expected': '返回路径存在 + JPEG 可重新解码；无异常',
    'actual': threw
        ? 'save 抛出异常: ${save['error']}（Gal 写相册失败也会走这里）'
        : 'path=$path exists=$exists byteLen=${save['byteLen']} decoded=$decoded '
            '(${save['decodedWidth']}x${save['decodedHeight']})；$runAsNote',
    'pass': !threw && exists && decoded,
    'manual': false,
  };
}

// ---------------------------------------------------------------------------
// 3.4 冷启动（判定口径 = Dart main→首帧探针；TotalTime 仅作参考记录。
// 2026-09-14 人工授权修订 docs/ACCEPTANCE.md G3.4，见该文件口径变更记录）
// ---------------------------------------------------------------------------

Future<bool> _buildRelease(StringBuffer log) async {
  final releaseBuild = await runProcess(
    'flutter',
    ['build', 'apk', '--release'],
    timeout: const Duration(minutes: 30),
  );
  log.writeln('flutter build apk --release 退出码=${releaseBuild.exitCode} '
      'timedOut=${releaseBuild.timedOut}');
  log.writeln(releaseBuild.tail(maxChars: 1500));
  if (!releaseBuild.success) return false;
  return File('build/app/outputs/flutter-apk/app-release.apk').exists();
}

Future<Map<String, dynamic>> _judge34(String deviceId, StringBuffer log) async {
  final packageId = await findApplicationId();
  if (packageId == null) {
    return _fail34('无法从 android/app/build.gradle(.kts) 解析 applicationId');
  }

  final apk = File('build/app/outputs/flutter-apk/app-release.apk');
  if (!await apk.exists()) {
    return _fail34('找不到 ${apk.path}（release 构建未完成）');
  }

  final install = await runProcess(
      'adb', ['-s', deviceId, 'install', '-r', apk.path],
      timeout: const Duration(minutes: 5));
  log.writeln('adb install -r app-release.apk 退出码=${install.exitCode}');
  if (!install.success) {
    return _fail34('adb install app-release.apk 失败: ${install.tail(maxChars: 300)}');
  }

  final totals = <int>[];
  final totalDetails = <String>[];
  String? interactiveFail;

  // ---- 参考口径（不判定）：release(AOT) am start -W TotalTime ----
  // 安装后先试启动一次再计时：避开安装刚完成时系统的整理噪声（实测第一次
  // am start 常报 Status: timeout）。每次计时前都 force-stop，仍是冷启动。
  await runProcess(
    'adb',
    ['-s', deviceId, 'shell', 'am', 'start', '-W', '--ez', 'enable-impeller', 'false',
     '-n', '$packageId/.MainActivity'],
    timeout: const Duration(seconds: 120),
  );

  // --ez enable-impeller false：见文件头注释。宿主 GPU 栈损坏期间 Impeller
  // GLES 渲染真实 UI 会杀死 qemu 宿主进程，必须 Skia 启动。
  const impellerOff = ['--ez', 'enable-impeller', 'false'];
  for (var cycle = 1; cycle <= 3; cycle++) {
    await runProcess('adb', ['-s', deviceId, 'shell', 'am', 'force-stop', packageId],
        timeout: const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(seconds: 2));
    final start = await runProcess(
      'adb',
      [
        '-s', deviceId, 'shell', 'am', 'start', '-W',
        ...impellerOff,
        '-n', '$packageId/.MainActivity',
      ],
      timeout: const Duration(seconds: 120),
    );
    final m = RegExp(r'TotalTime:\s*(\d+)').firstMatch(start.stdout);
    if (m == null) {
      totalDetails.add('第${cycle}轮: 未解析到 TotalTime（${start.stdout.trim()}）');
      continue;
    }
    final ms = int.parse(m.group(1)!);
    totals.add(ms);
    totalDetails.add('第${cycle}轮: ${ms}ms');

    // "到可交互"交叉验证：Activity 处于 resumed 且屏幕非纯黑。
    // 注意字段名：Android 14 (API 34) 镜像的 dumpsys 里旧字段 mResumedActivity
    // 已不存在（实测全文 0 次出现），现名 topResumedActivity= 与
    // ResumedActivity:（见 out/GATE_dumpsys_raw.txt）。'ResumedActivity' 是
    // 新旧字段名的公共子串，用它匹配。此前两轮误报即源于此（工装 bug，
    // 非 app 问题：取证显示全新安装首次启动 2s 内即 resumed，见
    // out/GATE_c1_f*.png 与 r2 报告）。
    var resumedOk = false;
    final resumeDeadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(resumeDeadline)) {
      final resumed = await runProcess(
          'adb', ['-s', deviceId, 'shell', 'dumpsys', 'activity', 'activities'],
          timeout: const Duration(seconds: 20));
      resumedOk = resumed.ok &&
          resumed.stdout.split('\n').any((l) =>
              l.contains('ResumedActivity') && l.contains(packageId));
      if (resumedOk) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (!resumedOk && interactiveFail == null) {
      interactiveFail = '第${cycle}轮 12s 内 ResumedActivity 未指向 $packageId';
    }
    if (cycle == 1) {
      final shot = await _screenshot(deviceId, 'out/GATE_G3_coldstart.png');
      if (shot == null) {
        if (interactiveFail == null) interactiveFail = '冷启动证据截图失败';
      } else if (isCenterAllBlack(shot)) {
        if (interactiveFail == null) interactiveFail = '冷启动截图中心区域纯黑（未渲染出界面）';
      }
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  String ttNote;
  if (totals.isEmpty) {
    ttNote = 'TotalTime 参考未取得（${totalDetails.join('; ')}）';
  } else {
    final ttSorted = totals.toList()..sort();
    ttNote = 'TotalTime 参考（不判定）: ${totalDetails.join(', ')} → 中位 '
        '${ttSorted[ttSorted.length ~/ 2]}ms';
  }

  // ---- 判定口径（2026-09-14 人工授权修订）：Dart main() → 首帧探针 ----
  // profile(AOT)+Skia 驱动 coldstart_probe_test.dart，3 轮取中位数。
  final probeMs = <int>[];
  final probeDetails = <String>[];
  for (var cycle = 1; cycle <= 3; cycle++) {
    final rf = File(kResponseDataPath);
    if (await rf.exists()) await rf.delete();
    final probeDrive = await runProcess(
      'flutter',
      [
        'drive', '--profile', '--no-enable-impeller',
        '--driver=test_driver/integration_test_driver.dart',
        '--target=integration_test/coldstart_probe_test.dart',
        '-d', deviceId,
      ],
      timeout: const Duration(minutes: 20),
    );
    log.writeln('探针第${cycle}轮 drive 退出码=${probeDrive.exitCode} '
        'timedOut=${probeDrive.timedOut}');
    log.writeln(probeDrive.tail(maxChars: 1500));
    if (!probeDrive.success || !await rf.exists()) {
      probeDetails.add('第${cycle}轮: drive 失败或无数据');
      await Future<void>.delayed(const Duration(seconds: 2));
      continue;
    }
    try {
      final pd = jsonDecode(await rf.readAsString()) as Map<String, dynamic>;
      final v = pd['mainToFrameMs'];
      if (v is num) {
        probeMs.add(v.round());
        probeDetails.add('第${cycle}轮: ${v.round()}ms');
      } else {
        probeDetails.add('第${cycle}轮: mainToFrameMs 缺失');
      }
    } catch (e) {
      probeDetails.add('第${cycle}轮: 探针数据解析失败($e)');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  if (probeMs.isEmpty) {
    return _fail34('探针 3 轮均未产出 mainToFrameMs: ${probeDetails.join('; ')}；'
        '$ttNote');
  }

  final sorted = probeMs.toList()..sort();
  final median = sorted[sorted.length ~/ 2];
  return {
    'id': '3.4',
    'description': '冷启动 ≤2000ms（2026-09-14 人工授权修订口径）：Dart main() → '
        '真实工作台首帧（探针 integration_test/coldstart_probe_test.dart，'
        'profile AOT + Skia）3 轮取中位数；进程级 am start -W TotalTime 仍测量、'
        '只记录作参考不判定；mResumedActivity + 截图非纯黑交叉验证可交互',
    'expected': '探针中位数 ≤ 2000ms 且界面可交互',
    'actual': '探针各轮 ${probeDetails.join(', ')} → 中位数 $median ms；$ttNote；'
        '可交互交叉验证: ${interactiveFail ?? '通过（out/GATE_G3_coldstart.png）'}',
    'pass': median <= 2000 && interactiveFail == null,
    'manual': false,
  };
}

Map<String, dynamic> _fail34(String reason) => {
      'id': '3.4',
      'description': '冷启动 ≤2000ms（2026-09-14 人工授权修订口径：Dart main→首帧探针）',
      'expected': '探针中位数 ≤ 2000ms 且界面可交互',
      'actual': reason,
      'pass': false,
      'manual': false,
    };

/// 二进制安全的截图（runProcess 会把 stdout 按 utf8 解码，PNG 会被破坏）。
Future<dynamic> _screenshot(String deviceId, String outPath) async {
  try {
    final proc = await Process.start('adb', ['-s', deviceId, 'exec-out', 'screencap', '-p']);
    final bytes = <int>[];
    await for (final chunk in proc.stdout) {
      bytes.addAll(chunk);
    }
    final exitCode = await proc.exitCode;
    if (exitCode != 0 || bytes.isEmpty) return null;
    final f = File(outPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return decodePng(Uint8List.fromList(bytes));
  } catch (_) {
    return null; // 截图证据失败由调用方记入 interactiveFail，不吞判定
  }
}
