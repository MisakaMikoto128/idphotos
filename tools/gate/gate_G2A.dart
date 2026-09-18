// tools/gate/gate_G2A.dart
//
// G2A — 抠图引擎（ml-porting 出口）。对应 docs/ACCEPTANCE.md 2A.1-2A.8。
//
// 架构说明（重要，决定了这个文件为什么长这样）：
// onnxruntime 走 Android 平台通道，`removeBackground`/`detectFace` 摸不到真实推理结果
// 除非跑在真机/模拟器里的完整 Flutter App 进程中。所以：
// - 2A.1/2A.2（模型文件体积）是纯文件系统检查，本文件直接做。
// - 2A.3-2A.8 需要真实推理结果，本文件只负责"编排"：
//     1) 用 findMixinImportPath 动态找 ml-porting 交付的 `MattingEngineMixin` 在哪个文件
//        （不猜文件名，只认 CONTRACTS.md 锁定的类名）。找不到 = 还没交付，全部 FAIL 并说明。
//     2) 生成胶水文件 integration_test/_generated_matting_harness.dart。
//     3) adb push 黄金集 + Pictures 全量数据集到设备。
//     4) 用 --dart-define 注入设备端临时目录路径，跑
//        integration_test/matting_eval_test.dart（用 `flutter test ... -d <device>`）。
//        该文件只产出原始测量数据（JSON），不做阈值判断——判断在这里做。
//     5) adb pull 结果 JSON，逐项套 ACCEPTANCE.md 阈值。
//
// 阈值解释（ACCEPTANCE.md 原文有歧义的两处，这里记录我的解读，供主会话核对）：
// - 2A.5「边缘带误差 ≤0.12」没写"均值"两字，对照 2A.3（明确写"每一张"）和 2A.4
//   （明确写"均值"）的措辞差异，本脚本按**每一张**图片的环带 MAE 都必须 ≤0.12 来判，
//   而不是取均值。如与主会话原意不符，请在报告里指出，我会改。
// - 2A.7「非人像返回 null 或抛约定异常」：本脚本认定"非人像"= dataset.json 里
//   class ∈ {screenshot, landscape, non_image}（`multi_face`/`portrait` 视为人像，不纳入
//   此项检查，但仍纳入"进程 0 崩溃"的鲁棒性检查范围）。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'gate_common.dart';
import 'device_harness_common.dart';

const String kMattingMixinDir = 'lib/core/matting';
const String kMattingMixinName = 'MattingEngineMixin';
const String kGeneratedHarnessPath = 'integration_test/_generated_matting_harness.dart';
const String kGeneratedHarnessClass = 'GateMattingHarness';
const String kDeviceGateDir = '/data/local/tmp/muzhao_gate_tmp';

Future<void> main(List<String> args) async {
  var outPath = 'out/gate_G2A.json';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outPath = args[i + 1];
  }

  final items = <Map<String, dynamic>>[];

  final modelDir = Directory('assets/models');
  final onnxFiles = <File>[];
  if (await modelDir.exists()) {
    await for (final e in modelDir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.onnx')) onnxFiles.add(e);
    }
  }

  // 用文件名里是否含 face/det/landmark 区分人脸模型 vs 抠图模型；
  // 一个都没有、或无法明确区分时，两项都 FAIL 并写清原因，不猜。
  File? faceModel;
  File? mattingModel;
  final faceLike = onnxFiles.where((f) => RegExp(r'face|landmark|det', caseSensitive: false)
      .hasMatch(f.path.split(RegExp('[\\\\/]')).last));
  final nonFaceLike = onnxFiles.where((f) => !faceLike.contains(f));
  if (faceLike.length == 1) faceModel = faceLike.first;
  if (nonFaceLike.length == 1) mattingModel = nonFaceLike.first;

  items.add(await _modelSizeItem(
    id: '2A.1',
    desc: '抠图模型文件体积 ≤10MB',
    file: mattingModel,
    maxBytes: 10 * 1024 * 1024,
    onnxFilesFound: onnxFiles,
  ));
  items.add(await _modelSizeItem(
    id: '2A.2',
    desc: '人脸模型文件体积 ≤2MB',
    file: faceModel,
    maxBytes: 2 * 1024 * 1024,
    onnxFilesFound: onnxFiles,
  ));

  // ---- 2A.3-2A.8：需要设备端真实推理 ----
  final mixinLocation = await findMixinImportPath(kMattingMixinDir, kMattingMixinName);
  if (mixinLocation == null) {
    final waiting = _waitingItems();
    items.addAll(waiting);
  } else {
    await generateHarnessFile(
      outPath: kGeneratedHarnessPath,
      location: mixinLocation,
      className: kGeneratedHarnessClass,
      mixinName: kMattingMixinName,
      providedMethods: const {'warmUp', 'removeBackground', 'detectFace'},
    );
    items.addAll(await _runDeviceEval());
  }

  await writeGateReport(outPath: outPath, gateId: 'G2A', items: items);
  final allPass = items.every((i) => i['pass'] == true);
  stdout.writeln('G2A 结果: ${allPass ? 'PASS' : 'FAIL'}，详情见 $outPath');
  exit(allPass ? 0 : 1);
}

