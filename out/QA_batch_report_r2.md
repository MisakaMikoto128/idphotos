# QA_batch_report_r2 — G4 第 2 轮复测（qa-batch，2026-09-15）

设备：`Pixel_3a_API_34_extension_level_7_x86_64`（emulator-5554，`-gpu guest -feature -Vulkan -no-window -no-snapshot-load`，RAM 4096）。
APK：**全量重建**（`flutter clean` + `flutter build apk --debug --target=test/batch/batch_runner.dart`，01:24）。r1 用的 APK（09-14 22:58）早于三笔修复 commit（b24ccbd 00:31 / 851d89a、474036a 01:18）和 imaging 的未提交构图重写，直接复测会测到旧代码。
数据：`test/dataset.json` 冻结 80 项未动。原始数据：`out/batch_r2.json`、`out/metrics_r2.json`、`out/mem_r2.json`、`out/mem_breakdown_r2.json`、`out/leak_r2*.json`、`out/perf_r2*.json`、`out/crash_r2.json`、`out/memdump_r2/`（66 份峰值期完整 dumpsys）、logcat `out/logcat_*_r2.txt`。网格：`out/grid_r2_portrait.png`（14 行）、`out/grid_r2_watchpoints.png`（观察点 5 行）、`out/grid_r2_extra.png`。

## r1 → r2 逐项对比

| 项 | 阈值 | r1 | r2 | 数据判定 |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0**（6 份 logcat 全扫） | 保持达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 保持达标 |
| 4.3 非人像优雅 | 100% | 66/66 | **66/66**（45 graceful + 21 提示+候选，21 项 `error_message`="没找到人脸，请手动框选" 全部到达，中文 100%） | 保持达标 |
| 4.6 抠图 p95（512²，n=25） | ≤1500ms | 933ms | **909.6ms**（p50 871） | 保持达标 |
| 4.7 批量峰值内存 | ≤450MB | 814.6MB | **563.1MB** | **仍不达标**（见拆解） |
| 4.8 连续 20 张回落 | 基线+80MB | +27.6MB | **+36.4MB**（基线 414.4 → 回落 450.9，曲线峰值 577.2） | 保持达标 |

## 4.7 峰值构成拆解（如实报，不许隐藏）

- **峰值 563.1MB**，落在 chunk 0 的 **item 16 窗口**（`Globe_High.png`，仅 800×800；采样间隔 2s、每项约 4s，归属为近似值）。进入 item 16 时 PSS 已 552.7MB，**该项自身增量仅 ~10MB** —— 峰值不是单张图打的，是 floor 累积。
- **floor（进程稳态）440–510MB**，与 ml-porting 的警告一致：**floor 本身就压着/超过 450 阈值线**。构成（峰值期完整 dumpsys，`out/memdump_r2/`）：Native Heap 245–327MB + Private Other 154–216MB + Code 28–30MB + Java Heap 6.5MB。前置检查：首项开始前 PSS 仅 68.8MB，floor 是 warmUp（模型+ORT arena）+ 分配器滞留堆出来的，不是输入数据常驻。
- **大图解码增量已被控制**：4958×7017 扫描件（item 21）所在区间 PSS 峰值仅 ~502MB；r1 的 814.6 就发生在它身上。降采样解码对"单图打爆"这一失效模式**有效**（814.6 → 563.1，-251.5MB / -31%）。
- 裁决依据：阈值 450 要转绿，要么 ORT 会话/arena 的 floor 降下来（~60-100MB 量级的压缩空间在 ml-porting/环境侧），要么改用真机口径 —— **真机数据见下节，本次未取得**。

## 四个观察点新状态（视觉证据 `out/grid_r2_watchpoints.png`）

