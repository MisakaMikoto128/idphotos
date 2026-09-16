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

/// 前景完整性门槛（G4.3 碎片化优雅失败）：把二值 alpha（@128）按
/// [kFragDilateRadius] 轮 3×3 膨胀把碎发/睫毛归并进主体后做连通域，
/// 最大连通域的原前景像素占比低于 [kMinLargestComponentShare] 即判定
/// "前景是一堆碎片，没有可用的主体"。
///
/// 阈值校准（native/bench/frag_gate_calib_test.dart，88 张全量测量）：
/// 黄金集 8 张最低 0.836（g08，发丝最碎的一张），14 张人像/合影里最低
/// 0.497（五人合影，人之间自然留空隙）；取 0.35 与最差真图保持 0.147
/// 余量。注意它**不是** G4.3 的主判据——电路板截图的最大连通域占比高达
/// 0.91，碎片判据杀不掉它也不该误杀合影；主判据是人脸门槛（见
/// runMattingFromRgb 的 faceSessionAddress 注释）。这一条是碎片状 alpha
/// 的兜底（比人脸门槛便宜且与人脸检测的召回无关）。
const double kMinLargestComponentShare = 0.35;

/// 碎片化判据的膨胀轮数。4 轮 3×3 = 半径 4，512 尺度下足以把发丝/睫毛
/// 归并进主体（黄金集最碎的 g08 在 d4 下 lg_fg=0.836），又不至于把画面
/// 里真正互不相连的物体粘成一块。
const int kFragDilateRadius = 4;

/// 膨胀面积低于该值的连通域视为噪声，不参与碎片统计。
const int kFragMinComponentArea = 16;

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
  MattingPayload(
    this.rgba,
    this.alpha,
    this.width,
    this.height, {
    this.sourceWidth,
    this.sourceHeight,
    this.subjectFace,
  }) : alphaOnly = false;

  /// alpha-only 构造（G4.7）：rgba 由调用方（引擎宿主）就地复用，
  /// payload 不携带。materialize 时必须传 rgbaOverride。
  MattingPayload.alphaOnly(
    this.alpha,
    this.width,
    this.height, {
    this.sourceWidth,
    this.sourceHeight,
    this.subjectFace,
  })  : rgba = TransferableTypedData.fromList(const <Uint8List>[]),
        alphaOnly = true;

  final TransferableTypedData rgba;
  final TransferableTypedData alpha;
  final int width;
  final int height;

  /// true = 不携带 rgba，[materialize] 必须传 [MattingPayload.materialize]。
  final bool alphaOnly;

  /// 降采样前的原图（摆正后）尺寸；null = 未降采样。
  final int? sourceWidth;
  final int? sourceHeight;

  /// 人像门槛的检脸结果（与 detectFace 同口径：pickSubjectFace +
  /// kMinFaceAreaRatio）。只在本次调用真正跑过检脸时非"未跑"——
  /// 门没跑时为 null 且引擎不得用它覆盖缓存。FaceInfo 本就跨 isolate
  /// 传递（detectFace 同路径），可安全随 payload 回宿主。
  final FaceInfo? subjectFace;

  MattingResult materialize({Uint8List? rgbaOverride}) =>
      MattingResult(
        rgba: rgbaOverride ?? rgba.materialize().asUint8List(),
        alpha: alpha.materialize().asUint8List(),
        width: width,
        height: height,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
      );
}

/// 完整抠图流程，同步执行。调用方负责把它放进 isolate。
///
/// [maxEdge] 非 null 时解码后立即降采样到该长边（dart:ui 快路径不可用时的
/// 兜底；全尺寸解码的瞬时缓冲不可避免，但后续管线只吃小图）。
/// [faceSessionAddress] 非 null 时先跑人像门槛（见下）。
MattingPayload runMattingSync(Uint8List bytes, int sessionAddress,
    {int? maxEdge, int? targetEdge, int? faceSessionAddress}) {
  final image = decodeToRgb(bytes, maxEdge: maxEdge, targetEdge: targetEdge);
  return runMattingFromRgb(image, sessionAddress,
      faceSessionAddress: faceSessionAddress);
}

