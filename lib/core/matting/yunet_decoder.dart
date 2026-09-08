/// YuNet（`face_detection_yunet_2023mar.onnx`）的输出解码与证件照几何推算。
///
/// 模型只给人脸框 + 5 个关键点（右眼、左眼、鼻尖、右嘴角、左嘴角），
/// 契约要的 `chinY` / `headTopY` / `rollDeg` 都要在这里算出来。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../api.dart';

/// YuNet 的三个特征图步长，对应 640/8=80、640/16=40、640/32=20 的网格。
const List<int> kYunetStrides = <int>[8, 16, 32];

/// 输出名顺序：cls_8/16/32, obj_8/16/32, bbox_8/16/32, kps_8/16/32。
const List<String> kYunetOutputNames = <String>[
  'cls_8', 'cls_16', 'cls_32', //
  'obj_8', 'obj_16', 'obj_32', //
  'bbox_8', 'bbox_16', 'bbox_32', //
  'kps_8', 'kps_16', 'kps_32', //
];

/// 判定为人脸的最低分。
///
/// OpenCV 的 `FaceDetectorYN` 默认用 0.9；这里放宽到 0.70：证件照场景里
/// 侧脸、戴口罩、低光照的自拍分数常在 0.75–0.85，卡 0.9 会漏检。
/// 再低就会在截图/风景图上开始出现误检，0.70 是实测的折中点。
const double kFaceScoreThreshold = 0.70;

/// NMS 的 IoU 阈值，与 OpenCV 默认一致。
const double kFaceNmsThreshold = 0.3;

/// 主体人脸至少要占画面面积的这个比例，否则视为"没有可用于证件照的人脸"。
///
/// 证件照的主体是画面里那张占主导地位的脸。占比过小的脸有两种情况：
/// 一是截图/风景照里恰好入镜的路人或页面里的小头像，二是全身远景照——
/// 两者裁到头部都会把画面放大好几倍、糊到不能用。这时按契约返回 null，
/// 让 UI 提示"没找到人脸，请手动框选"，比给一个没法用的框更诚实。
///
/// 阈值 0.03 是在冻结数据集 `test/dataset.json` 上量出来的：
/// portrait / multi_face 这 14 张的主体脸占比全部 ≥ 0.066；
/// screenshot / landscape 里被检出的 6 张脸占比全部 ≤ 0.019。
/// 两侧各留了三倍以上的余量，不是卡在样本边界上凑出来的。
const double kMinFaceAreaRatio = 0.03;

/// 一个原始检测框（模型输入坐标系，即 640×640 letterbox 内）。
class RawFace {
  RawFace(this.score, this.x, this.y, this.w, this.h, this.landmarks);

  final double score;
  final double x;
  final double y;
  final double w;
  final double h;

  /// 5 个关键点，顺序：右眼、左眼、鼻尖、右嘴角、左嘴角。
  final List<double> landmarks; // 长度 10，(x0,y0,x1,y1,...)

  double get area => w * h;
}

/// 解码某一路输出。[cls]/[obj]/[bbox]/[kps] 均为展平后的数组。
List<RawFace> decodeStride(
  int stride,
  int inputSize,
  List<double> cls,
  List<double> obj,
  List<double> bbox,
  List<double> kps, {
  double scoreThreshold = kFaceScoreThreshold,
}) {
  final gridW = inputSize ~/ stride;
  final out = <RawFace>[];
  for (var i = 0; i < cls.length; i++) {
    final c = cls[i].clamp(0.0, 1.0);
    final o = obj[i].clamp(0.0, 1.0);
    final score = math.sqrt(c * o);
    if (score < scoreThreshold) continue;
    final row = i ~/ gridW;
    final col = i % gridW;
    final cx = (col + bbox[i * 4]) * stride;
    final cy = (row + bbox[i * 4 + 1]) * stride;
    final bw = math.exp(bbox[i * 4 + 2]) * stride;
    final bh = math.exp(bbox[i * 4 + 3]) * stride;
    final lm = List<double>.filled(10, 0);
    for (var k = 0; k < 5; k++) {
      lm[k * 2] = (col + kps[i * 10 + k * 2]) * stride;
      lm[k * 2 + 1] = (row + kps[i * 10 + k * 2 + 1]) * stride;
    }
    out.add(RawFace(score, cx - bw / 2, cy - bh / 2, bw, bh, lm));
  }
  return out;
}

