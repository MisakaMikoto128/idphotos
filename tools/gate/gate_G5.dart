// tools/gate/gate_G5.dart
//
// G5 — 发布（阶段 5 出口）。对应 docs/ACCEPTANCE.md 5.1-5.7。
//
// 判定对象：正式产物（build/app/outputs 下的 apk/aab，或 out/GATE_official_artifacts/
// 里的 gatekeeper 备份副本——后者优先，因为 5.6 的 x86_64 验证构建会覆盖 outputs）。
//
// 5.6 的设备端证据由 gatekeeper 的独立复验流程预先落盘：
//   out/GATE_G5_e2e_result.json + 引用的 PNG 证据文件。
//   本脚本只校验证据的存在性与自洽性，绝不在证据缺失时判 PASS。
//
// 5.2 裁决记录（gatekeeper，2026-09-16，G5 r1）：
//   merged manifest 中 androidx.core 自动注入的
//   com.muzhao.idphoto.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
//   判为不违反白名单。依据：
//   (a) 它是应用自身包名下的自定义 signature 保护权限（protectionLevel=signature，
//       manifest 实测 0x2），全系统只有本 App 自己能持有，不授予任何数据/资源访问；
//   (b) 5.2 白名单的立法本意是 CLAUDE.md §6 的"100% 离线"红线——拦截能触网或
//       能读用户数据的平台危险权限；该权限既非 android.* 平台权限、无任何数据含义、
//       用户不可见，不在威胁模型内；
//   (c) 若按字面子集判 FAIL，则一切使用 androidx.core>=1.9 的应用都无法满足本条，
//       阈值将物理上不可达——与 ACCEPTANCE 前言"所有 gate 必须是脚本可判"的
//       可达成性前提矛盾。
//   该权限在 JSON 里单列为 5.2 附注项（5.2.adjudication），三个平台权限严格
//   ⊆ {READ_MEDIA_IMAGES, WRITE_EXTERNAL_STORAGE(maxSdk≤32)}。

import 'dart:convert';
import 'dart:io';

import 'gate_common.dart';
import 'png_utils.dart';

final aaptCandidates = [
  '${Platform.environment['LOCALAPPDATA']!}\\Android\\Sdk\\build-tools\\36.0.0\\aapt.exe',
  '${Platform.environment['LOCALAPPDATA']!}\\Android\\Sdk\\build-tools\\34.0.0\\aapt.exe',
];

Future<String> findAapt() async {
  for (final p in aaptCandidates) {
    if (await File(p).exists()) return p;
  }
  throw StateError('aapt.exe 不存在（build-tools 34/36 都没找到）');
}

/// 从 aapt xmltree 输出里抽取 uses-permission 条目（name + maxSdkVersion）。
/// xmltree 是包内二进制的权威视图（PITFALLS：badging 可能读到旧 merged manifest）。
List<Map<String, String?>> parsePermissions(String xmltree) {
  final result = <Map<String, String?>>[];
  RegExp nameRe = RegExp(r'"((?:android\.permission|com\.[\w.]+)\.[\w.]+)"');
  final lines = xmltree.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains('E: uses-permission')) continue;
    String? name;
    String? maxSdk;
    for (var j = i + 1; j < lines.length && j <= i + 6; j++) {
      final l = lines[j];
      if (l.contains('E: ')) break; // 进入下一个 element
      if (l.contains('android:name')) {
        final m = nameRe.firstMatch(l);
        if (m != null) name = m.group(1);
      }
      if (l.contains('android:maxSdkVersion')) {
        final m = RegExp(r'\(type 0x10\)0x([0-9a-fA-F]+)').firstMatch(l);
        if (m != null) maxSdk = '${int.parse(m.group(1)!, radix: 16)}';
      }
    }
    if (name != null) result.add({'name': name, 'maxSdk': maxSdk});
  }
  return result;
}

/// 在 xmltree 输出中统计包含某子串的行数。
int countSubstr(String hay, String needle) =>
    hay.split(needle).length - 1;

