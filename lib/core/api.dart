/// 木照 MuZhao — 引擎契约。
///
/// 本文件是 `docs/CONTRACTS.md` 的 Dart 落地，**主会话独占写入**。
/// 阶段 2 的三个并行 agent 都只对着本文件编程：
///
/// - `ml-porting`  实现 [IdPhotoEngine.warmUp] / [IdPhotoEngine.removeBackground]
///                 / [IdPhotoEngine.detectFace]，类名 `MattingEngineMixin`
/// - `imaging`     实现 [IdPhotoEngine.compose] 与规格几何推算，类名 `ComposeEngineMixin`
/// - `ui-woodcraft` 只能看见 [IdPhotoController] 与 [AppState]，不得 import 任何实现类
///
/// 任何人想改本文件的签名，必须在报告里向主会话提出，不得自己改 ——
/// 改签名会打断阶段 2 的并行。
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

// ---------------------------------------------------------------------------
// 1. 数据类型
// ---------------------------------------------------------------------------

/// 证件照规格。
///
/// `id` / `nameZh` / 毫米尺寸 / 像素尺寸 / `dpi` 由 `docs/CONTRACTS.md` 第 4 节锁定，
/// **任何人不得修改**（G2B.1 逐像素校验，G2B.2 回读 DPI）。
///
/// [headTopRatio] 与 [headHeightRatio] 是几何目标值，归 `imaging` 调校：
/// 若需按证件照国标微调，请在 `lib/core/specs/photo_specs.dart` 里用 [copyWith] 派生，
/// **不要改本文件里的 mm / px / dpi**。
class PhotoSpec {
  /// 稳定标识，如 `'cn_1inch'`。
  final String id;

  /// 中文名，如 `'一寸'`。直接用于 UI 展示，已本地化。
  final String nameZh;

  final int widthMm;
  final int heightMm;

  final int widthPx;
  final int heightPx;

  /// 写入 JPEG JFIF 头的分辨率，恒为 300。
  final int dpi;

  /// 头顶距画面上边距 / 画面总高。典型 0.08。
  final double headTopRatio;

  /// （头顶 → 下巴）/ 画面总高。典型 0.62。
  final double headHeightRatio;

  const PhotoSpec({
    required this.id,
    required this.nameZh,
    required this.widthMm,
    required this.heightMm,
    required this.widthPx,
    required this.heightPx,
    required this.dpi,
    required this.headTopRatio,
    required this.headHeightRatio,
  });

  /// 画面宽高比（宽 / 高）。裁剪框锁定此比例。
  double get aspectRatio => widthPx / heightPx;

  /// 仅允许派生两个几何比例；尺寸字段刻意不开放覆写。
  PhotoSpec copyWith({double? headTopRatio, double? headHeightRatio}) {
    return PhotoSpec(
      id: id,
      nameZh: nameZh,
      widthMm: widthMm,
      heightMm: heightMm,
      widthPx: widthPx,
      heightPx: heightPx,
      dpi: dpi,
      headTopRatio: headTopRatio ?? this.headTopRatio,
      headHeightRatio: headHeightRatio ?? this.headHeightRatio,
    );
  }

  @override
  bool operator ==(Object other) => other is PhotoSpec && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PhotoSpec($id, ${widthPx}x$heightPx@$dpi)';
}

/// 抠图结果。[rgba] 与 [alpha] 同分辨率，均为**引擎工作分辨率**：
/// 原图等比降采样到引擎上限，原图本就不超过上限时两者相同
/// （G4.7 内存修复引入，ml-porting）。
///
/// ⚠️ 本文档出现的"摆正"一律指 **EXIF 正向烘焙**（`dart:ui` 解码时按
/// orientation 做的 90° 转置，无损），**不是**面内摆正。
/// **生产路径喂给抠图引擎的永远是未做面内旋转的原图**：`controller.loadImage`
/// 把原始字节直接透传给 [IdPhotoEngine.removeBackground]，面内旋转只发生在
/// `compose` 内、且作用在抠图**之后**（`compose_engine.dart` 的 `planRotation`）。
/// 别据此认为"抠图看到的已经是摆正图"——这个误解会让"旋转输入上抠图崩坏"
/// 这类**只在夹具里存在**的现象被误判成用户可见缺陷。
class MattingResult {
  /// 原图 RGBA，长度恒为 `width * height * 4`。
  final Uint8List rgba;

