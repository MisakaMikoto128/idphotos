# 接口契约（阶段 2 并行的唯一依据）

主会话是本文件的唯一写入者。任何 agent 想改签名，必须在报告里提出，不得自己改。
`lib/core/api.dart` 是本文件的 Dart 落地，由主会话在阶段 0 写好；实现者只写实现类。

## 1. 数据类型

```dart
/// 证件照规格
class PhotoSpec {
  final String id;          // 'cn_1inch'
  final String nameZh;      // '一寸'
  final int widthMm, heightMm;
  final int widthPx, heightPx;
  final int dpi;            // 写入 JPEG/PNG 元数据
  final double headTopRatio;    // 头顶距上边距 / 总高，典型 0.08
  final double headHeightRatio; // 头顶到下巴 / 总高，典型 0.62
}

/// 抠图结果
class MattingResult {
  final Uint8List rgba;   // 原图 RGBA，w*h*4
  final Uint8List alpha;  // 单通道 mask，w*h，0=背景 255=前景
  final int width, height;
}

/// 人脸信息（用于自动裁剪 + 框选初始值）
class FaceInfo {
  final Rect box;             // 人脸框，原图像素坐标
  final double chinY, headTopY; // 下巴/头顶 y，原图像素坐标
  final double rollDeg;       // 面内旋转角，用于摆正
  final double confidence;
}

/// 底色样式
class BackgroundStyle {
  final String id;        // 'white' | 'blue' | 'red' | 'blue_gradient' ...
  final String nameZh;    // '白底'
  final int colorTop;     // 0xAARRGGBB
  final int? colorBottom; // 非 null 则为竖向渐变
}

/// 一张候选结果
class Candidate {
  final BackgroundStyle style;
  final Uint8List jpegBytes; // 已按 spec 裁剪+换底+写 DPI，可直接保存
  final Uint8List thumbBytes; // UI 列表用小图，长边 320px
}
```

## 2. 引擎接口（`lib/core/api.dart`）

```dart
abstract class IdPhotoEngine {
  /// 加载模型到内存。App 启动后异步调用一次。
  Future<void> warmUp();

  /// 抠图。失败抛 MattingException。
  Future<MattingResult> removeBackground(Uint8List imageBytes);

  /// 人脸检测。无人脸返回 null（不抛异常）。
  Future<FaceInfo?> detectFace(Uint8List imageBytes);

  /// 按规格裁剪 + 换底 + 编码。cropOverride 非 null 时用用户框选的区域，
  /// 否则用 FaceInfo 自动推算。
  Future<Candidate> compose({
    required MattingResult matting,
    required PhotoSpec spec,
    required BackgroundStyle style,
    FaceInfo? face,
    Rect? cropOverride,
  });

  void dispose();
}
```

**归属**：`removeBackground` / `detectFace` / `warmUp` → ml-porting；`compose` 及所有规格计算 → imaging。
两者各自实现一个 mixin，主会话在阶段 3 合成为 `IdPhotoEngineImpl`。

## 3. UI 侧唯一入口（`lib/ui` 只能看到这个）

```dart
abstract class IdPhotoController {
  Future<void> loadImage(Uint8List bytes);   // 触发抠图+检脸
  void setCrop(Rect rectInSourcePx);          // 用户拖拽框选
  void setSpec(PhotoSpec spec);
  Stream<AppState> get state;                 // Riverpod StateNotifier 暴露
  Future<String> save(Candidate c);           // 返回保存路径
}

class AppState {
  final Uint8List? sourceImage;
  final Rect? suggestedCrop;   // 自动推算的框，UI 用作拖拽初始值
  final List<Candidate> candidates;
  final PhotoSpec spec;
  final Stage stage;           // idle | matting | composing | ready | error
  final String? errorMessage;  // 已本地化的中文文案
}
```

ui-woodcraft **只依赖 `IdPhotoController` 和 `AppState`**，阶段 2 用 `FakeController`（返回纯色占位图）自测。

## 4. 内置规格表（imaging 负责实现，数值不得改）

| id | 中文名 | mm | px@300dpi |
|---|---|---|---|
| cn_1inch | 一寸 | 25×35 | 295×413 |
| cn_small_1inch | 小一寸 | 22×32 | 260×378 |
| cn_big_1inch | 大一寸 | 33×48 | 390×567 |
| cn_2inch | 二寸 | 35×49 | 413×579 |
| cn_small_2inch | 小二寸 | 35×45 | 413×531 |
| cn_social_security | 社保卡 | 26×32 | 358×441 |
| visa_us | 美签 | 51×51 | 600×600 |

