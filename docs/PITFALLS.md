# 踩坑记录

任何浪费超过 10 分钟的坑，追加一条到这里。**只追加，不删改他人条目。**

格式：
```
## [agent名] 一句话标题
- 现象：
- 原因：
- 解法：
```

## [gatekeeper] dart:io ZLibDecoder 没有 decodeBytes 方法
- 现象：写 PNG inflate 时想当然地调用 `ZLibDecoder().decodeBytes(bytes)`，这个方法根本不存在。
- 原因：`ZLibDecoder` 是 `Converter<List<int>, List<int>>`，正确 API 是 `.convert(bytes)`。
- 解法：统一用 `ZLibDecoder().convert(zlibBytes)`。已在 `tools/gate/png_utils.dart` 里改好，
  其他 agent 如果也要手撸 PNG/zlib 解码，直接抄这个函数，别重踩。

## [gatekeeper] integration_test 截图流水线依赖 pubspec.yaml 尚未声明的 dev_dependencies
- 现象：`integration_test/shots_test.dart`、`test_driver/integration_test_driver.dart` 目前无法编译。
- 原因：阶段 1 此刻 `pubspec.yaml`、`lib/main.dart` 都还不存在（等 env-setup/主会话完成脚手架）；
  这两个文件还依赖 `integration_test: {sdk: flutter}` 和 `flutter_test: {sdk: flutter}`。
- 解法：这是给主会话的请求，非阻塞项——阶段 1.5 落地 `pubspec.yaml` 时请把这两个 dev_dependencies
  加上。`shots_test.dart` 用相对路径 `import '../lib/main.dart' as app;` 引用应用入口，
  故意不写死 package 名，pubspec 的 `name:` 定成什么都不需要回来改这个文件。

## [env-setup] onnxruntime 1.4.1 插件 compileSdk 33 与其他 androidx 依赖冲突
- 现象：`flutter build apk --debug` 在 `:onnxruntime:checkDebugAarMetadata` 报 15 条
  "requires libraries and applications that depend on it to compile against
  version 34 or later"，构建失败。
- 原因：pub 包 `onnxruntime: ^1.4.1`（唯一可用版本）的 `android/build.gradle` 里硬编码
  `compileSdkVersion 33`，晚于自己引入的 androidx.fragment/window/lifecycle/
  exifinterface 等库要求的 compileSdk 34+。这个包放在 pub cache 里，不能直接改。
- 解法：在项目根 `android/build.gradle.kts` 里只对 `:onnxruntime` 这一个子项目注册
  `project.afterEvaluate { ext.compileSdk = 36 }`（36 与 app 的
  `flutter.compileSdkVersion` 一致）。**注意不要用泛化的
  `subprojects { afterEvaluate {...} }` 或 `plugins.withId(...) { compileSdk = 36 }`**：
  前者会因为别的子项目已经因 `evaluationDependsOn(":app")` 提前 eval 完而报
  "Cannot run Project.afterEvaluate(Action) when the project is already evaluated"；
  后者的回调在 `apply plugin:` 那一刻就触发，早于 onnxruntime 自己脚本里
  `compileSdkVersion 33` 那行，会被它自己覆盖回 33，等于没修。必须精确 scope 到
  `:onnxruntime` 单个子项目 + `afterEvaluate`（此时它自己的脚本已跑完）才生效。
  这段 workaround 目前写在 `android/build.gradle.kts`（env-setup 为了让 G1.1
  通过而改，已越出常规势力范围，release agent 阶段 5 请知悉，若替换掉
  onnxruntime 插件可移除这段）。

## [qa-batch] mtcnn-runtime 在 0 张脸时抛 ValueError 而不是返回空列表
- 现象：用 `.venv_ref` 的 `mtcnnruntime.MTCNN().detect(img)` 对纯风景/截图等无人脸图片
  检测时，偶发 `ValueError: need at least one array to concatenate`（`detector.py`
  里 P-Net 阶段 `np.vstack(bounding_boxes)`，当所有尺度都没有候选框时列表为空）。
  不是每张无人脸图都触发（取决于图像内容是否连粗筛候选框都没有），概率性出现。
