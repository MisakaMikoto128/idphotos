# GATE G4 — 第 1 轮（2026-09-15）

## G4 第 1 轮：**FAIL**

- 通过 **13 / 16** 项（含 6 项防作弊巡查），MANUAL 项 **0** 个
- **真实退出码：1**（`dart run tools/gate/gate_G4.dart --out out/gate_G4.json --batch out/gate_G4_batch_ref.json --adversarial out/gate_G4_adversarial_ref.json --metrics out/gate_G4_release_metrics.json`；机器可读结果 `out/gate_G4.json`）
- 本轮是第 **1** 轮 / 3 轮预算。未触发终止。
- 设备阶段真实执行：spotcheck drive 退出码 0（8 项抽查复跑）+ memcheck drive 退出码 0（profile 构建 20 张 churn）。模拟器一次一台，用毕 `adb emu kill` 已确认消失；真机 1e01895d 本轮零触碰（编排 assert 钉死 emulator-*，该机被 MIUI「USB 安装」开关阻塞属用户侧事项）。

## 脚本完整性

- 与 `out/hashes_prev.txt`（G3 r2 末）比对：`docs/ACCEPTANCE.md` 哈希变化 → **放行**。变化 = 提交 `76cf071`（acceptance: 4.6 真机→设备端口径，人工授权），diff 仅 4.6 一行，AC.6 自动溯源通过，本轮人工复核 `git show 76cf071` 属实。
- `tools/gate/gate_G4.dart` 为本轮 gatekeeper 新增（允许）；本轮另新增 `tools/gate/g4_release_memcheck.py`（release 口径复测编排）。其余 14 个文件哈希逐字节一致；RUBRIC.md 未变。
- hashes 已滚动至 `out/hashes_prev.txt`（含 gate_G4.dart 本轮终版哈希）。

### 本轮工装变更（全部 gatekeeper 势力范围，未放宽任何阈值）

1. `gate_G4.dart` 新增（G1 计划内的 G4 门禁本体）。
2. 4.3 判定语义按 `docs/CONTRACTS.md` §异常表固化：NoFace「仅提示，不阻断」= hint+候选属契约行为；「不产出诡异结果」以 qa-batch weird 标记 + gatekeeper 目视裁决为准。
3. memcheck 复测改 **--profile** 构建 + 空闲窗 14s（原 debug 构建会抬高 floor、旧启发式会把预热爬坡段误当基线）；这是 4.7 构建口径修正的配套，450 阈值不变。
4. `_pickPreferredDevice` 改为只认 emulator-*（原"真机优先"逻辑在本轮会撞上用户在线的真机，危险）。
5. 新增 `out/gate_G4_batch_ref.json` / `out/gate_G4_adversarial_ref.json`（裁判数据 → gate schema 的**逐项忠实映射**，映射规则写在文件内；含 1 处 gatekeeper 目视裁决注记，见 4.3）。

## 4.7 构建口径核实（本轮关键裁决）

- **实锤：qa-batch 模拟器度量是 debug 构建**（`test/batch/run_device.py` APK=app-debug.apk，qa-batch r2 报告亦自述）。debug JIT+调试服务显著抬高 floor。
- **release 口径重测**（`out/app-release-runner.apk`，含全部 r2 修复，模拟器实测，原始数据 `out/gate_G4_release_metrics.json`、`out/memdump_gate_release/`、曲线 `out/gate_G4_release_{batch,leak}_curve.json`）：
  - 4.6 p95 = **750ms**（n=25，p50 629）——比 debug 的 909.6ms 更好，达标；
  - 4.7 batch 全量 80 项峰值 = **487.5MB，仍超 450**（debug 563.1 记为参考）；
  - 4.8 20 轮回落 Δ = **60.6MB**（280.8→341.4）达标。
- **release 拆解**：稳态 floor ≈ 340-348MB（Native Heap 251-262 + Private Other 47-52 + Code 25）——**floor 本身已低于 450**（与 debug 440-510 的 floor 主导结论不同，debug 结论系工件偏差）；峰值超阈值来自**瞬时滞留**：>450MB 的 3 个采样点集中在 batch 后段，峰值 dump（482MB）Private Other 187MB（稳态 ~50MB，+135MB），且峰值落在 item 76（638 字节的截图输入）上——**不是大图解码打的，是分配器/图像缓存滞留累积**。
- **裁决：4.7 = FAIL（按 release 实测判）**，责任标注「待真机裁决」：真机数字因 MIUI「USB 安装」开关未取得（`out/metrics_r1_realdevice.json` 缺失，脚本按真实退出码记 4.7 FAIL，不作 MANUAL、不当作通过）。第 2 轮路径：用户开启 USB 安装后跑 `test/batch/run_realdevice.py`（钉死 1e01895d）取真机数字重判；或 ml-porting 直接压掉 ~40MB 瞬时滞留（图像缓存/ORT arena 收尾释放）。

## 防作弊巡查：**1 条自动化命中，人工裁定为误报**（其余清白）

