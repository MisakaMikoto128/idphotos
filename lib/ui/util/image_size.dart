/// 从字节流的文件头**同步**读出图片像素尺寸。
///
/// 为什么不用 `decodeImageFromList`：那是异步的，会让裁剪框的几何布局依赖
/// "图片解码完成"这个时序。CONTRACTS §7.1 要求截图场景**确定性**，
/// gatekeeper 的 widget test（G2C.5/2C.6/2C.7）也需要在不解码像素的前提下
/// 就能拿到正确的裁剪框坐标。因此这里只解析文件头，纯同步、零分配。
///
/// `AppState` 只给了 `sourceImage` 字节和 `suggestedCrop`（原图像素坐标），
/// 没有给宽高；UI 必须自己算出来才能把原图坐标映射到屏幕坐标。
///
/// 解析器本体（simplify 起）在 `lib/core/image_header.dart`——与引擎侧
/// `readImageHeaderSize` 是同一份实现（原先两处逐行双写，已合并）。
/// 这里只保留 UI 侧的 [PixelSize] 类型与摆正语义包装。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';

import '../../core/image_header.dart';

/// 解析结果。解析不出来时返回 null，调用方退化到默认比例。
class PixelSize {
  final int width;
  final int height;

  const PixelSize(this.width, this.height);

  double get aspectRatio => width / height;

  @override
  bool operator ==(Object other) =>
      other is PixelSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// 支持 JPEG / PNG / GIF / BMP / WebP(VP8, VP8L, VP8X)。
///
/// 与引擎侧同一口径：**返回摆正后的尺寸**（见 [applyOrientation] 与
/// `lib/core/image_header.dart` 的文档——orientation 5–8 的手机竖拍照，
/// 按 SOF 原始宽高建立坐标系会把整套取景算错）。
PixelSize? readImageSize(Uint8List bytes) {
  final ImageHeaderSize? h = readImageHeaderSize(bytes);
  return h == null ? null : PixelSize(h.width, h.height);
}

/// EXIF orientation 值 5/6/7/8 表示图像被旋转了 90°，**摆正后宽高互换**。
///
/// 引擎侧 `decodeToRgb()` 显式调了 `img.bakeOrientation`，所以
/// `MattingResult.width/height` 和 `AppState.suggestedCrop` 全都在**摆正后**的
/// 坐标系里；Flutter 的 `Image.memory` 渲染的也是摆正后的位图。UI 若按 SOF 头的
/// 原始宽高建立坐标系，一张 orientation=6 的手机竖拍照就会用 4000×3000 去解读
/// 一个 3000×4000 空间里的建议框，再把转置空间里的矩形回传给 `setCrop` ——
/// 取景整个是错的。共享解析器已按此口径返回摆正后尺寸；本函数保留给
/// 需要显式做"原始→摆正"换算的调用方。
PixelSize applyOrientation(PixelSize raw, int orientation) =>
    (orientation >= 5 && orientation <= 8)
        ? PixelSize(raw.height, raw.width)
        : raw;