- 原因：上游 `mtcnn-runtime` 包（HivisionIDPhotos 依赖）没有对"完全没有候选框"这个
  边界情况做判空，直接 vstack 空列表。
- 解法：调用处套 `try: faces, landmarks = mtcnn.detect(...) except ValueError: faces, landmarks = [], []`，
  按 0 张脸处理即可。已在 `test/batch/freeze_dataset.py` 里这样处理。任何后续 agent
  （尤其 adversarial）用同一参考环境跑人脸检测，会遇到同一个坑。

## [gatekeeper] am start -W 前必须先 adb install，flutter build 不会自动装
- 现象：`collect_metrics.dart` 第一轮直接对着刚 `flutter build apk --debug` 出的 apk 跑
  `adb shell am start -W -n <pkg>/.MainActivity`，报 "Error type 3 / Activity class ...
  does not exist"，`coldStartMs` 解析不到，1.7 判 FAIL。
- 原因：`flutter build apk` 只是把 apk 产出到 `build/app/outputs/flutter-apk/`，
  不会自动安装到当前在线的模拟器/真机上（这点和 `flutter run`/`flutter install` 不同）。
- 解法：`am start` 前先显式 `adb -s <device> install -r <apk路径>`，装不上就直接 FAIL 并
  报出 adb install 的输出，不要猜测。已在 `tools/gate/collect_metrics.dart` 里修好。

## [gatekeeper] G2A/G2B 的评测 mixin 摸不到平台通道/dart:ui，必须在设备上跑
- 现象：`removeBackground`/`detectFace`（onnxruntime 平台通道）和 `compose`
  （`lib/core/api.dart` 依赖 `dart:ui show Rect`）都没法在纯 `dart run` 里跑——
  `dart:ui` 是 Flutter 引擎专属库，Dart SDK CLI 根本解析不了这个 import。
- 解法：G2A/G2B 的实际推理/合成评测代码必须写成 `integration_test/*.dart`，
  用 `flutter test xxx_test.dart -d <device>` 跑（不需要 `flutter drive`，`flutter test`
  能直接跑 integration_test 目标）。host 侧的 `gate_G2A.dart`/`gate_G2B.dart` 只负责
  adb push 数据、发起这条命令、adb pull 结果 JSON、套阈值判断——阈值判断本身留在
  host 侧，不下放到设备端代码里（裁判不下场，设备端代码只产出测量数字）。

## [gatekeeper] `mixin X implements IdPhotoEngine` 的坑：胶水类必须补全整个接口，且补的桩不能覆盖真实方法
- 现象：`ComposeEngineMixin implements IdPhotoEngine`（`MattingEngineMixin` 则没有
  这个 `implements` 子句）。`class GateComposeHarness extends Object with impl.ComposeEngineMixin {}`
  编译不过，因为 mixin 声明了实现整个 `IdPhotoEngine`，但只真正覆写了 `compose`，
  其余 4 个方法仍是抽象的，混入后的具体类必须补全。
- 陷阱：补桩时如果手滑给已经真正实现的那个方法（这里是 `compose`）也生成一个
  `throw UnimplementedError` 占位，Dart 的方法解析规则是"类体自己声明的方法覆盖
  mixin 里的同名方法"——桩会**静默**吃掉真实实现，测试照样能跑，但测的是空壳，
  不会报错，是最隐蔽的一种"测了等于没测"。
- 解法：`tools/gate/device_harness_common.dart` 的 `findMixinImportPath` 会检测
  mixin 声明是否带 `implements IdPhotoEngine`，`generateHarnessFile` 按调用方传入的
  `providedMethods`（明确列出这个 mixin 真正实现了哪几个方法）只给**其余**方法生成桩。
  这是我自己在这轮里边写边用真实的 `ComposeEngineMixin`/`MattingEngineMixin`
  （ml-porting/imaging 并行交付中的快照）实测发现并修复的，不是纸上谈兵。

