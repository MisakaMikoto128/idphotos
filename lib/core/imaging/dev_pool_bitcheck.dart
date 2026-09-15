/// 木照 MuZhao — 合成路径逐位回归（开发期工装，不进发布路径）。
///
/// 用途：验证工作缓冲复用（WorkBufferPool / 编码器实例 / 编码画布缓存）
/// **不改变任何输出字节**。运行两次 —— 改动前打一次基线、改动后打一次，
/// 两次输出逐行 diff 必须完全一致：
///
/// ```
/// flutter test lib/core/imaging/dev_pool_bitcheck.dart > out/tmp/bitcheck_before.txt
/// （改动）
/// flutter test lib/core/imaging/dev_pool_bitcheck.dart > out/tmp/bitcheck_after.txt
/// ```
///
/// 序列刻意覆盖三类复用场景：
/// 1. **同键连发**：同一 spec 连续换底色（renderComposite 的 rgb 缓冲同键反复
///    命中），任何"上一张残留像素泄进这一张"都会立刻变哈希；
/// 2. **跨图同键**：两张同尺寸合成人像按 spec 交替合成（模拟 batch 里连续
///    两张图），覆盖跨图串染；
/// 3. **跨 spec 轮转**：7 个规格轮转，覆盖全部缓冲键的换入换出。
///
/// 哈希用 FNV-1a 64 位 + 字节长度，不引入任何依赖；对逐位差异的敏感度足够
/// （单字节变化必变哈希）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

// flutter_test 是 dev_dependency；本文件是纯开发期工装，不进发布路径。
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../api.dart';
import '../specs/photo_specs.dart';
import 'compose_only_engine.dart';

const Timeout _long = Timeout(Duration(minutes: 20));

/// FNV-1a 64 位流式哈希。
class _Fnv {
  int _h = 0xcbf29ce484222325;
  void add(Uint8List b) {
    for (int i = 0; i < b.length; i++) {
      _h ^= b[i];
      _h = (_h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
  }

  String get value => _h.toRadixString(16).padLeft(16, '0');
}

String _hash(Uint8List b) {
  final _Fnv f = _Fnv()..add(b);
  return '${b.length}:${f.value}';
}

MattingResult _loadGolden(String id) {
  final img.Image? src =
      img.decodeJpg(File('test/golden/src/$id.jpg').readAsBytesSync());
  final img.Image? ref =
      img.decodePng(File('test/golden/ref/$id.png').readAsBytesSync());
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

/// 由参考 alpha 反推 FaceInfo（与 dev_selfcheck.dart 同口径的简化版）。
FaceInfo _faceFromAlpha(MattingResult m) {
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

/// 合成人像（软边矩形头 + 颈肩，饱和蓝底），两种"内容"靠颜色与几何区分，
/// 尺寸相同 —— 用来打跨图同键复用的串染。
MattingResult _synthMatting({
  required int width,
  required int height,
  required double headCx,
  required double headTopY,
  required double chinY,
  required double headWidth,
  required List<int> skin,
}) {
  final Uint8List rgba = Uint8List(width * height * 4);
  final Uint8List alpha = Uint8List(width * height);
  const List<int> bg = <int>[26, 92, 176];
  const List<int> cloth = <int>[46, 54, 70];
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
      final List<int> col = y < chinY + 40 ? skin : cloth;
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

void main() {
  final ComposeOnlyEngine engine = ComposeOnlyEngine();

  test('合成路径逐位哈希（跨缓冲复用回归）', () async {
    final StringBuffer log = StringBuffer();

    const BackgroundStyle green =
        BackgroundStyle(id: 'probe_green', nameZh: '探针绿', colorTop: 0xFF00FF00);
    const BackgroundStyle blue =
        BackgroundStyle(id: 'kBgBlue', nameZh: '蓝', colorTop: 0xFF134A85);
    const BackgroundStyle white =
        BackgroundStyle(id: 'kBgWhite', nameZh: '白', colorTop: 0xFFFFFFFF);

    // ---- 1. 黄金集 8 张 × 7 规格 × 3 底色（跨 spec 轮转 + 同键连发）----
    for (int i = 1; i <= 8; i++) {
      final String id = 'g${i.toString().padLeft(2, '0')}';
      final MattingResult m = _loadGolden(id);
      final FaceInfo face = _faceFromAlpha(m);
      for (final PhotoSpec spec in photoSpecs) {
        for (final BackgroundStyle style in <BackgroundStyle>[green, blue, white]) {
          final Candidate c = await engine.compose(
              matting: m, spec: spec, style: style, face: face);
          log.writeln('$id ${spec.id} ${style.id} '
              '${_hash(c.jpegBytes)} ${_hash(c.thumbBytes)}');
        }
      }
    }

    // ---- 2. 同尺寸双图交替（跨图同键串染）----
    final List<MattingResult> twins = <MattingResult>[
      _synthMatting(
          width: 1100,
          height: 1500,
          headCx: 420,
          headTopY: 300,
          chinY: 660,
          headWidth: 260,
          skin: const <int>[232, 184, 140]),
      _synthMatting(
          width: 1100,
          height: 1500,
          headCx: 640,
          headTopY: 380,
          chinY: 800,
          headWidth: 340,
          skin: const <int>[150, 205, 190]),
    ];
    final List<FaceInfo> twinFaces = twins.map(_faceFromAlpha).toList();
    for (final PhotoSpec spec in photoSpecs) {
      for (int k = 0; k < twins.length; k++) {
        final Candidate c = await engine.compose(
            matting: twins[k],
            spec: spec,
            style: kBgWhite,
            face: twinFaces[k]);
        log.writeln('twin$k ${spec.id} '
            '${_hash(c.jpegBytes)} ${_hash(c.thumbBytes)}');
      }
    }

    // ---- 3. 摆正 + 用户框选越界（同一图反复 compose 的另一条路径）----
    final MattingResult t0 = twins[0];
    final FaceInfo f0 = twinFaces[0];
    for (final PhotoSpec spec in photoSpecs) {
      final Candidate c1 = await engine.compose(
          matting: t0,
          spec: spec,
          style: kBgWhite,
          face: f0,
          cropOverride: Rect.fromCenter(
              center: const Offset(40, 40), width: 460, height: 644));
      final Candidate c2 = await engine.compose(
          matting: t0, spec: spec, style: blue, face: f0);
      log.writeln('oob ${spec.id} ${_hash(c1.jpegBytes)} ${_hash(c2.jpegBytes)}');
    }

    // ignore: avoid_print
    print('BITCHECK-BEGIN\n$log BITCHECK-END');
  }, timeout: _long);
}
