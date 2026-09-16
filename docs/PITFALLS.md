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

## [gatekeeper] shots_test.dart 把 convertFlutterSurfaceToImage() 错放进了场景循环
- 现象：8 场景截图流水线只产出 1 张，第 2 个场景起 `flutter drive` 抛
  `Surface already converted to an image`（ui-woodcraft 用自己的 adb 兜底截图自测
  UI 时发现这个 G2C 官方流水线的问题，按纪律没有动手改我的文件，写了 PITFALLS 转达）。
- 原因：`binding.convertFlutterSurfaceToImage()` 每个测试生命周期只能调用一次
  （一次性把渲染 surface 切到可截图模式），我在循环体内每个场景都调用了一次。
- 解法：加一个 `surfaceConverted` 标志位，只在第一个场景的首帧之后转换一次，
  后续场景直接复用。已在 `integration_test/shots_test.dart` 修好。

## [gatekeeper] adb push 到 /sdcard/ 的文件 App 自己读不到（scoped storage）
- 现象：`gate_G2A.dart` 第一次跑设备端评测，`flutter test matting_eval_test.dart` 里
  `File('/sdcard/muzhao_gate_tmp/dataset_manifest.json').readAsBytes()` 报
  `PathAccessException ... errno = 13 (Permission denied)`，和模型/代码对不对无关。
- 原因：`adb push` 建到 `/sdcard/...` 的文件属主是 shell 的 `media_rw` 组
  （`adb shell ls -la` 实测 `-rw-rw---- u0_a179 media_rw`），App 自己的沙箱 UID 不在
  这个组，Android 10+ 的 scoped storage（FUSE 模拟层）直接拒绝跨 UID 读取。
- 解法：改用 `/data/local/tmp/`——真实 ext4 路径，不走 scoped storage。`adb push`
  在这里建的文件默认 world-readable（`rw-rw-rw-`），子目录 world-traversable
  （`rwxrwxr-x`），App 读没问题；但顶层目录本身默认只有 shell 能写，App 要在里面
  **新建**结果 JSON 前，host 侧必须先 `adb shell mkdir -p <dir> && chmod 777 <dir>`
  （见 `tools/gate/device_harness_common.dart` 的 `prepareDeviceGateDir`）。
  实测验证过整条链路：push 目录/文件权限、chmod 后 App 能建文件，都用
  `adb shell ls -la` 逐层核对过，不是纸上推断。

## [imaging] 溢色判据对通道**不对称**：只用绿底自测必然漏掉品红方向
- 现象：G2B 第 1 轮我自测「溢色 0」，门禁实测**绿 0 / 品红 295**。不是脚本 bug，
  两套判定是镜像对称写的。
- 原因：双线性插值是逐通道独立的凸组合，会**凭空造出原图不存在的色相**，
  而两个判据抓它的能力天差地别。以「青色标记条 (0,255,255) 与中性灰混色」为例：
  G 和 B 同步变化，`G − max(R,B)` 恒等于 0，绿判据**永远抓不到**；
  换成品红 (255,0,255) 与灰混色，R、B 同升而 G 下降，`min(R,B) − G` 直接冲到 255·t。
  也就是说**绿底自测通过，完全不能推出品红底也通过**。
- 解法：不要给品红打补丁（补丁只会让下一种底色翻车）。真正对任意底色都成立的做法是
  **禁止重采样发明新色相**：四角样本的 `R−G`/`B−G`/`R−B` 跨度超过阈值时判定这一格
  跨了色度硬边，色度取权重最大的那个真实源样本、亮度仍走双线性
  （`render.dart` 的 `kChromaSnapSpread`）。自测必须跑绿/品红/红/蓝四种极端底色。

## [imaging] JPEG 振铃不随 quality 单调下降，q95→q98 反而更差
- 现象：门禁同款合成图（纯蓝底 + 纯青标记条，亮度阶跃 Y 从 29 跳到 179）下，
  溢色计数在 q94/95/96/98 上是 **287 / 0 / 3 / 6**。
- 原因：Gibbs 过冲的来源是被保留的高频 AC 系数。质量越高、量化步长越小，
  过冲越不会被量化抹平，反而更明显；低质量则是过冲和细节一起被量化掉。
  想靠「提高 quality 减少溢色」的直觉是错的。
- 附带结论：**溢色必须解码成品 JPEG 之后再测**，测渲染缓冲会漏掉振铃这一份；
  且一个 1.6px 高的全宽饱和色条会让整行进入同一个 8×8 块，振铃沿整行铺开。

## [imaging] 摆正的方向性 bug：错在「用错 x 去转 y」，不是旋转符号
- 现象：`rollDeg = −10°` 残差 0.0° 完美，`+10°` 成片里**完全找不到头顶标记条**。
- 原因：`FaceInfo.headTopY` 是纯 y 标量，要把「头顶」搬进旋转空间必须凑一个 x。
  之前用 `box.center.dx`，而它未必落在头部真实竖直轴上；旋转会把这份横向误差
  按 `Δy = sinθ·Δx` 折算进 y（θ=10°、Δx=165px → Δy≈29px），**正负角符号相反**，
  于是一侧完美、另一侧把头顶整条裁出画面。只验一侧必然漏掉。
- 解法：用 alpha 掩膜在旋转空间里量出头部真实水平中心 Xc
  （`crop_geometry.dart` 的 `probeHeadInRotated`），再按仿射逆关系闭式解出
  「源图 y 恰为 headTopY」的那条旋转空间行。θ 只出现在 `sinθ·Δx` 和 `cosθ` 里，
  正负角完全对称。**摆正类改动一律要正负两个方向 + 至少两个角度一起验。**

## [imaging] 真实人像的「品红溢色」有天然假阳性，判据必须看换底前后的差异
- 现象：黄金集 g05 在纯品红底下有 2 个像素满足 `min(R,B) − G > 40`。
- 原因：被摄者身上本来就有紫红色（衣物/深紫头发）。实测同一坐标换**白底**合成，
  一个是 [181,118,159] vs [177,117,154]（底色贡献 +4），另一个 [73,0,70] vs
  [80,4,88]（底色贡献 **−6**，白底反而更「品红」）——与换底质量无关。
- 解法：对真实照片，「溢色」只能定义成**底色渗进前景**，即同一像素在目标底色下的
  偏色量减去白底下的偏色量。门禁的 2B.7 用灰色合成人像（不含这种自然色），
  绝对计数 0 才是可达的；拿绝对计数去卡真实照片会得到假阳性。

## [imaging] 把用户框选映射进旋转空间，取轴对齐外接框 = 静默篡改构图
- 现象：`|rollDeg|>3°` 触发摆正后，用户框的 460×644 被换成 564.8×790.8（10°），
  成片里主体只剩用户框选的 **81.7%**（6° 时 88.2%）。用户框得更紧也纠正不了 ——
  外接框按同一比例继续放大，只是基数变小。全程无报错、无提示。
- 原因：用四个角点转到旋转空间后取 AABB。`W'=w·cosθ+h·sinθ`、`H'=w·sinθ+h·cosθ`
  **恒大于** `w×h`，`normalizeToAspect` 再把它撑回目标比例，于是二次放大。
- 解法：把框当**刚体**整体反旋转 —— 只用 `plan.toRotated` 映射中心，宽高原样带过去。
  面积与主体尺度精确守恒（实测保留 100.5%）。代价是框的四角可能探到源图之外，
  但这条路和自动取景的越界策略一致（alpha=0 填底色），实测 ±10° × 5 个贴角/全出图
  用例，图外非白像素 0。**判「越界」要在源图空间判**：旋转画布是源图四角的包围盒，
  它自己的四个角本来就是空的，拿旋转画布边界去判会漏掉真正的空区。
- 通用教训：任何「把矩形换到另一个坐标系」的代码，先问一句它是不是保面积的。
  AABB 不是；它只在你**本来就想要包住**的场景里正确。

## [gatekeeper] 双 AVD 并跑时主 AVD 反复崩溃，`waitForAdbDeviceOnline` 也不区分设备
- 现象：G2C 复核本轮（响应 REVIEW_G2 #7/#2）连续 3 次 `runFullShotsPipeline()` 全部
  在主 AVD（Pixel_3a_API_34, emulator-5554）上失败：`adb.exe: device 'emulator-5554'
  not found`，之后触发 adb 兜底（只拿到 1 张纯截图，2C.1/2C.2/2C.3/2C.4 被迫全 FAIL）。
  每次事后 `adb devices -l` 都发现主 AVD 的 qemu 进程已经整个消失（不是卡住，是真的
  退出了），`systeminfo` 显示当时可用物理内存只剩 ~3GB（总 28GB）。判断是host 内存
  压力下 AEHD 加速的主 AVD 被挤掉，与本轮改动的代码无关（capture_shots.dart /
  device_harness_common.dart 本轮未改一行）。
- 顺带发现一个独立的小 bug（未在本轮修，记录留给下次）：`waitForAdbDeviceOnline()`
  （`tools/gate/gate_common.dart`）只返回 `adb devices` 里**第一个** `device` 状态的
  设备，完全不区分调用方想要的是主 AVD 还是小屏 AVD。两台都在线时，`capture_shots.dart`
  给小屏 AVD 请求设备也会拿到主 AVD 的 serial——如果那次侥幸没崩溃，小屏截图会在错误
  分辨率的设备上跑，`S2_small/S5_small` 内容其实是主屏分辨率，不会报错但语义错误。
  建议后续给 `waitForAdbDeviceOnline` 加一个可选的 `productModel`/期望分辨率过滤，
  或者直接用 `adb -s <serial> shell wm size` 校验后再用。
