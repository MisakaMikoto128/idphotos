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
- Edge 新版默认禁止对默认 User Data 目录开 CDP（报错 "DevTools remote debugging requires a
  non-default data directory"），launch_persistent_context 复用登录态必须先把 profile 复制到
  非默认路径；且 robocopy 复制 Default 后 Cookies 库可能不完整（31 条 doubao cookie 只带出 11
  条，sessionid 丢失），需单独再 Copy-Item 一次 Cookies 文件才拿得到登录态。
- 用 Playwright 自动化豆包出图时：生成图的 DOM 特征是 img[src*="/rc_gen_image/"] 且 alt="image"，
  其余 img 全是 UI 图标（用 naturalWidth 过滤会误抓聊天气泡图标）；CDN URL 的 ~tplv 后缀含签名，
  剥掉去拿"原图"会 403，必须按页面渲染的完整 URL 原样下载；豆包出一次通常给 4 张候选，无需补发。
- Python 脚本里 `sys.stdout = TextIOWrapper(sys.stdout.buffer)` 重定向中文输出，若另一脚本 import 它
  会二次包装，旧 wrapper 被 GC 时连带关闭底层 buffer，报 "I/O operation on closed file"；
  应该用 `sys.stdout.reconfigure(encoding="utf-8")`。

## [windows专员] WM_SIZING 比例锁定的验证三坑：SetWindowPos 不触发、DPI 虚拟化坐标、工作区 clamp 被误判成 bug
- 现象（2026-09-16）：验证 WM_SIZING 比例锁定时，(1) 用 SetWindowPos 设 1200x900 再读回，
  比例没锁，差点误判处理器失效；(2) 脚本读到的窗口尺寸和 App 内部日志差 1.25 倍，对不上账；
  (3) 拖宽到 1085px 时读回比例 0.909，像是处理器没生效。
- 原因与解法：
  (1) **WM_SIZING 只在用户交互拖拽时发送**，`SetWindowPos`/`MoveWindow` 等编程式改尺寸
  根本不走它（走 WM_SIZE）。自动化验证必须用 `SetCursorPos` + `mouse_event` 模拟真实
  拖拽（抓边框角、分步移动、抬起），否则测的不是同一条代码路径。
  (2) 验证脚本进程是 DPI-unaware，它的 `SetWindowPos`/`GetWindowRect` 坐标被系统按
  比例因子（本机 1.25）虚拟化缩放，而 per-monitor aware 的 App 用物理像素——两侧数字
  差 1.25 倍。**比例（w/h）是无量纲的，不受虚拟化影响**，验证脚本一律只比 ratio，别比
  绝对像素；如需绝对值，脚本要声明 PerMonitorV2 awareness。
  (3) 拖宽超出的"比例失真"其实是 WM_SIZING 里**工作区 clamp 在正确工作**：宽度超出
  "工作区高 × 1080/2220"后推算高度封顶（本机 2048x1280 屏最多约 600 逻辑 px 宽）。
  判定脚本要保证拖拽幅度留在 clamp 阈值内，否则把设计行为当 FAIL。
- 附带：C4996 把 `fopen` 当 error（/W3 + WX），临时日志用 `fopen_s`；验证完的临时代码
  必须删干净再出 release 包（本次日志宏在 release 前删除，release 无残留）。

## [ui-woodcraft] 真机在线时 `dart run tools/gate/capture_shots.dart` 会把截图跑在用户手机上
- 现象（2026-09-16，阶段 6 收尾重拍样张）：用户 vivo X21A（5bc6e093）插着 USB，
  `capture_shots.dart` 的 `waitForAdbDeviceOnline` 只认"第一台 `device` 状态的 adb 设备"，
  不区分模拟器/真机——直接命中真机，违反"真机不要碰"铁律。
- 解法：实现类 agent 手动重拍时不要用该 runner，自启 AVD
  （`emulator -avd <id> -no-snapshot-save -no-boot-anim -no-window -gpu guest -feature -Vulkan`）
  并显式 `flutter drive ... -d emulator-5554`；`_rects.json` 需自行合并两次
  `build/integration_response_data.json`（main 跑完先另存，small 跑完合并）。
- 附带：后台方式启动 emulator 时，包一层 `&& emulator ... > log 2>&1` 的 bash 后台任务
  会在 emulator 被杀后报 exit 127，属正常收尾，不是启动失败；判断依据看 `adb devices`
  是否出现 `emulator-*`，别看 wrapper 退出码。

## 横向 ListView 在 Windows 鼠标滚轮下不动（ui-woodcraft，2026-09-16）

- 现象：区域 B 横向候选列表，Windows 实测鼠标滚轮滚不动，只有触摸板双指可用。
- 根因：`Scrollable` 对 `Axis.horizontal` 列表只取 `PointerScrollEvent.scrollDelta.dx`；
  Windows 桌面鼠标滚轮只报 `dy`（按住 Shift 才被翻转为轴），dy 事件被整个丢弃。
- 修法：列表外层包 `Listener`，`onPointerSignal` 里经 `GestureBinding.pointerSignalResolver.register`
  把 `dy` 交给 `ScrollPosition.pointerScroll`（与原生同路径，自带物理与边界钳制）。
  因 dx==0 时原生 Scrollable 不会注册同一事件，无 resolver 抢占冲突；Shift+滚轮行为不受影响。
- 复用件：`lib/ui/widgets/mouse_wheel_scroller.dart`（MouseWheelScroller）；
  widget 自测在 `lib/ui/dev/mouse_wheel_scroller_selftest.dart`（4 例全过）。
- 注意：不要直接 `jumpTo(pixels + dy)`——绕过物理，与拖拽手势/Bouncing 回弹互相打断。

## Enigma Virtual Box 打包 Windows 单文件版的三个坑（packaging，2026-09-17）

- 坑 1：enigmavb.exe 安装包是 Inno Setup 且要求管理员（UAC）。无人值守会话里
  UAC 弹窗没人点会永远挂起（consent.exe 常驻）。免管理员方案：`scoop install innoextract`
  后 `innoextract -e -d portable enigmavb.exe` 解出便携版
  enigmavb.exe/enigmavbconsole.exe（已存于 `scripts_pack/enigma/portable/app/`），
  打包本身不需要驱动、不需要提权。
- 坑 2：手写 .evb 工程文件（XML）给 enigmavbconsole 用，虚拟文件列表**必须**包在
  一个 `<Type>3</Type><Name>%DEFAULT FOLDER%</Name>` 的根文件夹节点里，
  否则虚拟盘不生效（进程能起，但 LoadLibrary/文件读取拿不到虚拟文件）。
- 坑 3：Options 节点若带旧版的 `<TemporaryFileMask/>` 和
  `<ProcessesOfAnyPlatforms>`，v11.30 console 打出的包一启动就 0xC0000005
  （连原生 notepad 都崩）；v11.30 GUI 保存的 Options 只有 ShareVirtualSystem /
  MapExecutableWithTemporaryFile / AllowRunningOfVirtualExeFiles 三个节点，照抄即好。
  另：wrapper 格式下 `<CompressFiles>True</CompressFiles>` 会被 console 静默忽略
  （日志打 "Compress file" 但产物不压缩，45MB→50MB），压缩产物（25MB）只在旧格式下
  生成而旧格式运行必崩——即压缩与可用性二选一，当前选可用性。
- 复用件：`scripts_pack/make_evb.py`（生成 .evb）+ `scripts_pack/muzhao.evb` +
  `scripts_pack/enigma/portable/app/enigmavbconsole.exe`；
  一条命令重建：`python scripts_pack/make_evb.py build/windows/x64/runner/Release
  muzhao.exe dist/muzhao-portable.exe scripts_pack/muzhao.evb` 后跑 console。
- .NET 程序被 Enigma 包后读不到虚拟文件时会弹隐藏对话框挂死（不是崩溃），
  验证虚拟盘是否生效要用原生 exe 写结果文件到包目录外来判断。

## [imaging] P0「成片可见歪斜」归因：不是旋转矫枉过正，是 3° 死区放行 + YuNet 眼线小角度噪声
- 现象（2026-09-17）：Windows 用户真实照片成片人像/衣领 1–3° 歪斜，怀疑摆正"转过头"。
- 实验设计（`lib/core/imaging/dev_roll_probe.dart` / `dev_roll_probe2.dart`）：黄金集
  g01/g03/g07 人工旋转 ±1/1.5/2/2.5/3/4/6/10° 跑全管线，真值用刚体几何
  （残差 = T0+φ−applied，构造上精确）。**成片 295×413 上重新检脸的 roll 读数不可信**：
  g03 目视水平却读 −6.6°——估角有尺度依赖偏差，量残差别用它当地面真值。
- 归因（修前数据，残差均值/最大，单位度）：① 主因是死区 3°：1–3° 真实倾斜完全不修正
  （g01 φ=1° 残差 2.86）；② YuNet 眼线估角：干净脸 1–4° 误差 ≤1.1；镜框脸（g03）在
  +2–4° **非单调**抖动 ±4（est(+3°)=−1.2，方向都反）；−10° 方向性衰减 ~2.3（三张照片
  一致，est(−10° 相对变化)≈−7.7，ml-porting 侧问题，eyeball 中心回归对大 CCW 倾角收敛差）；
  ③ alpha 掩膜头轴（各行前景质心斜率）被发型不对称吸向 0，斜率仅 0.6–0.85×真值，
  眼线/掩膜融合后更差（mean 1.78 vs 1.10），弃用。
