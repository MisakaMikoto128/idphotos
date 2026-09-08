/// 在后台 isolate 里跑的那部分：解码、缩放、ORT 推理、后处理。
///
/// 主 isolate 只负责 warmUp 时创建会话、以及在这里拿结果。ORT 的 session
/// 是 native 指针，同进程内跨 isolate 共享是安全的（插件自带的
/// `OrtIsolateSession` 用的就是同一套做法），所以这里只传地址。
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../api.dart';
import 'image_ops.dart';
import 'ort_runtime.dart';
import 'yunet_decoder.dart';

/// 前景占比低于这个值就认为"这张图里没有可抠的人像"。
///
/// 风景照 / 纯文字截图喂给 MODNet 会得到几乎全 0 的 mask，此时返回一张
/// 空图对用户毫无意义，按契约抛 [MattingException]（"抠图失败了，换一张试试吧"）。
/// 黄金集 8 张的前景占比在 0.21–0.69，阈值取 0.01 有足够余量。
const double kMinForegroundRatio = 0.01;

/// alpha 放回原图时的最小羽化 sigma（约 1–2px 过渡带）。
const double kMinFeatherSigma = 0.6;

/// 放大倍率低于这个值就认为"没有阶梯、但边缘偏硬"，固定补一次最小羽化。
const double kHardEdgeUpscale = 1.5;

/// 选羽化半径。
///
/// alpha 从 512×512 放回原图用的是面积重采样（与生成黄金集参考的
/// `cv2.INTER_AREA` 同一套公式，G2A.3–2A.5 才对得上）。面积法在放大时
/// 会把一个源像素摊成 `upscale × upscale` 的方块，边缘出现与放大倍率同宽的
/// 阶梯。取 sigma = upscale / 4（约半个阶梯）刚好把台阶抹平又不糊掉发丝；
/// 阶梯本身不到一个像素（sigma < 0.6）时就不必再模糊了。
/// 反过来，图比 512 还小的时候没有阶梯但边缘发硬，固定给 [kMinFeatherSigma]。
double featherSigmaFor(double upscale) {
  if (upscale < kHardEdgeUpscale) return kMinFeatherSigma;
  final sigma = upscale / 4;
  return sigma >= kMinFeatherSigma ? sigma : 0.0;
}

/// 抠图结果的可跨 isolate 载荷。用 [TransferableTypedData] 搬运，
/// 4000×3000 的图 rgba 有 48MB，走普通拷贝会明显拖慢一次调用。
class MattingPayload {
  MattingPayload(this.rgba, this.alpha, this.width, this.height);

  final TransferableTypedData rgba;
  final TransferableTypedData alpha;
  final int width;
  final int height;

  MattingResult materialize() => MattingResult(
        rgba: rgba.materialize().asUint8List(),
        alpha: alpha.materialize().asUint8List(),
        width: width,
        height: height,
      );
}

/// 完整抠图流程，同步执行。调用方负责把它放进 isolate。
MattingPayload runMattingSync(Uint8List bytes, int sessionAddress) {
  final image = decodeToRgb(bytes);
  final input = modnetInput(
      image.rgb, image.width, image.height, kMattingInputSize);

  final outputs = runFloatInput(
    sessionAddress,
    input,
    <int>[1, 3, kMattingInputSize, kMattingInputSize],
    const <String>[],
  );
  Uint8List small;
  try {
    small = _matteToBytes(outputs.first?.value, kMattingInputSize);
  } finally {
    for (final o in outputs) {
      o?.release();
    }
  }

  var alpha = areaResampleGray(
      small, kMattingInputSize, kMattingInputSize, image.width, image.height);
  final upscale = (image.width + image.height) / (2.0 * kMattingInputSize);
  final sigma = featherSigmaFor(upscale);
  if (sigma > 0) {
    alpha = featherGray(alpha, image.width, image.height, sigma);
  }

  var foreground = 0;
  for (var i = 0; i < alpha.length; i++) {
    if (alpha[i] >= 128) foreground++;
  }
  if (foreground < alpha.length * kMinForegroundRatio) {
    throw const MattingException();
  }

  return MattingPayload(
    TransferableTypedData.fromList(<Uint8List>[image.toRgba()]),
    TransferableTypedData.fromList(<Uint8List>[alpha]),
    image.width,
    image.height,
  );
}

/// 完整人脸检测流程，同步执行。没检出返回 null（契约要求不抛异常）。
FaceInfo? runFaceSync(Uint8List bytes, int sessionAddress) {
  final image = decodeToRgb(bytes);
  final input =
      yunetInput(image.rgb, image.width, image.height, kFaceInputSize);

  final outputs = runFloatInput(
    sessionAddress,
    input.data,
    <int>[1, 3, kFaceInputSize, kFaceInputSize],
    kYunetOutputNames,
  );
  final raw = <RawFace>[];
  try {
    for (var i = 0; i < kYunetStrides.length; i++) {
      raw.addAll(decodeStride(
        kYunetStrides[i],
        kFaceInputSize,
        _flatten(outputs[i]?.value),
        _flatten(outputs[3 + i]?.value),
        _flatten(outputs[6 + i]?.value),
        _flatten(outputs[9 + i]?.value),
      ));
    }
  } finally {
    for (final o in outputs) {
      o?.release();
    }
  }
  if (raw.isEmpty) return null;
  final kept = nonMaxSuppression(raw);
  if (kept.isEmpty) return null;
  // 证件照只关心主体人物：取面积最大的那张脸。
  kept.sort((a, b) => b.area.compareTo(a.area));
  final face = toFaceInfo(kept.first, input.scale, image.width, image.height);
  final ratio = face.box.width * face.box.height / (image.width * image.height);
  if (ratio < kMinFaceAreaRatio) {
    return null;
  }
  return face;
}

/// `[1,1,512,512]` 的嵌套输出 → 512*512 的 uint8。
///
/// 取整方式刻意与参考实现的 `(matte * 255).astype("uint8")` 一致：向零截断，
/// 不是四舍五入。差一个 LSB 在 g08 这类发丝图上会实打实地影响 IoU。
Uint8List _matteToBytes(dynamic value, int size) {
  final out = Uint8List(size * size);
  var i = 0;
  // 直接在嵌套结构上就地转换，不先摊平成 26 万个元素的 List<double>：
  // 那一步在中端机上要多花几十毫秒，而 2A.6 只有 1.5s 的预算。
  void walk(dynamic v) {
    if (v is num) {
      if (i >= out.length) {
        throw const MattingException(cause: 'matte longer than expected');
      }
      var b = (v * 255).toInt();
      if (b < 0) b = 0;
      if (b > 255) b = 255;
      out[i++] = b;
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    } else {
      throw MattingException(cause: 'unexpected ORT output node: $v');
    }
  }

  walk(value);
  if (i != out.length) {
    throw MattingException(
        cause: 'unexpected matte length $i (want ${out.length})');
  }
  return out;
}

/// ORT 的 Dart 绑定把输出还原成嵌套 List，这里压平成一维 double 列表。
List<double> _flatten(dynamic value) {
  final out = <double>[];
  void walk(dynamic v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    } else {
      throw MattingException(cause: 'unexpected ORT output node: $v');
    }
  }

  walk(value);
  return out;
}
