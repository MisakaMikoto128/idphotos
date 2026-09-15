/// 木照 MuZhao — compose 段内存剖面（开发期工装，不进发布路径）。
///
/// 背景：G4 r5，4.7 峰值 570.4MB，其中瞬态 +65.6MB（Private Other）被
/// ml-porting 的分段实测排除在引擎解码/抠图之外，锁定在 compose 段。
/// 本工装对 compose 全链路（字段估计 → 去色边 → 预滤波 → 渲染 → 编码）
/// 做逐段记账（[ImagingLedger]，精确字节）+ 进程 RSS 对照
/// （`ProcessInfo.currentRss` / `maxRss`，host 采样）。
///
/// 两个用例对应 qa-batch 的大头：
/// - A：4032×3024 人像（12.2MP，QA item 1979d869 同量级）；
/// - B：4958×7017 扫描件（34.8MP，batch 里最大的输入）。
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
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

// flutter_test 是 dev_dependency；本文件是纯开发期工装，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_only_engine.dart';
import 'mem_ledger.dart';

const Timeout _long = Timeout(Duration(minutes: 30));

int get _rss => ProcessInfo.currentRss;
int get _maxRss => ProcessInfo.maxRss;

String _mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);

MattingResult _synthMatting({
  required int width,
  required int height,
  required double headCx,
  required double headTopY,
  required double chinY,
  required double headWidth,
}) {
  final Uint8List rgba = Uint8List(width * height * 4);
  final Uint8List alpha = Uint8List(width * height);
  const List<int> bg = <int>[26, 92, 176];
  const List<int> cloth = <int>[46, 54, 70];
  final List<int> skin = <int>[
    200 + (headCx.toInt() % 40),
    170 + (headTopY.toInt() % 40),
    130 + (chinY.toInt() % 40),
  ];
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int ai = y * width + x;
      final double dx = (x + 0.5 - headCx) / (headWidth / 2);
      final double dyH =
          (y + 0.5 - (headTopY + chinY) / 2) / ((chinY - headTopY) / 2);
      final double dHead = math.sqrt(dx * dx + dyH * dyH);
      final double a = ((1.0 - dHead) * 40.0 / 3.0 + 0.5)
          .clamp(0.0, 1.0)
          .toDouble();
      alpha[ai] = (a * 255).round().clamp(0, 255);
      final List<int> col = y < chinY + height * 0.08 ? skin : cloth;
      final int p = ai * 4;
      for (int ch = 0; ch < 3; ch++) {
        rgba[p + ch] = (col[ch] * a + bg[ch] * (1 - a)).round();
      }
      rgba[p + 3] = 255;
    }
  }
  return MattingResult(rgba: rgba, alpha: alpha, width: width, height: height);
}

FaceInfo _faceFromAlpha(MattingResult m) {
  int minY = 1 << 30, maxY = -1;
  double sx = 0;
  int sn = 0;
  for (int y = 0; y < m.height; y++) {
    final int row = y * m.width;
    for (int x = 0; x < m.width; x++) {
      if (m.alpha[row + x] > 128) {
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        sx += x;
        sn++;
      }
    }
  }
  if (maxY < 0) {
    minY = 0;
    maxY = m.height - 1;
  }
  final double headTop = minY.toDouble();
  final int bboxH = maxY - minY + 1;
  final double headH = math.max(8.0, bboxH * 0.5);
  final double cx = sn > 0 ? sx / sn : m.width / 2.0;
  return FaceInfo(
    box: Rect.fromCenter(
      center: Offset(cx, headTop + headH / 2),
      width: headH * 0.8,
      height: headH,
    ),
    headTopY: headTop,
    chinY: headTop + headH,
    rollDeg: 0.0,
    confidence: 1.0,
  );
}

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

  ImagingLedger.reset();
  ImagingLedger.enabled = true;
  final int rss0 = _rss;
  final StringBuffer caseLog = StringBuffer();

  final MattingResult m = _synthMatting(
    width: width,
    height: height,
    headCx: width * 0.42,
    headTopY: height * 0.12,
    chinY: height * 0.34,
    headWidth: width * 0.18,
  );
  final FaceInfo face = _faceFromAlpha(m);
  final int rss1 = _rss;
  caseLog.writeln(
    '[$label] 输入就绪 rss=${_mb(rss1)} '
    '(Δ+${_mb(math.max(0, rss1 - rss0))}) ledger:',
  );
  caseLog.writeln(ImagingLedger.report().trimRight());

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
          'peakRss=${_mb(_maxRss)} ledger:',
        );
        caseLog.writeln(ImagingLedger.report().trimRight());
      }
    }
  }
  caseLog.writeln(
    '[$label] 全部 $n 次合成后 rss=${_mb(_rss)} '
    'peakRss=${_mb(_maxRss)} poolResidency='
    '${_mb(engine.poolResidencyBytes)} ledger:',
  );
  caseLog.writeln(ImagingLedger.report().trimRight());
  ImagingLedger.enabled = false;
  log.writeln(caseLog);
}

void main() {
  test('compose 段内存剖面（A 4032x3024 / B 4958x7017）', () async {
    final StringBuffer log = StringBuffer();
    await _profileCase(log, 'A-portrait-12MP', 4032, 3024);
    await _profileCase(log, 'B-scan-35MP', 4958, 7017);
    // ignore: avoid_print
    print('MEMPROFILE-BEGIN\n$log MEMPROFILE-END');
  }, timeout: _long);
}