- 排查手法记录下来供下次复用：`adb devices -l`（判存活）→
  `adb -s <serial> shell wm size`（区分主屏 1080x2220 / 小屏 720x1280，两台设备的
  `model`/`product` 字段完全一样，光看 `adb devices -l` 分不出谁是谁）→
  `tasklist | grep qemu-system` 数进程数对不对得上→ `systeminfo | grep Available` 看
  host 内存。
- 本轮处理方式：不是代码缺陷，没有为了强行拿到 8/8 截图而反复重跑到烧完 3 轮预算；
  2C.6/2C.7 是 host 端 `flutter test`、不依赖模拟器，独立于此问题被完整验证了两次
  （结果一致）；2C.1-2C.4 本轮如实标记为因 host 资源不足未能复核，留给下一轮。

## [ui-woodcraft] 2026-09-14 子集字体重新生成的两个坑

- `pyftsubset --layout-features='*'` 会把 Noto Serif SC 的纵排/异体等 GSUB/GPOS 全保留：478 字符的子集单个字重从 151KB 涨到 234KB，两个字重就 467KB，直接顶爆 G2C.8 的 400KB 硬线。**不要加这个参数**，默认特性集即可（最终 151,052 + 151,040 = 302,092B）。
- U+21B3（↳）在 NotoSerifSC-VF 源字体里根本没有字形，离线无法补；它只出现在 `lib/core/imaging/dev_selfcheck.dart` 的控制台日志里，UI 不渲染，不算缺字。
- 字符集提取器已重写为真正的 Dart 字符串扫描器：`dart run lib/ui/dev/charset_scan.dart`，可正确处理插值 `${}`、`\u{...}`、三引号、原始字符串（旧的正则版漏了 28 字）。新增文案后跑它 + 重新 pyftsubset + 同步 `fonts.dart` 的 coveredCharset。

