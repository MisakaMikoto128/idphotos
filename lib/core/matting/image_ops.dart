/// 抠图/检脸链路上的纯 Dart 图像算子。
///
/// 这里所有重采样都刻意与 OpenCV 的实现对齐：黄金集参考 alpha
/// （`test/golden/ref/*.png`）是用 `cv2.resize(..., INTER_AREA)` 做前处理、
/// 再用 `INTER_AREA` 放大回原图生成的。G2A.3–2A.5 逐像素比对这份参考，
/// 所以缩放算法一旦跑偏，指标会直接掉下阈值——不要"顺手"换成别的插值。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../api.dart';
import 'image_header.dart';

/// 引擎工作分辨率的长边上限（"要不要降采样"的门槛）。
///
/// 模型输入是 kMattingInputSize²（ort_runtime.dart，1024），alpha 再放大
/// 回去；合成出片最大也就二寸（413×579@300dpi ≈ 1745px）。长边 2048 对
/// 成片质量零损失，但把 4958×7017 这类扫描件的工作缓冲从 ~140MB/份 压到
/// ~12MB/份——这是 G4.7 峰值内存达标的根本手段。黄金集长边全部 ≤2048，
/// 严格大于才降采样，所以对黄金集逐字节零影响。
const int kEngineMaxEdge = 2048;

/// 长边**超过** [kEngineMaxEdge] 的图实际降采样到的工作分辨率长边。
///
/// G4 r3：真机 churn 相位的瞬态峰与"工作缓冲总量"成正比——4032×3024 在
/// 2048 工作分辨率下单份 rgba 12.6MB、compose 去色边再持一份，叠加
/// isolate 拷贝就是真机 615MB 峰值的主要来源。把"确实超过 2048 的大图"
/// 再压到 1536：单份 rgba 7.1MB（-44%），成片（≤579px）的过采样仍有
/// ~2.4×，视觉无损失；黄金集长边 ≤2048 不进这条分支，逐位零影响。
/// 注意 ≤2048 的图**不**再降——黄金集 2048 长边的参考 alpha 就是原生
/// 尺寸产出的，动了就是黄金集回归 FAIL。
///
/// 1024 输入后复核（2026-09-19）：**维持 1536 不动**。抠图细节上限由模型
/// 输入分辨率决定而非工作分辨率，1024 输入下 1536 工作长边对 alpha 的
/// 放大倍率仅 1.5×（512 时代是 3×），大图的发丝收益已经拿到；而把这条
/// 线抬回 2048 会把单份 rgba 从 7.1MB 拉回 12.6MB——G4.7 压峰的根基，
/// 与"抠图质量"无关的内存硬约束，不随本次换档松动。
const int kBigImageWorkEdge = 1536;

/// 引擎工作分辨率的规划结果。
class WorkingSizePlan {
  WorkingSizePlan(
      this.width, this.height, this.sourceWidth, this.sourceHeight,
      {this.orientation = 1});

  /// 引擎工作分辨率（等比降采样后，长边 = [kEngineMaxEdge]）。
  final int width;
  final int height;

  /// 原图（摆正后）尺寸。`width/height == sourceWidth/sourceHeight` 的
  /// 等比关系恒成立，坐标换算只依赖这一对比值。
  final int sourceWidth;
  final int sourceHeight;

  /// 原始 EXIF orientation（1–8）。dart:ui 降采样解码对 5–8 同样适用
  /// （它烘焙 EXIF，Android 设备端已实测；见 ml_probe2_main P1），
  /// orientation 字段保留供诊断与 bench 使用。
  final int orientation;

  bool get downsampled => width != sourceWidth || height != sourceHeight;
}

/// 解码**之前**规划引擎工作分辨率。
///
/// 头部解析不出（冷门格式）返回 null，调用方走"解码后才知道尺寸"的旧路径；
/// 摆正后长边 > [kMaxImageEdgePx] 直接抛 [ImageTooLargeException]——
/// 契约允许拒绝，而且不必为拒绝一张 20000px 的图先解码 3 亿像素。
WorkingSizePlan? planWorkingSize(Uint8List bytes) {
  final header = readImageHeaderSize(bytes);
  if (header == null) return null;
  final long = math.max(header.width, header.height);
  if (long > kMaxImageEdgePx) {
    throw const ImageTooLargeException();
  }
  if (long <= kEngineMaxEdge) {
    return WorkingSizePlan(
        header.width, header.height, header.width, header.height,
        orientation: header.orientation);
  }
  final s = kBigImageWorkEdge / long;
  return WorkingSizePlan(
    (header.width * s).round().clamp(1, kBigImageWorkEdge),
    (header.height * s).round().clamp(1, kBigImageWorkEdge),
    header.width,
    header.height,
    orientation: header.orientation,
  );
}

