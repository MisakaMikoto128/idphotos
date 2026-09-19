// 抠图提速专项 ①：ORT 会话配置扫参（ml-porting 自用，不是门禁）。
//
// 跑法（Windows，仓库根目录）：
//   flutter test native/bench/ort_speed_sweep_test.dart
//
// 口径：纯模型推理（runFloatInput，[1,3,1024,1024] float32 零输入），
// 不含解码/前处理/后处理——那些与会话配置无关。dense fp32/int8 算子耗时
// 与输入数值无关，零输入不失真。
//
// 采样方法：同批配置的会话先建好常驻，之后逐轮交替采样（每轮每配置 2 次，
// 共 4 轮；每配置第 1 次为预热不计入）。背景负载对所有配置均等摊薄，
// 避免"先跑的配置吃亏"。开发机有常驻后台负载（~40% CPU），单次连跑
// 的 p95 抖动可达 2 倍，不可用于排序。
//
// 分批原因：单会话推理瞬态峰值含一个 ~784MB 的 transpose 缓冲
// （decoder/aspp_deforms），6 会话常驻会撞内存上限——分批 ≤3 个常驻。
//
// 与 G2A.6 全管线口径的关系：全管线 = 纯推理 + 固定前/后处理（~0.6–1s），
// 最优配置最终用 G2A.6 复测确认。
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:muzhao/core/matting/ort_runtime.dart' as ort;

void _preloadHostOnnxRuntime() {
  if (!Platform.isWindows) return;
  // 设了 MUZHAO_ORT_DLL 就交给 ensureOrtRuntimeLoaded 按 env 预载（② 运行时
  // 升级 A/B 用同一探针切换 1.15.1 / 1.29.0，不能两份 dll 同时进场）。
  final override = Platform.environment['MUZHAO_ORT_DLL'];
  if (override != null && override.isNotEmpty) return;
  // 插件已是 path 依赖（native/vendor/onnxruntime_flutter，ORT 1.29）：
  // ensureOrtRuntimeLoaded 会按 package_config 解析到它。pub cache 里残留的
  // hosted 1.4.1（ORT 1.15.1）不能再预载，否则旧库抢先进场、升级静默失效。
  ort.ensureOrtRuntimeLoaded();
}

class _Cfg {
  _Cfg(this.label, this.threads, this.apply);

  final String label;
  final int threads;

  /// 设置 bench 钩子（forceEp 之外的）。
  final void Function() apply;
}

void _resetHooks() {
  ort.debugForceEp = null;
  ort.debugInterOpThreads = null;
  ort.debugDisableMemPattern = false;
  ort.debugParallelExecutionMode = false;
  ort.debugDisableCpuMemArena = false;
  ort.debugSetDenormalAsZero = false;
  ort.debugOptOutEnvAllocator = false;
  ort.debugSkipEnvAllocatorRegistration = false;
  ort.debugUsePluginSessionCreation = false;
}