## [ui-woodcraft] integration_test 的 convertFlutterSurfaceToImage 一次会话只能调一次
- 现象：`integration_test/shots_test.dart` 在 for 循环里对每个场景先 `pumpWidget`
  再 `convertFlutterSurfaceToImage()`，第 1 张 `S1_empty.png` 正常落盘，第 2 个场景
  直接崩：`Surface already converted to an image`，
  `package:integration_test/src/_callback_io.dart:70 '!_isSurfaceRendered'`。
  结果 8 张只出得来 1 张，G2C.1 必然 FAIL。
- 原因：`_IOCallbackManager.convertFlutterSurfaceToImage()` 内部有
  `assert(!_isSurfaceRendered)`，它是**整个测试会话一次性**的开关（把 SurfaceView
  换成可读回的 ImageReader），不是每帧的操作。调第二次必然断言失败。
- 解法：把 `convertFlutterSurfaceToImage()` 挪到 for 循环**之前**只调一次，
  循环里只保留 `pumpWidget` → `pumpAndSettle` → `takeScreenshot`。
  本条属 gatekeeper 势力范围（`integration_test/`），ui-woodcraft 不改，已在报告里提出。

## [ui-woodcraft] pumpAndSettle 与无限循环动画互斥，进度指示器必须可冻结
- 现象：候选区"冲洗中"如果用 `AnimationController..repeat()`，截图流水线里
  `await tester.pumpAndSettle()` 会一直有新帧被调度，最终超时抛
  `pumpAndSettle timed out`，S4 这一张永远截不出来。
- 原因：`pumpAndSettle` 的循环条件就是 `binding.hasScheduledFrame`，
  循环动画意味着这个条件永远为真。Material 的 `CircularProgressIndicator` 同理，
  只是它被 RUBRIC 致命项 1 禁掉了，我们自绘的复古进度条也一样会踩。
- 解法：所有循环动画的相位改成"从状态里读"，由 `UiConfig.freezeAnimations`
  决定是否真的起 `AnimationController`；截图场景 (`buildShotScenario`) 一律传
  `freezeAnimations: true, frozenPhase: 0.38`。同一场景每次画同一帧，
  既满足 CONTRACTS §7.1 的确定性，也不会卡住 pumpAndSettle。
  自动消失的 Toast 计时器同理要能关掉。

## [ui-woodcraft] 程序化材质不要用"逐格子画方块"实现二维噪声
- 现象：纸纹/绒布的斑驳用 `for y { for x { drawRect(cell) } }` + 二维值噪声实现，
  真机截图上出现明显的棋盘状色阶，像 JPEG 块效应，一眼就是"假材质"（RUBRIC R1 扣分项）。
- 原因：每个格子取一个采样值画成纯色方块，相邻格之间是硬边；即使把格子缩到 6px，
  在 2.75 倍 DPR 的截图上依然看得见台阶。
- 解法：二维斑驳改用**一批径向渐变的柔边色斑**（`ui.Gradient.radial`，中心有 alpha、
  边缘透明），一维方向性色带改用**单个多停靠点的线性渐变**（一次 `drawRect`
  给 48 个 stop）。两者都没有硬边。另外斑点半径要按表面短边缩放，
  否则同一组常量在 150px 的小卡片上会变成几块大污渍。

## [ui-woodcraft] pubspec.yaml 没有 fonts: 段时，用 FontLoader 从已声明的 assets 目录注册字体
- 现象：`assets/fonts/` 已在 pubspec 的 `assets:` 里声明，但没有 `fonts:` 段，
  `TextStyle(fontFamily: 'XXX')` 完全不生效（静默回退系统字体，不报错）。
  而 `pubspec.yaml` 归主会话独占，ui-woodcraft 不能自己加。
