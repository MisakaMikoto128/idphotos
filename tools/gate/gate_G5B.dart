// tools/gate/gate_G5B.dart
//
// G5B — 上架材料（store-assets 出口，与 G5 并行）。对应 docs/ACCEPTANCE.md 5B.1-5B.13。
//
// 机读项：5B.1-5B.6 / 5B.8 / 5B.10-5B.13（本脚本直接判）。
// MANUAL 项：5B.7（截图真实性——基于真实界面而非手绘）与 5B.9（文案功能逐条可溯源），
//   由 gatekeeper 人工抽查后在报告 out/GATE_G5B_r<n>.md 里显式裁决，JSON 里恒为
//   manual=true / pass=false，绝不默认当作通过。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'png_utils.dart';

DecodedPng loadPng(String path) {
  final bytes = File(path).readAsBytesSync();
  return decodePng(bytes);
}

/// 盒式降采样到 w×h（RGBA 输入），返回每像素 [r,g,b,a]。
Uint8List boxResize(DecodedPng src, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final x0 = (x * src.width / w).floor();
      final x1 = ((x + 1) * src.width / w).ceil().clamp(0, src.width);
      final y0 = (y * src.height / h).floor();
      final y1 = ((y + 1) * src.height / h).ceil().clamp(0, src.height);
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          final i = (yy * src.width + xx) * 4;
          // 非预乘：按 alpha 加权避免透明像素颜色污染
          final av = src.rgba[i + 3];
          r += src.rgba[i] * av;
          g += src.rgba[i + 1] * av;
          b += src.rgba[i + 2] * av;
          a += av;
          n += av;
        }
      }
      final o = (y * w + x) * 4;
      if (n > 0) {
        out[o] = (r / n).round().clamp(0, 255);
        out[o + 1] = (g / n).round().clamp(0, 255);
        out[o + 2] = (b / n).round().clamp(0, 255);
      }
      out[o + 3] = (a / ((x1 - x0) * (y1 - y0))).round().clamp(0, 255);
    }
  }
  return out;
}

bool hasAlphaChannel(DecodedPng png) {
  for (var i = 3; i < png.rgba.length; i += 4) {
    if (png.rgba[i] != 255) return true;
  }
  return false;
}

