/// 大图的降采样解码（dart:ui 主路径）。
///
/// 4958×7017 的扫描件如果用 image 包全分辨率解码，光解码缓冲就要 ~104MB，
/// 叠加后续中间份就是 G4.7 的 814MB 峰值。`instantiateImageCodec` 的
/// targetWidth/targetHeight 让原生解码器（Skia / Android ImageDecoder）
/// 直接产出目标尺寸，Dart 侧从头到尾只见 ~12MB 的小图。
///
/// **只用于降采样路径**：小图（≤[kEngineMaxEdge]）继续走 image 包，
/// 逐字节保持黄金集口径，不让 Skia 的 JPEG 解码数值混进来。
///
/// 语义已用探针钉死（`native/bench/ui_decode_probe_test.dart`）：
/// 1. EXIF orientation 由 dart:ui 烘焙（与 image 包 4.9、cv2.imread 一致），
///    所以 target 尺寸要按**摆正后**的尺寸给；
/// 2. 同时给 targetWidth/targetHeight 时输出恰好是该尺寸（宽高比按
///    规划值传入，畸变 ≤1px）；
/// 3. 同传两个 target 不会保持宽高比，因此**必须**自己算好等比尺寸。
///
/// 这里不按 orientation 分流：调用方对**所有** orientation 传摆正后的
/// 目标尺寸。dart:ui 烘焙 EXIF 已在 Android 设备端实测（ml_probe2_main
/// 的 P1：orientation=6 样张解出 128×64 且顶边带出现在右侧），不再是
/// "Windows 探针结论不外推"的悬案；后台 isolate 解码不可用（P2）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'image_ops.dart';

class UiDecodeResult {
  UiDecodeResult(this.rgba, this.width, this.height);

  /// RGBA，长度 = width * height * 4。
  final Uint8List rgba;
  final int width;
  final int height;
}

/// 把 [bytes] 解码到 `targetW x targetH`。任何失败返回 null，
/// 调用方退化到 image 包兜底路径——这里不许抛，否则等于把
/// "快路径失败"升级成"整张图失败"。
Future<UiDecodeResult?> decodeDownsampledUi(
  Uint8List bytes,
  int targetW,
  int targetH,
) async {
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();
    if (data == null || w != targetW || h != targetH) return null;
    return UiDecodeResult(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        w,
        h);
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}
