// integration_test/coldstart_probe_test.dart
//
// G3.4 冷启动探针（设备端测量代码，阈值判定在 tools/gate/gate_G3.dart）。
//
// 背景（为什么不是直接 `am start -W`，见 out/GATE_G3_r1.md 与 gate_G3.dart 头注释）：
// 本开发机宿主 GPU 驱动栈损坏（docs/PITFALLS.md），**任何以 Impeller GLES 渲染
// 真实 UI 的 AOT App 都会在首次真实渲染时杀死 qemu 宿主进程**（release/profile
// 直启均秒死，debug main.dart 启动也在 ~45s 内死，已 5 次复现，2 台 AVD、2 种
// 客户机内存、无 WER/无 minidump）。唯一稳定路径是 flutter 工具链以
// `--no-enable-impeller`（Skia）注入启动 —— 这正是 G2 截图流水线一直以来的做法。
// `flutter build apk` 不接受 --no-enable-impeller（退出码 64，实测），
// 因此冷启动用 `flutter drive --profile --no-enable-impeller` 驱动本探针。
//
// 测量口径：**进程创建 → 真实工作台首帧栅格化完成**。
// - 进程创建时刻：/proc/self/stat 第 22 字段（starttime，boot 后的 CLK_TCK tick）
// - 首帧时刻：pump 真实 App 根（MuZhaoApp，真实 controller/engine 装配）后等
//   WidgetsBinding.endOfFrame，读 /proc/uptime
// - coldStartMs = (uptime_at_first_frame − starttime/CLK_TCK) × 1000
// 与 `am start -W` TotalTime 相比少了 ActivityManager 调度的一小段（几十 ms 量级），
// 是偏乐观的方向；但 profile AOT 比 release AOT 略慢（偏保守方向），两者部分抵消。
// 判定阈值不变：中位数 ≤ 2000ms。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:muzhao/core/controller.dart';
import 'package:muzhao/core/engine_impl.dart';
import 'package:muzhao/main.dart' show MuZhaoApp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:muzhao/ui/state/providers.dart' show controllerProvider;

/// CLK_TCK 在 Android 上恒为 100。

/// /proc/self/stat 的 starttime（第 22 字段），单位：boot 后的 tick。
/// comm 字段可能含空格，从最后一个 ')' 之后解析。
double? _processStartTicks() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final closeParen = stat.lastIndexOf(')');
  if (closeParen == -1) return null;
  final fields = stat.substring(closeParen + 2).split(' ');
  // 去掉 pid 和 comm 后，字段从 state(1) 起，starttime 是原文件第 22 字段
  // = 这里的第 20 个（22 − 2）。
  if (fields.length < 20) return null;
  return double.tryParse(fields[19]);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G3.4 cold start probe', (tester) async {
    // /proc/uptime 对 untrusted_app 被 SELinux 拒读（avc denied，实测），
    // 进程创建→首帧的完整口径在设备端测不了；探针退化为
    // "Dart main 进点 → 真实 UI 首帧栅格化完成"（Stopwatch，CLOCK_MONOTONIC），
    // 用于把 am start -W TotalTime 拆成 引擎/进程启动段 与 Dart build+layout+栅格段。
    final sw = Stopwatch()..start();
    final startTicks = _processStartTicks();

    // 真实 App 根：与 lib/main.dart 的 runApp 完全一致的装配
    // （真实 engine + 真实 controller + 真实主题 + 真实工作台）。
    final engine = IdPhotoEngineImpl();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controllerProvider.overrideWithValue(MuZhaoController(engine)),
        ],
        child: const MuZhaoApp(),
      ),
    );
    // 注意：endOfFrame 在 pumpWidget 已把当帧 flush 掉之后会等一个永远不会被
    // 调度的"下一帧"而挂死（实测 5 分钟超时）。live binding 的 pump 会真实
    // 调度并等待一帧，用它作为首帧完成点。
    await tester.pump(const Duration(milliseconds: 100));
    sw.stop();

    binding.reportData = {
      'coldStartMs': null,
      'measuredVia': 'main_to_frame_stopwatch',
      'mainToFrameMs': sw.elapsedMilliseconds,
      'processStartTicks': startTicks,
      'note': '进程创建→首帧的权威口径由 host 侧 am start -W TotalTime 提供；'
          '本探针只负责拆分 Dart 侧 build/layout/栅格占比。'
          'main() 的 unawaited(engine.warmUp()) 不在首帧路径上，探针不调用 warmUp，与真实 App 一致',
    };
  }, timeout: const Timeout(Duration(minutes: 5)));
}