/// 抠图推理 + 后处理。输入是已经按引擎工作分辨率解码好的 RGB。
///
/// **人像门槛（G4.3 的主判据）**：[faceSessionAddress] 非 null 时先跑
/// 与 detectFace 完全同口径的检脸（YuNet + pickSubjectFace +
/// kMinFaceAreaRatio），检不到就抛 [NoFaceException]（主会话 r2 指令，
/// 文案"没找到人脸，请手动框选"经 controller 错误通道渲染）——MODNet 对任意图
/// 都会强抠出一个"显著主体"，电路板/地球仪/风景的 alpha 甚至相当连贯，
/// 单看 alpha 结构杀不掉这些伪主体；校准数据（88 张全量，见
/// frag_gate_calib_test.dart）显示它是唯一能把"黄金集+14 张人像全过"与
/// "21 张伪成功非人像全拒"同时做干净的分界：真图主脸面积 ≥0.066、置信度
/// ≥0.93，全部伪成功非人像要么无脸要么主脸 ≤0.019。门槛放在 MODNet
/// **之前**：被拒的图省掉整次抠图推理，失败路径更快、瞬时内存更小。
/// 传 null 表示引擎已用缓存裁决过本次门槛（跳过检脸，省一次推理）。
///
MattingPayload runMattingFromRgb(DecodedImage image, int sessionAddress,
    {int? faceSessionAddress}) {
  final core = _mattingCore(image, sessionAddress,
      faceSessionAddress: faceSessionAddress);
  final Uint8List rgba = image.toRgba();
  return MattingPayload(
    TransferableTypedData.fromList(<Uint8List>[rgba]),
    TransferableTypedData.fromList(<Uint8List>[core.alpha]),
    image.width,
    image.height,
    // 契约口径：只在真的降采样时才填，null = 未降采样（逐位等价旧行为）。
    sourceWidth:
        image.sourceWidth != image.width ? image.sourceWidth : null,
    sourceHeight:
        image.sourceHeight != image.height ? image.sourceHeight : null,
    subjectFace: core.subjectFace,
  );
}

/// 抠图核心：人像门槛（可选）→ MODNet → 前景占比/碎片化门槛 →
/// alpha 放大回工作分辨率 + 羽化。alpha-only 路径与完整 payload 路径共用。
class _MattingCore {
  _MattingCore(this.alpha, this.subjectFace);

  /// 工作分辨率单通道 alpha（已羽化）。
  final Uint8List alpha;
  final FaceInfo? subjectFace;
}

_MattingCore _mattingCore(DecodedImage image, int sessionAddress,
    {int? faceSessionAddress}) {
  FaceInfo? subjectFace;
  if (faceSessionAddress != null) {
    subjectFace = runFaceFromRgb(image, faceSessionAddress);
    if (subjectFace == null) {
      // "图里没有可出证件照的人物"——语义就是没找到人脸，抛 NoFaceException
      // （主会话 r2 指令）：文案"没找到人脸，请手动框选"由 controller 的
      // 错误通道直接渲染，控制流与原 MattingException 完全一致。
      throw const NoFaceException(cause: 'face gate: no subject face');
    }
  }

  final input =
      modnetInput(image.rgb, image.width, image.height, kMattingInputSize);
  final alpha = _matteFromModnetInput(
      input, sessionAddress, image.width, image.height);
  return _MattingCore(alpha, subjectFace);
}

