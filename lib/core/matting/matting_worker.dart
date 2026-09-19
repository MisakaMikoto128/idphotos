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
import 'iris_roll.dart';
import 'ort_runtime.dart';
import 'yunet_decoder.dart';

/// 前景占比低于这个值就认为"这张图里没有可抠的人像"。
///
/// 风景照 / 纯文字截图喂给抠图模型会得到几乎全 0 的 mask，此时返回一张
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

/// 碎片化判据的膨胀轮数，**以 512 模型尺度为基准**：4 轮 3×3 = 半径 4，
/// 512 尺度下足以把发丝/睫毛归并进主体（黄金集最碎的 g08 在 d4 下
/// lg_fg=0.836），又不至于把画面里真正互不相连的物体粘成一块。
///
/// 实际轮数随模型输入尺寸等比放大（见 [ensureCoherentSubject]）：发丝的
/// 物理宽度不随输入尺寸变，1024 尺度要粘住同样物理宽度的缝隙需要半径 8。
/// 注意阈值 [kMinLargestComponentShare] 是按 512 口径校准的，膨胀半径
/// 换算保持物理一致后，占比统计的物理口径也随之保持一致。
const int kFragDilateRadius = 4;

/// 膨胀面积低于该值的连通域视为噪声，不参与碎片统计。
const int kFragMinComponentArea = 16;

/// alpha 放回原图时的最小羽化 sigma（约 1–2px 过渡带）。
const double kMinFeatherSigma = 0.6;

/// 模型输出 alpha 在**模型尺度**上的去斑 + 平滑参数。
///
/// 为什么必须在模型尺度上做、而不是放大回工作分辨率之后再做：
/// 模型输出是一张 N×N（N = kMattingInputSize）网格上的场，轮廓的过渡带
/// 只有约一个模型像素宽。直接面积放大到工作分辨率，只是把这个一像素宽的
/// 台阶拉成坡——台阶的**拐角仍然钉在模型网格上**。下游 `render.dart` 会把
/// alpha **二值化**（`hardenAlpha` 恒返回 0/1）并按 `alphaMax ≥ 191` 强制
/// 不透明，于是轮廓呈现为一堆轴对齐的直角缺口/凸块（实测 p_1x2「1 (2).jpg」
/// 的头顶轮廓、p_2 的左侧发际线，512 输入 3× 放大后肉眼可见）。
///
/// 先在模型尺度上抹掉这个台阶，再放大，轮廓才是连续曲线。
///
/// - [kMatteMedianPasses] 轮 3×3 中值：吃掉孤立的高 alpha 噪点。这些噪点
///   正是下游 `alphaMax ≥ 191` 强制不透明的触发源——一个模型像素上的孤立
///   亮点会被放大成一块输出像素的方块凸起。
/// - [kMatteSmoothSigma] 高斯 sigma（**以模型像素为单位**）：把一像素宽的
///   台阶展宽成几像素的坡，使 0.5 阈值穿越点连续变化。
///
/// sigma 取 0.4 的依据（512 时代的实测，native/bench/matting_bench_test.dart）：
///
/// | 中值 | sigma | g08 edgeMAE |
/// |---|---|---|
/// | 0 | 0（= 改前基线） | 0.1085 |
/// | 1 | 0.3 | 0.1109 |
/// | 1 | **0.4** | **0.1131** |
/// | 1 | 0.6 | 0.1228 ← 超旧 2A.5 线 |
///
/// **1024 下的换算**：过渡带在模型网格上仍约 1 像素宽，而 1024 的 1 模型
/// 像素只有 512 的一半物理宽度——sigma 保持 0.4（模型像素）即把同样的
/// 网格台阶抹成坡，物理模糊量自动减半，这正是换 1024 想要的效果。旧 2A.5
/// 的 0.12 edgeMAE 上限随 512 口径作废（主会话重校准中），不再是约束；
/// 但也不要因此加码——更重的平滑会把发丝细节糊掉，与提分辨率的目的相悖。
///
/// 另一条试过并被否决的路：把上采样从 INTER_AREA 换成双线性/双三次。
/// 台阶确实少了一半，但网格上那条一像素宽的坡线性插值后仍是折线
/// （native/bench/out/up_p_2.png 中间那张），消不干净；而 guided filter
/// 反而更差——它会把轮廓吸到头发内部的强纹理上，重新长出直角
/// （native/bench/out/zg_p_2.png）。两者都没采纳。
const int kMatteMedianPasses = 1;
const double kMatteSmoothSigma = 0.4;

