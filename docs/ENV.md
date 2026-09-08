# 环境状态

**本文件由 env-setup agent 在阶段 1 填写。其他 agent 只读。**

在 env-setup 完成前，此处为空 —— 任何 agent 若发现此处为空，说明阶段 1 未完成，
应立即停止并报告，**不要自己安装任何东西**。

## 已探明的开发机现状（主会话 2026-09-08 实测，env-setup 直接采信，不必重复探测）

| 项 | 状态 | 备注 |
|---|---|---|
| CPU | AMD Ryzen 7 7735HS | AMD-V 已在 BIOS 启用 |
| 内存 / C 盘 | 27.7 GB / 188 GB 空闲 | 充足 |
| **模拟器加速** | **AEHD 2.0 已装并运行**（`gvm.sys`） | `emulator -accel-check` 退出码 0 |
| Hyper-V / WHPX | 未启用，**且必须保持未启用** | 与 AEHD 互斥，启用会顶掉现有加速 |
| Android Studio | 已装 | `C:\Program Files\Android\Android Studio` |
| Android SDK | 已装 | `C:\Users\liuyu\AppData\Local\Android\Sdk` |
| 系统镜像 | android-34 google_apis x86_64 | 已就位 |
| 现有 AVD | `Pixel_3a_API_34_extension_level_7_x86_64` | 1080×2220 / density 440 / **RAM 仅 1536MB，需调整** |
| JDK（PATH 上的） | **22.0.1 — 与 Flutter 不兼容** | 不要卸载，改用下面的 JBR |
| JDK 17 (JBR) | `C:\Program Files\Android\Android Studio\jbr` (17.0.9) | Flutter 应指向这里 |
| Python | 3.11.4 | 参考环境用，需 venv 隔离 |
| **Flutter** | **未安装** | env-setup 唯一的大件安装任务 |

### 因此 env-setup 的实际任务被大幅缩减

1. 装 Flutter SDK 到 `C:\src\flutter`（约 3GB），加入 PATH
2. `flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"` —— **必做，否则构建必失败**
3. `flutter config --android-sdk "C:\Users\liuyu\AppData\Local\Android\Sdk"`
4. **把 AVD 的 `hw.ramSize` 从 1536 调到 4096**（改 `config.ini`），否则内存/耗时指标全部失真
5. 再建一个小屏 AVD `MuZhao_Small`（720×1280, API 34 x86_64）用于响应式截图
6. `flutter create` + 加依赖 + `flutter build apk --debug`
7. Python venv + HivisionIDPhotos 参考环境

**不要**启用 Hyper-V、不要装 WHPX、不要卸载 JDK 22、不要重装 Android Studio/SDK。


## 已填写（env-setup，2026-09-08）

### 1. Flutter SDK

- 版本：Flutter 3.47.2 • channel stable
- 路径：`C:\src\flutter`（已加入用户 PATH）
- Framework revision d3b14c8769（2026-08-26），Engine a804b26164
- DevTools 2.60.0

### 2. Dart

- Dart SDK version: 3.13.2 (stable) on "windows_x64"（随 Flutter SDK 自带，未单独安装）

### 3. Android SDK / Build Tools / NDK

