# Windows 桌面 release 端到端验证报告（阶段 6 W2 验收）

日期：2026-09-16。验证员只测不修。基线 commit：0290ef8。

## 1. release 构建

- `flutter build windows --release`：**成功**（首次 68.4s；插件 symlink 报错按
  PITFALLS junction 方案处理，为 6 个 Windows 插件建联接后通过）。
- 产物 `build/windows/x64/runner/Release/` 自检：onnxruntime.dll、
  file_selector/gal 等插件 dll 齐；flutter_assets 含 assets/models
  （face_yunet + modnet_portrait_int8）、fonts、textures。
- 验证后已用默认入口重建产品包并复核入口点（data/app.so 不含 WINCMP 特征串），
  最终冒烟 20s 存活、窗口标题"木照"。

## 2. 启动冒烟

- 启动 muzhao.exe：进程存活 **6 分钟以上**（验证窗口期后正常结束），
  工作集 ~2.2GB（模型已加载），主窗口句柄存在、标题 =「木照」。无崩溃退出。

## 3. 引擎 e2e（AOT vs JIT）— 黄金集

- `flutter test --release` **不存在**（Flutter 3.47 flutter_tools test.dart 无该选项，
  与 PITFALLS release 条目一致）。改用真正的 AOT 路径验证：
  `flutter clean` → `flutter build windows --release --target=native/bench/win_cmp_android_main.dart`
  （复用现有探针入口，未新增任何文件；构建后以 app.so 含 1 处 WINCMP 特征串确认入口已换）。
- AOT exe 从仓库根运行（读 test/golden/src 8 张），结果：
  **8/8 黄金图 alpha sha256 与 JIT（flutter test 探针）逐位一致**；
  g01 原始 alpha blob 逐字节一致（sha256 c502dc27…93cc，JIT 临时目录与 AOT
  %APPDATA%/com.muzhao/muzhao/win_cmp/ 两份哈希相同）；
  FaceInfo 六位小数逐值一致；provider=cpu（Windows dll 无 XNNPACK，预期降级）；
  warmUp 159ms（JIT 292ms）、latency512 median 507ms（JIT 515ms）；win_cmp_done
  marker 落盘，进程 exit(0)。
- JIT 基线（flutter test win_port_probe_test.dart）：All tests passed，
  8/8 alpha + robustness checked=8 rejected=8 violations=0。

## 4. 保存链路

- `controller.dart` Windows 分支 = `_pickSaveDestination`（getSaveLocation 对话框）
  → `dest.writeAsBytes(c.jpegBytes, flush: true)`（与 Android 分支 373 行同一 API 同参数）。
- 已验证：file_selector_windows_plugin.dll 打进产物、
  generated_plugin_registrant.cc 注册了 FileSelectorWindows（无 MissingPlugin 风险）。
- writeAsBytes 本身是 dart:io 一行调用，与已过门禁的 Android 路径同源；
  无人值守无法点按对话框，**对话框交互留待用户目检**（未用 SendInput，按纪律）。

## 5. 遗留（用户目检清单）

1. 启动后真实 UI 外观/材质（本验证只确认窗口出现与进程稳定）。
2. 保存对话框点按→文件落盘→重新解码（G3.3 口径）的人工走查。
3. AOT 探针未含 robustness 段（includeRobustness 仅 flutter test 形态开启）；
   非人像优雅失败以 JIT 侧 8/8 rejected 为准。