  /// 单通道 mask，长度恒为 `width * height`。0 = 背景，255 = 前景。
  final Uint8List alpha;

  /// 引擎工作分辨率（[rgba]/[alpha] 的实际尺寸）。
  final int width;
  final int height;

  /// 原图（EXIF 正向烘焙后）尺寸。null = 未降采样（与 [width]/[height] 相同）。
  /// 与工作分辨率的比值是唯一的坐标换算系数，见 [srcWidth]/[srcHeight]。
  final int? sourceWidth;
  final int? sourceHeight;

  const MattingResult({
    required this.rgba,
    required this.alpha,
    required this.width,
    required this.height,
    this.sourceWidth,
    this.sourceHeight,
  });

  /// 原图（EXIF 正向烘焙后）宽。恒 ≥ [width]。
  int get srcWidth => sourceWidth ?? width;

  /// 原图（EXIF 正向烘焙后）高。恒 ≥ [height]。
  int get srcHeight => sourceHeight ?? height;
}

/// [FaceInfo.rollDeg] 的估计来源。
enum RollSource {
  /// 瞳孔对精测：由双眼虹膜/瞳孔中心连线得到，不依赖 YuNet 的眼睑关键点。
  /// 这是唯一"可以据以旋转"的来源。
  pupil,

  /// 无法可信估计。[FaceInfo.rollDeg] 恒为 0.0，含义是"放弃摆正"，
  /// **不是**"这张图不需要摆正"。
  unavailable,

  /// 调用方直接给定（合成自检 / 测试夹具 / dev 探针），引擎未参与估计。
  given,
}

/// 人脸信息。用于自动裁剪推算与框选初始值。
///
/// 坐标为**引擎工作分辨率**（与 [MattingResult] 同一坐标系，G4.7 降采样后
/// 由 ml-porting 如此返回）。需要原图坐标时由调用方按
/// `MattingResult.srcWidth / MattingResult.width` 等比换算。
class FaceInfo {
  /// 人脸框，原图像素坐标。
  final Rect box;

  /// 下巴 y，原图像素坐标。恒有 `chinY > headTopY`（G2A.8 校验）。
  final double chinY;

  /// 头顶 y，原图像素坐标。
  final double headTopY;

  /// **待施加的摆正角**（度）。
  ///
  /// 精确定义（别用"顺/逆时针"口头描述，实测已因此出过一次反向事故）：
  /// 记 φ = atan2(y_图像右眼 − y_图像左眼, x_图像右眼 − x_图像左眼)，
  /// 图像坐标 y 向下。**`rollDeg` 就等于 φ 本身，不取负**。
  /// 实现侧的恒等式是 `输出倾角 = φ − rollDeg`，所以 φ 摆平当且仅当
  /// `rollDeg == φ`。旧路径 `yunet_decoder.toFaceInfo` 用的就是这个公式。
  ///
  /// 语义（阶段 6 P0 收紧，主会话授权）：这是"要转多少"，不是"测得多少"。
  /// 引擎无法可信估计时**必须返回 0.0**——宁可不摆正，不可引入歪斜。
  /// 消费方（imaging）无条件按本值旋转，不做二次仲裁。
  ///
  /// 为什么不能说"测不出就用旧值兜底"：YuNet 眼球关键点落在上睑褶而非
  /// 瞳孔，在真实照片上误差 3.7~6.7° 且可反号（p1 +0.84 vs 真值 −4.4；
  /// p2 −3.91 vs 真值 −0.2）。拿它兜底会把一张竖直的证件照转歪，
  /// 这正是本次 P0 事故。
  final double rollDeg;

  /// [rollDeg] 的估计来源，供门禁判定"覆盖率与诚实性"（ACCEPTANCE P0.4）
  /// 与排查用。消费方不得据此改变行为——行为差异全部由 [rollDeg] 承载。
  final RollSource rollSource;

  /// 检出置信度，0–1。
  final double confidence;