/// dart:ui 解码产物（RGBA）→ [DecodedImage]（丢掉 alpha 通道）。
///
/// [sourceWidth]/[sourceHeight] 传降采样前的原图（摆正后）尺寸，
/// 未降采样时省略即可。
DecodedImage rgbaToDecoded(
  Uint8List rgba,
  int width,
  int height, {
  int? sourceWidth,
  int? sourceHeight,
}) {
  assert(rgba.length == width * height * 4);
  final rgb = Uint8List(width * height * 3);
  for (var i = 0, j = 0, o = 0; i < rgb.length; i += 3, j += 4, o += 4) {
    rgb[i] = rgba[o];
    rgb[i + 1] = rgba[o + 1];
    rgb[i + 2] = rgba[o + 2];
  }
  return DecodedImage(
    rgb,
    width,
    height,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}

/// 解码后的原图，RGB 紧凑排布（w*h*3），外加一份 RGBA 视图所需的信息。
class DecodedImage {
  DecodedImage(
    this.rgb,
    this.width,
    this.height, {
    int? sourceWidth,
    int? sourceHeight,
  })  : sourceWidth = sourceWidth ?? width,
        sourceHeight = sourceHeight ?? height;

  /// 长度 = width * height * 3，顺序 R,G,B。
  final Uint8List rgb;
  final int width;
  final int height;

  /// 解码摆正后、**降采样前**的尺寸（未降采样时与 [width]/[height] 相同）。
  final int sourceWidth;
  final int sourceHeight;

  int get pixelCount => width * height;

  /// 展开成契约要求的 RGBA（w*h*4，A 恒 255）。
  Uint8List toRgba() {
    final out = Uint8List(pixelCount * 4);
    for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      out[j] = rgb[i];
      out[j + 1] = rgb[i + 1];
      out[j + 2] = rgb[i + 2];
      out[j + 3] = 255;
    }
    return out;
  }
}

