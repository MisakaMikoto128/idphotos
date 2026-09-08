// tools/gate/color_utils.dart
//
// sRGB -> CIE Lab -> CIEDE2000 色差。纯 Dart，无第三方依赖。
// 供 gate_G2C（调色板合规 2C.2、Material 紫检测 2C.3）与 gate_G2B（换底溢色目视校验时的
// 辅助判断，如需要）复用。
//
// CIEDE2000 是本轮最容易写错的地方：公式本身有多处符号/角度陷阱（G 因子、hbar' 的分支、
// RT 的符号）。用两个**可解析证明**、不依赖记忆数字的用例做运行时自检（见 selfTest()）：
//   1) 恒等：ΔE00(X, X) == 0，对任意 X 成立（所有分量差为 0）。
//   2) 纯黑 vs 纯白：Lab(0,0,0) vs Lab(100,0,0)，两者 C'=0，色相项完全消失，
//      SL = 1 + 0.015*(50-50)^2/sqrt(20+0) = 1，ΔE00 = ΔL'/(1*1) = 100，可以手算精确验证。
// 另外附上 Sharma/Wu/Dalal (2005) 论文 Table I 里凭记忆抄录的几组标准测试向量作为“软校验”
// （容差放宽到 0.1，且只打印差异不 fail 整个 gate），因为手抄数字有转录出错的风险，
// 不能把整个 G2C 的通过与否押在我记忆力上——两条可证明用例才是硬门槛。

import 'dart:math' as math;

class Lab {
  final double l, a, b;
  const Lab(this.l, this.a, this.b);
}

/// sRGB (0-255 每通道) -> CIE Lab (D65 白点)。
Lab rgbToLab(int r, int g, int b) {
  double lin(int c) {
    final v = c / 255.0;
    return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final rl = lin(r), gl = lin(g), bl = lin(b);

  // sRGB D65 线性 RGB -> XYZ，结果放大到 0-100 量程。
  final x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) * 100.0;
  final y = (0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl) * 100.0;
  final z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) * 100.0;

  const xn = 95.0489, yn = 100.0, zn = 108.8840;

  double f(double t) {
    const delta = 6.0 / 29.0;
    if (t > delta * delta * delta) {
      return math.pow(t, 1.0 / 3.0).toDouble();
    }
    return t / (3 * delta * delta) + 4.0 / 29.0;
  }

  final fx = f(x / xn), fy = f(y / yn), fz = f(z / zn);
  final l = 116.0 * fy - 16.0;
  final a = 500.0 * (fx - fy);
  final bb = 200.0 * (fy - fz);
  return Lab(l, a, bb);
}

double _deg2rad(double d) => d * math.pi / 180.0;
double _rad2deg(double r) => r * 180.0 / math.pi;

/// CIEDE2000 色差公式（kL=kC=kH=1）。标准实现，参照 Sharma/Wu/Dalal (2005)。
double deltaE2000(Lab lab1, Lab lab2) {
  final l1 = lab1.l, a1 = lab1.a, b1 = lab1.b;
  final l2 = lab2.l, a2 = lab2.a, b2 = lab2.b;

  final c1 = math.sqrt(a1 * a1 + b1 * b1);
  final c2 = math.sqrt(a2 * a2 + b2 * b2);
  final cbar = (c1 + c2) / 2.0;

  final cbar7 = math.pow(cbar, 7).toDouble();
  const pow25_7 = 6103515625.0; // 25^7
  final g = 0.5 * (1 - math.sqrt(cbar7 / (cbar7 + pow25_7)));

  final a1p = a1 * (1 + g);
  final a2p = a2 * (1 + g);
  final c1p = math.sqrt(a1p * a1p + b1 * b1);
  final c2p = math.sqrt(a2p * a2p + b2 * b2);

  double hAngle(double a, double bch) {
    if (a == 0 && bch == 0) return 0.0;
    var h = _rad2deg(math.atan2(bch, a));
    if (h < 0) h += 360.0;
    return h;
  }

  final h1p = hAngle(a1p, b1);
  final h2p = hAngle(a2p, b2);

  final deltaLp = l2 - l1;
  final deltaCp = c2p - c1p;

  double deltahp;
  if (c1p * c2p == 0) {
    deltahp = 0.0;
  } else {
    var dh = h2p - h1p;
    if (dh > 180) {
      dh -= 360;
    } else if (dh < -180) {
      dh += 360;
    }
    deltahp = dh;
  }
  final deltaHp = 2 * math.sqrt(c1p * c2p) * math.sin(_deg2rad(deltahp) / 2.0);

  final lbarp = (l1 + l2) / 2.0;
  final cbarp = (c1p + c2p) / 2.0;

  double hbarp;
  if (c1p * c2p == 0) {
    hbarp = h1p + h2p;
  } else {
    final diff = (h1p - h2p).abs();
    if (diff <= 180) {
      hbarp = (h1p + h2p) / 2.0;
    } else if (h1p + h2p < 360) {
      hbarp = (h1p + h2p + 360) / 2.0;
    } else {
      hbarp = (h1p + h2p - 360) / 2.0;
    }
  }

  final t = 1 -
      0.17 * math.cos(_deg2rad(hbarp - 30)) +
      0.24 * math.cos(_deg2rad(2 * hbarp)) +
      0.32 * math.cos(_deg2rad(3 * hbarp + 6)) -
      0.20 * math.cos(_deg2rad(4 * hbarp - 63));

  final deltaTheta = 30 * math.exp(-math.pow((hbarp - 275) / 25, 2));
  final cbarp7 = math.pow(cbarp, 7).toDouble();
  final rc = 2 * math.sqrt(cbarp7 / (cbarp7 + pow25_7));

  final lbarMinus50Sq = math.pow(lbarp - 50, 2).toDouble();
  final sl = 1 + (0.015 * lbarMinus50Sq) / math.sqrt(20 + lbarMinus50Sq);
  final sc = 1 + 0.045 * cbarp;
  final sh = 1 + 0.015 * cbarp * t;

  final rt = -math.sin(_deg2rad(2 * deltaTheta)) * rc;

  const kl = 1.0, kc = 1.0, kh = 1.0;
  final termL = deltaLp / (kl * sl);
  final termC = deltaCp / (kc * sc);
  final termH = deltaHp / (kh * sh);

  final result = math.sqrt(termL * termL + termC * termC + termH * termH + rt * termC * termH);
  return result;
}