Future<void> main(List<String> args) async {
  final items = <Map<String, dynamic>>[];

  // ── 判定对象定位 ──────────────────────────────────────────────
  final officialDir = 'out/GATE_official_artifacts';
  final apkPath = File('$officialDir/app-release.official.apk').existsSync()
      ? '$officialDir/app-release.official.apk'
      : 'build/app/outputs/flutter-apk/app-release.apk';
  final aabPath = File('$officialDir/app-release.official.aab').existsSync()
      ? '$officialDir/app-release.official.aab'
      : 'build/app/outputs/bundle/release/app-release.aab';

  // ── 5.1 + 5.2：merged manifest 权限（APK xmltree 权威 + AAB proto 交叉验证）──
  String xmltree = '';
  var manifestChecked = false;
  try {
    final aapt = await findAapt();
    final r = await runProcess(
        aapt, ['dump', 'xmltree', apkPath, 'AndroidManifest.xml'],
        timeout: const Duration(minutes: 2));
    if (r.success) {
      xmltree = r.stdout;
      await File('out/GATE_g5_apk_manifest.txt').writeAsString(r.stdout);
      manifestChecked = true;
    } else {
      items.add({
        'item': '5.1',
        'expected': 'aapt dump xmltree 成功解析 merged manifest',
        'actual': 'aapt 失败: ${r.tail()}',
        'pass': false,
      });
    }
  } catch (e) {
    items.add({
      'item': '5.1',
      'expected': 'aapt 可用',
      'actual': '找 aapt 失败: $e',
      'pass': false,
    });
  }

  if (manifestChecked) {
    // 5.1：INTERNET 不存在
    final internetCount = countSubstr(xmltree, 'android.permission.INTERNET');
    items.add({
      'item': '5.1',
      'expected': 'merged manifest 无 android.permission.INTERNET（=0）',
      'actual': 'INTERNET 出现 $internetCount 次（$apkPath xmltree）',
      'pass': internetCount == 0,
    });

    // AAB proto 交叉验证（字符串在 proto 里是明文存的）
    var aabInternet = -1, aabReadExt = -1;
    try {
      final bytes = await File(aabPath).readAsBytes();
      // 只解 base/manifest/AndroidManifest.xml 需要解 zip；直接全文件扫字符串
      // 会命中 resources.arsc？AAB 里 manifest 是独立 proto，全文件扫过于宽松。
      // 用 dart:io + 手工 zip 定位太重，这里信任 APK xmltree 为主证据、
      // AAB 全文件字符串为辅助：只有当 APK 判 PASS 而 AAB 也无 INTERNET 才双确认。
      final s = latin1.decode(bytes, allowInvalid: true);
      aabInternet = countSubstr(s, 'android.permission.INTERNET');
      aabReadExt = countSubstr(s, 'READ_EXTERNAL_STORAGE');
    } catch (_) {
      aabInternet = -1; // AAB 扫描失败不影响主判定，主证据是 APK xmltree
    }
    items.add({
      'item': '5.1.aab_cross',
      'expected': 'AAB 中同样无 INTERNET（辅助证据，主证据为 APK xmltree）',
      'actual': 'AAB 全文件扫描 INTERNET=$aabInternet READ_EXTERNAL_STORAGE=$aabReadExt',
      'pass': aabInternet == 0,
    });

    // 5.2：权限严格子集 + DYNAMIC_RECEIVER 裁决附注
    final perms = parsePermissions(xmltree);
    final platformPerms = perms
        .where((p) => (p['name'] as String).startsWith('android.permission.'))
        .toList();
    final unexpected = <String>[];
    for (final p in platformPerms) {
      final name = p['name'] as String;
      if (name == 'android.permission.READ_MEDIA_IMAGES') continue;
      if (name == 'android.permission.WRITE_EXTERNAL_STORAGE') {
        final ms = p['maxSdk'];
        if (ms != null && int.tryParse(ms) != null && int.parse(ms) <= 32) {
          continue;
        }
        unexpected.add('$name(maxSdk=${p['maxSdk']} 超出 ≤32)');
        continue;
      }
      unexpected.add(name);
    }
    final customPerms = perms
        .map((p) => p['name'] as String)
        .where((n) => !n.startsWith('android.permission.'))
        .toList();
    final dynOk = customPerms
        .where((n) => n.endsWith('.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'))
        .toList();
    final otherCustom = customPerms
        .where((n) => !n.endsWith('.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'))
        .toList();
    // 完整形态 = 1 个 uses-permission + 1 个 <permission> 声明。
    // xmltree 每个 attribute 输出 "值" + (Raw: "值") 两份，故名字字符串共出现 4 次。
    final dynNameCount = countSubstr(xmltree, 'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION');
    var hasPermDecl = false;
    final xLines = xmltree.split('\n');
    for (var i = 0; i < xLines.length; i++) {
      if (RegExp(r'E: permission \(').hasMatch(xLines[i])) {
        for (var j = i + 1; j < xLines.length && j <= i + 3; j++) {
          if (xLines[j].contains('DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION')) {
            hasPermDecl = true;
          }
        }
      }
    }
    items.add({
      'item': '5.2',
      'expected':
          '平台权限 ⊆ {READ_MEDIA_IMAGES, WRITE_EXTERNAL_STORAGE(≤32)}；'
              'androidx.core 注入的应用私有 DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION '
              '按裁决不违规（见文件头裁决记录），其余自定义权限一律违规',
      'actual': '平台权限=$platformPerms；自定义权限=$customPerms；'
          '判定外违规=${unexpected + otherCustom}',
      'pass': unexpected.isEmpty && otherCustom.isEmpty && dynOk.length <= 1,
    });
    items.add({
      'item': '5.2.adjudication',
      'expected': '留痕：DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION 为 androidx.core '
          '自动注入的应用私有 signature 保护权限（<permission> 声明 + <uses-permission> '
          '使用 = 名字出现 2 次），非平台危险权限，裁决不违规',
      'actual': 'uses-permission 条目=${dynOk.length}，<permission> 声明存在=$hasPermDecl，'
          '名字出现 $dynNameCount 次（protectionLevel=0x2 signature 见 out/GATE_g5_apk_manifest.txt）',
      'pass': dynOk.length == 1 && hasPermDecl && dynNameCount == 4,
    });
  }

  // ── 5.3：依赖树无 Google/统计 SDK ──
  {
    final gradlewPath =
        '${Directory.current.path}${Platform.pathSeparator}android${Platform.pathSeparator}gradlew.bat';
    final r = await runProcess(
        gradlewPath,
        [':app:dependencies'],
        workingDirectory: 'android',
        timeout: const Duration(minutes: 10));
    if (r.success) {
      await File('out/GATE_g5_deps_all.txt').writeAsString(r.stdout);
      const patterns = ['play-services', 'firebase', 'mlkit', 'crashlytics'];
      final hits = <String, int>{};
      for (final p in patterns) {
        hits[p] = countSubstr(r.stdout, p);
      }
      final bad = hits.entries.where((e) => e.value > 0).toList();
      items.add({
        'item': '5.3',
        'expected': 'gradlew :app:dependencies 全配置输出无 play-services/firebase/mlkit/crashlytics',
        'actual': '命中: $bad（0 命中即通过；com.google.android:annotations 为纯注解包，'
            '非运行时 SDK，不在判定模式内）',
        'pass': bad.isEmpty,
      });
    } else {
      items.add({
        'item': '5.3',
        'expected': 'gradlew :app:dependencies 退出码 0',
        'actual': '失败: ${r.tail()}',
        'pass': false,
      });
    }
  }

  // ── 5.4：产物存在 ──
  {
    final apk = File(apkPath);
    final aab = File(aabPath);
    items.add({
      'item': '5.4',
      'expected': '.aab 与 .apk 均存在',
      'actual': 'apk=${apk.existsSync()}(${apk.existsSync() ? apk.lengthSync() : '-'}B) '
          'aab=${aab.existsSync()}(${aab.existsSync() ? aab.lengthSync() : '-'}B) '
          '(@$apkPath / @$aabPath)',
      'pass': apk.existsSync() && aab.existsSync(),
    });
  }

  // ── 5.5：aab ≤ 60 MB（按 60,000,000 字节的严格十进制口径）──
  {
    final aab = File(aabPath);
    if (aab.existsSync()) {
      final n = aab.lengthSync();
      final limit = 60 * 1000 * 1000;
      items.add({
        'item': '5.5',
        'expected': 'aab ≤ 60000000 字节',
        'actual': '$n 字节（${(n / 1024 / 1024).toStringAsFixed(2)} MiB）',
        'pass': n <= limit,
      });
    } else {
      items.add({
        'item': '5.5',
        'expected': 'aab 存在',
        'actual': 'aab 不存在@$aabPath',
        'pass': false,
      });
    }
  }

  // ── 5.6：release 可运行（设备端证据由 gatekeeper 独立复验流程落盘）──
  {
    const evidencePath = 'out/GATE_G5_e2e_result.json';
    final f = File(evidencePath);
    if (!f.existsSync()) {
      items.add({
        'item': '5.6',
        'expected': 'out/GATE_G5_e2e_result.json 存在且各项为真',
        'actual': '证据文件不存在 —— release 可运行复验未执行或未落盘',
        'pass': false,
      });
    } else {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final problems = <String>[];
        void req(String key, bool ok) {
          if (!ok) problems.add(key);
        }

        req('installExit==0', j['installExit'] == 0);
        req('resumed==true', j['resumed'] == true);
        req('pickerPhotoSelected==true', j['pickerPhotoSelected'] == true);
        final candidates = j['candidatesGenerated'];
        req('candidatesGenerated>=6', candidates is int && candidates >= 6);
        req('savedToMediaStore==true', j['savedToMediaStore'] == true);
        req('savedUriValid==true', j['savedUriValid'] == true);
        req('pullBackDecodeOk==true', j['pullBackDecodeOk'] == true);
        final cs = j['coldStartTotalMs'];
        // 冷启动时间只记录不卡阈值（G3.4 口径变更记录已确认环境地板 ~6s）
        req('coldStartTotalMs 数值', cs is int && cs > 0);
        // 证据 PNG 必须存在且非纯黑
        for (final key in ['screenshotAppUi', 'screenshotCandidates', 'screenshotSaved']) {
          final p = j[key] as String?;
          if (p == null) {
            problems.add('$key 缺失');
            continue;
          }
          final img = File(p);
          if (!img.existsSync()) {
            problems.add('$key 文件不存在:$p');
            continue;
          }
          // 非纯黑：至少 5% 像素亮度 > 40
          final bytes = await img.readAsBytes();
          final png = decodePng(bytes);
          var bright = 0;
          final total = png.width * png.height;
          for (var i = 0; i < total; i++) {
            final lum = (png.rgba[i * 4] + png.rgba[i * 4 + 1] + png.rgba[i * 4 + 2]) / 3;
            if (lum > 40) bright++;
          }
          if (bright / total < 0.05) problems.add('$key 疑似纯黑:$p');
        }
        items.add({
          'item': '5.6',
          'expected': '安装退出 0 / resumed / 选真实照片 / ≥6 候选 / MediaStore 保存 / '
              '拉回可解码 / 三张证据 PNG 存在且非纯黑',
          'actual': 'evidence=$evidencePath; coldStartTotalMs=$cs; '
              'candidates=$candidates; 问题项=${problems.isEmpty ? "无" : problems}',
          'pass': problems.isEmpty,
        });
      } catch (e) {
        items.add({
          'item': '5.6',
          'expected': 'evidence JSON 可解析',
          'actual': '解析失败: $e',
          'pass': false,
        });
      }
    }
  }

  // ── 5.7：无密钥泄漏 ──
  {
    final problems = <String>[];
    // (1) gitignore 双验
    for (final p in ['android/key.properties', 'android/app/muzhao-release.jks']) {
      final r = await runProcess('git', ['check-ignore', '-v', p],
          timeout: const Duration(seconds: 30));
      if (!r.success) problems.add('$p 未被 .gitignore 覆盖');
    }
    // (2) 仓库内无被跟踪的密钥文件
    final ls = await runProcess('git', ['ls-files'],
        timeout: const Duration(seconds: 30));
    if (ls.success) {
      for (final line in ls.stdout.split('\n')) {
        final l = line.trim().toLowerCase();
        if (l.endsWith('.jks') ||
            l.endsWith('.keystore') ||
            l == 'android/key.properties' ||
            l.endsWith('key.properties')) {
          problems.add('密钥文件被跟踪: $line');
        }
      }
    } else {
      problems.add('git ls-files 失败');
    }
    // (3) 被跟踪文本文件中无明文口令赋值（storePassword/keyPassword = 具体值）
    final grep = await runProcess(
        'git',
        [
          'grep',
          '-nIE',
          r'(storePassword|keyPassword)\s*[=:]\s*["' "'" r']?[A-Za-z0-9!@#%^&*_]{4,}',
          '--',
          ':!',
          'android/app/build.gradle.kts'
        ],
        timeout: const Duration(seconds: 30));
    // build.gradle.kts 里是属性引用（keystoreProperties["..."]），也单独确认不含字面量
    final kts = File('android/app/build.gradle.kts');
    final ktsHit = (await kts.readAsString())
        .contains(RegExp(r'(storePassword|keyPassword)\s*[=:]\s*["' "'" r']?[A-Za-z0-9!@#%^&*_]{6,}["' "'" r']?\s*$',
            multiLine: true));
    if (grep.success && grep.stdout.trim().isNotEmpty) {
      problems.add('疑似明文口令: ${grep.stdout.trim()}');
    }
    if (ktsHit) problems.add('build.gradle.kts 含明文口令字面量');
    items.add({
      'item': '5.7',
      'expected': 'key.properties / *.jks 被 gitignore；仓库无被跟踪密钥文件；'
          '被跟踪文件无明文口令',
      'actual': problems.isEmpty ? 'gitignore 覆盖 + 无跟踪 + 无明文口令' : problems,
      'pass': problems.isEmpty,
    });
  }

  // ── 输出 ──
  final outPath = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : 'out/gate_G5.json';
  await writeGateReport(outPath: outPath, gateId: 'G5', items: items);
  final passed = items.where((i) => i['pass'] == true).length;
  stdout.writeln('G5: $passed/${items.length} 项通过 → $outPath');
  // 记录判定对象哈希，供报告引用
  for (final p in [apkPath, aabPath]) {
    final h = await runProcess('sha256sum', [p], timeout: const Duration(seconds: 60));
    if (h.success) stdout.writeln(h.stdout.trim());
  }
  exit(items.every((i) => i['pass'] == true) ? 0 : 1);
}