## [gatekeeper] host GPU 驱动栈损坏后模拟器起不来/截图 drive 带走 qemu + Windows 增量 assembleDebug 产出损坏 APK
- 现象一（2026-09-14）：`flutter emulators --launch` 和裸 `emulator -avd` 全部卡死或退出。
  `-verbose` 抓到真因：`Failed to make GLES 2.x context current` → `Failed to initialize GL emulation`，
  软渲染后又报 `vkGetDeviceQueue: Invalid device`。回溯 crash DB
  （`%TEMP%\AndroidEmulator\emu-crash-33.1.24.db\reports\`，9月8日 23:35/23:59 两份 47MB/53MB
  minidump）确认 **r2 那三次"内存不足挤崩主 AVD"的真实死因是 host GPU 驱动崩溃**，
  内存压力只是诱因。GPU 栈此后持续劣化直至今天 GL/Vulkan 全废。
- 可用解法：`emulator -avd <id> -no-window -gpu guest -feature -Vulkan`。
  `-gpu guest` 让 App 渲染走 guest 内部软件 GL（不碰 host GL）；`-feature -Vulkan`
  禁掉宿主 Vulkan 仿真（swiftshader_indirect 下 vkGetDeviceQueue 仍会炸）。
  `--no-window` 必须加——带窗口启动会先走 host GL，直接死。
- 现象二：即使模拟器起来了，**Windows 上 Flutter 增量 `assembleDebug` 会产出损坏的 APK**，
  表现为 app 启动即 `Can't load Kernel binary: Invalid kernel binary: Indicated size is
  invalid` → `Could not create root isolate`，driver 侧只看到 "root isolate is taking an
  unusually long time to start"，毫无指向性。全量构建（flutter clean 后第一次）必好，
  增量（10-17s 的 assembleDebug）必坏。怀疑与 Defender 扫描 build 目录有关（本 skill
  Gradle 一节早有预警）。
- 现象三：修好上面两条后 shots drive 仍会把 qemu 宿主进程整个带走（G2A 的推理 drive
  跑 27 分钟没事，shots drive 稳定 3-5 分钟内死）。真凶是 Impeller 的 OpenGLES 后端
  在软件渲染下跑 takeScreenshot。`flutter drive --no-enable-impeller`（退回 Skia，
  仅 deprecation 警告）后 8 张截图全部跑通。真机不受影响，这是纯测试环境 workaround。
- 教训：模拟器"消失/卡死"时先查 crash DB 的 minidump，再看 `systeminfo` 内存——
  r2 把 GPU 崩溃误判成内存问题，多烧了一轮预算。

## [visual-critic r2C] 官方 S2 截图出现"图片间歇性不渲染"，量图时别误判成空态 bug

- 2026-09-14，G2C 第 3 轮官方 8 张截图里，`S2_loaded.png`（1080×2154）区域 A 只有绒布+
  裁剪框，**照片整个没渲染**（框内取色 `(49,75,54)` 与框外绒布同色，仅多一圈暗带），
  但状态文案已是"已完成 6 张"且候选框全是空白纸占位；同场景小屏 `S2_small.png` 却渲染
  完全正常（照片+6 张候选都在）。同一步骤两种结果 → 疑似图片 decode/渲染竞态，而非
  空态逻辑缺失。S3/S4/S5 均正常。
- 教训：审截图遇到"该有的图没有"先对比同场景其他分辨率截图再下结论；qa/gatekeeper
  复拍 S2 时应在截图谓词里显式等待区域 A 图片像素非纯绒布色，避免再拿到间歇性废片。

## [ui-woodcraft] 同一个 tester 连续 pumpWidget 多个场景时，Riverpod 的 overrideWith 会被静默丢弃
- 现象：官方截图 S3/S5/S6 两轮全部没吃到场景状态——S3 的裁剪框不在"拖拽后"位置（`_rects.json` 里
  S2/S3 的 crop_box 完全相同）、S5 选中的是白底而非钉死的蓝底、S6 的保存纸条不出现。查了三处才发现：
  seed 本身传对了（单独 pump S5 时 `container.read` 就是 blue），**只有按官方顺序 S1→…→S5 连续 pump 时才丢**。
- 原因：`integration_test/shots_test.dart` 在同一个 tester 里对 6 个场景逐个 `pumpWidget(buildShotScenario(id))`。
  每个场景的根 widget 都是同类型同位置的 `ProviderScope`，Flutter 会**原地 update** 这个元素而不是卸载重建，
  于是 Riverpod 容器被跨场景复用；`updateOverrides` 对**已经初始化过**的 provider 不生效——S1 已把
  `workbenchProvider` 用默认 seed 初始化，后面场景传入的新 override 闭包（带拖拽框/蓝底/保存反馈）全部被忽略。
- 解法：给每个场景的 `ProviderScope` 挂 `ValueKey('MuZhaoScope-$scenarioId')`（已改在
  `lib/ui/dev/shot_harness.dart` 的 buildShotScenario 里）。换 key 强制旧 scope 卸载、容器按本场景
  overrides 重建。凡是用 Riverpod + 连续 pumpWidget 驱动多状态的测试都要注意这一条。
- 教训：排查这类问题别只看"seed 传没传对"，要用**和流水线完全相同的 pump 序列**复现——单独 pump 一个
  场景永远是好的。

## [ui-woodcraft] 官方 S2 截图"照片整张没渲染"的根因：Image.memory 异步解码 + pumpAndSettle 等不到未调度的帧
- 现象：visual-critic 两轮都见到 S2_loaded.png 里照片整个没渲染、候选全是空白纸，但状态文案已是
  "已完成 6 张"；同场景 S2_small 却正常，看似"间歇性"。10 连拍实验（out/tmp/race_exp_data/）证明
  主 AVD 上是**确定性复现**：10/10 全部丢图，且与上一轮废片逐像素一致。
- 原因：`Image.memory` 的解码在引擎后台线程异步完成，解码回调落地前没有任何帧被调度；
  `pumpAndSettle` 的循环条件是 `hasScheduledFrame`，于是在解码完成前就退出。S2 是整个 drive 里
  **第一个**触发照片/缩略图解码的场景，截图定格在"未解码"帧；到 S3 时解码结果已进 image cache，
  所以 S3/S5 全部正常。小屏 AVD 解码时序不同，侥幸赶上。
- 解法：截图/测试场景不用引擎解码——`lib/ui/widgets/sync_raster.dart` 用 `image` 包**同步**解码字节、
  铺成顶点色三角网格（`canvas.drawVertices`）直出首帧，由 `UiConfig.syncRaster` 开关控制（场景开、
  真机关，真机大图同步解码会卡 UI 线程）。CONTRACTS §7.1 的确定性因此真正成立。
- 附带坑：排查时别拿 (540,600) 单点取色判"照片在不在"——该点在深绿绒布上时和"丢图"同色；
  先导出裁剪图目检，或对区域 A 求色彩方差。

## [ui-woodcraft] charset_scan 报"缺字 据"但没人新加文案：异常/日志字符串也是字符串字面量
- 现象：修绒布噪点时顺手跑 `dart run lib/ui/dev/charset_scan.dart`，突然 COVERAGE FAIL，
  缺字"据"。本轮 UI 文案没新增任何字，以为是扫描器坏了，白查 15 分钟。
- 原因：`sync_raster.dart` 的 `ArgumentError('SyncRaster: 无法解码的图片数据')` 里的"数据"——
  该文件是修 S2 丢图时**新增**的，落地后没人重跑扫描器，子集里一直没有"据"。扫描器扫的是
  `lib/` 全部字符串字面量，**异常消息、debugPrint、semanticLabel 都算**，不只是"界面上看得见的文案"。
- 教训：任何 agent 在 `lib/` 里新增含中文的字符串（哪怕只是异常消息）之后，必须重跑 charset_scan +
  重新 pyftsubset + 同步 `fonts.dart` 的 coveredCharset 三件套；CI/门禁若只在"UI 文案变更"时触发
  字体检查，就会漏掉这一类。另外 `pyftsubset` 对同字符集重跑是幂等安全的，发现缺字直接补跑即可。

## [gatekeeper] 宿主 GPU 损坏机器上，Impeller GLES 渲染真实 UI 的 App 会直接杀死 qemu 宿主进程 —— 直启 APK 必须带 `--ez enable-impeller false`
- 现象（2026-09-14，G3 冷启动测量，5 次复现）：release/profile APK 用普通 `am start` 直启 → qemu 宿主进程**秒死**（无 WER、无 minidump、guest logcat 无任何痕迹、Settings 等非 Flutter 应用正常）；debug（JIT）main.dart App 能过 am start 但 ~45s 内同样死。2 台 AVD、4096/2560MB 客户机内存、有无旧数据都一样。同一 APK 用 `flutter drive --no-enable-impeller`（工具启动）则稳定跑完。Skia 下同一 App 完全稳定。
- 原因：Impeller 的 OpenGLES 后端在本机已损坏的 host GL/SwiftShader 栈上首次真实渲染即把宿主 qemu 进程带走。debug 之前"看起来没事"只是因为 JIT 慢/测试目标不渲染真实 UI。
- 解法：`am start` 直启时手动带 intent extra：`adb shell am start -W --ez enable-impeller false -n <pkg>/.MainActivity` —— 这正是 flutter 工具 `drive/run --no-enable-impeller` 在 Android 上的注入方式（flutter_tools `android_device.dart` 的 `--ez enable-impeller false`，可 grep 实证）。注意 `flutter build apk --no-enable-impeller` 不存在（exit 64），build 阶段关不掉，只能在启动 intent 上带。G3.4/G5.6 任何需要直启测量的场景都要照做。

## [gatekeeper] 设备端冷启动探针的两个坑：/proc/uptime 被 SELinux 拒读；pumpWidget 之后 await endOfFrame 会挂死
- 现象一：`File('/proc/uptime').readAsStringSync()` 在 App 内抛 `PathAccessException errno=13`，avc denied `{ getattr } for path="/proc/uptime" ... scontext=u:r:untrusted_app`。Android 10+ 的 SELinux 策略不给 untrusted_app 读 proc_uptime，"进程创建→首帧"的完整口径在设备端测不了。
- 现象二：`await tester.pumpWidget(...)` 之后 `await binding.endOfFrame` 永远不完成（测试 5 分钟超时）。endOfFrame 等的是**下一帧**的结束，而 pumpWidget 已经把当前帧 flush 掉了，此后没有新帧被调度。
- 解法：探针退化用 `Stopwatch`（CLOCK_MONOTONIC）量 "Dart main 进点→首帧"，首帧完成点用 `await tester.pump(Duration(milliseconds:100))`（live binding 会真实调度并等一帧）；进程创建→首帧的权威数字仍由 host 侧 `am start -W TotalTime` 提供，探针只用于拆分 Dart 侧占比。G3 实测拆分：真实工作台 main→首帧仅 ~0.5s，am start TotalTime 的大头（~7s）是进程/引擎启动段，与 G1 骨架 App 的 5988ms 基线一致，属模拟器环境固有开销。

## [gatekeeper][2026-09-14] dumpsys 在 Android 14 镜像上没有 mResumedActivity 字段（G3.4 可交互验证误报）

`dumpsys activity activities` 在 API 34 (Android 14, extension level 7) 镜像上已不输出旧字段
`mResumedActivity`（实测全文 0 次出现），新字段名为 `topResumedActivity=` 与
`ResumedActivity:`。G3.4 的"可交互"交叉验证最初用旧字段名匹配，从未命中过，造成两轮
误判 FAIL（第 1 轮误诊为"dumpsys 采样时序"，第 2 轮才取证实锤：全新安装首次启动 2s 内
即 resumed）。匹配请用公共子串 `ResumedActivity`。证据：`out/GATE_dumpsys_raw.txt`、
`out/GATE_c1_f*.png`（gate_G3.dart 内已固化注释）。

## [qa-batch] G4 第 1 轮设备端批量回归的 4 个环境坑（编排脚本已固化解法）
- adb push 到模拟器目录时 **Git Bash MSYS 路径改写**：`adb push x /data/local/tmp/...` 的目标路径会被
  MSYS 改写成 `C:/DevTools/Git/data/local/tmp/...`，push 静默失败（旧配置残留导致 app 按 stale 配置跑）。
  Git Bash 里跑 adb push 带绝对 POSIX 路径必须 `export MSYS2_ARG_CONV_EXCL="*"`，或改用 python subprocess。
- 本 API 34 AVD 上 **untrusted_app 对 /data/local/tmp 只写不进**（SELinux 拒，chmod 777 无用；
  读可以）——与早前 gatekeeper "App 能在里面新建文件"的条目矛盾，疑与镜像/时点有关。
  输出一律改走 App 私有 cache（`/data/user/0/<pkg>/cache/...`），host 侧用
  `adb exec-out run-as <pkg> tar -cf - -C cache qa_out` 二进制流拉回，python tarfile 解包。
- **adb devices 第一个 "device" 不一定是你启动的模拟器**：本轮模拟器启动参数错误秒退后，
  编排脚本抓到开发机新接入的**用户真机**（Xiaomi 2201122C）把回归跑上去了。任何 adb 编排必须
  钉死 `emulator-*` serial 前缀，非 emulator 设备在线时只告警不使用。
- `run-as rm -rf cache/qa_out` 清目录后，设备端测量代码用 `File.writeAsString` 写 marker/jsonl
  **不会自建父目录**（`File.create(recursive:true)` 才会），写失败 → 进程挂着无任何产出。
  清完必须 `run-as <pkg> mkdir -p cache/qa_out` 再启动 app。
- 顺带：AVD 用 `-no-snapshot-load` 冷启动，但 userdata 分区**跨次启动持久**——上次的
  qa_config.json、已装 APK、App cache 都还在，编排每阶段前要显式清态。

## [imaging] 底边「硬约束」在人脸贴底时会把构图整体推垮；推算头顶必须用掩膜复核
- 现象：G4 r1 两类真实构图缺陷。(1) 摄像头横图、人脸贴近图片底边（1280×720，
  下巴离底边 14px）：`solveAutoCrop` 的「底边压回画布」把整个画幅上移，
  成片下巴落在 0.98 倍画高处（贴边即裁），头顶留白从 0.09 膨胀到 0.36。
  (2) 五人合影选边缘人：成片发际齐着眼镜被裁——由成片反推出部署时实际用的
  FaceInfo 是 headTopY≈957、chinY≈2364，而 alpha 里真实发顶在 420。
- 原因：(1) 把「底边不许凭空补肩」当硬约束——脸贴底时画面下方本来就没有肩
  可保，压回画幅的代价是头部几何全毁，怎么选都是输，不如保头身比。
  (2) `FaceInfo.headTopY` 是**人体测量学推算值**（eyeY − 1.89·d，见
  yunet_decoder），头后仰大笑压缩 d、检测框肥大把脖子框进脸时，推算值会掉进
  脸里；`min(推算值, 框顶)` 的兜底救不了推算值本身偏低。
- 解法：(a) `solveAutoCrop` 四条边统一策略——画幅按头身比定死，越界（含底边）
  面积 ≤45% 直接接受、填底色；缩小档改成以头顶点+人脸水平中心为**锚点**等比
  缩小，绝不钳回画布（钳了锚点就丢，头顶留白随钳制量漂移）。
  (b) compose 里用 alpha 剪影**向上量真实发顶**（头部带状扫描，容忍 ~2% 头高
  的稀疏发梢缺口），headTopY 只允许向上修、不允许往下压；水平中心换成上半头
  分带质心，比全宽行中点抗合影干扰。见 `crop_geometry.dart` 的
  `refineHeadFromMask`。(c) **不要试图从宽度剖面修下巴**：MODNet 的 alpha 把
  头颈躯干连成整块，「脸颊宽—脖子窄—肩宽」的收窄信号在真实设备 alpha 上
  不存在（实测四张，剖面里的变窄全在脸颊中部，是眼镜/发型噪声），按它修
  下巴会把好图改坏——下巴错只能等 ml-porting 把检测框修对。
- 复测台：`lib/core/imaging/dev_repro_g4.dart`（qa-batch 拉回的真实设备 alpha +
  复刻检测值 × 真实 compose 路径，带几何断言），成片在 `out/tmp/g4_repro/`。
  配准取证手法：把候选成片的前景色模板（屏蔽底色）对源图做 masked SQDIFF
  多尺度匹配，可从成片反推当时实际用的裁剪框（a14 实测与本地复算差 ≤2px）。
- 顺带：检测值的「脸框肥大」样本（部署版 a4）修后头身比精确达标但人在画面里
  偏小——headTopY 修到真实发顶后 chinY(2364) 还是胸口，这是检测端问题；
  ml-porting 修好选脸/框后自然消失。

## [ml-porting] image 包 4.9.2 与 dart:ui 都会烘焙 EXIF orientation——别再手工 bake，头部解析必须返回摆正后尺寸
- 现象：为 G4.7 降采样方案做解码器语义探针时发现，`img.decodeJpg` 对带
  orientation=6 的 JPEG 返回的已是**旋转后**的像素（64×128 原片解成 128×64），
  且 `exif.imageIfd.orientation` 被**置空**；`dart:ui.instantiateImageCodec`
  行为相同（顺带：同时给 targetWidth/targetHeight 时输出恰好是该尺寸、
  不保宽高比，等比尺寸必须自己算好传进去）。
- 依据源码：image 4.9.2 的 JPEG 解码在 `_jpeg_quantize_io.dart` 的
  `getImageFromJpeg` 里按 orientation 重排像素并 `orientation = null`——
  所以 `decodeToRgb` 里的 `bakeOrientation` 对 JPEG 是死代码（真正兜底的是
  "tag 还在"的其它格式）。风险：**将来 image 包升级若把烘焙挪回显式调用，
  这里的双重烘焙会静默变单次/零次**，orientation≥5 的链路目前数据集零覆盖，
  不会报错只会出横躺图。
- 探针：`native/bench/ui_decode_probe_test.dart`、`image_pkg_exif_probe_test.dart`
  （手工拼 APP1/EXIF 的手法在里面，想造带 orientation 的样张直接抄）。
- 结论落地：`lib/core/matting/image_header.dart` 的头部解析与两个解码器
  对齐——**返回摆正后尺寸**；dart:ui 降采样解码只用于 orientation<5 的图，
  5–8 走 image 包兜底（Windows 探针结论不外推到 Android）。

## [ml-porting] Isolate.run 的闭包会把整条作用域链发过去——engine 别被闭包"沾"上
- 现象：A/B 台里 `Isolate.run(() => runMattingSync(bytes, session))` 报
  `object is unsendable - _Future@... <- _warmUp in Instance of '_Engine'`，
  尽管闭包字面上只引用了 bytes 和 session。
- 原因：Dart 闭包捕获的是**词法作用域链**，外层函数作用域里的 `engine`
  变量（带 `_warmUp` Future 字段）跟着上下文一起序列化，Future 不可发送。
- 解法：跨 isolate 的计算入口放**顶层函数**，参数只传值（bench 的
  `_measureLegacyPeak` 就是为此搬出测试体的）。同坑变体：类方法闭包捕获
  `this` 同样会带上全部字段。

## [qa-batch] 小米真机 adb install 报 INSTALL_FAILED_USER_RESTRICTED，不是授权问题
- 现象：`adb -s 1e01895d install -r xxx.apk` 稳定失败 `Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]`，重试同样。设备 `adb devices` 是 device 状态（调试授权正常）。
- 原因：MIUI/澎湃OS 的"USB 安装"安全开关（开发者选项里独立于 USB 调试），默认要求每次安装在手机屏幕上人工确认；息屏/未确认即自动拒绝。host 侧无任何 adb 手段绕过（这是故意的安全设计，别试）。
- 解法：需要用户在手机上 开发者选项 → 开启"USB 安装"（可能还要求插着 SIM 卡/登录小米账号），或安装弹窗出现时手动点确认。G4 真机优先通道（4.6/4.7/4.8）在此开关打开前无法执行；qa-batch r2 的真机补测因此只完成了前置检查即中止，未在真机上留下任何残留（pm path 确认无包、无 push 文件）。

## [gatekeeper] release runner 编排三连坑：non-debuggable run-as 失效、QA_DIR 烤死、读 r2 残留配置跑错模式
- 现象（2026-09-15，G4 r1 release 口径复测）：(1) `run-as com.muzhao.muzhao` 对 release 包一律
  `package not debuggable`，cache/qa_out 清理与拉取全失效；(2) release runner 的 `QA_DIR` 是
  构建期 dart-define 烤死的（libapp.so strings 实证 = `/data/local/tmp/muzhao_qa_tmp/in`），
  运行期 qa_config.json 推到别处会被静默忽略；(3) 忽略后 runner 读到 qa-batch r2 残留的
  perf 配置，app 跑了 75 分钟"perf"（每秒 Explicit GC 的 logcat 长相像死循环，其实是
  空转 + 引擎 housekeeping），host 还在傻等 done_batch。
- 解法：AVD 非 playstore 镜像 `adb root` 可用（`restarting adbd as root`）——私有目录
  清理/读取全部改走 root shell（mkdir 后记得 chown 回 `u0_a191:u0_a191_cache`，否则
  untrusted_app 写不进）；qa_config.json 必须推到烤死路径，且每阶段前先
  `am force-stop`（app 只在启动时读一次配置）。已在 `tools/gate/g4_release_memcheck.py` 固化。
- 附带：release APK 的 lib/ 三 ABI 齐（arm64-v8a/armeabi-v7a/x86_64），x86_64 模拟器可直接装。

## [qa-batch] 真机 release 包跑设备端测量：run-as 全线失效，输出必须走应用自有外部目录
- 现象：release APK 装上真机后，`run-as <pkg> ...` 一律报 `run-as: package not debuggable`——
  模拟器上跑 debug 包用得好好的 run-as marker 轮询 / tar 拉回通道在 release 包上整个不存在；
  编排脚本每个阶段都空等满 deadline 且拿不到任何结果。
- 解法：输出目录改用**应用自有外部目录** `/storage/emulated/0/Android/data/<pkg>/files/qa_out`：
  App 用 `File/Directory.create(recursive:true)` 免权限可写（**必须由 App 自建目录**，
  shell 建的目录属主是 shell，App 可能写不进）；adb shell 对该路径可读、`adb pull` 可拉。
  代价：`/data/user/0/<pkg>/cache` 那套私有目录方案只在 debug 包上可用。
  已落地在 `test/batch/batch_runner.dart`（启动时 create qa_out）+ `test/batch/run_realdevice.py` v2。
- 附带：MIUI「USB 安装」开关状态不稳（开关存在但安装仍被
  `INSTALL_FAILED_USER_RESTRICTED` 瞬时拒绝，疑似自动重置），adb 侧无法查询/干预；
  备选路径是把 APK 推给用户在文件管理器里侧载，然后 `QA_SKIP_INSTALL=1` 跑测量。

## [ml-porting] "碎片化连通域"杀不掉连贯伪主体 —— 非人像优雅失败的真正分界是人脸，不是 alpha 形状
- 现象（2026-09-15，G4 r1 4.3）：电路板截图（item 60）被 MODNet 抠出"主体"，6 底色候选全是
  碎片拼贴。直觉以为 alpha 是碎的，上连通域门槛就行；但 88 张全量校准（out/frag_calib_raw.jsonl，
  native/bench/frag_gate_calib_test.dart）显示：item 60 的最大连通域前景占比高达 **0.91**（比多数
  真人还"连贯"），地球仪 0.98、风景大块主体 0.97 —— 反而是五人合影只有 **0.497**（人之间自然
  留空隙）。纯 alpha 几何判据两头不讨好：阈值高杀合影，阈值低放过伪主体。
- 解法：门槛必须落在"这是不是人"上，与 detectFace 完全同口径（YuNet + pickSubjectFace +
  kMinFaceAreaRatio=0.03）放进 removeBackground：校准集上 22 张真图（黄金 8 + 人像 14）主脸
  面积 ≥0.066、置信度 ≥0.93；21 张伪成功非人像要么无脸要么主脸 ≤0.019（面积差 3.4 倍），
  一刀切干净。碎片化连通域（膨胀 4 轮 + lg_fg<0.35）保留作兜底，但别指望它当主判据。
- 附带：把检脸挪进 removeBackground 后，controller 的"removeBackground → detectFace"第二次
  调用可用单槽 identical() 缓存直接命中，全流程反而少一次解码 + 一次推理 —— 顺手收了 4.6/4.8 的余量。

## [ml-porting] dumpsys meminfo 的 "Unknown" 类别 = 大块 native 分配的去向，瞬时滞留要看它不是 Native Heap
- 现象（2026-09-15，G4 r1 4.7）：release batch 峰值 487.5MB，floor 340 达标，+135MB 峰值点落在
  638 字节的截图输入上。拆 memdump：Native Heap 稳定在 251-274MB，涨的全在 **Unknown** 类别
  （46→220MB）——匿名 mmap 页。Dart VM 的 external typed data（image 包解码缓冲、>几百 KB 的
  Uint8List 走 scudo secondary = 匿名 mmap）全记在这里，Native Heap 看不出任何异常。
- 判据：峰值 - floor 的差值 ≈ 没被 GC 的垃圾 + 在途缓冲；同一份内存在 leak 曲线上"冲高 ~1s 后
  回落"就是 GC 滞后而非泄漏。压法不是手动 GC（AOT 没有 API），是减单张瞬时缓冲：
  闭包别把整个文件 bytes 捕进 Isolate.run（拆闭包）、rgba 就地强制 A=255 复用别再重建一份、
  同一张图的两次解码合并成一次。

## [ml-porting] flutter build apk --release 换 --target 时 Windows 增量构建保留旧入口点：APK 是旧的 main + 新的代码
- 现象（2026-09-15，G4 r2 期间）：先构建 batch_runner 入口，再 `flutter build apk --release
  --target=native/bench/ml_probe_main.dart`，增量构建 26-54s 完成、安装成功，但跑起来仍是
  batch_runner（logcat 出现 batch_items.jsonl，而 probe 的 PROBE 行一条没有）；且栈帧行号是
  **新代码**的（_mattingCore）。也就是说 kernel/libapp 重编了，唯独入口 main 没换 —— APK
  "半新半旧"，且无任何警告。构建时长正常（20-60s）完全看不出异常。
- 解法：**换 --target 必须先 `flutter clean`**（clean 后 probe 构建 54s、行为正确）。构建完
  先用 `python -c "import zipfile; print(zipfile.ZipFile(apk).read('lib/x86_64/libapp.so').count(b'特征串'))"`
  验证入口点（batch runner 特征 = `batch_items.jsonl`，probe 特征 = `PROBE `），再上设备。
- 附带：多次 full build 期间 `flutter test`（host 测试）与 `flutter build` 并发会抢 file lock，
  串行执行即可，不必清缓存。

## [ml-porting] G4.8 的 after20 回落读数受 Dart idle-GC 时机支配，单次读数可能虚高 3 倍
- 现象（2026-09-15，G4 r2 修复后自测）：同一份代码连续两轮 leak 20 轮复测，Δ 分别为 60.3MB 和
  236.9MB。后者的曲线形态：最后一轮结束时 PSS 冲高到 521MB 后**平台 8s+ 不动**（leak 协议最后
  一轮后 app 只 sleep 不分配，AOT 无手动 GC 入口，major GC 不被触发），采样窗正好落在平台上。
  同一轮 batch 80 项跑完的尾部读数只有 ~340MB（若真泄漏 237MB，batch 尾部不可能正常）。
- 判据：分辨"泄漏"与"GC 时机"看三处——① batch 曲线尾部是否回归 floor；② 平台是否在后续
  分配恢复后立即回落；③ 多次复测的 Δ 方差。建议 4.8 复测读数窗内安排一次微小分配（或对
  Δ>阈值的样本复测一次）再判 FAIL。

## [imaging] image 包 4.9.2 的 encodeJpg 每次调用白付 ~1.5MB 纯垃圾；fromBytes 是逐行拷贝
- 现象（2026-09-15，G4 r2 4.7 压瞬时滞留时剖析）：`img.encodeJpg` 内部
  `JpegEncoder` 是**每次调用新建实例**，构造函数要建 `_bitCode`/`_category`
  两张 65535 槽表（各 0.5MB 指针数组）+ RGB→YUV 表 + 量化/DCT 表；
  `encodeJpg` 又不提供实例复用入口。一次 compose（成品+缩略图两档编码）
  就是 ~2MB 垃圾，一个数据项 42 次合成 × 2 次编码 ≈ 90MB 纯垃圾 ——
  这是 compose 路径单笔最大的重复分配，且全在 >100KB 的 external typed
  data（scudo secondary = 匿名 mmap，dumpsys 记 "Unknown"）。
- 另一处：`img.Image.fromBytes` **逐行拷贝**输入字节进自建 data 缓冲
  （image.dart 的 fromBytes 实现，rowStride == dataStride 满拷，无零拷贝
  选项）——把 RGB 喂给编码器还要再付一份 w×h×3。
- 解法：JpegEncoder 实例**跨 encode 复用是安全的**（encode() 只读码表，
  位缓冲等编码期状态在 encode 开头 `_resetBits` 自复位，输出只由
  quality 与像素决定），按 quality 档缓存实例；编码画布按 (宽,高) 缓存
  一次 fromBytes，之后把成片 RGB `Uint8List.view(canvas.data!.buffer)`
  整块 setRange 进去。已落地在 `compose_engine.dart` 的 `_encodeRgbJpeg`，
  黄金集 190 个输出哈希与逐次新建的基线**逐位一致**
  （`lib/core/imaging/dev_pool_bitcheck.dart`）。
- 附带：`RenderedImage` 若加非 final 字段就不能再有 const 构造函数
  （analyzer 会拦）；渲染输出缓冲的池化键控与防串染依据写在
  `render.dart` 的 `WorkBufferPool` 文档里（所有输出像素在所有分支下
  都被写入循环覆盖，复用不影响数值）。

## [主会话] 宿主机内存是全局约束——起模拟器前必跑预检
- 现象：G2C 期间 AVD 连崩 3 次疑似内存问题；G4 期间 commit 一度 40.5/52.6GB，可用物理内存掉到 2.6GB。
- 原因：模拟器 4GB + Gradle daemon + flutter tool + 多 agent 并发的 dart 进程叠加；用户明确这台电脑装不下更多东西。
- 解法：`python tools/hostmem.py`（判据：可用物理 <4GB 或 commit>80% 即拒绝起模拟器）。
  超限先 `cd android && ./gradlew --stop`、杀残留 dart/qemu。**模拟器同时最多 1 台（用户指令，时间换空间）**。
  各 agent 派发时写明；gatekeeper/qa-batch 的编排脚本已按此执行。

## [imaging] WorkBufferPool 第一版被 G4 r3 实测证伪：池没有生命周期纪律就是泄漏
- 现象（2026-09-15，G4 r3 v4 终裁）：加了「按尺寸键控复用」的缓冲池后，
  4.7 峰值 563.1→638.9MB（恶化 +75.8，阈值 450）、4.8 回落 +36.4→+135.8MB，
  Private Other +100MB，时间线与池提交吻合。bitcheck 逐位一致没问题
  —— **错的是生命周期，不是正确性**。
- 设计假设的两个漏洞：① 只按「用途+尺寸」键控，尺寸没变过的键永不归还
  （规格尺寸恰恰是常量 → 每个键钉死一份）；② 没有「换图失效」，复用范围
  从「图内」悄悄变成了「跨图」，输入尺寸各异的 batch 把滞留放大。
- 解法（A，已落地 `render.dart`）：池加 32MB 总字节硬预算 + LRU 淘汰
  （LinkedHashMap 插入序即最近归还序，acquire 即移出池、使用中不算驻留）
  + **换图即 clear 全池**（compose_engine `_cleanForegroundOf` 缓存未命中
  即新图边界，同时清 `_encodeCanvas`/`_mipCache`）——图内复用收益保住，
  跨图滞留归零。JpegEncoder 实例缓存保留（键控 quality，只读码表，与图无关）。
- 审计工装：`lib/core/imaging/dev_pool_audit.dart`（20 张尺寸各异合成图
  连续 compose，逐图读 `poolResidencyBytes`，断言 ≤ 预算、不随图数增长）；
  逐位一致性复验：`dev_pool_bitcheck.dart` 改动前后哈希 diff。
- 元教训：**「复用」必须与「失效」成对设计**。只写 acquire/release 不写
  失效时机的池，稳态驻留就是它见过的所有键的总和；凡是"按尺寸键控"的池，
  先问一句"尺寸会不会永不变化"。

## [ml-porting] ORT 1.15.1 上 XNNPACK 与「共享 arena / 关 arena」组合必崩：floor 压缩的 arena 杠杆在设备上不可用
- 现象（2026-09-15，G4 r5 4.7）：release 包首次推理即 SIGSEGV（SEGV_ACCERR，写在页尾越界 8 字节，
  全部落在 libonnxruntime.so 同一地址），且与 EP 尝试顺序无关地复现。
- 原因：C API 没有 `SessionOptionsSetArenaCfg`，给 CPU arena 配 kSameAsRequested 的唯一官方路径是
  `CreateAndRegisterAllocator(env, mem_info, cfg)` + 会话 config entry `session.use_env_allocators=1`。
  实测矩阵（native/bench/ml_probe2_main.dart，逐变体单进程）：注册+选入+XNNPACK=崩；
  注册不选入+XNNPACK=稳；选入+纯CPU=稳但瞬态峰值反而更高（4032 图 +75MB vs XNNPACK +23MB）；
  DisableCpuMemArena+XNNPACK=也崩。即 XNNPACK EP 在这版 ORT 上只吃默认 arena 配置。
- 解法：生产保持默认配置（FFI 建会话层保留、arena 政策默认关闭、留 bench 开关）；Windows host 的
  CPU-EP 探针显示 kSameAsRequested 确实省（固定负载 +303MB→+151MB、输出逐位一致）， arm64 真机
  无法在本机验证，按有坑处理。另注意 `CreateArenaCfg` 出来的 cfg 别提前 Release（所有权语义不明，
  留活到进程结束）；bench 的全局开关是 per-isolate 副本，必须随 Isolate.spawn 显式带进工厂
  isolate（debugBenchFlags），否则 A/B 台所有变体都在静默跑同一份生产配置——第一轮矩阵的
  "全部崩溃"就是这么来的，差点误诊成预存 bug。
- 教训：给 ORT 换任何 allocator 配置，先建"逐变体单进程"矩阵台，别在生产配置上直接 A/B。

## [ml-porting] r4 的 "+65.6MB 全分辨率解码" 归因不成立：引擎解码瞬态实测只有 ~22MB，别照单全收
- 现象（2026-09-15，G4 r5 设备实测，release/模拟器）：removeBackground 全链路对 4032×3024
  输入的进程 RSS 峰值增量 +22~26MB（4032 JPEG、4958×7017 扫描件 +39~41MB）；
  image 包全解码兜底路径（decodeToRgb maxEdge）也只 +21.3MB——都不是 4032×3024 RGBA 的 48.8MB。
- 原因：r4 memdump 里 Private Other +65.6MB 被归因为"全分辨率解码"，但引擎侧每段峰值都对不上；
  疑似来自 compose 段（成片/候选工作集，imaging 的 WorkBufferPool 相关）或多缓冲叠加，
  归属不在 matting 解码路径。
- 解法/证据：探针 native/bench/ml_probe2_main.dart（PROBE2 日志，20ms RSS 采样、峰值取 3 轮最小）。
  后续谁再压 4.7 瞬态，先跑它分段归因，别重复"48.8MB 解码"这个站不住的假设。
- 顺带钉死两个事实：dart:ui 在 Android 上确实烘焙 EXIF（orientation=6 样张解出摆正像素，P1）；
  dart:ui 解码在后台 isolate（Isolate.run）恒失败（P2）——解码必须留宿主 isolate。

## [imaging] 去色边行带流式化：av==0 分支只写 alpha 不写 RGB，行带缓冲复用后残留泄进 box 平均
- 现象（2026-09-15，G4 r5 compose 段瞬态改造）：把 decontaminate 拆成
  decontaminateRows（行带版）后，黄金集 bitcheck 首跑 g03/g06 的部分规格
  哈希变了。分层定位（行带 vs 整图去色边 = 0 差；区域 vs 整幅 mip = 仅
  premul 平均值差、alphaMax 全同）后锁定：decontaminate 的 `av == 0`
  分支历来只写 `out[a] = 0`，RGB 不写 —— 整图版整缓冲 fresh（恰为全 0）
  掩盖了这个隐含约定；行带版缓冲跨单元格行**复用**，上一行的 RGB 残留
  被当成「零 alpha 像素的颜色」算进 box 平均。
- 修复：av==0 分支四通道全写 0。**教训：凡是「跳过写入」的分支，在整图
  一次性缓冲里无害，改成复用缓冲后就是串染**；复用缓冲的写入方必须
  全通道全像素覆盖（与 WorkBufferPool 防串染同一纪律）。
- 顺带：f==1 时 boxDownsample 的 alphaMax 是 w×h 字节（12MP 即 12.2MB），
  且 mip.premul 与 clean.premul 是**同一块内存的别名** —— r4 的 memdump
  归因清单里这一块是隐形的，compose 段 +65.6MB 用「48.8 premul + 12.2
  amax + 画布/池」刚好对上，别再漏算别名。

## [imaging] compose 段瞬态终改：全图 premul 与整幅 mip 全部消灭，黄金集 190 哈希逐位一致
- 改造（2026-09-15，G4 r5，4.7 真机贴线）：① 去色边改行带流式
  （estimateCleanFields 全图扫两遍出 ~1.4MB 低分辨率字段 → decontaminateRows
  按 f+2 行现算现喂）；② 预滤波从「整幅」改「区域」——MipLevel 加
  cellX0/cellY0，只存裁剪框源图 AABB ±2/+3 格的子矩形，同倍数多规格按
  union 重建（单元格值只取决于源窗口，与区域划分无关，这是逐位一致的依据）。
  改造前整项存续：12MP = 48.8 premul + 12.2 amax；35MP 扫描件 = 139.2
  premul + 43.5(f2) + 19.3(f3)。改造后整项存续仅字段 1.4MB + 区域 mip
  ≤2.7MB/份 + 池 5.7 + 画布 5.7；dev_compose_memprofile 记账峰值
  12MP 60.2→14.3MB、35MP 213.4→15.3MB。
- 工装：`lib/core/imaging/mem_ledger.dart`（大缓冲记账，enabled 默认关）、
  `dev_compose_memprofile.dart`（host 剖面：ledger 精确字节 + ProcessInfo RSS
  对照）。回归：dev_pool_bitcheck 190 哈希与改造前逐位一致、dev_selfcheck
  2B 九项 9/9、dev_pool_audit 20 图驻留不增长。
- 不可流式项：推挽字段（需要全图 alpha 分布做种子与补洞，但产物只有
  ~1.4MB）；JPEG 编码器码表/画布缓存（<4MB，已缓存复用）。编码画布 13 份
  5.7MB 是剩余最大的整项块，若真机仍贴线可按「缩略图画布用完即弃」再压 1.4MB。

## [qa-batch] vivo X21A 真机测量三连坑：am start -W 间歇挂死 / dumpsys 采样空 / 设备时钟漂移
- 现象一：`am start -W ...` 间歇性 120-180s 无返回（同设备此前可秒起），force-stop + 唤醒重试仍超时；多会话复现。锁屏与否无关（已验证亮屏解锁同样挂）。疑似 Funtouch 自启动管控/活动空闲回调丢失。规避：am start 超时后改用 `am start`（不带 -W）+ 轮询 `pidof` 代偿"等启动完成"，或干脆弃机。
- 现象二：`dumpsys meminfo <pkg>` 在 vivo 上对运行中进程也可能返回慢/被上一条 adb 串行阻塞，host 侧 1s 间隔采样若单次调用抛 TimeoutExpired 会整线程静默死亡——采样循环必须逐次 try/except（已在 run_realdevice.py 修复），且必须验证 samples 非空再用于判定。
- 现象三：vivo 系统时钟会被 NTP 拉动（观测到在 2026-09-15 与 2025-08-24 之间跳变）。所有"设备 epoch（logcat -v epoch / app DateTime）↔ 宿主 epoch（python time.time()）"的时间窗匹配（如 leak 基线/回落窗口）都会因此全空。必须每阶段计算 device-host 偏移量换算，或干脆用"阶段内相对时间窗"代替绝对 marker 时间。
- 结论：vivo X21A（Android 9/Funtouch）做长时间无人值守内存测量的可靠性显著低于 MIUI 小米机（后者只卡安装确认，测量本身稳定）。r5 真机终裁因此未产出，模拟器口径兜底。

## [imaging] 内存优化的「记账口径」不能当验收口径——记账降了、进程 PSS 反升（c669d36 回退实录）
- 现象（2026-09-15，G4 r5 终测）：compose 流式化 c669d36 把"单时刻最大未释放大分配"
  从 60.2→14.3MB（12MP 记账口径），申报 4.7 收官；但设备实测 4.7 峰值 570.4→663.5MB、
  4.8 回落 +42.3→+87.9MB，**双破线且双双恶化**——优化在申报口径上是赢、在验收口径上是输。
- 根因：把"单点大缓冲"拆成"更多小缓冲"后，记账只看单笔分配，看不到
  ① scudo/分配器碎片化（小块更碎、驻留更久）② 多个行带缓冲并发存活叠加
  ③ leak 路径上多滞留一份。Private Other 与 Native Heap 两类目同时抬升即为证据。
- 教训：**4.7/4.8 的唯一验收口径是进程 PSS（dumpsys），记账（mem_ledger）只配当
  定位工装（归因"这笔分配是谁"），绝不配当"达标证明"**。任何"拆大缓冲"类优化
  在上设备前，先用 dev_pool_audit/dev_compose_memprofile 打 RSS 对照，别只报记账峰值。
- 处置：c669d36 已整体回退到 1dcd35c 行为（r4 为当前最优已验证态），工装文件
  mem_ledger.dart / dev_compose_memprofile.dart 保留；bitcheck 190 哈希与 1dcd35c
  基线逐位一致，2B 9/9。复测口径 = qa-batch QA_ROUND 重跑。
- 补记（/simplify，2026-09-16）：`mem_ledger.dart` 已随 simplify 删除
  （c669d36 回退后零挂点、账本恒 0，头注已成谎言）；重挂记账需按当时
  的分配点重新实现 hook，dev_compose_memprofile 现仅剩 ProcessInfo RSS 对照。

## [imaging] memprofile 的「decontaminate premul 12MP 48.8MB」是工装假象，不是管线路径——compose 全部大缓冲本来就随 matting 分辨率缩放
- 现象（2026-09-15，G4 最后一轮）：归因"compose 段 12MP 缓冲从哪来"时发现，
  `dev_compose_memprofile.dart` 旧版直接构造 4032×3024 的合成 MattingResult
  喂 compose，账面上的 48.8MB premul + 12.2MB alphaMax 量的是「假如引擎
  不降采样」的假想工况。真实管线（kEngineMaxEdge=2048 已在 ml-porting 落地）
  中该工况不存在：compose 入参只有 MattingResult，从不接触原图字节，
  premul/mip alphaMax/背景估计/池/画布全部按 matting.width×height 缩放。
- 教训：改数据流上游（降采样）之后，下游的内存剖面工装要同步换口径，
  否则会拿旧工况的数字去指导新架构的优化（r5 的流式化改造正是在旧口径
  数字驱动下做的，后因进程 PSS 净回归被回退）。工作分辨率落地后，
  整图 premul 2048×1536×4=12.6MB、amax ≤3.1MB、字段 ~1.4MB，
  r4 的"整项存续大缓冲"结构在 ≤2048 输入下已是 ~17MB 级，
  **无需任何流式化复杂度**。
- 附：mem_ledger 的 alloc/free hook 挂在 c669d36 里随回退一起消失，
  b2fab99 起账本恒为 0 属预期；RSS 对照（ProcessInfo）不受影响。

## [gatekeeper G4 r2] adb push "1 file pushed" 是噪声行 + /data/local/tmp 下的 root 属主遗留目录会静默杀死所有 push
- 现象（2026-09-15，G4 r2 设备阶段）：`adb push` 到 `/data/local/tmp/muzhao_gate_tmp/g4_spot/`
  间歇性失败，报 `remote couldn't create file: Permission denied`，**但同一输出里还会打印
  `1 file pushed, 0 skipped`** —— 这行是噪声，文件实际没上去；以退出码或输出判断都会误判成功。
  且失败与成功在同一次 run 内交错，极像随机 flake。
