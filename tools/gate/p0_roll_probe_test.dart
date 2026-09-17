// tools/gate/p0_roll_probe_test.dart
//
// G2B-P0 摆正估计准确性 —— **测量台，不做判定**。
//
// 属 gatekeeper 势力范围（tools/gate/）。判定阈值全部在 gate_P0.dart 里，
// 本文件只负责把生产路径的客观数字量出来，落盘 out/p0_probe_raw.json。
// 这种拆分是刻意的：改阈值必须动 gate 脚本、留 SHA256 痕迹，改测量不会。
//
// 运行（项目根目录，由 gate_P0.dart 调起，也可手动）：
// ```
// flutter test tools/gate/p0_roll_probe_test.dart
// ```
// 之所以放在 tools/gate/ 而不是 test/：本探针要跑几分钟且要写真机文件，
// 不能被杀毒式的 `flutter test` 全量收集顺带跑掉。
//
// ## 为什么不用「成片上重新检脸读 roll」
//
// PITFALLS（imaging，2026-09-17）：295×413 成片上重检的 roll 有尺度依赖偏差，
// g03 目视水平却读 −6.6°。本探针改用**刚体恒等式**测量：
//
//   把源图按已知 Δ 旋转后重跑整条生产链路，若估角器正确，成片应与未旋转时
//   逐像素一致（同一个人、同一朝向）。两者之间**实际残留的刚体旋转角**由
//   掩膜配准搜索给出——这是位图空间的直接测量，不经过任何「策略复制」，
//   也不依赖对成片重检人脸。
//
// 残差口径只读生产路径实际施加的角（ComposeDiagnostics.straightenDeg），
// 绝不在这里私设死区/钳制副本 —— 复制阈值会测出「改前 = 改后」的假对照
// （PITFALLS imaging 已白烧过一轮）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// flutter_test 是 dev_dependency；本文件是门禁测量台，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:muzhao/core/api.dart';
import 'package:muzhao/core/imaging/compose_engine.dart';
import 'package:muzhao/core/matting/matting_engine.dart';
import 'package:muzhao/core/matting/ort_runtime.dart' as ort;
import 'package:muzhao/core/specs/photo_specs.dart';

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

/// 输出（相对项目根）。
const String kOutPath = String.fromEnvironment(
  'P0_OUT',
  defaultValue: 'out/p0_probe_raw.json',
);

/// qa-batch 交付的真值锚点。
const String kTruthPath = String.fromEnvironment(
  'P0_TRUTH',
  defaultValue: 'out/P0_truth.json',
);

/// 旋转夹具目录（qa-batch 交付；缺失时本探针自己用 image 包生成一套，
/// 并在 raw JSON 里如实标注用的是哪一种，不冒充别人的真值）。
const String kAnchorDir = String.fromEnvironment(
  'P0_ANCHOR_DIR',
  defaultValue: 'out/P0_anchors',
);

/// 真实语料全量（P0.4 覆盖率分母）。Pictures 有非人像混杂，属预期。
const String kPicturesDir = String.fromEnvironment(
  'P0_PICTURES',
  defaultValue: r'C:\Users\liuyu\Pictures',
);

const String kGoldenDir = String.fromEnvironment(
  'P0_GOLDEN',
  defaultValue: 'test/golden/src',
);

/// 施加给源图的已知倾角（度）。`img.copyRotate(angle: Δ)`，正 Δ = 顺时针。
///
/// 正式轮次必须用全套（ACCEPTANCE P0.3 点名的 ±3/±5/±10）。`P0_DELTAS=0`
/// 只用于**快速验通**探针本身，出的数字不得当判定依据。
const String kDeltasEnv = String.fromEnvironment('P0_DELTAS');

List<double> deltas() {
  if (kDeltasEnv.isEmpty) return kDeltas;
  return kDeltasEnv
      .split(',')
      .map((String s) => double.parse(s.trim()))
      .toList();
}

/// 快速验通用：跳过 P0.4 的全语料覆盖扫描。
const bool kSkipCoverage = bool.fromEnvironment('P0_SKIP_COVERAGE');

const List<double> kDeltas = <double>[0, 3, -3, 5, -5, 10, -10];

