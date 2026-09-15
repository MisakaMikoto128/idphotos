/// 木照 MuZhao — 应用入口（接线层）。
///
/// **主会话独占写入**（CLAUDE.md §4）。阶段 3 起本文件做的事：
///
/// 1. 创建唯一的 [IdPhotoEngineImpl]（matting + compose 两个 mixin 的合成体）
/// 2. 用真实 [MuZhaoController] 覆盖 `controllerProvider`
/// 3. `home` 挂上 `lib/ui/` 的三段式工作台，主题用 `buildMuZhaoTheme()`
///
/// 截图/测试场景**不走本文件**：它们用 `lib/ui/dev/shot_harness.dart`
/// 构造确定性场景（CONTRACTS §7），FakeController 在那边注入。
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/controller.dart';
import 'core/engine_impl.dart';
import 'ui/app.dart';
import 'ui/state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final IdPhotoEngineImpl engine = IdPhotoEngineImpl();
  // 预取（prefetch）：初始化本身由 warmUp 的幂等共享 Future 保证
  // （MattingEngineMixin 内部 _requireSession 会 await 同一个 Future），
  // 这里只是让模型在用户选图前就开始加载，不阻塞首帧。
  // 失败不致命：首次 loadImage 会重新 await warmUp 并以中文提示呈现；
  // 监听错误是为了不让启动期的拒绝变成未处理 zone 错误，并留下诊断。
  unawaited(engine.warmUp().then(
    (_) {},
    onError: (Object e, StackTrace st) {
      developer.log('引擎预热失败（将在首次载入照片时重试）',
          name: 'muzhao.main', error: e, stackTrace: st);
    },
  ));
  runApp(
    ProviderScope(
      overrides: [
        controllerProvider.overrideWithValue(MuZhaoController(engine)),
      ],
      child: const MuZhaoApp(),
    ),
  );
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
      theme: buildMuZhaoTheme(),
      home: const MuZhaoWorkbench(),
    );
  }
}
