/// 木照 MuZhao — 设计令牌（Design Token）。
///
/// `docs/DESIGN.md` §1 的 13 个色值是本 App **全部可用颜色**。
/// 任何界面代码只能引用本文件的常量，**禁止写字面色值**（G2C.2 / G2C.3 会实测）。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

/// DESIGN.md §1 色卡。名字与文档表格逐行对应，顺序不得调整。
abstract final class T {
  // ---- 木 ----
  /// `#3E2A1B` 最外层框体、深色木纹阴影。
  static const Color woodDark = Color(0xFF3E2A1B);

  /// `#6B4A2F` 主背景木纹底色。
  static const Color woodBase = Color(0xFF6B4A2F);

  /// `#A9784F` 木纹高光、边缘倒角。
  static const Color woodLight = Color(0xFFA9784F);

  // ---- 黄铜 ----
  /// `#B08D3F` 金属件基色。
  static const Color brass = Color(0xFFB08D3F);

  /// `#E8CE7A` 金属高光。
  static const Color brassHi = Color(0xFFE8CE7A);

  /// `#6E5320` 金属暗部。
  static const Color brassShadow = Color(0xFF6E5320);

  // ---- 纸 ----
  /// `#F4E9D6` 卡片/照片衬纸、文字区底。
  static const Color paper = Color(0xFFF4E9D6);

  /// `#DCCBAE` 纸张边缘、分隔线。
  static const Color paperEdge = Color(0xFFDCCBAE);

  // ---- 绒布 ----
  /// `#2F4F3A` 台面绒布衬底。
  static const Color feltGreen = Color(0xFF2F4F3A);

  // ---- 文字 ----
  /// `#3A2B1C` 纸上正文文字。
  static const Color inkBrown = Color(0xFF3A2B1C);

  /// `#7A6A55` 次要色。
  ///
  /// 注意：DESIGN.md 把它标为"纸上次要文字"，但 `inkFaded` on `paper` 的对比度
  /// 实测仅 4.34:1，低于无障碍红线 4.5:1（RUBRIC 致命项 4）。
  /// 因此本 App **不把它用于纸上文字**，只用于分隔线、哑光禁用金属、非文字装饰。
  /// 次要文字一律用 [inkBrown] 配小字号。
  static const Color inkFaded = Color(0xFF7A6A55);

  /// `#F0E4CE` 木头/深色上的文字。
  static const Color creamText = Color(0xFFF0E4CE);

  /// `#8C2B22` 危险/删除，旧漆红。
  static const Color accentRed = Color(0xFF8C2B22);
}

/// DESIGN.md §3 形态。
abstract final class Shape {
  /// 容器圆角 6px。复古家具是小圆角。
  static const double panelRadius = 6;

  /// 按钮圆角 4px。
  static const double buttonRadius = 4;

  static const Radius panel = Radius.circular(panelRadius);
  static const Radius button = Radius.circular(buttonRadius);

  static const BorderRadius panelBorder =
      BorderRadius.all(Radius.circular(panelRadius));
  static const BorderRadius buttonBorder =
      BorderRadius.all(Radius.circular(buttonRadius));
}

/// DESIGN.md §3 阴影：暖色，禁止冷灰。
abstract final class Shade {
  /// 投影基色 `0x66241609`。
  static const Color warmShadow = Color(0x66241609);

  /// 更淡的一层，用于贴近表面的元素。
  static const Color warmShadowSoft = Color(0x33241609);

  /// 裁剪框外压暗 `0x99241609`（DESIGN.md §5 区域 A）。
  static const Color scrim = Color(0x99241609);

  /// 标准落影。
  static const List<BoxShadow> lifted = <BoxShadow>[
    BoxShadow(color: warmShadow, blurRadius: 8, offset: Offset(0, 3)),
  ];

  /// 按下时收缩的影。
  static const List<BoxShadow> pressed = <BoxShadow>[
    BoxShadow(color: warmShadow, blurRadius: 3, offset: Offset(0, 1)),
  ];
}

/// DESIGN.md §2 全局光源方向：左上。所有倒角与投影据此推算（RUBRIC R2）。
///
/// 单位向量，指向"光来的方向"。
const Offset kLightDir = Offset(-0.707, -0.707);

/// DESIGN.md §6 动效。
abstract final class Motion {
  static const Curve curve = Curves.easeOutCubic;

  /// 微交互 180ms。
  static const Duration micro = Duration(milliseconds: 180);

  /// 区域切换 320ms。
  static const Duration area = Duration(milliseconds: 320);
}

/// DESIGN.md §4 字号阶：11 / 13 / 15 / 18 / 24。
abstract final class FontSize {
  static const double caption = 11;
  static const double small = 13;
  static const double body = 15;
  static const double subtitle = 18;
  static const double title = 24;
}

/// 触摸热区最小边长（G2C.5：≥ 44×44 逻辑像素）。
const double kMinHitSize = 48;