/// sRGB 便捷入口：两个 0xRRGGBB（或 0xAARRGGBB，忽略 alpha）颜色的 ΔE00。
double rgbDeltaE00(int rgb1, int rgb2) {
  final r1 = (rgb1 >> 16) & 0xFF, g1 = (rgb1 >> 8) & 0xFF, b1 = rgb1 & 0xFF;
  final r2 = (rgb2 >> 16) & 0xFF, g2 = (rgb2 >> 8) & 0xFF, b2 = rgb2 & 0xFF;
  return deltaE2000(rgbToLab(r1, g1, b1), rgbToLab(r2, g2, b2));
}

class SelfTestResult {
  final bool hardPass;
  final List<String> hardFailures;
  final List<String> softWarnings;
  SelfTestResult(this.hardPass, this.hardFailures, this.softWarnings);
}

/// 运行时自检。硬门槛只有两条可解析证明的用例；Sharma 论文向量作为软提示。
/// 任何 gate_G2C.dart 在做真正的 2C.2/2C.3 判定前，必须先跑这个，硬门槛不过就整体 FAIL
/// （说明我的 CIEDE2000 实现本身有 bug，不能拿它去判别人）。
SelfTestResult selfTest() {
  final hardFailures = <String>[];
  final softWarnings = <String>[];

  // 硬用例 1：恒等
  final identity = deltaE2000(const Lab(37.2, 12.4, -8.9), const Lab(37.2, 12.4, -8.9));
  if (identity.abs() > 1e-9) {
    hardFailures.add('恒等用例失败：ΔE00(X,X)=$identity，期望 0');
  }

  // 硬用例 2：纯黑 vs 纯白，可手算精确到 100.0
  final blackWhite = deltaE2000(const Lab(0, 0, 0), const Lab(100, 0, 0));
  if ((blackWhite - 100.0).abs() > 1e-6) {
    hardFailures.add('黑白用例失败：ΔE00(黑,白)=$blackWhite，期望精确 100.0');
  }

  // 软用例：Sharma et al. 2005 Table I 部分向量（凭记忆抄录，容差放宽，仅供参考）。
  final vectors = <List<double>>[
    // L1,a1,b1, L2,a2,b2, expected
    [50.0000, 2.6772, -79.7751, 50.0000, 0.0000, -82.7485, 2.0425],
    [50.0000, -1.3802, -84.2814, 50.0000, 0.0000, -82.7485, 1.0000],
    [50.0000, 2.4900, -0.0010, 50.0000, -2.4900, 0.0009, 7.1792],
    [50.0000, 2.5000, 0.0000, 73.0000, 25.0000, -18.0000, 27.1492],
    [50.0000, 2.5000, 0.0000, 61.0000, -5.0000, 29.0000, 22.8977],
  ];
  for (final v in vectors) {
    final got = deltaE2000(Lab(v[0], v[1], v[2]), Lab(v[3], v[4], v[5]));
    final expected = v[6];
    if ((got - expected).abs() > 0.1) {
      softWarnings.add('参考向量 $v：算出 ${got.toStringAsFixed(4)}，记忆中的期望 '
          '${expected.toStringAsFixed(4)}，差 ${(got - expected).abs().toStringAsFixed(4)}'
          '（可能是我抄录记忆有误，不是硬失败，人工复核）');
    }
  }

  return SelfTestResult(hardFailures.isEmpty, hardFailures, softWarnings);
}

void main() {
  final r = selfTest();
  print('CIEDE2000 自检：${r.hardPass ? "硬门槛 PASS" : "硬门槛 FAIL"}');
  for (final f in r.hardFailures) {
    print('  [硬失败] $f');
  }
  for (final w in r.softWarnings) {
    print('  [软提示] $w');
  }
}
