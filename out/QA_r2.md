# QA_r2 —— P0 摆正事故 第二轮复测（qa-batch）

- 日期：2026-09-17
- 基线 tag：`baseline-p6p0-r2`
- 被测指纹：**`0f66aabb3c08105f`**（`lib/**.dart` 67 + `test/batch/**.{dart,py}` 36 = 103 文件，FNV-1a 64）
- 全程 `codeStableDuringRun: true` / `changedFiles: []` / `roundValid: true`（HEAD 因他人提交移动过 5 次：72e1a67 → 8adff7e → 7d72195 → 9c82125 → dcc5903，被测域无变化）
- 本轮**沿用上一轮的旋转夹具**，未重新生成（见 §5 一致性证据）
- 本文件只报**可复现的具体问题**，不含 PASS/FAIL —— 判定权在 gatekeeper。所有数字为实跑。

---

## 1. 链条执行（13 步，全部 exit 0）

| # | 步骤 | 产物 | 结果 |
|---|---|---|---|
| 1 | `p0_resolve_check.dart` | — | ok |
| 2 | `p0_compose_test.dart` | `out/P0_compose_items.jsonl`、`out/P0_compose_summary.json` | 110/110 |
| — | **括号 1**：成片存在性 | `p0_provenance_check.py after-compose` | **exit 0**，110/110 成片在盘上（行 110，去重 id 100） |
| 3 | `p0_alpha_dump_test.dart` | `out/P0_alpha/` | 110 张，9 s |
| 4 | `p0_output_residual.py` | `out/P0_output_residual.json` | ok |
| 5 | `p0_alpha_scan_test.dart` | `out/P0_alpha_scan/` | 110 张，46 s |
| 6 | `p0_alpha_holes.py` | `out/P0_alpha_holes.json` | ok |
| 7 | `p0_selfcheck_run.dart` | `out/P0_selfcheck_provenance.json` | `sameCodeStateAsCompose: true` |
| 8 | `p0_coverage_test.dart` | `out/P0_coverage_post.json` | **实测 2:44**（`02:44 +1: All tests passed!`） |
| — | **括号 2**：`p0_provenance_check.py after-coverage` | | **exit 0**，5 项检查 OK，110/110 |
| 9 | `p0_verify_geo.py` | `out/P0_anchors/fixture_geo_verify.json` | 78 夹具，无引擎 |
| 10 | `p0_finalize_v1.py --strict` | `out/P0_truth.json` | 写出 |
| — | **括号 3**：`p0_provenance_check.py final` | | **exit 0**，7 份产物 + 绑定复核全 OK |

链路曾被截断：`p0_alpha_holes.py`、`p0_alpha_scan_test.dart`、`p0_alpha_dump_test.dart` 在仓库内**零调用者**，不补进来 `P0_alpha_holes.json` 将无 provenance ⇒ `allBound=false` ⇒ 整轮作废。已作为第 3/5/6 步接入。

产物摘要：

| 产物 | sha256 |
|---|---|
| `P0_compose_items.jsonl` | `aea8b3cc9ab95f758e682a8661867e23e00dfc03f85e62e18433193b7cea0310` |
| `P0_compose_summary.json` | `94acef995ce3c6572cc26fd89b3e9692598df64936ce5078951cc4bf5f25676a` |
| `P0_output_residual.json` | `249a56ec358f9f5a53db1999fa2ab389b614bd8f2b7aaf2c7986005a6268c08d` |
| `P0_alpha_holes.json` | `67497012047ee0879d7fc41d8ecfeaceb518118e27ccd193b77dab2dd9a1a45f` |
| `P0_coverage_post.json` | `d8f7c61f3fa56663394582776003b6f7564d9664b30fc1917356b588aa645a04` |

## 2. 实测数字（供 gatekeeper 计分）

硬判据取自**成片端到端残余**（ACCEPTANCE 计分口径第 5 条）。

| 判据 | n | unavailable | 极值 | 违规 |
|---|---|---|---|---|
| P0.1a 锚点端到端残余 | 12 | 0 | absMax 0.575 / absMed 0.145 | 0 |
| P0.1b 锚点条件覆盖率 | 8 | 0 | — | 0 |
| P0.2 竖直合成残余 | 1 | 0 | absMax 0.21 | 0 |
| P0.3a 瞳孔夹具回归 | 70 | — | — | 0 |
| **P0.3b 夹具条件覆盖率** | **67** | **2** | — | **2：`c06_d-3`、`c08_d-10`**（`c06_d+3` 走 nearZeroExempt） |
| P0.4 滚转来源分布 | — | 4 | — | — |