1. **win11/21 横图（item 36/37）构图：已修复。** 头顶留白正常、下巴完整、主体居中（r1：脸贴底、下巴裁掉、头顶留白 0.36）。残留：白色毛巾碎片仍被 alpha 带进全部 6 底色候选（`grid_r2_portrait.png` 倒数 1–2 行）。责任：imaging（alpha 精化未去掉主体外碎块）。
2. **1979d869 五人合影（item 4）：已修复。** 选脸从右侧比 V 人改为居中主体，头顶完整有留白（r1 两大缺陷均消失）。
3. **e9168d2c 合影（item 14）：改善未清零。** 主体构图合理，但左上角有一个邻人头发碎块出现在全部 6 候选（r1 是邻人半张脸，碎片变小了）。责任：ml-porting（alpha 把邻人发梢连进主体）。
4. **item 60 电路板：无变化**，仍是碎片状候选（fg_ratio 0.21，6 底色全部碎片），提示照常到达。按 r1 口径交 gatekeeper 会同 visual-critic 裁决。

## 其他记录

- **分类口径说明（不是 app 行为变化）**：r1 的 21 项"提示+候选"在 batch_r2.json 里标成 `success`，因为 runner 分类器先判 success（候选尺寸合规即中）再看提示；r1 时这些项候选尺寸不合规落到 hint_ready 分支。r2 这 21 项 `error_message` 逐项核实全部为"没找到人脸，请手动框选"——提示通路无回归，4.3 仍按 45+21=66/66 计。
- **扫描件 item 无回归**：r1/r2 均为 `MattingException: 抠图失败了，换一张试试吧` 优雅失败；r2 从 22.8s 降到 1.8s 快速失败（降采样路径提前拒绝）。
- 各 class matting p95（r1 → r2）：portrait 5038→1782ms、multi_face 7498→2024ms、landscape 16204→2381ms、screenshot 2412→2038ms。无性能回归，大图耗时大幅下降。
- 编排脚本固化改进：`run_device.py` 轮次化（`QA_ROUND` 环境变量）、r2 起采样器在 PSS>450MB 时保存完整 dumpsys 分类明细（4.7 拆解证据）、`merge_results.py`/`build_grid.py` 轮次参数化。
- **真机补测被环境阻断**：主会话追加的 `out/metrics_r1_realdevice.json` 任务未能执行 —— `adb -s 1e01895d install` 共尝试 3 次（r2 收尾 2 次 + 主会话追加复验 1 次，当时 `adb devices` 均为 device 状态），全部报 `INSTALL_FAILED_USER_RESTRICTED`（MIUI"USB 安装"开关，详见 PITFALLS 追加条目）。已按纪律停止重试；真机无残留（pm path 无包、无 push 文件）。release APK 已备好：`out/app-release-runner.apk`（batch_runner 入口）、`out/app-release-main.apk`（主入口冷启动用）。**待用户在手机上 开发者选项 → 开启"USB 安装"后重跑 `test/batch/run_realdevice.py`（钉死 1e01895d，跑完自动 uninstall）。**
- 上轮事故整改确认：真机 1e01895d 全程只被前置检查和两次 install 尝试接触，无任何 push/读数据动作。

## 问题清单（按严重度）

1. **【G4.7 仍 FAIL】峰值 563.1MB，floor 主导** —— 拆解见上节。责任：ml-porting（floor：ORT 会话/arena 常驻 ~440-510MB）；大图解码增量部分已修复。
2. **【构图残留】item 36/37 毛巾碎片进全部 6 候选** —— class: portrait / `Camera Roll\WIN_20230522_00_19_11_Pro.jpg`、`WIN_20230522_00_19_21_Pro.jpg`。复现：直接喂图看候选。责任：imaging。
3. **【alpha 残留】item 14 邻人发梢碎块在左上角** —— class: multi_face / `e9168d2cfe9045d07fac74e68419d211.png`。责任：ml-porting。
4. **【待裁决】item 60 碎片候选** —— class: screenshot / `Screenshots\屏幕截图 2024-10-16 121748.png`，与 r1 一致无变化。责任：ml-porting（MODNet 对任意图强抠主体）；裁决权：gatekeeper + visual-critic。
5. **【流程阻塞】真机 USB 安装被 MIUI 拒** —— 责任：环境/用户操作；已备好 APK 与脚本，解锁后一条命令可补测。
