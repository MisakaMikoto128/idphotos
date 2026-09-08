/// 木照 MuZhao — 应用入口。
///
/// **主会话独占写入**（接线层）。
///
/// 阶段 1.5 的本文件只是骨架：它只负责 `runApp` 与全局 Theme 的硬性约束
/// （不做深色模式、禁用 Material ripple）。真正的三段式界面由 `ui-woodcraft`
/// 在 `lib/ui/` 实现，主会话在阶段 3 把 `MuZhaoApp.home` 换成 UI 根 widget、
/// 并注入真实的 `IdPhotoController`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: MuZhaoApp()));
}

class MuZhaoApp extends StatelessWidget {
  const MuZhaoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '木照',
      debugShowCheckedModeBanner: false,
      // DESIGN.md §7：不做深色模式，木制风格本身即深色调。
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        // DESIGN.md §3 / G2C.9：禁止 Material ripple，按压反馈由木质按钮自绘。
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: const _ScaffoldPlaceholder(),
    );
  }
}

/// 阶段 3 由主会话替换为 `lib/ui/` 的根 widget。
///
/// 之所以留一个能真实渲染的占位而不是空 `Container`：gatekeeper 的
/// `integration_test/shots_test.dart` 要靠它截出非纯黑的一帧来守住 G1.6。
class _ScaffoldPlaceholder extends StatelessWidget {
  const _ScaffoldPlaceholder();

  @override
  Widget build(BuildContext context) {
    // 用 DESIGN.md 的 woodBase / creamText，避免占位期出现纯黑纯白（G2C.4）。
    return const ColoredBox(
      color: Color(0xFF6B4A2F),
      child: Center(
        child: Text(
          '木照',
          textDirection: TextDirection.ltr,
          style: TextStyle(
            color: Color(0xFFF0E4CE),
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