  /// YuNet 五关键点，依次 [左眼(x,y), 右眼, 鼻尖, 左嘴角, 右嘴角]，
  /// 长度 10（Float32），与 [MattingResult] 同一坐标系。null = 解码器未提供。
  ///
  /// ⚠️ **不要拿这四个眼球点当角度用**。它们在真实照片上落在**上睑褶**而非
  /// 瞳孔，误差 3.7~6.7° 且可反号（阶段 6 P0 复现结论，详见 PITFALLS），
  /// 这正是本次 P0 事故的根因。
  /// 唯一正确的用法是当**瞳孔搜索的种子**：[0..3] 只用来给出两只眼睛的大致
  /// 位置，由 `estimatePupilRoll` 在各自窗口内找真实瞳孔中心，再由瞳孔连线定角
  /// （见 `matting_worker.dart` 的 `eyeAx/eyeAy/eyeBx/eyeBy` 入参）。
  /// imaging 曾据此做过「眼线为主 + 嘴线共识门」的多线融合（已删除）——
  /// 三条线同源于同一组关键点、强相关（104 组对照差 ±0.02°，噪声级），
  /// 合并拿不到新增信息。**别再重做这个实验。**
  final Float32List? landmarks;

  const FaceInfo({
    required this.box,
    required this.chinY,
    required this.headTopY,
    required this.rollDeg,
    required this.confidence,
    this.rollSource = RollSource.given,
    this.landmarks,
  });

  /// 头高（头顶到下巴）像素数。
  double get headHeightPx => chinY - headTopY;
}

/// 底色样式。色值由 `docs/CONTRACTS.md` 第 5 节锁定，不得修改。
class BackgroundStyle {
  /// 稳定标识，如 `'white'`。
  final String id;

  /// 中文名，如 `'白底'`。直接用于 UI 铭牌。
  final String nameZh;

  /// 0xAARRGGBB。纯色时即为整体底色。
  final int colorTop;

  /// 非 null 则为竖向线性渐变，[colorTop] 在上、本值在下。
  final int? colorBottom;

  const BackgroundStyle({
    required this.id,
    required this.nameZh,
    required this.colorTop,
    this.colorBottom,
  });

  bool get isGradient => colorBottom != null;

  @override
  bool operator ==(Object other) => other is BackgroundStyle && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 一张候选结果。[jpegBytes] 已裁剪、换底、写好 DPI，可直接落盘。
class Candidate {
  final BackgroundStyle style;

  /// 成品 JPEG，已按 spec 裁剪 + 换底 + 写入 DPI 元数据。
  final Uint8List jpegBytes;

  /// UI 列表用缩略图，长边 320px。
  final Uint8List thumbBytes;

