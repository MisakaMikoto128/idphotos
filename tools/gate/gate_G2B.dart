// tools/gate/gate_G2B.dart
//
// G2B — 合成引擎（imaging 出口）。对应 docs/ACCEPTANCE.md 2B.1-2B.9。
//
// 架构同 gate_G2A.dart：`compose()` 依赖 dart:ui，纯 `dart run` 摸不到，
// 编排设备端评测（integration_test/compose_eval_test.dart），阈值判断留在本文件。
// 不依赖 ml-porting 的抠图结果——用 gatekeeper 自己构造的"合成人像"喂给 compose()，
// 解耦 G2A/G2B（细节见 compose_eval_test.dart 头部注释）。
//
// **2B.1 的期望像素尺寸严格抄自 docs/CONTRACTS.md 第 4 节**，不读 lib/core/api.dart
// 里的常量——如果 imaging 改动了 api.dart 里的数字（不管是不是故意的），这里应该能测出来，
// 而不是自己骗自己（两边抄一份一样的数字，测了等于没测）。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';
import 'device_harness_common.dart';

const String kComposeMixinDir = 'lib/core/imaging';
const String kComposeMixinName = 'ComposeEngineMixin';
const String kGeneratedHarnessPath = 'integration_test/_generated_compose_harness.dart';
const String kGeneratedHarnessClass = 'GateComposeHarness';
const String kDeviceGateDir = '/sdcard/muzhao_gate_tmp';

/// CONTRACTS.md 第 4 节，逐字抄录，不从 api.dart 读。
const Map<String, Map<String, int>> kContractSpecsPx = {
  'cn_1inch': {'w': 295, 'h': 413},
  'cn_small_1inch': {'w': 260, 'h': 378},
  'cn_big_1inch': {'w': 390, 'h': 567},
  'cn_2inch': {'w': 413, 'h': 579},
  'cn_small_2inch': {'w': 413, 'h': 531},
  'cn_social_security': {'w': 358, 'h': 441},
  'visa_us': {'w': 600, 'h': 600},
};

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G2B.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final mixinLocation = await findMixinImportPath(kComposeMixinDir, kComposeMixinName);
  List<Map<String, dynamic>> items;
  if (mixinLocation == null) {
    items = _waitingItems();
  } else {
    await generateHarnessFile(
      outPath: kGeneratedHarnessPath,
      location: mixinLocation,
      className: kGeneratedHarnessClass,
      mixinName: kComposeMixinName,
      providedMethods: const {'compose'},
    );
    items = await _runDeviceEval();
  }

  await writeGateReport(outPath: outPath, gateId: 'G2B', items: items);
  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G2B 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  exit(allPass ? 0 : 1);
}

List<Map<String, dynamic>> _waitingItems() {
  const ids = ['2B.1', '2B.2', '2B.3', '2B.4', '2B.5', '2B.6', '2B.7', '2B.8', '2B.9'];
  const descs = [
    '7 个规格逐一像素级精确匹配 CONTRACTS 第 4 节',
    'JFIF DPI 字段回读=300，7/7',
    '头高比偏差 <=0.02',
    '头顶留白比偏差 <=0.02',
    '人脸水平居中偏差 <=画宽 3%',
    '纯绿底溢色计数=0',
    '纯品红底溢色计数=0',
    '摆正 rollDeg 残差 <=1.5°',
    '边界安全：不抛异常、无黑边',
  ];
  return List.generate(ids.length, (i) {
    return {
      'id': ids[i],
      'description': descs[i],
      'expected': '见 ACCEPTANCE.md',
      'actual': '在 $kComposeMixinDir 下没有找到 `mixin $kComposeMixinName` 声明，'
          'imaging 尚未交付，无法跑设备端合成评测',
      'pass': false,
      'manual': false,
    };
  });
}

Future<List<Map<String, dynamic>>> _runDeviceEval() async {
  final deviceId = await waitForAdbDeviceOnline(timeout: const Duration(seconds: 5)) ??
      await _launchAndWait();
  if (deviceId == null) {
    return _deviceUnavailableItems('模拟器未能上线');
  }

  final testRun = await runProcess(
    'flutter',
    [
      'test',
      'integration_test/compose_eval_test.dart',
      '-d',
      deviceId,
      '--dart-define=GATE_TMP_DIR=$kDeviceGateDir',
    ],
    timeout: const Duration(minutes: 10),
  );
  if (!testRun.success) {
    return _deviceUnavailableItems(
        '设备端评测（flutter test compose_eval_test.dart）失败/超时，可能是 imaging 的 '
        'mixin 编译不过或运行异常。退出码=${testRun.exitCode} timedOut=${testRun.timedOut}\n'
        '${testRun.tail(maxChars: 1500)}');
  }

  final pullDir = Directory('out/tmp/g2b_device_results');
  await pullDir.create(recursive: true);
  final pull = await adbPull(deviceId, '$kDeviceGateDir/g2b_results.json', pullDir.path);
  final resultFile = File('${pullDir.path}/g2b_results.json');
  if (!pull.success || !await resultFile.exists()) {
    return _deviceUnavailableItems('adb pull 结果文件失败: ${pull.tail(maxChars: 300)}');
  }

  final data = jsonDecode(await resultFile.readAsString()) as Map<String, dynamic>;
  return _applyThresholds(data);
}