- 修复：`kRollDeadZoneDeg` 3.0 → 1.0（crop_geometry.dart）。修后：g01 均值 1.03→0.72、
  最大 2.86→2.42（1–3° 段 2.86→0.72）；g07 0.87→0.84；g03（镜框+估角不稳）1.52→1.73、
  max 4.10→4.29——该例残差全是估角误差，死区怎么改都救不了，只能等 ml-porting 修估角。
- 教训：a) 实验脚本里模拟策略裁决必须读生产路径（lastDiagnostics.straightenDeg），
  自己复制一份阈值会测出"修前=修后"的假对照（residA==residB 假象，白烧一轮）；
  b) 摆正类改动一律正负两方向 + 覆盖死区边界的小角度系列一起验（±6/±10 测不出死区问题）。

## [imaging] P0 歪斜二次归因：compose 几何精确，根因坐实 YuNet 眼球关键点（误差 4–7° 且可反号）
- 现象（2026-09-17）：死区收窄到 1° 后用户两张真实照片（`1 (2).jpg` 室外自拍 2880×4982、
  `2.jpg` 蓝底证件照 1080×1415）成片依然可见歪斜。全管线复现（`lib/core/imaging/dev_roll_repro.dart`
  系列 + `out/tmp/roll_repro/`）逐阶段测量：p1 est=+0.84 → 死区放行不转，真值 −5.5±1.5（虹膜精读
  −5.9/−6.8，镜梁 −4.3、眉线 −9.5 同向），成片残余 −5.5；p2 est=−3.85 → 转 −3.9，真值 −0.2±0.5
  （眼线/镜梁/衣领三方水平），成片过矫正 +3.7。
- compose 几何被客观配准证明**精确**：同一 matting 注入 rollDeg 0/±10/est 后成片两两刚体配准
  （`out/tmp/roll_repro/step9_ab.py`），±10 实测 ±10.0（IoU 0.974）、−3.9 实测 +3.6~4.0（IoU 0.985）
  ——旋转方向、幅度、裁剪映射全对。死区也不是根因（p1 est 在任何死区下都不会转；p2 旧死区 3° 照转）。
- 根因：YuNet 眼球中心关键点（lm[0..3]）在真实照片上误差 3.7~6.7° 且**可反号**（无框眼镜+上睑下垂、
  hooded 眼）。这是 PITFALLS「镜框脸 ±4° 抖动」的实拍放大版，修复在 ml-porting。
- imaging 侧唯一独立信号 alpha 掩膜头轴也救不了：p1 读 +0.22（发型对称淹没 −5.5 信号）、
  p2 读 −0.61（能救 p2 但策略会劣化黄金集均值 1.10→1.78，见 probe2）。**没有任何 compose 侧
  策略能同时修两张**，停手等 ml-porting。
- 给 ml-porting 的依据：YuNet 原始 10 关键点在 toFaceInfo 里解码后被丢弃，只留了眼球连线 rollDeg；
  建议暴露嘴角/鼻尖或直接融合多关键点线（p2 嘴线客观 −3°=est、p1 眼/眉/镜梁 −4~−9 分散——
  单一线都不可靠，需中位/加权融合 + 框竖轴校验）。两张照片+真值可作回归夹具。
- 教训：a) 多 agent 传图时先 `PIL` 缩图落盘复核内容——本次两张源图内容与预览认知对调，白烧 15 分钟；
  b) 人工读数、暗像素质心（含眉毛）、头区 PCA（被发型污染）、IoU 配准（太平坦）全都有偏，
  结论必须落到**注入已知量的刚体恒等式**上（注入角=回收角）才可信；
  c) FaceInfo 与 MattingResult 同用「引擎工作分辨率」（长边 1536 上限，大图整体降采样）——
  拿 FaceInfo 坐标去原图上找会得出「框打在背景上」的假象（p1 差点误判成检测 bug）。

## [imaging] 五关键点三线实测：鼻轴有 ±9° 系统偏置、嘴线与眼线同错——「眼镜时上调嘴线权重」假设被否决
- 背景（2026-09-17）：ml-porting 透传 `FaceInfo.landmarks` 后，imaging 落地多线融合
  （`lib/core/imaging/roll_fusion.dart`，compose 消费，诊断进 `ComposeDiagnostics.rollFusion`）。
  10 图基线数据：`out/tmp/roll_repro/lm_fusion_baseline.json`；8 图 × 0,±1/2/3/4/6/10°
  策略对照：`lib/core/imaging/dev_roll_fusion_series.dart`。
- 实测三条线（x 定向 atan2，符号与 rollDeg 同口径）：① **鼻轴**（两眼中点→鼻尖）有
  −9°~+9° 的随 yaw/pitch 变化的系统偏置（p1 +7.0 vs 眼 +0.84、p2 −11.1 vs 眼 −3.91、
  g05 −15.3、g07 +7.3），不垂直于眼线是生物力学事实，**不是独立 roll 信号**，进三线
  等权中位只会引入 ±4° 级噪声（p2 三线中位 −4.56 比眼线更差）；② **嘴线与眼线强相关**
  （10 图 |eye−mouth| ≤ 1.17°），且在所有可判真值样本上嘴线误差 ≥ 眼线（p1 嘴 +0.71/
  眼 +0.84 同错；p2 戴镜嘴 −4.56 比眼 −3.91 更差）——两条线共享同一失败模式
  （单眼 hooded 时关键点落在上睑褶皱），**换线救不了**，ml-porting 建议的「眼镜/hooded
  上调嘴线权重」方向相反。
- 落地策略（数据定）：眼线为主 + 嘴线共识门（|eye−mouth| ≤ 0.5°）内平均去抖；
  眼线退化回退嘴线；无 landmarks 回退解码器 rollDeg（旧路径逐位保留，dev 自检的
  FaceInfo 均无 landmarks，不受影响）。系列对照（同轮同数据，mean|resid| over 104）：
  眼线 1.686 / 融合 1.709 / 纯嘴线 1.757 / 三线中位 1.689——融合在噪声级（±0.02），
  g01 小角度段有真实收益（φ=±1 残差 0.72→0.49、0.97→0.75，g01 均 0.76→0.68），
  其余图 ±0.07 内抖动。
- **p1/p2 未救回（如实报告）**：p1 融合 0.77（死区内不转）→ 残余 −5.5 原样；
  p2 共识门开（差 0.65>0.5）保持眼线 −3.91 → 残余 +3.7 原样。硬指标 |resid|≤1.5
  两者均未达成。根因在关键点定位本身（overlay 实证：p1 左眼点悬在睑褶上比瞳孔
  高约 50px 工作分辨率，见 `out/tmp/roll_repro/p1_kps_check.png`），compose 侧
  无独立信号可仲裁（掩膜轴被发型吸 0 已证伪）。**需 ml-porting 换眼球定位方案**
  （瞳孔/虹膜回归而非眼睑点，或眼区局部精化），五点线融合已到上限。
- 死区维持 1.0：融合没有带来可信度提升（前提不成立），收窄到 0.5 只会让 p1 按
  一个同样不可信的 0.77 去转、并让死区带内更多噪声估计付诸旋转。
- 教训：a) 多图系列按图统计时每图必须清零累加器，否则均值单调增长假象（g04 起全是
  跨图累计）；b) 「融合多信号」在信号间强相关时是零和的——先测相关性再设计权重。

## [imaging] P0 二次修复落地：多线融合层整体删除，compose 无条件消费 FaceInfo.rollDeg —— 别重建
- 背景（2026-09-17）：契约把 `rollDeg` 语义改成「待施加的摆正角」（测不出必须给 0.0），
  并新增 `RollSource{pupil,unavailable,given}` 仅诊断用。上一轮 imaging 落的
  `roll_fusion.dart`（眼线为主 + 嘴线共识门平均，覆盖解码器 rollDeg）**整层删除**：
  它在 104 组系列对照里与纯眼线差 ±0.02°（噪声级），p1/p2 两张真实照片一张没救回
  （见上一条 imaging 归因）。根因在眼球关键点定位，换线/融合都是零和的。
- 现状：`compose_engine.dart` 的 `planRotation(rollDeg: face?.rollDeg ?? 0.0)` 是**唯一**
  摆正入口，无任何二次仲裁分支；`ComposeDiagnostics.rollFusion` 字段一并删除，
  `straightenDeg`（实际施加角，门禁判残差用）语义与取值不变。
- 后手别踩：① 想再引入「多信号融合估角」前先读 `out/tmp/roll_repro/lm_fusion_baseline.json`
  与上一条条目——同一组 YuNet 眼睑关键点派生出的任何线都是强相关的，融合是零和的；
  ② 摆正残差实验必须读生产路径的 `lastDiagnostics.straightenDeg`，自己复制一份阈值
  会测出「修前=修后」的假对照；③ `RollSource` 只是给门禁判「覆盖率与诚实性」用的，
  消费方**不得**据它改变行为（行为差异全部由 `rollDeg` 承载）。
