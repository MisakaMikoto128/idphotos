/// 木照 MuZhao — imaging 自检（G2B.1 – G2B.9 实测）。
///
/// 运行方式（项目根目录）：
///
/// ```
/// C:\src\flutter\bin\flutter test lib/core/imaging/dev_selfcheck.dart
/// ```
///
/// 为什么不用 `dart run`：`lib/core/api.dart` 依赖 `dart:ui`，纯 Dart VM 起不来。
/// `flutter test` 自带 flutter_tester engine，能提供 `dart:ui`，也能用 `dart:io`
/// 读黄金集文件。
///
/// ## 自检原则
///
/// 1. **测真正交付的字节**。所有几何、溢色指标都是把 `Candidate.jpegBytes`
///    重新解码回像素后测出来的，不是测中间缓冲 —— JPEG 的振铃与色度处理
///    同样会制造溢色，绕过编码等于没测。
/// 2. **不自证**。几何指标不复算裁剪公式，而是在成片里**找像素**：
///    合成图中肤色区域的最高行 / 最低行 / 质心 x，直接给出头顶留白比、
///    头高比、水平居中偏差。
/// 3. **溢色用最严的方式判**。把参考 alpha 用**最近邻点采样**映射到成片坐标系
///    （而不是与渲染同款的盒式滤波），这样任何「边缘上我糊了、验收脚本没糊」
///    的偏差都会暴露出来，而不是被同款滤波掩盖。
///
/// 本文件不进入发布路径（不被 `lib/main.dart` 引用），但留在仓库里，
/// 任何人改了合成流水线都能一条命令复测。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

// flutter_test 是 dev_dependency；本文件是纯开发期自检，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_only_engine.dart';
import 'crop_geometry.dart';
import 'jpeg_dpi.dart';

// ---------------------------------------------------------------------------
// 测试用素材
// ---------------------------------------------------------------------------

/// 合成的「证件照原片」。刻意用饱和蓝底，方便暴露去色边是否到位。
class _Synth {
  final MattingResult matting;
  final FaceInfo face;
  const _Synth(this.matting, this.face);
}

const List<int> _kBgBlue = <int>[26, 92, 176]; // 原片背景（待换掉）
const List<int> _kSkin = <int>[232, 184, 140]; // 头部
const List<int> _kCloth = <int>[46, 54, 70]; // 肩部
const List<int> _kEye = <int>[196, 24, 24]; // 摆正测量用的两个标记点

double _ellipseCoverage(
    double x, double y, double cx, double cy, double rx, double ry) {
  final double dx = (x - cx) / rx;
  final double dy = (y - cy) / ry;
  final double f = math.sqrt(dx * dx + dy * dy);
  final double rmin = math.min(rx, ry);
  // (1 − f) · rmin 近似到边界的像素距离；3px 过渡带模拟真实抠图的软边。
  final double s = (1.0 - f) * rmin;
  return (s / 3.0 + 0.5).clamp(0.0, 1.0).toDouble();
}

/// 矩形的软边覆盖率（3px 过渡带），[l]/[r]/[t]/[b] 为边界坐标。
double _rectCoverage(double x, double y, double l, double r, double t,
    double b) {
  final double sd = math.min(math.min(x - l, r - x), math.min(y - t, b - y));
  return (sd / 3.0 + 0.5).clamp(0.0, 1.0).toDouble();
}

