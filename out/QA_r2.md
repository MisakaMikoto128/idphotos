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
| P0.2 竖直残余（`p2` + 9 `uprightSynthetic`） | **10** | 0（1 条 notScorable，已单列于 §2.1） | `output_tilt_deg`（qa 量具实测）残余 absMax **0.290**（`c10_upright`；`p2` 0.210） | 0 |
| P0.3a 瞳孔夹具回归 | 70 | — | — | 0 |
| **P0.3b 夹具条件覆盖率** | **67** | **2** | — | **2：`c06_d-3`、`c08_d-10`**（`c06_d+3` 走 nearZeroExempt） |
| P0.4 滚转来源分布 | — | 4 | — | — |

分母口径：锚点栏原始 13 条 − `c03`/`c04` 真重复 = **11 张不同照片**；P0.3b 分母 67 = 78 夹具 − 11 条 `|expectedTiltDeg| ≤ 1.5` 豁免。

### 2.1 P0.2 逐条清单（分母 10，按 ACCEPTANCE:105 不得有样本静默消失）

构成为 `ACCEPTANCE.md:73` 写死的 **10 条** = 用户 `2.jpg`（即 `p2`）1 条 + 合成竖直 9 条。逐条列出，残余 = `output_tilt_deg`（**qa 量具在成片上的实测倾角**，见 §2.3）与「摆正后应为 0」之差。右两列是**引擎自报**（`out/P0_compose_items.jsonl`，spec `cn_big_1inch`），与本表的实测列**不同源**，并列仅供对账：

| id | `output_tilt_deg`（qa 量具实测） | 残余 | 引擎自报 `rollSource`/`straightenDeg` | `outOfBoundsFraction` |
|---|---|---|---|---|
| `p2`（用户 `2.jpg`，真值 −0.200） | −0.2099 | **0.210** | pupil / 0.0 | 0.021 |
| `p1_upright` | 0.0467 | 0.047 | pupil / 0.0 | 0.259 |
| `c01_upright` | −0.0817 | 0.082 | pupil / 0.0 | 0.159 |
| `c03_upright` | −0.2527 | 0.253 | pupil / 0.0 | 0.274 |
| `c04_upright` | −0.2438 | 0.244 | pupil / 0.0 | 0.270 |
| `c05_upright` | −0.0421 | 0.042 | pupil / 0.0 | **0.435** |
| `c06_upright` | −0.0557 | 0.056 | pupil / 0.0 | 0.000 |
| `c08_upright` | **null** | **notScorable**（见下） | pupil / 0.0 | 0.290 |
| `c10_upright` | 0.2899 | **0.290 ← 最大** | pupil / 0.0 | 0.078 |
| `c12_upright` | −0.1285 | 0.128 | pupil / 0.0 | 0.000 |

**引擎自报一列值得单说**：10 条**全部** `rollSource=pupil` + `straightenDeg=0.0`。即引擎在这 10 条上**一次也没旋转**（正确：真值全部落在死区 `|roll|≤1.5°`），也**从未自报失败**。注意 `c08_upright`：引擎报 `pupil`，而 qa 量具在同一张成片上 `no_pair`（无法测量）——**「引擎自报成功」与「测量侧可测」是两件事**，`rollSource` 单独看不构成可用性证明。`P0.2_allSamplesReturnedPupil`（`straight 1/1` + `uprightSynthetic 9/9`）与此一致。

`c08_upright` 单列，不静默消失：`end_to_end.output_tilt_deg = null`，原因是 `m1_pupil: {error: "no_pair"}`（`m2_radon_yunet` 给出 16.0 的越界值）。故可计分 9 条，最大残余 **0.290**。10 条全部 ≤1.5°，P0.2 无违规。

**口径对齐（已查清）**：gatekeeper 的 `out/gate_P0_r2.json` 里 P0.2 记的「max|残余| = 0.637」与上表**不是一个量具**，且其数值**已被根因解释**。

