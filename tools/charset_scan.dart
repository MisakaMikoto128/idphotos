/// 字符集提取器：扫描 `lib/` 下全部 Dart 源码的**字符串字面量**，收集其中
/// 出现过的字符，用于生成 Noto Serif SC 子集（见 `theme/fonts.dart`）。
///
/// 为什么不用正则：上一版用正则抓字符串，遇到插值 `${...}`、转义 `\u{XXXX}`、
/// 三引号、原始字符串就抓瞎，漏了 28 个字。这是一个真正的词法扫描器：
///
/// * 跳过 `//` 与（可嵌套的）`/* */` 注释；
/// * 处理 `'…'` / `"…"` / `'''…'''` / `"""…"""` / `r'…'`；
/// * 处理转义：`\n` `\xXX` `\uXXXX` `\u{…}`；
/// * 遇到插值 `${…}` 时把内部当**代码**继续扫描（内部还可能有嵌套字符串），
///   遇到 `$identifier` 时跳过标识符本身（运行期才确定，子集按保守覆盖处理）。
///
/// 用法（在项目根目录）：
/// ```
/// dart run lib/ui/dev/charset_scan.dart
/// ```
/// 输出比对报告，并把子集字符表写到 `%TEMP%\muzhao_charset.txt` 供
/// `pyftsubset --text-file` 使用。纯 dart:io，可在 VM 下直接跑。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final String root = Directory.current.path;
  final List<File> files = <File>[];
  _collectDartFiles(Directory('$root/lib'), files);
  if (files.isEmpty) {
    stderr.writeln('错误：lib/ 下没有找到 .dart 文件（请在项目根目录运行）');
    exitCode = 2;
    return;
  }

  final Set<int> used = <int>{};
  final List<String> perFileMissingNotes = <String>[];
  for (final File f in files) {
    final String src = f.readAsStringSync();
    final String scanned = _blankCoveredCharset(src);
    final _Scanner s = _Scanner(scanned);
    s.scan();
    used.addAll(s.chars);
  }

  // fonts.dart 的 coveredCharset：与扫描结果比对。
  final String fontsSrc =
      File('$root/lib/ui/theme/fonts.dart').readAsStringSync();
  final Set<int> covered = _extractCoveredCharset(fontsSrc);

  final List<int> nonAsciiUsed = used.where((int c) => c >= 0x80).toList()
    ..sort();
  final List<int> missing =
      nonAsciiUsed.where((int c) => !covered.contains(c)).toList();
  final List<int> extra =
      covered.where((int c) => c >= 0x80 && !used.contains(c)).toList()
        ..sort();

  // 子集字符表 = 全部 ASCII 可见字符 + 本次扫到的全部非 ASCII 字符。
  // 保守起见，coveredCharset 里原有的字符即使本轮没扫到也保留（旧文案回滚、
  // 测试夹具注入的文案都可能用到）。
  final Set<int> keep = <int>{
    for (int c = 0x20; c <= 0x7E; c++) c,
    ...nonAsciiUsed,
    ...covered,
  };
  final String charsetText = String.fromCharCodes(keep.toList()..sort());
  final String tmp = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
  final File outFile = File('$tmp/muzhao_charset.txt');
  outFile.writeAsStringSync(charsetText, encoding: utf8);

  stdout.writeln('扫描文件数: ${files.length}');
  stdout.writeln('字符串字面量用到的非 ASCII 字符: ${nonAsciiUsed.length}');
  stdout.writeln('coveredCharset 非 ASCII 字符: '
      '${covered.where((int c) => c >= 0x80).length}');
  stdout.writeln('缺字（用到但子集没有）: ${missing.length}');
  if (missing.isNotEmpty) {
    perFileMissingNotes.add(String.fromCharCodes(missing));
    stdout.writeln('  缺字明细: ${String.fromCharCodes(missing)}');
    stdout.writeln('  码点: '
        '${missing.map((int c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}').join(' ')}');
  }
  stdout.writeln('保留但本轮未用到的字符: ${extra.length}');
  if (extra.isNotEmpty) {
    stdout.writeln('  ${String.fromCharCodes(extra)}');
  }
  stdout.writeln('子集字符表（含 ASCII 共 ${keep.length} 字符）已写入: ${outFile.path}');
  stdout.writeln(missing.isEmpty ? 'COVERAGE OK — 0 缺字' : 'COVERAGE FAIL');
  if (missing.isNotEmpty) exitCode = 1;
}

