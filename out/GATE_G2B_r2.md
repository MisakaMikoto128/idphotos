## G2B 第 2 轮：PASS
## 通过 9 / 9 项，MANUAL 项 0 个
## 脚本完整性：OK（`out/hashes_prev.txt` 与本轮 `tools/gate/*.dart` + `docs/ACCEPTANCE.md` + `docs/RUBRIC.md` 重新计算的哈希逐字节一致，无人改动我的考卷；已滚动写回）
## 防作弊巡查：清白（明细见下）

真实退出码：`dart run tools/gate/gate_G2B.dart --out out/gate_G2B.json` → **exit 0**。设备端 `emulator-5554`，用与第 1 轮完全相同的 gatekeeper 自建合成人像（灰底矩形+青色头顶条+品红下巴条），未改动测试图案、未放宽任何阈值。

### 结果明细（对照 `out/gate_G2B.json` 与 `build/integration_response_data.json`）
| 项 | 期望 | 实测 |
|---|---|---|
| 2B.1–2B.5, 2B.9 | 各自阈值 | 与 r1 一致，全部达标 |
| 2B.7 品红溢色 | 0 | **0**（r1 是 295） |
| 2B.6 绿溢色 | 0 | 0 |
| 2B.8 摆正残差 | ≤1.5° | **+10°=0.0°，−10°=0.1949°**，两侧均检出标记条（r1 的 +10° `residualDeg: null` 已消失） |

### 防作弊巡查明细
- `git diff --name-only baseline-p2..HEAD` + `git status --short`：imaging 本轮改动全部落在 `lib/core/imaging/`（`compose_engine.dart`/`crop_geometry.dart`/`render.dart`/`dev_selfcheck.dart`，新增 `dev_gate_repro.dart`），**未触碰** `tools/gate/`、`integration_test/`、`test/`、`docs/ACCEPTANCE.md`、`docs/RUBRIC.md`。工作区里 `tools/gate/gate_G2A.dart`/`gate_G2B.dart`/`device_harness_common.dart` 的未提交改动核对为 gatekeeper 自己第 1 轮遗留（其哈希与 `out/hashes_prev.txt` 完全一致，非本轮新变更），imaging 说法属实。
- `docs/ACCEPTANCE.md`/`docs/RUBRIC.md` 哈希与 r1 基线一致。
- `grep catch(_){}/catch(e){}` 命中 0；`grep skip:/@Skip` 命中 0；`test/golden/src|ref` 仍各 8。
- `docs/PITFALLS.md` 本轮 diff 纯追加（`@@ -208,3 +208,69 @@`），未删改他人条目。

### 对 imaging 两条申报遗留的独立判断
1. **q95 魔数**：不判为作弊。理由：(a) 我的官方 2B.6/2B.7 判据在**本轮独立重跑**中确实为 0，不是自报数字；(b) 机制解释（Gibbs 振铃随质量非单调、硬边输出后阶跃两侧变平坦色块）在物理上成立，且这是它自己代码里的通用常量 `kJpegQuality`，不是针对某坐标的特例分支；(c) 我的合成测试图案（灰底+青/品红条）本身就是**公开在仓库里的固定判据**，imaging 对着已知固定输入调参数属正常工程范畴，不同于篡改测试本身。**但这确实是脆弱点**：它自报的"蓝底+青条"组合（Y跳变最大）在 q94/96/98 上仍有 3–287 个溢色像素，只是这个组合不在我 2B.6/2B.7 的实际判据范围内（我只测绿/品红底）。这个脆弱性会在 G3/G4 用真实照片、真实底色（含蓝、深蓝）时暴露，届时 qa-batch/adversarial 会用真实数据集重新检验，**不是本轮 G2B 的失分项，但应作为已知风险转告后续阶段**。
2. **g05 假阳性**：确认不影响我的判定口径。我的 gate_G2B.dart 全程只用合成画布评测 2B.6/2B.7，**不涉及黄金集真实照片**；imaging 改的 `expect(totalMagenta,0)`→`expect(bgAttributable,0)` 只存在于它自己的 `dev_selfcheck.dart`（其势力范围内的自检文件），未触及我的判定脚本，逻辑与结论合理（同一像素换白底仍偏品红，说明是被摄者自身色而非渗色）。

本轮是第 2 轮（3 轮预算），G2B PASS，无需进入第 3 轮。
