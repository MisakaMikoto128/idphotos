/// 三段式骨架（CLAUDE.md §2，不得增删主区域）。
///
/// 比例严格 **A 45% / B 38% / C 17%**（RUBRIC R5 实测，偏差 >10pp 是致命项）。
/// 因此这里**不套 SafeArea**：整列铺满整屏，三段之和恒为 100%，
/// 系统状态栏/导航栏的避让由各区域内部自己 padding 掉。
///
/// 主会话在阶段 3 把 `lib/main.dart` 的 `home` 换成 [MuZhaoWorkbench]，
/// 并用真实实现覆盖 `controllerProvider`。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/material.dart' show ThemeData, NoSplash, MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import 'areas/area_a_source.dart';
import 'areas/area_b_candidates.dart';
import 'areas/area_c_save.dart';
import 'state/providers.dart';
import 'theme/fonts.dart';
import 'theme/tokens.dart';
import 'theme/typography.dart';
import 'widgets/spec_drawer.dart';

/// A / B / C 三段的 flex 权重。
const int kAreaAFlex = 45;
const int kAreaBFlex = 38;
const int kAreaCFlex = 17;

/// 全局 Theme。木制风格不用 Material 的配色，这里只做三件事：
/// 关掉 ripple、锁死浅色模式、给未指定样式的文本一个衬线默认值。
ThemeData buildMuZhaoTheme() {
  return ThemeData(
    useMaterial3: true,
    // DESIGN.md §3 / G2C.9：禁止 Material ripple。
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    scaffoldBackgroundColor: T.woodBase,
  );
}

/// 工作台根 widget。可直接作为 `MaterialApp.home`。
class MuZhaoWorkbench extends StatelessWidget {
  const MuZhaoWorkbench({super.key});

  @override
  Widget build(BuildContext context) {
    return FontGate(
      child: DefaultTextStyle(
        style: Type.body(T.creamText),
        child: ColoredBox(
          color: T.woodBase,
          child: Stack(
            fit: StackFit.expand,
            children: const <Widget>[
              Column(
                children: <Widget>[
                  Expanded(flex: kAreaAFlex, child: AreaASource()),
                  Expanded(flex: kAreaBFlex, child: AreaBCandidates()),
                  Expanded(flex: kAreaCFlex, child: AreaCSave()),
                ],
              ),
              _SpecDrawerHost(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpecDrawerHost extends ConsumerWidget {
  const _SpecDrawerHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppState app = ref.watch(appStateProvider);
    final bool open =
        ref.watch(workbenchProvider.select((WorkbenchState s) => s.specSheetOpen));
    return SpecDrawer(
      open: open,
      current: app.spec,
      onPick: (PhotoSpec s) {
        ref.read(controllerProvider).setSpec(s);
        ref.read(workbenchProvider.notifier).setSpecSheet(false);
      },
      onClose: () => ref.read(workbenchProvider.notifier).setSpecSheet(false),
    );
  }
}

/// 一个可直接 `runApp` / `pumpWidget` 的完整 App（自带 MaterialApp）。
///
/// 阶段 2 由 `lib/ui/dev/shot_harness.dart` 使用；主会话接线时也可以直接复用。
class MuZhaoUiApp extends StatelessWidget {
  const MuZhaoUiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '木照',
      debugShowCheckedModeBanner: false,
      theme: buildMuZhaoTheme(),
      home: const MuZhaoWorkbench(),
    );
  }
}