Future<String?> _launchAndWait() async {
  await runProcess('flutter', ['emulators', '--launch', 'Pixel_3a_API_34_extension_level_7_x86_64'],
      timeout: const Duration(seconds: 30));
  return waitForAdbDeviceOnline(timeout: const Duration(minutes: 3));
}

List<Map<String, dynamic>> _deviceUnavailableItems(String reason) {
  const ids = ['2B.1', '2B.2', '2B.3', '2B.4', '2B.5', '2B.6', '2B.7', '2B.8', '2B.9'];
  return ids
      .map((id) => {
            'id': id,
            'description': '需要设备端合成结果',
            'expected': '见 ACCEPTANCE.md',
            'actual': reason,
            'pass': false,
            'manual': false,
          })
      .toList();
}

List<Map<String, dynamic>> _applyThresholds(Map<String, dynamic> data) {
  final items = <Map<String, dynamic>>[];
  final specs = (data['specs'] as Map<String, dynamic>?) ?? {};

  // 2B.1 像素尺寸
  final dimFails = <String>[];
  kContractSpecsPx.forEach((id, wh) {
    final m = specs[id] as Map<String, dynamic>?;
    if (m == null || m['error'] != null) {
      dimFails.add('$id(${m?['error'] ?? '缺失'})');
      return;
    }
    if (m['width'] != wh['w'] || m['height'] != wh['h']) {
      dimFails.add('$id(实测 ${m['width']}x${m['height']}，期望 ${wh['w']}x${wh['h']})');
    }
  });
  items.add({
    'id': '2B.1',
    'description': '7 个规格逐一像素级精确匹配 CONTRACTS.md 第 4 节',
    'expected': kContractSpecsPx.toString(),
    'actual': dimFails.isEmpty ? '7/7 精确匹配' : '不匹配: ${dimFails.join(', ')}',
    'pass': specs.length == 7 && dimFails.isEmpty,
    'manual': false,
  });

  // 2B.2 JFIF DPI
  final dpiFails = <String>[];
  specs.forEach((id, v) {
    final m = v as Map<String, dynamic>;
    final xd = m['xDensity'], yd = m['yDensity'], units = m['densityUnits'];
    if (xd != 300 || yd != 300 || units != 1) {
      dpiFails.add('$id(x=$xd y=$yd units=$units)');
    }
  });
  items.add({
    'id': '2B.2',
    'description': 'JFIF DPI 字段回读=300，7/7',
    'expected': '每个规格 xDensity=yDensity=300, units=1(DPI)',
    'actual': dpiFails.isEmpty ? '7/7 通过' : '不达标: ${dpiFails.join(', ')}',
    'pass': specs.length == 7 && dpiFails.isEmpty,
    'manual': false,
  });

  // 2B.3 头高比 / 2B.4 头顶留白比 / 2B.5 水平居中
  final headHeightFails = <String>[];
  final headTopFails = <String>[];
  final centerFails = <String>[];
  specs.forEach((id, v) {
    final m = v as Map<String, dynamic>;
    final h = (m['height'] as num?)?.toDouble();
    final w = (m['width'] as num?)?.toDouble();
    final headTopYOut = (m['headTopYOut'] as num?)?.toDouble();
    final chinYOut = (m['chinYOut'] as num?)?.toDouble();
    final headCenterXOut = (m['headCenterXOut'] as num?)?.toDouble();
    final expTop = (m['expectedHeadTopRatio'] as num?)?.toDouble();
    final expHeight = (m['expectedHeadHeightRatio'] as num?)?.toDouble();
    if (h == null || w == null || headTopYOut == null || chinYOut == null || expTop == null || expHeight == null) {
      headHeightFails.add('$id(数据缺失，标记条未测到)');
      headTopFails.add('$id(数据缺失)');
      centerFails.add('$id(数据缺失)');
      return;
    }
    final actualHeightRatio = (chinYOut - headTopYOut) / h;
    final actualTopRatio = headTopYOut / h;
    if ((actualHeightRatio - expHeight).abs() > 0.02) {
      headHeightFails.add('$id(实测${actualHeightRatio.toStringAsFixed(4)} 期望${expHeight.toStringAsFixed(4)})');
    }
    if ((actualTopRatio - expTop).abs() > 0.02) {
      headTopFails.add('$id(实测${actualTopRatio.toStringAsFixed(4)} 期望${expTop.toStringAsFixed(4)})');
    }
    if (headCenterXOut != null) {
      final offsetRatio = (headCenterXOut - w / 2).abs() / w;
      if (offsetRatio > 0.03) {
        centerFails.add('$id(偏移${(offsetRatio * 100).toStringAsFixed(1)}%)');
      }
    } else {
      centerFails.add('$id(数据缺失)');
    }
  });
  items.add({
    'id': '2B.3',
    'description': '头高比 (chinY-headTopY)/H 与 spec.headHeightRatio 偏差 <=0.02',
    'expected': '<=0.02',
    'actual': headHeightFails.isEmpty ? '全部达标' : '不达标: ${headHeightFails.join(', ')}',
    'pass': specs.length == 7 && headHeightFails.isEmpty,
    'manual': false,
  });
  items.add({
    'id': '2B.4',
    'description': '头顶留白比 headTopY/H 与 spec.headTopRatio 偏差 <=0.02',
    'expected': '<=0.02',
    'actual': headTopFails.isEmpty ? '全部达标' : '不达标: ${headTopFails.join(', ')}',
    'pass': specs.length == 7 && headTopFails.isEmpty,
    'manual': false,
  });
  items.add({
    'id': '2B.5',
    'description': '人脸水平居中，中心 x 与画面中心偏差 <=画宽 3%',
    'expected': '<=3%',
    'actual': centerFails.isEmpty ? '全部达标' : '不达标: ${centerFails.join(', ')}',
    'pass': specs.length == 7 && centerFails.isEmpty,
    'manual': false,
  });

  // 2B.6 / 2B.7 溢色
  final spill = (data['spill'] as Map<String, dynamic>?) ?? {};
  final greenCount = spill['greenSpillCount'];
  items.add({
    'id': '2B.6',
    'description': '换纯绿#00FF00底后，前景区 G-max(R,B)>40 的像素计数=0',
    'expected': '0',
    'actual': spill.containsKey('greenError') ? '出错: ${spill['greenError']}' : '$greenCount',
    'pass': greenCount == 0,
    'manual': false,
  });
  final magentaCount = spill['magentaSpillCount'];
  items.add({
    'id': '2B.7',
    'description': '换纯品红#FF00FF底后，前景区 min(R,B)-G>40 的像素计数=0',
    'expected': '0',
    'actual': spill.containsKey('magentaError') ? '出错: ${spill['magentaError']}' : '$magentaCount',
    'pass': magentaCount == 0,
    'manual': false,
  });

  // 2B.8 摆正
  final roll = (data['roll'] as Map<String, dynamic>?) ?? {};
  final rollFails = <String>[];
  roll.forEach((k, v) {
    final m = v as Map<String, dynamic>;
    final residual = (m['residualDeg'] as num?)?.toDouble();
    if (residual == null || residual.abs() > 1.5) {
      rollFails.add('$k(${residual ?? m['error']})');
    }
  });
  items.add({
    'id': '2B.8',
    'description': '构造±10°旋转输入，输出 rollDeg 残差 <=1.5°',
    'expected': '<=1.5°',
    'actual': roll.isEmpty ? '没有数据' : (rollFails.isEmpty ? '全部达标' : '不达标: ${rollFails.join(', ')}'),
    'pass': roll.length == 2 && rollFails.isEmpty,
    'manual': false,
  });

  // 2B.9 边界安全
  final edge = (data['edgeSafety'] as Map<String, dynamic>?) ?? {};
  final threw = edge['threw'] == true;
  final blackRatio = (edge['blackBorderRatio'] as num?)?.toDouble();
  items.add({
    'id': '2B.9',
    'description': '人脸贴近图片边缘时不抛异常、不产生黑边',
    'expected': '不抛异常；边框黑像素占比=0',
    'actual': threw
        ? '抛出异常: ${edge['error']}'
        : '未抛异常；边框黑像素占比=${blackRatio?.toStringAsFixed(4) ?? '未测到'}',
    'pass': !threw && blackRatio != null && blackRatio == 0,
    'manual': false,
  });

  return items;
}