void _collectDartFiles(Directory dir, List<File> out) {
  for (final FileSystemEntity e in dir.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e);
  }
}

/// fonts.dart 自身的 `coveredCharset` 字面量包含全字符表，若不跳过会让扫描
/// 结果永远"全覆盖"，比对就失去意义。把它替换成等长的空白（保住行号与偏移）。
/// 注意 docs 注释里也出现过这个词，必须锚定真正的**赋值**。
String _blankCoveredCharset(String src) {
  final RegExpMatch? m =
      RegExp(r'coveredCharset\s*=').firstMatch(src);
  if (m == null) return src;
  final int start = m.start;
  int end = src.indexOf(';', m.end);
  if (end < 0) end = src.length;
  return src.replaceRange(start, end, ' ' * (end - start));
}

/// 从 fonts.dart 源码里取出 `coveredCharset = '…' '…';` 的字符串内容
/// （Dart 相邻字符串字面量自动拼接，这里逐段抓出再拼回来）。
Set<int> _extractCoveredCharset(String src) {
  final RegExpMatch? m =
      RegExp(r'coveredCharset\s*=').firstMatch(src);
  if (m == null) return <int>{};
  int end = src.indexOf(';', m.end);
  if (end < 0) end = src.length;
  final String decl = src.substring(m.end, end);
  final RegExp lit = RegExp(r"'([^']*)'");
  final StringBuffer buf = StringBuffer();
  for (final RegExpMatch match in lit.allMatches(decl)) {
    buf.write(match.group(1));
  }
  return buf.toString().runes.toSet();
}

/// Dart 字符串字面量扫描器。
class _Scanner {
  final String src;

  /// 收集到的码点（字符串内容，含插值内部嵌套字符串）。
  final Set<int> chars = <int>{};

  int _hiSurrogate = -1;

  _Scanner(this.src);

  void scan() => _scanCode(0, src.length);

  /// 扫描一段**代码**（[start, end)）。遇到不匹配的 `}` 时提前返回其后的位置
  /// —— 递归调用方（插值 / 花括号组）用它定位自己的结束符。
  int _scanCode(int start, int end) {
    int i = start;
    while (i < end) {
      final int c = src.codeUnitAt(i);
      if (c == 0x2F) {
        // '/'：行注释或块注释，否则普通字符
        if (i + 1 < end && src.codeUnitAt(i + 1) == 0x2F) {
          i = _skipLineComment(i, end);
          continue;
        }
        if (i + 1 < end && src.codeUnitAt(i + 1) == 0x2A) {
          i = _skipBlockComment(i, end);
          continue;
        }
        i++;
        continue;
      }
      if (c == 0x27 || c == 0x22) {
        // ''' / "：字符串
        i = _scanString(i, end);
        continue;
      }
      if (c == 0x7B) {
        // '{'：递归扫花括号组（类体 / 函数体 / 集合字面量都一样处理）
        i = _scanCode(i + 1, end);
        continue;
      }
      if (c == 0x7D) {
        // '}'：当前层结束
        return i + 1;
      }
      i++;
    }
    return end;
  }

  /// 扫描从 [i]（指向引号）开始的字符串字面量，返回结束后的下标。
  int _scanString(int i, int end) {
    final int q = src.codeUnitAt(i);
    // 原始字符串：前一个字符是 r/R。Dart 里引号前紧邻 r 只可能是前缀
    // （标识符后不能直接跟字符串字面量），这个判断是安全的。
    final int prev = i > 0 ? src.codeUnitAt(i - 1) : 0;
    final bool raw = prev == 0x72 || prev == 0x52;
    final bool triple = i + 2 < end &&
        src.codeUnitAt(i + 1) == q &&
        src.codeUnitAt(i + 2) == q;
    i += triple ? 3 : 1;
    while (i < end) {
      final int c = src.codeUnitAt(i);
      if (c == q) {
        if (triple) {
          if (i + 2 < end &&
              src.codeUnitAt(i + 1) == q &&
              src.codeUnitAt(i + 2) == q) {
            return i + 3;
          }
          _addChar(c);
          i++;
          continue;
        }
        return i + 1;
      }
      if (!raw && c == 0x5C) {
        // 反斜杠转义
        i = _scanEscape(i + 1, end);
        continue;
      }
      if (!raw && c == 0x24 && i + 1 < end) {
        // '$'：插值
        final int n = src.codeUnitAt(i + 1);
        if (n == 0x7B) {
          i = _scanCode(i + 2, end);
          continue;
        }
        if (_isIdentStart(n)) {
          i += 2;
          while (i < end && _isIdentChar(src.codeUnitAt(i))) {
            i++;
          }
          continue;
        }
        _addChar(c);
        i++;
        continue;
      }
      _addChar(c);
      i++;
    }
    return end;
  }