/// 生成一张合成人像。所有几何都在「设计空间」定义，再按 [rollDeg] 整体旋转
/// 到图像空间，于是 [FaceInfo] 的坐标可以精确算出来，不依赖任何检测器。
///
/// 头部刻意画成**软边矩形**而不是椭圆：矩形的上下边是平的，成片里肤色区域的
/// 最高行 / 最低行就精确等于 headTopY / chinY，测量本身不引入形状误差。
/// 颈与肩用另一种颜色，避免把非头部像素误计进头高。
_Synth _makeSynthetic({
  required int width,
  required int height,
  required double headCx,
  required double headTopY,
  required double chinY,
  required double headWidth,
  double rollDeg = 0.0,
  bool withEyeMarkers = false,
}) {
  final Uint8List rgba = Uint8List(width * height * 4);
  final Uint8List alpha = Uint8List(width * height);
  final double cx = width / 2.0;
  final double cy = height / 2.0;
  final double rad = rollDeg * math.pi / 180.0;
  // 图像空间 → 设计空间：p_d = C + R(−θ)(p_s − C)
  final double c = math.cos(-rad);
  final double s = math.sin(-rad);

  final double headCy = (headTopY + chinY) / 2.0;
  final double ry = (chinY - headTopY) / 2.0;
  final double rx = headWidth / 2.0;
  final double neckTop = chinY - 3.0;
  final double shoulderTop = chinY + ry * 0.35;
  final double eyeY = headTopY + (chinY - headTopY) * 0.45;
  final double eyeDx = rx * 0.45;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double px = x + 0.5;
      final double py = y + 0.5;
      final double dx0 = px - cx;
      final double dy0 = py - cy;
      final double xd = cx + c * dx0 - s * dy0;
      final double yd = cy + s * dx0 + c * dy0;

      final double head = _rectCoverage(
          xd, yd, headCx - rx, headCx + rx, headTopY, chinY);
      final double neck = _rectCoverage(xd, yd, headCx - rx * 0.34,
          headCx + rx * 0.34, neckTop, shoulderTop + 2.0);
      final double shoulder = yd >= shoulderTop
          ? _ellipseCoverage(
              xd, yd, headCx, shoulderTop + ry * 3.4, rx * 2.3, ry * 3.4)
          : 0.0;

      double a = math.max(head, math.max(neck, shoulder));
      List<int> col = head >= math.max(neck, shoulder) ? _kSkin : _kCloth;

      if (withEyeMarkers && head > 0.5) {
        if (((xd - (headCx - eyeDx)).abs() <= 3.0 ||
                (xd - (headCx + eyeDx)).abs() <= 3.0) &&
            (yd - eyeY).abs() <= 3.0) {
          col = _kEye;
        }
      }

      final int ai = y * width + x;
      final int p = ai * 4;
      alpha[ai] = (a * 255).round().clamp(0, 255);
      // 原片 = 前景与原背景真实混合过，边缘像素天然带着蓝底 —— 这正是去色边要解的。
      for (int ch = 0; ch < 3; ch++) {
        rgba[p + ch] = (col[ch] * a + _kBgBlue[ch] * (1 - a)).round();
      }
      rgba[p + 3] = 255;
    }
  }

  // FaceInfo 用图像空间坐标：把设计空间的点按 +θ 转过去。
  final double cc = math.cos(rad);
  final double ss = math.sin(rad);
  List<double> toImg(double xd, double yd) {
    final double dx = xd - cx;
    final double dy = yd - cy;
    return <double>[cx + cc * dx - ss * dy, cy + ss * dx + cc * dy];
  }

  final List<double> top = toImg(headCx, headTopY);
  final List<double> chin = toImg(headCx, chinY);
  final List<double> fc = toImg(headCx, headCy);
  final FaceInfo face = FaceInfo(
    box: Rect.fromCenter(
        center: Offset(fc[0], fc[1]),
        width: headWidth,
        height: chinY - headTopY),
    headTopY: top[1],
    chinY: chin[1],
    rollDeg: rollDeg,
    confidence: 1.0,
  );
  // headTopY/chinY 在旋转后不再严格是「头顶/下巴的 y」，但契约就是这么定义的：
  // 二者之差即头高，合成引擎按刚体变换处理。
  return _Synth(
    MattingResult(rgba: rgba, alpha: alpha, width: width, height: height),
    face,
  );
}

// ---------------------------------------------------------------------------
// 解码与测量
// ---------------------------------------------------------------------------

class _Decoded {
  final Uint8List rgb; // w*h*3
  final int width;
  final int height;
  const _Decoded(this.rgb, this.width, this.height);

  int r(int x, int y) => rgb[(y * width + x) * 3];
  int g(int x, int y) => rgb[(y * width + x) * 3 + 1];
  int b(int x, int y) => rgb[(y * width + x) * 3 + 2];
}

_Decoded _decodeJpeg(Uint8List bytes) {
  final img.Image? im = img.decodeJpg(bytes);
  if (im == null) {
    throw StateError('成品 JPEG 解不开');
  }
  final Uint8List rgba = im.getBytes(order: img.ChannelOrder.rgb);
  return _Decoded(rgba, im.width, im.height);
}

bool _near(_Decoded d, int x, int y, List<int> c, int tol) {
  return (d.r(x, y) - c[0]).abs() <= tol &&
      (d.g(x, y) - c[1]).abs() <= tol &&
      (d.b(x, y) - c[2]).abs() <= tol;
}

