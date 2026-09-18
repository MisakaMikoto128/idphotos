/// 木照 MuZhao — imaging 侧的「门禁同款」复现自检。
///
/// 运行（项目根目录）：
///
/// ```
/// C:\src\flutter\bin\flutter test lib/core/imaging/dev_gate_repro.dart
/// ```
///
/// ## 为什么单独有这个文件
///
/// `dev_selfcheck.dart` 用的是我自己造的椭圆人像，和 gatekeeper 的合成人像
/// （灰底矩形 + 头顶青条 + 下巴品红条）形态不同，导致第 1 轮出现「自测 0、
/// 门禁 295」的偏差。本文件**逐字复刻** `integration_test/compose_eval_test.dart`
/// 的画布构造与 `tools/gate/compose_check_utils.dart` 的测量口径（只读不改
/// 那两个文件），使我的数字与门禁的数字可比。
///
/// 覆盖面比门禁更宽：溢色跑纯绿 / 纯品红 / 纯红 / 纯蓝四种极端底色。
/// **摆正夹具与门禁同值（±15°），两处必须同步改** —— 一旦漂开，本文件就不再是
/// 门禁同款，而它下面没有判据，漂了不会报错。本文件是**复现工具，不是门禁项**：
/// 它只打印，不加阈值断言；但夹具的前置条件会断言，保证"漂了会响"。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

// flutter_test 是 dev_dependency；本文件是开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../api.dart';
import 'compose_only_engine.dart';
import 'crop_geometry.dart';
import 'jpeg_dpi.dart';

// ---------------------------------------------------------------------------
// 与 compose_eval_test.dart 完全一致的合成画布
// ---------------------------------------------------------------------------

const int kCanvasW = 1000;
const int kCanvasH = 1400;
const int kRectX0 = 350, kRectX1 = 650;
const int kRectY0 = 300, kRectY1 = 1000;
const int kFeatherPx = 8;
const int kStripeH = 4;

const int kCyanR = 0, kCyanG = 255, kCyanB = 255;
const int kMagentaR = 255, kMagentaG = 0, kMagentaB = 255;
const int kBgFillR = 180, kBgFillG = 120, kBgFillB = 60;

img.Image buildGateCanvas() {
  final img.Image image =
      img.Image(width: kCanvasW, height: kCanvasH, numChannels: 4);
  for (int y = 0; y < kCanvasH; y++) {
    for (int x = 0; x < kCanvasW; x++) {
      final bool insideX = x >= kRectX0 - kFeatherPx && x < kRectX1 + kFeatherPx;
      final bool insideY = y >= kRectY0 - kFeatherPx && y < kRectY1 + kFeatherPx;
      double alpha = 0;
      if (x >= kRectX0 && x < kRectX1 && y >= kRectY0 && y < kRectY1) {
        alpha = 255;
      } else if (insideX && insideY) {
        final int dx =
            x < kRectX0 ? kRectX0 - x : (x >= kRectX1 ? x - kRectX1 + 1 : 0);
        final int dy =
            y < kRectY0 ? kRectY0 - y : (y >= kRectY1 ? y - kRectY1 + 1 : 0);
        final double dist = math.sqrt((dx * dx + dy * dy).toDouble());
        alpha =
            (255 * (1 - (dist / kFeatherPx).clamp(0, 1))).clamp(0, 255).toDouble();
      }
      int r = kBgFillR, g = kBgFillG, b = kBgFillB;
      if (alpha > 0) {
        r = 128;
        g = 128;
        b = 128;
      }
      image.setPixelRgba(x, y, r, g, b, alpha.round());
    }
  }
  for (int y = kRectY0; y < kRectY0 + kStripeH; y++) {
    for (int x = kRectX0; x < kRectX1; x++) {
      image.setPixelRgba(x, y, kCyanR, kCyanG, kCyanB, 255);
    }
  }
  for (int y = kRectY0 + 200; y < kRectY0 + 200 + kStripeH; y++) {
    for (int x = kRectX0; x < kRectX1; x++) {
      image.setPixelRgba(x, y, kMagentaR, kMagentaG, kMagentaB, 255);
    }
  }
  return image;
}