- 真因：早前某轮以 root adbd（`adb root`）操作过模拟器，留下 root 属主的 `g4_spot/` 目录
  （`drwxrwxr-x root root`）。shell 用户的 push 既不能创建文件、`chmod 777` 也报
  `Operation not permitted`（连目录属主都不是）。时钟对不上不要紧，`ls -ld` 一眼定位。
- 解法（已固化在 `tools/gate/device_harness_common.dart` prepareDeviceGateDir）：
  对 push 实际落盘的**叶子目录**做写探针（mkdir x/touch/rm），探针失败才 `adb root` 深清理重建
  （仅限 emulator-*，真机不能 adb root）；push 判定改为设备端 `stat -c %s` 与本地字节数一致
  才算成功，不信退出码。
- 教训：adb push 的 "N file pushed" 永远不要当真；模拟器上凡是动过 `adb root`，/data/local/tmp
  下的属主状态就会污染后续所有 shell 会话。另：本日 qemu 崩溃 6 次均集中在 flutter drive 阶段，
  预先 `flutter build apk --debug/--profile` 把 gradle 峰值挪到模拟器启动前，可缩小崩溃暴露窗。

## [ml-porting] 模拟器 RSS 瞬态（峰值-基线）读数噪声地板 ±15-25MB：GC 滞后支配，单步级 A/B 别用它下结论
- 现象（2026-09-16，G4 r3 4.7 A/B 台 ml_probe3）：同一台模拟器、同一探针，**逐位同代码**的
  两次运行（旧引擎构建里 P1 复刻 = 旧 P2 的同一 workload），mf.png 单步峰值一次测得 +58.1MB、
  一次 +43.2MB；新路径全回合（P3）与单步（P2）甚至出现 P3 < P2 的倒挂。都是 20ms RSS 采样
  + 3 轮取最小。