- 复测口径（本地已验证，commit 0bf4f3b，ml-porting 瞳孔估计尚未落地，`rollSource=given`）：
  `dev_selfcheck` 9/9；`dev_roll_repro` 两图 p1 straightenDeg=0.000（est +0.837 落死区内）、
  p2 straightenDeg=-3.913（est -3.913）；设备端 `compose_eval_test` 2B.8 ±10° 残差
  0.220/0.390（阈值 1.5）。该夹具 `landmarks == null`，改前走 fuseRollDeg 的 legacy
  分支、改后直取 rollDeg，**同一条路径**，残差与 r2 记录（0.0/0.195）的差异是设备端
  测量噪声，不是回归。

## [gatekeeper] 摆正角符号链：三个"看起来显然"的口径里有两个是反的，判 PASS/FAIL 前必须先实测钉住
- 现象（2026-09-17，建 G2B-P0 门禁时）：`回正残差 = 真值 − 实际施加角` 这个公式里，
  真值和施加角各自有"顺时针/逆时针""倾角/矫正量"两套口径，四种组合里只有一种是
  对的。选错不会报错，只会让**同一份实现从 PASS 翻成 FAIL**（p1 差 0.02° vs 8.82°）。
- 踩到的三个反直觉点：
  1. `docs/CONTRACTS.md` / `lib/core/api.dart` 写「rollDeg 正值 = 把图像顺时针转」，
     与实测行为**相反**：注入 `rollDeg=+10` 后成片倾角**减小** 10.2°，即实现是按
     逆时针转的（等价说法：`output_tilt = input_tilt − applied`）。
  2. 由此推出引擎输出的 `rollDeg` 语义是**倾角本身**（即"要抵消的量"），
     不是"矫正量"；契约那句注释把人往反方向带。
  3. qa-batch 的 `out/P0_truth.json` 里 `expectedCorrectionDeg = −trueRollDeg`，
     并注明"app 契约 FaceInfo.rollDeg = −tilt"——正是被 (1) 带偏的产物。
     **取 `trueRollDeg` 才对**，取 `expectedCorrectionDeg` 会把两个符号错误叠一起。
- 怎么钉死的（两条独立实测 + 一条事故数字反证，缺一不可）：
  a) 方向：`img.copyRotate(angle:+10)` 对 100×100 图上左中白点 (10,50) → (19,52)，
     相对中心 atan2(dy,dx) 由 179.3° 变到 −172.5°（+8.2°），y 轴向下下角度增大 =
     **顺时针**。（不要凭 PIL 印象推：PIL `rotate` 正角是逆时针，image 包相反。）
  b) 施加方向：同一张源图、同一份抠图，只把注入的 `FaceInfo.rollDeg` 从 0 改成 ±10，
     成片掩膜配准读到 ∓10.1/±9.95 → 施加 r 使倾角变化 −r。
  c) 事故数字反证：p1 applied=0 → 输出倾角 = −4.4（正是用户报的歪）；
     p2 applied=−3.85 → −0.2+3.85 = **+3.65**，对上 imaging 记录的"过矫正 +3.7"。
     若改用另一套口径，p2 会算成 −4.05，与记录矛盾。
- 教训：a) 涉及旋转的判据，**每一环都要有一个自造的最小实测**（一个白点就够），
  不要从注释、从别的库的习惯、从"大家都这么说"推；b) 契约注释与实现不符时，
  **以实现为准并把冲突写进报告**，不要为了让公式好看去改数据；
  c) 配准量具本身也要自检（注入 3.0° 读回多少），量具偏 0.2° 时结论还站得住，
  但量具要是符号反了，前面所有结论全废。
- 复用件：`tools/gate/p0_roll_probe_test.dart` 的 `registerResidual`（旋转+缩放+质心
  对齐的掩膜配准，带 `instrumentSelfTest`）；注入夹具用"同图同抠图只改注入角"，
  这样成片之间的差异**只可能**来自 compose 的几何。

## [qa-batch] 建真值集时，"目视 + 多方法一致"仍然不够——方法族本身有系统偏置
- 现象（2026-09-17，G2B-P0 真值锚点集）：四套独立测角方法（瞳孔连通域质心、
  Radon 眼带脊线、Haar 眼线、Haar 带 Radon）在 13 张真实人像上互差 ≤2.6°，
  看起来"四法一致"已经很可信；但与唯一有外部真值的 p1（主会话 −4.4）比对后发现：
  **pupil/haar 特征点族读到 −4.38/−4.08，Radon 带族只读到 −3.51/−3.54**。
  Radon 族有一个约 0.7° 的"向零收缩"系统偏置（带的上下边各含眉毛/脸颊，
  矩形带在倾斜时两侧内容权重不等）。取四法中位数当"真值"会把该偏置写进真值，
  再用真值去判实现，等于把裁判的尺子本身做歪了。
- 更隐蔽的一层：**单次量测噪声 ±0.4°，而门禁阈值是 1.5°**。于是"同一张图测两次
  差 0.4°"这种噪声，配上偶尔的 gross failure（瞳孔 blob 锁到镜框/眉毛上，
  实测出现过 −29.5° 这种离谱值），会让单张真值完全不可信。
- 解法（两条都做）：
  a) **把夹具变成重复观测**：对每个锚点施加已知 Δ∈{0,±3,±5,±10}°（纯几何旋转），
     则 `est_base(method) = median_Δ( measure_M(method, Δ) − Δ )` 是 7 次观测的中位数，
     噪声与 gross failure 一起被压掉。实测四法的 n=7 稳健估计逐法可复现（两次跑完全相同）。
  b) **必须有一个外部真值来标定方法族**，否则上面的稳健估计只是"稳"，不是"准"。
     p0 这次的关键一步是先拿 p1 的外部真值判断出 Radon 族偏置，才敢只取 M1。
- 另外两条量具坑：
  - `PIL.Image.rotate(+a)` 使本项目的 tilt 约定**减小** a（旋转方向与 `image` 包相反），
     生成"已知倾角夹具"时必须统一在一处、且用已知值标定回来（见 p0_lib 头部）。
  - 旋转夹具的**回测失败不等于夹具错**。夹具是纯几何变换，`expectedTiltDeg` 精确；
     回测方法在个别图上失手（c01/c06/c08 的负 Δ）。给夹具做几何背书要用
     **无特征点的像素级配准**（cv2 旋转搜索 + NCC），实测 78/78 误差 ≤0.015°、NCC≥0.9985。
     拿有特征点的量具去"验证夹具"，会把量具的失败误判成夹具的失败。
- 复用件：`test/batch/p0_lib.py`（四法测角）、`p0_rotate.py`（夹具生成）、
  `p0_verify_geo.py`（无特征点几何核验）、`p0_est.py`（稳健真值反推）。

## [qa-batch] 判"摆正准不准"要用成片端到端残余，但成片上的瞳孔测量会被抠图空洞打废
- 现象（2026-09-17，G2B-P0 二次收紧）：ACCEPTANCE 计分口径第 5 条把硬判据从
  `ComposeDiagnostics.straightenDeg` 改成**成片端到端残余**（口径无关）。这一步是对的
  ——符号之争不该靠定义拍板，成片正了就是正了。但落到实施上多了一个新坑：
  **成片是"抠图+换底"的产物，抠图空洞会直接把瞳孔涂成底色**，此时在成片上测眼线
  得到的是随机数，不是"残余"。
- 实例：c08 家族（`Camera Roll/WIN_20230522_00_19_11_Pro.jpg` 及其 ±Δ 旋转件）。
  用洋红底重合成立刻可见：alpha=0 的区域在成片上变成纯洋红，而 c08_d-10/d-5/d+3、
  c08_upright 的洋红正好盖住双眼与额头。此时 M1 瞳孔法读到 +7.9°/+21.8°（跨规格还
  互不一致），**与真值 −18.0° 差 7.9°**，而真值本身是对的。
  （2026-09-17 补正，本条原作者：**`c08_d+10` 并不属于这一组** —— 它的 eyeBandZeroFrac
  = 0.002，alpha 是干净的，却同样自证不可信（−2.92°）。那是**另一类失败：量测失效**，
  不是抠图失效；两类必须分开记，混在一起会让人以为"洞"能解释全部 6 条不可计分样本。）
- 关键教训：**"在成片上测出来的角"必须再自证一次**，否则会把抠图缺陷记成摆正缺陷，
  回派错人。可用的自证式：
  `隐含输入倾角 = 成片输出倾角 + 施加角(straightenDeg)`，它应等于独立测得的真值；
  差 > 2° 即判该量测不可信（实测把 c08 家族 4 条全挑出来，而正常样本最大只差 0.81°）。
  另一条有用的旁证是**跨方法族分歧**：c08_d+5 的 M1=+5.76 / M2=−16.00 / M1h=−11.68，
  分歧 21.8°，一票否决。
