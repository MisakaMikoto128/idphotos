# ADVERSARIAL 对抗测试报告 — r1（G4.4）

日期：2026-09-15 ｜ 执行环境：Pixel_3a_API_34_extension_level_7_x86_64（RAM 4096，AEHD，`-gpu guest -feature -Vulkan -no-window -no-snapshot-load`，`--ez enable-impeller false`）
被测对象：真实引擎 `IdPhotoEngineImpl` + 真实控制器 `MuZhaoController`（设备端，debug APK，`--target=test/adversarial/adversarial_runner.dart`），无任何 mock。
编排脚本：`test/adversarial/run_adversarial.py` ｜ runner：`test/adversarial/adversarial_runner.dart` ｜ fixtures：`test/adversarial/fixtures/`（53 个文件，保留供回归）
原始数据：`out/ADVERSARIAL_r1.json`（59 条用例记录 + 19 个成片 host 端 PIL 回读验证）｜ 内存曲线：`out/ADVERSARIAL_r1_mem.json` ｜ logcat：`out/logcat_adv_*_r1.txt`

## 一、总量与覆盖

**59 个设备端用例，全部执行完毕（4 个独立 app 启动分块，任何一块无 done-marker 缺失 → 0 进程崩溃）。**

| 类别 | 数量 | 覆盖 |
|---|---|---|
| 畸形文件 m01–m16 | 16 | 0 字节、文本改名 .jpg、截断 JPEG、IDAT 损坏 PNG、1 亿像素 PNG 炸弹头、限内 7900×7900 炸弹、CMYK JPEG、16-bit PNG、动图 GIF、动画 WebP、多帧 TIFF、伪 HEIC、尾部垃圾 JPEG、PNG 改名 .jpg、PE 头改名 .png、中文+emoji 文件名 |
| 极端尺寸 s01–s11 | 11 | 1×1（png/jpg）、20×8000、8000×20、1×8000、8000×6000 真实大图（降采样路径）、8001×100（超限 1px）、12000×9000、600×600、2×3、2049×2049（恰好越过引擎工作分辨率） |
| 内容极端 c01–c11 | 11 | 全黑、全白、纯噪、强噪人像、五人合影、倒置人脸、半脸贴边（mtcnn 定位构造）、人占画面 <2%、纯肤色块、灰度人像、浅背景浅肤色 |
| **EXIF 方向 e01–e11** | 11 | orientation **1–8 全覆盖**（qa-batch 指定的零覆盖缺口）+ 谎报 orientation（像素摆正 tag=6/8）+ 非法 tag=9；objective 判据 = 16×16 灰度剖面 MAD 对比摆正参考与三个旋转参考 |
| 操作序列 q01–q09 | 9 | load 进行中再 load、合成中切规格、load 中 setCrop、7 规格连点、8 种极端裁剪框（含反向/出界/零面积）、**并发 save×20**、坏图后立刻换好图、好→坏→恢复、30 张连续压力 |
| 资源压力 | 1 | q09（30 张含 4032×3024 合影）+ host 侧 1s 采样 dumpsys meminfo |

## 二、三个判定项实测结论

### 0 进程崩溃 — PASS
- 4 块全部出现 `done_cases` marker；59 条记录 0 条 `harness_exception`；`begin_/end_` marker 无缺失（无中途死亡）。
- logcat 四块均无 FATAL/AndroidRuntime 崩溃记录（`out/logcat_adv_*.txt`）。

### 0 数据损坏 — r1 FAIL → **修复后 r2 复验 PASS**（见第五节）
- 50 个引擎用例的所有"成功"成片（设备端 `img.decodeJpg` + host 端 PIL 二次独立解码）全部可解码、尺寸精确正确（19 个落盘 artifact host 端回读全过）。
- EXIF e01–e08 的方向验证：MAD(摆正参考) = 0.5 vs MAD(旋转参考) = 53.6–66.2，8/8 全部 `orientation_ok=true, aspect_ok=true`。**成片方向全部正确，qa-batch 指定的缺口已补齐。**
- r1 的 q06（并发连点保存 20 次）暴露文件名撞名缺陷（原判 CRITICAL，经 r2 复验修正为 MAJOR——"字节级损坏"一项是我的验证脚本口径错误，详见第五节的修正说明）。