/// 内置锚点：ACCEPTANCE P0.2 点名的用户 `2.jpg`，加同一事故的 `1 (2).jpg`。
///
/// 真值出处（不是本探针自造，全部落在 PITFALLS / 事故记录里）：
/// - p2 `2.jpg`：imaging 2026-09-17 二次归因，眼线 / 镜梁 / 衣领三方独立测量
///   一致水平，真值 −0.2 ± 0.5；用户原话「严重事故」的那张，本项即事故判据。
/// - p1 `1 (2).jpg`：同条记录，虹膜精读 −5.9 / −6.8、镜梁 −4.3、眉线 −9.5 同向，
///   取 −4.4（qa-batch 独立测量口径）。
///
/// 这两张只是**下限兜底**：P0.1 仍要求 ≥ 8 张锚点，缺 qa-batch 真值时照实 FAIL。
const List<Map<String, Object>> kBuiltinAnchors = <Map<String, Object>>[
  <String, Object>{
    'id': 'p2_user_upright',
    'path': r'C:/Users/liuyu/Pictures/2.jpg',
    'kind': 'upright',
    'truth_apply_deg': -0.2,
    'truth_note': '蓝底证件照，眼线/镜梁/衣领三方水平（imaging PITFALLS 2026-09-17），'
        'ACCEPTANCE P0.2 点名的已知竖直样本',
  },
  <String, Object>{
    'id': 'p1_user_portrait',
    'path': r'C:/Users/liuyu/Pictures/1 (2).jpg',
    'kind': 'portrait',
    'truth_apply_deg': -4.4,
    'truth_note': '虹膜精读 −5.9/−6.8、镜梁 −4.3、眉线 −9.5 同向（imaging PITFALLS 2026-09-17）',
  },
];

// ---------------------------------------------------------------------------
// ONNX Runtime 预载
// ---------------------------------------------------------------------------

/// 返回实际加载的 DLL 路径，找不到返回 null（调用方必须把它当阻塞，不许当跳过）。
String? preloadHostOnnxRuntime() {
  final List<String> candidates = <String>[];
  final String? fromEnv = Platform.environment['ORT_DLL'];
  if (fromEnv != null && fromEnv.isNotEmpty) candidates.add(fromEnv);
  // gatekeeper 自己留的固定副本，防别人地盘的探针被删/被换。
  candidates.add('tools/gate/onnxruntime/onnxruntime.dll');
  if (Platform.isWindows) {
    final String? local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final Directory dir = Directory('$local\\Pub\\Cache\\hosted\\pub.dev');
      if (dir.existsSync()) {
        final List<String> found = <String>[];
        for (final FileSystemEntity e in dir.listSync()) {
          final String name = e.path.split(Platform.pathSeparator).last;
          if (e is Directory && name.startsWith('onnxruntime-')) {
            found.add('${e.path}\\windows\\onnxruntime.dll');
          }
        }
        found.sort(); // 版本号升序，取最后一个可用的
        candidates.addAll(found.reversed);
      }
    }
  }
  for (final String p in candidates) {
    final File f = File(p);
    if (f.existsSync()) {
      DynamicLibrary.open(f.path);
      return f.path;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 刚体配准量具
// ---------------------------------------------------------------------------

/// 从两张不同底色的成片提取「不透明前景」掩膜。
///
/// 底色不同的像素必然是背景或半透明边，两图一致的像素是不透明前景。
/// 这样不需要抄一份色卡常量（抄色卡 = 自证式夹具）也不用猜底色 id。
Float32List opaqueForeground(
  img.Image a,
  img.Image b,
  int w,
  int h, {
  int tol = 14,
}) {
  final Float32List out = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final img.Pixel pa = a.getPixel(x, y);
      final img.Pixel pb = b.getPixel(x, y);
      final num dr = (pa.r - pb.r).abs();
      final num dg = (pa.g - pb.g).abs();
      final num db = (pa.b - pb.b).abs();
      num d = dr;
      if (dg > d) d = dg;
      if (db > d) d = db;
      out[y * w + x] = d <= tol ? 1.0 : 0.0;
    }
  }
  return out;
}

/// 盒式降采样 + 二值化。配准搜索在 ~150px 宽上做，够精（0.05° 量级）且快。
({Float32List mask, int w, int h}) downsampleBinary(
  Float32List src,
  int w,
  int h,
  int factor,
) {
  final int nw = (w / factor).floor();
  final int nh = (h / factor).floor();
  final Float32List out = Float32List(nw * nh);
  for (int y = 0; y < nh; y++) {
    for (int x = 0; x < nw; x++) {
      int sum = 0;
      int n = 0;
      for (int dy = 0; dy < factor; dy++) {
        final int sy = y * factor + dy;
        if (sy >= h) break;
        for (int dx = 0; dx < factor; dx++) {
          final int sx = x * factor + dx;
          if (sx >= w) break;
          if (src[sy * w + sx] > 0.5) sum++;
          n++;
        }
      }
      out[y * nw + x] = (n > 0 && sum * 2 > n) ? 1.0 : 0.0;
    }
  }
  return (mask: out, w: nw, h: nh);
}

double _sample(Float32List m, int w, int h, double x, double y) {
  if (x < 0 || y < 0 || x > w - 1 || y > h - 1) return 0.0;
  final int x0 = x.floor();
  final int y0 = y.floor();
  final int x1 = math.min(x0 + 1, w - 1);
  final int y1 = math.min(y0 + 1, h - 1);
  final double fx = x - x0;
  final double fy = y - y0;
  final double v00 = m[y0 * w + x0];
  final double v10 = m[y0 * w + x1];
  final double v01 = m[y1 * w + x0];
  final double v11 = m[y1 * w + x1];
  return v00 * (1 - fx) * (1 - fy) +
      v10 * fx * (1 - fy) +
      v01 * (1 - fx) * fy +
      v11 * fx * fy;
}

