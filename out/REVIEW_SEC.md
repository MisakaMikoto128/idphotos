# REVIEW_SEC — G5 前安全审查（手动 /security-review 等价执行）

- 日期：2026-09-16 · 执行者：主会话安全审查（全库 first-pass，非 diff review）
- 项目：木照 MuZhao（纯离线 Android 证件照 App，隐私即卖点，从严标准）
- 依据：CLAUDE.md §6 硬红线、ACCEPTANCE.md G5.1/5.2/5.3/5.7
- 只读审查，未改任何代码。

---

## 一、发现清单

### HIGH

**H1 — release 包目前用 debug 密钥签名**
- 位置：`android/app/build.gradle.kts:51`（`signingConfig = signingConfigs.getByName("debug")`，附带 TODO 注释）
- 攻击场景：Android debug keystore 是全世界通用的公开密钥（口令 "android"）。若以 debug 签名上架，任何持有该标准 keystore 的人都能构造**签名匹配**的同包名更新 APK，在用户设备上覆盖安装（Android 只验签名一致性）。同时 Play Store 拒收 debug 签名包。
- 建议：G5 产出 `.aab`/`.apk`（5.4）之前必须换成项目专属 keystore（release 阶段职责）。属"阶段未完成"而非代码漏洞，但**放行 G5 前必须闭合**。

### MED

**M1 — 保存成功后，成品照片永久滞留在 App 私有 temp 目录**
- 位置：`lib/core/controller.dart:308-338`（`save()`：Gal 写相册成功后不删除 `file`；只有 Gal 失败路径才清理）
- 攻击/隐私场景：用户每保存一次，一张全分辨率人像 JPEG 就留在 `getTemporaryDirectory()`，累积不清理，直到系统偶发清 cache。配合 M2（allowBackup 默认开），Android 12+ 的**设备到设备迁移（换机数据线传输）会连带复制 cache 目录**，人像照片随之迁移到新机/被迁移工具读取。与"不把用户照片留在非必要位置"的隐私承诺相悖。
- 建议：Gal 写入成功后删除私有临时文件（G3.3 的"回读可解码"验证可移到删除前，或保存后仅返回相册 URI）。当前门禁 G3.3 依赖返回路径存在，改动需主会话协调 gatekeeper 同步口径。

**M2 — 未显式声明 `allowBackup=false` / `dataExtractionRules`（取默认 true）**
- 位置：`android/app/src/main/AndroidManifest.xml:15`（`<application>` 缺 `android:allowBackup`、`android:dataExtractionRules`、`android:fullBackupContent`）
- 攻击场景：默认 allowBackup=true。云自动备份虽默认排除 cache 目录（M1 的照片暂时幸免），但允许通过 `adb backup`（旧版本）/ D2D 迁移提取应用数据；对一个隐私优先 App，应显式拒绝备份与设备迁移。`android:debuggable` release 默认 false、cleartext 默认禁用（targetSdk 36），这两项无问题。
- 建议：加 `android:allowBackup="false"`（或 dataExtractionRules 明确 exclude 全部用户数据域）。属 release 阶段 manifest 精简范围。

**M3 — 头解析失败时的兜底解码路径存在内存耗尽 DoS 面（单图 ~256MB 瞬时分配）**
- 位置：`lib/core/matting/image_ops.dart:163-181`（`decodeToRgb` 先全量 `img.decodeImage` 再校验 ≤ `kMaxImageEdgePx`=8000，`lib/core/api.dart:394`）
- 攻击场景：`planWorkingSize`（`image_ops.dart:65`）只覆盖 JPEG/PNG/GIF/BMP/WebP 五类头；头解析返回 null（如 TGA/EXR/PNM 等 image 包可解但头未覆盖的格式，或构造使扫描器提前 break 的畸形 JPEG）时走兜底全量解码。8000×8000×4B ≈ 256MB RGBA + image 包内部中间缓冲，叠加 ORT 常驻 floor（模拟器实测 ~505MB）→ 单张图即可触发 OOM kill（进程崩溃 = DoS；真机低内存机型更易触发）。
- 建议：兜底路径在 `decodeImage` 前先用 image 包的 decoder info 接口（`findDecoderForData` → `startDecode`/`info`）预取尺寸做同口径拒绝；或把 kMaxImageEdgePx 收紧。对抗组 59 例未打爆此面（0 崩溃），属残余风险而非已证缺陷。

