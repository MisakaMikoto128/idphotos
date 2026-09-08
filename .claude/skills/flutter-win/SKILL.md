---
name: flutter-win
description: Windows 上开发 Flutter/Android 的坑速查。任何 agent 遇到构建失败、模拟器问题、路径问题、Gradle 报错时先读这个，不要自己瞎试。
---

# Windows + Flutter 踩坑速查

在浪费时间之前先查这里。解决了新问题就追加到 `docs/PITFALLS.md`。

## 路径

- Flutter SDK 和项目路径**不能有空格、中文、括号**。`C:\src\flutter` 是安全的。
- 项目在 `C:\Users\liuyu\Desktop\WorkPlace\idPhotos` —— 无空格无中文，OK。
- Windows 路径长度上限 260。Gradle 构建产物层级很深，项目路径尽量短。
- Bash 工具里用 `/c/Users/...`，PowerShell 里用 `C:\Users\...`。别混用。

## Gradle / Android

| 症状 | 原因 | 解法 |
|---|---|---|
| `Could not resolve all files` 卡住 | 网络或 Gradle 缓存损坏 | `cd android && ./gradlew clean`，再 `flutter clean` |
| `Execution failed for task ':app:checkDebugAotSharedLibrary'` | NDK 版本不匹配 | 在 `android/app/build.gradle` 显式指定 `ndkVersion` |
| `Unsupported class file major version` | PATH 上的 java 是 **JDK 22**，AGP 不支持 | `flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"`（JBR 17.0.9）。**不要卸载 JDK 22**，别的软件在用 |
| `INSTALL_FAILED_INSUFFICIENT_STORAGE` | 模拟器空间不足 | 建 AVD 时把 internal storage 调到 4GB+ |
| 构建极慢 | Windows Defender 扫描构建目录 | 把项目目录和 `~/.gradle` 加入排除项 |

## 模拟器

- `flutter emulators --launch <id>` 启动；启动后 `flutter devices` 才看得到。
- 冷启动慢是正常的，第一次可能 2 分钟。**不要因为超时就判定失败。**
- 截图：`adb exec-out screencap -p > out.png`（注意 Bash 里要用 `exec-out` 不是 `shell`，否则 CRLF 会损坏 PNG）。
- 内存：`adb shell dumpsys meminfo <package> | grep TOTAL`。
- **加速用的是 AEHD 不是 Hyper-V。** 本机 `gvm.sys` (AEHD 2.0) 已运行，
  `emulator -accel-check` 返回 0。**绝对不要启用 Hyper-V 或 WHPX** —— 二者与 AEHD 互斥，
  开了会把现有加速顶掉，模拟器反而变慢甚至起不来。
- 模拟器慢或起不来，先跑 `emulator -accel-check` 确认，不要凭猜测去改 Windows 功能。
- **AVD 内存至少 4096MB**。默认 1536 会让 ONNX 抠图 OOM，并且让性能指标测出假数字。
  改 `~/.android/avd/<name>.avd/config.ini` 的 `hw.ramSize`，改完冷启动（`-no-snapshot-load`）。

## Dart / pub

- `flutter pub get` 失败先试 `flutter pub cache repair`。
- 改了 `pubspec.yaml` 的 assets 声明后必须**重启** app，热重载不生效。
- `dart run` 独立脚本要放在项目内，且不能 import Flutter 库（无 UI 上下文会崩）。

## ONNX Runtime 特有

- Android 上 `.so` 是按 ABI 分的。只保留 `arm64-v8a` 可显著减小包体（现代手机全是 arm64），
  但模拟器通常是 x86_64 —— **测试和发布的 ABI 配置要分开**，别在模拟器上跑不起来就以为坏了。
- release 混淆会破坏 ONNX 的反射调用，必须加 keep 规则。
- 模型文件放 `assets/` 后是压缩存储的，首次加载要先 copy 到 app 私有目录再让 ORT 读。

## 通用纪律

- 同一个错误试 **2 次**没解决就停下来查这个文件和 `docs/PITFALLS.md`，再不行就报告，**不要循环重试**。
- 报错信息完整读完再动手。Gradle 的真实原因常在 `Caused by:` 后面，不在第一行。
