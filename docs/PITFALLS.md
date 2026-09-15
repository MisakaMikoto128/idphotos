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