- 出处已由 team-lead 钉死：`out/GATE_P0_r2_eyeline.json` → `rows[17]` = `{"id":"c05_upright","path":".../c05_upright__cn_big_1inch.jpg","tilt_deg":0.6365935759634865,"truthTiltDeg":0.0}`。它**不是** `out/P0_truth.json` 的 `anchors[4]`（那是 `c04`，一个巧合，见 §2.2）。
- **根因不是串样本、也不是符号约定，是「亚像素量化」**（§2.2 有全量验证）：`0.6365935759634865` = `atan(1/90)`，对应 `dy=+1.0 px`，即我这支量具（**0.5 px 栅格**）的 **2 个量子**。同一条上 `c05_upright` 的 **qa 量具** `output_tilt_deg` 残余是 **0.042**（9 条里最小之一）。
- 因此本表用 qa 量具 `output_tilt_deg` 口径（与 P0.1a/P0.3b **同一量具**，见 §2.3），上界 **0.290**；**0.637 作为 gatekeeper `gate_eyeline` 量具的读数引用，不采纳**，更不与 0.290 取 max。两数均 ≤1.5°，**P0.2 维持 PASS**。
- 仍待指认：gatekeeper 称「`c08_upright` 由 SIFT 兜底」，但盘上该条 `m1_pupil` 为 `no_pair`、`m1h_pupil_haarseed` 与 `m3_haar_eyeline` 均为 `null` —— **未见兜底生效**。是没触发，还是写在别的字段？请指字段。**另注意量不同**：其 SIFT 量的是**施加角**，本表 `output_tilt` 量的是**成片绝对倾角**，两者仅在 `truth_apply_deg == 0` 时重合。

### 2.2 量具分辨率：`m3_haar_eyeline` 被**亚像素**量化，步长**逐样本** `atan(0.5/dx)`（均值 0.333°）

对 `out/P0_output_residual.json` 里**全部 99 条** `m3_haar_eyeline` 记录做验证（全量，非抽样）：

    deg == atan2(right.y - left.y, right.x - left.x)   —— 99/99 逐条成立，0 例外

- **坐标不是整数**（此处更正我先前的说法）：99 条里只有 **29 条**四坐标全为整数，**70 条含半像素**（如 `left [145.0,235.0] / right [240.5,235.5]`）。`dy` 实测**只取 0.5 的倍数**（15 个取值，`−7.5 … 3.5`）⇒ **量子 q = 0.5 px，不是 1 px**。
- 因此**没有固定角步长**：`step = atan(0.5/dx)`，而 `dx` 有 **43 个不同取值、范围 39.5–102.0** ⇒ 步长**均 0.3330°、范围 0.2809–0.7252°**，**逐样本不同**。占阈值：**均 22.2%、最差 48.3%**。我曾把 "0.637°" 当成本批常数 —— **错**，那只是 `dy=1.0, dx=90` 这**一个栅格点**的值（且 99 条里有 **60 个不同角值**、**54 条落在 `0<|deg|<0.6366`**，在"0.637 常数栅格"上这些值根本不存在）。

这解释了两件先前看起来矛盾的事：

1. **「跨样本逐位相同」不是串样本**：`0.6365935759634865` 等于 `atan(1/90)`，即 `dy=+1.0, dx=90.0` 这个**栅格点**。我的 `c04`（实测 `dx=90.0, dy=+1.00`）与 gatekeeper 的 `c05_upright`（其坐标 `left[134.25,239.75] right[224.25,240.75]` ⇒ 同为 `dx=90, dy=+1.0`）**落在同一栅格点**，角度自然逐位相同。**角度是两点检测的纯函数，所以同值碰撞是必然、与图像内容无关。** 我也哈希过两边图片，sha256 各不相同 ⇒ 串样本已排除。
2. **「同图两量具符号相反」不是符号约定问题**：我 `c05_upright` 的**夹具侧** `measured m3 = +0.616`（反解 `dy=+1.00, dx=93`）与**成片侧** `end_to_end m3 = −0.6585`（实测 `dy=−1.00, dx=87`）—— **dy 差 2 px**，在定位噪声底。**team-lead 估的「差 1.29°」是按 0.637° 当常数步长推出来的，随该常数一并作废**；真实差异是两侧各约 2 个 0.5 px 量子。