- 原因：external typed data（scudo secondary = 匿名 mmap）的释放由 Dart idle-GC 时机决定，
  "峰值-窗口基线"把 GC 滞后垃圾全部计进峰值；基线本身又受上一阶段残留垃圾影响（P3 紧跟
  P2，基线偏高 → 峰值-基线反而偏小）。采样步长不同（20ms vs 50ms）也直接改变可比性。
- 解法：可下结论的口径只有三种——① **结构性 live-set 清单**（逐缓冲算术：worker 收 8MB vs
  34.6MB 这种，恒真）；② **同协议 churn 每回合墙钟时间**（新旧引擎 mf.png ~2.6s → ~1.9s，
  稳定复现）；③ 真机 VmHWM（qa-batch 通道，4.7 的唯一验收口径）。凡要做瞬态 A/B，先跑
  一次"同代码重复测"定噪声地板，差值小于地板的结论一律不作数。
- 附带：debug APK 没有 libapp.so（JIT 走 assets/flutter_assets/kernel_blob.bin），换
  --target 后的入口点验证对 debug 包要查 kernel_blob.bin 里的特征串，对 release 包查
  lib/x86_64/libapp.so。

## [qa-batch] G4.8 锚定 Δ 指标的基线伪影：leak_begin±8s 窗口会踩到预热期，轮间波动 ±60MB
- 现象：同一相邻代码（r7 vs r8）锚定 Δ 从 -7.4MB 跳到 +91.8MB，像"回归"；逐采样曲线却显示 20 轮内无单调漂移（430-519MB 振荡）。
- 原因：baseline 取 leak_begin marker ±8s 窗口中位，而 App 在该窗口内仍在 warmUp（首样可低至 140MB，warmup 后即到 390-460）——锚点踩在预热期就比稳态低 30-60MB，Δ 全盘虚高。r3 的 +135.8/-9.1 斜率是真回归，r8 的 +91.8/+2.4 斜率是伪影。
- 解法：4.8 判读改双指标——(1) 稳态段（leak_begin+15s 后）线性回归斜率（MB/20轮，r4-r8 全部 ±7 内 = 无泄漏）；(2) 峰值完整回落检查（曲线内峰值 vs 末值）。绝对 Δ 只作参考。已在 r8 报告给出全轮斜率表。