- SDK 根目录：`C:\Users\liuyu\AppData\Local\Android\Sdk`
- Build Tools（`Sdk\build-tools\` 实测列举）：`30.0.2`、`34.0.0`、`36.0.0`
- NDK（`Sdk\ndk\` 实测列举）：`28.2.13676358`
- `flutter doctor -v` 中 Android toolchain 使用 SDK version 36.0.0（platform android-36, build-tools 36.0.0）
- 系统镜像：android-34 google_apis x86_64（阶段 0 已就位，未变）
- Android licenses：`flutter doctor -v` 显示 "All Android licenses accepted."

### 4. JDK

- PATH 上的 java：22.0.1（**不要用于 Flutter，未卸载**）
- Flutter 实际使用的 JDK（`flutter config --jdk-dir` 已指向）：
  `C:\Program Files\Android\Android Studio\jbr\bin\java.exe`
  实测输出：`openjdk version "17.0.9" 2023-10-17`，
  `OpenJDK Runtime Environment (build 17.0.9+0--11185874)`，
  `OpenJDK 64-Bit Server VM (build 17.0.9+0--11185874, mixed mode)`
- `flutter doctor -v` 确认："This JDK is specified in your Flutter configuration." / "Java version OpenJDK Runtime Environment (build 17.0.9+0--11185874)"

### 5. 可用设备

`flutter emulators` 列出 2 个可用 AVD：

```
Id                                       • Name                                     • Manufacturer • Platform
MuZhao_Small                             • MuZhao Small                             • Google       • android
Pixel_3a_API_34_extension_level_7_x86_64 • Pixel_3a_API_34_extension_level_7_x86_64 • Google       • android
```

`flutter devices`（模拟器均未启动时的实测结果，此时输出中**没有** Android 设备是正常现象——
模拟器是按需启动的虚拟机，不启动就不会出现在 `flutter devices` 里，需要先
`flutter emulators --launch <id>` 或从 Android Studio Device Manager 启动）：

```
Found 3 connected devices:
  Windows (desktop) • windows • windows-x64    • Microsoft Windows [Version 10.0.26100.9168]
  Chrome (web)      • chrome  • web-javascript • Google Chrome 132.0.6834.160
  Edge (web)        • edge    • web-javascript • Microsoft Edge 152.0.4191.66
```

两个 AVD 的规格（`~/.android/avd/<name>.avd/config.ini` 实测）：

| AVD 名 | 分辨率 | density | RAM |
|---|---|---|---|
| `Pixel_3a_API_34_extension_level_7_x86_64` | 1080×2220 | 440 | **4096 MB**（已从 1536 调整） |
| `MuZhao_Small` | 720×1280 | 320 | 4096 MB |

真机：当前开发机未接入 Android 真机，`flutter devices` 中无真机条目。真机验证需在阶段 3/4 由持有设备的 agent/主会话另行连接测试。

### 6. `flutter doctor -v` 完整输出

```
[√] Flutter (Channel stable, 3.47.2, on Microsoft Windows [Version 10.0.26100.9168], locale zh-CN) [1,004ms]
    • Flutter version 3.47.2 on channel stable at C:\src\flutter
    • Upstream repository https://github.com/flutter/flutter.git
    • Framework revision d3b14c8769 (13 days ago), 2026-08-26 16:07:51 -0700
    • Engine revision a804b26164
    • Dart version 3.13.2
    • DevTools version 2.60.0
    • Feature flags: enable-web, enable-linux-desktop, enable-macos-desktop, enable-windows-desktop, enable-android, enable-ios, cli-animations, enable-native-assets, enable-record-use, enable-swift-package-manager, omit-legacy-version-file, enable-lldb-debugging, enable-uiscene-migration

[√] Windows Version (11 专业工作站版 64-bit, 24H2, 2009) [2.8s]

[√] Android toolchain - develop for Android devices (Android SDK version 36.0.0) [9.8s]
    • Android SDK at C:\Users\liuyu\AppData\Local\Android\Sdk
    • Emulator version 33.1.24.0 (build_id 11237101) (CL:N/A)
    • Platform android-36, build-tools 36.0.0
    • Java binary at: C:\Program Files\Android\Android Studio\jbr\bin\java
      This JDK is specified in your Flutter configuration.
      To change the current JDK, run: `flutter config --jdk-dir="path/to/jdk"`.
    • Java version OpenJDK Runtime Environment (build 17.0.9+0--11185874)
    • All Android licenses accepted.

[√] Chrome - develop for the web [452ms]
    • Chrome at C:\Program Files\Google\Chrome\Application\chrome.exe

[√] Visual Studio - develop Windows apps (Visual Studio Community 2022 17.8.5) [451ms]
    • Visual Studio at C:\Program Files\Microsoft Visual Studio\2022\Community
    • Visual Studio Community 2022 version 17.8.34511.84
    • Windows 10 SDK version 10.0.22621.0

[√] Connected device (3 available) [364ms]
    • Windows (desktop) • windows • windows-x64    • Microsoft Windows [Version 10.0.26100.9168]
    • Chrome (web)      • chrome  • web-javascript • Google Chrome 132.0.6834.160
    • Edge (web)        • edge    • web-javascript • Microsoft Edge 152.0.4191.66

[√] Network resources [5.1s]
    • All expected network resources are available.