### 0 无响应 >5s — PASS
- 单个引擎操作最大 4.0s（m03，含截断 JPEG 的宽松解码）；stress30 单张最大 3.0s。
- q04（5.7s）/q05（9.5s）/q09（66s）是**批量操作累计耗时**（7 次连续重合成 / 8 次拖拽重合成 / 30 张连续处理），全程异步调度无阻塞，不构成 ANR。
- 全部引擎异常均为契约异常且 `messageZh` 含中文（CJK 检查 0 失败），无异常穿透。

## 三、缺陷清单

### #1 MAJOR（r1 原判 CRITICAL，r2 复验降级）— controller.save 文件名毫秒级冲突：并发连点保存共享同一路径（责任：主会话 / `lib/core/controller.dart`）**【已修复，r2 复验通过，见第五节】**
- 用例：q06_save_x20。复现：加载 g01.jpg → 并发调用 `controller.save(candidates.first)` ×20（模拟连点）。
- r1 实测：20 次保存只产生 **6 个不同路径**（时间戳 `DateTime.now().millisecondsSinceEpoch` 相同 → `muzhao_<ms>_white.jpg` 撞名）；15/20 返回路径在校验时读不到文件。其中一部分是我的验证脚本在首个校验通过后删除了共享路径所致，但这恰恰证明**多个 save 共享同一条落盘路径**：任何一次失败清理（X4 的 `file.delete()`）都会删掉其他保存刚返回的文件。
- **修正（r2）**：r1 曾报"存活文件解码尺寸错误 = 字节级损坏"，经 r2 复验查明是**我的验证脚本把期望尺寸硬编码成 295×413**，而 q06 的候选此时是 visa_us 规格（600×600，同控制器前面用例切换后残留）——文件本身完好。r1 真正成立的缺陷只有**路径撞名**一条，故降级 MAJOR。撞名下并发 `writeAsBytes` 互相截断的损坏风险理论上存在，r1 未抓到实际证据。
- 期望：每次 save 返回的路径必须真实存在且可重新解码（G3.3 契约）；G4.4 要求 0 数据损坏。
- 附带风险：X4 清理逻辑（相册写入失败 → `file.delete()`）在撞名场景会删掉别人正在写的同名文件（修复后路径唯一，该风险结构性消除）。
- 复现材料：`test/adversarial/fixtures/g01.jpg` + runner `q06_save_x20`；证据 `out/ADVERSARIAL_r1.json` → cases.q06_save_x20.steps[0].detail（r1）、`out/ADVERSARIAL_r2.json`（修复后复验）。
- 修复（主会话已提交）：`save()` 文件名加进程内序号 `_saveSeq++`。r2 复验通过：20/20 独立路径、20/20 存在、20/20 解码成功且 600×600 与候选一致。

### #2 MAJOR（观察项）— 对抗压力负载下峰值 PSS 589MB（责任：主会话评估，ml-porting 关注）
- 位置：content_exif + sequences 两个块（含 4032×3024 合影、30 张连续处理、并发保存）期间 1s 采样。
- `out/ADVERSARIAL_r1_mem.json`：`peak_kb=603192`（589MB）；采样明细最大 499MB（差异来自采样间隙的瞬时尖峰）。曲线波动在 450–500MB、无单调上升 → **无泄漏迹象**（G4.8 泄漏判定仍以 qa-batch 协议为准），但瞬时峰值显著高于 G4.7 的 450MB 阈值口径。与 qa-batch 的正式 4.7/4.8 测量（不同负载协议）合并评估，确认是否需要处理。

### #3 MINOR — 截断 JPEG 被宽松解码成"完整"图并成功出片（责任：ml-porting）
- m03（g01.jpg 截断 50%）：解码出 1080×1415 全尺寸像素（下半部为解码器填充），`compose` 成功产出合法 295×413 成片（检脸失败 → "没找到人脸"提示）。不崩溃、尺寸合法，但用户可能拿到半截垃圾像素的"成功"结果。行为可接受，记录备查。