/// 解码任意受支持的图片字节。
///
/// - 解码不出来 → [UnsupportedImageException]
/// - 长边超过 [kMaxImageEdgePx] → [ImageTooLargeException]
/// - [maxEdge] 非 null 且解码结果长边超过它时，解码后立即等比降采样到
///   [targetEdge]（缺省与 [maxEdge] 相同）该长边（面积插值）。这是 dart:ui
///   降采样解码不可用时的兜底路径——全尺寸解码的瞬时缓冲躲不掉，但后续
///   管线只吃小图。触发门槛与目标长边分开：大图（长边 > [kEngineMaxEdge]）
///   要与 planWorkingSize 的规划（降到 [kBigImageWorkEdge]）保持一致，而
///   ≤[kEngineMaxEdge] 的图（黄金集）绝不重采样——动了就是黄金集回归 FAIL。
///
/// EXIF 方向会被烘焙进像素。注意 image 包 4.9 的 JPEG 解码器在 `getImage`
/// 里**已经**烘焙过 orientation 并把 tag 置空，下面的 `bakeOrientation`
/// 只兜真正还带 tag 的格式；这与参考实现 `cv2.imread` 的默认行为一致。
///
/// 内存口径（REVIEW_SEC M3）：[readImageHeaderSize] 只覆盖 JPEG/PNG/GIF/
/// BMP/WebP 五类头。头解析失败时旧代码直接 `img.decodeImage` 全量解码——
/// image 包还能解 TGA/EXR/PNM/TIFF/PSD 等头未覆盖的格式，30000×30000 的
/// TGA 全量解码是 2.7GB 瞬时分配（8000px 上限拦不住它，因为尺寸压根没
/// 读过），叠加 ORT 常驻 floor 单张图即可 OOM（对抗组没打爆只是没构造
/// 这个组合）。这里按"头解析失败 = 解不开"拒绝（[UnsupportedImage-
/// Exception]），零像素分配。**依据是全量数据集实测**：88 项里 22 个
/// success 条目的头全部可解析（0 例外），13 个头解析失败条目全是
/// ini/db/txt 等非图片、旧结局本来就是 [UnsupportedImageException]——
/// 即"头解析失败但能解出有效图"的真实格式在本项目数据面不存在，不值得
/// 为它保留一条无界解码路径。冷门格式（TGA 等）从此不再支持：能正常
/// 使用的图片（相册 JPEG/PNG/截图）头解析不该失败，这条判定与契约的
/// "解不开 → UnsupportedImageException" 语义一致。
DecodedImage decodeToRgb(Uint8List bytes, {int? maxEdge, int? targetEdge}) {
  if (bytes.isEmpty) {
    throw const UnsupportedImageException();
  }
  if (readImageHeaderSize(bytes) == null) {
    throw UnsupportedImageException(
        cause: 'unrecognized image header (${bytes.length}B)');
  }
  img.Image? decoded;
  Object? failure;
  try {
    decoded = img.decodeImage(bytes);
  } catch (e) {
    // 损坏文件、伪装成图片的文本等都会在这里抛，统一翻译成契约异常。
    failure = e;
  }
  if (decoded == null) {
    // cause 只放字符串：这个异常会穿过 isolate 边界，带上第三方异常对象
    // 有可能不可序列化。
    throw UnsupportedImageException(cause: failure?.toString());
  }
  if (math.max(decoded.width, decoded.height) > kMaxImageEdgePx) {
    throw const ImageTooLargeException();
  }
  if (decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1) {
    decoded = img.bakeOrientation(decoded);
  }
  final w0 = decoded.width;
  final h0 = decoded.height;
  if (w0 <= 0 || h0 <= 0) {
    throw const UnsupportedImageException();
  }
  if (maxEdge != null && math.max(w0, h0) > maxEdge) {
    final target = targetEdge ?? maxEdge;
    final s = target / math.max(w0, h0);
    decoded = img.copyResize(
      decoded,
      width: (w0 * s).round().clamp(1, target),
      height: (h0 * s).round().clamp(1, target),
      interpolation: img.Interpolation.average,
    );
  }
  final w = decoded.width;
  final h = decoded.height;
  // 统一成 8bit 三通道再取字节：源图可能是灰度、带调色板、16bit 或带 alpha。
  if (decoded.numChannels != 3 || decoded.format != img.Format.uint8) {
    decoded = decoded.convert(format: img.Format.uint8, numChannels: 3);
  }
  final rgb = decoded.getBytes(order: img.ChannelOrder.rgb);
  if (rgb.length != w * h * 3) {
    throw const UnsupportedImageException();
  }
  return DecodedImage(rgb, w, h, sourceWidth: w0, sourceHeight: h0);
}

/// 一维面积重采样的权重表。等价于 OpenCV `INTER_AREA`：
/// 输出像素 j 覆盖源区间 `[j*s, (j+1)*s)`，权重 = 交叠长度 / s。
/// 缩小时是盒式平均，放大时退化为"带过渡的最近邻"，两种情形同一套公式。
class _AreaWeights {
  _AreaWeights(this.start, this.count, this.weights);

  final Int32List start;
  final Int32List count;
  final Float32List weights;

  static _AreaWeights build(int srcLen, int dstLen) {
    final scale = srcLen / dstLen;
    final start = Int32List(dstLen);
    final count = Int32List(dstLen);
    final acc = <double>[];
    for (var j = 0; j < dstLen; j++) {
      final s0 = j * scale;
      final s1 = (j + 1) * scale;
      var i0 = s0.floor();
      var i1 = s1.ceil();
      if (i0 < 0) i0 = 0;
      if (i1 > srcLen) i1 = srcLen;
      if (i1 <= i0) i1 = math.min(i0 + 1, srcLen);
      start[j] = i0;
      count[j] = i1 - i0;
      for (var i = i0; i < i1; i++) {
        final lo = math.max(s0, i.toDouble());
        final hi = math.min(s1, (i + 1).toDouble());
        acc.add(math.max(0.0, hi - lo) / scale);
      }
    }
    return _AreaWeights(start, count, Float32List.fromList(acc));
  }
}

int _roundToByte(double v) {
  // OpenCV saturate_cast<uchar>：四舍五入 + 饱和到 [0,255]。
  final r = v < 0 ? (v - 0.5).ceil() : (v + 0.5).floor();
  if (r < 0) return 0;
  if (r > 255) return 255;
  return r;
}