/// 放大倍率低于这个值就认为"没有阶梯、但边缘偏硬"，固定补一次最小羽化。
const double kHardEdgeUpscale = 1.5;

/// 选羽化半径。
///
/// alpha 从模型尺寸放回原图用的是面积重采样（历史上与生成黄金集参考的
/// `cv2.INTER_AREA` 同一套公式）。面积法在放大时会把一个源像素摊成
/// `upscale × upscale` 的方块，边缘出现与放大倍率同宽的阶梯。
/// 取 sigma = upscale / 4（约半个阶梯，**以输出像素为单位**）刚好把台阶
/// 抹平又不糊掉发丝——阶梯宽度随放大倍率变化，所以这个公式天然适配
/// 任何模型输入尺寸：1024 输入下 upscale 减半，羽化量自动减半。
/// 阶梯本身不到一个像素（sigma < 0.6）时就不必再模糊了。
/// 反过来，图比模型输入还小的时候没有阶梯但边缘发硬，固定给 [kMinFeatherSigma]。
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
/// 文案"没找到人脸，请手动框选"经 controller 错误通道渲染）——抠图模型对任意图
/// 都会强抠出一个"显著主体"，电路板/地球仪/风景的 alpha 甚至相当连贯，
/// 单看 alpha 结构杀不掉这些伪主体；校准数据（88 张全量，见
/// frag_gate_calib_test.dart）显示它是唯一能把"黄金集+14 张人像全过"与
/// "21 张伪成功非人像全拒"同时做干净的分界：真图主脸面积 ≥0.066、置信度
/// ≥0.93，全部伪成功非人像要么无脸要么主脸 ≤0.019。门槛放在抠图
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
  final alpha = _matteFromModelInput(
      input, sessionAddress, image.width, image.height);
  return _MattingCore(alpha, subjectFace);
}

/// 模型输出的模型尺度 alpha → 交给下游的 alpha：去斑 + 平滑。
///
/// 参数依据见 [kMatteSmoothSigma]。两步都作用在模型尺度（[size]×[size]）
/// 上，必须在放大回工作分辨率**之前**做，否则网格台阶已经烙进数据里了。
///
/// [medianPasses]/[smoothSigma] 仅供 bench 做参数 A/B；生产路径不传，
/// 走 [kMatteMedianPasses]/[kMatteSmoothSigma] 常量。
Uint8List cleanMatte(Uint8List alpha, int size,
    {int? medianPasses, double? smoothSigma}) {
  var out = alpha;
  for (var i = 0; i < (medianPasses ?? kMatteMedianPasses); i++) {
    out = medianGray3(out, size, size);
  }
  final sigma = smoothSigma ?? kMatteSmoothSigma;
  if (sigma > 0) {
    out = featherGray(out, size, size, sigma);
  }
  return out;
}