### LOW

**L1 — 日志出口未按 release 裁剪，原始异常（可含私有路径）进 logcat**
- 位置：`lib/ui/util/error_text.dart:56-57`（`debugPrint` + `debugPrintStack`）、`lib/core/controller.dart:332`、`lib/main.dart:35`
- 场景：debugPrint 在 release 仍输出；内容为异常对象（`FileSystemException` 含 temp 目录绝对路径）与栈。无照片内容外泄；现代 Android 上第三方 App 读他人 logcat 已被 READ_LOGS 签名级权限挡住，仅 adb 可见。
- 建议：包一层 `if (kDebugMode)` 或在 release 静默。非阻塞。

**L2 — image_picker_android 的 merged manifest 含 Google Play Services 存根 service（惰性，不构成依赖）**
- 位置：merged release manifest（`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`）中 `com.google.android.gms.metadata.ModuleDependencies`，源：pub 缓存 `image_picker_android-0.8.13+22/android/src/main/AndroidManifest.xml`
- 事实核查：`enabled=false, exported=false`，类不存在（tools:ignore MissingClass），gradle 依赖树**没有**拉任何 play-services AAR（与 G5.3 判定一致，可由 `gradlew :app:dependencies` 复核）。不联网、不执行代码。
- 建议：仅文档层面在隐私政策/合规材料说明"无 GMS 依赖，此条目为 Flutter 官方 image_picker 的空存根"。若要绝对洁癖需 fork 插件，代价不值。

**L3 — 传递依赖树含 `http` 包（不可达于 Android release 路径）**
- 位置：`pubspec.lock`（经 file_selector_platform_interface / image_picker 平台接口 / webdriver 等桌面与测试链引入）
- 核查：`http` 本身不声明 INTERNET 权限；Android 端 image_picker_android 不引用它，release 编译树摇除。无联网路径。记录在案防止误判。

**L4 — git 仓库内已提交含真实人像的测试/产出物**
- 位置：`test/golden/src/*.jpg`（黄金集人像）、`out/`（3059 个被跟踪文件，QA 网格/指标图内嵌真实照片）
- 场景：仓库目前无 origin、纯本地，风险=0；一旦未来 push 到任何远端，即把真人生物特征数据外发。
- 建议：push 前决策 out/ 的 gitignore 策略与黄金集脱敏。记入遗留事项。

**L5 — `lib/core/imaging/dev_*.dart`（6 个）与 `lib/ui/dev/` 的开发 harness 混在生产目录**
- 核查：生产 import 链（main.dart → app.dart → areas）未引用任何 dev_*/fake_*（已逐一 grep），release 树摇除后不可达；这些文件含 `print` 与向 `out/tmp` 写文件的调试逻辑。
- 建议：保持现状可接受；若做 `/simplify` 可考虑移出 lib/。非阻塞。

---

## 二、已核对无问题清单