/// 面积重采样 RGB 图到 `dstW x dstH`，返回 uint8 RGB。
///
/// 先横向再纵向，中间量保持 double；最后一步才量化回 uint8 ——
/// 与 OpenCV 一致（模型前处理拿到的是 uint8）。
///
/// 内存口径（G4.7）：纵向不落地整块 `srcH*dstW` 的中间缓冲，而是按源行
/// 流式累加进 `dstH*dstW*3` 的累加器——每个目标元素的加法次序与旧实现
/// 逐项一致（都按源行升序），结果**逐位相同**，但峰值中间量从
/// `srcH*dstW*3*4` 降到 `dstH*dstW*3*4`（2048×1536→1024 时 18.9MB→12.6MB）。
Uint8List areaResampleRgb(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  return _areaResampleRgbStrided(src, srcW, srcH, dstW, dstH, 3);
}

/// 同 [areaResampleRgb]，但源是 **RGBA**（stride 4，alpha 列被跳过）。
///
/// G4 r3：dart:ui 降采样解码产物是 RGBA。旧路径要先在 worker 里把它
/// 转成紧凑 RGB（一份 w*h*3 的分配 + 拷贝）再重采样；直接按 stride 4
/// 读源像素后这份中间缓冲就不再需要。逐字节取的 RGB 值与转换后的
/// 完全一致、权重与累加次序共用同一套实现——结果与旧路径**逐位相同**。
Uint8List areaResampleRgbFromRgba(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  return _areaResampleRgbStrided(src, srcW, srcH, dstW, dstH, 4);
}

Uint8List _areaResampleRgbStrided(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
  int srcStride,
) {
  final wx = _AreaWeights.build(srcW, dstW);
  final wy = _AreaWeights.build(srcH, dstH);
  // 每个源行贡献给哪些目标行、权重多少（按目标行升序）。
  final srcRowCount = Int32List(srcH);
  for (var j = 0; j < dstH; j++) {
    for (var k = 0; k < wy.count[j]; k++) {
      srcRowCount[wy.start[j] + k]++;
    }
  }
  final srcRowOff = Int32List(srcH + 1);
  for (var y = 0; y < srcH; y++) {
    srcRowOff[y + 1] = srcRowOff[y] + srcRowCount[y];
  }
  final srcRowDst = Int32List(srcRowOff[srcH]);
  final srcRowW = Float32List(srcRowOff[srcH]);
  final fill = Int32List(srcH);
  // wy.weights 的写入游标随目标行增量推进（原实现每个 j 都从 0 重数
  // 前面所有 count，O(dstH²)；游标推进后权重下标与原实现完全一致）。
  var wi = 0;
  for (var j = 0; j < dstH; j++) {
    for (var k = 0; k < wy.count[j]; k++) {
      final y = wy.start[j] + k;
      final pos = srcRowOff[y] + fill[y]++;
      srcRowDst[pos] = j;
      srcRowW[pos] = wy.weights[wi + k];
    }
    wi += wy.count[j];
  }
  final acc = Float32List(dstH * dstW * 3);
  final row = Float32List(dstW * 3);
  for (var y = 0; y < srcH; y++) {
    // 横向重采样当前源行
    final rowBase = y * srcW * srcStride;
    var wi = 0;
    for (var j = 0; j < dstW; j++) {
      var r = 0.0, g = 0.0, b = 0.0;
      final i0 = wx.start[j];
      final n = wx.count[j];
      for (var k = 0; k < n; k++) {
        final w = wx.weights[wi + k];
        final p = rowBase + (i0 + k) * srcStride;
        r += src[p] * w;
        g += src[p + 1] * w;
        b += src[p + 2] * w;
      }
      wi += n;
      row[j * 3] = r;
      row[j * 3 + 1] = g;
      row[j * 3 + 2] = b;
    }
    // 纵向贡献：按目标行升序逐项累加（与旧实现的 k 序一致）
    for (var pos = srcRowOff[y]; pos < srcRowOff[y + 1]; pos++) {
      final j = srcRowDst[pos];
      final w = srcRowW[pos];
      final aBase = j * dstW * 3;
      for (var x = 0; x < dstW * 3; x++) {
        acc[aBase + x] += row[x] * w;
      }
    }
  }
  final out = Uint8List(dstW * dstH * 3);
  for (var i = 0; i < out.length; i++) {
    out[i] = _roundToByte(acc[i]);
  }
  return out;
}