1. `git diff baseline-p4..HEAD` 受保护路径（test/ tools/gate/ ACCEPTANCE/RUBRIC）：**0 变更**。四笔修复提交越界检查：b24ccbd（CONTRACTS+core+main+charset_scan，主会话合法）、851d89a（matting+native/bench，ml-porting 合法）、474036a（lib/ui+charset_scan，ui-woodcraft 合法，charset_scan 系主会话放行文件）、b2cb15d（controller.dart，主会话合法）。工作区未提交变更：lib/core/imaging 2 文件 + dev_repro_g4.dart（imaging 势力范围，r2 测量前已落地，时间戳核实 19:38 < 测量 01:34，合法）、PITFALLS 追加 79 行（只追加，核实无删改）。
2. gate 脚本 SHA256：除本人本轮新增/修改的 gate_G4.dart 外全部一致。
3. `skip:`/`@Skip`/skip tag：test/、integration_test/ 均 0 命中。
4. 黄金集 src 8 / ref 8，与上轮快照一致，无增删。
5. `catch (_) {}` 空实现：**命中 1 处** —— `test/adversarial/adversarial_runner.dart:189`。人工核查上下文：该 catch 包的是**诊断用 alpha PNG 工件导出**（可选 side-path），被测的 matting/detectFace/compose 均有独立 try/catch 且错误逐条记入 rec；崩溃判定依赖 done marker + logcat，不经过这条 catch。**不构成 ACCEPTANCE #5「吞异常让 0 崩溃成立」**——裁定为工装卫生问题（导出失败应记日志），回派 adversarial 自行修复，不计违规。下轮 AC.5 检查将白名单"工件导出 side-path"类命中（gatekeeper 工装修订，非放行违规）。
6. 报告数字与 `out/gate_G4.json` 逐项一致（本轮 4.5 总分 10.0/致命 0/PASS 由脚本机读 `out/VISUAL_G4_r1.md` 核实）。

## 通过项（13/16）

| 项 | 结果 | 关键数字 |
|---|---|---|
| AC.1/2/3/4/6 | PASS | 见防作弊巡查 |
| 4.1 崩溃/ANR | PASS | 裁判 80/80 跑完 crashes=0 anrs=0（6 份 logcat 全扫）；gate 抽查 8 项复跑全部与裁判一致 |
| 4.2 人像成功率 | PASS | 裁判 14/14 ok 且候选>0；gate 抽查人像子项 ready 且候选全部可解码 |
| 4.4 对抗用例 | PASS | 裁判 59 用例 0 崩溃 / 0 数据损坏（q06 经 b2cb15d 修复，r2 复验 20/20）/ 0 无响应>5s（q04/q05/q09 系批量累计耗时口径，裁判分析单操作≤4.0s）；gate 抽查 3 个对抗用例复跑全部落定 |
| 4.5 视觉评分 | PASS | visual-critic 10.0/10，致命项 0，结论 PASS（机读） |
| 4.6 抠图耗时 | PASS | release 口径 p95=750ms(n=25)；gate debug 复测 p95=981ms；均 ≤1500 |
| 4.8 内存泄漏 | PASS | release Δ=60.6MB（280.8→341.4）；gate profile 复测 Δ=75.7MB；均 ≤80 |
| 4.9 无遗留 TODO | PASS | lib/ 全部 .dart 计数 = 0（gate 直接 grep） |

## 失败项（3）

| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| 4.3 非人像优雅 | 66/66 中文提示、不崩溃、**不产出诡异结果** | 65/66 合规（45 优雅失败 + 21 NoFace 契约 hint+候选，中文 100%）；**item 60 电路板截图 6 底色候选均为碎片状诡异拼贴**（`out/grid_r2_watchpoints.png` 末行，gatekeeper 目视裁决；qa-batch r1 报告同判"碎片状诡异"，r2 无变化；r1/r2 网格 `out/grid_r1_nonportrait_weird.png`） | ml-porting（MODNet 对任意图强抠主体、alpha 碎片未设完整性门槛） |
| 4.7 峰值内存 | ≤450MB | **release 487.5MB**（floor 340 达标，超阈来自后段 +135MB 瞬时滞留，峰值点在 638B 输入上；debug 563.1 作参考）；真机数字缺失（用户侧 USB 安装开关） | ml-porting（瞬时滞留：图像缓存/ORT 资源收尾释放）；主会话（真机补测通道待用户解锁，第 2 轮重判依据） |
| AC.5 catch-all 扫描 | 0 命中 | 1 命中（adversarial_runner.dart:189，诊断工件导出 side-path） | adversarial（工装卫生，人工裁定不构成 ACCEPTANCE #5 违规，见巡查第 5 条） |

## 回派指令

- **ml-porting**：(a) 4.3 item 60 —— 增加前景完整性/碎片化门槛，碎片状 alpha 走优雅失败（"抠图失败了，换一张试试吧"），不许产出碎片候选；(b) 4.7 —— 压掉批量后段 ~40-135MB 瞬时滞留（候选图像缓存上界、ORT arena/资源在 item 间收尾），目标 release 模拟器全量 batch 峰值 ≤450MB（留真机余量）。
- **adversarial**：adversarial_runner.dart:189 的空 catch 改为记录失败（不得吞掉诊断工件导出错误）。
- **主会话**：4.7 第 2 轮重判需要真机数字 —— 请转达用户在小米 12 上开启 开发者选项 → USB 安装，然后 qa-batch 重跑 `test/batch/run_realdevice.py`（产出 `out/metrics_r1_realdevice.json`）。在此之前 4.7 保持 FAIL。
- 无需回派：4.1/4.2/4.4/4.5/4.6/4.8/4.9 全部达标。

## 轮次状态

第 1 轮 FAIL（4.3、4.7 两项实质不达标 + AC.5 工装卫生命中）。剩余预算 2 轮。未触发终止。