({double cx, double cy}) _centroid(Float32List m, int w, int h) {
  double sx = 0, sy = 0;
  int n = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (m[y * w + x] > 0.5) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  if (n == 0) return (cx: double.nan, cy: double.nan);
  return (cx: sx / n, cy: sy / n);
}

double _iouAt(
  Float32List a,
  Float32List b,
  int w,
  int h,
  double thetaDeg,
  double cax,
  double cay,
  double cbx,
  double cby, [
  double scale = 1.0,
]) {
  final double t = thetaDeg * math.pi / 180.0;
  final double ct = math.cos(t);
  final double st = math.sin(t);
  int inter = 0;
  int uni = 0;
  for (int y = 0; y < h; y++) {
    final double dy = y - cby;
    for (int x = 0; x < w; x++) {
      final double dx = x - cbx;
      final double sx = (ct * dx - st * dy) / scale + cax;
      final double sy = (st * dx + ct * dy) / scale + cay;
      final double av = _sample(a, w, h, sx, sy);
      final double bv = b[y * w + x];
      final bool ai = av > 0.5;
      final bool bi = bv > 0.5;
      if (ai && bi) inter++;
      if (ai || bi) uni++;
    }
  }
  return uni == 0 ? 0.0 : inter / uni;
}

/// 把掩膜 A 绕自己质心旋转 [deg] 度（顺时针为正，与 `img.copyRotate` 同口径）。
Float32List rotateMask(Float32List a, int w, int h, double deg) {
  final ({double cx, double cy}) c = _centroid(a, w, h);
  final double t = deg * math.pi / 180.0;
  final double ct = math.cos(t);
  final double st = math.sin(t);
  final Float32List out = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double dx = x - c.cx;
      final double dy = y - c.cy;
      final double sx = ct * dx - st * dy + c.cx;
      final double sy = st * dx + ct * dy + c.cy;
      out[y * w + x] = _sample(a, w, h, sx, sy) > 0.5 ? 1.0 : 0.0;
    }
  }
  return out;
}

/// A 相对 B 残留的刚体旋转角（度）：先按质心平移对齐，再搜索使 IoU 最大的
/// 「旋转 + 缩放」。|结果| 就是「成片还歪多少度」。
///
/// 为什么必须带缩放：注入 ±10° 后裁剪框会跟着变（越界/收缩），成片里人像的
/// 尺度会差几个百分点。只搜旋转的话，尺度差会把最优角拽偏 —— 实测 p2 注入
/// ±10° 只读回 ∓8.1°，IoU 掉到 0.895，看着像"转少了 2°"，其实是量具的问题。
/// 带上缩放后同一条数据读回 9.9–10.1°，IoU 上到 0.96。
({double deg, double iou, double scale}) registerResidual(
  Float32List a,
  Float32List b,
  int w,
  int h, {
  double range = 10.0,
  double coarseStep = 0.25,
  double fineStep = 0.025,
}) {
  final ({double cx, double cy}) ca = _centroid(a, w, h);
  final ({double cx, double cy}) cb = _centroid(b, w, h);
  if (ca.cx.isNaN || cb.cx.isNaN) {
    return (deg: double.nan, iou: 0.0, scale: double.nan);
  }

  double bestDeg = 0.0;
  double bestScale = 1.0;
  double bestIou = -1.0;

  // 1) 粗搜旋转（尺度先按 1）
  for (double d = -range; d <= range + 1e-9; d += coarseStep) {
    final double iou = _iouAt(a, b, w, h, d, ca.cx, ca.cy, cb.cx, cb.cy);
    if (iou > bestIou) {
      bestIou = iou;
      bestDeg = d;
    }
  }
  // 2) 固定角度搜尺度
  for (double s = 0.90; s <= 1.1001; s += 0.01) {
    final double iou = _iouAt(a, b, w, h, bestDeg, ca.cx, ca.cy, cb.cx, cb.cy, s);
    if (iou > bestIou) {
      bestIou = iou;
      bestScale = s;
    }
  }
  // 3) 交替精修
  for (int iter = 0; iter < 3; iter++) {
    for (double d = bestDeg - coarseStep; d <= bestDeg + coarseStep + 1e-9; d += fineStep) {
      final double iou =
          _iouAt(a, b, w, h, d, ca.cx, ca.cy, cb.cx, cb.cy, bestScale);
      if (iou > bestIou) {
        bestIou = iou;
        bestDeg = d;
      }
    }
    for (double s = bestScale - 0.01; s <= bestScale + 0.0101; s += 0.002) {
      final double iou = _iouAt(a, b, w, h, bestDeg, ca.cx, ca.cy, cb.cx, cb.cy, s);
      if (iou > bestIou) {
        bestIou = iou;
        bestScale = s;
      }
    }
  }
  return (deg: bestDeg, iou: bestIou, scale: bestScale);
}