**影响面（已界定，不动已报的分数）**：
- 本报告 §2/§2.1 的残余全部取自 **qa 量具 `output_tilt_deg`（主值 m1_pupil，见 §2.3）**，**不经 m3**，故 P0.2 的 **0.290**、P0.1a 的 **0.575/0.145**、P0.3b 的计数**均不受影响**。
- 但**含 m3 的统计会失真**：`tilt_abs_max_deg` / `method_spread_deg` 是**跨方法取 max/极差**，近竖直样本上它们测的是 **m3 的量子**而非样本 —— 例：`c04`(`anchors[4]`) 的 `tilt_abs_max_deg = 0.637`，而其 m1/m2/m4 均在 0.01–0.02 量级，即该 0.637 **完全来自 m3 的 2 个量子**。**r3 应排除量化方法或显式标注。**
- **判别力下限是逐样本的，不是"近零区间"一句**：步长 0.281–0.725°（眼距越小越粗，`dx=39.5` 那条达 **0.725°，接近阈值一半**）⇒ 与自身步长同量级的读数不可用，但**必须逐条标注**。对**大角度仍然有效**：`c06_d-3`（真值 −4.73°）位移 **成片 `dy=−7.50 px` / 夹具 `dy=−6.25 px`** ⇒ 是我方量子的 **12–15 倍**、是 gatekeeper 量具（0.25 px）的 **25–30 倍**，远超噪声底 ⇒ §4c 的引用不受影响。
- **【撤回】一条我先前的归属错误**：我曾写「gatekeeper 报的 0.637 恰好等于一个量化步长 ⇒ 那个数量的是**它自己量具的分辨率地板**」。**反了，我撤回。** `out/GATE_P0_r2_eyeline.json` 的 `dy` 取 **0.25 px 的倍数**（−0.75…1.75），`dx` 46 个取值、范围 62.0–100.5 ⇒ 其步长**均 0.1545°、范围 0.1425–0.2310°**，**比我这支（均 0.333°）细约一倍**；88 条里有 **66 个不同角值**。所以它的 0.637 是**可分辨的真实读数**（约 4 个它自己的步长），**不是它的分辨率地板**。
- 由此**结论方向不变、理由变了**：两支量具在同一张图上的近零读数**不能互为佐证** —— 不是因为谁粗，而是 (a) 角度是两点检测的纯函数、同值碰撞必然；(b) 近零处两个读数的差就是**各自 1–2 个量子**，谁也压不住谁。**把一支能分辨的量具说成不能分辨，会让真实读数被当噪声丢掉** —— 这比原来的错误更坏，故一并更正。

### 2.3 `*_tilt_deg` 与 `measuredTiltDeg.*` 的量具署名（**自查发现的一处误标**）

**结论**：`P0_truth.json` 里的 `output_tilt_deg` 与 `measuredTiltDeg.*` **不是引擎自报值**，而是 **qa-batch 自己的 Python 量具**（`test/batch/p0_lib.py`）对图像的实测值 —— 该库 docstring 明写「qa-batch：真值锚点测量库（**纯 Python，绝不调用被测 Dart 代码**）」。引擎的自报值只有 `rollSource` / `straightenDeg` / `outcome`，落在 `out/P0_compose_items.jsonl`（已作 §2.1 右两列并列）。