• No issues found!
```

无任何警告（iOS/Xcode 检查项在 Windows 上 `flutter doctor` 根本不会出现，故不存在"缺 Xcode"的警告行；这是 Windows 平台的正常行为，不代表 iOS 工具链健康，只代表本机无需/无法安装 Xcode）。

### 7. 已安装的 pub 依赖及版本（`pubspec.lock` 直接依赖，实测解析）

| 包 | 版本 |
|---|---|
| flutter_riverpod | 3.4.3 |
| image | 4.9.2 |
| image_picker | 1.2.3 |
| onnxruntime | 1.4.1 |
| path_provider | 2.1.6 |
| gal | 2.3.3 |
| cupertino_icons | 1.0.9（Flutter 模板默认带的，未在任务清单里但 `flutter create` 自动加入） |
| flutter_lints (dev) | 6.0.0 |

`android/app/outputs/flutter-apk/app-debug.apk` 已产出，178,070,204 字节（约 178MB），
构建于 2026-09-08 04:45，`flutter build apk --debug` 退出码 0（G1.1 已验证通过）。

### 8. 已知的环境限制

- **iOS 不可构建**：开发机为 Windows，无 Xcode。`ios/` 目录已由 `flutter create` 生成、可编译期语法检查，但**不能**在本机执行 `flutter build ios` 或任何需要 Xcode 工具链的操作。这是平台限制，不是配置错误。
- **模拟器加速为 AEHD，非 Hyper-V/WHPX**：`gvm.sys` 常驻运行提供加速。**任何 agent 都不得启用 Hyper-V 或 Windows Hypervisor Platform (WHPX)**——二者与 AEHD 互斥，一旦启用会顶掉现有加速导致模拟器退化为纯软件模拟（极慢甚至无法启动）。
- **PATH 上的默认 java 是 JDK 22，与 Flutter/Gradle 不兼容**：已通过 `flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"` 让 Flutter 固定使用 JBR 17.0.9。**不要卸载 JDK 22**（可能被其他工具依赖），也不要指望 Flutter 会自动探测到 JBR——配置是显式写死的，如果这台机器上 `flutter config` 被重置，需要重新执行该命令。
- Windows Visual Studio / Chrome 检查项均为 `[√]` 正常，不影响 Android 构建，无需处理。
- 真机测试：本机当前没有连接 Android 真机，只能用模拟器验证。

## 参考环境（HivisionIDPhotos，仅开发机本地，不进 App / 不进 git 仓库）

- 位置：`C:\Users\liuyu\Desktop\WorkPlace\idPhotos\.ref_hivision\`（源码，已 `git clone`，`.gitignore` 已排除）
- Python venv：`C:\Users\liuyu\Desktop\WorkPlace\idPhotos\.venv_ref\`（`.gitignore` 已排除），关键包版本：
  numpy 2.4.6 / onnxruntime 1.29.0 / opencv-python 5.0.0.93 / pillow 12.3.0
- MODNet 权重：`.ref_hivision\hivision\creator\weights\modnet_photographic_portrait_matting.onnx`
  - 体积：25,888,640 字节（约 24.7MB，与上游标注一致）
  - 来源：`https://github.com/Zeyi-Lin/HivisionIDPhotos/releases/download/pretrained-model/modnet_photographic_portrait_matting.onnx`
  - SHA256：`07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9`
- 调用方式（qa-batch 生成黄金集参考 alpha 时用这个命令）：
  ```
  C:\Users\liuyu\Desktop\WorkPlace\idPhotos\.venv_ref\Scripts\python.exe ^
    C:\Users\liuyu\Desktop\WorkPlace\idPhotos\.ref_hivision\run_matting.py ^
    <输入图片路径> <输出alpha.png路径>
  ```
  退出码：0=成功，1=输入文件不存在/读取失败，2=权重文件缺失。
  输出为单通道灰度 PNG（0=背景，255=前景），尺寸与输入图一致。
  已实测跑通：对 `C:\Users\liuyu\Pictures\1 (2).jpg` 输出 2880×4982 单通道 alpha PNG，退出码 0。
  脚本内部绕开了 HivisionIDPhotos 顶层 `__init__.py`（会硬依赖 `gradio`，未装），
  直接按文件路径加载 human_matting 所需的三个模块，详见脚本头部注释。