## [store-assets] assets/fonts 子集字体缺字但 PIL getbbox 检测不出来
- 现象：宣传图用 `NotoSerifSC-Subset-Bold.ttf` 渲染"免费/证件"等字，画出来是空白。
  用 `f.getbbox(c)` 检查覆盖时返回 `(0,44,38,44)` 这种零高度框（truthy），误判为有字。
- 原因：子集字体只含 App 内出现过的字符；PIL 对 cmap 里有映射但无轮廓的字形返回退化 bbox，
  非空元组导致 `if not f.getbbox(c)` 通过。
- 解法：缺字检测用 `f.getmask(c).getbbox()` 并要求宽高都 >0；宣传图渲染时对缺字回退到
  系统全量字体 `C:\Windows\Fonts\NotoSerifSC-VF.ttf`（`set_variation_by_name("Bold")` 取粗体），
  只用于营销 PNG，不进 App 包。见 `store/gen_promo.py` 的 `font_zh()`。

## [release] ABI 过滤写在 buildTypes.release.ndk 无效：Flutter 插件预填的 defaultConfig 三 ABI 是并集基底
- 现象：release buildType 里写 `ndk.abiFilters = {arm64-v8a, armeabi-v7a}`，出的 APK 仍带 x86_64 的
  libonnxruntime.so（16.5MB 白付）；后来在 defaultConfig 里只 `addAll` 两个 arm ABI，同样无效。