/// 在成片里找肤色区域，返回 [minY, maxY, centroidX, 计数]。
List<double> _measureHead(_Decoded d, {int tol = 26}) {
  int minY = 1 << 30;
  int maxY = -1;
  double sumX = 0;
  int n = 0;
  for (int y = 0; y < d.height; y++) {
    for (int x = 0; x < d.width; x++) {
      if (_near(d, x, y, _kSkin, tol)) {
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        sumX += x;
        n++;
      }
    }
  }
  return <double>[
    minY.toDouble(),
    maxY.toDouble(),
    n > 0 ? sumX / n : -1.0,
    n.toDouble(),
  ];
}

// ---------------------------------------------------------------------------

Uint8List _readFile(String p) => File(p).readAsBytesSync();

MattingResult _loadGolden(String id) {
  final img.Image? src = img.decodeJpg(_readFile('test/golden/src/$id.jpg'));
  final img.Image? ref = img.decodePng(_readFile('test/golden/ref/$id.png'));
  if (src == null || ref == null) {
    throw StateError('黄金集 $id 读取失败');
  }
  final Uint8List rgba = src.getBytes(order: img.ChannelOrder.rgba);
  final Uint8List refBytes = ref.getBytes(order: img.ChannelOrder.rgb);
  final Uint8List alpha = Uint8List(src.width * src.height);
  for (int i = 0; i < alpha.length; i++) {
    alpha[i] = refBytes[i * 3];
  }
  return MattingResult(
      rgba: rgba, alpha: alpha, width: src.width, height: src.height);
}