- `output_tilt_deg` 的定义见 `p0_output_residual.py:9`：「成片眼线的**实测倾角**，理想值 0」。主值按固定优先级取 `m1_pupil → m1h_pupil_haarseed → m3_haar_eyeline`（`:166-172`），再由 `p0_finalize_v1.py:889/925` 落到 `output_tilt_deg`。
- **回退链本轮未触发**：在有 `output_tilt_by_method` 的全部 **22** 条（13 锚点 + 9 合成竖直，除 `c08_upright`）中，主值**逐条等于 `m1_pupil`**，`m1h`/`m3` 一次都没有被选中 —— 即**没有量化值（m3）漏进任何主值**。
- **用词更正（我自己的错）**：本报告早先把该列写成「**引擎** `output_tilt`」，并在 §2/§2.1/§2.2 沿用。判据本身没错（在**成片**上量倾角正是端到端残余的正确口径），错的是**署名** —— 量它的是我的量具。全文已改为「qa 量具 `output_tilt_deg`」。**这与本项目反复出现的形状同型（名字宣称的口径 ≠ 实现给的口径），这次出在我的报告里。**
- 同理 `measuredTiltDeg.m1_pupil` **不是引擎读数**，而是 qa 量具的一个**独立变体**（与引擎同为「瞳孔/暗色圆盘」原理、不同实现）。它的名字容易被读成引擎的数 —— r3 应改名（如 `qa_m1_pupil`），或在产物里加 `methodProvenance` 段统一声明「凡 `measuredTiltDeg.*` 与 `output_tilt_by_method.*` 均为 qa-batch 独立量具」。
- **独立性要分层（team-lead 指出，我原来说得含糊）**：既然回退链未触发、主值逐条是 `m1_pupil`，那么 `output_tilt_deg` 这一列与引擎的独立性是「**实现不同**」（**同原理**：瞳孔/暗色圆盘），**不是「原理不同」**。因此它做门禁交叉复核时，与引擎只算同原理的第二种实现；**只有 gatekeeper 的 Haar 那一支才是跨原理佐证**。结论里必须分开写，不能笼统说"两支量具互相独立"。

### 2.4 非判据输入的已知异常（已界定，**不需再查**）

**A. `m3_haar_eyeline` 在旋转成片上有 8 条离群 —— 是配对失败，不是量错阶段。**

- **先答 stage 问题**：`out/P0_output_residual.json` 里 m3 量的是**成片**（`path` = `out/P0_anchors/composed/*__cn_big_1inch.jpg`），**不是夹具**。
- **机制（全量 99 条统计，非抽样）**：m3 自报的两眼点宽度 ÷ YuNet 眼距 = **中位 1.04，90/99 条 > 0.9** ⇒ 正常情况下它配对正确。但有 **8 条 < 0.75**，即配到了**不是双眼中心**的两点：`c02_d+10` 53.0/90.2、`c02_d+3` 52.5/92.5、`c02_d-10` 54.5/89.7、`c02_d-3` 58.5/91.1、`c07_d-10` 51.0/88.4、`c07_d-3` 61.0/88.4、`p2` 39.5/66.4、`p2_d+5` 41.5/89.3（全部集中在 c02 族、c07 族、p2 族）。
- 因恒等式 `deg == atan2(dy, dx)` **99/99** 成立，**读数就是那两个（错）点的纯函数** ⇒ 不是量纲/缩放错、也不是量错了阶段，而是**检测配对失败**。`p2_d-3`（−4.3987）属同一族，表现是 **dy 偏移**（`dx=78, dy=−6.0`，而正确眼对 dy≈0），不是宽度不足。
- **跨路径一致性**（team-lead 表）：`p2_d-3` 的 m1 −0.272 / m2 −0.013 / m4 −0.017 / gate_eyeline 0.0 / SIFT −0.178（129 内点）—— **四条路径一致，m3 独自离群**。
- **影响与处置**：该文件是门禁交叉复核列的输入（`gate_P0.dart:1350` → `inputs['qaResidual']`），m3 离群会弄脏那一列；但 **m3 不是判据输入**（`tools/gate/` 对 `measuredTiltDeg`/`measuredConsensus`/`tilt_abs_max_deg` **零命中**）。**结论：已知离群、非判据输入；r3 在该列排除或标注 m3。** 不追到底。
- **修正我 §2.2 的措辞**：「含 m3 的统计会失真」仍成立，但**不是普遍失真** —— 90/99 条 m3 配对正常，失真是这 8 条（及 `p2_d-3` 同类）造成的，应说成**局部离群**而非"该量具整体不可信"。

