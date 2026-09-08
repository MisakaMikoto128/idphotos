/// 确定性噪声。
///
/// 材质绘制**绝不能用 `dart:math` 的 `Random()`**：截图流水线要求同一场景每次
/// 画出同一帧（CONTRACTS §7.1），未播种的随机数会让 golden 截图逐轮漂移。
/// 这里用整数哈希产生可重复的伪随机值，纯函数、无状态。
///
/// 势力范围：ui-woodcraft。
library;

/// 32 位整数哈希（Thomas Wang 变体），返回 `[0, 1)`。
double hash1(int x) {
  int h = x & 0x7FFFFFFF;
  h = (h ^ 61) ^ (h >> 16);
  h = (h + (h << 3)) & 0x7FFFFFFF;
  h = h ^ (h >> 4);
  h = (h * 0x27d4eb2d) & 0x7FFFFFFF;
  h = h ^ (h >> 15);
  return (h & 0xFFFFFF) / 0x1000000;
}

/// 二维哈希。
double hash2(int x, int y) => hash1(x * 73856093 ^ y * 19349663);

/// 一维平滑值噪声，周期由 [scale] 控制（输入单位：逻辑像素）。
double valueNoise1(double t, int seed) {
  final double p = t;
  final int i = p.floor();
  final double f = p - i;
  // smoothstep，避免线性插值造成的折线感
  final double u = f * f * (3 - 2 * f);
  final double a = hash2(i, seed);
  final double b = hash2(i + 1, seed);
  return a + (b - a) * u;
}

/// 分形叠加（fBm）。返回 `[0, 1)` 附近。
double fbm1(double t, int seed, {int octaves = 4}) {
  double sum = 0;
  double amp = 0.5;
  double freq = 1;
  double norm = 0;
  for (int o = 0; o < octaves; o++) {
    sum += amp * valueNoise1(t * freq, seed + o * 977);
    norm += amp;
    amp *= 0.5;
    freq *= 2.07; // 非整数倍频，避免各阶极值对齐产生规则条纹
  }
  return sum / norm;
}

/// 以 0 为中心的 fBm，范围约 `[-1, 1]`。
double fbm1c(double t, int seed, {int octaves = 4}) =>
    fbm1(t, seed, octaves: octaves) * 2 - 1;