  const Candidate({
    required this.style,
    required this.jpegBytes,
    required this.thumbBytes,
  });
}

// ---------------------------------------------------------------------------
// 2. 内置规格表（CONTRACTS 第 4 节，数值锁定）
// ---------------------------------------------------------------------------

/// 7 个内置规格。mm / px / dpi 由契约锁定，G2B.1 逐像素校验。
///
/// 两个几何比例取契约第 1 节给出的典型值作为默认；`imaging` 可在
/// `lib/core/specs/photo_specs.dart` 里用 [PhotoSpec.copyWith] 按国标派生
/// （头顶留白 7–12%，头高占 60–65%）。
const PhotoSpec kSpecCn1inch = PhotoSpec(
  id: 'cn_1inch',
  nameZh: '一寸',
  widthMm: 25,
  heightMm: 35,
  widthPx: 295,
  heightPx: 413,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecCnSmall1inch = PhotoSpec(
  id: 'cn_small_1inch',
  nameZh: '小一寸',
  widthMm: 22,
  heightMm: 32,
  widthPx: 260,
  heightPx: 378,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecCnBig1inch = PhotoSpec(
  id: 'cn_big_1inch',
  nameZh: '大一寸',
  widthMm: 33,
  heightMm: 48,
  widthPx: 390,
  heightPx: 567,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecCn2inch = PhotoSpec(
  id: 'cn_2inch',
  nameZh: '二寸',
  widthMm: 35,
  heightMm: 49,
  widthPx: 413,
  heightPx: 579,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecCnSmall2inch = PhotoSpec(
  id: 'cn_small_2inch',
  nameZh: '小二寸',
  widthMm: 35,
  heightMm: 45,
  widthPx: 413,
  heightPx: 531,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecCnSocialSecurity = PhotoSpec(
  id: 'cn_social_security',
  nameZh: '社保卡',
  widthMm: 26,
  heightMm: 32,
  widthPx: 358,
  heightPx: 441,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

const PhotoSpec kSpecVisaUs = PhotoSpec(
  id: 'visa_us',
  nameZh: '美签',
  widthMm: 51,
  heightMm: 51,
  widthPx: 600,
  heightPx: 600,
  dpi: 300,
  headTopRatio: 0.08,
  headHeightRatio: 0.62,
);

/// 7 个内置规格，顺序即 UI 规格选择器的展示顺序。
const List<PhotoSpec> kBuiltInSpecs = <PhotoSpec>[
  kSpecCn1inch,
  kSpecCnSmall1inch,
  kSpecCnBig1inch,
  kSpecCn2inch,
  kSpecCnSmall2inch,
  kSpecCnSocialSecurity,
  kSpecVisaUs,
];

/// 默认规格：一寸。
const PhotoSpec kDefaultSpec = kSpecCn1inch;

// ---------------------------------------------------------------------------
// 3. 内置底色（CONTRACTS 第 5 节，色值锁定、顺序锁定）
// ---------------------------------------------------------------------------

/// 6 种底色，候选列表按此顺序排列，默认选中 `white`。
const BackgroundStyle kBgWhite =
    BackgroundStyle(id: 'white', nameZh: '白底', colorTop: 0xFFFFFFFF);
const BackgroundStyle kBgBlue =
    BackgroundStyle(id: 'blue', nameZh: '蓝底', colorTop: 0xFF438EDB);
const BackgroundStyle kBgRed =
    BackgroundStyle(id: 'red', nameZh: '红底', colorTop: 0xFFD9001B);
const BackgroundStyle kBgDeepBlue =
    BackgroundStyle(id: 'deep_blue', nameZh: '深蓝底', colorTop: 0xFF244A83);
const BackgroundStyle kBgGray =
    BackgroundStyle(id: 'gray', nameZh: '浅灰底', colorTop: 0xFFF0F0F0);
const BackgroundStyle kBgBlueGradient = BackgroundStyle(
  id: 'blue_gradient',
  nameZh: '蓝渐变',
  colorTop: 0xFF628BCE,
  colorBottom: 0xFF2B5AA0,
);

/// 6 种底色，候选列表按此顺序排列，默认选中 `white`。
const List<BackgroundStyle> kBuiltInBackgrounds = <BackgroundStyle>[
  kBgWhite,
  kBgBlue,
  kBgRed,
  kBgDeepBlue,
  kBgGray,
  kBgBlueGradient,
];

/// 默认底色：白底。
const BackgroundStyle kDefaultBackground = kBgWhite;

// ---------------------------------------------------------------------------
// 4. 错误契约（CONTRACTS 第 6 节）
// ---------------------------------------------------------------------------

/// 本 App 所有可预期错误的基类。
///
/// [messageZh] 是**已本地化的中文文案**，controller 层直接塞进
/// [AppState.errorMessage]。异常不得穿透到 UI 层。
abstract class IdPhotoException implements Exception {
  final String messageZh;

  /// 便于排查的原始错误，不展示给用户。
  final Object? cause;

  const IdPhotoException(this.messageZh, {this.cause});

  @override
  String toString() => '$runtimeType: $messageZh';
}

/// 抠图失败。
class MattingException extends IdPhotoException {
  const MattingException({super.cause}) : super('抠图失败了，换一张试试吧');
}

/// 没找到人脸。**仅提示，不阻断流程** —— 用户可以手动框选。
///
/// 注意：[IdPhotoEngine.detectFace] 无人脸时返回 `null` 而**不抛**本异常；
/// 本异常只用于 controller 向 UI 传达提示文案。
class NoFaceException extends IdPhotoException {
  const NoFaceException({super.cause}) : super('没找到人脸，请手动框选');
}

/// 图片格式无法解码。
class UnsupportedImageException extends IdPhotoException {
  const UnsupportedImageException({super.cause}) : super('这个图片格式打不开');
}

/// 图片尺寸超限。
class ImageTooLargeException extends IdPhotoException {
  const ImageTooLargeException({super.cause})
      : super('图片太大了，请用小于 8000px 的照片');
}

/// 长边像素上限，超过即抛 [ImageTooLargeException]。
const int kMaxImageEdgePx = 8000;

/// 用户手动微调角度的下限（度，负值 = 逆时针）。
///
/// 与自动摆正的适用域**互不重叠也不留缺口**：自动只在 |倾角| > 30° 时介入
/// （见 `kAutoRotateMinAbsDeg`），30° 以内全部由用户自己调。
const double kManualAngleMinDeg = -30.0;

/// 用户手动微调角度的上限（度，正值 = 顺时针）。
const double kManualAngleMaxDeg = 30.0;

// ---------------------------------------------------------------------------
// 5. 引擎接口（CONTRACTS 第 2 节）
// ---------------------------------------------------------------------------

abstract class IdPhotoEngine {
  /// 加载模型到内存。App 启动后异步调用一次。重复调用应幂等。
  Future<void> warmUp();

  /// 抠图。失败抛 [MattingException]；
  /// 格式不支持抛 [UnsupportedImageException]；过大抛 [ImageTooLargeException]。
  Future<MattingResult> removeBackground(Uint8List imageBytes);

  /// 人脸检测。**无人脸返回 `null`，不抛异常。**
  Future<FaceInfo?> detectFace(Uint8List imageBytes);

  /// 按规格裁剪 + 换底 + 编码。
  ///
  /// [cropOverride] 非 null 时用用户框选的区域，否则用 [face] 自动推算；
  /// 两者皆无时退化为居中最大内接框。
  ///
  /// **坐标系**：[face] 与 [cropOverride] 与 [matting] 同一坐标系
  /// （引擎工作分辨率）。controller 负责把原图坐标的用户框选换算进来
  /// （G4.7 降采样后；未降采样时即原图坐标）。
  ///
  /// [manualRollDeg] 是用户在界面上手动微调的面内角度（度）。**与
  /// [FaceInfo.rollDeg] 同一口径**，不另立一套"顺/逆"措辞——实现侧的恒等式
  /// 是 `输出倾角 = φ − rollDeg`，手动分量与自动分量在 `planRotation` 里
  /// **相加**后再统一钳制。正值即表示与同值 `rollDeg` 相同的方向。
  /// **自动只处理方向明显不对的照片**（|倾角| > 30°），细微倾角一律由
  /// 用户自己调。0.0 = 用户未调整。
  Future<Candidate> compose({
    required MattingResult matting,
    required PhotoSpec spec,
    required BackgroundStyle style,
    FaceInfo? face,
    Rect? cropOverride,
    double manualRollDeg = 0.0,
  });

  /// 自动推算的裁剪框，用作 [AppState.suggestedCrop]。
  ///
  /// 纯几何计算，无模型依赖。阶段 3 起提升到契约面（审查 A3）：
  /// 此前它只存在于 ComposeEngineMixin 上，导致 controller 为调用它
  /// 不得不依赖具体实现类而无法注入假引擎。
  ///
  /// **坐标系**：与传入的 [imageWidth]/[imageHeight]/[face] 一致。
  /// controller 传原图（摆正后）尺寸与原图坐标的 face，返回原图坐标的
  /// 矩形——UI 的裁剪框画在原图上，必须是原图空间的轴对齐矩形。
  ///
  /// 不含摆正——`compose` 内部若判定需要摆正，成片会比这个框略微转正，
  /// 属预期。
  Rect suggestedCropInSourcePx({
    required int imageWidth,
    required int imageHeight,
    required PhotoSpec spec,
    FaceInfo? face,
  });

  /// 释放模型与 native 资源。
  void dispose();
}

// ---------------------------------------------------------------------------
// 6. UI 侧唯一入口（CONTRACTS 第 3 节）
// ---------------------------------------------------------------------------

/// 处理阶段。UI 据此决定渲染空态 / 进度 / 结果。
enum Stage { idle, matting, composing, ready, error }

/// UI 可见的全部状态。不可变，每次变更产生新实例。
class AppState {
  /// 用户选中的原图字节。null = 空态。
  final Uint8List? sourceImage;

  /// 自动推算的裁剪框（原图像素坐标），UI 用作拖拽初始值。
  final Rect? suggestedCrop;

  /// 已生成的候选，顺序与 [kBuiltInBackgrounds] 一致。
  final List<Candidate> candidates;

  /// 当前规格。
  final PhotoSpec spec;

  /// 用户手动微调的面内角度（度）。0.0 = 未调整。
  ///
  /// 口径与 [IdPhotoEngine.compose] 的 `manualRollDeg` 完全相同；屏幕上的
  /// 顺/逆由 UI 按该口径换算（不要在这里另写方向措辞，见 CONTRACTS 的同源事故）。
  ///
  /// UI 的画布预览、裁剪框与成片都必须按它旋转；重新载入图片时归零。
  final double manualAngleDeg;

  /// 当前 [candidates] 这一批所用的几何快照：手动角度（度）。
  ///
  /// 与 [composedCrop] 一起供 UI 做**实时预览变换**：拖拽框选/角度微调期间，
  /// 候选缩略图不必等重新合成，直接按「当前几何 − 本快照」做旋转/缩放/平移
  /// 跟手显示；停手后的全精度候选抵达时本快照随之更新，变换自然归零。
  final double composedAngleDeg;

  /// 当前 [candidates] 所用的裁剪框（原图像素坐标）。null = 自动推算框
  /// （UI 此时用 [suggestedCrop] 参与变换换算）。
  final Rect? composedCrop;

  final Stage stage;

  /// **已本地化的中文文案**。UI 直接显示，不做任何加工。
  final String? errorMessage;

  const AppState({
    this.sourceImage,
    this.suggestedCrop,
    this.candidates = const <Candidate>[],
    this.spec = kDefaultSpec,
    this.manualAngleDeg = 0.0,
    this.composedAngleDeg = 0.0,
    this.composedCrop,
    this.stage = Stage.idle,
    this.errorMessage,
  });

  /// 初始空态。
  const AppState.initial() : this();

  AppState copyWith({
    Uint8List? sourceImage,
    Rect? suggestedCrop,
    List<Candidate>? candidates,
    PhotoSpec? spec,
    double? manualAngleDeg,
    double? composedAngleDeg,
    Rect? composedCrop,
    Stage? stage,
    String? errorMessage,
    bool clearError = false,
    bool clearSuggestedCrop = false,
    bool clearComposedCrop = false,
  }) {
    return AppState(
      sourceImage: sourceImage ?? this.sourceImage,
      suggestedCrop:
          clearSuggestedCrop ? null : (suggestedCrop ?? this.suggestedCrop),
      candidates: candidates ?? this.candidates,
      spec: spec ?? this.spec,
      manualAngleDeg: manualAngleDeg ?? this.manualAngleDeg,
      composedAngleDeg: composedAngleDeg ?? this.composedAngleDeg,
      composedCrop:
          clearComposedCrop ? null : (composedCrop ?? this.composedCrop),
      stage: stage ?? this.stage,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// `lib/ui/` 唯一能看见的入口。UI **不得** import 任何实现类。
abstract class IdPhotoController {
  /// 载入原图，触发抠图 + 检脸，随后生成候选。
  Future<void> loadImage(Uint8List bytes);

  /// 用户拖拽框选，[rectInSourcePx] 为原图像素坐标。
  void setCrop(Rect rectInSourcePx);

  /// 切换规格，会重新推算裁剪框并重新生成候选。
  void setSpec(PhotoSpec spec);

  /// 用户手动微调面内角度（度，正值顺时针），随后重新生成候选。
  ///
  /// 取值范围 [kManualAngleMinDeg] ~ [kManualAngleMaxDeg]，越界即钳制；
  /// **自动摆正不受影响**，两者叠加。
  void setManualAngle(double deg);

  /// 状态流。Riverpod `StateNotifier` 暴露。
  Stream<AppState> get state;

  /// 当前状态快照，供 UI 首帧同步取值。
  AppState get currentState;

  /// 保存候选到相册，返回保存路径。
  Future<String> save(Candidate c);
}