- 反面教材（我自己先踩的）：用"头部矩形内洋红占比 > 5%"当自动判据，把 c04_d-10
  误报成空洞——该图头小偏心，矩形里本来就大半是背景。**几何启发式判据要么用
  拓扑（flood fill 连通性），要么用自证式，不要用固定窗口占比**；而拓扑判据在这里
  也失效：空洞沿头发丝与背景相连，不是闭合洞。
- 复用件：`test/batch/p0_compose_test.dart`（走生产引擎出成片，含洋红底诊断）、
  `test/batch/p0_output_residual.py`（成片端到端残余 + 自证式筛选）。

## [qa-batch] 把自己的测量 overlay 当成"原图"去跑生产抠图，会造出一个不存在的缺陷
- 现象（2026-09-17，G2B-P0）：为排查"成片上眼睛被 alpha=0 盖住"，我把
  `out/P0_anchors/c08.png` 当原图跑了 `removeBackground`，得到一张脸上有巨大空洞的
  alpha，据此报"c08 家族抠图把脸挖空"。**这个结论是错的。**
- 根因：`out/P0_anchors/<anchorId>.png` 是**画了测量线的 overlay**（黄色水平参考线、
  四条方法线、关键点圆圈横贯整个画面），不是干净原图。原图 158KB，那份 overlay
  951KB、2.13% 像素被改动。MODNet 对横穿人脸的高饱和直线极其敏感，直接给出
  一张残破的 alpha（eyeBandZeroFrac 0.926 vs 干净原图 0.000）。
- 更正后的实测（干净输入，`out/P0_alpha_holes.json`）：
  - Pictures 全量**未旋转**人像 14 张，双眼带内 alpha=0 占比**全部为 0.0**；
  - 洞只出现在 c08 的**旋转夹具**上（d-10 0.968 / d-5 0.755 / upright 0.619 /
    d+3 0.528 / d+5 0.197 / d+10 0.002），同批的 c04_d-10、c11_d-10 为 0.0。
  - 即：**旋转诱导的抠图失效**，不是独立于摆正的既有缺陷；且对 Δ 非单调
    （d+10 干净而 d+3 破），像是该张照片上的不稳定失效，不是系统性的角度响应。
- 复用纪律：**凡是要喂给被测系统的输入，必须是原始字节**。测量产物（overlay、
  对比图、带水印的预览）只能给人看，不得回灌。夹具目录与原图目录要物理分开，
  或在文件名上强制区分（本次 `<id>.png` = overlay / `<id>_d±N.png` = 干净夹具，
  这个命名歧义就是踩坑的直接原因）。
- 复用件：`test/batch/p0_alpha_scan_test.dart`（干净输入的全量 alpha 扫描 + 洋红
  合成证据）、`test/batch/p0_alpha_holes.py`（双眼带 alpha=0 占比判据）。

## [主会话] 两个测量台各自造旋转夹具，同一个"c05_d−10"测出相反结论
- 现象（2026-09-17，G2B-P0）：gatekeeper 报 `c05_d−10` = `unavailable`、成片残余
  −10.75°；qa-batch 报同一样本 `pupil`、施加 −13.88°、残余 0.155°。双方都指同一个
  文件名、同一个"真值 −13.91"，且两侧生产代码的 rollSource 在 100 个重叠样本上
  失配为 0——一度看起来像非确定性或读数错误。
- 根因（2026-09-17 二次收紧，已逐像素复核）：**两边图像内容完全一致，只差旋转出画后
  四角的填充色。** 实测 `c05_d-10.png` == `PIL.rotate(exif_transpose(a.jpg), +10,
  BICUBIC, expand=False, fillcolor=白)`，**MAE 0.000、差异像素 0**；同参数
  `fillcolor=黑` 则 MAE 19.289、差异像素 22068/291732（7.56%），且**全部落在
  画面中央 60% 框之外，框内差异像素 = 0**。就是这个填充色差异把该样本的
  rollSource 从 `pupil` 翻成了 `unavailable`。
- **我第一版这条写错了，就地更正**：我把 MAE 19.29 读成"插值/缩放路径不同"，并据此
  说夹具被放大过 —— 两处都错。19.29 是 `fillcolor=黑` 那一组的 MAE；而 719×900 的
  `c05.png` 是**锚点 overlay（测量可视化图）**，不是夹具母本——夹具由
  `test/batch/p0_rotate.py` 直接从原图旋转而来，与 `a.jpg` 同尺寸 483×604。
  由 qa-batch 更正、我复算确认。
- 更根本的纪律：**夹具应由一方产出、另一方按哈希消费，不要各自重推。**
  "独立测量"要独立在**量测方法**上，不该独立在**输入数据**上——否则是两个都在测、
  却测的不是同一个东西的"交叉校验"。
- 教训：**"同一张图"必须以输入字节 SHA256 为准，不能以文件名、也不能以尺寸为准**
  —— 本例两边尺寸恰好相同（483×604），看尺寸会误判同源。生产两条路径一致
  （失配 0）**不能**用来排除测量台之间的差异，它们证明的不是同一件事。
- 附带发现（比本坑本身更重要）：这个样本一碰就翻，说明**瞳孔配对的判决没有裕量
  概念**，与 `c06_d−3` 的 3 倍过冲（同图 d−10 残余仅 0.075°）同源。真实照片的
  缩放/JPEG 量化/噪点会提供同量级扰动，线上同样会翻。修法方向：配对须对亚军有
  裕量要求，裕量不足返回 `unavailable` 而不是硬选。
- 复用纪律：**探针不要自己造夹具**，直接读对方落盘的夹具文件，并把输入 SHA256
  写进结果；跨测量台比对前先比哈希，再比数值。

## [qa-batch] 测量数字按 HEAD 记账会漂：docs-only 的 commit 会把结果错标到无关 commit 上
- 现象（2026-09-17，G2B-P0）：成片/覆盖率/残余三份数字产出于「HEAD `b3518ba` +
  ml-porting 未提交的估角改动」。此后主会话为收紧判据提交了两个 **docs-only** 的
  commit（`6f01e6e` / `5d4e89e`），`out/P0_truth.json` 的 `evaluatedState.gitCommit`
  就跟着漂成了 `5d4e89e`。而这个字段的语义是**测量当时的状态**——等于把一份
  03:2x 测出来的数字，标到了一小时后与它无关的 commit 上。**代码一个字没变，
  标注却错了**，这正是本项目最怕的一类"看着合理的数"。
- 根因：`evaluatedState` 是**后处理脚本**（`p0_finalize_v1.py`）写的，它读的是
  `rev-parse HEAD`（此刻），而不是测量时的工作区。同理，`P0_compose_items.jsonl` /
  `P0_output_residual.json` 里**根本没记**任何 git 字段，事后无法追。
- 解法：**按文件内容记账，不按 HEAD 记账**。用 `git hash-object`（对内容取 SHA-1，
  未跟踪文件同样适用）对 `lib/core/matting`、`lib/core/imaging`、`lib/core/api.dart`
  取指纹，再合成一个 fnv1a64。内容不变则指纹不变，与提交时序完全无关。
  - 产出侧在测量**当时**写：`out/P0_compose_summary.json` → `provenance.codeFingerprint`
    （`test/batch/p0_compose_test.dart` 的 `_codeFingerprint()`）。
  - 消费侧比对：`out/P0_truth.json` → `evaluatedState.fingerprintVerdict`，
    一致 = 数字未被后续改动污染；不一致 = 必须重跑全链。
  - 拿不到测量时指纹时，字段**明说"无法自证"**，不许回退成"记当前 HEAD"了事。
- 更一般的纪律：**判据/真值文件里的每个数字都要能被钉到产生它的代码内容上**。
  "跑的时候 HEAD 是 X"不是溯源，因为 HEAD 会动，而内容是那份内容。

## [qa-batch] 两个测量台各自"重推"同一份夹具，输入就不同源了——判决会因此翻转
- 现象（2026-09-17，G2B-P0）：同一个 `c05 Δ=-10` 样本，qa 的量测台读回 `pupil`
  （施加 -13.88°、成片残 0.155°），gatekeeper 的量测台读回 `unavailable`
  （成片残 -10.75°）。第一反应是"有一方测错了"或"非确定性"。**两者都不是。**
- 根因：**两条路径各自从原图重新推导夹具，得到的不是同一份字节。**
  qa 的 `out/P0_anchors/c05_d-10.png` 与
  `PIL.rotate(exif_transpose(a.jpg), +10, BICUBIC, expand=False, fillcolor=白)`
  **逐像素相同（MAE 0.00）**；而 gatekeeper 侧最接近的重放 MAE = **19.29**
  —— 差异像素 22068/291732 = **7.56%**，**全部落在画面中央 60% 框之外，框内差异为 0**，
  即只差旋转出画后**四角三角区的填充色**（白 vs 黑）。图像内容完全一致。
  而这个样本恰好卡在瞳孔 blob 门限上，四角填充色就足以把 `rollSource` 从
  `pupil` 翻成 `unavailable`。
- 教训一：**"同一张图"只能以内容哈希为准，不能以文件名或尺寸为准。** 本轮 c04/c05
  的尺寸恰好与源图相同，看尺寸会直接误判同源。