Future<Map<String, dynamic>> _modelSizeItem({
  required String id,
  required String desc,
  required File? file,
  required int maxBytes,
  required List<File> onnxFilesFound,
}) async {
  if (file == null) {
    return {
      'id': id,
      'description': desc,
      'expected': '<= $maxBytes 字节',
      'actual': 'assets/models/ 下找到 ${onnxFilesFound.length} 个 .onnx 文件，'
          '无法用文件名启发式（含 face/det/landmark）明确区分出这一项对应哪个文件；'
          '等待 ml-porting 交付并按命名约定放置',
      'pass': false,
      'manual': false,
    };
  }
  final size = await file.length();
  return {
    'id': id,
    'description': desc,
    'expected': '<= $maxBytes 字节',
    'actual': '${file.path}: $size 字节',
    'pass': size <= maxBytes,
    'manual': false,
  };
}

List<Map<String, dynamic>> _waitingItems() {
  const ids = ['2A.3', '2A.4', '2A.5', '2A.6', '2A.7', '2A.8'];
  const descs = [
    'alpha 与参考 IoU 每张 >=0.95',
    'alpha MAE 均值 <=0.04',
    '边缘带 MAE 每张 <=0.12',
    '512x512 耗时 p95 <=1500ms',
    '全量鲁棒性：0 崩溃，非人像 null/约定异常',
    '人脸检测 8/8 且 chinY>headTopY',
  ];
  return List.generate(ids.length, (i) {
    return {
      'id': ids[i],
      'description': descs[i],
      'expected': '见 ACCEPTANCE.md',
      'actual': '在 $kMattingMixinDir 下没有找到 `mixin $kMattingMixinName` 声明，'
          'ml-porting 尚未交付，无法跑设备端推理评测',
      'pass': false,
      'manual': false,
    };
  });
}