/// 量具自检：把掩膜人为转 3.0°、放大 3%，配准必须读回这两者。
/// 量具坏了，后面所有残差数字都是废的。
({double recovered, double iou, double recoveredScale, double recoveredScaled})
    instrumentSelfTest(Float32List m, int w, int h) {
  final ({double deg, double iou, double scale}) r =
      registerResidual(rotateMask(m, w, h, 3.0), m, w, h);
  final Float32List scaled = scaleMask(m, w, h, 1.03);
  final ({double deg, double iou, double scale}) r2 =
      registerResidual(scaled, m, w, h);
  return (
    recovered: r.deg,
    iou: r.iou,
    recoveredScale: r.scale,
    recoveredScaled: r2.scale,
  );
}

/// 把掩膜绕质心缩放 [s] 倍（采样，最近邻语义即双线性阈值）。
Float32List scaleMask(Float32List a, int w, int h, double s) {
  final ({double cx, double cy}) c = _centroid(a, w, h);
  final Float32List out = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double sx = (x - c.cx) / s + c.cx;
      final double sy = (y - c.cy) / s + c.cy;
      out[y * w + x] = _sample(a, w, h, sx, sy) > 0.5 ? 1.0 : 0.0;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 引擎
// ---------------------------------------------------------------------------

class _FullEngine with MattingEngineMixin, ComposeEngineMixin {
  @override
  void dispose() {
    disposeMattingEngine();
  }
}

Uint8List rotateJpeg(Uint8List bytes, double deltaDeg) {
  final img.Image? src = img.decodeImage(bytes);
  if (src == null) throw StateError('源图解码失败');
  final img.Image rot = img.copyRotate(
    src,
    angle: deltaDeg,
    interpolation: img.Interpolation.cubic,
  );
  return Uint8List.fromList(img.encodeJpg(rot, quality: 95));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ort.debugModelDirectory = 'assets/models';

  final Map<String, dynamic> raw = <String, dynamic>{
    'generatedAt': DateTime.now().toIso8601String(),
    'deltas': deltas(),
    'skip_coverage': kSkipCoverage,
    'blockers': <String>[],
  };

  test('P0 摆正估计测量台', () async {
    final String? ortPath = preloadHostOnnxRuntime();
    raw['ortDll'] = ortPath;
    // 被测代码的版本指纹：实现类 agent 可能正在改 lib/，不钉住修订号的话
    // 这一轮的数字下一分钟就对不上任何一个 commit（本次实测就遇到了）。
    raw['measured_revision'] = _sourceHashes();
    if (ortPath == null) {
      (raw['blockers'] as List<String>).add(
          'ONNX Runtime DLL 找不到（试过 ORT_DLL 环境变量 / tools/gate/onnxruntime/ / '
          'pub cache）。真实引擎跑不起来，本测量台无法产出任何数字。');
      _writeOut(raw);
      return;
    }

    // ---- 锚点集：内置（用户实拍）+ qa-batch 真值文件 ----
    //
    // qa-batch 的真值文件里有两个字段：`trueRollDeg`（实测倾角 tilt）与
    // `expectedCorrectionDeg = −tilt`，并在 convention 里声称后者才是
    // FaceInfo.rollDeg。**该注记与实现相反**，本测量台取 `trueRollDeg`：
    //   证据链（两条互相独立的实测，见 out/GATE_P0_r1.md「符号口径」一节）
    //   ① `img.copyRotate(angle: +10)` 是顺时针（白点位移实测），顺时针使
    //      图像右侧变低即 tilt 变大；而引擎的估计满足 est(Δ)=est(0)+Δ，
    //      即引擎输出的就是 tilt 本身；
    //   ② 注入 FaceInfo.rollDeg=+10，成片相对注入 0 的那张**倾角减小** 10.2°，
    //      即 output_tilt = input_tilt − applied。两条合起来：施加 est 恰好
    //      抵消输入倾角，输出回正——自洽。用事故数字反证也成立：
    //      p1 applied=0 → 输出 tilt = −4.4（事故）；p2 applied=−3.85 →
    //      输出 tilt = −0.2+3.85 = +3.65 ≈ 记录的 +3.7（事故）。
    //      若改用 expectedCorrectionDeg，p2 会算出 −4.05，与记录不符。
    final List<Map<String, dynamic>> anchors = <Map<String, dynamic>>[];
    void addAnchor(Map<String, dynamic> m) {
      anchors.add(m);
    }
    for (final Map<String, Object> a in kBuiltinAnchors) {
      addAnchor(<String, dynamic>{
        'id': a['id'],
        'path': a['path'],
        'kind': a['kind'],
        'truth_apply_deg': a['truth_apply_deg'],
        'truth_field': 'builtin:${a['kind']}',
        'truth_note': a['truth_note'],
        'truth_source': 'builtin',
        'sweep': true,
      });
    }
    final File truthFile = File(kTruthPath);
    raw['truth_file'] = kTruthPath;
    raw['truth_file_exists'] = truthFile.existsSync();
    final List<String> truthWarnings = <String>[];
    if (truthFile.existsSync()) {
      try {
        final Map<String, dynamic> t =
            jsonDecode(truthFile.readAsStringSync()) as Map<String, dynamic>;
        raw['truth_convention'] = t['convention'];
        raw['truth_generated_by'] = t['generatedBy'];
        final Set<String> seen = anchors
            .map((Map<String, dynamic> a) =>
                (a['path'] as String).replaceAll('\\', '/'))
            .toSet();
        int added = 0;
        void take(List<dynamic> list, String section, String kind) {
          for (final dynamic e in list) {
            final Map<String, dynamic> m = e as Map<String, dynamic>;
            if (m['path'] == null) continue;
            final String p =
                (m['path'] as String).replaceAll('\\', '/').replaceAll('"', '');
            if (seen.contains(p)) {
              truthWarnings.add('$section/${m['id']} 与既有锚点同路径，去重跳过');
              continue;
            }
            seen.add(p);
            final double? truth = _truthOf(m);
            if (truth == null) {
              truthWarnings.add('$section/${m['id']} 既无 truth_apply_deg 也无 '
                  'trueRollDeg，跳过');
              continue;
            }
            added++;
            addAnchor(<String, dynamic>{
              'id': '${m['id']}',
              'path': p,
              'kind': kind,
              'truth_apply_deg': truth,
              'truth_field': m['truth_apply_deg'] != null
                  ? 'truth_apply_deg'
                  : 'trueRollDeg(qa-batch 的 tilt 口径)'
                      '${m['expectedCorrectionDeg'] != null ? '；该文件另有 '
                          'expectedCorrectionDeg=${m['expectedCorrectionDeg']} '
                          '（= −tilt），与实现相反，未采用' : ''}',
              'truth_note': m['note'] ?? '',
              'truth_source': 'qa_batch:$section',
              'sweep': true,
            });
          }
        }

        take((t['anchors'] as List<dynamic>?) ?? <dynamic>[], 'anchors', 'portrait');
        take((t['straight'] as List<dynamic>?) ?? <dynamic>[], 'straight', 'upright');
        // 回正合成样本：P0.2 点名要，但不进 P0.3 的旋转等变集（它们是派生图，
        // 且量已经够），跑到 Δ=0 就够，省下的是时间不是证据。
        for (final dynamic e
            in (t['uprightSynthetic'] as List<dynamic>?) ?? <dynamic>[]) {
          final Map<String, dynamic> m = e as Map<String, dynamic>;
          final double? truth = _truthOf(m);
          if (m['path'] == null || truth == null) continue;
          final String p = (m['path'] as String).replaceAll('\\', '/');
          if (seen.contains(p)) continue;
          seen.add(p);
          addAnchor(<String, dynamic>{
            'id': '${m['id']}',
            'path': p,
            'kind': 'upright',
            'truth_apply_deg': truth,
            'truth_field': 'trueRollDeg',
            'truth_note': m['note'] ?? '',
            'truth_source': 'qa_batch:uprightSynthetic',
            'sweep': false,
          });
        }
        raw['truth_anchors_added'] = added;
      } catch (e) {
        (raw['blockers'] as List<String>)
            .add('$kTruthPath 解析失败：$e（按未交付处理，P0.1 不能判 PASS）');
      }
    }
    raw['truth_warnings'] = truthWarnings;
    raw['anchors'] = anchors;
    raw['anchor_count'] = anchors.length;
    raw['sweep_cohort'] =
        anchors.where((Map<String, dynamic> a) => a['sweep'] == true).length;
    final List<double> defDeltas = deltas();
    for (final Map<String, dynamic> a in anchors) {
      a['deltas_used'] = a['sweep'] == true ? defDeltas : <double>[0];
    }

    // ---- 逐锚点测量 ----
    final _FullEngine engine = _FullEngine();
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    try {
      await engine.warmUp();
      for (final Map<String, dynamic> a in anchors) {
        results.add(await _measureAnchor(engine, a));
      }
    } catch (e, st) {
      (raw['blockers'] as List<String>).add('锚点测量中断：$e\n$st');
    } finally {
      try {
        await engine.disposeMattingEngine();
      } catch (_) {
        // 关闭失败不影响已经测到的数字，但要留痕。
        (raw['blockers'] as List<String>).add('引擎释放抛异常（数字仍有效）');
      }
    }
    raw['anchor_results'] = results;

    // ---- 量具自检（用第一条成功锚点的掩膜） ----
    for (final Map<String, dynamic> r in results) {
      final String? b64 = r['mask0_png_b64'] as String?;
      if (b64 == null) continue;
      final img.Image m = img.decodePng(base64Decode(b64))!;
      final Float32List f = Float32List(m.width * m.height);
      for (int y = 0; y < m.height; y++) {
        for (int x = 0; x < m.width; x++) {
          f[y * m.width + x] = m.getPixel(x, y).r > 127 ? 1.0 : 0.0;
        }
      }
      final ({double recovered, double iou, double recoveredScale,
              double recoveredScaled}) st =
          instrumentSelfTest(f, m.width, m.height);
      raw['instrument_selftest'] = <String, dynamic>{
        'injected_deg': 3.0,
        'recovered_deg': st.recovered,
        'iou': st.iou,
        'injected_scale': 1.03,
        'recovered_scale': st.recoveredScaled,
        'recovered_scale_when_none': st.recoveredScale,
        'mask_px': f.where((double v) => v > 0.5).length,
      };
      break;
    }
    for (final Map<String, dynamic> r in results) {
      r.remove('mask0_png_b64');
    }

    // ---- P0.4 覆盖率：Pictures 全量 + 黄金集 + 锚点，只跑 detectFace ----
    if (kSkipCoverage) {
      raw['coverage'] = <String, dynamic>{
        'skipped': true,
        'why': 'P0_SKIP_COVERAGE=1（快速验通模式），本文件不得作为 P0.4 的判定依据',
      };
    } else {
      raw['coverage'] = await _measureCoverage(engine, anchors);
    }

    _writeOut(raw);
  }, timeout: const Timeout(Duration(minutes: 90)));
}