## 5. 内置底色（ui-woodcraft 负责呈现，色值不得改）

| id | 中文名 | 色值 |
|---|---|---|
| white | 白底 | #FFFFFF |
| blue | 蓝底 | #438EDB |
| red | 红底 | #D9001B |
| deep_blue | 深蓝底 | #244A83 |
| gray | 浅灰底 | #F0F0F0 |
| blue_gradient | 蓝渐变 | #628BCE → #2B5AA0 |

候选结果按此顺序排列，默认选中 `white`。

## 6. 错误契约

| 异常 | 中文文案 |
|---|---|
| MattingException | 抠图失败了，换一张试试吧 |
| NoFaceException（仅提示，不阻断） | 没找到人脸，请手动框选 |
| UnsupportedImageException | 这个图片格式打不开 |
| ImageTooLargeException | 图片太大了，请用小于 8000px 的照片 |

所有异常必须在 controller 层转成 `AppState.errorMessage`，**不得让异常穿透到 UI**。

---

## 7. 截图接缝（阶段 1.5 追加，主会话写入）

G2C.1 要求用 `FakeController` 截出 8 张固定场景图。但 `lib/ui/` 归 ui-woodcraft，
`integration_test/` 归 gatekeeper（考生不出考卷）。两者必须靠一个稳定接缝对接，
否则截图测试要么侵入 UI 内部实现，要么根本驱动不了瞬时状态（S3 拖拽中 / S4 生成中）。

### 7.1 场景工厂（ui-woodcraft 提供，gatekeeper 消费）

ui-woodcraft 必须提供 `lib/ui/dev/shot_harness.dart`：

```dart
/// 截图场景 id，与 capture-shots skill 的文件名一一对应，不得增删改名。
const List<String> kShotScenarios = <String>[
  'S1_empty',      // 空态，未选照片
  'S2_loaded',     // 已加载照片，裁剪框默认位置
  'S3_dragging',   // 按住右下角控制点拖拽中
  'S4_generating', // 候选区生成中
  'S5_ready',      // 6 个候选就绪，选中蓝底
  'S6_saved',      // 保存成功反馈态
];

/// 构造处于指定场景状态的完整 App 根 widget（内部用 FakeController 驱动）。
///
/// 必须是**确定性**的：同一 id 每次构造出同一画面，不依赖真实模型、
/// 不依赖时序、不依赖随机数。S3/S4 这类瞬时态由 FakeController 直接钉住，
/// 不许靠 `Future.delayed` 碰运气。
///
/// 照片输入固定用 `test/golden/src/` 按文件名排序的第一张（g01.jpg），
/// 以 asset 或内嵌字节的方式提供，不读运行时相册。
Widget buildShotScenario(String scenarioId);
```

`buildShotScenario` 返回的 widget 必须能直接塞进 `tester.pumpWidget()`，
自带 `MaterialApp` / `ProviderScope` 等一切所需上下文。

### 7.2 稳定 Key（ui-woodcraft 必须挂，gatekeeper 只准用这些）

widget 树内部结构随时可能变，测试只认这几个 Key：

| Key | 挂在哪 | 用途 |
|---|---|---|
| `Key('area_a')` | 区域 A 根容器 | G2C 三段比例实测 |
| `Key('area_b')` | 区域 B 根容器 | 同上 |
| `Key('area_c')` | 区域 C 根容器 | 同上 |
| `Key('btn_pick')` | 空态"轻触选择照片" | 交互测试 |
| `Key('btn_save')` | 保存按钮 | 交互测试 |
| `Key('spec_ruler')` | 顶部黄铜标尺条 | 规格切换 |
| `Key('crop_handle_tl'/'tr'/'bl'/'br')` | 裁剪框四角控制点 | G2C.5 热区 / G2C.6 宽高比 / G2C.7 边界 |
| `Key('crop_handle_t'/'b'/'l'/'r')` | 裁剪框四边控制点 | 同上 |
| `Key('crop_box')` | 裁剪框本体 | 整体拖动 |
| `Key('candidate_<styleId>')` | 每个候选项，如 `candidate_blue` | G2C 选中态 |

ui-woodcraft 若要改 Key 名或场景 id，必须在报告里向主会话提出，不得自己改 ——
改了 gatekeeper 的截图测试会静默截错图，而不是报错。