  /// [i] 指向反斜杠后的第一个字符，返回转义结束后的下标。
  int _scanEscape(int i, int end) {
    if (i >= end) return end;
    final int c = src.codeUnitAt(i);
    switch (c) {
      case 0x75: // 'u'
        if (i + 1 < end && src.codeUnitAt(i + 1) == 0x7B) {
          int j = i + 2;
          int v = 0;
          bool any = false;
          while (j < end && src.codeUnitAt(j) != 0x7D) {
            final int h = _hexDigit(src.codeUnitAt(j));
            if (h < 0) return j;
            v = v * 16 + h;
            any = true;
            j++;
          }
          if (any && j < end) _add(v);
          return j < end ? j + 1 : end;
        }
        if (i + 4 < end) {
          int v = 0;
          bool ok = true;
          for (int k = 1; k <= 4; k++) {
            final int h = _hexDigit(src.codeUnitAt(i + k));
            if (h < 0) {
              ok = false;
              break;
            }
            v = v * 16 + h;
          }
          if (ok) _add(v);
          return i + 5;
        }
        return i + 1;
      case 0x78: // 'x' \xXX
        if (i + 2 < end &&
            _hexDigit(src.codeUnitAt(i + 1)) >= 0 &&
            _hexDigit(src.codeUnitAt(i + 2)) >= 0) {
          _add(_hexDigit(src.codeUnitAt(i + 1)) * 16 +
              _hexDigit(src.codeUnitAt(i + 2)));
          return i + 3;
        }
        return i + 1;
      default:
        // \n \t \r \b \f \v \0 与 \' \" \\ \$ 等：控制字符反正进不了字体，
        // 统一按"转义后的字面字符"收录即可。
        _add(c);
        return i + 1;
    }
  }

  int _skipLineComment(int i, int end) {
    while (i < end) {
      final int c = src.codeUnitAt(i);
      if (c == 0x0A) return i + 1;
      if (c == 0x0D) return i + 1 < end && src.codeUnitAt(i + 1) == 0x0A ? i + 2 : i + 1;
      i++;
    }
    return end;
  }

  /// 块注释可嵌套（`/* /* */ */` 是合法 Dart）。
  int _skipBlockComment(int i, int end) {
    int depth = 0;
    while (i < end) {
      if (i + 1 < end && src.codeUnitAt(i) == 0x2F && src.codeUnitAt(i + 1) == 0x2A) {
        depth++;
        i += 2;
        continue;
      }
      if (i + 1 < end && src.codeUnitAt(i) == 0x2A && src.codeUnitAt(i + 1) == 0x2F) {
        depth--;
        i += 2;
        if (depth == 0) return i;
        continue;
      }
      i++;
    }
    return end;
  }

  void _addChar(int unit) {
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      _hiSurrogate = unit;
      return;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF && _hiSurrogate >= 0) {
      final int cp =
          0x10000 + ((_hiSurrogate - 0xD800) << 10) + (unit - 0xDC00);
      _hiSurrogate = -1;
      _add(cp);
      return;
    }
    _hiSurrogate = -1;
    _add(unit);
  }

  void _add(int cp) {
    // 丢弃控制字符；ASCII 可见字符与全部非 ASCII 都收。
    if (cp >= 0x20 && (cp <= 0x7E || cp >= 0x80)) chars.add(cp);
  }

  static bool _isIdentStart(int c) =>
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x41 && c <= 0x5A) ||
      c == 0x5F ||
      c == 0x24;

  static bool _isIdentChar(int c) =>
      _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

  static int _hexDigit(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    return -1;
  }
}
