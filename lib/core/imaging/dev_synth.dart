/// 木照 MuZhao — 开发期工装共享的合成输入（不进发布路径）。
///
/// `dev_pool_audit.dart` / `dev_compose_memprofile.dart` /
/// `dev_pool_bitcheck.dart` 三处原先各持一份逐字节相同的 `_synthMatting` /
/// `_faceFromAlpha` 拷贝（bitcheck 差一个 skin 参数），simplify 合并到此。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import '../api.dart';

/// 合成一张"软边椭圆头 + 颈肩、饱和蓝底"的人像抠图结果。
///
/// [skin] 缺省时按 [headCx]/[headTopY]/[chinY] 派生（audit/memprofile 的
/// 原行为，靠颜色区分内容）；bitcheck 传显式 skin。颈部色带从 [chinY]
/// 下移 [neckOffset] 像素开始（audit/memprofile 传 `height * 0.08`，
/// bitcheck 传 40）。
MattingResult synthMatting({
  required int width,
  required int height,
  required double headCx,
  required double headTopY,
  required double chinY,
  required double headWidth,
  List<int>? skin,
  required double neckOffset,
}) {
  skin ??= <int>[
    200 + (headCx.toInt() % 40),
    170 + (headTopY.toInt() % 40),
    130 + (chinY.toInt() % 40),
  ];
  final Uint8List rgba = Uint8List(width * height * 4);
  final Uint8List alpha = Uint8List(width * height);
  const List<int> bg = <int>[26, 92, 176];
  const List<int> cloth = <int>[46, 54, 70];
  final double neckY = chinY + neckOffset;
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
      final List<int> col = y < neckY ? skin : cloth;
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

/// 由 alpha 剪影反推 FaceInfo（与 dev_selfcheck.dart 同口径的简化版）。
FaceInfo faceFromAlpha(MattingResult m) {
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
