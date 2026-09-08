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
