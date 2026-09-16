# GATE G4 — 第 2 轮（2026-09-15）

## G4 第 2 轮：**FAIL**

- 通过 **13 / 15** 项（AC.1–AC.6 六项防作弊 + 4.1/4.2/4.3/4.4/4.5/4.6/4.9），MANUAL 项 **0** 个
- 失败项 **2** 个：**4.7（实质性 FAIL）**、**4.8（gate 复测数据缺失，裁判双口径 PASS）**
- **真实退出码：1**（最终机读结果 `out/gate_G4.json` = 第 11 次尝试的完整输出）
- 本轮是第 **2** 轮 / 3 轮预算。未触发终止。

## 执行经过（环境严重劣化，如实报）

设备阶段共尝试 11 次，其间 **qemu 宿主进程崩溃 6 次**（`out/GATE_G4_emu_console.log` 均有
crashreport 记录；PITFALLS 已确认本机 host GPU 驱动栈 9 月 8 日起损坏，`-gpu guest`
软渲染只是 workaround，qemu 仍在随机死亡）。完整的测量轮：

| 尝试 | spotcheck | memcheck | 备注 |
|---|---|---|---|
| 第 4 次 | **13 项全过，与裁判一致**；对抗 8 例全落定 | 完成，但 host 窗口算法 Δ=296.9MB（假 Δ，见 4.8） | 设备侧 RSS 数据当时未落盘 |
| 第 10 次 | 12 项全过；4.6 gate 复测 p95=**1429.0ms 达标** | 模拟器在 memcheck 启动前死亡 | |
| 第 11 次（最终 JSON） | **13 项全过**；对抗 8 例全落定 | 模拟器濒死：4.6 复测 p95=3363ms 后崩溃 | 该 3363 为劣化末态，非有效测量 |

有效裁决以"健康会话"测量为准（判定依据逐条注明）；最终 JSON 保留第 11 次原始输出作机读留痕。

## 脚本完整性

- `out/hashes_prev.txt` 对照：`docs/ACCEPTANCE.md` 哈希变化 = 提交 `520650d`（4.7 阈值
  450→550MB，人工授权），diff 仅 4.7 一行，AC.6 自动溯源 + 人工复核 `git show 520650d` 属实。**放行**。
- `tools/gate/gate_G4.dart`、`tools/gate/device_harness_common.dart` 哈希变化 = **gatekeeper 本轮修订**
  （判定口径对齐两处授权修订 + 工装修复，见下），AC.2 记注记不判 FAIL。
- 其余 12 个脚本与 RUBRIC.md 哈希逐字节一致。hashes 已滚动。

### 本轮工装变更（全部 gatekeeper 势力范围，未放宽任何 ACCEPTANCE 阈值）

1. 4.6/4.7 判定源对齐授权口径：4.6 = 模拟器设备端（真机数字只作参考）；4.7 = 真机优先（≤550MB），gate 自己的模拟器复测对 4.7 降为参考注记（模拟器 floor 被 ORT bug 锁死，修订记录已认定其固有超阈）。
2. AC.5 白名单 r1 裁定项：`adversarial_runner.dart:189` 紧跟工件导出（writeAsBytes）行的空 catch（精确匹配，其余空 catch 仍 FAIL）。
3. AC.1 对 ACCEPTANCE/RUBRIC 的哈希变化改由 AC.6 溯源，消除授权修订误报。
4. 针对性对抗补测：`kTargetedAdversarialIds` 固定 5 例（c03/c05/c06/e09_lie_o6/m13）+ 随机 3 例，覆盖 adversarial r2（02:50）之后落地的代码变更面（301434f 人脸门槛、imaging 池化/回退、08144ab 解码路径）。
5. push 证据制修复：adb push 失败时仍打 "1 file pushed" 噪声行且设备端存在 root 属主遗留目录（`g4_spot` 为 root:root，13:49 某 root adbd 会话所建）——改为设备端 stat 大小校验 + 可写探针 + 探针失败才走 `adb root` 深清理（G4 设备选择已钉死 emulator-*）。
6. 4.8 gate 复测改用 harness 设备侧直测（/proc/self/status VmRSS 前后各一次），host dumpsys 窗口算法（r1 引入）降为参考——后者在采样节奏波动时会错位出假 Δ（本轮实测 296.9MB，同代码 qa-batch r7 为 -7.4MB，矛盾）。

## 4.7 裁决（原 FAIL 项，本轮实质 FAIL）

