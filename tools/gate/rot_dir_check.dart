// tools/gate/rot_dir_check.dart
//
// 旋转符号口径的最小实测（属 gatekeeper 势力范围）。
//
// 为什么单独留一个文件：`docs/PITFALLS.md` 里"摆正角符号链"那条的关键论据是
// 「`img.copyRotate(angle: +10)` 是顺时针」，这是整个回正残差公式成立的前提。
// 把它写成可复跑的一行命令，别人就不用再靠印象推一遍（PIL 的 rotate 正角是
// 逆时针，image 包相反 —— 凭印象推必错）。
//
// 运行：
// ```
// dart run tools/gate/rot_dir_check.dart
// ```
// 期望输出：angle=+10 时白点相对中心的角度比 angle=0 时**变大**（y 轴向下，
// 角度增大 = 顺时针）。

import 'dart:math' as math;

import 'package:image/image.dart' as img;

void main() {
  // 100×100 黑图，左中 (10,50) 一个白点。
  final img.Image im = img.Image(width: 100, height: 100);
  img.fill(im, color: img.ColorRgb8(0, 0, 0));
  im.setPixelRgb(10, 50, 255, 255, 255);

  double? base;
  for (final double a in <double>[0, 10, -10]) {
    final img.Image r =
        img.copyRotate(im, angle: a, interpolation: img.Interpolation.nearest);
    int bx = -1;
    int by = -1;
    for (int y = 0; y < r.height; y++) {
      for (int x = 0; x < r.width; x++) {
        if (r.getPixel(x, y).r > 200) {
          bx = x;
          by = y;
        }
      }
    }
    final double cx = r.width / 2.0 - 0.5;
    final double cy = r.height / 2.0 - 0.5;
    final double ang = math.atan2(by - cy, bx - cx) * 180 / math.pi;
    base ??= ang;
    // 角度差归一到 (−180, 180]
    double d = ang - base!;
    while (d > 180) {
      d -= 360;
    }
    while (d <= -180) {
      d += 360;
    }
    // ignore: avoid_print
    print('copyRotate(angle: $a)  size=${r.width}x${r.height}  '
        '白点=($bx,$by)  相对中心角=${ang.toStringAsFixed(1)}°  '
        '相对 angle=0 变化=${d.toStringAsFixed(1)}°');
  }
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print('判读：y 轴向下时角度增大 = 顺时针。'
      'angle=+10 的"变化"应为正 ≈ +8~10°，即 copyRotate 正角 = 顺时针。');
}