- 教训二：**夹具应当由一方产出、另一方按哈希消费，不要各自重推。** 重新推导时
  任何实现细节（填充色、重采样库、PNG/JPEG 编码）都会改变输入，进而改变判决——
  "独立测量"应当独立在**量测方法**上，不该独立在**输入数据**上。两者的区别一旦
  混淆，产出的就是两个都在测、但测的不是同一个东西的"交叉校验"。
- 教训三：**判决卡在门限上的样本，撑不起一条斜率。** 用一个能随四角填充色翻转的
  点去拟合 `c05 的 −侧 slope = -1.141`，结论本身就是脆的。凡拟合前先把逐点状态
  摊开（`gateInputs.c05SlopeRecheck.rows`），别只报一个斜率数字。
- 复用件：`gateInputs.inputHashes.byId` + `out/P0_input_hashes.json`（喂给引擎的
  输入字节 SHA256，测量当时写、按 id 索引）；`test/batch/sha256_util.dart`
  （无依赖 SHA-256，正确性由 `test/batch/sha256_selftest.dart` 的三组公开向量
  + 1e6 个 'a' + 与 Python hashlib 逐位比对钉死）。

## [gatekeeper] 2026-09-17 复核成片倾角时踩的三个量具坑

给 qa-batch 的成片残余做独立复核（ACCEPTANCE 计分口径第 7 条要求"换一条独立路径"），
在 Haar 眼线量具上连踩三坑，合计约 40 分钟。三条都值得下一个人直接绕开：

- 坑一：**cv2 的旋转角与 tilt 差一个负号。** `cv2.getRotationMatrix2D(angle=+θ)`
  在屏幕上逆时针，而 tilt 用 y 向下的 `atan2(dy,dx)`，于是 `tilt_out = tilt_in − θ`。
  自检时"注入 +3° 却读回 −2.73°"看起来像量具坏了，其实是自检自己把符号搞反了。
  先跑自检把符号钉死，再拿去判别人——否则会把正确的实现判成符号反了。
- 坑二：**不要靠"轮廓配准"跨成片比角度。** 同一张源图的 Δ=0 与 Δ=+10 两张成片，
  裁剪框会跟着人脸重算、尺度会变、抠图结果也不同，二者**不是刚体变换**；拿二值轮廓
  去配准会得到 0.45 的 IoU 和完全错误的角度（实测读到 +20.9°，且尺度顶到搜索边界）。
  要么在同一坐标系内比，要么退回"真值 + 实际施加角"的恒等式。
- 坑三：**"精修瞳孔质心"会帮倒忙。** Haar 眼框中心 1px 抖动 ≈ 0.6°（眼距 95px），
  看着该修；但取框内最暗 25% 像素质心会被眉毛/睫毛拽偏，自检最大误差从 0.51° 涨到 1.50°。
  真正有效的是**把检测放到 2 倍放大图上**做（量化误差减半），自检 0.41°。
  另外必须加"瞳距/脸宽 ∈ 0.22–0.55"的合理性筛，否则 Haar 会把"单眼 + 眉毛"配成一对，
  实测 c07_d-3 被配成 40.8px（同人其它成片 95px），凭空读出 3.86° 的假倾角。

复用件：`tools/gate/p0_eyeline.py`（Haar 2× 眼线量具，自带旋转自检）、
`tools/gate/p0_rigid_check.py`（轮廓配准 + 自检）。两个自检不过就不许判别人。

## [qa-batch] 用「关键词 grep 0 命中」证明「代码里没有某能力」是不可靠的
- 现象（2026-09-17，G2B-P0）：为论证「生产绝不会把面内旋转过的图喂给抠图引擎」，
  论据之一是关键词 grep **0 命中**。qa-batch 复核后发现该论据在**目录范围**下不成立。
- **更正（本条初版把范围写错了，2026-09-17 就地修正）**：那次 grep 是**只对
  `matting_engine.dart` 单文件**跑的，**在该文件内 0 命中是准确的**。
  问题出在**表述的范围**——结论被写成"matting 没有旋转/摆正代码"，
  读成"整个 `lib/core/matting/`"完全合理。qa-batch 按目录复核实测 **19 处命中**。
  **不是关键词选错，是范围被悄悄放大了。**
- 那 19 处全是 `rollDeg` 这个**估计结果字段/标识符**（`iris_roll.dart`、
  `yunet_decoder.dart`、`matting_worker.dart`）以及 `kPupilMaxRollDeg` 常量，
  **没有一处是对像素做旋转的算子**。所以「无面内旋转」这个结论本身成立，
  但支撑它的论据必须换。
- 教训一：**证据必须连范围一起说。** "文件 X 里没有" ≠ "目录里没有"。
  范围一放大，真的 0 命中就变成了假证明。
- 教训二：**证明"没有某能力"要看算子/调用，不要看关键词。** 本例正确的论据是
  「`lib/core/matting` 下没有 `copyRotate` / `.rotate(` 这类改像素的调用」
  +「该目录**唯一**的改像素几何算子是 `lib/core/matting/image_ops.dart:203` 的
  `img.bakeOrientation`，即 EXIF 方向烘焙，90° 整数倍的无损转置，不是面内旋转」。
  漏一个同义算子，0 命中同样会变成假证明。
- 附带一个同类错误：引用代码位置时把路径写成了 `lib/core/imaging/image_ops.dart`，
  该文件**不存在**，实际在 `lib/core/matting/image_ops.dart`。
  行号对、目录错，读的人会以为文件被删了。**引用行号时必须连路径一起核。**

## [ml-porting] 瞳孔定位：两条"看起来更鲁棒"的判据实测是零收益（已回退，别再试）
- 背景（2026-09-17，G2B-P0 修复）：`lib/core/matting/iris_roll.dart` 用
  「眼窗内多阈值分位数 → 暗连通域 → 圆度/尺寸/种子偏移门」找虹膜。
  在 3 张源图（c06 / c08 / c11）上有单只眼失败。
- 实测失败机理：那些眼的**眼窝与上睑阴影连成一大块暗区**，虹膜与周围皮肤之间
  **不存在**能把二者切开的分位数阈值——不是参数没调好，是判据本身没有分辨力。
- 试过 A：**加高档分位数** `[…, 16, 20, 25]`。**变差**：门禁 78 夹具覆盖率 85%→78%，
  c04/c10/c12 的 ±侧斜率掉出 [0.85, 1.15]。机理：高档把眉毛吞进连通域，触发"两家争鸣"否决。
- 试过 B：**局部对比度判据**（"比 5×5 邻域均值暗 N 灰阶"，积分图求盒式均值，N∈{8,14,22,32}）。
  **零收益**：产出的候选全被尺寸门挡下，D 段最差误差**一位数字都没变**
  （回退前 0.6169115721279401，加 B 后仍是 0.6169115721279401），纯增 8% 耗时。已完整回退，
  回退后 D 段输出与实验前**逐字节相同**。
- 机理（省得再试）：虹膜半径 ≈13px 而背景窗半径只有 2 采样点，**虹膜内部**的邻域均值
  本身就是虹膜色，对比度 ≈0，只剩虹膜**边缘**一条细环；把背景窗放大到能盖住虹膜，
  邻域均值就退化成窗口均值，判据与"直接对灰度卡阈值"**等价**。
  亮度类判据在数学上不可能比 A 多出信息——能切开这种情况的是**边缘/圆**判据（Hough 圆）。
- 实测不可用的三张源图与原因（下一轮不要重复挖）：
  · c11（5 人合影的裁切）：右眼虹膜在任何档位都不单独成域，只有 d=81–101 的"整眼窝"
    或 d=6–15 的碎点；
  · c08（gatekeeper 真值文件自标 `lowConfidence`）：左眼窗内是一片 ~7px 散点（睫毛/噪点），
    虹膜不成域；且同一张脸 d=5 能出、d=−5/−3/+3 出不来，说明它**贴着判决边界**，
    强行提覆盖等于编数据；
  · c06_d−3：左眼正常、右眼落在眉梢。
  三者一律按契约返回 `unavailable`（`rollDeg=0.0`），**没有**回退 YuNet 眼睑眼线。
- 教训：**"这个判据看起来更鲁棒"不是证据，跑一遍最差误差有没有变才是。**
  A 是"改了会变差"，B 是"改了等于没改"——后者更隐蔽，因为它不会让任何测试变红。

## [ml-porting] 判决不稳的根因：把一个 nuisance parameter 当成了定值（窗口半径）
- 现象（2026-09-17，G2B-P0 第 2 轮）：瞳孔估计的**可用性随输入姿态跳变**。
  `c06_d−5` 残余 0.020°、`c06_d−10` 残余 0.075°，唯独 `c06_d−3` 直接放弃；
  c11 五个旋转全挂。qa-batch 也报过同一夹具在内存旋转台与落盘夹具上台判决相反。
- 根因（逐档 trace 实测，`native/bench/iris_roll_debug_test.dart`）：
  **窗口半径 r = 0.30 × ed，而 ed 是 YuNet 报的双眼距、它自己随输入像素抖动**
  ——同一张 c06 在 d−3 量到 ed=88.9、d−5 量到 ed=84.9，于是 r 从 25px 变成 27px。
  而分位数阈值**是在窗口内统计的**：窗口一变，直方图就变，同一颗虹膜可能从
  "最暗的 4%" 掉出去。实测 `c06_d−5` 右眼在 r=25 的 p4 档拿到 `d=15.0 n=86` 的好候选，
  `c06_d−3` 右眼在 r=27 的 p4 档**一个候选都没有**（窗内唯一的域是 d=29.0 的"整眼窝"，
  而尺寸上界是 0.32×88.9=28.45px，**差 0.55px**）。同一张图、相隔 2°，一个 0.020° 一个放弃。
