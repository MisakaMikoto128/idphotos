/// 木照 MuZhao — compose 段内存剖面（开发期工装，不进发布路径）。
///
/// 背景：G4 r5，4.7 峰值 570.4MB，其中瞬态 +65.6MB（Private Other）被
/// ml-porting 的分段实测排除在引擎解码/抠图之外，锁定在 compose 段。
/// 本工装对 compose 全链路（字段估计 → 去色边 → 预滤波 → 渲染 → 编码）
/// 做进程 RSS 对照（`ProcessInfo.currentRss` / `maxRss`，host 采样）。
/// （原先还挂过大缓冲逐段记账 mem_ledger，c669d36 回退后零挂点、账本恒 0，
/// simplify 已删除；重挂需重新实现 hook，见 docs/PITFALLS.md。）
///
/// 两个用例对应 qa-batch 的大头（**工作分辨率口径**，G4.7 改造后）：
/// compose 的入参只有 [MattingResult]，其 rgba/alpha 已由 ml-porting 降采样到
/// 引擎工作分辨率（长边 ≤ kEngineMaxEdge=2048，见 `lib/core/matting/image_ops.dart`）。
/// 本工装喂的是引擎真实会产出的那两种尺寸：
/// - A：2048×1536 —— 12MP 人像（QA item 1979d869 的 4032×3024）降采样后；
/// - B：1447×2048 —— 4958×7017 扫描件（batch 里最大的输入）降采样后。
///
/// 归因注记（G4 最后一轮的谜题）：此前报告的「decontaminate premul 12MP
/// 48.8MB」不是管线路径 —— compose 从不接触原图字节，全部大缓冲都按
/// matting.width×height 缩放；那个数字来自本工装旧版直接构造
/// 4032×3024 的合成输入（第 190 行 `_profileCase(log, 'A', 4032, 3024)`），
/// 量的是「假如引擎不降采样」的假想工况。kEngineMaxEdge 落地后该工况
/// 在真实管线中不存在。
///
/// 每个用例跑 7 规格 × 2 底色（模拟一个数据项的真实合成次数），三个检查点：
/// 1. 抠图结果就绪后（相当于进入 compose 段前的基线）；
/// 2. 首次 compose 后（整项存续缓存全部建立）；
/// 3. 全部 compose 后。
///
/// 运行方式（项目根目录）：
///
/// ```
/// flutter test lib/core/imaging/dev_compose_memprofile.dart
/// ```
library;

import 'dart:io';
import 'dart:math' as math;

// flutter_test 是 dev_dependency；本文件是纯开发期工装，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_only_engine.dart';
import 'dev_synth.dart';

const Timeout _long = Timeout(Duration(minutes: 30));

int get _rss => ProcessInfo.currentRss;
int get _maxRss => ProcessInfo.maxRss;

String _mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);

Future<void> _profileCase(
  StringBuffer log,
  String label,
  int width,
  int height,
) async {
  final ComposeOnlyEngine engine = ComposeOnlyEngine();
  const BackgroundStyle bgA = BackgroundStyle(
    id: 'prof_blue',
    nameZh: '剖面蓝',
    colorTop: 0xFF134A85,
  );
  const BackgroundStyle bgB = BackgroundStyle(
    id: 'prof_grad',
    nameZh: '剖面渐变',
    colorTop: 0xFF134A85,
    colorBottom: 0xFF6FA8DC,
  );

  final int rss0 = _rss;
  final StringBuffer caseLog = StringBuffer();

  final MattingResult m = synthMatting(
    width: width,
    height: height,
    headCx: width * 0.42,
    headTopY: height * 0.12,
    chinY: height * 0.34,
    headWidth: width * 0.18,
    neckOffset: height * 0.08,
  );
  final FaceInfo face = faceFromAlpha(m);
  final int rss1 = _rss;
  caseLog.writeln(
    '[$label] 输入就绪 rss=${_mb(rss1)} '
    '(Δ+${_mb(math.max(0, rss1 - rss0))})',
  );

  int peakRss = rss1;
  int n = 0;
  for (final PhotoSpec spec in photoSpecs) {
    for (final BackgroundStyle style in <BackgroundStyle>[bgA, bgB]) {
      await engine.compose(matting: m, spec: spec, style: style, face: face);
      n++;
      peakRss = math.max(peakRss, _rss);
      if (n == 2) {
        caseLog.writeln(
          '[$label] 首规格 2 次合成后 rss=${_mb(_rss)} '
          'peakRss=${_mb(_maxRss)}',
        );
      }
    }
  }
  caseLog.writeln(
    '[$label] 全部 $n 次合成后 rss=${_mb(_rss)} '
    'peakRss=${_mb(_maxRss)} poolResidency='
    '${_mb(engine.poolResidencyBytes)}',
  );
  log.writeln(caseLog);
}

void main() {
  test('compose 段内存剖面（A 2048x1536 / B 1447x2048，工作分辨率口径）', () async {
    final StringBuffer log = StringBuffer();
    await _profileCase(log, 'A-portrait-12MP-downsampled', 2048, 1536);
    await _profileCase(log, 'B-scan-35MP-downsampled', 1447, 2048);
    // ignore: avoid_print
    print('MEMPROFILE-BEGIN\n$log MEMPROFILE-END');
  }, timeout: _long);
}