1. **网络红线（lib/ 全量 grep）**：无 http/https/dio/Socket/HttpClient/WebSocket/Uri 使用。唯一命中是 `lib/ui/dev/sample_photo.dart:298` 的 base64 样张数据字符串（'H3cm1/…'），非网络代码。
2. **网络红线（android/）**：main manifest 无 INTERNET；debug/profile manifest 的 INTERNET 是 Flutter 标准开发配置，仅进 debug/profile 产物。
3. **网络红线（release merged manifest 实证）**：解析 `build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml` —— 权限集恰为 {READ_MEDIA_IMAGES, WRITE_EXTERNAL_STORAGE(maxSdk=32)} + signature 级 DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION，**无 INTERNET**，符合 G5.1/5.2（G5 正式判定仍由 gatekeeper 对最终产物跑）。
4. **网络红线（native/、依赖树）**：native/ 无任何网络引用；`flutter pub deps` 全树无 firebase/play-services/mlkit/crashlytics；onnxruntime(1.4.1)/gal(2.3.3)/path_provider(2.3.1) 插件自身 manifest 均不声明权限。
5. **遥测/上报**：全库无统计、崩溃上报、分析 SDK；无任何上传路径。取图流程为 ImagePicker→内存字节→引擎，用户输入照片全程不落盘。
6. **数据去向**：唯一落盘点是 `save()`（用户点击触发）：App 私有 temp + Gal/MediaStore 写相册（相册名 '木照' 为编译期常量，无注入面）——符合 CLAUDE.md §6 例外条款。模型权重（ORT）解压到 App 私有 support 目录（`ort_runtime.dart:66-78`），私有权限。
7. **文件名与路径注入**：`save()` 文件名 = 时间戳 + 进程内序号 + `style.id`；`style.id`/spec.id 全部来自 `lib/core/api.dart:216-344` 编译期常量，无外部输入可影响。无路径拼接自用户数据。
8. **不可信输入 — 头解析器**：`image_header.dart` 与 `lib/ui/util/image_size.dart` 全程下标越界检查；JPEG 段扫描 `i += 2+len` 单调递增保证终止；EXIF IFD 偏移/条目数越界检查完备；Dart int 64 位无整数回绕。超出 8000px 的五类已知头在解码前即拒绝（`ImageTooLargeException`）。
9. **不可信输入 — 解码降采样主路径**：>2048 长边走 dart:ui `instantiateImageCodec` 目标尺寸解码（原生解码器产出 ≤2048/1536 小图），Dart 侧不接触全尺寸缓冲（`flutter_decode.dart`）。
10. **ORT FFI 层（安全面）**：`ort_runtime.dart` calloc/free 在成功/失败/finally 各路径均配对；OrtStatus 用后释放；EP 尝试失败时 options 释放；`OrtSession.fromAddress` 失败时显式释放 native session（无泄漏）；模型字节仅来自 APK assets（const 路径），`debugModelDirectory` 与 5 个 `debug*` bench 钩子为 dev-only 全局量，生产代码不可自外部输入设置。无指向已释放内存的 UAF 面（G4 已审正确性，此处复核安全面）。
11. **Android 组件面**：MainActivity exported=true 仅 MAIN/LAUNCHER（必需）；ImagePickerFileProvider exported=false；GMS 存根 service exported=false + enabled=false（见 L2）；androidx ProfileInstallReceiver exported=true 但受 DUMP 签名级权限保护（androidx 标准件）；无自定义 receiver/provider。
12. **密钥面**：`android/key.properties`、`*.jks`、`*.keystore` 磁盘与 git 均不存在；`.gitignore` 已覆盖三者；全库 grep 无硬编码口令/token/API key。G5.7 的"在 .gitignore 中"条件已满足（"密钥本身尚不存在"—— release 阶段生成后不得破坏该 ignore）。
13. **供应链**：pubspec.lock 全量锁定；直接依赖 8 个均为知名维护（flutter first-party：riverpod/image/ffi/path_provider/image_picker/cupertino_icons；社区：gal 2.3.3 midoridesign 活跃、onnxruntime 1.4.1 gtbluesky 社区维护活跃度一般但版本锁定 + 供应链风险仅影响本地已缓存副本）。无 git 依赖、无 path 依赖。
14. **三段式 UI 侧**：裁剪坐标经 controller 快照/钳制；UI 层异常统一转中文 + 日志（见 L1），无原始异常透出 UI。

---

## 三、结论

- **HIGH 1 / MED 3 / LOW 5。**
- 网络红线：**全库（lib/android/native/依赖树）无任何联网路径**，release merged manifest 实证无 INTERNET —— 红线成立。
- 密钥面：仓库与磁盘均无密钥物，.gitignore 就位；唯一风险是 release 签名还挂在 debug keystore（H1），G5 出包前必须闭合。
- 放行建议：H1/M1/M2/M3 均属 release 阶段（阶段 5）职责范围内的修复项，转派 release + 主会话；不阻塞进入阶段 5，但 G5 判定前必须全部闭合。