/// 抠图模型推理 + alpha 后处理（前景占比/碎片门槛、放大回工作分辨率、羽化）。
///
/// 输入是已按 [modnetInput]/[modnetInputFromRgba] 备好的 NCHW
/// （边长 = [kMattingInputSize]）——rgb 路径（黄金集口径）与 RGBA 预计算
/// 路径（G4 r3）共用同一套实现，喂进模型的字节逐位一致，产出也逐位一致。
Uint8List _matteFromModelInput(
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
  // 在模型尺度上去斑 + 平滑（理由见 kMatteSmoothSigma 的注释）。放在两个
  // 门槛之前：门槛应当判"实际会交给下游的那张 alpha"，而不是清理前的中间态。
  small = cleanMatte(small, kMattingInputSize);

  var foreground = 0;
  for (var i = 0; i < small.length; i++) {
    if (small[i] >= 128) foreground++;
  }
  if (foreground < small.length * kMinForegroundRatio) {
    throw const MattingException();
  }
  // 碎片化兜底门槛：在模型尺度上做（便宜、与成片分辨率无关），在分配
  // 大图缓冲之前就把碎片状 alpha 拒掉。
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
/// （YuNet letterbox + 抠图 N²，N = kMattingInputSize）由调用方在宿主
/// isolate 直接从 RGBA 算好带进来，worker 里不再持有 rgba、不再转紧凑
/// rgb——Isolate.run 的闭包拷贝从 w*h*4 降到固定两张 Float32 输入
/// （1024 口径下 4.9+12.6 ≈ 17.5MB），worker 峰值少掉
/// ~22MB（rgba 12.6 + rgb 9.4，2048 工作分辨率口径）。喂进模型的字节与
/// 旧路径**逐位一致**（见 [modnetInputFromRgba] 的等价论证），输出不变。
///
/// [faceSessionAddress] 非 null 时先跑人像门槛（同 [runFaceFromRgb] 口径：
/// YuNet + pickSubjectFace + kMinFaceAreaRatio），检不到抛
/// [NoFaceException]。此时 [yunetInput] 必须非 null。
///
/// [gray] 是工作分辨率灰度平面（宿主从同一份 rgba 备好），供瞳孔级眼线
/// 估计用；它是 1 字节/像素的额外拷贝（相对本路径已有的 8MB Float32 输入
/// 是 +w·h 字节），换来的是人像门槛返回的 [FaceInfo] 与 detectFace 逐位
/// 同口径——controller 先 removeBackground 再 detectFace 会命中缓存，
/// 两者给不出不同的 rollDeg。传 null 则该次门槛不产摆正角。
MattingPayload runMattingPrecomputed({
  required Float32List mattingInput,
  LetterboxInput? yunetInput,
  Uint8List? gray,
  required int sessionAddress,
  int? faceSessionAddress,
  required int width,
  required int height,
  int? sourceWidth,
  int? sourceHeight,
}) {
  FaceInfo? subjectFace;
  if (faceSessionAddress != null) {
    subjectFace = faceFromYunetInput(yunetInput!, faceSessionAddress, width,
        height, gray: gray);
    if (subjectFace == null) {
      // 文案/控制流与 _mattingCore 的门槛分支逐字一致。
      throw const NoFaceException(cause: 'face gate: no subject face');
    }
  }
  final alpha = _matteFromModelInput(mattingInput, sessionAddress, width,
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
  // [kFragDilateRadius] 是 512 尺度的轮数；膨胀半径的物理含义是"把相距
  // 多远的发丝粘回主体"，发丝物理宽度不随模型输入尺寸变，故按边长等比
  // 换算（512→4 轮，1024→8 轮）。
  final dilateRounds = size * kFragDilateRadius ~/ 512;
  assert(dilateRounds >= 1, 'matting input size too small for frag gate');
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
  for (var it = 0; it < dilateRounds; it++) {
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
///
/// [gray] 为 null 时跳过瞳孔级眼线估计，[FaceInfo.rollSource] 为
/// `unavailable`、`rollDeg` 为 0.0（诚实失败，不回退眼睑关键点）。
FaceInfo? runFaceFromRgb(DecodedImage image, int sessionAddress,
    {bool withPupilRoll = true}) {
  final input =
      yunetInput(image.rgb, image.width, image.height, kFaceInputSize);
  return faceFromYunetInput(
    input,
    sessionAddress,
    image.width,
    image.height,
    gray: withPupilRoll
        ? grayPlaneFromRgb(image.rgb, image.width, image.height)
        : null,
  );
}

/// [runFaceFromRgb] 的核心：从备好的 YuNet letterbox 输入跑检测。
///
/// 供 rgb 路径与预计算输入路径（G4 r3）共用；同一输入产出同一 FaceInfo。
///
/// [gray] 是**工作分辨率**灰度平面（长度 `imgW*imgH`），用于瞳孔级眼线
/// 估计（P0 修复）。传 null 则该次检测放弃摆正角（`rollSource =
/// unavailable`），而不是退回 YuNet 眼睑连线。
FaceInfo? faceFromYunetInput(LetterboxInput input, int sessionAddress, int imgW,
    int imgH, {Uint8List? gray}) {
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
  final face = pickSubjectFace(kept, imgW, imgH);
  // 主脸面积门槛（判据与旧实现逐位一致，只是提前到建 FaceInfo 之前，
  // 免得对注定被拒的图白跑一次瞳孔估计）。
  final double boxW = face.w / input.scale;
  final double boxH = face.h / input.scale;
  if (boxW * boxH / (imgW * imgH) < kMinFaceAreaRatio) {
    return null;
  }
  PupilRoll? pupil;
  if (gray != null) {
    pupil = estimatePupilRoll(
      gray: gray,
      width: imgW,
      height: imgH,
      eyeAx: face.landmarks[0] / input.scale,
      eyeAy: face.landmarks[1] / input.scale,
      eyeBx: face.landmarks[2] / input.scale,
      eyeBy: face.landmarks[3] / input.scale,
    );
  }
  return toFaceInfo(face, input.scale, imgW, imgH, pupil: pupil);
}

/// `[1,1,N,N]` 的嵌套输出 → N*N 的 uint8（N = 模型输入边长）。
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