/// 单通道面积重采样（alpha 用）。
///
/// 纵向按目标行流式计算（横向重采样按需重算），不落地 `srcH*dstW`
/// 的中间缓冲；加法次序与"先横后纵"的旧实现逐项一致，结果逐位相同。
Uint8List areaResampleGray(
  Uint8List src,
  int srcW,
  int srcH,
  int dstW,
  int dstH,
) {
  final wx = _AreaWeights.build(srcW, dstW);
  final wy = _AreaWeights.build(srcH, dstH);
  final acc = Float32List(dstW);
  final out = Uint8List(dstW * dstH);
  var wi = 0;
  for (var j = 0; j < dstH; j++) {
    final i0 = wy.start[j];
    final n = wy.count[j];
    for (var x = 0; x < dstW; x++) {
      acc[x] = 0.0;
    }
    for (var k = 0; k < n; k++) {
      // 横向重采样源行 i0+k（k 升序 = 旧实现累加序）
      final rowBase = (i0 + k) * srcW;
      var wxi = 0;
      for (var x = 0; x < dstW; x++) {
        var v = 0.0;
        final sx0 = wx.start[x];
        final m = wx.count[x];
        for (var t = 0; t < m; t++) {
          v += src[rowBase + sx0 + t] * wx.weights[wxi + t];
        }
        wxi += m;
        acc[x] += v * wy.weights[wi + k];
      }
    }
    wi += n;
    final outBase = j * dstW;
    for (var x = 0; x < dstW; x++) {
      out[outBase + x] = _roundToByte(acc[x]);
    }
  }
  return out;
}

/// 3×3 中值滤波（可分离近似：先横向 3 元素中值，再纵向 3 元素中值）。
///
/// 用于抠图 alpha 的**去斑**：模型尺度上孤立的高 alpha 噪点会被下游
/// （`render.dart` 的 `alphaMax ≥ 191 强制不透明`）放大成一块方形的
/// "凸块/缺角"，在成片轮廓上表现为锯齿。中值能吃掉这类孤立噪点而不
/// 移动轮廓本身的位置（均值滤波会把轮廓整体拖软）。
///
/// 边界按夹取处理（等价于复制边缘像素）。
Uint8List medianGray3(Uint8List src, int w, int h) {
  final tmp = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final a = src[row + (x > 0 ? x - 1 : 0)];
      final b = src[row + x];
      final c = src[row + (x < w - 1 ? x + 1 : w - 1)];
      // 三元素中值：a,b,c 的中位数
      tmp[row + x] = a < b
          ? (b < c ? b : (a < c ? c : a))
          : (a < c ? a : (b < c ? c : b));
    }
  }
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    final up = (y > 0 ? y - 1 : 0) * w;
    final dn = (y < h - 1 ? y + 1 : h - 1) * w;
    for (var x = 0; x < w; x++) {
      final a = tmp[up + x];
      final b = tmp[row + x];
      final c = tmp[dn + x];
      out[row + x] = a < b
          ? (b < c ? b : (a < c ? c : a))
          : (a < c ? a : (b < c ? c : b));
    }
  }
  return out;
}

/// 就地高斯羽化（可分离核）。仅在放大倍率很小、边缘还偏硬时才调用。
///
/// 内存口径（G4.7）：横向滤波结果按滑动窗口缓存（`2r+1` 行），不再落地
/// 整幅 `Float32List(w*h)` 的中间图（2048² 时 16.8MB→57KB）。纵向累加在
/// double 局部量上进行、次序与旧实现一致（i 从 -r 到 r），结果逐位相同。
Uint8List featherGray(Uint8List src, int w, int h, double sigma) {
  if (sigma <= 0) return src;
  final radius = math.max(1, (sigma * 3).ceil());
  final k = Float32List(radius * 2 + 1);
  var sum = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final v = math.exp(-(i * i) / (2 * sigma * sigma));
    k[i + radius] = v;
    sum += v;
  }
  for (var i = 0; i < k.length; i++) {
    k[i] = k[i] / sum;
  }
  // 滑动窗口缓存：hrow[yy] = 源行 yy 的横向滤波结果。每个源行只需算
  // 一次（stamp 记录槽位对应的行号），窗口大小 2r+1 行。
  final window = radius * 2 + 1;
  final ring = Float32List(window * w);
  final stamp = Int32List(window);
  for (var i = 0; i < window; i++) {
    stamp[i] = -1;
  }
  Float32List hrowOf(int yy) {
    final slot = yy % window;
    if (stamp[slot] != yy) {
      stamp[slot] = yy;
      final base = slot * w;
      final base0 = yy * w;
      for (var x = 0; x < w; x++) {
        var v = 0.0;
        for (var i = -radius; i <= radius; i++) {
          final xx = (x + i).clamp(0, w - 1);
          v += src[base0 + xx] * k[i + radius];
        }
        ring[base + x] = v;
      }
    }
    return Float32List.sublistView(ring, slot * w, slot * w + w);
  }

  final out = Uint8List(w * h);
  // 行视图缓存：每个 y 只对窗口内 (2r+1) 行各调一次 hrowOf（建一次
  // 视图对象），x 循环里直接下标访问——调用数从 (2r+1)·w·h 降到
  // (2r+1)·h，加法次序与权重完全不变，结果逐位一致。
  final rows = List<Float32List?>.filled(window, null);
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var i = -radius; i <= radius; i++) {
      rows[i + radius] = hrowOf((y + i).clamp(0, h - 1));
    }
    for (var x = 0; x < w; x++) {
      var v = 0.0;
      for (var i = -radius; i <= radius; i++) {
        v += rows[i + radius]![x] * k[i + radius];
      }
      out[base + x] = _roundToByte(v);
    }
  }
  return out;
}