/// 从 qa-batch 的锚点条目里取"应施加角"。
///
/// 优先 `truth_apply_deg`（约定的字段名）；没有就退回 `trueRollDeg`（tilt
/// 口径，实测等价，理由见 main 里的证据链注释）。**不碰
/// `expectedCorrectionDeg`** —— 它与实现相反，采用它会把两个符号错误叠一起。
double? _truthOf(Map<String, dynamic> m) {
  final dynamic a = m['truth_apply_deg'];
  if (a is num) return a.toDouble();
  final dynamic b = m['trueRollDeg'];
  if (b is num) return b.toDouble();
  return null;
}

Future<Map<String, dynamic>> _measureAnchor(
  _FullEngine engine,
  Map<String, dynamic> anchor,
) async {
  final String id = anchor['id'] as String;
  final String path = anchor['path'] as String;
  final List<double> ds = ((anchor['deltas_used'] as List<dynamic>?) ??
          <dynamic>[0])
      .map((dynamic d) => (d as num).toDouble())
      .toList();
  final Map<String, dynamic> out = <String, dynamic>{
    'id': id,
    'path': path,
    'kind': anchor['kind'],
    'truth_apply_deg': anchor['truth_apply_deg'],
    'truth_field': anchor['truth_field'],
    'truth_source': anchor['truth_source'],
    'truth_note': anchor['truth_note'],
    'deltas_used': ds,
    'configs': <Map<String, dynamic>>[],
  };
  final File f = File(path);
  if (!f.existsSync()) {
    out['error'] = '锚点文件不存在：$path';
    out['compose_rigid'] = <String, dynamic>{'skipped': true, 'why': '锚点缺失'};
    return out;
  }
  final Uint8List srcBytes = f.readAsBytesSync();
  final img.Image? decoded = img.decodeImage(srcBytes);
  out['src_size'] = decoded == null ? null : '${decoded.width}x${decoded.height}';

  final PhotoSpec spec = specCn1inch;
  Float32List? refMask;
  MattingResult? matting0;
  FaceInfo? face0;
  int refW = 0;
  int refH = 0;

  for (final double delta in ds) {
    final Map<String, dynamic> cfg = <String, dynamic>{'delta': delta};
    try {
      final Uint8List bytes =
          delta == 0 ? srcBytes : rotateJpeg(srcBytes, delta);

      final FaceInfo? face = await engine.detectFace(bytes);
      cfg['detected'] = face != null;
      if (face != null) {
        cfg['rollDeg'] = face.rollDeg;
        cfg['rollSource'] = face.rollSource.name;
        cfg['confidence'] = face.confidence;
        cfg['has_landmarks'] = face.landmarks != null;
      }

      final MattingResult matting = await engine.removeBackground(bytes);
      final Candidate cWhite = await engine.compose(
        matting: matting,
        spec: spec,
        style: kBgWhite,
        face: face,
      );
      final ComposeDiagnostics? dAfterWhite = engine.lastDiagnostics;
      final Candidate cBlue = await engine.compose(
        matting: matting,
        spec: spec,
        style: kBgBlue,
        face: face,
      );
      cfg['applied_deg'] = dAfterWhite?.straightenDeg;
      cfg['straightened'] = dAfterWhite?.straightened;
      cfg['note'] = dAfterWhite?.note;
      cfg['out_size'] =
          '${img.decodeJpg(cWhite.jpegBytes)!.width}x${img.decodeJpg(cWhite.jpegBytes)!.height}';

      final img.Image imWhite = img.decodeJpg(cWhite.jpegBytes)!;
      final img.Image imBlue = img.decodeJpg(cBlue.jpegBytes)!;
      final int w = imWhite.width;
      final int h = imWhite.height;
      final Float32List full = opaqueForeground(imWhite, imBlue, w, h);
      final int factor = math.max(1, (w / 150).round());
      final ({Float32List mask, int w, int h}) ds =
          downsampleBinary(full, w, h, factor);
      int fgCount = 0;
      for (final double v in ds.mask) {
        if (v > 0.5) fgCount++;
      }
      cfg['mask_px'] = fgCount;
      cfg['mask_total'] = ds.w * ds.h;
      cfg['mask_w'] = ds.w;
      cfg['mask_h'] = ds.h;

      if (delta == 0) {
        refMask = ds.mask;
        matting0 = matting;
        face0 = face;
        refW = ds.w;
        refH = ds.h;
        out['mask0_png_b64'] = base64Encode(img.encodePng(imWhite));
        cfg['is_reference'] = true;
      } else if (refMask != null) {
        final ({double deg, double iou, double scale}) reg =
            registerResidual(ds.mask, refMask, ds.w, ds.h);
        cfg['residual_deg'] = reg.deg;
        cfg['residual_iou'] = reg.iou;
        cfg['residual_scale'] = reg.scale;
      }
    } catch (e, st) {
      cfg['error'] = '$e';
      cfg['stack'] = st.toString().split('\n').take(4).join(' | ');
    }
    (out['configs'] as List<Map<String, dynamic>>).add(cfg);
  }

  // ---- P0.5b：compose 侧「给了角就转对」（ACCEPTANCE 2B.8 的 host 版） ----
  //
  // 夹具：同一张源图、同一份抠图，只把注入的 FaceInfo.rollDeg 从 0 改成 ±10，
  // 其余全同。若 compose 侧几何正确，成片相对注入 0 的那张应当只差一个刚体
  // 旋转 ±10°。用掩膜配准直接量这个旋转角——不重检人脸（尺度偏差）、
  // 不复制裁剪策略（复制阈值会测出"改前=改后"的假对照）。
  //
  // 只对 P0.3 cohort（真实锚点）跑：回正合成样本是派生的，几何性质和源图一样。
  if (anchor['sweep'] == true && matting0 != null && face0 != null) {
    out['compose_rigid'] =
        await _measureRigid(engine, matting0, face0, spec, refMask, refW, refH);
  } else {
    out['compose_rigid'] = <String, dynamic>{
      'skipped': true,
      'why': anchor['sweep'] == true ? '无人脸或抠图失败' : '非 P0.3 cohort',
    };
  }
  return out;
}