MattingResult toMattingResult(img.Image image) {
  final int w = image.width, h = image.height;
  final Uint8List rgba = Uint8List(w * h * 4);
  final Uint8List alpha = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final int idx = y * w + x;
      rgba[idx * 4] = p.r.toInt();
      rgba[idx * 4 + 1] = p.g.toInt();
      rgba[idx * 4 + 2] = p.b.toInt();
      rgba[idx * 4 + 3] = 255;
      alpha[idx] = p.a.toInt();
    }
  }
  return MattingResult(rgba: rgba, alpha: alpha, width: w, height: h);
}

class GateSynthetic {
  final MattingResult matting;
  final FaceInfo face;
  const GateSynthetic(this.matting, this.face);
}

GateSynthetic buildGateSynthetic({double rollDeg = 0}) {
  img.Image canvas = buildGateCanvas();
  if (rollDeg != 0) {
    canvas = img.copyRotate(canvas,
        angle: rollDeg, interpolation: img.Interpolation.linear);
  }
  final List<PxMatch> headTopMatches =
      findMatches(canvas, kCyanR, kCyanG, kCyanB, tolerance: 30);
  final List<PxMatch> chinMatches =
      findMatches(canvas, kMagentaR, kMagentaG, kMagentaB, tolerance: 30);
  final PxCentroid? headC = centroid(headTopMatches);
  final PxCentroid? chinC = centroid(chinMatches);
  final double headTopY = headC?.y ?? kRectY0.toDouble();
  final double chinY = chinC?.y ?? (kRectY0 + 200).toDouble();

  final FaceInfo face = FaceInfo(
    box: Rect.fromLTWH(kRectX0.toDouble(), headTopY,
        (kRectX1 - kRectX0).toDouble(), chinY - headTopY),
    chinY: chinY,
    headTopY: headTopY,
    rollDeg: rollDeg,
    confidence: 1.0,
  );
  return GateSynthetic(toMattingResult(canvas), face);
}

// ---------------------------------------------------------------------------
// 与 compose_check_utils.dart 一致的测量口径
// ---------------------------------------------------------------------------

class PxMatch {
  final int x, y;
  const PxMatch(this.x, this.y);
}

class PxCentroid {
  final double x, y;
  final int count;
  const PxCentroid(this.x, this.y, this.count);
}

List<PxMatch> findMatches(img.Image image, int tr, int tg, int tb,
    {int tolerance = 40}) {
  final List<PxMatch> matches = <PxMatch>[];
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final num dr = p.r - tr, dg = p.g - tg, db = p.b - tb;
      if (dr * dr + dg * dg + db * db <= tolerance * tolerance) {
        matches.add(PxMatch(x, y));
      }
    }
  }
  return matches;
}

PxCentroid? centroid(List<PxMatch> matches) {
  if (matches.isEmpty) return null;
  double sx = 0, sy = 0;
  for (final PxMatch m in matches) {
    sx += m.x;
    sy += m.y;
  }
  return PxCentroid(sx / matches.length, sy / matches.length, matches.length);
}

double? tiltDeg(List<PxMatch> matches) {
  if (matches.length < 2) return null;
  PxMatch? leftmost, rightmost;
  for (final PxMatch m in matches) {
    if (leftmost == null || m.x < leftmost.x) leftmost = m;
    if (rightmost == null || m.x > rightmost.x) rightmost = m;
  }
  if (leftmost == null || rightmost == null || leftmost.x == rightmost.x) {
    return null;
  }
  final double dx = (rightmost.x - leftmost.x).toDouble();
  final double dy = (rightmost.y - leftmost.y).toDouble();
  return math.atan2(dy, dx) * 180.0 / math.pi;
}