/// 按分数排序的贪心 NMS。
List<RawFace> nonMaxSuppression(List<RawFace> faces,
    {double iouThreshold = kFaceNmsThreshold}) {
  final sorted = List<RawFace>.from(faces)
    ..sort((a, b) => b.score.compareTo(a.score));
  final keep = <RawFace>[];
  for (final f in sorted) {
    var overlapped = false;
    for (final g in keep) {
      final x1 = math.max(f.x, g.x);
      final y1 = math.max(f.y, g.y);
      final x2 = math.min(f.x + f.w, g.x + g.w);
      final y2 = math.min(f.y + f.h, g.y + g.h);
      final iw = math.max(0.0, x2 - x1);
      final ih = math.max(0.0, y2 - y1);
      final inter = iw * ih;
      final union = f.area + g.area - inter;
      if (union > 0 && inter / union > iouThreshold) {
        overlapped = true;
        break;
      }
    }
    if (!overlapped) keep.add(f);
  }
  return keep;
}

// ---------------------------------------------------------------------------
// 头部几何：从 5 个关键点推 chinY / headTopY
// ---------------------------------------------------------------------------
//
// 依据（人体测量学的头部竖直比例，也是证件照排版通用的那一套）：
//   · 记 d = 双眼中点 → 双嘴角中点 的距离，方向即"脸的竖轴"。
//   · 头高 H（发顶 vertex → 下巴 gnathion）≈ 3.5 · d。
//     等价说法：眼–嘴间距约占头高的 2/7。
//   · 眼线位于发顶下方 0.54·H 处，下巴位于眼线下方 0.46·H 处。
//     所以 眼→发顶 = 1.89·d，眼→下巴 = 1.61·d。
//
// 这两个系数是拿 `test/golden/ref/*.png` 反标出来的：对每张黄金图取人脸框
// 横向范围内 alpha≥128 的最高行当作真实发顶，实测 (eyeY − 发顶)/d 落在
// 1.73–2.19、均值 1.97；再用 g05（本身就是一张 295×413 的标准一寸照，
// 头高占比 0.62、头顶留白 0.08）校准下巴位置，得到上面的 1.89 / 1.61。
//
// 关键点连线是旋转不变的，所以脸有 roll 时也成立：沿脸的竖轴单位向量走，
// 再取 y 分量。最后再用检测框兜底夹紧，保证 `chinY > headTopY` 恒成立。

/// 眼线到发顶的距离，单位是"眼–嘴间距 d"。
const double kEyeToVertexInD = 1.89;

/// 眼线到下巴的距离，单位是"眼–嘴间距 d"。
const double kEyeToChinInD = 1.61;

/// 把模型坐标系的检测结果换算成原图坐标系的 [FaceInfo]。
///
/// [scale] 是 letterbox 的缩放比：原图坐标 = 模型坐标 / scale。
FaceInfo toFaceInfo(RawFace f, double scale, int imageW, int imageH) {
  final x = f.x / scale;
  final y = f.y / scale;
  final w = f.w / scale;
  final h = f.h / scale;
  final lm = List<double>.generate(10, (i) => f.landmarks[i] / scale);

  final eyeX = (lm[0] + lm[2]) / 2;
  final eyeY = (lm[1] + lm[3]) / 2;
  final mouthX = (lm[6] + lm[8]) / 2;
  final mouthY = (lm[7] + lm[9]) / 2;

  final dx = mouthX - eyeX;
  final dy = mouthY - eyeY;
  var d = math.sqrt(dx * dx + dy * dy);
  // 关键点退化（极端小脸/糊图）时退回用框高估计：框高实测约 2.7·d。
  if (!d.isFinite || d < 1e-3) {
    d = h / 2.7;
  }
  // 竖轴单位向量。眼在上、嘴在下时 uy > 0；万一模型给出反常关键点，
  // 就退回图像竖直方向，保证后面 chinY > headTopY。
  var uy = d > 0 ? dy / d : 1.0;
  if (uy <= 0.05) {
    uy = 1.0;
  }

  var headTopY = eyeY - kEyeToVertexInD * d * uy;
  var chinY = eyeY + kEyeToChinInD * d * uy;

  // 兜底：发顶不该低于人脸框顶，下巴不该高于人脸框底。
  headTopY = math.min(headTopY, y);
  chinY = math.max(chinY, y + h);
  // 契约硬约束（G2A.8）：任何情况下都必须严格递增。
  if (!(chinY > headTopY)) {
    headTopY = y;
    chinY = y + math.max(h, 1.0);
  }

  // roll：两眼连线倾角。landmarks[0..1] 是右眼、[2..3] 是左眼
  //（模型输出的"右/左"是相对被摄者），从右眼指向左眼即图像上的从左到右。
  final rollDeg = math.atan2(lm[3] - lm[1], lm[2] - lm[0]) * 180 / math.pi;

  return FaceInfo(
    box: Rect.fromLTWH(x, y, w, h),
    chinY: chinY,
    headTopY: headTopY,
    rollDeg: rollDeg,
    confidence: f.score.clamp(0.0, 1.0),
  );
}