### #4 MINOR — 纯色/无结构图统一走 MattingException 而非"无人脸"提示（责任：ml-porting，行为可接受）
- s01–s05、s09–s11（1×1、2×3、长条、正方形纯色）、c01 全黑、c02 全白、c09 肤色块、c08（<2% 小人）全部 `MattingException("抠图失败了，换一张试试吧")`——中文文案、优雅失败，符合 G4.3 底线；但 MODNet 对纯色输入返回退化结果被当作"抠图失败"而非"无人脸可手动框选"。全噪声 c03、纯色 c09 反而走"成功+无人脸"，行为不一致但无害。

### #5 MINOR — 格式支持口径不一致（责任：ml-porting，不崩溃）
- 动图 GIF → `UnsupportedImageException`；动画 WebP / 16-bit PNG → `MattingException`；多帧 TIFF → 成功取首帧。三种"非主流格式"三种结果，均优雅失败或成功，无崩溃。文档化即可。

### 期望行为确认（无缺陷）
- 超限拒绝：m05（1 亿像素炸弹头）、s07（8001，超限 1px）、s08（12000×9000）全部在头扫描阶段秒拒（0–4ms）`ImageTooLargeException`，不先解码。
- s06（8000×6000 真实大图）走 dart:ui 降采样路径成功，工作分辨率 2048×1536，`src_size=8000x6000` 坐标链正确，compose 成片 295×413。
- 谎报/非法 EXIF tag（e09/e10/e11）：按 tag 字面处理、无崩溃（tag 是数据权威，横躺输出属预期）。
- m13（合法 JPEG + 尾部垃圾）容忍成功；m16（中文+emoji 文件名）正常；m12 伪 HEIC / m15 PE 头 → `UnsupportedImageException`。
- 全部 race 用例（q01/q02/q03/q07/q08）：终态 sourceImage 与最后请求一致、候选 6 张、规格/尺寸正确、错误态可恢复——X1/L1 修复在真实引擎时序下成立。

## 四、设备已释放
`adb emu kill` 已执行（run_adversarial.py 末尾确认），模拟器已退出，真机 1e01895d 全程未触碰（编排脚本 assert 钉死 emulator-*）。

---

# r2 — q06 修复复验（2026-09-15）

**修复内容**（主会话提交）：`lib/core/controller.dart` `save()` 文件名由 `muzhao_<毫秒>_<styleId>.jpg` 改为 `muzhao_<毫秒>_<saveSeq++>_<styleId>.jpg`（进程内自增序号），同毫秒连点不再撞名。`dart analyze lib/core/` 干净。

**复验方式**：重打 adversarial_runner APK（`--target=test/adversarial/adversarial_runner.dart`），重跑整个 sequences 块（q01–q09，顺带回归验证相邻用例未受修复影响）。q06 的验证脚本同时修正：期望尺寸不再硬编码 295×413，改为与候选自身的解码尺寸比对，并记录实际解码宽高与去重路径数。

**结果（`out/ADVERSARIAL_r2.json` → cases.q06_save_x20）**：

| 指标 | r1（修复前） | r2（修复后） |
|---|---|---|
| 去重路径数 / 20 次保存 | **6**（撞名） | **20** |
| 校验时文件存在 | 5/20 | **20/20** |
| 双重解码成功（设备端 image 包 + 尺寸比对） | 5/20 | **20/20** |
| 解码尺寸与候选一致 | 全部不符（验证脚本口径错误所致） | **20/20 = 600×600 与候选一致** |
| save_ok / save_bad | —（记录口径不同） | **20 / 0** |

- 文件名形如 `muzhao_1789476215877_0_white.jpg` … `_19_`（时间戳 + 序号），无一重复。
- 序列块其余 8 个用例（q01–q05、q07–q09）全部 `done`、终态语义与 r1 一致——修复未破坏相邻行为。
- **X4 清理路径（Gal 失败 → 临时文件被删 → 不误删他人）**：未复验。Gal 走 MediaStore，设备端 runner 里没有不改动 `lib/` 就能稳定触发 `GalException` 的手段（裁判不下场，不改生产代码）；跳过该子项。但结构上该风险已消除：文件名唯一后，X4 的 `file.delete()` 只可能删到自己刚创建的那一个文件，不存在误删对象。
- 判定更新：**G4.4 "0 数据损坏" 在修复后转绿**。r1 报告中缺陷 #1 的"产出损坏文件"描述已在本报告中修正（详见第三节 #1 的修正注记），责任在验证脚本口径，不在 app。
- 设备已释放：`adb emu kill` 确认，真机未触碰。