String _modelPath() {
  final sep = Platform.pathSeparator;
  // ③ A/B：MUZHAO_MODEL_DIR 指到候选模型目录（文件名仍为
  // birefnet_lite_1024_int8.onnx），不覆盖仓库里的现役模型。
  final dir = Platform.environment['MUZHAO_MODEL_DIR'];
  if (dir != null && dir.isNotEmpty) {
    return '$dir${sep}birefnet_lite_1024_int8.onnx';
  }
  return '${Directory.current.path}${sep}assets${sep}models$sep'
      'birefnet_lite_1024_int8.onnx';
}
/// 对一批配置（≤3 个常驻会话）做轮询采样并打印结果。
void _runBatch(List<_Cfg> cfgs) {
  assert(cfgs.length <= 3);
  final input = Float32List(1 * 3 * 1024 * 1024);
  const shape = <int>[1, 3, 1024, 1024];
  final sessions = <int>[];
  for (final c in cfgs) {
    _resetHooks();
    ort.debugForceEp = 'cpu'; // 本机捆绑 dll 无 XNNPACK（首版探针已证实）
    c.apply();
    sessions.add(ort.createSession(_modelPath(), threads: c.threads).address);
  }  try {
    final samples = List.generate(cfgs.length, (_) => <int>[]);
    const rounds = 4;
    const runsPerRound = 2;
    for (var round = 0; round < rounds; round++) {
      for (var ci = 0; ci < cfgs.length; ci++) {
        for (var r = 0; r < runsPerRound; r++) {
          final warm = round == 0 && r == 0;
          try {
            final sw = Stopwatch()..start();
            final outs =
                ort.runFloatInput(sessions[ci], input, shape, const []);
            sw.stop();
            for (final o in outs) {
              o?.release();
            }
            if (!warm) samples[ci].add(sw.elapsedMilliseconds);
          } catch (e) {
            stdout.writeln('${cfgs[ci].label} run FAILED: $e');
          }
        }
      }
    }
    for (var ci = 0; ci < cfgs.length; ci++) {
      final s = samples[ci]..sort();
      if (s.isEmpty) {
        stdout.writeln('${cfgs[ci].label}: ALL RUNS FAILED');
        continue;
      }
      final med = s[s.length ~/ 2];
      final p95 = s[math.max(0, (s.length * 0.95).ceil() - 1)];
      stdout.writeln('RESULT ${cfgs[ci].label}: n=${s.length} '
          'median=${med}ms p95=${p95}ms min=${s.first}ms');
    }
    // 批次级进程峰值（RSS 高水位）：内存 cliff 归因用。多会话常驻时是
    // 累计口径；单会话批次（single t6）即该配置的峰值。
    stdout.writeln('RESULT peakRssMb=${ProcessInfo.maxRss ~/ (1024 * 1024)}');
  } finally {
    for (final s in sessions) {
      ort.releaseSession(s);
    }
  }
}

void main() {
  setUpAll(() {
    _preloadHostOnnxRuntime();
    final sep = Platform.pathSeparator;
    ort.debugModelDirectory =
        '${Directory.current.path}${sep}assets${sep}models';
    ort.ensureOrtRuntimeLoaded();
    // 版本自证：每次扫参输出实际加载的 ORT 版本（A/B 口径的第一行防线）。
    // System32 异版 dll 劫持过一次（PITFALLS），这行不是装饰。
    stdout.writeln('ORT version = ${ort.ortVersionString()} '
        'from ${ort.ortLoadedFrom}');
  });

  test('batch1 threads', () {
    _runBatch(<_Cfg>[
      _Cfg('t4 baseline', 4, () {}),
      _Cfg('t6', 6, () {}),
      _Cfg('t8', 8, () {}),
    ]);
  });

  test('batch2 knobs on t6', () {
    _runBatch(<_Cfg>[
      _Cfg('t6 nomempattern', 6, () => ort.debugDisableMemPattern = true),
      _Cfg('t6 daz', 6, () => ort.debugSetDenormalAsZero = true),
      _Cfg('t6 parallel inter2', 6, () {
        ort.debugParallelExecutionMode = true;
        ort.debugInterOpThreads = 2;
      }),
    ]);
  });

  // 1.29 专用批次（插件捆绑 dll 的 1.15.1 无 XNNPACK，跑了也是 cpu 降级）。
  test('batch3 xnnpack', () {
    _runBatch(<_Cfg>[
      _Cfg('xnnpack t4', 4, () => ort.debugForceEp = 'xnnpack'),
      _Cfg('xnnpack t6', 6, () => ort.debugForceEp = 'xnnpack'),
      _Cfg('xnnpack t8', 8, () => ort.debugForceEp = 'xnnpack'),
    ]);
  });

  // A/B 专用：单配置短测（1 预热 + 7 计时）。跨 dll 比较靠多次交替调用
  // 本测试（MUZHAO_ORT_DLL 切换），负载漂移对两边均等。
  test('single t6', () {
    _runBatch(<_Cfg>[
      _Cfg('t6', 6, () {}),
    ]);
  });
}