- 解法：启动时 `FontLoader('MuZhaoSerif')..addFont(rootBundle.load('assets/fonts/x.ttf'))..load()`
  在运行期注册同名字体族，效果与 pubspec 声明等价。加载完成后引擎会广播
  `fontsChange` 自动重排全部文本，**不需要**自己 setState，也不该阻塞首帧
  （阻塞会让截图拍到空白帧）。见 `lib/ui/theme/fonts.dart`。

## [imaging] 软边 alpha + 纯色底 = G2B.6/2B.7 必挂，光做 unpremultiply 救不回来
- 现象：常规合成 `out = F·a + BG·(1−a)`，即使去色边做得完美，
  alpha=205（刚过 200 判定线）的像素换纯绿底后仍然会掺进 20% 的绿，
  `G − max(R,B)` 直接 ≈ 50，超过 40 的判定线。**只要保留软边，这条就不可能为 0。**
- 原因：验收判据是「alpha > 200 的像素不得有底色成分」，而 alpha=201 的像素
  按定义就有 21% 的底色成分。去色边解决的是「原背景色残留」，
  解决不了「新底色按 alpha 掺进来」。这是两件事，容易混为一谈。
- 解法：三件事要一起做，缺一不可——
  1. **unpremultiply 去色边**：用推挽插值从 alpha<0.1 的像素外推出原背景色，
     再 `F = (C − (1−a)·B)/a` 反解真前景色；
  2. **alpha 硬化**：`a' = clamp((a−0.22)/(0.62−0.22))`，让 alpha ≥ 0.62 的像素
     一律输出纯前景（0.62 < 200/255，留够余量），软边只保留在 0.22–0.62 之间；
  3. **窗口 alpha 最大值强制不透明**：验收脚本多半用**点采样**把 alpha 搬到成片
     坐标系，而渲染用的是盒式平均。轮廓上点采样取到 207、窗口平均只有 0.4 是常事，
     于是「脚本认为是前景、渲染认为是软边」，底色照样漏。必须额外算一份
     降采样窗口（再外扩 1 像素）内的 alpha 最大值，超过 0.75 就强制纯前景。
     只做 1、2 时黄金集实测仍有 2/9200000 个像素超线，加上 3 才归零。
- **最关键的一条**：先去读验收脚本怎么数，别照着 ACCEPTANCE.md 的文字自己脑补。
  本项目 `integration_test/compose_eval_test.dart` 的实际口径是
  「**遍历成片每个像素**，只放过接近纯底色的（`g>200&&r<100&&b<100`），
  其余一旦 `G−max(R,B)>40` 就计数」——**根本不看 alpha**。
  于是灰色前景与纯绿底之间任何半透明过渡像素（a′ 约 0.44–0.87）都算溢色，
  一条边就能贡献上千个。结论：**成片必须输出硬边**（每个像素要么纯前景要么纯底色），
  阈值作用在盒式平均后的 alpha 上以保证轮廓位置仍有亚像素精度。
  我按「只查 alpha>200 区域」写的自检一开始全绿，差点漏掉这条。
- 附带坑：**JPEG 振铃也算溢色**。软边版本 q95 实测最大 `min(R,B)−G` = 38（判定线 40），
  只剩 2 个色阶余量；改硬边后阶跃两侧变成平坦色块，振铃变小，q95/q97 已无实质差别。
  测溢色一定要**解码成品 JPEG 之后再测**，测渲染缓冲会漏掉这一部分。
- 附带坑 3：低 alpha 处 unpremultiply 会把误差放大 1/a 倍，F 容易被顶到 0/255 轨道上，
  硬边输出时这些饱和杂色点会整个显示出来。要按 (1−a)² 的权重向「局部实心前景色」
  回落（同一套推挽插值，种子换成 alpha≥0.9 的像素）。
- 附带坑 4：**compose 不要偷偷替换入参 spec 的几何比例**。
  `photo_specs.dart` 里调校过的 headTopRatio/headHeightRatio 只供接线层选用；
  验收脚本传 `kBuiltInSpecs`（0.08/0.62）进来，就拿测量值和这个入参比。
  在 compose 里替换成自己那份（0.09/0.60…）会让偏差正好卡在 0.02 的判定线上。