Future<List<Map<String, dynamic>>> _runDeviceEval() async {
  // 只认 emulator-*；拿不到就抛（不返回 null、不退回真机）。
  final deviceId = await requireEmulatorDevice(
    // 启动走 `launchMainAvd`（与 G3/G4/预检同一条路），不再用
    // `flutter emulators --launch`：那条路走默认硬件 GPU，而本机 GPU 驱动栈
    // GL/Vulkan 全废（见 `capture_shots.dart` 的说明与 `out/tmp/emu_verbose.log`），
    // 拉起来的模拟器会卡死或直接退出。旗标是与本机实测绑定的，见 gate_common。
    onMissing: () => launchMainAvd(
      consoleLogPath: 'out/GATE_G2A_emu_console.log',
      log: (String s) => stderr.writeln('[G2A emu] $s'),
    ),
  );

  final prep = await prepareDeviceGateDir(deviceId, kDeviceGateDir);
  if (!prep.success) {
    return _deviceUnavailableItems('设备端建目录/放权限失败: ${prep.tail(maxChars: 300)}');
  }

  // 推送黄金集
  final pushGolden =
      await adbPush(deviceId, 'test/golden', '$kDeviceGateDir/golden');
  if (!pushGolden.success) {
    return _deviceUnavailableItems('adb push 黄金集失败: ${pushGolden.tail(maxChars: 300)}');
  }

  // 推送数据集：读 test/dataset.json，逐个 push，生成设备端 manifest。
  final datasetFile = File('test/dataset.json');
  if (!await datasetFile.exists()) {
    return _deviceUnavailableItems('test/dataset.json 不存在（qa-batch 尚未冻结数据集）');
  }
  final dataset = jsonDecode(await datasetFile.readAsString()) as Map<String, dynamic>;
  final rawItems = (dataset['items'] as List<dynamic>).cast<Map<String, dynamic>>();
  final manifest = <Map<String, dynamic>>[];
  var pushFailCount = 0;
  for (var i = 0; i < rawItems.length; i++) {
    final srcPath = rawItems[i]['path'] as String;
    final cls = rawItems[i]['class'] as String? ?? 'unknown';
    final ext = srcPath.contains('.') ? srcPath.substring(srcPath.lastIndexOf('.')) : '';
    final deviceName = 'item_${i.toString().padLeft(3, '0')}$ext';
    final localFile = File(srcPath);
    if (!await localFile.exists()) {
      pushFailCount++;
      continue;
    }
    final push = await adbPush(deviceId, srcPath, '$kDeviceGateDir/dataset/$deviceName');
    if (!push.success) {
      pushFailCount++;
      continue;
    }
    manifest.add({'sourcePath': srcPath, 'category': cls, 'deviceName': deviceName});
  }
  final manifestJson = jsonEncode(manifest);
  final localManifest = File('out/tmp/g2a_dataset_manifest.json');
  await localManifest.parent.create(recursive: true);
  await localManifest.writeAsString(manifestJson);
  final pushManifest = await adbPush(
      deviceId, localManifest.path, '$kDeviceGateDir/dataset_manifest.json');
  if (!pushManifest.success) {
    return _deviceUnavailableItems('adb push 数据集 manifest 失败');
  }

  // 跑设备端评测：必须用 flutter drive（不是 flutter test），结果通过
  // binding.reportData 走 VM service 通道带回 host，落到
  // build/integration_response_data.json——不走 adb push/pull，彻底绕开
  // Android scoped storage / SELinux 写权限问题（踩坑记录见 docs/PITFALLS.md）。
  const responseDataPath = 'build/integration_response_data.json';
  final responseFile = File(responseDataPath);
  if (await responseFile.exists()) await responseFile.delete();

  final driveRun = await runProcess(
    'flutter',
    [
      'drive',
      '--driver=test_driver/integration_test_driver.dart',
      '--target=integration_test/matting_eval_test.dart',
      '-d',
      deviceId,
      '--dart-define=GATE_TMP_DIR=$kDeviceGateDir',
    ],
    timeout: const Duration(minutes: 25),
  );
  if (!driveRun.success || !await responseFile.exists()) {
    return _deviceUnavailableItems(
        '设备端评测（flutter drive matting_eval_test.dart）失败/超时或没有产出 '
        '$responseDataPath，可能是 ml-porting 的 mixin 编译不过，或推理过程崩溃/无响应。'
        '退出码=${driveRun.exitCode} timedOut=${driveRun.timedOut}\n${driveRun.tail(maxChars: 1500)}');
  }

  final data = jsonDecode(await responseFile.readAsString()) as Map<String, dynamic>;
  return _applyThresholds(data, pushFailCount: pushFailCount, rawDatasetCount: rawItems.length);
}

List<Map<String, dynamic>> _deviceUnavailableItems(String reason) {
  const ids = ['2A.3', '2A.4', '2A.5', '2A.6', '2A.7', '2A.8'];
  return ids
      .map((id) => {
            'id': id,
            'description': '需要设备端推理结果',
            'expected': '见 ACCEPTANCE.md',
            'actual': reason,
            'pass': false,
            'manual': false,
          })
      .toList();
}