/// 由参考 alpha 粗略反推一个 FaceInfo。
///
/// 阶段 2 拿不到 ml-porting 的真实人脸检测，这里用轮廓宽度做一个人体测量学近似：
/// 取头顶往下 8%–20% 处轮廓宽度的中位数当头宽，再按「头高 ≈ 1.35 × 头宽」
/// 反推下巴位置。这只影响自检取景是否像张证件照，不影响任何 G2B 指标 ——
/// 溢色 / DPI / 尺寸都与 chinY 的精度无关。阶段 4 会换成真实 FaceInfo 复测。
FaceInfo _faceFromAlpha(MattingResult m) {
  int minY = 1 << 30, maxY = -1, minX = 1 << 30, maxX = -1;
  for (int y = 0; y < m.height; y++) {
    final int row = y * m.width;
    for (int x = 0; x < m.width; x++) {
      if (m.alpha[row + x] > 128) {
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
  }
  if (maxY < 0) {
    minX = 0;
    minY = 0;
    maxX = m.width - 1;
    maxY = m.height - 1;
  }
  final double headTop = minY.toDouble();
  final int bboxH = maxY - minY + 1;
  final List<int> widths = <int>[];
  final int y0 = (minY + bboxH * 0.08).round();
  final int y1 = (minY + bboxH * 0.20).round();
  for (int y = y0; y <= y1 && y < m.height; y++) {
    int w = 0;
    for (int x = 0; x < m.width; x++) {
      if (m.alpha[y * m.width + x] > 128) w++;
    }
    widths.add(w);
  }
  widths.sort();
  final double headW =
      widths.isEmpty ? bboxH * 0.4 : widths[widths.length ~/ 2].toDouble();
  final double headH =
      math.max(8.0, math.min(headW * 1.35, bboxH * 0.95));
  // 头部质心 x：取头顶往下半个头高那一行的前景重心
  final int probeY = (headTop + headH * 0.5).round().clamp(0, m.height - 1);
  double sx = 0;
  int n = 0;
  for (int x = 0; x < m.width; x++) {
    if (m.alpha[probeY * m.width + x] > 128) {
      sx += x;
      n++;
    }
  }
  final double cx = n > 0 ? sx / n : (minX + maxX) / 2.0;
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

// ---------------------------------------------------------------------------

void main() {
  final ComposeOnlyEngine engine = ComposeOnlyEngine();
  const Timeout long = Timeout(Duration(minutes: 10));

  test('2B.1 / 2B.2 输出尺寸与 JFIF DPI（7 个规格）', () async {
    final _Synth s = _makeSynthetic(
      width: 900,
      height: 1300,
      headCx: 450,
      headTopY: 260,
      chinY: 620,
      headWidth: 300,
    );
    final StringBuffer log = StringBuffer();
    for (final PhotoSpec spec in photoSpecs) {
      final Candidate c = await engine.compose(
          matting: s.matting, spec: spec, style: kBgWhite, face: s.face);
      final _Decoded d = _decodeJpeg(c.jpegBytes);
      final List<int>? dpi = readJpegDpi(c.jpegBytes);
      final List<int>? dpiIndep = _independentDpiScan(c.jpegBytes);
      final _Decoded t = _decodeJpeg(c.thumbBytes);
      log.writeln('  ${spec.id.padRight(20)} '
          '${d.width}x${d.height} (期望 ${spec.widthPx}x${spec.heightPx}) '
          'dpi=$dpi 独立解析=$dpiIndep '
          '缩略图=${t.width}x${t.height} '
          '成品=${c.jpegBytes.length}B 缩略=${c.thumbBytes.length}B');
      expect(d.width, spec.widthPx, reason: '${spec.id} 宽');
      expect(d.height, spec.heightPx, reason: '${spec.id} 高');
      expect(dpi, <int>[300, 300], reason: '${spec.id} DPI');
      expect(dpiIndep, <int>[300, 300], reason: '${spec.id} DPI（独立解析）');
      expect(math.max(t.width, t.height), kThumbEdgeExpect,
          reason: '${spec.id} 缩略图长边');
    }
    // ignore: avoid_print
    print('[2B.1/2B.2]\n$log');
  }, timeout: long);

  test('2B.3 / 2B.4 / 2B.5 头高比 / 头顶留白 / 水平居中', () async {
    final StringBuffer log = StringBuffer();
    double worstHead = 0, worstTop = 0, worstCenter = 0;
    // 三种取景：正常、人脸偏左、人脸偏小
    final List<_Synth> cases = <_Synth>[
      _makeSynthetic(
          width: 900,
          height: 1300,
          headCx: 450,
          headTopY: 260,
          chinY: 620,
          headWidth: 300),
      _makeSynthetic(
          width: 1200,
          height: 900,
          headCx: 320,
          headTopY: 120,
          chinY: 380,
          headWidth: 210),
      _makeSynthetic(
          width: 1600,
          height: 2000,
          headCx: 800,
          headTopY: 500,
          chinY: 760,
          headWidth: 220),
    ];
    for (int ci = 0; ci < cases.length; ci++) {
      final _Synth s = cases[ci];
      for (final PhotoSpec spec in <PhotoSpec>[...kBuiltInSpecs, ...photoSpecs]) {
        final Candidate c = await engine.compose(
            matting: s.matting, spec: spec, style: kBgWhite, face: s.face);
        final _Decoded d = _decodeJpeg(c.jpegBytes);
        final List<double> m = _measureHead(d);
        expect(m[3] > 100, isTrue, reason: '成片里没找到头部像素');
        final double headTopRatio = (m[0] + 0.5) / d.height;
        final double headHeightRatio = (m[1] - m[0] + 1) / d.height;
        final double centerOff =
            (m[2] - (d.width - 1) / 2.0).abs() / d.width;
        worstTop = math.max(worstTop, (headTopRatio - spec.headTopRatio).abs());
        worstHead = math.max(
            worstHead, (headHeightRatio - spec.headHeightRatio).abs());
        worstCenter = math.max(worstCenter, centerOff);
        log.writeln('  case$ci ${spec.id.padRight(20)} '
            'headTop=${headTopRatio.toStringAsFixed(4)}'
            '(目标 ${spec.headTopRatio}) '
            'headH=${headHeightRatio.toStringAsFixed(4)}'
            '(目标 ${spec.headHeightRatio}) '
            'centerOff=${(centerOff * 100).toStringAsFixed(2)}%');
      }
    }
    // ignore: avoid_print
    print('[2B.3/2B.4/2B.5]\n$log'
        '  最差头高比偏差=${worstHead.toStringAsFixed(4)} (阈值 0.02)\n'
        '  最差头顶留白偏差=${worstTop.toStringAsFixed(4)} (阈值 0.02)\n'
        '  最差水平偏心=${(worstCenter * 100).toStringAsFixed(2)}% (阈值 3%)');
    expect(worstHead <= 0.02, isTrue);
    expect(worstTop <= 0.02, isTrue);
    expect(worstCenter <= 0.03, isTrue);
  }, timeout: long);

  test('2B.6 / 2B.7 溢色（纯绿 / 纯品红底，黄金集 8 张 × 7 规格）', () async {
    const BackgroundStyle green =
        BackgroundStyle(id: 'probe_green', nameZh: '探针绿', colorTop: 0xFF00FF00);
    const BackgroundStyle magenta = BackgroundStyle(
        id: 'probe_magenta', nameZh: '探针品红', colorTop: 0xFFFF00FF);
    final StringBuffer log = StringBuffer();
    int totalGreen = 0;
    int totalMagenta = 0;
    int checkedPixels = 0;
    int maxGreen = -999;
    int maxMagenta = -999;
    final List<List<int>> offenders = <List<int>>[];
    int bgAttributable = 0;

    for (int i = 1; i <= 8; i++) {
      final String id = 'g${i.toString().padLeft(2, '0')}';
      final MattingResult m = _loadGolden(id);
      final FaceInfo face = _faceFromAlpha(m);
      for (final PhotoSpec spec in photoSpecs) {
        final Candidate cg = await engine.compose(
            matting: m, spec: spec, style: green, face: face);
        final RectD crop = engine.lastDiagnostics!.cropRect;
        final Candidate cm = await engine.compose(
            matting: m, spec: spec, style: magenta, face: face);
        final _Decoded dg = _decodeJpeg(cg.jpegBytes);
        final _Decoded dm = _decodeJpeg(cm.jpegBytes);
        final Uint8List mask = _alphaMaskNearest(m, crop, spec);
        int ng = 0, nm = 0, cnt = 0;
        for (int p = 0; p < mask.length; p++) {
          if (mask[p] <= 200) continue;
          cnt++;
          final int x = p % spec.widthPx;
          final int y = p ~/ spec.widthPx;
          final int gr = dg.r(x, y), gg = dg.g(x, y), gb = dg.b(x, y);
          final int ge = gg - math.max(gr, gb);
          if (ge > maxGreen) maxGreen = ge;
          if (ge > 40) ng++;
          final int mr = dm.r(x, y), mg = dm.g(x, y), mb = dm.b(x, y);
          final int me = math.min(mr, mb) - mg;
          if (me > maxMagenta) maxMagenta = me;
          if (me > 40) {
            nm++;
            offenders.add(<int>[x, y, mr, mg, mb]);
          }
        }
        totalGreen += ng;
        totalMagenta += nm;
        checkedPixels += cnt;
        log.writeln('  $id ${spec.id.padRight(20)} '
            '受检像素=$cnt 绿溢色=$ng 品红溢色=$nm');
        if (offenders.isNotEmpty) {
          // 「溢色」按定义是**底色渗进前景**，所以必须用换底前后的差异来判：
          // 同一坐标在白底成片里是什么颜色？两者一致就说明这是被摄者自身的
          // 颜色（紫红色衣物 / 深紫头发），换任何底色都会是这个样子，
          // 不是渗色。少了这一步就分不清「真渗色」和「人本来就穿紫衣服」。
          final Candidate cw = await engine.compose(
              matting: m, spec: spec, style: kBgWhite, face: face);
          final _Decoded dw = _decodeJpeg(cw.jpegBytes);
          for (final List<int> o in offenders) {
            final int wr = dw.r(o[0], o[1]),
                wg = dw.g(o[0], o[1]),
                wb = dw.b(o[0], o[1]);
            final int meWhite = math.min(wr, wb) - wg;
            final int delta = (math.min(o[2], o[4]) - o[3]) - meWhite;
            if (delta > 8) {
              bgAttributable++;
            }
            log.writeln('    ↳ (${o[0]},${o[1]}) '
                '品红底 rgb=[${o[2]},${o[3]},${o[4]}] '
                '白底 rgb=[$wr,$wg,$wb] '
                '底色贡献=$delta ${delta > 8 ? '← 真渗色' : '（被摄者自身颜色）'}');
          }
          offenders.clear();
        }
      }
    }
    // ignore: avoid_print
    print('[2B.6/2B.7]\n$log'
        '  合计受检像素=$checkedPixels\n'
        '  绿底溢色像素总数=$totalGreen (阈值 0)，'
        '全集最大 G−max(R,B)=$maxGreen (判定线 40)\n'
        '  品红底绝对计数=$totalMagenta，其中**底色造成的**=$bgAttributable (阈值 0)，'
        '全集最大 min(R,B)−G=$maxMagenta (判定线 40)');
    expect(totalGreen, 0);
    // 绝对计数不作为断言：真实人像里本来就可能有紫红色的衣物/头发，
    // 它们在**任何**底色下都满足 min(R,B)−G>40，与换底质量无关。
    // 门禁的 2B.7 用的是灰色合成人像，不含这种自然色，所以那里绝对计数=0
    // 是可达的；对真实照片只能判「底色是否渗进来」。
    expect(bgAttributable, 0);
  }, timeout: long);

  test('2B.6 / 2B.7 溢色（验收脚本口径：全图逐像素，不看 alpha）', () async {
    const BackgroundStyle green =
        BackgroundStyle(id: 'probe_green', nameZh: '探针绿', colorTop: 0xFF00FF00);
    const BackgroundStyle magenta = BackgroundStyle(
        id: 'probe_magenta', nameZh: '探针品红', colorTop: 0xFFFF00FF);
    final StringBuffer log = StringBuffer();
    int total = 0;

    // (a) 复刻验收脚本的灰矩形画布
    final _Synth gate = _makeGateStyleCanvas();
    for (final PhotoSpec spec in kBuiltInSpecs) {
      final Candidate cg = await engine.compose(
          matting: gate.matting, spec: spec, style: green, face: gate.face);
      final Candidate cm = await engine.compose(
          matting: gate.matting, spec: spec, style: magenta, face: gate.face);
      final int ng = _gateStyleSpillCount(_decodeJpeg(cg.jpegBytes), green: true);
      final int nm =
          _gateStyleSpillCount(_decodeJpeg(cm.jpegBytes), green: false);
      total += ng + nm;
      log.writeln('  灰矩形画布 ${spec.id.padRight(20)} 绿=$ng 品红=$nm');
    }

    // (b) 真实黄金集，同一口径
    for (int i = 1; i <= 8; i++) {
      final String id = 'g${i.toString().padLeft(2, '0')}';
      final MattingResult m = _loadGolden(id);
      final FaceInfo face = _faceFromAlpha(m);
      final Candidate cg = await engine.compose(
          matting: m, spec: kSpecCn1inch, style: green, face: face);
      final Candidate cm = await engine.compose(
          matting: m, spec: kSpecCn1inch, style: magenta, face: face);
      final int ng = _gateStyleSpillCount(_decodeJpeg(cg.jpegBytes), green: true);
      final int nm =
          _gateStyleSpillCount(_decodeJpeg(cm.jpegBytes), green: false);
      total += ng + nm;
      log.writeln('  黄金集 $id 绿=$ng 品红=$nm');
    }
    // ignore: avoid_print
    print('[2B.6/2B.7 验收口径]\n$log  合计溢色像素=$total (阈值 0)');
    expect(total, 0);
  }, timeout: long);

  test('2B.8 摆正（±10° 输入的残差角）', () async {
    final StringBuffer log = StringBuffer();
    double worst = 0;
    for (final double roll in <double>[-10.0, -6.0, 6.0, 10.0]) {
      final _Synth s = _makeSynthetic(
        width: 1000,
        height: 1400,
        headCx: 500,
        headTopY: 320,
        chinY: 700,
        headWidth: 320,
        rollDeg: roll,
        withEyeMarkers: true,
      );
      final Candidate c = await engine.compose(
          matting: s.matting,
          spec: specCn2inch,
          style: kBgWhite,
          face: s.face);
      final _Decoded d = _decodeJpeg(c.jpegBytes);
      final double? residual = _eyeLineAngleDeg(d);
      expect(residual, isNotNull, reason: 'roll=$roll 时找不到两个标记点');
      worst = math.max(worst, residual!.abs());
      log.writeln('  输入 roll=${roll.toStringAsFixed(1)}° → '
          '成片残差 ${residual.toStringAsFixed(3)}°');
    }
    // 死区验证：小于 ±3° 不应触发旋转
    final _Synth small = _makeSynthetic(
      width: 1000,
      height: 1400,
      headCx: 500,
      headTopY: 320,
      chinY: 700,
      headWidth: 320,
      rollDeg: 2.0,
      withEyeMarkers: true,
    );
    await engine.compose(
        matting: small.matting,
        spec: specCn2inch,
        style: kBgWhite,
        face: small.face);
    final bool straightened = engine.lastDiagnostics!.straightened;
    log.writeln('  输入 roll=2.0°（死区内）→ 是否旋转=$straightened');
    // ignore: avoid_print
    print('[2B.8]\n$log  最差残差=${worst.toStringAsFixed(3)}° (阈值 1.5°)');
    expect(worst <= 1.5, isTrue);
    expect(straightened, isFalse);
  }, timeout: long);

  test('2B.9 边界安全（贴边人脸不抛异常、无黑边）', () async {
    final StringBuffer log = StringBuffer();
    // 人脸贴左上、贴右上、贴底、超大特写
    final List<List<double>> setups = <List<double>>[
      <double>[70, 20, 200, 130], // headCx, headTopY, chinY, headWidth
      <double>[830, 16, 210, 140],
      <double>[450, 640, 860, 200],
      <double>[450, 4, 1180, 640], // 头几乎占满整幅
      <double>[30, 500, 700, 180], // 贴左边中部
    ];
    int worstBlack = 0;
    for (int i = 0; i < setups.length; i++) {
      final List<double> u = setups[i];
      final _Synth s = _makeSynthetic(
        width: 900,
        height: 1300,
        headCx: u[0],
        headTopY: u[1],
        chinY: u[2],
        headWidth: u[3],
      );
      for (final PhotoSpec spec in photoSpecs) {
        final Candidate c = await engine.compose(
            matting: s.matting, spec: spec, style: kBgWhite, face: s.face);
        final _Decoded d = _decodeJpeg(c.jpegBytes);
        final RectD crop = engine.lastDiagnostics!.cropRect;
        // 落在原图之外的输出像素必须是纯白底色，不能是黑的
        int black = 0;
        for (int y = 0; y < d.height; y++) {
          final double ys =
              crop.top + (y + 0.5) * crop.height / d.height;
          for (int x = 0; x < d.width; x++) {
            final double xs =
                crop.left + (x + 0.5) * crop.width / d.width;
            final bool outside = xs < 0 ||
                ys < 0 ||
                xs >= s.matting.width ||
                ys >= s.matting.height;
            if (!outside) continue;
            if (d.r(x, y) < 210 || d.g(x, y) < 210 || d.b(x, y) < 210) {
              black++;
            }
          }
        }
        worstBlack = math.max(worstBlack, black);
        if (black > 0) {
          log.writeln('  setup$i ${spec.id} 图外区域非白像素=$black');
        }
      }
      log.writeln('  setup$i 完成，越界比例='
          '${(engine.lastDiagnostics!.outOfBoundsFraction * 100).toStringAsFixed(1)}%'
          ' 缩小=${engine.lastDiagnostics!.shrunk}'
          ' 说明=${engine.lastDiagnostics!.note}');
    }
    // ignore: avoid_print
    print('[2B.9]\n$log  图外区域出现的非底色像素总数（最差单张）=$worstBlack (阈值 0)');
    expect(worstBlack, 0);
  }, timeout: long);

  test('渐变底与去色边质量（蓝渐变 / 白底，合成原片）', () async {
    final _Synth s = _makeSynthetic(
      width: 900,
      height: 1300,
      headCx: 450,
      headTopY: 260,
      chinY: 620,
      headWidth: 300,
    );
    final Candidate grad = await engine.compose(
        matting: s.matting,
        spec: specCn1inch,
        style: kBgBlueGradient,
        face: s.face);
    final _Decoded d = _decodeJpeg(grad.jpegBytes);
    final int topR = d.r(4, 4), topG = d.g(4, 4), topB = d.b(4, 4);
    final int botR = d.r(4, d.height - 5),
        botG = d.g(4, d.height - 5),
        botB = d.b(4, d.height - 5);
    // ignore: avoid_print
    print('[渐变] 顶部=($topR,$topG,$topB) 期望≈(98,139,206) '
        '底部=($botR,$botG,$botB) 期望≈(43,90,160)');
    expect((topR - 0x62).abs() <= 6, isTrue);
    expect((botB - 0xA0).abs() <= 6, isTrue);

    // 白底：统计人像边缘残留的蓝色偏量（去色边效果的直接量化）
    final Candidate white = await engine.compose(
        matting: s.matting, spec: specCn1inch, style: kBgWhite, face: s.face);
    final _Decoded w = _decodeJpeg(white.jpegBytes);
    int blueish = 0;
    for (int y = 0; y < w.height; y++) {
      for (int x = 0; x < w.width; x++) {
        // 原背景是蓝色；换白底后不该有任何像素蓝分量明显高于红分量
        if (w.b(x, y) - w.r(x, y) > 40) blueish++;
      }
    }
    // ignore: avoid_print
    print('[去色边] 换白底后残留蓝边像素=$blueish (阈值 0)');
    expect(blueish, 0);
  }, timeout: long);
}


/// 复刻验收脚本的画布：中央灰色矩形 + 8px 羽化边 + 橙棕背景。
///
/// 关键差异：验收脚本判溢色时**不看 alpha**，而是遍历成片每个像素，
/// 只放过「接近纯底色」的那些（纯绿：`g>200 && r<100 && b<100`），
/// 其余一旦满足 `G−max(R,B)>40` 就计数。灰色前景与纯绿底之间任何
/// 半透明过渡像素都会被算成溢色 —— 这是比「只查 alpha>200 区域」严得多的口径，
/// 也是成片必须做硬边的直接原因。
_Synth _makeGateStyleCanvas() {
  const int w = 1000, h = 1400;
  const int x0 = 350, x1 = 650, y0 = 300, y1 = 1000;
  const double feather = 8.0;
  final Uint8List rgba = Uint8List(w * h * 4);
  final Uint8List alpha = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double dx = x < x0
          ? (x0 - x).toDouble()
          : (x >= x1 ? (x - x1 + 1).toDouble() : 0.0);
      final double dy = y < y0
          ? (y0 - y).toDouble()
          : (y >= y1 ? (y - y1 + 1).toDouble() : 0.0);
      final double dist = math.sqrt(dx * dx + dy * dy);
      final double a =
          (1.0 - (dist / feather).clamp(0.0, 1.0)).clamp(0.0, 1.0).toDouble();
      final int i = y * w + x;
      alpha[i] = (a * 255).round();
      final int p = i * 4;
      if (a > 0) {
        rgba[p] = 128;
        rgba[p + 1] = 128;
        rgba[p + 2] = 128;
      } else {
        rgba[p] = 180;
        rgba[p + 1] = 120;
        rgba[p + 2] = 60;
      }
      rgba[p + 3] = 255;
    }
  }
  const FaceInfo face = FaceInfo(
    box: Rect.fromLTWH(350, 301.5, 300, 200),
    headTopY: 301.5,
    chinY: 501.5,
    rollDeg: 0.0,
    confidence: 1.0,
  );
  return _Synth(
    MattingResult(rgba: rgba, alpha: alpha, width: w, height: h),
    face,
  );
}

/// 按验收脚本口径数溢色：遍历整幅成片，排除「接近纯底色」的像素。
int _gateStyleSpillCount(_Decoded d, {required bool green}) {
  int n = 0;
  for (int y = 0; y < d.height; y++) {
    for (int x = 0; x < d.width; x++) {
      final int r = d.r(x, y), g = d.g(x, y), b = d.b(x, y);
      if (green) {
        final bool nearBg = g > 200 && r < 100 && b < 100;
        if (!nearBg && (g - math.max(r, b)) > 40) n++;
      } else {
        final bool nearBg = r > 200 && b > 200 && g < 100;
        if (!nearBg && (math.min(r, b) - g) > 40) n++;
      }
    }
  }
  return n;
}

/// 缩略图长边期望值。
const int kThumbEdgeExpect = 320;

/// 独立于 `jpeg_dpi.dart` 的 APP0 解析，避免「用自己写的读器验证自己写的写器」。
List<int>? _independentDpiScan(Uint8List b) {
  for (int i = 0; i + 18 < b.length; i++) {
    if (b[i] == 0xFF &&
        b[i + 1] == 0xE0 &&
        b[i + 4] == 0x4A &&
        b[i + 5] == 0x46 &&
        b[i + 6] == 0x49 &&
        b[i + 7] == 0x46 &&
        b[i + 8] == 0x00) {
      if (b[i + 11] != 1) return null; // 单位必须是「每英寸」
      return <int>[
        (b[i + 12] << 8) | b[i + 13],
        (b[i + 14] << 8) | b[i + 15],
      ];
    }
  }
  return null;
}

/// 把参考 alpha 用**最近邻点采样**搬到成片坐标系（不做任何滤波）。
/// 这是比渲染更严格的采样方式，用来暴露边缘上的滤波差异。
Uint8List _alphaMaskNearest(MattingResult m, RectD crop, PhotoSpec spec) {
  final Uint8List out = Uint8List(spec.widthPx * spec.heightPx);
  for (int y = 0; y < spec.heightPx; y++) {
    final double ys = crop.top + (y + 0.5) * crop.height / spec.heightPx;
    final int sy = ys.floor();
    for (int x = 0; x < spec.widthPx; x++) {
      final double xs = crop.left + (x + 0.5) * crop.width / spec.widthPx;
      final int sx = xs.floor();
      if (sx < 0 || sy < 0 || sx >= m.width || sy >= m.height) continue;
      out[y * spec.widthPx + x] = m.alpha[sy * m.width + sx];
    }
  }
  return out;
}

/// 找两个红色标记点的质心，返回连线相对水平线的夹角（度）。
double? _eyeLineAngleDeg(_Decoded d) {
  double lx = 0, ly = 0, rx = 0, ry = 0;
  int ln = 0, rn = 0;
  final int mid = d.width ~/ 2;
  for (int y = 0; y < d.height; y++) {
    for (int x = 0; x < d.width; x++) {
      if (!_near(d, x, y, _kEye, 40)) continue;
      if (x < mid) {
        lx += x;
        ly += y;
        ln++;
      } else {
        rx += x;
        ry += y;
        rn++;
      }
    }
  }
  if (ln < 4 || rn < 4) return null;
  final double dx = rx / rn - lx / ln;
  final double dy = ry / rn - ly / ln;
  return math.atan2(dy, dx) * 180.0 / math.pi;
}
