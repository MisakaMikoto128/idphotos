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
  final double rollDeg;       // 待施加的摆正角；无法可信估计时恒为 0.0
  final double confidence;
  final Float32List? landmarks;   // YuNet 五关键点（阶段 6 透传）
  final RollSource rollSource;    // rollDeg 的来源（阶段 6 P0 新增）
}

enum RollSource { pupil, unavailable, given }

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

**阶段 3 后追加（主会话，审查 A3）**：`suggestedCropInSourcePx` 已提升到 `IdPhotoEngine`
抽象面（`lib/core/api.dart`）——它是纯几何、无模型依赖，此前只存在于 ComposeEngineMixin
迫使 controller 依赖具体实现类、无法注入假引擎。mixin 实现不变。

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

**语义扩展记录（阶段 6 P0，主会话授权）**：[FaceInfo] 新增可空 `landmarks`
（YuNet 五关键点，工作分辨率坐标）。P0 歪斜复现证明单凭眼球连线估角在
眼镜/上睑下垂/单眼 hooded 时误差 3.7~6.7° 且可反号——imaging 将用
多线（眼线/嘴线/鼻梁）中位融合仲裁。ml-porting 负责填充，imaging 负责消费。

**语义扩展记录（阶段 6 P0 二次收紧，主会话授权）**：`rollDeg` 的语义从
"面内旋转角"改为 **"待施加的摆正角"**——引擎测不出时必须给 0.0，由 ml-porting
在内部决定信任度，**imaging 无条件按 `rollDeg` 旋转、不做二次仲裁**。
配套新增 `RollSource`（`pupil` / `unavailable` / `given`）仅供门禁与排查，
消费方不得据此改变行为。

**符号口径（事故级，必须按公式理解，不要用"顺/逆时针"口头描述）**：记
`φ = atan2(y_图像右眼 − y_图像左眼, x_图像右眼 − x_图像左眼)`（图像坐标 y 向下），
则 **`rollDeg == φ`，不取负**。实现侧的恒等式是

```
输出倾角 = φ − rollDeg          （实测印证：p2 φ=−0.22 注入 rollDeg=−3.913 → 输出 +3.69）
```

所以摆平当且仅当 `rollDeg == φ`。

⚠️ **已出过一次反向事故**：本文件早先的措辞写过"正值 = 把图像顺时针转"，
**与实现相反**（`RotationPlan.toRotated` 用 `R(−angleRad)`，正 θ 使内容在
atan2 口径下转 −θ；而 y 向下时 atan2 正向恰好是视觉顺时针，故正 `rollDeg`
实际让画面**逆**时针转）。该措辞已把 qa-batch 的真值文件带偏成
`expectedCorrectionDeg = −φ`，采用它会让 p1 的残差从 +0.02 变成 8.82（PASS→FAIL）。
相关三处（本文件、`api.dart`、qa-batch 真值文件）已一并改正。
另有独立第二证：`RotationPlan.angleDeg == rollDeg`（`planRotation` 不取负），
故门禁读到的 `ComposeDiagnostics.straightenDeg` 与 `rollDeg` 同号同值。

上一版（同阶段更早，已被本次取代）：暴露 `landmarks` 给 imaging 做多线融合。
实测否决——眼线、嘴线、鼻线同源于同一组 YuNet 眼睑关键点，强相关，融合是零和的
（`docs/PITFALLS.md` imaging 两条归因条目，104 组系列实测差 ±0.02°）；根因在
关键点定位（眼点落在上睑褶上，p1 高约 50px）。`landmarks` 字段保留（诊断与
回归夹具仍用），但**不再作为生产摆正路径**。

**语义扩展记录（G4，主会话授权）**：ml-porting 的 G4.3 修复在 `removeBackground`
入口加了人脸门槛——非人像输入（无人脸）**作为阻断性拒绝抛出 NoFaceException**，
而不是产出碎片拼贴的"伪成功"候选（item 60 电路板案例，详见 out/GATE_G4_r1.md）。
"NoFace 仅提示不阻断"的原始语义保留在 detectFace 返回 null 的路径上；
异常类本身在"管线主动拒绝"场景复用同一文案（"没找到人脸，请手动框选"），
controller 错误通道不变。
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

/// 阶段 6 追加（主会话追认 ui-woodcraft 的申请）：
/// 'S7_about' —— 关于页抽屉展开态（入口 btn_about 长按黄铜标尺）。
/// 场景清单从 6 张扩到 7 张；既有 6 张语义不变。

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
| `Key('photo_display')` | **区域 A 内照片实际铺满的矩形**（`contain` 后的显示区，比裁剪框大） | G2C.2/2C.4 排除照片区域；G2C.7 判裁剪框边界 |
| `Key('candidate_<styleId>')` | 每个候选项，如 `candidate_blue` | G2C 选中态 |

ui-woodcraft 若要改 Key 名或场景 id，必须在报告里向主会话提出，不得自己改 ——
改了 gatekeeper 的截图测试会静默截错图，而不是报错。

### 7.3 `photo_display` 的由来（阶段 2 后追加）

`/code-review high` 发现 G2C.2/2C.4 只排除了 `crop_box`，而区域 A 里照片是铺满整个显示矩形的，
裁剪框外的照片只被压暗（`Shade.scrim` 60% alpha）而没有从采样集合剔除。
换成饱和度高的真实照片后，这些像素会被拿去和木色卡比 ΔE ——
**一个本该只评界面 chrome 的门禁会误判 FAIL，冤枉 ui-woodcraft**。
ACCEPTANCE.md 2C.2 的原文是"截图**去除照片区域后**"，所以这不是加严，是修正实现使其符合原文。

gatekeeper 拒绝了"用 `find.byType(CropOverlay)` 绕过去"的做法，理由正确：
那会让门禁耦合到 ui-woodcraft 的内部结构，违反 §7.2 "只准用列出的稳定 Key"。
因此由主会话在此正式加入 `photo_display`。

同一个 Key 还用于修正 G2C.7：裁剪框的边界约束应当相对**照片显示区**判定，
而不是相对区域 A 容器 —— 后者判不出"框跑到照片外、成片出现底色填充条"这类缺陷。
