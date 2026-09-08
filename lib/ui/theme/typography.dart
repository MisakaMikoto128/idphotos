/// 字体样式阶（DESIGN.md §4）。
///
/// 字号只有 11 / 13 / 15 / 18 / 24，字重只有 400 / 700。
/// 任何界面代码都从这里取样式，不要就地写 `TextStyle(fontSize: 14)`。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import 'fonts.dart';
import 'tokens.dart';

/// 字体族回退链：子集字体 → 系统衬线。
const List<String> _fallback = <String>['serif'];

TextStyle _base({
  required double size,
  required FontWeight weight,
  required Color color,
  double? letterSpacing,
  double height = 1.35,
}) {
  return TextStyle(
    fontFamily: MuZhaoFonts.family,
    fontFamilyFallback: _fallback,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// 全部文本样式。命名按"用途"而不是按"字号"。
abstract final class Type {
  /// 24 / 700 —— 区域标题、按钮主文案。
  static TextStyle title(Color c) =>
      _base(size: FontSize.title, weight: FontWeight.w700, color: c, letterSpacing: 2);

  /// 18 / 700 —— 次级标题、规格名。
  static TextStyle subtitle(Color c) =>
      _base(size: FontSize.subtitle, weight: FontWeight.w700, color: c, letterSpacing: 1);

  /// 15 / 400 —— 正文。
  static TextStyle body(Color c) =>
      _base(size: FontSize.body, weight: FontWeight.w400, color: c, letterSpacing: 0.4);

  /// 15 / 700 —— 强调正文。
  static TextStyle bodyStrong(Color c) =>
      _base(size: FontSize.body, weight: FontWeight.w700, color: c, letterSpacing: 0.4);

  /// 13 / 400 —— 次要说明。用 [T.inkBrown] 而非 `inkFaded`（对比度红线）。
  static TextStyle small(Color c) =>
      _base(size: FontSize.small, weight: FontWeight.w400, color: c, letterSpacing: 0.4);

  /// 13 / 700 —— 铭牌刻字。
  static TextStyle plate(Color c) =>
      _base(size: FontSize.small, weight: FontWeight.w700, color: c, letterSpacing: 1.2);

  /// 11 / 400 + letterSpacing 0.5 —— 尺寸标注、打字机味的数字。
  static TextStyle caption(Color c) =>
      _base(size: FontSize.caption, weight: FontWeight.w400, color: c, letterSpacing: 0.5);

  /// 11 / 700 —— 标尺上的规格数字。
  static TextStyle captionStrong(Color c) =>
      _base(size: FontSize.caption, weight: FontWeight.w700, color: c, letterSpacing: 1.0);
}
