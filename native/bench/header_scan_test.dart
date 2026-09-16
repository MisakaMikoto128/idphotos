// M3 安全闭合前置扫描：全量数据集（batch 80 唯一路径 + 黄金 8）里，
// 哪些文件 readImageHeaderSize 返回 null（= 会走 decodeToRgb 无条件全量
// 解码兜底），以及它们在 dataset_gate_regress.jsonl 里的实际结局。
// 若所有 success 条目的头都能解析，则"头解析失败 → UnsupportedImageException"
// 的硬拒对现网数据零影响。
//
// 跑法：flutter test native/bench/header_scan_test.dart
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/matting/image_header.dart';

void main() {
  test('scan dataset for header-parse failures', () async {
    final repo = Directory.current.path;
    final sep = Platform.pathSeparator;
    final outcomes = <String, String>{};
    // regress 结果按 顺序 对应 cases 构造顺序（golden_g01..08 + batch 去重序）
    final regress = File('$repo${sep}out${sep}dataset_gate_regress.jsonl');
    final ref = File('$repo${sep}out${sep}gate_G4_batch_ref.json');
    final paths = <String, String>{};
    for (var i = 1; i <= 8; i++) {
      paths['golden_g0$i'] =
          '$repo${sep}test${sep}golden${sep}src${sep}g0$i.jpg';
    }
    if (ref.existsSync()) {
      final items =
          (jsonDecode(ref.readAsStringSync()) as Map)['items'] as List;
      final seen = <String>{};
      for (final it in items) {
        final m = it as Map;
        final p = m['sourcePath'] as String;
        if (!seen.add(p)) continue;
        paths['b_${m['class']}_${seen.length}'] = p;
      }
    }
    if (regress.existsSync()) {
      for (final line in regress.readAsStringSync().split('\n')) {
        if (line.trim().isEmpty) continue;
        final r = jsonDecode(line) as Map;
        final id = r['id'] as String;
        outcomes[id] = '${r['outcome']}${r['exc'] ?? ''}';
      }
    }
    var nullHeader = 0;
    for (final e in paths.entries) {
      final f = File(e.value);
      if (!f.existsSync()) continue;
      final h = readImageHeaderSize(f.readAsBytesSync());
      final oc = outcomes[e.key] ?? 'no-regress-run';
      if (h == null) {
        nullHeader++;
        stdout.writeln('NULL_HEADER ${e.key} outcome=$oc ${e.value}');
      }
    }
    stdout.writeln('SUMMARY total=${paths.length} nullHeader=$nullHeader');
    final succIds = outcomes.entries
        .where((e) => e.value.startsWith('success'))
        .map((e) => e.key)
        .toList();
    final succNullHeader = succIds
        .where((id) => paths[id] != null)
        .where((id) => !File(paths[id]!).existsSync() ||
            readImageHeaderSize(File(paths[id]!).readAsBytesSync()) == null)
        .toList();
    stdout.writeln('success_items=${succIds.length} '
        'success_with_null_header=${succNullHeader.length}');
    for (final id in succNullHeader) {
      stdout.writeln('SUCCESS_BUT_NULL_HEADER $id ${paths[id]}');
    }
  });
}