/// MODNet 推理 + alpha 后处理（前景占比/碎片门槛、放大回工作分辨率、羽化）。
///
/// 输入是已按 [modnetInput]/[modnetInputFromRgba] 备好的 512×512 NCHW——
/// rgb 路径（黄金集口径）与 RGBA 预计算路径（G4 r3）共用同一套实现，
/// 喂进模型的字节逐位一致，产出也逐位一致。
Uint8List _matteFromModnetInput(
    Float32List input, int sessionAddress, int dstW, int dstH) {
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

  var foreground = 0;
  for (var i = 0; i < small.length; i++) {
    if (small[i] >= 128) foreground++;
  }
  if (foreground < small.length * kMinForegroundRatio) {
    throw const MattingException();
  }
  // 碎片化兜底门槛：在 512×512 上做（便宜、分辨率无关），在分配大图
  // 缓冲之前就把碎片状 alpha 拒掉。
  ensureCoherentSubject(small);

  var alpha = areaResampleGray(
      small, kMattingInputSize, kMattingInputSize, dstW, dstH);
  final upscale = (dstW + dstH) / (2.0 * kMattingInputSize);
  final sigma = featherSigmaFor(upscale);
  if (sigma > 0) {
    alpha = featherGray(alpha, dstW, dstH, sigma);
  }
  return alpha;
}

/// alpha-only 抠图（G4.7 dart:ui 降采样路径专用）：worker 只回 alpha 与
/// 检脸结果，rgba 由宿主就地复用（强制 A=255），全程不再跨 isolate 搬运
/// 或重建 `w*h*4` 的大缓冲——比完整 payload 路径少两次全尺寸拷贝。
///
/// 生产管线已改走 [runMattingPrecomputed]（G4 r3）；本函数现在唯一的
/// 调用方是 `native/bench/ml_probe3_main.dart`（P1 旧路径复刻探针），
/// 删除前先改探针。
MattingPayload runMattingAlphaOnly(DecodedImage image, int sessionAddress,
    {int? faceSessionAddress}) {
  final core = _mattingCore(image, sessionAddress,
      faceSessionAddress: faceSessionAddress);
  return MattingPayload.alphaOnly(
    TransferableTypedData.fromList(<Uint8List>[core.alpha]),
    image.width,
    image.height,
    sourceWidth:
        image.sourceWidth != image.width ? image.sourceWidth : null,
    sourceHeight:
        image.sourceHeight != image.height ? image.sourceHeight : null,
    subjectFace: core.subjectFace,
  );
}

/// 预计算输入版抠图（G4 r3 dart:ui 降采样路径专用）。
///
/// 与 [runMattingAlphaOnly] 的差别只在**输入缓冲从哪来**：模型输入
/// （YuNet letterbox + MODNet 512²）由调用方在宿主 isolate 直接从 RGBA
/// 算好带进来，worker 里不再持有 rgba、不再转紧凑 rgb——Isolate.run 的
/// 闭包拷贝从 w*h*4 降到固定的 8MB（4.9+3.1），worker 峰值少掉 ~22MB
/// （rgba 12.6 + rgb 9.4，2048 工作分辨率口径）。喂进模型的字节与旧路径
/// **逐位一致**（见 [modnetInputFromRgba] 的等价论证），输出不变。
///
/// [faceSessionAddress] 非 null 时先跑人像门槛（同 [runFaceFromRgb] 口径：
/// YuNet + pickSubjectFace + kMinFaceAreaRatio），检不到抛
/// [NoFaceException]。此时 [yunetInput] 必须非 null。
MattingPayload runMattingPrecomputed({
  required Float32List modnetInput,
  LetterboxInput? yunetInput,
  required int sessionAddress,
  int? faceSessionAddress,
  required int width,
  required int height,
  int? sourceWidth,
  int? sourceHeight,
}) {
  FaceInfo? subjectFace;
  if (faceSessionAddress != null) {
    subjectFace = faceFromYunetInput(yunetInput!, faceSessionAddress,
        width, height);
    if (subjectFace == null) {
      // 文案/控制流与 _mattingCore 的门槛分支逐字一致。
      throw const NoFaceException(cause: 'face gate: no subject face');
    }
  }
  final alpha = _matteFromModnetInput(modnetInput, sessionAddress, width,
      height);
  return MattingPayload.alphaOnly(
    TransferableTypedData.fromList(<Uint8List>[alpha]),
    width,
    height,
    sourceWidth: sourceWidth != width ? sourceWidth : null,
    sourceHeight: sourceHeight != height ? sourceHeight : null,
    subjectFace: subjectFace,
  );
}