- 教训：**判决依赖的参数，如果是被测输入的连续函数，就必须扫描/边际化，不能钉一个值。**
  一个与答案无关的自由度决定了答案 = 判决不稳，而"不稳"在残差判据下和"错"同价。
- 修法：把 r 从定值改成**扫描四档** 0.20 / 0.25 / 0.30 / 0.36 × ed，四档各收一遍候选后一起竞争
  （几何门一道不放松，所以不新增准入面）。代价 ×3.6 耗时（中位 1.7ms → 7ms），可忽略。
- 实测效果（门禁 78 张旋转夹具，同一 revision 前后对照）：
  覆盖率 66/78 → **72/78**；语料 19/20 → **20/20**；c11 五个旋转全部恢复；
  **21 条变好、5 条变差**（变差的 5 条最大只涨 0.25°，且全部仍 ≤0.54°，无一从"准"变"错"）；
  最差误差 0.62° → 0.92°，>1.0° 的仍是 0 条；13 个锚点斜率仍全在 0.98–1.01。
- **同时暴露一个我引入的偏差，记在这里免得后面踩**：打分是 `面积 × 圆度²`，
  **面积大的赢**。窗口开大后虹膜会和上睑阴影连成一片，得到一个偏大的域，
  它靠面积就能压过干净的虹膜（实测 c08_d−3 左眼 r=30 给 d=31、r=37 给 d=39，
  后者得分更高，于是双眼直径比 39/22=1.77 撞上 1.6 的门）。
  即"半径扫描"会把偏差从**阈值抖动**换成**面积偏好**。要根治得给打分加"偏离
  生物常数 0.19×瞳距 的程度"权重，但那要重调 σ、可能反噬现有 72 条，
  本轮**没做**（现状 0 条错、最差 0.92° 仍达标），留作已知缺口。

## [ml-porting] 否决权不该给一个"明显不是目标"的东西：争鸣门要看种子距离
- 现象：`c08_d−3` 右眼**找到了正确答案**却被否决。真虹膜在 (838,451)
  （离 YuNet 种子 5.6px = 0.038×眼距，用它算得 −10.65° vs 真值 −11.01°，**误差 0.36°**），
  但眉毛在 (835,402)（离种子 44px = 0.296×眼距）得分 86/150 = 57% > 0.5，
  触发"两家争鸣"→ 整只眼放弃。
- 机理：争鸣门**只看分数**。面积大的东西（眉毛、镜框）天然容易达到真目标的 50%，
  于是它获得了否决权——这是"用一个不像目标的东西去否决一个像目标的东西"。
- 修法：只有**同样贴近种子**的候选才有资格否决。加
  `kPupilRivalSeedSlackInEyeDist = 0.15`（× 眼距）：竞争者离种子超过
  `首选种子距离 + 0.15×眼距` 就不参与争鸣。依据：实测真图虹膜中心离 YuNet 种子
  ≤0.093×眼距（20 张），眉毛这类假候选在 0.296×眼距，两侧都有余量。
- 注意这是**改否决权、不是改准入**：候选仍要过全部几何门。
  单独上这一条时覆盖率为 0 增益（因为 c08_d−3 随即被双眼直径比门接住），
  两条合起来才见效。

## [主会话] "已经提交了"锁不住被测代码——测量台从工作树编译，不从 commit 编译
- 现象（2026-09-17，G2B-P0，**本阶段第二次**）：ml-porting 提交 `e12f1a0` 后**继续改工作区**，
  qa-batch 按该 hash 开跑，第一步 `flutter test test/batch/p0_compose_test.dart` 就编译失败
  （`iris_roll.dart:299/304`，`_findPupil` 签名 9 参、调用点 8 参）。**整轮测量作废**。
  前一次同源事故：`evaluatedState` 从 `b3518ba` 漂到 `5d4e89e`，只是方向相反。
- 根因：**测量台是从工作树编译的**，所以"提交了"只保证存在一个可引用的版本，
  **不保证被测的字节就是这个版本**。HEAD 干净而工作树脏时，跑出来的读数绑不到任何 commit。
  更坏的是它**不会报错**——除非正好改到一半编译不过，否则数字看起来完全正常。
- 附带暴露：qa-batch 的 `codeFingerprint` 原先在**成片跑完、写 summary 时**才取，
  于是指纹记的是"跑完之后"的状态，而不是被测代码的状态——**把版本绑到了错误的时间点上**。
  已改为开跑与收尾各取一次，不一致即标 `失效`。
- 纪律（现已定为硬规则）：**门禁轮次运行期间 `lib/core/matting/` 冻结**。
  开跑前 `git status lib/` 必须干净；轮次结束前不许有任何未提交改动。
  要在测量窗口里继续干活，**用分支**（`git switch -c wip/...`），让主干工作树保持干净。
- 通用教训：**"绑到某个 commit"是一个需要主动维护的不变量，不是一个能一次性达成的状态。**
  凡是"用 commit hash 标注测量结果"的流程，都必须同时记录**开跑时工作树是否干净**，
  否则那个 hash 只是装饰。

## [gatekeeper] 越界比例不是"坏照比例"——差点把取景问题误归因成旋转
- 现象（2026-09-17，G2B-P0）：`ComposeDiagnostics.outOfBoundsFraction`（裁剪框落在源图外的面积占比）
  在 `cn_big_1inch` 的 100 条样本里 73 条 >0、40 条 >0.10、26 条 >0.20，中位 0.0423。
  看到这个分布的第一反应是"旋转把成片转坏了"，于是写下"c08 家族全部 8 条越界 8.4%–29.0%，
  是旋转诱导的"。
- 打脸的是数据本身：**越界最大的那条恰恰没旋转**（`c05_upright` 43.5%、`c08_upright` 29.0%，
  两者 `straightened=false`）。而且**越界比例与可见破损不成比例**——`c05` 越界 36.0%
  成片看着完全正常，`c08` 越界 21.0% 才肉眼可见坏（下巴被切、下缘一道底色）。
- 根因：越界只说明"裁剪框比源图大"，而成片好不好看取决于**未被覆盖的那部分落在画面哪个位置**——
  落在肩膀外侧空白处无害，落在下巴下面就是断头。
- 做法：**别拿指标当结论，渲染出来看**。`out/P0_anchors/composed/*__cn_big_1inch.jpg` 直接读图，
  一眼就能分辨"指标高但成片正常"和"指标中等但成片是坏的"。
- 通用教训：**先算相关性，再讲故事**。手上只有一个分布时，"它随时间/旋转/某个变量变差"
  是一个需要单独验证的假设，不是能从"这个数很大"推出来的结论。

## [qa-batch] summary 写着"跑完了、没崩"，实际只测了 13/100 个样本——路径被拼两次
- 现象（2026-09-17，G2B-P0 脏树那轮）：`out/P0_compose_summary.json` 读起来一片祥和——
  `cases:100, crash:0, mattingFail:0, composeFail:0`，`codeFingerprint` 开跑/收尾一致。
  实际 `ok` 只有 17（r1 是 110），items 104 条里 **87 条 `outcome:"missing"`**，
  真正被测量的 id 只有 **13 个**（其中 p1/p2 是 spotlight，各出 3 行）。
- **真凶是路径拼接，不是"被 kill 截断"。** 我起初归因成"进程被中途杀掉、剩下的补成 missing"，
  **这个归因是错的**：进程 exit 0 正常跑完，全部 100 个 case 都迭代到了。
  真正的原因是 `P0_truth.json` 里各语料的 path **格式不统一**：`anchors`/`straight` 一直是绝对
  路径，`uprightSynthetic`/`rotated` 在 v0 里是仓库相对路径、在 v1（`p0_finalize_v1.py` 重建）
  里也变成了绝对路径。而成片台对后两者**无条件拼 `$repo` 前缀**，于是得到
  `.../idPhotos/C:/Users/.../idPhotos/out/P0_anchors/p1_upright.png` —— 87 条夹具（9 upright + 78 rotated）
  全部落进 `missing` 分支 `continue` 掉。
- 后果的严重性在于**它不报错**：P0.2 / P0.3a / P0.3b 会在**零样本**上"跑完"，退出码 0。
  这正是 ACCEPTANCE 条款 7「样本不得静默消失」禁止的失败，而且**差点在提交版重跑里原样复现**——
  那会白烧一整轮 gate 预算，还可能因为"没样本 = 没违规"而误判。
- 修复（都在 `test/batch/`）：
  1. `p0_cases.dart` 统一路径口径（绝对则原样用、相对则相对**仓库根**解析），**一套逻辑两处用**；
  2. `p0_resolve_check.dart` 3 秒前置检查：跑 17 分钟的成片台之前，先问"每条样本都解析得到吗"；
  3. summary 增加 `expectedOutputs` / `missing` / `complete`——**完整性要有独立字段，不能靠 crash 推**。