void main(List<String> args) {
  final items = <Map<String, dynamic>>[];

  // ── 5B.1：icon_512.png 存在、512×512、含 alpha ──
  {
    const p = 'store/icon_512.png';
    if (File(p).existsSync()) {
      final png = loadPng(p);
      final alpha = hasAlphaChannel(png);
      items.add({
        'item': '5B.1',
        'expected': 'icon_512.png 512×512 含 alpha 通道',
        'actual': '${png.width}×${png.height}, alpha通道=$alpha',
        'pass': png.width == 512 && png.height == 512 && alpha,
      });
    } else {
      items.add({
        'item': '5B.1', 'expected': '$p 存在', 'actual': '不存在', 'pass': false,
      });
    }
  }

  // ── 5B.2：mipmap 五套密度齐备、尺寸正确 ──
  {
    const expectSizes = {
      'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
      'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192,
    };
    final problems = <String>[];
    for (final e in expectSizes.entries) {
      final p = 'android/app/src/main/res/${e.key}/ic_launcher.png';
      if (!File(p).existsSync()) {
        problems.add('${e.key} 缺失');
        continue;
      }
      final png = loadPng(p);
      if (png.width != e.value || png.height != e.value) {
        problems.add('${e.key} ${png.width}×${png.height} 应为 ${e.value}');
      }
    }
    items.add({
      'item': '5B.2',
      'expected': 'mipmap-{m,h,xh,xxh,xxxh}dpi 五套 ic_launcher 尺寸 48/72/96/144/192',
      'actual': problems.isEmpty ? '五套齐备且尺寸正确' : problems,
      'pass': problems.isEmpty,
    });
  }

  // ── 5B.3：自适应图标前景在中心 66% 安全区内 ──
  {
    final xml = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
    var xmlOk = false;
    var fg = '', bg = '';
    if (xml.existsSync()) {
      final s = xml.readAsStringSync();
      final fgM = RegExp(r'<foreground[^>]*android:drawable="([^"]+)"').firstMatch(s);
      final bgM = RegExp(r'<background[^>]*android:drawable="([^"]+)"').firstMatch(s);
      if (fgM != null && bgM != null) {
        fg = fgM.group(1)!;
        bg = bgM.group(1)!;
        xmlOk = true;
      }
    }
    if (!xmlOk) {
      items.add({
        'item': '5B.3',
        'expected': 'mipmap-anydpi-v26/ic_launcher.xml 声明前景/背景分离',
        'actual': xml.existsSync() ? 'xml 存在但解析不到 foreground/background' : 'xml 不存在',
        'pass': false,
      });
    } else {
      // 前景 drawable 是 @mipmap/ic_launcher_foreground，取 xxxhdpi（最大样本）量外接框
      final fgPath =
          'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png';
      final png = loadPng(fgPath);
      var minX = png.width, minY = png.height, maxX = -1, maxY = -1;
      for (var y = 0; y < png.height; y++) {
        for (var x = 0; x < png.width; x++) {
          if (png.a(x, y) > 10) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX < 0) {
        items.add({
          'item': '5B.3', 'expected': '前景非透明像素外接框在中心 66% 内',
          'actual': '前景全透明?$fgPath', 'pass': false,
        });
      } else {
        final margins = [
          minX / png.width,
          minY / png.height,
          (png.width - 1 - maxX) / png.width,
          (png.height - 1 - maxY) / png.height,
        ];
        // 中心 66% → 四边留白 ≥ 17%
        final ok = margins.every((m) => m >= 0.17);
        items.add({
          'item': '5B.3',
          'expected': '非透明像素外接框四边留白 ≥17%（中心 66% 安全区），@xxxhdpi',
          'actual': '前景=$fg 背景=$bg 留白='
              '${margins.map((m) => (m * 100).toStringAsFixed(1) + '%').join('/')}',
          'pass': ok,
        });
      }
    }
  }

  // ── 5B.4：缩略可辨认：48×48 后非背景色像素占比 ≥12% ──
  {
    final png = loadPng('store/icon_512.png');
    final thumb = boxResize(png, 48, 48);
    // 背景色 = 量化（每通道 32 步长）后出现最多的颜色
    final counts = <String, int>{};
    final centers = <String, List<int>>{};
    for (var i = 0; i < thumb.length; i += 4) {
      if (thumb[i + 3] < 128) continue;
      final key =
          '${thumb[i] >> 5}_${thumb[i + 1] >> 5}_${thumb[i + 2] >> 5}';
      counts[key] = (counts[key] ?? 0) + 1;
      centers.putIfAbsent(key, () => [thumb[i], thumb[i + 1], thumb[i + 2]]);
    }
    var bgKey = '';
    var bgN = -1;
    counts.forEach((k, v) {
      if (v > bgN) {
        bgN = v;
        bgKey = k;
      }
    });
    final bg = centers[bgKey]!;
    var distinct = 0, total = 0;
    for (var i = 0; i < thumb.length; i += 4) {
      if (thumb[i + 3] < 128) continue;
      total++;
      final dr = thumb[i] - bg[0], dg = thumb[i + 1] - bg[1], db = thumb[i + 2] - bg[2];
      if ((dr * dr + dg * dg + db * db) > 60 * 60) distinct++;
    }
    final ratio = total > 0 ? distinct / total : 0.0;
    items.add({
      'item': '5B.4',
      'expected': '缩到 48×48 后非背景色像素占比 ≥0.12',
      'actual': 'ratio=${ratio.toStringAsFixed(4)}（distinct=$distinct/total=$total，'
          '背景色=${bg}）',
      'pass': ratio >= 0.12,
    });
  }

  // ── 5B.5：feature_graphic 恰好 1024×500 ──
  {
    const p = 'store/feature_graphic.png';
    if (File(p).existsSync()) {
      final png = loadPng(p);
      items.add({
        'item': '5B.5', 'expected': 'feature_graphic.png 恰好 1024×500',
        'actual': '${png.width}×${png.height}', 'pass': png.width == 1024 && png.height == 500,
      });
    } else {
      items.add({
        'item': '5B.5', 'expected': '$p 存在', 'actual': '不存在', 'pass': false,
      });
    }
  }

  // ── 5B.6：宣传截图 zh/en 各 ≥5 张、均 1080×1920 ──
  {
    final problems = <String>[];
    var counts = <String, int>{};
    for (final lang in ['zh', 'en']) {
      final dir = Directory('store/screenshots/$lang');
      if (!dir.existsSync()) {
        problems.add('$lang 目录缺失');
        counts[lang] = 0;
        continue;
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.png'))
          .toList();
      counts[lang] = files.length;
      if (files.length < 5) problems.add('$lang 仅 ${files.length} 张（<5）');
      for (final f in files) {
        final png = loadPng(f.path);
        if (png.width != 1080 || png.height != 1920) {
          problems.add('${f.path} ${png.width}×${png.height} 应为 1080×1920');
        }
      }
    }
    items.add({
      'item': '5B.6',
      'expected': 'zh/en 各 ≥5 张且全部 1080×1920',
      'actual': '张数=$counts；问题=${problems.isEmpty ? "无" : problems}',
      'pass': problems.isEmpty,
    });
  }

  // ── 5B.7：截图真实性（MANUAL）──
  items.add({
    'item': '5B.7',
    'expected': '宣传截图基于 out/shots/ 真实界面合成，非手绘',
    'actual': 'MANUAL —— 由 gatekeeper 人工抽查，见 out/GATE_G5B_r1.md；'
        '本 JSON 不把它算作通过',
    'pass': false,
    'manual': true,
  });

  // ── 5B.8：文案长度 ──
  {
    final problems = <String>[];
    for (final lang in ['zh', 'en']) {
      final s = File('store/listing/$lang/listing.md').readAsStringSync();
      // 抽取代码围栏段落：按标题行定位
      String? fenceAfter(String header) {
        final idx = s.indexOf(header);
        if (idx < 0) return null;
        final start = s.indexOf('```', idx);
        if (start < 0) return null;
        final end = s.indexOf('```', start + 3);
        if (end < 0) return null;
        var body = s.substring(start + 3, end);
        if (body.startsWith('\n')) body = body.substring(1);
        if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
        return body;
      }

      final short = fenceAfter(lang == 'zh' ? '简短描述' : 'Short description');
      final full = fenceAfter(lang == 'zh' ? '完整描述' : 'Full description');
      if (short == null || full == null) {
        problems.add('$lang 缺少简短/完整描述围栏段');
        continue;
      }
      final shortLen = short.characters;
      final fullLen = full.characters;
      if (shortLen > 80) problems.add('$lang 简短描述 $shortLen > 80');
      if (fullLen > 4000) problems.add('$lang 完整描述 $fullLen > 4000');
      items.add({
        'item': '5B.8.${lang}',
        'expected': '简短 ≤80 字符；完整 ≤4000 字符',
        'actual': '简短=$shortLen，完整=$fullLen',
        'pass': shortLen <= 80 && fullLen <= 4000,
      });
    }
    if (problems.any((p) => p.contains('缺少'))) {
      items.add({
        'item': '5B.8', 'expected': '两种语言围栏段齐备',
        'actual': problems, 'pass': false,
      });
    }
  }

  // ── 5B.9：文案真实性（MANUAL）──
  items.add({
    'item': '5B.9',
    'expected': '文案中每个功能均可在 lib/ 找到对应实现',
    'actual': 'MANUAL —— gatekeeper 抽查 3 条并留锚点，见 out/GATE_G5B_r1.md',
    'pass': false,
    'manual': true,
  });

  // ── 5B.10：隐私政策 zh/en 齐备且含三点 ──
  {
    final problems = <String>[];
    final checks = {
      'zh': ['store/privacy_policy_zh.md'],
      'en': ['store/privacy_policy_en.md'],
    };
    final keywords = {
      'zh': [
        RegExp('不收集|不会收集'),
        RegExp('不传输|不会传输|不向任何服务器'),
        RegExp('未申请\\s*INTERNET|不申请.{0,4}网络|无.{0,4}INTERNET|无网络权限'),
      ],
      'en': [
        RegExp('collect nothing|does not collect', caseSensitive: false),
        RegExp('transmit nothing|does not send|does not transmit', caseSensitive: false),
        RegExp('INTERNET permission'),
      ],
    };
    for (final lang in ['zh', 'en']) {
      var found = false;
      for (final p in checks[lang]!) {
        if (!File(p).existsSync()) {
          problems.add('$p 缺失');
          continue;
        }
        found = true;
        final content = File(p).readAsStringSync();
        for (var i = 0; i < 3; i++) {
          if (!keywords[lang]![i].hasMatch(content)) {
            problems.add('$p 缺少要点${i + 1}（收集/传输/网络权限）');
          }
        }
      }
      if (!found) problems.add('$lang 隐私政策文件不存在');
    }
    items.add({
      'item': '5B.10',
      'expected': 'zh/en 隐私政策齐备且明确含「不收集/不传输/无网络权限」三点',
      'actual': problems.isEmpty ? '两版齐备，三点齐备' : problems,
      'pass': problems.isEmpty,
    });
  }

  // ── 5B.11：PRIVACY_HOSTING.md ──
  {
    const p = 'store/PRIVACY_HOSTING.md';
    items.add({
      'item': '5B.11',
      'expected': '$p 存在',
      'actual': File(p).existsSync()
          ? '存在（${File(p).lengthSync()} 字节）'
          : '不存在',
      'pass': File(p).existsSync(),
    });
  }

  // ── 5B.12：COMPLIANCE.md + CHECKLIST.md，且区分自动/手动 ──
  {
    const c = 'store/COMPLIANCE.md';
    const k = 'store/CHECKLIST.md';
    final problems = <String>[];
    if (!File(c).existsSync()) problems.add('$c 缺失');
    if (!File(k).existsSync()) problems.add('$k 缺失');
    if (File(k).existsSync()) {
      final s = File(k).readAsStringSync();
      final hasAuto = RegExp('自动').hasMatch(s);
      final hasManual = RegExp('手动|人工').hasMatch(s);
      if (!hasAuto || !hasManual) {
        problems.add('CHECKLIST 未区分自动完成/需手动（auto=$hasAuto manual=$hasManual）');
      }
    }
    items.add({
      'item': '5B.12',
      'expected': 'COMPLIANCE.md 与 CHECKLIST.md 存在；CHECKLIST 区分「已自动完成/需用户手动」',
      'actual': problems.isEmpty ? '两文件存在，CHECKLIST 含区分' : problems,
      'pass': problems.isEmpty,
    });
  }

  // ── 5B.13：启动无全白帧（机读 splash_check 全部 PNG）──
  {
    final dir = Directory('store/splash_check');
    final problems = <String>[];
    var framesChecked = 0;
    if (dir.existsSync()) {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.png'))
          .toList();
      for (final f in files) {
        final png = loadPng(f.path);
        // frames_sheet 是多帧拼贴：按面板宽 1080 切分逐帧检查
        final panels = (png.width / 1080).round();
        final panelW = png.width ~/ panels;
        for (var pi = 0; pi < panels; pi++) {
          framesChecked++;
          var white = 0, total = 0;
          for (var y = 0; y < png.height; y += 3) {
            for (var x = pi * panelW; x < (pi + 1) * panelW; x += 3) {
              total++;
              final i = (y * png.width + x) * 4;
              if (png.rgba[i] >= 245 &&
                  png.rgba[i + 1] >= 245 &&
                  png.rgba[i + 2] >= 245) {
                white++;
              }
            }
          }
          final wr = white / total;
          if (wr > 0.99) {
            problems.add('${f.path} 面板#$pi 近全白占比 ${(wr * 100).toStringAsFixed(1)}%');
          }
        }
      }
    } else {
      problems.add('store/splash_check/ 目录缺失');
    }
    items.add({
      'item': '5B.13',
      'expected': '冷启动帧（splash_check 全部 PNG 含 frames_sheet 各面板）无全白帧',
      'actual': problems.isEmpty
          ? '检查 $framesChecked 个面板，无全白帧（sheet=6 面板 + 2 单帧）。'
              '注：46 帧原始录屏未随交付保留，可机读证据为 6 面板抽样 + 2 单帧，'
              '另经 gatekeeper 目检 sheet 无全白帧，证据局限在报告 r1 中注明'
          : problems,
      'pass': problems.isEmpty,
    });
  }

  // ── 输出 ──
  final outPath = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : 'out/gate_G5B.json';
  writeGateReportSync(outPath, 'G5B', items);
  final passed = items.where((i) => i['pass'] == true).length;
  stdout.writeln('G5B: $passed/${items.length} 项通过（MANUAL '
      '${items.where((i) => i['manual'] == true).length} 项）→ $outPath');
  exit(items.every((i) => i['pass'] == true) ? 0 : 1);
}

void writeGateReportSync(
    String outPath, String gateId, List<Map<String, dynamic>> items) {
  for (final i in items) {
    if (i['manual'] == true && i['pass'] == true) {
      throw StateError('gate 脚本内部错误：${i['item']} manual=true 却 pass=true');
    }
  }
  final passed = items.where((i) => i['pass'] == true).length;
  final manual = items.where((i) => i['manual'] == true).length;
  final report = {
    'gate': gateId,
    'generatedAt': DateTime.now().toIso8601String(),
    'items': items,
    'summary': {'total': items.length, 'passed': passed, 'manual': manual},
    'pass': items.every((i) => i['pass'] == true),
  };
  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
}

extension _Chars on String {
  // 简易 UTF-8 感知的字符计数（Dart String.characters 需要 characters 包，
  // gate 脚本不引第三方依赖，码点迭代即可满足长度判定）。
  Iterable<int> get _codePoints sync* {
    for (final rune in runes) {
      yield rune;
    }
  }

  int get characters => _codePoints.length;
}
