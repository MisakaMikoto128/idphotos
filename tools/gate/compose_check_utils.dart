// tools/gate/compose_check_utils.dart
//
// G2B 设备端评测用的像素级小工具，基于 package:image（项目已声明的依赖，
// 纯 Dart，设备端/主机端都能跑）。职责：在合成图里找"标记色条"的位置、
// 数偏色像素。所有函数只返回**原始测量数字**，阈值判断留在 gate_G2B.dart。
//
// 设计背景见 integration_test/compose_eval_test.dart 头部注释：合成引擎测试
// 用的是我自己构造的"合成人像"（灰底矩形 + 头顶青色条 + 下巴品红条），
// 不依赖 ml-porting 的真实抠图结果，也不依赖真实人脸检测——G2B 只测 imaging
// 的裁剪/换底/编码几何逻辑，两者解耦。

import 'dart:math' as math;

import 'package:image/image.dart' as img;

class ColorMatch {
  final int x, y;
  const ColorMatch(this.x, this.y);
}

/// 找出图中与 [target] 颜色距离在 [tolerance] 内的所有像素坐标（简单欧氏距离，逐通道）。
List<ColorMatch> findColorMatches(img.Image image, int targetR, int targetG, int targetB,
    {int tolerance = 40}) {
  final matches = <ColorMatch>[];
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      final dr = p.r - targetR, dg = p.g - targetG, db = p.b - targetB;
      final distSq = dr * dr + dg * dg + db * db;
      if (distSq <= tolerance * tolerance) {
        matches.add(ColorMatch(x, y));
      }
    }
  }
  return matches;
}

class Centroid {
  final double x, y;
  final int count;
  const Centroid(this.x, this.y, this.count);
}

Centroid? centroidOf(List<ColorMatch> matches) {
  if (matches.isEmpty) return null;
  double sx = 0, sy = 0;
  for (final m in matches) {
    sx += m.x;
    sy += m.y;
  }
  return Centroid(sx / matches.length, sy / matches.length, matches.length);
}

/// 用匹配像素里 x 最小和最大的两个点算倾角（度），用于 2B.8 摆正残差测量。
/// 返回 null 表示匹配点太少无法算倾角。
double? tiltAngleDeg(List<ColorMatch> matches) {
  if (matches.length < 2) return null;
  ColorMatch? leftmost, rightmost;
  for (final m in matches) {
    if (leftmost == null || m.x < leftmost.x) leftmost = m;
    if (rightmost == null || m.x > rightmost.x) rightmost = m;
  }
  if (leftmost == null || rightmost == null || leftmost.x == rightmost.x) return null;
  final dx = (rightmost.x - leftmost.x).toDouble();
  final dy = (rightmost.y - leftmost.y).toDouble();
  return math.atan2(dy, dx) * 180.0 / math.pi;
}