分母口径：锚点栏原始 13 条 − `c03`/`c04` 真重复 = **11 张不同照片**；P0.3b 分母 67 = 78 夹具 − 11 条 `|expectedTiltDeg| ≤ 1.5` 豁免。

端到端覆盖率（`P0_coverage_post.json`，spec `cn_big_1inch` 390×567）：总 188，产出 **188/188**，faceDetected 122，noFace 53，rejected 13，**crash 0**。滚转来源：pupil 118 / none 66 / unavailable 4。

`P0_alpha_holes.json`：total 87，assessable 21，眼带空洞全部落在 c08 家族 4 条（`c08_d-10` 0.9677 / `c08_d-5` 0.7549 / `c08_upright` 0.6193 / `c08_d+3` 0.5277）。**这与 P0.3b 的 `c08_d-10` 违规是同一张图上的两个独立信号**，互相印证。

## 3. `alphaHoleHint`：已解释 + 假阳实例

1. **已解释（几何混淆，假阳的根因）。** `p0_output_residual.py:220-252` 用固定矩形 `x∈[0.12W,0.88W]`、`y∈[0.06H,0.72H]`（= 图面积 50.2%）判空洞，**从不检查该矩形内是否真有头**，阈值 `frac > 0.05`。典型背景占比 0.65 ⇒ 干净人脸被算术判成空洞。同文件 `:223-225` 的 docstring 写的是「头顶 0.08H、头高 0.62H、水平居中」，与那四个常量不是同一套几何。
2. **假阳实例（复现：`out/P0_output_residual.json` 对应 id 的 `magentaInHeadFrac`）**：中心区 magenta `c04_d-10` 0.001、`c08` 0.000、`c11_d-10` 0.000 —— 全部被标记；真阳性 `c08_d-10` 0.569、`c08_upright` 0.280。同一判据既报真阳性也报 0.000 的假阳，不可用。
3. **另一条独立理由（gatekeeper 提供）**：`outOfBoundsFraction > 0` 在 110 行里占 77 行（70%，最大 43.5%），而越界区域**按设计填 alpha=0** ⇒ 成片端 alpha=0 无法区分「设计留白」与「抠图失败」。结论：**只有 `P0_alpha_holes.json`（干净原图侧）是可用的洞信号**。
4. 两条理由都属**咨询性质**：目前没有任何判据读 `alphaHoleHint`。

## 4. 待修（r3，均不在本轮改动）

| # | 位置 | 问题 | 责任 |
|---|---|---|---|
| 1 | `test/batch/p0_finalize_v1.py:574-588`（`evidenceProvenance` 块，`codeFingerprintOfSources` 在 `:581`） | `evidenceProvenance.codeFingerprintOfSources` **写死 `None`**，`note` 断言「这些产物**没有** `provenance` 字段」「估角器在 03:34 之后已改过 3 次」。**本轮起该断言已为假**：三份源产物（`P0_output_residual.json` `summary.provenance` 为继承、`P0_alpha_holes.json`、`P0_compose_summary.json`）**都带** `codeFingerprint = 0f66aabb3c08105f`。同一块里 `what` 的条数是现算的，唯独这个子块是写死的 —— 与我在别人产物里报的「硬编码叙述不随产物漂移」是同一类缺陷，出在我自己的生成器上。**未在本轮修**：改它会变更指纹、作废 r2。 | qa-batch |
| 2 | `test/batch/p0_output_residual.py:220-252` | 几何混淆的空洞判据 + 与 docstring 不符（见 §3.1） | qa-batch |
| 3 | `test/batch/p0_output_residual.py:44-52` | `_compose_provenance` docstring 称测量侧 Python「属于 `test/`」故在指纹域外 —— **两个方向都错**：36 个 `test/batch` 文件**在**域内；`test/gate`、`test/adversarial`、`docs`、`out` **不在**。 | qa-batch |
| 4 | `test/batch/p0_rotate.py:8` | 悬空引用 `rotation_calib.json`（文件不存在） | qa-batch |
| 5 | `out/P0_alpha_scan/` | 4 个 03:45/03:46 的陈旧文件未被 manifest 引用 | qa-batch |
| 6 | `p0_alpha_scan_test.dart` | manifest 无指纹字段 | qa-batch |
| 7 | `out/P0_anchors/` | 人看的产物与程序消费的输入混在同一目录（`c08.png` 是线描 overlay，曾被本测试误当测量输入，见 §6） | qa-batch |
| 8 | `p0_coverage_test.dart` | **流程失误（订正）**：我先前把此步定成「唯一零余量步骤」，依据是**我自己估的 ~85 min**，而超时上限恰好被设成同一个估时值（上限 = 估时 ⇒ 表面零余量）。实测 **2:44**，余量 **~31×**，与 `alpha_scan` 一样**根本不是风险**。该错误估时导致全队为它串行避让了很长时间（team-lead 为此停掉一切重活）。**教训**：不拿未实测的估算值定优先级；先跑一条最小子集实测再定。「上限 = 估时」本身即说明该估时没有实测支撑。 | qa-batch |

