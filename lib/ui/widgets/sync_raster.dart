/// 同步位图渲染（截图/测试场景专用，替代 `Image.memory`）。
///
/// ## 为什么必须有这个 widget
///
/// `Image.memory` 的解码由引擎在后台线程**异步**完成，解码完成前该 widget
/// 一个像素都不画。截图流水线（`pumpAndSettle` → `convertFlutterSurfaceToImage`
/// → `takeScreenshot`）只等"已被调度的帧"——解码回调落地之前没有任何帧被调度，
/// `pumpAndSettle` 会提前退出，于是最后呈现进截图的帧可能仍是"照片尚未解码"
/// 的那一帧。这就是官方 S2 截图**间歇性**整张丢照片、候选全空白的根因
/// （out/VISUAL_2C.md 致命项 [F-场景]，同一场景 S2_small 却正常）。
///
/// [SyncRaster] 用纯 Dart 的 `image` 包**同步**解码字节，把像素铺成顶点色
/// 三角网格（`canvas.drawVertices`），**首帧即出图、全程无异步**，
/// CONTRACTS §7.1 的"同一 id 每次画出同一帧"因此真正成立。
///
/// ## 性能与适用范围
///
/// 同步解码 + 网格构建是一次性成本（32 万像素 ≈ 几十毫秒），结果按字节
/// 身份缓存。**只给截图/测试场景的小图用**（由 `UiConfig.syncRaster` 打开）；
/// 真实用户照片（可达上千万像素）仍走 `Image.memory` 异步解码，
/// 否则会卡住首帧。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

/// 已解码的位图：源尺寸 + 顶点色网格。
final class _Raster {
  final int width;
  final int height;
  final ui.Vertices vertices;

  const _Raster(this.width, this.height, this.vertices);
}

/// 按**字节实例身份**缓存（不用哈希做 key，避免碰撞导致渲染错图）。
/// 场景里的样张与候选缩略图都是进程级缓存的同一份字节，条目数 ≤ 8。
final List<(Uint8List, _Raster)> _cache = <(Uint8List, _Raster)>[];

_Raster _rasterFor(Uint8List bytes) {
  for (final (Uint8List b, _Raster r) in _cache) {
    if (identical(b, bytes)) return r;
  }
  final _Raster r = _build(bytes);
  _cache.add((bytes, r));
  return r;
}

_Raster _build(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw ArgumentError.value(
      bytes.length,
      'bytes',
      'SyncRaster: 无法解码的图片数据',
    );
  }
  final Uint8List px = decoded.getBytes(order: img.ChannelOrder.rgba);
  final int w = decoded.width;
  final int h = decoded.height;

  // 网格步长：长边约 160 格。顶点色沿网格线性插值，插值精度随网格变细
  // 收敛到原图；160 格在候选缩略图/区域 A 显示尺寸下与原图肉眼无差，
  // 而顶点量（约 10 万）对 GPU 是一次普通 draw call。
  final int step =
      (math.max(w, h) / 160).ceil().clamp(1, 64);
  final int quadsX = ((w + step - 1) / step).ceil();
  final int quadsY = ((h + step - 1) / step).ceil();
  final int triVerts = quadsX * quadsY * 6;

  final List<Offset> positions = List<Offset>.filled(triVerts, Offset.zero);
  final List<Color> colors = List<Color>.filled(triVerts, const Color(0xFF000000));

  Color sampleColor(int x, int y) {
    final int i = (y.clamp(0, h - 1) * w + x.clamp(0, w - 1)) * 4;
    return Color.fromARGB(255, px[i], px[i + 1], px[i + 2]);
  }

  int vi = 0;
  for (int qy = 0; qy < quadsY; qy++) {
    for (int qx = 0; qx < quadsX; qx++) {
      final double x0 = (qx * step).toDouble();
      final double y0 = (qy * step).toDouble();
      final double x1 = math.min((qx + 1) * step, w).toDouble();
      final double y1 = math.min((qy + 1) * step, h).toDouble();
      final Color c00 = sampleColor(qx * step, qy * step);
      final Color c10 = sampleColor((qx + 1) * step, qy * step);
      final Color c01 = sampleColor(qx * step, (qy + 1) * step);
      final Color c11 = sampleColor((qx + 1) * step, (qy + 1) * step);

      // 三角 1：(x0,y0) (x1,y0) (x0,y1)
      positions[vi] = Offset(x0, y0);
      colors[vi++] = c00;
      positions[vi] = Offset(x1, y0);
      colors[vi++] = c10;
      positions[vi] = Offset(x0, y1);
      colors[vi++] = c01;
      // 三角 2：(x1,y0) (x1,y1) (x0,y1)
      positions[vi] = Offset(x1, y0);
      colors[vi++] = c10;
      positions[vi] = Offset(x1, y1);
      colors[vi++] = c11;
      positions[vi] = Offset(x0, y1);
      colors[vi++] = c01;
    }
  }

  final ui.Vertices vertices = ui.Vertices(
    ui.VertexMode.triangles,
    positions,
    colors: colors,
  );
  return _Raster(w, h, vertices);
}

/// 同步出图的位图 widget。[fit] 支持 fill（区域 A 的 `photo_display` 矩形
/// 本就与原图同比例）与 cover（候选缩略图裁满相纸）。
class SyncRaster extends StatelessWidget {
  final Uint8List bytes;
  final BoxFit fit;

  const SyncRaster({super.key, required this.bytes, this.fit = BoxFit.fill});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        return CustomPaint(
          size: Size(c.maxWidth, c.maxHeight),
          painter: _SyncRasterPainter(
            raster: _rasterFor(bytes),
            fit: fit,
          ),
        );
      },
    );
  }
}

class _SyncRasterPainter extends CustomPainter {
  final _Raster raster;
  final BoxFit fit;

  const _SyncRasterPainter({required this.raster, required this.fit});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || raster.width == 0 || raster.height == 0) return;
    final Rect dst = Offset.zero & size;
    // 顶点网格铺在整张源图上；cover 时按窗口比例裁源，fill 时全图铺满。
    final Rect src;
    if (fit == BoxFit.cover) {
      final double s = math.max(size.width / raster.width,
          size.height / raster.height);
      src = Rect.fromCenter(
        center: Offset(raster.width / 2, raster.height / 2),
        width: (size.width / s).clamp(1.0, raster.width.toDouble()),
        height: (size.height / s).clamp(1.0, raster.height.toDouble()),
      );
    } else {
      src = Rect.fromLTWH(0, 0, raster.width.toDouble(), raster.height.toDouble());
    }
    canvas.save();
    canvas.clipRect(dst);
    canvas.translate(dst.left, dst.top);
    canvas.scale(dst.width / src.width, dst.height / src.height);
    canvas.translate(-src.left, -src.top);
    canvas.drawVertices(raster.vertices, ui.BlendMode.srcOver, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SyncRasterPainter old) => !identical(old.raster, raster);
}