- 原因：两条叠加。① AGP 把 defaultConfig 与 buildType 的 abiFilters 做**并集**，buildType 写
  arm-only 挡不住 defaultConfig 里的 x86_64；② Flutter Gradle 插件在 apply 期（早于 app 的
  android{} 块）把 defaultConfig.abiFilters **clear 后填入全部三 ABI**，所以自己的 defaultConfig
  里直接 addAll 是往三元素集合里加两个，等于没过滤。
- 解法：defaultConfig.ndk.abiFilters **先 clear() 再 addAll**（本脚本 android{} 块执行晚于插件
  apply，赋值生效）。要给某个 buildType 单独放宽（如 debug 补 x86_64 供模拟器），只能做"加法"，
  不能做"减法"。AGP 9.1 的 variant API 已无 `variant.ndk`（onVariants 里 Unresolved reference），
  别往那条路走。
- 附带：Flutter 3.47 的 `flutter drive --release` 明确报"does not support running in release mode"，
  `flutter test` 也**没有** --release 选项了。release 模式设备端验证只能：构建真 release APK
  （x86_64 验证版经环境变量把 x86_64 加回 abiFilters）→ adb install → am start；引擎链路
  用 batch_runner 入口的 release 包跑；UI 全流程（选照片→抠图→候选→保存）用 adb input 驱动
  系统照片选择器完成（照片先 push 到 /sdcard/Pictures + MEDIA_SCANNER_SCAN_FILE 广播），
  保存结果用 MediaStore content query 验证。

## [release] 增量构建下 aapt badging 的 uses-permission 会读到旧 merged manifest；manifest 改动要 flutter clean 后重出包
- 现象：manifest 加了 `tools:node="remove"` 删 READ_EXTERNAL_STORAGE 后，packaged_manifests 下的
  文本 manifest 已正确，但 `aapt dump badging` 仍报 READ_EXTERNAL_STORAGE，白查 20 分钟。
- 原因：Windows 增量构建在 manifest/DSL 变更后复用旧中间产物（与早前"增量 assembleDebug 产出
  损坏 APK"同族），badging 读的是旧二进制。
- 解法：以 `aapt dump xmltree <apk> AndroidManifest.xml` 看实际二进制为准（它显示的才是包内真相）；
  出**正式产物**前一律 flutter clean 全量重建。别信 badging 的权限行当唯一证据。

## [release] --dart-define 的设备路径会被 Git Bash MSYS 改写烤进 libapp.so；模拟器随机段错误（exit 139、无 minidump）
- 现象一：`--dart-define=QA_DIR=/data/local/tmp/...` 构建出的 release 包读
  `C:/DevTools/Git/data/local/tmp/...`——MSYS 改写不只在 adb push，对 flutter build 的参数同样生效。
- 解法一：构建命令前 `export MSYS2_ARG_CONV_EXCL="*"`（与 qa-batch 的 adb push 条目同源）；
  出包后 `python` 读 libapp.so 验证特征串（本例 QA_DIR 原文）再上设备。