- 附带坑 2：`image: 4.9.2` 的 `JpegEncoder._writeAPP0()` 把 JFIF 写死成
  `units=0, Xdensity=1, Ydensity=1` 且无参数可改。要写 DPI 必须编码后手动改
  APP0 段第 11–15 字节（units=1, X/Ydensity=300 大端）。见 `lib/core/imaging/jpeg_dpi.dart`。

## [ml-porting] onnxruntime 插件在 Android 上**没有 x86_64 的 .so**，模拟器必挂
- 现象：`libonnxruntime.so` 在 x86_64 AVD 上 `DynamicLibrary.open` 失败，
  warmUp 第一步就抛。真机（arm64）没问题，所以本地看不出来。
- 原因：pub 包 `onnxruntime: 1.4.1` 的 `android/src/main/jniLibs/` 只打了
  `arm64-v8a` 和 `armeabi-v7a`。本项目两台 AVD 都是 x86_64，安装时系统只取
  `lib/x86_64/`，`libonnxruntime.so` 根本不在包里。凡是跑在模拟器上的
  integration_test（G2A 设备端评测、G3、G4）都会在这一步全灭。
- 解法：ml-porting 已把官方 `com.microsoft.onnxruntime:onnxruntime-android:1.15.1`
  里的 `jni/x86_64/libonnxruntime.so` 放到 `native/android/jniLibs/x86_64/`
  （版本可对：该 AAR 的 arm64 .so 与插件自带那份字节数完全一致，说明插件就是
  从它重打包的）。**还差最后一步**：`android/app/build.gradle.kts` 归 release，
  需要在 `android { }` 里加
  `sourceSets { getByName("main") { jniLibs.srcDirs("src/main/jniLibs", "../../native/android/jniLibs") } }`。
  没加这一行之前，任何在模拟器上跑推理的门禁都会 FAIL，且报错长得不像"缺 so"。

## [ml-porting] onnxruntime 插件的 `OrtSession.fromFile` 在 Windows 上必坏
- 现象：宿主机 `flutter test` 里建会话报
  `Load model from 㩃啜敳獲…failed. File doesn't exist`，路径变成乱码方块字。
- 原因：插件把路径按 UTF-8 `char*` 传给 `CreateSession`，而 Windows 上 ORT 的
  `ORTCHAR_T` 是 `wchar_t*`，UTF-8 字节被当成 UTF-16 解释。Android/Linux 上
  `ORTCHAR_T` 就是 `char`，所以只有 Windows 炸。
- 解法：一律走 `OrtSession.fromBuffer(File(path).readAsBytesSync(), options)`
  （底层是 `CreateSessionFromArray`，收字节数组，没有编码问题），各平台行为一致。
  已在 `lib/core/matting/ort_runtime.dart` 里这样写。

## [ml-porting] 黄金集 g08 对输入的 1 个 LSB 都敏感，别把误差都算到量化头上
- 现象：MODNet int8 化以后 g08 的 IoU 怎么调都上不去，其它 7 张都 ≥0.998。
- 原因：g08 是蓬松头发 + 杂乱白背景，alpha 有一大片贴着 128 阈值。
  实测**用 fp32 原始权重**、只给输入加 ±1 LSB 的随机噪声，IoU 就掉到 0.932；
  JPEG 重压到 q95 也只有 0.986。也就是说它本身就在混沌区。
- 解法：先分清误差来源再动手。量化误差可以用"逐层敏感度扫描 + 敏感层保留 fp32"
  压到可忽略；剩下的是 Dart `image` 包与 OpenCV(libjpeg-turbo) 的 JPEG 解码差异
  （实测逐像素平均差 0.5、最大 8–31，主要来自 IDCT 和色度上采样实现不同），
  这部分**没法在 Dart 侧消除**，除非自己重写一个 bit-exact 的 JPEG 解码器。
  谁再去调 g08 的指标，先看这条，别重复走一遍量化调参的死路。
