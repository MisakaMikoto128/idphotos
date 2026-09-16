# QA_r1 — G4 批量回归报告（qa-batch，2026-09-14）

设备：`Pixel_3a_API_34_extension_level_7_x86_64`（emulator-5554，`-gpu guest -feature -Vulkan -no-window -no-snapshot-load`，RAM 4096）。
数据：`test/dataset.json` 冻结 80 项（screenshot 37 / landscape 16 / portrait 11 / non_image 13 / multi_face 3），staging 于 `test/batch/device_in/`，设备端全流程跑完。
原始逐项数据：`out/batch_r1.json`；汇总：`out/metrics_r1.json`；耗时/内存原始序列：`out/mem_r1.json`、`out/leak_r1_mem_curve.json`、`out/leak_r1.json`、`out/perf_r1_raw.json`；logcat 证据：`out/logcat_chunk0-3.txt`、`out/logcat_leak.txt`、`out/logcat_perf.txt`。

## G4 判定数据一览

| 项 | 阈值 | 实测 | 数据判定 |
|---|---|---|---|
| 4.1 崩溃/ANR | 0 | FATAL=0，ANR=0，进程存活跑完 80 项 | 达标 |
| 4.2 人像成功率 | 100% | portrait+multi_face **14/14** | 达标 |
| 4.3 非人像优雅失败 | 100% 中文提示、不崩溃、不诡异 | 66/66 中文提示到达、0 崩溃；45 项走 error 分支，21 项走"提示+6 候选"分支（见问题 3）；视觉证据 `out/grid_r1_nonportrait_weird.png` | 争议点：item 60 产出碎片诡异结果（见问题 4） |
| 4.6 抠图 p95（512×512，n=25） | ≤1500ms | **p95=933ms**（p50=848，min=768，max=969） | 达标 |
| 4.7 批量峰值内存 | ≤450MB | **814.6MB**（item 22，4958×7017 扫描件解码时） | **不达标** |
| 4.8 连续 20 张回落 | 基线+80MB 内 | 基线 507MB → 结束 534.7MB，**Δ+27.6MB** | 达标 |

## 问题清单（按严重度）

1. **【G4.7 FAIL】峰值内存 814.6MB，超阈值 361MB** — class: landscape / `C:\Users\liuyu\Pictures\Online Verification Report of Student Record_LIU YUANLIN_00.jpg`（4958×7017）。复现：batch 跑到 item 22 时 dumpsys meminfo TOTAL PSS=834104KB。原始大图解码 RGBA≈139MB + 抠图管线多份全尺寸缓冲叠加。前 10 大采样 755–815MB 全部落在 items 20–29 区间。责任：ml-porting（removeBackground 输入未先降采样即解码/推理）。
2. **【构图错误】摄像头横图人脸贴底， Chin 被裁掉** — class: portrait / `Camera Roll\WIN_20230522_00_19_11_Pro.jpg`、`WIN_20230522_00_19_21_Pro.jpg`（1280×720，人在画面右下）。复现：直接喂图，6 张候选里人脸贴画面底部、下巴裁掉、头顶留白过大，且左侧白毛巾碎片被 alpha 带进成片。视觉证据 `out/grid_r1_portrait.png` 倒数 1–2 行。责任：imaging（取景框几何对贴边主体失效）。注意：这 2 项在 4.2 口径里计"成功"（流程走完+尺寸合法），但产出构图不合法。
3. **【非人像"提示+候选"分支】无人脸图仍产出 6 张候选** — class: screenshot/landscape，21 项（清单 `out/metrics_r1.json` G4_3）。行为与契约一致（`lib/core/api.dart:356` NoFaceException"仅提示，不阻断"），中文提示"没找到人脸，请手动框选"全部到达。但 `屏幕截图 2024-10-16 121748.png`（红色电路板图）的候选是碎片状诡异结果（证据 `out/grid_r1_nonportrait_weird.png` 第 4 行）；地球仪/花朵 3 个样本产出语义连贯的主体证件照。是否违 4.3"不产出诡异结果"由 gatekeeper 会同 visual-critic 裁决。责任：ml-porting（MODNet 对任意图都强抠一个主体）。
4. **【multi_face 头顶被裁】** — `1979d869c783fcc849d4e05b81eb809e.png`（5 人合影）：选中右侧比 V 人（非最大/最居中脸），且成片头顶发际被裁。视觉证据 `out/grid_r1_portrait.png` 第 2 行。责任：ml-porting（detectFace 主体选择策略）+ imaging（取景上边界）。同一图集 `e9168d2cfe9045d07fac74e68419d211.png` 选中主体合理但左边缘带入邻人半张脸（第 10 行）。
5. **【覆盖缺口】EXIF Orientation 未被真实数据覆盖** — 冻结数据集 80 项 `exif_orientation` 全为 1（竖拍原图不在 `C:\Users\liuyu\Pictures` 内），orientation=6 旋转链路本轮零覆盖。数据集已冻结不得增删，留给 adversarial 或人工补验。

## 附注

- 各 class 耗时（matting p50/p95）：portrait 907/5038ms、multi_face 7476/7498ms（4032×3024）、landscape 1618/16204ms（含 4958×7017 的 16s）、screenshot 953/2412ms、non_image 快速失败 ~4ms。4.6 口径只卡 512×512（933ms），大图耗时只作参考。
- **事故披露**：本轮第一次编排时模拟器因启动参数错误秒退，`adb devices` 第一个 online 设备是开发机新接入的**用户真机**（Xiaomi 2201122C），批量 App 被误装误跑到真机约 5 分钟（SELinux 拒写、未产生任何文件、未读任何用户数据，随后已 `adb uninstall` 清除并退出）。已固化编排脚本只接受 `emulator-*` serial（`test/batch/run_device.py`）。设备已 `adb emu kill` 释放，adversarial 可直接使用。