- 现象二：`-no-window -gpu guest -feature -Vulkan -no-snapshot-load` 启动的 qemu 仍会启动后
  数分钟内 SIGSEGV（exit 139，crash DB 无新 minidump），重试即可恢复；**flutter tool 命令
  （drive/test）在线期间极易伴随 qemu 死亡**（G4 已有先案，本轮再现）。build 全部放模拟器
  启动前做，模拟器在线期间只用裸 adb，能显著缩短暴露窗。

## [store-assets] Windows 无头 Chrome 的两个坑：截图默认写入被拒；窗口宽度下限约 470px，375px 移动端布局无法直接量
- 坑一：`chrome --headless --screenshot=相对路径.png` 报"拒绝访问 (0x5)"，换绝对路径写到
  `%TEMP%` 即可（沙箱对项目目录的写入被拦）。
- 坑二：`--window-size=375,...` 实际渲染视口被钳到约 470（`documentElement.clientWidth` 实测 470），
  想验证真 375px 移动端布局，直接截出来的图会出现"右侧被裁"的假象。
- 解法：做一个外壳页内嵌 `<iframe style="width:375px">` 加载目标页，对 500px 窗口截图/量尺寸，
  iframe 内布局才是真实 375px；溢出检测可用临时脚本把 `scrollWidth` 与越界元素清单写进 DOM 再
  `--dump-dom` 读取（记得测完删掉临时代码）。

## [ml-porting] onnxruntime 插件 1.4.1 其实**自带** Windows 桌面支持——"插件不支持 Windows"是过时结论
- 现象：W2 评估按"插件无 Windows"的假设起步，准备手动下载/分发 onnxruntime.dll。
- 原因：v1.3.0 起 pub 包 `onnxruntime` 就声明了 `windows: ffiPlugin: true`，
  包内 `windows/` 有 CMakeLists（把 onnxruntime.dll 列进 `onnxruntime_bundled_libraries`），
  pub cache 里就带着 dll（FileCapture VersionInfo = 1.15.2023...，与 ffigen 绑定同源）。
  之前"不支持"的印象来自早年在 Windows host 跑 flutter test 时 dll 找不到——那只是
  **flutter_tester.exe 旁没有打包步骤**，不是插件不支持。
- 解法：① 桌面 App 形态：`flutter build windows` 自动把 dll 拷到 muzhao.exe 旁，
  什么都不用做（release 无需任何额外打包动作）。② flutter test / bench 形态：
  `lib/core/matting/ort_runtime.dart` 新增 `ensureOrtRuntimeLoaded()`（warmUp 前调用，
  按 MUZHAO_ORT_DLL 环境变量 → pub cache → exe 目录的顺序预载 dll，LoadLibrary
  之后按名字 open 命中同一模块）。数值验证：黄金集 g01 与 Android 模拟器（同 CPU EP）
  alpha 逐字节比对 99.87% 全同、max delta=1 LSB、IoU@128=1.000000；FaceInfo 六位小数同值。
- 附带：Windows 官方 dll（桌面 CPU 包）**不含 XNNPACK EP**，createSession 的
  xnnpack 尝试会失败并按设计降级到 cpu——探针实测 provider=cpu，属预期行为不是 bug。

## [ml-porting] Windows 桌面首次构建三连坑：启动锁静默等待 / Developer Mode symlink / 引擎 artifacts 重复下载
- 现象一：`flutter build windows --debug` 20+ 分钟零输出（输出文件 0 字节、CPU 0.03s），
  看似卡死。真因：另一个并行 agent 的 `flutter drive` 长时间持有 Flutter 工具启动锁，
  我的 build 在锁上排队且不打印任何东西。多 agent 并行期做任何 flutter 命令前先
  `Get-CimInstance Win32_Process -Filter "Name='dart.exe'"` 看有没有别的 flutter_tools 在跑。
- 现象二：构建在插件注入阶段报 "Building with plugins requires symlink support"
  （ERROR_PRIVILEGE_NOT_HELD）。非 admin 终端无法开 Developer Mode，注册表写 HKLM 被拒。
- 解法（无 admin 的 workaround）：手动为每个 Windows 插件建 **目录联接**（junction，
  `cmd /c mklink /J`，不需要任何特权）到 `windows/flutter/ephemeral/.plugin_symlinks/<name>`。
  flutter_tools 的 `_createPlatformPluginSymlinks` 只在 link 缺失时才创建（force=true 仅在
  插件清单变化后触发），junction 会被当作已存在直接跳过。注意 **`flutter clean` 会删掉
  ephemeral，之后必须重建这些 junction**，否则构建又失败。
- 现象三：symlink 失败前的那次构建仍会先下载全部 4 份 Windows 引擎 artifacts
  （debug/profile/release + wrapper，约 1GB、本机实测 10-25 分钟/份），失败后下次还会重下。
  成功率低的构建尝试可能反复支付这个下载成本；junction 修好后增量构建仅 65s。

## 2026-09-16 ui-woodcraft（W1 关于页）

- 现象：`flutter drive`（integration_test 截图流水线）连续 4 次在
  `convertFlutterSurfaceToImage()` 处抛 `MissingPluginException`，此前同一命令成功过。
- 根因：`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`
  被一次 **release 构建**重写成了"不含 dev_dependencies 插件"的版本（`integration_test`
  是 dev 依赖，release registrant 不含 `IntegrationTestPlugin`），mtime 与并行 agent
  的构建时间吻合。之后的 debug 增量构建认为该文件"最新"不再重新生成，装出来的 APK
  永远缺这个平台通道。两个 agent 在**同一个项目里并行跑 gradle**（一个 debug 一个
  release）就会互相重写这个文件。
- 解法：删掉 `GeneratedPluginRegistrant.java` + `flutter pub get`（debug 形态下重新
  生成，含 IntegrationTestPlugin），再 `flutter drive` 即恢复。并行构建期间注意
  重新检查这个文件；症状与"模拟器抽风"极像，别往模拟器方向查。
- 代价：~4 轮 drive × 5 分钟才定位。若门禁截图批量挂在这种 MissingPlugin 上，
  先看 registrant 里有没有 `IntegrationTestPlugin`，再看模拟器。

## [验证员/W2] `flutter test --release` 不存在——Windows AOT 引擎验证用 `flutter build windows --release --target=<探针main>` 替代

- 现象：需要验证"release AOT 编译模式下黄金集是否仍逐位一致"，但 Flutter 3.47 的
  `flutter test` 没有 `--release` 选项（flutter_tools `commands/test.dart` 全文 0 处
  release，与早前 release 条目"flutter test 也没有 --release 选项了"一致）。
- 解法：`flutter clean` → `flutter build windows --release
  --target=native/bench/win_cmp_android_main.dart`（该入口本来就是为 --target 设计的，
  从仓库根跑 exe 时默认读 `test/golden/src`，产物落 getApplicationSupportDirectory 的
  `win_cmp/`，含 `win_cmp_done` marker，跑完 exit(0)）。宿主侧验证三件套：
  ① `data/app.so` 含 1 处 `WINCMP` 特征串（确认入口真换了，防"半新半旧"）；
  ② stdout 经 `Start-Process -RedirectStandardOutput` 可正常捕获（GUI 子系统 exe
  只要给了句柄，print 就落盘）；③ 拿 JIT（flutter test 探针）与 AOT 两边的
  alpha sha256 逐位比对。实测 8/8 逐位一致、g01 原始 alpha 逐字节一致。
  附带：换 --target 前后都要 clean 重建产品包，最后用特征串复核默认入口已还原
  （app.so 不含 WINCMP）。
- 另两个小坑：① `flutter clean` 连 `.flutter-plugins-dependencies` 一起删——
  **junction 重建必须排在 `flutter pub get` 之后**，否则清单文件不存在无从枚举插件；
  ② `Start-Process -Wait -PassThru | ... ExitCode` 对 GUI 进程有竞态
  （"Process must exit before requested information can be determined"），
  要退出码就改用 `$LASTEXITCODE` 或轮询进程消失 + 落盘 marker。

## 2026-09-16 ui-woodcraft（阶段 6 收尾：官方样张换木木）

- `store/draw_demo_pair.py` 的 `draw_character()` 脖子几何有 bug：脖子椭圆画在
  `HEAD_CY+s(680)`，而下巴在 `HEAD_CY+s(345)`、肩线在 `HEAD_CY+s(720)`——脖子上缘与下巴之间
  露出约 200px 背景缝隙（demo_before.png 里肉眼可见"脖子悬空"）。`store/gen_avatar.py` 因
  用绝对坐标 `H-500` 没踩中。store-assets 复用部件函数画宣传图时注意：脖子椭圆应满足
  `上缘 < 下巴 y` 且 `下缘 > 肩线 y`（木木样张用的参数：cy=HEAD_CY+s(430), ry=s(120), 肩线 BY=HEAD_CY+s(520)）。
- `flutter drive` 跑完会打印 `adb uninstall ... DELETE_FAILED_INTERNAL_ERROR`，是 flutter 工具
  卸载残留包的已知噪音，截图已正常落盘，不要当成流水线失败重跑。
- 杀掉模拟器后 serial 会被下一台复用（5554 → 5554），"等 emulator-5556 上线"的轮询会白等；
  等 boot 用实际出现的 serial 轮询 `sys.boot_completed` 即可。
