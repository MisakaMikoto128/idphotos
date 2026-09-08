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

## 待填写

- [ ] Flutter SDK 版本与路径
- [ ] Dart 版本
- [ ] Android SDK / Build Tools / NDK 版本与路径
- [ ] JDK 版本
- [ ] 可用设备（模拟器 / 真机）及其 `flutter devices` 输出
- [ ] `flutter doctor -v` 完整输出
- [ ] 已安装的 pub 依赖及版本
- [ ] 已知的环境限制（例如：无 Xcode，iOS 不可构建）