- **完整性判据的确切形式**（我第一版写错了，主会话纠正）：
  正确的两条不变量是 **`missing == 0`** 且 **`ok == expectedOutputs`**，
  其中 `expectedOutputs` 是**推导值** = 输入 id × 该 id 的规格数，必须显式写进 summary。
  **不能写成 `ok == cases`**：`cases` 是去重后的输入 id 数（100），`ok` 是成片条数（110，
  同一张图跨规格产出多条），好轮次里两者本来就不相等，这么判会把好轮次误判成失效（假阴性）。
  `crash == 0` 是**必要但远不充分**的条件——只跑了 17/100 的轮次同样报得出 `crash=0`。
- 通用教训：
  - **`crash:0` 统计的是"没抛异常"，不是"跑完了"。** 完整性只能靠"预期产出数 vs 实际产出数 + missing 数"三个量一起判。
  - **同一个概念在两个产物里用不同口径表示（相对/绝对路径），并且消费方假设了其中一种**，
    是"静默失败"的经典配方。边界处必须归一化，且归一化逻辑要被检查脚本复用。
  - **发现了成因就要改归因。** 一条写错根因的 PITFALLS 比没有更坏——它会把人引向错误的方向。
  - **"判完整性"的判据本身也会错，而且会朝两个方向错**：太松放过截断的轮次，太紧废掉好轮次。
    写判据时要同时问"什么情况下它会把好的判成坏的"。
  - **用一个为别的目的造的字段去判另一件事，是同一类错误的另一种形态。** 实例：覆盖率台把
    `uprightSynthetic` 归进 `corpus: 'anchor'`，于是**拿 `byCorpus` 判 P0.2 会漏掉全部竖直样本**——
    因为 `corpus` 回答的是"这张图属于哪批素材"，而 P0.2 问的是"它是不是合成竖直样本"。
    （同类：`ok == cases`——`ok` 是成片条数，被拿去当输入 id 数用。）
    **解法是加一个正交字段，不是重新解释旧字段**：`corpus` 一律不动（改了会让差分里冒出
    一堆**并非代码变化**的"变化"），另加 `synthetic: "upright" | "rotated" | null`，
    **P0.2 的样本集一律用它取**。成本远低于重新解释一个旧字段，也远低于让下一个人再踩一次。
    附带一条同源纪律：**同一个概念在不同产物里必须用同一种表示**（"不适用"是写 `null`
    还是不写这个键，两个 harness 必须一致）——两种表示并存，就等着下一次静默错配。
  - **假绿比没有检查更坏。** 实例：我写了一条断言
    `_check('corpus 仍把竖直样本并进 anchor', perCorpus['anchor'] > 9)`——实际
    `buildCases` 的 corpus **本来就分得开**（uprightSynthetic 独立成栏 9 条），
    那件事只发生在**覆盖率台**的 `anchor_${id}` 键里。所以它实际只测了"anchor 条数 > 9"，
    **不可能因它名字所述的原因失败**，却报着 `ok`，让人以为"覆盖率台的标签问题已验证过"——
    恰恰是**没验证**的那件事。这与我们这轮抓的"仪表报干净却看不见被检查的对象"同源。
    **规矩：写断言时，先问"它在什么输入下会变红"；答不上来就删掉或改成真检查。**
    本条断言已改为"竖直样本在成片台语料里独立成栏 = 9"，并配**负向对照**——
    把竖直样本并进 anchor、或少一条，断言**必须**变红（两条对照现均通过）。
  - **假红是假绿的镜像，净效果相同：信号不再携带信息。** 实例：`fingerprint_selftest.dart`
    原有一段断言，**声明**的是"这个自测没污染真实 `lib/`"，**实际**测的是"整个自测期间
    真实 `lib/` 对**任何人**都没变"——两者不等价，它分不清"我写的"和"别人写的"。
    于是它在两次连跑之间 FAIL→PASS 翻转，翻的原因是别人的编辑器先动后停，
    **与被测代码、与指纹实现都无关**。三个后果，最要命的是第三个：
    ① 结果不确定（同一命令两次不同）；② **恰在门禁轮次期间必红**——而那种情况本轮数字
    早已被运行自身的开跑/收尾指纹判为 `roundValid=false`，这个红纯属冗余；
    ③ **人一旦学会"这条红是因为有人在编辑，不是真问题"，真正的指纹 bug 也会被同一句话带过去。**
    而它对自己声称的那件事**覆盖率是零**：隔离性由**构造**保证（所有写操作都走沙箱路径），
    第 1 段已证明沙箱是真实仓库的逐字节忠实副本。**已删除。**
    替代它的不是另一条断言（"沙箱路径在仓库外"是常量，断言它近乎同义反复，
    那是另一种"名字比检查多"），而是**把行为放回正确的位置**：
    **运行时的作废判定归 `roundVerdict`，不归"对实现的自测"。**
    区分清楚别误伤：**"机制会响"这个结论仍然成立且已确证**（沙箱内的确定性证据在
    第 2/3/4/5 段）——问题不在行为，在位置。
- 处置：脏树那轮产物挪到 `out/P0_deadrun_8097da2_truncated/`（附 `VERDICT.txt`），
  canonical 路径回滚为 `out/P0_r1_backup/` 快照。**注意 `out/P0_anchors/composed/` 是混合态**——
  脏树轮覆盖了其中 17 张（04:55–04:56），其余 93 张仍是 r1（03:30–03:31），被覆盖的 r1 原图
  没有备份、已不可恢复；反正提交版重跑会重新生成全部 110 张。
- 附带：`codeFingerprint` 的自测（`test/batch/fingerprint_selftest.dart`）必须包含**正例**——
  "开跑后改文件 → 必须报失效"。只测"没改就报有效"的机制，无法与"永远返回有效"的坏实现区分。

## [qa-batch] r1 的成片集**已不可复现**——数字仍有效，但不得从现存成片重推
- 事实：`out/P0_anchors/composed/` 现为 **93/110**（纯 r1，03:30–03:31）。被脏树轮覆盖的 17 张
  r1 原图**无备份、不可恢复**。缺失清单（已逐条核对）：
  `c01`–`c08`、`c10`–`c12` 的 `__cn_big_1inch`，加 `p1`、`p2` 各三个规格
  （`cn_big_1inch` / `cn_1inch` / `visa_us`）。
- **这 17 张不是随便哪 17 张——它们恰好是 P0.1a 与 P0.2 的判据样本集。**
  缺失的正是**全部锚点/竖直样本**（`anchors` 12 + `straight` 1 = 13 个 id）；
  而 78 条 rotated + 9 条 uprightSynthetic **一张没丢**（脏树轮根本没跑到它们，
  全被路径 bug 送进 `missing`，因此没产出、也就没覆盖）。
  于是"拿现存成片重算 r1 残余"这个动作会产出一份**看着完整、P0.3 有数、P0.1a/P0.2 全空**
  的报告——比单纯的"少 17 条"更容易骗过复核。
- **但 r1 的数字仍然有效**：`out/P0_output_residual.json` 写于 **03:34**，**早于** 04:55 的覆盖，
  量的就是当时那批原图（110 条，canonical 与 `out/P0_r1_backup/` 逐字节相同，已核 sha256）。
- **禁令（防下一个人踩）**：**任何人不得再从现存的 93 张成片重新推导 r1 的残余。**
  那样会得到一组"看起来很新、其实少算 17 条"的数字，并且很容易被当成 r1 的复算结果引用。
  r1 的残余以 `P0_output_residual.json` 为准；要新数字就**整轮重跑**，不要拿残缺的成片集凑。
- 附带一条同性质的（不是 bug）：`p2`（`2.jpg`，真值 −0.2°）**同现于 `anchors` 与 `straight` 两个语料**，
  成片台按 id 合并只测一次、归到 `straight`。**与 r1 行为一致，不是样本丢失**——
  同一张照片、同一条真值，合并后信息不减少。（对照条款 6 的去重：那是**不同文件**指向同一张照片。）
- 通用教训：**"输入产物"和"输出数字"要分别保管。** 数字一旦落盘且带时间戳，就与产生它的
  输入解耦；只要输入可能被覆盖，就必须假定"数字可复现"这件事已经失效，并显式写下禁令。

## [qa-batch] 判"两张图是不是同一张照片"：ORB 内点率会骗人，平坦背景会骗人
- 背景：核实 `ACCEPTANCE.md` 条款 6 的去重结论（`c10`/`c11`/`c12` 是否同一张合影的不同裁切）。
  前后用了三种口径，前两种都给了**会误导人的高相似度**，差点得出相反结论。
- **口径一（错）——按面积排序后逐下标比较人脸的归一化位置。** 排序键一变，`#i` 就不指同一个人，
  于是"位移"里混进了"换了一个人"。同一批图换个配对方式，max 位移从 3.503 掉到 0.490。
  **教训：跨图比较必须做一对一最优配对（匈牙利/全排列），不能靠"两边都按同一键排序"假装对齐。**