/// 通用溢色计数：底色 [bg] 为 0xRRGGBB。判定与门禁镜像对称 ——
/// 「不接近纯底色」且「沿底色主方向的色偏 > 40」的像素计一个。
///
/// 门禁只查绿和品红两个方向，这里推广成任意底色：设底色的高通道集合 H、
/// 低通道集合 L，只要 min(H) − max(L) > 40 且该像素不接近纯底色，就算溢色。
int spillCount(img.Image image, List<int> highIdx, List<int> lowIdx) {
  int count = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final List<int> c = <int>[p.r.toInt(), p.g.toInt(), p.b.toInt()];
      int hiMin = 255, loMax = 0;
      for (final int i in highIdx) {
        if (c[i] < hiMin) hiMin = c[i];
      }
      for (final int i in lowIdx) {
        if (c[i] > loMax) loMax = c[i];
      }
      // 接近纯底色的像素排除（与门禁 isNearPureGreen/Magenta 同构）。
      bool nearPure = true;
      for (final int i in highIdx) {
        if (c[i] <= 200) nearPure = false;
      }
      for (final int i in lowIdx) {
        if (c[i] >= 100) nearPure = false;
      }
      if (!nearPure && (hiMin - loMax) > 40) {
        count++;
      }
    }
  }
  return count;
}

/// 打印一张图里所有「溢色像素」的分布摘要，便于定位是哪一块出的问题。
String spillProfile(img.Image image, List<int> highIdx, List<int> lowIdx) {
  final Map<int, int> byRow = <int, int>{};
  int total = 0;
  int worst = 0;
  int worstX = -1, worstY = -1;
  List<int> worstC = <int>[0, 0, 0];
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final List<int> c = <int>[p.r.toInt(), p.g.toInt(), p.b.toInt()];
      int hiMin = 255, loMax = 0;
      for (final int i in highIdx) {
        if (c[i] < hiMin) hiMin = c[i];
      }
      for (final int i in lowIdx) {
        if (c[i] > loMax) loMax = c[i];
      }
      bool nearPure = true;
      for (final int i in highIdx) {
        if (c[i] <= 200) nearPure = false;
      }
      for (final int i in lowIdx) {
        if (c[i] >= 100) nearPure = false;
      }
      final int d = hiMin - loMax;
      if (!nearPure) {
        // 记录**所有**非纯底色像素里的最大色偏，哪怕没越线 ——
        // 只报「0」看不出余量，40 的判定线离得有多近必须知道。
        if (d > worst) {
          worst = d;
          worstX = x;
          worstY = y;
          worstC = c;
        }
        if (d > 40) {
          total++;
          byRow[y] = (byRow[y] ?? 0) + 1;
        }
      }
    }
  }
  if (total == 0) {
    return '0（判定线 40，全图非纯底色像素的最大色偏 $worst'
        '@($worstX,$worstY) rgb=$worstC，余量 ${40 - worst}）';
  }
  final List<int> rows = byRow.keys.toList()..sort();
  final String head = rows
      .take(12)
      .map((int r) => '$r:${byRow[r]}')
      .join(' ');
  return '$total（行分布 $head${rows.length > 12 ? ' …共 ${rows.length} 行' : ''}；'
      '最差 ($worstX,$worstY) rgb=$worstC 差值 $worst）';
}

// ---------------------------------------------------------------------------

const BackgroundStyle bgGreen =
    BackgroundStyle(id: '_t_green', nameZh: '测试绿', colorTop: 0xFF00FF00);
const BackgroundStyle bgMagenta =
    BackgroundStyle(id: '_t_magenta', nameZh: '测试品红', colorTop: 0xFFFF00FF);
const BackgroundStyle bgRed =
    BackgroundStyle(id: '_t_red', nameZh: '测试红', colorTop: 0xFFFF0000);
const BackgroundStyle bgBlue =
    BackgroundStyle(id: '_t_blue', nameZh: '测试蓝', colorTop: 0xFF0000FF);