## 4b. `ds_portrait_37`：真实人像上估角器静默失效（**不构成违规，但单列**）

按 ACCEPTANCE:105「样本不得静默消失」单列 —— 它会被 `rollSourceDistribution` 的 `none (66)` / `unavailable (4)` 计数吞掉。

- 文件：`C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_21_Pro.jpg`（`test/dataset.json` 中 `class=portrait`，1272×716，`exif_orientation 1`）
- 读数（`out/P0_coverage_items.jsonl`）：`outcome: face`、`hasLandmarks: true`、`confidence 0.907`，但 **`rollSource: unavailable`、`rollDeg: 0.0`**
- **为何不入判据**：P0.1b 只统计锚点、P0.3b 只统计旋转夹具；本行 `corpus=pictures`，不在任何分母内。故 **不计违规**。
- **隐患（接口层，非本测试）**：`rollDeg: 0.0` 与「实测为 0°」在数据上不可区分 —— 只读 `rollDeg` 不查 `rollSource` 的消费者会把「没测出来」当成「正立」。本轮无判据如此读。
- **不是小脸/分辨率问题（已实测证伪）**：该脸框 **304×384 = 117,073 px**，**大于**多条估角成功的真实人像 —— `ds_portrait_32` 148×178 = 26,344、`ds_portrait_27` 178×240 = 42,720、`ds_portrait_6` 261×338 = 88,218；处于成功组面积中位数（117,735）水平。故失败来自眼部区域内容本身，不是脸太小。
- **与锚点 c08 是同一次拍摄的相邻帧**：`..._00_19_21_Pro.jpg`（1272×716）与 **c08** = `..._00_19_11_Pro.jpg`（1280×720）相隔 10 秒（00:19:11 / 00:19:21）。至此 c08 这一被摄者/session 上汇集了三条读数：① `P0_alpha_holes` 的 4 条眼带空洞**全部**在 c08 家族；② P0.3b 违规之一 `c08_d-10`；③ 本条整帧估角 dropout。①与②可能同根因，但读数来自独立测量路径（alpha 通道扫描 vs 滚转残余）。综合指向**被摄者/session 特异**，而非「旋转夹具伪影」。

## 5. 夹具沿用（未重生成）及其一致性证据

本轮**未重新生成**旋转夹具（`p0_rotate.py` 按 team-lead 裁定出范围）。改用与瞳孔法完全无关的第二读数做交叉验证：`p0_verify_geo.py` 用 cv2 像素级旋转配准（NCC 在 phi 上取极大），**不调引擎、不用特征检测器**，输出 `out/P0_anchors/fixture_geo_verify.json`：

- 78 夹具 = **13 个源 id × 6 个 delta**（−10/−5/−3/+3/+5/+10°），无缺失
- 残差 `|recoveredPhiDeg + deltaDeg|`：max **0.01500**、median **0.00400**；4 条恰在 0.0150（未超过阈值）
- NCC：min **0.9985**、median **0.9991**，无一条低于 1.0 的异常
- 结论：沿用夹具与上一轮一致到 ±0.015° 以内；夹具不是本轮差异的来源

**字节级重跑证据**：`out/P0_alpha_scan/` 下 **8 个** `_magenta.jpg` 的 mtime 为 **07:39:54 – 07:40:15**（`WIN_20230522_00_19_11_Pro` 07:39:54、`WIN_20230522_00_19_21_Pro` 07:39:56、`c08_d-3` 07:40:11、`c08_d-5` 07:40:13、`c08_d-10` 07:40:14、`c08_d+3` 07:40:08、`c08_d+5` 07:40:09、`c08_upright` 07:40:15）。
（订正：先前转述的「3 个 07:37–07:38」不准确，实际为 8 个、07:39:54–07:40:15。)

## 6. 本轮修掉的两处（供回溯）

