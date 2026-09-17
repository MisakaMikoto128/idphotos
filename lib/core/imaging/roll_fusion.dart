/// 木照 MuZhao — 多线融合估角（P0 歪斜修复接力第三棒）。
///
/// 纯数学，不依赖 `dart:ui` / `../api.dart`（输入是裸关键点数组），可用
/// `dart run` 单独测试，便于复算。
///
/// ## 设计与数据依据（out/tmp/roll_repro/lm_fusion_baseline.json，10 图实测）
///
/// YuNet 五关键点可以组成三条候选 roll 线（全部按 x 从小到大定向后取
/// atan2，符号口径与解码器 rollDeg 一致：正 = 头向观众右倾）：
///
/// - **眼线**：关键点对 0–3；
/// - **嘴线**：关键点对 6–9；
/// - **鼻轴**：鼻尖(4) 相对两眼中点的方向角 − 90°。
///
/// 实测结论（这是权重不为「三线等权中位」的依据）：
///
/// 1. **鼻轴有 −9°~+9° 的随 yaw/pitch 变化的系统偏置**（鼻尖方向不垂直于
///    眼线，偏置量因人而异：p1 +6.2、p2 −7.2、g05 −8.7、g07 +8.9）。它不是
///    独立的 roll 信号，等权进中位只会引入 ±4° 级噪声（p2 三线中位 −4.56，
///    比眼线 −3.91 更远离真值 0），**剔除出估计，只留作一致性诊断**。
/// 2. **嘴线与眼线强相关**（10 图 |eye−mouth| ≤ 1.17°），且在所有可判真值
///    的样本上嘴线误差 ≥ 眼线（p1：嘴 +0.71 / 眼 +0.84，同样错；p2 戴镜：
///    嘴 −4.56 比眼 −3.91 更差）。「眼镜/hooded 时上调嘴线权重」的假设被
///    实测否决——两条线共享同一失败模式（单眼 hooded 时该侧关键点被放到
///    上睑褶皱上），换线救不了。
/// 3. 因此生产策略：**眼线为主，嘴线在共识门内做小幅平均去抖**；
///    眼线不可用（退化）时回退嘴线；landmarks 整体不可用时回退解码器
///    rollDeg（旧路径）。共识门 [kLineConsensusDeg] 的作用是把「两条线各错
///    各的」的样本（p2 差 0.65°）挡在平均之外，避免把误差叠加。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 眼线/嘴线共识门（度）：|eye − mouth| 不超过它才做平均。
///
/// 实测 10 图眼嘴差分布 [0.01, 1.17]，损坏样本（p1 0.13 / p2 0.65）两线
/// **同错**、差值不大——任何门限都分不出它们，门的意义只在「别让分歧大的
/// 样本被平均推得更偏」。取 0.5 使 p2（0.65）保持旧路径不被劣化。
const double kLineConsensusDeg = 0.5;

/// 一次融合估角的完整结果（含诊断）。
class RollFusion {
  /// 最终采纳的摆正角（度）。恒有限。
  final double rollDeg;

  /// 估计来源：`'eye+mouth'`（共识门内平均）/ `'eye'` / `'mouth'`（眼线
  /// 退化时回退）/ `'legacy'`（无 landmarks，回退解码器 rollDeg）。
  final String source;

  /// 三线原始角（度，x 定向 atan2 口径）。不可用为 NaN。
  final double eyeDeg;
  final double mouthDeg;
  final double noseDeg;

  const RollFusion({
    required this.rollDeg,
    required this.source,
    required this.eyeDeg,
    required this.mouthDeg,
    required this.noseDeg,
  });
}

/// 点对按 x 从小到大定向后的 atan2 角（度）。标签口径（被摄者左右）无关。
double _pairDeg(double x1, double y1, double x2, double y2) {
  final double dx = x2 - x1;
  final double dy = y2 - y1;
  if (dx == 0 && dy == 0) {
    return double.nan;
  }
  return math.atan2(dy, dx) * 180.0 / math.pi;
}

/// 契约关键点序 [左眼, 右眼, 鼻尖, 左嘴角, 右嘴角]（Float32List，长度 ≥10，
/// 工作分辨率坐标）→ 多线融合 roll 估计。
///
/// [legacyRollDeg] 是解码器按眼球连线算出的 rollDeg，在 landmarks 缺失/
/// 退化时原样回退（旧路径行为逐位保留）。
RollFusion fuseRollDeg({
  required Float32List? landmarks,
  required double legacyRollDeg,
}) {
  double eye = double.nan, mouth = double.nan, nose = double.nan;
  final Float32List? lm = landmarks;
  if (lm != null && lm.length >= 10) {
    // 眼对 0–3、嘴对 6–9：按 x 定向。
    eye = (lm[2] > lm[0])
        ? _pairDeg(lm[0], lm[1], lm[2], lm[3])
        : _pairDeg(lm[2], lm[3], lm[0], lm[1]);
    mouth = (lm[8] > lm[6])
        ? _pairDeg(lm[6], lm[7], lm[8], lm[9])
        : _pairDeg(lm[8], lm[9], lm[6], lm[7]);
    // 鼻轴：两眼中点 → 鼻尖，竖直向下为 0。仅诊断，不进估计（见库注释）。
    final double midX = (lm[0] + lm[2]) / 2.0;
    final double midY = (lm[1] + lm[3]) / 2.0;
    nose = _pairDeg(midX, midY, lm[4], lm[5]) - 90.0;
  }

  if (!eye.isFinite && !mouth.isFinite) {
    return RollFusion(
      rollDeg: legacyRollDeg.isFinite ? legacyRollDeg : 0.0,
      source: 'legacy',
      eyeDeg: eye,
      mouthDeg: mouth,
      noseDeg: nose,
    );
  }
  if (!eye.isFinite) {
    return RollFusion(
      rollDeg: mouth,
      source: 'mouth',
      eyeDeg: eye,
      mouthDeg: mouth,
      noseDeg: nose,
    );
  }
  if (!mouth.isFinite) {
    return RollFusion(
      rollDeg: eye,
      source: 'eye',
      eyeDeg: eye,
      mouthDeg: mouth,
      noseDeg: nose,
    );
  }
  if ((eye - mouth).abs() <= kLineConsensusDeg) {
    return RollFusion(
      rollDeg: (eye + mouth) / 2.0,
      source: 'eye+mouth',
      eyeDeg: eye,
      mouthDeg: mouth,
      noseDeg: nose,
    );
  }
  return RollFusion(
    rollDeg: eye,
    source: 'eye',
    eyeDeg: eye,
    mouthDeg: mouth,
    noseDeg: nose,
  );
}
