/// 木照 MuZhao — WorkBufferPool 池占用审计（开发期工装，不进发布路径）。
///
/// 背景：G4 r3 v4 终裁，4.7 峰值 638.9MB（阈值 450）、4.8 回落 +135.8MB，
/// 与第一版池「按尺寸键控、永不收缩」的跨图滞留在时间线上吻合。修复后
/// （32MB 总预算 + LRU + 换图即清空），本工装用 20 张**尺寸各异**的合成图
/// 连续过 compose，逐图读池内驻留字节数，验证：
///
/// 1. 驻留 ≤ 池预算（[WorkBufferPool.kMaxPoolBudget]）；
/// 2. **驻留不随图数增长**（换图即清空 → 每张图结束后的驻留只取决于本图
///    触过的规格键，与历史图数无关）；
/// 3. LRU 淘汰计数合理（本序列不该触发预算淘汰，若触发说明规格键总量
///    已逼近预算，需要重新评估）。
///
/// 运行方式（项目根目录）：
///
/// ```
/// flutter test lib/core/imaging/dev_pool_audit.dart
/// ```
///
/// 20 张模拟 qa-batch workload（人像/多人脸交替、输入尺寸各异 —— 尺寸是
/// 第一版池滞留的放大器，这里每张都不同）。模拟器上的整进程 PSS 复测
/// 归 qa-batch / ml-porting 的 memcheck 编排（native/bench/ml_release_memcheck.py），
/// 本工装只审计池本身。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

// flutter_test 是 dev_dependency；本文件是纯开发期工装，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_engine.dart';
import 'compose_only_engine.dart';

const Timeout _long = Timeout(Duration(minutes: 20));

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
      final double a =
          ((1.0 - dHead) * 40.0 / 3.0 + 0.5).clamp(0.0, 1.0).toDouble();
      alpha[ai] = (a * 255).round().clamp(0, 255);
      final List<int> col = y < chinY + height * 0.08 ? skin : cloth;
      final int p = ai * 4;
      for (int ch = 0; ch < 3; ch++) {
        rgba[p + ch] = (col[ch] * a + bg[ch] * (1 - a)).round();
      }
      rgba[p + 3] = 255;
    }
  }
  return MattingResult(
      rgba: rgba, alpha: alpha, width: width, height: height);
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
        height: headH),
    headTopY: headTop,
    chinY: headTop + headH,
    rollDeg: 0.0,
    confidence: 1.0,
  );
}

void main() {
  test('WorkBufferPool 池占用审计（20 图，尺寸各异）', () async {
    final ComposeOnlyEngine engine = ComposeOnlyEngine();
    const BackgroundStyle bgA =
        BackgroundStyle(id: 'audit_blue', nameZh: '审计蓝', colorTop: 0xFF134A85);
    const BackgroundStyle bgB = BackgroundStyle(
        id: 'audit_grad',
        nameZh: '审计渐变',
        colorTop: 0xFF134A85,
        colorBottom: 0xFF6FA8DC);

    final StringBuffer log = StringBuffer();
    log.writeln('budget_bytes=${ComposeEngineMixin.poolBudgetBytes}');

    int? residencyAfterFirstImage;
    int maxResidency = 0;
    bool failed = false;

    for (int i = 0; i < 20; i++) {
      // 尺寸各异（人像竖构图为主，混横构图），模拟 batch 里输入尺寸连续变化
      // —— 这正是第一版池跨图滞留的放大器。
      final int w = 1300 + (i * 137) % 1100;
      final int h = w + 350 + (i * 211) % 800;
      final MattingResult m = _synthMatting(
        width: w,
        height: h,
        headCx: w * (0.35 + (i % 5) * 0.07),
        headTopY: h * 0.12,
        chinY: h * 0.34,
        headWidth: w * 0.18,
      );
      final FaceInfo face = _faceFromAlpha(m);

      for (final PhotoSpec spec in photoSpecs) {
        for (final BackgroundStyle style in <BackgroundStyle>[bgA, bgB]) {
          await engine.compose(matting: m, spec: spec, style: style, face: face);
        }
      }

      final int residency = engine.poolResidencyBytes;
      final int entries = engine.poolResidentEntries;
      maxResidency = math.max(maxResidency, residency);
      residencyAfterFirstImage ??= residency;
      log.writeln('img$i ${w}x$h residency=$residency entries=$entries '
          'evictions=${engine.poolEvictions} '
          'canvas=${engine.encodeCanvasEntries}');

      // 判定 1：驻留 ≤ 预算。
      if (residency > ComposeEngineMixin.poolBudgetBytes) {
        failed = true;
        log.writeln('FAIL img$i residency $residency > budget');
      }
      // 判定 2：不随图数增长 —— 每张图结束后的驻留应与首图一致
      //（同一组规格键；换图清空后重新填的也是同样的键）。
      if (residency != residencyAfterFirstImage) {
        failed = true;
        log.writeln('FAIL img$i residency $residency != baseline '
            '$residencyAfterFirstImage（跨图滞留？）');
      }
      // 判定 3：本序列不该触发预算淘汰。
      if (engine.poolEvictions > 0) {
        failed = true;
        log.writeln('FAIL img$i 出现预算淘汰（键总量逼近预算，需复核）');
      }
    }
    log.writeln('max_residency=$maxResidency budget='
        '${ComposeEngineMixin.poolBudgetBytes} '
        'verdict=${failed ? 'FAIL' : 'PASS'}');
    // ignore: avoid_print
    print('POOL-AUDIT-BEGIN\n$log POOL-AUDIT-END');
    expect(failed, isFalse, reason: '池占用审计未通过，见 POOL-AUDIT 输出');
  }, timeout: _long);
}