/// MODNet 前处理：RGB → [size]×[size] → BGR、NCHW、`(x/255 - 0.5) / 0.5`。
///
/// 通道顺序是 **BGR**：参考实现用 `cv2.imread` 读图后直接喂给模型，
/// 黄金集参考 alpha 就是在 BGR 下产生的，换成 RGB 会得到不同的 mask。
/// [size] 的生产口径 = `kMattingInputSize`（ort_runtime.dart，1024）。
Float32List modnetInput(Uint8List rgb, int w, int h, int size) {
  final resized = areaResampleRgb(rgb, w, h, size, size);
  return _modnetInputFromResampled(resized, size);
}

/// [modnetInput] 的 RGBA 源版本（dart:ui 降采样解码路径专用）。
///
/// 源像素是同一条解码产物的 RGBA 布局：跳过 alpha 列后与"先转紧凑 RGB
/// 再重采样"的旧路径喂进模型的是**逐位相同**的输入（权重与累加次序共用
/// 同一套实现），但省掉一份 w*h*3 的中间缓冲。
Float32List modnetInputFromRgba(Uint8List rgba, int w, int h, int size) {
  final resized = areaResampleRgbFromRgba(rgba, w, h, size, size);
  return _modnetInputFromResampled(resized, size);
}

Float32List _modnetInputFromResampled(Uint8List resized, int size) {
  final out = Float32List(3 * size * size);
  final plane = size * size;
  for (var i = 0, p = 0; p < plane; i += 3, p++) {
    out[p] = (resized[i + 2] / 255.0 - 0.5) / 0.5; // B
    out[plane + p] = (resized[i + 1] / 255.0 - 0.5) / 0.5; // G
    out[2 * plane + p] = (resized[i] / 255.0 - 0.5) / 0.5; // R
  }
  return out;
}

/// YuNet 前处理结果：等比缩放 + 右下角补 0 的 640×640 BGR NCHW（不做归一化）。
class LetterboxInput {
  LetterboxInput(this.data, this.scale);

  final Float32List data;

  /// 原图坐标 = 模型坐标 / scale。
  final double scale;
}

LetterboxInput yunetInput(Uint8List rgb, int w, int h, int size) {
  final scale = math.min(size / w, size / h);
  var nw = (w * scale).round().clamp(1, size);
  var nh = (h * scale).round().clamp(1, size);
  final resized = areaResampleRgb(rgb, w, h, nw, nh);
  return _yunetInputFromResampled(resized, nw, nh, size, scale);
}

/// [yunetInput] 的 RGBA 源版本。逐位等价论证同 [modnetInputFromRgba]。
LetterboxInput yunetInputFromRgba(Uint8List rgba, int w, int h, int size) {
  final scale = math.min(size / w, size / h);
  var nw = (w * scale).round().clamp(1, size);
  var nh = (h * scale).round().clamp(1, size);
  final resized = areaResampleRgbFromRgba(rgba, w, h, nw, nh);
  return _yunetInputFromResampled(resized, nw, nh, size, scale);
}

LetterboxInput _yunetInputFromResampled(
    Uint8List resized, int nw, int nh, int size, double scale) {
  final plane = size * size;
  final out = Float32List(3 * plane);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final s = (y * nw + x) * 3;
      final d = y * size + x;
      out[d] = resized[s + 2].toDouble(); // B
      out[plane + d] = resized[s + 1].toDouble(); // G
      out[2 * plane + d] = resized[s].toDouble(); // R
    }
  }
  return LetterboxInput(out, scale);
}