- **口径二（会骗人）——ORB+RANSAC 相似变换的内点率。** 在真人证件照上它把一堆**明显不同**的对
  判成了同图：`p1↔c03` 74.0% 内点、中位残差 0.74px；`c03↔c05` 70.1%。原因是这类图**人脸姿态相近、
  背景是同一面墙**，结构特征本身就能被一个相似变换拟上，RANSAC 把"长得像"当成了"对得上"。
  **内点率高只说明存在一个能拟合的变换，不说明两张图是同一帧。别把拟合优度当同一性检验。**
- **口径三（本次采用）——对齐后比较逐像素差，且必须把度量限制在"结构像素"上。**
  先 ECC 求欧氏对齐，再算 `|diff|`，但**不能**在全图统计：证件照一半以上像素是平坦蓝底，
  两块蓝底随便怎么比都几乎相等，会把相似度整体抬高（`c07↔p2` 全图 ≤2 灰阶 = 56%，
  看着像同图；只取 Sobel 梯度 >25 的像素后 ≤5 灰阶只剩 24.2%，中位差 13——是不同照片）。
- **标定（这是本条的实用部分，下次直接用这三组当尺子）**：
  | 对 | 结构像素 ≤5 灰阶 | 中位差 |
  |---|---|---|
  | `c03`/`c04` 已知同图（1159×1920 vs 483×800） | **95.2%** | 1 |
  | `c10`/`c11` 已知异帧 | 11.3% | 33 |
  | `c10`/`c12` 已知异帧 | 10.6% | 36 |
  同图与异帧之间差了一个数量级，中间没有灰区。
- **据此得到的结论（与条款 6 冲突，已上报主会话，我未改 ACCEPTANCE.md）**：
  `c10`/`c11`/`c12` **不是**同一张照片的不同裁切，而是同一场景、同一群人的**三张不同照片**
  （三张都是 4032×3024 全画幅原图；目视可见取景/站位不同；结构像素一致度 10–11%，与"同图"的 95%
  相差一个数量级）。条款 6 里 `c03`/`c04` 是同图那半句**经我复核成立**（scale=0.4165 恰为分辨率比、
  相对旋转 −0.024°、结构像素 ≤5 = 95.2%）。于是**不同照片数是 12 不是 11**。
- 通用教训：**"相似度"这个指标必须先在已知正例和已知反例上各跑一遍**，确认两端分得开、且中间没有
  重叠，再拿去判未知样本。直接拿一个没标定过的阈值去判，得到的数字只是阈值本身的回声。

## [qa-batch] 本机 OpenCV 4.10：`warpAffine` 在 `dsize` 小于源图时会返回**全零**
- 现象：`cv2.warpAffine(src, M, dsize)` 当 `dsize` 比源图小、且 `M` 含缩放时，
  **输出整幅为 0**，不报错、不抛异常。`INTER_NEAREST/LINEAR/CUBIC/AREA` 四种插值全中。
  同一个 `M`、`dsize` 换成 (612,612) 或源尺寸就正常。
- 最小复现（与图像内容无关，纯合成数组即可）：
  ```python
  g = np.arange(1536*888, dtype=np.float32).reshape(1536,888) % 251
  M = np.float32([[0.581,0,113.7],[0,0.581,390.6]])
  cv2.warpAffine(g, M, (306,306)).max()   # -> 0.0   （应为 250.0）
  cv2.warpAffine(g, M, (612,612)).max()   # -> 250.0
  ```
- **代价**：我基于它写的"人脸 ROI 缩放"整条链路拿到的是全零图，于是对称性指标
  完全测不出旋转。因为下游是"求最小值/最大值"，**全零输入不会报错，只会给一个假答案**。
- 规避：ROI 缩放一律用 `crop + cv2.resize`（语义相同、行为正常）；
  `scale=1` 的**旋转** warp（`getRotationMatrix2D` + 同尺寸 dsize）是正常的，可继续用。
- 通用教训：**当测量管线里出现一个"求极值"的步骤时，先喂已知答案的合成输入验证一遍。**
  全零/常量输入在这类步骤里是最危险的一类失败——它不报错，只是把极值变成一个常数。

## [qa-batch] 独立复核：两个仪器都先被"已知答案"证伪，才没有产出假数字
- 背景：`P0_truth.json` 的真值主值与**被测引擎**同属瞳孔族，二者会同时错。
  为此要一条**非瞳孔**的第二读数。我先写方法再取数，差点直接报数。
- **纪律（本条的实用部分）**：先对**已知旋转量**的夹具（`<id>_d±N`，Δ 精确已知）
  跑 `meas(Δ) − meas(0) == Δ`。**这一步不需要任何真值**，却能直接判死一个坏仪器。
- 仪器一：**整脸双侧对称轴**（高通后镜像 NCC，搜索角度+横向偏移）。
  **标定最大误差 20.7°** —— 人脸不够对称（眼镜/刘海/侧光），NCC 面被噪声主导，
  极值随机游走。**直接废弃**，不产出任何读数。别再重做这个尝试。
- 仪器二：**眼带内 Hough 近水平线段**（长度加权中位角，与 blob 法无关）。
  标定：跟踪方向正确，但 `meas(Δ)−meas(0)` 与 Δ 的中位误差 **1.36°**、最大 **2.17°**；
  在 8 个锚点上"读数−真值"的系统偏置 **中位 +1.96°**、散布 −0.74…+3.91。
- **结论（必须写成"未完成"而不是"已复核"）**：仪器二在 p1 上的原始读数是 **−2.56°**。
  要判的问题是 −4.4° vs −2.2°（差 2.2°），而**仪器自身的不确定度就是 ±2°** ——
  **测不出来**。它既不支持也不推翻 −4.4°。若强行减掉 +1.96° 的偏置会得到 −4.5°
  （看着"支持 −4.4°"），但那个偏置本身是从**有争议的真值**上估出来的，**循环**，
  不能当证据。**这条复核未交付，交给下一轮用更准的仪器（眼镜框几何等）做。**
- 通用教训：**仪器精度必须先用已知量标定，并且只有当"仪器不确定度 ≪ 待判差异"时，
  它的读数才构成证据。** 不确定度和待判差异同量级时，读数只是噪声的另一种写法。

## [qa-batch] 真值的"来源"字段声称的比实际做的多（三处，均已改表述、数值未动）
- 起因：team-lead 要 `P0_truth.json` 里 `visual` 的表述订正。查下去发现是三处同类问题。
- **(1) `visual` 是 `trueRollDeg` 的逐位副本，却以"方法"身份并列在 `methods[]` 里。**
  实测 14/14 条与真值逐位相同；它是全部方法条目里**唯一没有 `nObservations`/
  `delta0Deg`** 的，即手写插进去的。危害：一份实际只有 1~4 条独立测量的真值，
  纸面上看起来有"4 法 + 目视"五个证据；而真值主值取自 M1（瞳孔），
  与**被测引擎同族**，`visual` 这个"第五证据"又只是它的副本 —— 等于零个独立佐证。
  处置：`p0_finalize_v1.py` 的 `methods_block` 改为返回 `(methods, derivedAnnotations)`，
  `visual` 落进 `derivedAnnotations` 并带 `derived: "trueRollDeg"` / `independent: false`。
  **改后 `methods[]` 长度 = 真实方法数**（锚点 4、c08 只有 2、合成夹具 0），
  人眼复查结论仍在 `visual_review` 文本字段里，信息没丢。
- **(2) `out/P0_truth_v0.json` 的 `methods: ["pupil-centroid","haar-eyeline","visual"]`** —
  同一错误的 v0 版本，13 条全中。已去掉 `visual`（纯文本替换，949 个数值叶节点零变化）。
- **(3) `anchor_robust_estimate.json` 的 `singleObsDeg` 根本不是"观测"。**
  `p0_est.py` 里它读的是 `a["trueRollDeg"]`，即 `p0_finalize.py` 里**手写**的真值，
  然后原样回写成一个叫"单次观测"的字段 —— 名字在暗示它是一条独立证据。
  改名 `handEnteredTruthDeg`。
- **顺带查出的实质问题（不是表述问题，已上报，我没有改任何真值）**：
  `p0_est.py` 自己有一条复核阈值——稳健估计与手写真值差 **>0.8° 就该人工复核**。
  **c08 实测 +1.45°（稳健 −6.56 vs 真值 −8.01），越线了，但既没改真值、
  也没留下任何复核记录**，`note` 里只写了"暗光、Haar 失败、lowConfidence"，没提这 1.45°。
  而 c08 是 **|真值| 最大的锚点**（8.01°），承担 P0.1b"该摆正就不许说测不出"，
  还生成 6 条夹具的 expected 与 1 条 upright 合成样本 —— 真值错 1.4°，
  这些期望值就整体错 1.4°。现已在 JSON 里加 `needsReview` 布尔量，不再只靠人眼扫表。
- 通用教训：**一个字段的"名字"就是一次关于它来源的断言。**
  `singleObsDeg` 让一条手写值冒充观测；`methods[]` 里的 `visual` 让一个副本冒充方法；
  `+visual` 的来源串让一次事后确认冒充独立佐证 —— 三者是同一种病，
  而且都不会触发任何异常，只会让复核的人得出比事实更强的结论。