- **修订合规性**：合规。人工授权在案（用户明示"实在压缩不了可以放松一小点"），证据链（r2–r6 五轮）
  写入修订记录，提交 `520650d` 主会话执行，AC.6 溯源通过。**但授权不改变判定义务**——阈值 550
  仍须以诚实测量对照。
- **裁判数据质量独立复核**：`out/metrics_r1_realdevice.json` v7 的 4.7 = **单条目**测量
  （`run_realdevice.py` 第 3 阶段只跑 4958×7017 扫描件一条，非全量 batch；`rd_batch_bigitem.json`
  为空，无条目结果落盘）。该条目是 landscape，模拟器 r7 上它是 455ms 快速 NoFace 条目，
  **不产出峰值工况**。产生峰值的 workload（3 张 4032×3024 multi_face + 11 人像，模拟器 r7
  batch 峰值 613.3 就落在这类条目上）在真机上**只有 4.8 churn 相位测过**。
- **同一台 vivo、1s 采样、覆盖全部 14 人像/多脸条目的 churn 相位实测**：瞬态峰 **615.1MB**
  （G4_8_leak.peak_during_mb），>540MB 的采样点 12+ 个——系统性瞬态，非孤点。且 batch 相位
  floor 读数 184.1 与同机 churn 稳态基线 489.1 互相矛盾，4 样本无法为峰值作证。
- **qa-batch 申报的"上界估计 ~380MB"不成立**：它假设 batch 瞬态 ≈ 模拟器级（~130MB），
  但同一文件里同 workload 类的实测瞬态就是 615.1MB——这是**下界**而非上界。
- **裁决：4.7 = FAIL**。按"就高不就低"，真机侧最可靠、覆盖峰值工况的实测 615.1MB > 550MB。
  （参考：模拟器 r7 batch 峰值 613.3MB，floor 固有，修订记录已定为参考口径。）
- 责任：ml-porting（multi_face 条目 ~130-140MB 瞬态）+ qa-batch（真机 4.7 测量覆盖面）。

## 4.8 裁决

- 裁判双口径 PASS：真机 Δ=-17.7MB（1s 采样，全项目最密）、模拟器 r7 Δ=-7.4MB；四轮 Δ 序列
  与代码回归/回退史完全同向，交叉验证成立。**无泄漏的证据是扎实的。**
- gate 自己的复测两轮均未取得干净数据：run 4 host 窗口假 Δ=296.9（算法错位），run 10b/11
  模拟器在 memcheck 前死亡。按"缺数据 = FAIL，不许当作通过"：**4.8 = FAIL（仅因 gate 复测
  数据缺失）**。环境修复后 gatekeeper 单独重测 memcheck 一项即可裁决，无需回派实现类。

## 通过项（13/15）

| 项 | 结果 | 关键数字 |
|---|---|---|
| AC.1–AC.6 | PASS | 见下防作弊巡查 |
| 4.1 崩溃/ANR | PASS | 裁判 80/80（6 份 logcat 全扫 0 崩 0 ANR）；gate 13 项抽查复跑全部一致（run 11，run 4 同结论） |
| 4.2 人像成功率 | PASS | 裁判 14/14 ok 且候选>0；gate 人像子项全部 ready 且候选可解码 |
| 4.3 非人像优雅 | PASS | **66/66 graceful_fail + 中文 100% + weird=0**；原 item 60（电路板）现走 NoFace 优雅失败（0 候选），人脸门槛修复生效；gate 抽查非人像子项全部落定于契约终态 |
| 4.4 对抗用例 | PASS | 裁判 59 用例三计数=0（r1）+ r2 序列复验（b2cb15d 后 20/20）；gate 在 HEAD 上复跑 8 例 = 3 随机 + **5 针对性**（c03/c05/c06/e09_lie_o6/m13，覆盖人脸门槛/池化/解码变更面），无崩溃全部落定 |
| 4.5 视觉评分 | PASS | visual-critic 10.0/10、致命 0、PASS（机读）；其后的 474036a 六项修复经 diff 审计为交互/健壮性（无任何颜色/字号/间距常量改动） |
| 4.6 抠图耗时 | PASS | 裁判（授权口径=模拟器）p95=761.4ms(n=25) 达标；gate 健康会话复测 p95=1198.0ms（run 4）、1429.0ms（run 10b）均 ≤1500；run 11 的 3363ms 为模拟器濒死末态，不作数（如报告注记，非隐匿） |
| 4.9 无遗留 TODO | PASS | lib/ 计数 = 0 |