void main() {
  final ComposeOnlyEngine engine = ComposeOnlyEngine();

  test('门禁同款：2B.1–2B.5 七规格几何', () async {
    final GateSynthetic syn = buildGateSynthetic();
    for (final PhotoSpec spec in kBuiltInSpecs) {
      final Candidate c = await engine.compose(
        matting: syn.matting,
        spec: spec,
        style: kBgWhite,
        face: syn.face,
      );
      final img.Image d = img.decodeJpg(c.jpegBytes)!;
      final List<int>? dens = readJpegDpi(c.jpegBytes);
      final PxCentroid? head =
          centroid(findMatches(d, kCyanR, kCyanG, kCyanB, tolerance: 60));
      final PxCentroid? chin = centroid(
          findMatches(d, kMagentaR, kMagentaG, kMagentaB, tolerance: 60));
      final String geo = (head == null || chin == null)
          ? '标记条未测到 head=$head chin=$chin'
          : '头高比 ${((chin.y - head.y) / d.height).toStringAsFixed(4)}'
              '(期望 ${spec.headHeightRatio}) '
              '留白比 ${(head.y / d.height).toStringAsFixed(4)}'
              '(期望 ${spec.headTopRatio}) '
              '居中偏差 ${((head.x - d.width / 2).abs() / d.width * 100).toStringAsFixed(2)}%';
      // ignore: avoid_print
      print('[2B.1-5] ${spec.id} ${d.width}x${d.height} '
          'dpi=$dens $geo');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('门禁同款：2B.6/2B.7 溢色（绿/品红/红/蓝四种极端底色）', () async {
    final GateSynthetic syn = buildGateSynthetic();
    final List<List<Object>> cases = <List<Object>>[
      <Object>['纯绿', bgGreen, <int>[1], <int>[0, 2]],
      <Object>['纯品红', bgMagenta, <int>[0, 2], <int>[1]],
      <Object>['纯红', bgRed, <int>[0], <int>[1, 2]],
      <Object>['纯蓝', bgBlue, <int>[2], <int>[0, 1]],
    ];
    for (final List<Object> cs in cases) {
      final Candidate c = await engine.compose(
        matting: syn.matting,
        spec: kSpecCn1inch,
        style: cs[1] as BackgroundStyle,
        face: syn.face,
      );
      final img.Image d = img.decodeJpg(c.jpegBytes)!;
      final String profile =
          spillProfile(d, cs[2] as List<int>, cs[3] as List<int>);
      // ignore: avoid_print
      print('[2B.6/7] ${cs[0]} 溢色=$profile');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('门禁同款：2B.8 摆正（门槛外 1.5 倍角）', () async {
    // ⚠️ **本项与门禁的夹具角已经不一致，必须在同一轮里一起挪**（2026-09-17）。
    //
    // 门禁侧的夹具是 `integration_test/compose_eval_test.dart` 的 `[15.0, -15.0]`
    // 与 `tools/gate/gate_G2B.dart` 的 `kDeadZoneDeg = 10.0`（后者独立抄一份、
    // 不读 lib）。自动门槛 10° → 30° 之后，±15° **落进了自动摆正的门槛内**：
    // `planRotation` 不再转动它们，门禁量到的"残余"会等于输入角本身（±15°），
    // 而不是摆正后的残差。那两个文件属 gatekeeper，imaging 不能改 ——
    // 已在报告里请主会话派给 gatekeeper，把夹具角挪到门槛外并同步 kDeadZoneDeg。
    //
    // 本文件按**新常量**取角（1.5 倍门槛），先把引擎侧的行为测出来；门禁侧一旦
    // 采用同样的推导，两边就重新对齐。夹具角必须落在门槛**外**，否则本项量的不是
    // 摆正 —— 下面这条是**前置断言，不是判据**，只让"夹具漂了"错得响。
    //
    // ⚠️⚠️ **但本夹具在 |θ| > 30° 时自身失效，下面打印的残差不是引擎判决**：
    // `buildGateSynthetic` 把 `FaceInfo.box` 写成 `Rect.fromLTWH(kRectX0, headTopY,
    // kRectX1−kRectX0, …)` —— 用的是**未旋转的设计坐标**，而画布已经被
    // `copyRotate` 转过并撑大了。契约规定 box 与抠图同坐标系，引擎据
    // `box.center.dx` 定水平锚点，于是锚点偏量随角度线性增长：
    //
    // | 输入角 | 画布 | face.box.x | 青条真实质心 x | 青条落在裁剪框的归一化 x |
    // |---|---|---|---|---|
    // | +15° | 1328×1611 | 350–650 | 766.8 | 0.886（勉强在框内）|
    // | −15° | 1328×1611 | 350–650 | 560.7 | 0.352 |
    // | +45° | 1697×1697 | 350–650 | 1129.8 | **1.916（头已出画幅）** |
    // | −45° | 1697×1697 | 350–650 | 566.2 | **−1.825（头已出画幅）** |
    //
    // ±15 时代这个错就已经存在（偏心 267px / 61px），只是画幅还兜得住；角度一大
    // 就兜不住了。**这是夹具缺陷，不是引擎缺陷** —— 引擎侧自建夹具
    // （`dev_selfcheck.dart` 的 `_makeSynthetic`，box 严格等于旋转后的头中心）
    // 在 ±45°/±60° 上的残差是 0.000°/0.076°。门禁要测门槛外的角，必须先让
    // `buildGateSynthetic` 从**旋转后的内容**反推 box（例如取匹配像素的外接框），
    // 否则测出来的是夹具自己的偏心。已在报告里回派。
    for (final double roll in <double>[
      kAutoRotateMinAbsDeg * 1.5,
      -kAutoRotateMinAbsDeg * 1.5
    ]) {
      expect(roll.abs() > kAutoRotateMinAbsDeg, isTrue,
          reason: '夹具角 $roll 必须落在门槛外（kAutoRotateMinAbsDeg='
              '$kAutoRotateMinAbsDeg），否则本项退化成量恒等变换，'
              '而本文件没有判据会为此报警');
      final GateSynthetic syn = buildGateSynthetic(rollDeg: roll);
      final Candidate c = await engine.compose(
        matting: syn.matting,
        spec: kSpecCn1inch,
        style: kBgWhite,
        face: syn.face,
      );
      final img.Image d = img.decodeJpg(c.jpegBytes)!;
      final List<PxMatch> head =
          findMatches(d, kCyanR, kCyanG, kCyanB, tolerance: 60);
      final List<PxMatch> chin =
          findMatches(d, kMagentaR, kMagentaG, kMagentaB, tolerance: 60);
      final PxCentroid? hc = centroid(head);
      // ignore: avoid_print
      print('[2B.8] ⚠️本夹具在 |θ|>30° 时 box 未随旋转更新（见上表），'
          '下列残差不是引擎判决，只作对照。roll=$roll 输入画布='
          '${syn.matting.width}x${syn.matting.height} '
          'faceHeadTopY=${syn.face.headTopY.toStringAsFixed(1)} '
          'chinY=${syn.face.chinY.toStringAsFixed(1)} '
          '→ 青色像素=${head.length} 品红像素=${chin.length} '
          '质心=${hc == null ? 'null' : '(${hc.x.toStringAsFixed(1)},${hc.y.toStringAsFixed(1)})'} '
          '残差=${tiltDeg(head)?.toStringAsFixed(2) ?? 'null'}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('门禁同款：2B.9 边界安全', () async {
    final MattingResult m = toMattingResult(buildGateCanvas());
    const FaceInfo edgeFace = FaceInfo(
      box: Rect.fromLTWH(0, 0, 40, 50),
      chinY: 50,
      headTopY: 2,
      rollDeg: 0,
      confidence: 1.0,
    );
    final Candidate c = await engine.compose(
      matting: m,
      spec: kSpecCn1inch,
      style: kBgWhite,
      face: edgeFace,
    );
    final img.Image d = img.decodeJpg(c.jpegBytes)!;
    int black = 0, total = 0;
    for (int x = 0; x < d.width; x++) {
      for (final int y in <int>[0, d.height - 1]) {
        total++;
        final img.Pixel p = d.getPixel(x, y);
        if (p.r == 0 && p.g == 0 && p.b == 0) black++;
      }
    }
    for (int y = 0; y < d.height; y++) {
      for (final int x in <int>[0, d.width - 1]) {
        total++;
        final img.Pixel p = d.getPixel(x, y);
        if (p.r == 0 && p.g == 0 && p.b == 0) black++;
      }
    }
    // ignore: avoid_print
    print('[2B.9] 黑边占比=${(black / total).toStringAsFixed(4)}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
