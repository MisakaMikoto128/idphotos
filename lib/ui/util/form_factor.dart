/// 形态判定：手机（紧凑布局）还是桌面窗口（宽松布局）。
///
/// 用户 2026-09-19 手机实测反馈：区域 A 太小、拖拽裁剪框不好操作，
/// 区域 C 在手机上偏大，要求压缩 C 让给 A。
///
/// 判定**不能**用"逻辑屏高 < 750"：主流竖屏手机（如 1080×2220 @440dpi）
/// 逻辑高是 808，会被误判成桌面。改用 `shortestSide < 600`（Flutter 惯例的
/// 手机/平板分界）：手机竖/横屏的 shortestSide 都是 360–430，而桌面窗口
/// 1280×800 的 shortestSide 是 800，widget test 默认表面 800×600 也恰好
/// 保持在桌面档，既有测试不受影响。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

/// 紧凑布局分界：`shortestSide` 低于此值按手机处理。
const double kCompactBreakpoint = 600;

/// 当前是否应按手机紧凑布局渲染。
bool isCompactPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide < kCompactBreakpoint;