## 防作弊巡查：清白（1 条 r1 裁定维持，1 条流程越界需主会话裁定）

1. `git diff baseline-p4..HEAD`：受保护路径（test/、tools/gate/、ACCEPTANCE、RUBRIC）中
   实现类 agent **0 越界**。ACCEPTANCE 变化 = 授权提交 520650d（溯源见 AC.6）。
   裁判类 test/batch、test/adversarial 本轮 0 变更。PITFALLS 只追加（297 行，0 删改）。
2. gate 脚本哈希变化均为 gatekeeper 本轮修订（AC.2 注记 + 本报告披露）。
3. skip/`@Skip`：0 命中。黄金集 src 8 / ref 8 未减。
4. AC.5：r1 裁定的工件导出 side-path 白名单命中 1 处（adversarial_runner.dart:189，
   adversarial 未改动该文件），维持误报裁定并已在脚本内精确化。其余 0 命中。
5. **流程越界 1 条（不属 6 条防作弊，但属宪法 §4/§6 领土规则）**：提交 `08144ab`（ml-porting）
   直接修改了 `pubspec.yaml`（+`ffi: ^2.1.0` 显式声明，原为传递依赖）与 `pubspec.lock`。
   pubspec.yaml 归主会话独占，宪法 §7.5 要求走报告申请。内容本身无网络/无新 SDK/无技术栈
   变更（ffi 早已在依赖树内），不构成 ACCEPTANCE 六条之一直接 FAIL，**交主会话追认或回退**。
6. 报告数字与 `out/gate_G4.json` 一致（本文所有数字均可在 JSON/裁判文件中复核）。

## 回派指令

- **ml-porting**：4.7 —— multi_face/大图条目的瞬态工作集（~130-140MB）叠加稳态 floor 后真机
  端 ≥615MB。目标：瞬态增量压到 floor+瞬态 ≤550MB 留真机余量，或证明可稳定低于。
- **qa-batch**：4.7 —— 真机 4.7 测量必须覆盖峰值工况：用全自动 runner 在 vivo 跑**全量 80 项
  batch**（不是单条目），采样改用 App 侧 VmHWM（/proc/self/status，logcat 通道上报，
  不受 dumpsys 饿死影响），产出可信的设备端 batch 峰值。若 ≤550 且采样可信，4.7 第 3 轮可 PASS。
- **主会话**（GPU 修复，用户已指示派专项 sub agent）：见下方"GPU 修复派单规格"。
- **gatekeeper 自留**：环境修复后单独重跑 memcheck（4.8 gate 复测）+ 4.6 健康会话复测。

## GPU 修复派单规格（给主会话，用户要求派 sub agent；与 gatekeeper 零冲突）

- **事实基线**（docs/PITFALLS.md 两条 [gatekeeper] 条目）：host GPU 驱动栈 9/8 起 GL/Vulkan
  全废（minidump：`Failed to make GLES 2.x context current` → `vkGetDeviceQueue: Invalid device`）；
  现行 workaround = `-gpu guest -feature -Vulkan --no-window` + `--no-enable-impeller`。
  今日 qemu 又崩 6 次（crash DB：%TEMP%\AndroidEmulator\emu-crash-33.1.24.db）。
- **调研步骤**：`wmic path win32_VideoController get name,driverversion` / dxdiag 导出；
  事件查看器 System 日志查 Display 驱动 TDR（nvlddmkm 超时等）；crash DB minidump 用
  windbg/who_crashed 看 faulting module 是否落在显卡驱动；确认 AGP/AEHD 与驱动版本兼容性。
- **修复路径**：干净重装/回退显卡驱动（DDU 安全模式最佳）；验证标准 = `emulator -gpu host`
  能存活 ≥10 分钟 + 无 TDR 事件。
- **领土约束（防冲突）**：修复 agent **不得**改 `tools/gate/`、`integration_test/`、`test/`、
  `docs/ACCEPTANCE.md/RUBRIC.md`、`lib/`；调研结论追加 `docs/PITFALLS.md` 并报告。
  驱动修好、验证通过后，由 **gatekeeper**（而非修复 agent）移除 gate 脚本里的软渲染 workaround。
- **时序**：驱动安装可能需要重启 = 会杀掉我正在跑的模拟器测量；请在本轮 G4 报告归档后
  （或与本轮错开）再执行重启类操作。

## 轮次状态

第 2 轮 FAIL（4.7 实质不达标；4.8 gate 复测数据缺失——裁判双口径 PASS）。剩余预算 **1** 轮。
未触发终止。