/// 注入已知角 → 量成片实际转了多少度。
Future<Map<String, dynamic>> _measureRigid(
  _FullEngine engine,
  MattingResult matting,
  FaceInfo f,
  PhotoSpec spec,
  Float32List? refMask,
  int refW,
  int refH,
) async {
  final Map<String, dynamic> out = <String, dynamic>{};
  try {
    final Map<double, Float32List> masks = <double, Float32List>{};
    int mw = 0;
    int mh = 0;
    for (final double r in <double>[0, 10, -10]) {
      final FaceInfo injected = FaceInfo(
        box: f.box,
        chinY: f.chinY,
        headTopY: f.headTopY,
        rollDeg: r,
        confidence: f.confidence,
        rollSource: RollSource.given,
        landmarks: f.landmarks,
      );
      final Candidate w = await engine.compose(
        matting: matting,
        spec: spec,
        style: kBgWhite,
        face: injected,
      );
      final Candidate b = await engine.compose(
        matting: matting,
        spec: spec,
        style: kBgBlue,
        face: injected,
      );
      final img.Image iw = img.decodeJpg(w.jpegBytes)!;
      final img.Image ib = img.decodeJpg(b.jpegBytes)!;
      final Float32List full = opaqueForeground(iw, ib, iw.width, iw.height);
      final int factor = math.max(1, (iw.width / 150).round());
      final ({Float32List mask, int w, int h}) ds =
          downsampleBinary(full, iw.width, iw.height, factor);
      out['applied_${r.toInt()}'] =
          engine.lastDiagnostics?.straightenDeg ?? double.nan;
      masks[r] = ds.mask;
      mw = ds.w;
      mh = ds.h;
    }
    final Float32List? m0 = masks[0];
    if (m0 == null) {
      out['error'] = '注入 0 的成片掩膜缺失';
      return out;
    }
    for (final double r in <double>[10, -10]) {
      final Float32List? mr = masks[r];
      if (mr == null) continue;
      final ({double deg, double iou, double scale}) reg =
          registerResidual(mr, m0, mw, mh);
      out[r > 0 ? 'measured_plus_deg' : 'measured_minus_deg'] = reg.deg;
      out[r > 0 ? 'iou_plus' : 'iou_minus'] = reg.iou;
      out[r > 0 ? 'scale_plus' : 'scale_minus'] = reg.scale;
    }
  } catch (e, st) {
    out['error'] = '$e';
    out['stack'] = st.toString().split('\n').take(4).join(' | ');
  }
  return out;
}