**B. `c03_upright` 的 2.66° 摆动 —— qa 量具自身的脆弱性数据点，非判据输入。**

同一内容、只差裁切/缩放，qa 量具的瞳孔法（`m1_pupil`）在**夹具侧读 2.406**、在**成片侧读 −0.2527**（该条引擎 `straightenDeg = 0.0`，未旋转 ⇒ 两侧只差裁切/缩放），**摆动 2.66°**。**这不是待查缺陷**：`tools/gate/` 对 `measuredTiltDeg` 零命中，它推不动任何判决。保留在此，作为「瞳孔族在这类图上不稳」的**第三条独立信号**（与 §4c 同向），供 r3 参考。

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

### 4c. 归因线索：两个**互相独立**的来源指向同一处（线索，**不是判据**）

写在此处是为了让他人可独立复核「两个来源彼此独立」这一点，而非仅存于对话。

1. **来源一（旋转夹具侧）**：`c06_d-3` 的形态为窄眼、上睑盖住大部分虹膜、可见虹膜成缝，**右眼窗口内无近圆候选**（拒绝形态 size / aspect / circ）；**左眼在同图、同参数下成功**。（该形态明细出自 **gatekeeper** 的拒绝形态分析，非我测量；其结论记录见 `docs/PITFALLS.md:2448` 条目。）
2. **来源二（真实照片侧）**：`ds_portrait_37` 人脸框 **304×384 = 117,073 px**，**大于**数张估角成功的照片（反例见本节上方），故「脸太小」被证伪，失效来自**眼区内容**。（本条为我实测。）
3. **归因**：两条来自**彼此独立**的测量路径（旋转夹具侧 / 真实照片侧），共同把归因从「夹具伪影」与「分辨率」推到**眼区内容**。

**到此为止** —— 「眼区里具体是什么特征导致失败」是第 3 轮要去**量**的对象，本报告不写成结论；写成结论会让后续跳过测量。

**边界（重要）**：本节是**归因线索**，**不是判据**，**不改变任何一条判据的通过与否**；`ds_portrait_37` 仍按「单列、不入分母」处理。本轮判定仍只由 `out/GATE_P0_r2.md` 出。

**通道澄清（防误读）**：眼带 alpha 空洞与瞳孔估计器失败**不在同一通道上**，不得读成因果。`estimatePupilRoll` 吃的是**原图灰度** —— `matting_worker.dart:399-411` 的 `runFaceFromRgb` 从 `image.rgb` 造 `gray`，与 `removeBackground(bytes)` 消费的是**同一份原始字节**（`controller.dart:137/:146`），成片与 alpha 都是其**下游产物**。因此 §4b① 的 alpha 空洞**不是**估计器失败的原因；gatekeeper §样本账 中「抠图失效（眼区被 alpha 空洞打掉）」那一列指的是**其自身眼线量具在成片上失效**，不是生产估计器失效。三条读数同指 c08 只支持「该 session 对多种方法都不友好」，**不支持**「一个原因造成三个后果」。另：`unavailable` 是**诚实失败**，按 `matting_worker.dart:398-399` 的注释设计上**不回退眼睑关键点**。

**佐证强度的边界（受 §2.2 约束）**：本节把 Haar 眼线与瞳孔估计器当作**跨方法佐证**是成立的，**但仅因为 `c06_d-3` 的位移远超量子**（成片 `dy=−7.50 px` / 夹具 `dy=−6.25 px`，即 0.25–0.5 px 量子的 **12–30 倍**，真值 −4.73°）。这条佐证**不可外推**：在与自身量子同量级的近零区间（步长**逐样本** 0.281–0.725°，眼距越小越粗）它没有判别力，**须逐条标注**。即「跨方法一致」**在大位移上可用、在近零处不可用** —— 后者的现成反例就是 §2.2 里两支量具在 `c05_upright` 上的近零读数：**不是谁的分辨率粗，而是两者只差 1–2 个量子。**

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