List<Map<String, dynamic>> _applyThresholds(
  Map<String, dynamic> data, {
  required int pushFailCount,
  required int rawDatasetCount,
}) {
  final items = <Map<String, dynamic>>[];
  final golden = (data['golden'] as Map<String, dynamic>?) ?? {};

  // 2A.3 IoU 每张 >=0.95
  final iouFails = <String>[];
  golden.forEach((k, v) {
    final m = v as Map<String, dynamic>;
    final iou = (m['iou'] as num?)?.toDouble();
    if (iou == null || iou < 0.95) {
      iouFails.add('$k(iou=${iou?.toStringAsFixed(4) ?? m['error']})');
    }
  });
  items.add({
    'id': '2A.3',
    'description': 'alpha 与参考 IoU（二值化@128），每一张 >=0.95',
    'expected': '每张 >=0.95',
    'actual': golden.isEmpty ? '没有黄金集结果' : '不达标: ${iouFails.isEmpty ? '无' : iouFails.join(', ')}',
    'pass': golden.isNotEmpty && iouFails.isEmpty,
    'manual': false,
  });

  // 2A.4 MAE 均值 <=0.04
  final maes = golden.values
      .map((v) => ((v as Map<String, dynamic>)['mae'] as num?)?.toDouble())
      .whereType<double>()
      .toList();
  final meanMae = maes.isEmpty ? null : maes.reduce((a, b) => a + b) / maes.length;
  items.add({
    'id': '2A.4',
    'description': 'alpha 平均绝对误差，黄金集均值 <=0.04',
    'expected': '<=0.04',
    'actual': meanMae == null ? '没有可用样本' : meanMae.toStringAsFixed(4),
    'pass': meanMae != null && meanMae <= 0.04,
    'manual': false,
  });

  // 2A.5 边缘带 MAE 每张 <=0.12（见文件头注释关于"每张 vs 均值"的解读）
  final edgeFails = <String>[];
  golden.forEach((k, v) {
    final m = v as Map<String, dynamic>;
    final e = (m['edgeMae'] as num?)?.toDouble();
    if (e == null || e > 0.12) {
      edgeFails.add('$k(edgeMae=${e?.toStringAsFixed(4) ?? m['error']})');
    }
  });
  items.add({
    'id': '2A.5',
    'description': '边缘带误差（参考边界±5px环带内 MAE），每张 <=0.12',
    'expected': '每张 <=0.12',
    'actual': golden.isEmpty ? '没有黄金集结果' : '不达标: ${edgeFails.isEmpty ? '无' : edgeFails.join(', ')}',
    'pass': golden.isNotEmpty && edgeFails.isEmpty,
    'manual': false,
  });

  // 2A.6 512x512 p95 <=1500ms
  final samples = (data['timing512SamplesMs'] as List<dynamic>?)?.cast<num>() ?? [];
  double? p95;
  if (samples.isNotEmpty) {
    final sorted = samples.map((e) => e.toDouble()).toList()..sort();
    final idx = math.min(sorted.length - 1, (0.95 * sorted.length).ceil() - 1);
    p95 = sorted[math.max(0, idx)];
  }
  items.add({
    'id': '2A.6',
    'description': '单张耗时 512x512 p95 <=1500ms',
    'expected': '<=1500ms',
    'actual': p95 == null ? '没有采样' : '${p95.toStringAsFixed(1)}ms（样本数=${samples.length}）',
    'pass': p95 != null && p95 <= 1500,
    'manual': false,
  });

  // 2A.7 全量鲁棒性
  final datasetResults = (data['dataset'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
  final nonPortraitViolations = <String>[];
  for (final r in datasetResults) {
    final cls = r['category'] as String?;
    if (cls == 'screenshot' || cls == 'landscape' || cls == 'non_image') {
      final faceOutcome = r['detectFaceOutcome'] as String?;
      final isNullOrException =
          faceOutcome == 'null' || (faceOutcome?.startsWith('exception:') ?? false);
      if (!isNullOrException) {
        nonPortraitViolations.add('${r['sourcePath']}(class=$cls, detectFace=$faceOutcome)');
      }
    }
  }
  final skippedCount = datasetResults.where((r) => r.containsKey('skipped')).length;
  final ranCount = datasetResults.length - skippedCount;
  final processErrors = (data['errors'] as List<dynamic>?) ?? [];
  final crashSuspected = ranCount == 0 && rawDatasetCount > 0;
  items.add({
    'id': '2A.7',
    'description': '全量鲁棒性：进程 0 崩溃，非人像(screenshot/landscape/non_image) 返回 null 或抛约定异常',
    'expected': '0 崩溃；非人像违规数=0',
    'actual': '数据集共 $rawDatasetCount 项，host push 失败 $pushFailCount 项，'
        '设备端实际处理 $ranCount 项（跳过 $skippedCount）；'
        '非人像违规: ${nonPortraitViolations.isEmpty ? '无' : nonPortraitViolations.join('; ')}；'
        '设备端流程性错误: ${processErrors.isEmpty ? '无' : processErrors.join('; ')}'
        '${crashSuspected ? '；警告：设备端一条都没跑完，怀疑进程崩溃或整体超时' : ''}',
    'pass': !crashSuspected && nonPortraitViolations.isEmpty && pushFailCount == 0,
    'manual': false,
  });

  // 2A.8 人脸检测 8/8 且 chinY>headTopY
  final faceViolations = <String>[];
  golden.forEach((k, v) {
    final m = v as Map<String, dynamic>;
    final detected = m['faceDetected'] == true;
    final chinY = (m['chinY'] as num?)?.toDouble();
    final headTopY = (m['headTopY'] as num?)?.toDouble();
    if (!detected) {
      faceViolations.add('$k(未检出)');
    } else if (chinY == null || headTopY == null || !(chinY > headTopY)) {
      faceViolations.add('$k(chinY=$chinY headTopY=$headTopY，chinY 应大于 headTopY)');
    }
  });
  items.add({
    'id': '2A.8',
    'description': '人脸检测召回：黄金集 8/8 检出，chinY>headTopY 恒成立',
    'expected': '8/8 且 chinY>headTopY',
    'actual': golden.isEmpty
        ? '没有黄金集结果'
        : '检出 ${golden.length - faceViolations.where((v) => v.contains('未检出')).length}/${golden.length}；'
            '违规: ${faceViolations.isEmpty ? '无' : faceViolations.join(', ')}',
    'pass': golden.length == 8 && faceViolations.isEmpty,
    'manual': false,
  });

  return items;
}