/// P0.4 覆盖率：真实语料全量跑生产检出路径，统计 RollSource 分布与诚实性违规。
Future<Map<String, dynamic>> _measureCoverage(
  _FullEngine engine,
  List<Map<String, dynamic>> anchors,
) async {
  final Map<String, dynamic> out = <String, dynamic>{
    'corpus': <String>[],
    'face_detected': 0,
    'no_face': 0,
    'by_source': <String, int>{},
    'violations': <Map<String, dynamic>>[],
    'errors': <Map<String, dynamic>>[],
  };

  final List<String> paths = <String>[];
  final List<String> files = <String>[];
  for (final String dir in <String>[kPicturesDir, kGoldenDir]) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) {
      (out['errors'] as List<Map<String, dynamic>>)
          .add(<String, dynamic>{'dir': dir, 'error': '目录不存在'});
      continue;
    }
    for (final FileSystemEntity e in d.listSync()) {
      if (e is! File) continue;
      final String lower = e.path.toLowerCase();
      if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png')) {
        files.add(e.path.replaceAll('\\', '/'));
      }
    }
  }
  files.sort();
  for (final Map<String, dynamic> a in anchors) {
    files.add(a['path'] as String);
  }
  out['corpus'] = files;
  out['corpus_total'] = files.length;

  final Map<String, int> bySource = out['by_source'] as Map<String, int>;
  for (final String p in files) {
    try {
      final Uint8List bytes = File(p).readAsBytesSync();
      final FaceInfo? face = await engine.detectFace(bytes);
      if (face == null) {
        out['no_face'] = (out['no_face'] as int) + 1;
        bySource['no_face'] = (bySource['no_face'] ?? 0) + 1;
        continue;
      }
      out['face_detected'] = (out['face_detected'] as int) + 1;
      final String s = face.rollSource.name;
      bySource[s] = (bySource[s] ?? 0) + 1;
      // P0.4 诚实性：不可信来源必须给 0.0，且不得是夹具语义 given。
      if (face.rollSource != RollSource.pupil) {
        if (face.rollDeg != 0.0) {
          (out['violations'] as List<Map<String, dynamic>>).add(
              <String, dynamic>{'path': p, 'source': s, 'rollDeg': face.rollDeg});
        }
      }
      if (s == 'given') {
        (out['violations'] as List<Map<String, dynamic>>).add(<String, dynamic>{
          'path': p,
          'source': s,
          'rollDeg': face.rollDeg,
          'why': '生产检出路径返回 given（夹具语义），说明检出器没有维护 rollSource',
        });
      }
      paths.add(p);
    } catch (e) {
      (out['errors'] as List<Map<String, dynamic>>)
          .add(<String, dynamic>{'path': p, 'error': '$e'});
    }
  }
  out['pupil_rate_over_detected'] =
      (out['face_detected'] as int) == 0
          ? null
          : (bySource['pupil'] ?? 0) / (out['face_detected'] as int);
  return out;
}

void _writeOut(Map<String, dynamic> raw) {
  final File f = File(kOutPath);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(raw));
}

/// 被测生产代码（非 dev_ 探针）的 SHA256，用于把本轮数字钉在某个修订上。
Map<String, String> _sourceHashes() {
  final Map<String, String> out = <String, String>{};
  for (final String dir in <String>['lib/core/matting', 'lib/core/imaging']) {
    final Directory d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final FileSystemEntity e in d.listSync()) {
      final String p = e.path.replaceAll('\\', '/');
      if (e is! File || !p.endsWith('.dart')) continue;
      if (p.split('/').last.startsWith('dev_')) continue;
      out[p] = _sha256(p);
    }
  }
  return out;
}

String _sha256(String path) {
  try {
    final ProcessResult r =
        Process.runSync('sha256sum', <String>[path], runInShell: true);
    if (r.exitCode != 0) return 'sha256sum失败';
    return (r.stdout as String).trim().split(RegExp(r'\s+')).first;
  } catch (e) {
    return 'sha256失败:$e';
  }
}