/// 碎片化门槛：膨胀后连通域，最大连通域的原前景像素占比必须达到
/// [kMinLargestComponentShare]（判据与校准依据见常量注释）。
void ensureCoherentSubject(Uint8List alpha, {int size = kMattingInputSize}) {
  final n = size * size;
  final fg = Uint8List(n);
  var fgCount = 0;
  for (var i = 0; i < n; i++) {
    if (alpha[i] >= 128) {
      fg[i] = 255;
      fgCount++;
    }
  }
  if (fgCount == 0) return; // 全零由前景占比门槛处理
  var dil = fg;
  for (var it = 0; it < kFragDilateRadius; it++) {
    final next = Uint8List(n);
    for (var y = 0; y < size; y++) {
      final y0 = y > 0 ? y - 1 : 0;
      final y1 = y < size - 1 ? y + 1 : size - 1;
      for (var x = 0; x < size; x++) {
        final x0 = x > 0 ? x - 1 : 0;
        final x1 = x < size - 1 ? x + 1 : size - 1;
        var v = 0;
        for (var yy = y0; yy <= y1 && v == 0; yy++) {
          final base = yy * size;
          for (var xx = x0; xx <= x1; xx++) {
            if (dil[base + xx] != 0) {
              v = 255;
              break;
            }
          }
        }
        next[y * size + x] = v;
      }
    }
    dil = next;
  }
  // 连通域标记（迭代栈，避免递归爆栈）。组件的前景质量 = 组件内
  // 原（未膨胀）前景像素数，这样细碎的噪声组件不会稀释占比。
  final label = Int32List(n);
  final stack = Int32List(n);
  var nComp = 0;
  var bestFgMass = 0;
  for (var seed = 0; seed < n; seed++) {
    if (dil[seed] == 0 || label[seed] != 0) continue;
    nComp++;
    var sp = 0;
    stack[sp++] = seed;
    label[seed] = nComp;
    var fgMass = 0;
    while (sp > 0) {
      final p = stack[--sp];
      if (fg[p] != 0) fgMass++;
      final y = p ~/ size, x = p % size;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= size) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= size) continue;
          final q = yy * size + xx;
          if (dil[q] != 0 && label[q] == 0) {
            label[q] = nComp;
            stack[sp++] = q;
          }
        }
      }
    }
    if (fgMass > bestFgMass) bestFgMass = fgMass;
  }
  // 只统计面积足够的组件：小组件的 fgMass 无论如何都小，这里只需要
  // 最大组件的质量，噪声组件不参与"最大"竞争即可，无需额外过滤。
  if (bestFgMass / fgCount < kMinLargestComponentShare) {
    throw const MattingException(cause: 'fragmented matte');
  }
}

/// 完整人脸检测流程，同步执行。没检出返回 null（契约要求不抛异常）。
FaceInfo? runFaceSync(Uint8List bytes, int sessionAddress,
    {int? maxEdge, int? targetEdge}) {
  final image = decodeToRgb(bytes, maxEdge: maxEdge, targetEdge: targetEdge);
  return runFaceFromRgb(image, sessionAddress);
}

/// 人脸检测推理 + 主体选择。输入是已解码好的 RGB（引擎工作分辨率）。
FaceInfo? runFaceFromRgb(DecodedImage image, int sessionAddress) {
  final input =
      yunetInput(image.rgb, image.width, image.height, kFaceInputSize);
  return faceFromYunetInput(input, sessionAddress, image.width, image.height);
}

/// [runFaceFromRgb] 的核心：从备好的 YuNet letterbox 输入跑检测。
///
/// 供 rgb 路径与预计算输入路径（G4 r3）共用；同一输入产出同一 FaceInfo。
FaceInfo? faceFromYunetInput(
    LetterboxInput input, int sessionAddress, int imgW, int imgH) {
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
  final face = toFaceInfo(
      pickSubjectFace(kept, imgW, imgH), input.scale, imgW, imgH);
  final ratio = face.box.width * face.box.height / (imgW * imgH);
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