- `test/batch/p0_cases.dart`：`buildCases` 无条件 `out.add(...)` 导致 p2 重复（101 行 / 100 id，因 `p0_finalize_v1.py:906-911` 把 `straight[0]` 也塞进 `anchors`）。改为按 id 去重的 Map。**核实**：消费者 `p0_compose_test.dart:108-110` 本就按 id 建 Map，重复从未落盘 —— 盘上 `summary.cases: 100` 佐证。故这是潜在契约缺陷，**不是**当时被报的「跑不动」。
- `test/batch/p0_alpha_dump_test.dart`：`kIds` 里的 `c08` 在 `:70` 解析到 `out/P0_anchors/c08.png` —— **线描 overlay**，被当测量输入喂进 `removeBackground`。加 `_cleanSource()` 从 `out/P0_truth.json` 的 `anchors`/`straight` 取原始路径。修后 `c08` 的 `alphaHoleHint` 由 `magentaInHeadFrac 0.7878 / largestBlobPx 87453` 变为 **0.3446 / 36579**（overlay 曾把该值抬高 2.3×）。日志已确认 `SRC c08 <- C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg`。主链核查干净：真值锚点直接取 `Pictures/` 原图，`p0_rotate.py:74` 取 `anchors_base.json`，同为原图。

## 7. 越界面积中位数：已决（**5.31% 为准**）

gatekeeper 复核后确认 **其报的 5.6% 作废**，成因不是子集也不是截断，而是**偶数 n 的中位数写法** `sorted(v)[len(v)//2]` —— n=110 时取 `sorted[55]`（第 56 个值），而偶数 n 的真中位数是两个中间值的平均。

| 口径 | 值 |
|---|---|
| **真中位（中间两值平均）** | **5.3136%** ← 本文件采用 |
| `sorted[n//2]`（gatekeeper 原报） | 5.6036% ← 作废 |
| `sorted[(n-1)//2]` | 5.0237% |
| 均值（全 110） | 10.4303% |

我的另两个变体经对方逐位复算一致：仅正值 77 条中位 **12.7381%**、仅 `cn_big_1inch` 100 条中位 **3.1794%**。越界填充那条论据**不依赖**本数（依赖 `>0` 的 77/110 = 70% 与 max 43.5%），结论不变。

三路互核逐字段一致（我 finalize 写、gatekeeper 从清单算、team-lead 从产物算）：
- `P0.3b_fixtureConditionalCoverage` = `{n: 67, unavailable: 2, culprits: [c06_d-3, c08_d-10], nearZeroExempt: [c06_d+3]}`
- `P0.1b_anchorConditionalCoverage` = `{n: 8, unavailable: 0, culprits: []}`
- 分母 75 = 67 + 8 中那 8 条锚点 = `c03, c04, c05, c06, c08, c10, c12, p1`（`|trueRollDeg| > 1.5`）

### 7b. 同型排查：`sorted(v)[len(v)//2]` 在本仓还是**模式**，不止一处（r3）

- **r2 已报的分数中位数不受影响**：live 路径用的是正确实现 —— `p0_finalize_v1.py:240`、`p0_output_residual.py:339`、`p0_lib.py:232` 用 `np.median`，`p0_est.py:57/61` 用 `statistics.median`。（P0.1a 的 `absMedian 0.145` 由 `np.median` 得出，**n=12 偶数也正确**。）
- **仍是 `//2]` 写法的 5 处**（均在我方 `test/batch/`）：`p0_measure.py:97`、`p0_finalize.py:217`、`p0_rotate.py:84`、`merge_results.py:285`、`run_realdevice.py:375/451`。
  - 其中 `merge_results.py:285` 与 `run_realdevice.py:375/451` 取的是**稳健基线/底线**（`baseline_mb`、`floor`），偏差被采样噪声（该处记录为 ±60MB 量级）覆盖，**非分数项**；
  - `p0_rotate.py:84` 的输入是 7 个旋转（**奇数**）——**本就正确**；
  - `p0_measure.py:97` / `p0_finalize.py:217` 属 r1 期脚本，已被 `p0_finalize_v1.py` 取代。
- **正确实现已经在仓里**：`p0_c08_sensitivity.py:318` 就是「奇数取中、偶数取两中值平均」。故这是**复制粘贴分叉**，不是没人会写。
- 另：`native/bench/ml_release_memcheck.py:312` 的 `p50_ms` 用同一写法（ml-porting 范围）。**p50 与 median 在偶数 n 上定义不同**（nearest-rank 与线性插值），该数若要对着阈值判，口径需写明。

**r3 动作**：抽一个共享 `median()`（以 `p0_c08_sensitivity.py:318` 为准）替换上述位置，并在字段名或 docstring 里写明每个数字的口径（median / nearest-rank p50 / 基线样本）。**本轮不改**：`test/batch/` 在指纹域内，改动会变更 `0f66aabb3c08105f`、作废 r2。
