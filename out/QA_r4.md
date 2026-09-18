# QA r4 —— 预轮重测（qa-batch）

**本轮性质**：这不是 r3 的重跑。r4 是**判据 v2（死区 10°）下的第一轮**，而 r3 的产物是在死区 **1.0°**
下生成的 ⇒ 两份的数字**不是同一把尺子量的**，任何"升降"都不得当成实现变好/变坏。

**本轮边界**：`lib/`、`test/gate/`、`tools/gate/`、`ACCEPTANCE.md`、`RUBRIC.md` 一行未碰。
开跑前 `git status --porcelain -- lib test tools docs` **为空**。开跑前提交 `71e273d`（量具修正，仅 `test/batch/` 3 文件）。

**被测集指纹**：`f003fdd0e73ed73a`（103 文件 = `lib` 67 + `test/batch` 36，`allCommitted=true`，
`uncommittedMeasuredFiles=[]`）。**Dart 与 Python 两侧独立算出同一个值**
（步骤 2 的成片台 provenance 与步骤 7 的自检都可核）。

---

## 1. 链条与读数（11 步，逐条退出码；日志 `out/r4_logs/`）

| # | 步骤 | 调用 | exit | 结果 |
|---|---|---|---|---|
| 1 | 样本解析 | `dart run test/batch/p0_resolve_check.dart` | 0 | RESOLVE CHECK PASS |
| 2 | 成片台 | `flutter test test/batch/p0_compose_test.dart` | 0 | cases 100 / expected 110 / **ok 110 / missing 0 / crash 0**；测试时钟 1:24 |
| 2b | 来源绑定 | `python test/batch/p0_provenance_check.py after-compose` | 0 | 3 份产物 + 绑定全过 |
| 3 | alpha 落盘 | `flutter test test/batch/p0_alpha_dump_test.dart` | 0 | 测试时钟 0:06 |
| 4 | 端到端残余 | `python test/batch/p0_output_residual.py` | 0 | 产物 15:55:43 |
| 5 | alpha 全扫 | `flutter test test/batch/p0_alpha_scan_test.dart` | 0 | SUMMARY ok=21 fail=66 total=87；测试时钟 0:35 |
| 6 | 眼带空洞 | `python test/batch/p0_alpha_holes.py` | 0 | 产物 15:56:41 |
| 7 | 自检 | `dart run test/batch/p0_selfcheck_run.dart` | 0 | 通过 9 / 失败 0；开跑=收尾=`f003fdd0e73ed73a`；`sameCodeStateAsCompose: true` |
| 8 | 覆盖率 | `flutter test test/batch/p0_coverage_test.dart` | 0 | total 188 / produced 188 / faceDetected 122 / noFace 53 / rejected 13 / crash 0；测试时钟 1:46 |
| 8b | 来源绑定 | `… after-coverage` | 0 | 5 份产物 + 绑定全过 |
| 9 | 几何核验 | `python test/batch/p0_verify_geo.py` | 0 | 78 夹具，minNCC=0.9985 |
| 10 | 真值重建 | `python test/batch/p0_finalize_v1.py --strict` | 0 | anchors 13（portrait 12 + upright 1）/ straight 1 / uprightSynthetic 9 / rotated 78 |
| 10b | 来源绑定 | `… final` | 0 | **7 份产物 + 绑定全过**，`allCommitted: True` |
| 11 | 重建后复检 | `dart run test/batch/p0_resolve_check.dart` | 0 | PASS（真值被步骤 10 重建过，故重跑） |

> 步骤 5 的 `fail=66` **不是测试失败**（`All tests passed`，exit 0），是"该夹具测得有空洞"的计数。
> r4 与 r3 **逐字相同**（21/66/87），量具修正没有扰动 alpha 侧。

## 2. 三份被钉产出（同一批、同一次运行）

| 产物 | mtime | sha256（前 16） | 记录指纹 | 与当前树不符文件 |
|---|---|---|---|---|
| `out/P0_compose_summary.json` | 15:54:43 | `baa38e468319a83e…` | `f003fdd0e73ed73a` | 0 |
| `out/P0_output_residual.json` | 15:55:43 | `7a51d2b556a2fd3a…` | `f003fdd0e73ed73a` | 0 |
| `out/P0_alpha_holes.json` | 15:56:41 | `14404c5f6288701a…` | `f003fdd0e73ed73a` | 0 |

其余同批产物：`P0_coverage_post.json` 15:59:32、`P0_coverage_items.jsonl` 15:59:31、
`P0_truth.json` 15:59:55、`P0_input_hashes.json` 15:59:55、`P0_selfcheck_provenance.json` 15:57:21、
`P0_anchors/fixture_geo_verify.json` 15:59:50。成片存在性 **110/110**（110 行 / 去重 id 100）。

## 3. v2 分档（ACCEPTANCE 的 15 / 11 口径）

按**真值**分档、按 id 去重，门禁规格 `cn_big_1inch`：

```
|truth| > 10°      15 条
  其中 9–11 边界带  4 条：c02_d-10, c07_d-10, c11_d-10, p2_d-10
  实际参与判定      11 条
|truth| <= 10°     85 条（P0.6 面）
```

- 15 条死区外里 **12 条 scored**，另 3 条因 `reliability_mismatch` 未计分
  （`c08_d-10`、`c08_d-5`、`p2_d-10`）。**12 是"scored 里死区外的行数"，不是 15**，两者不是同一个量。
- **边界带 4 条逐条挂牌**（ACCEPTANCE 要求不得静默丢弃）：

| id | 真值 | 估计 | 施加 | 残余 | 状态 |
|---|---|---|---|---|---|
| `c02_d-10` | −10.25 | −10.3215 | −10.3215 | +0.1556 | low_confidence |
| `c07_d-10` | −10.35 | −10.3021 | −10.3021 | −0.1463 | low_confidence |
| `c11_d-10` | −10.11 | −9.6325 | **0.0000** | −10.1490 | ok |
| `p2_d-10` | −10.20 | −10.1674 | −10.1674 | −17.9375 | reliability_mismatch |

## 4. 死区内的行为（P0.6 面）与两处违规

死区内 85 条里**只有 1 条被转动**：`c11_d+10`（真值 9.89、估计 10.283、施加 10.283、残余 −0.417）。

两条 v2 违规，**都在 9–11 边界带内**：

| id | 形态 | 真值 | 估计 | 施加 | 残余 | v2 越界量 |
|---|---|---|---|---|---|---|
| `c11_d+10` | 死区内**被转正** | 9.89 | 10.283 | 10.283 | −0.417 | \|残余−真值\|=10.307 |
| `c11_d-10` | 死区外**没摆平** | −10.11 | −9.633 | 0.000 | −10.149 | \|残余\|=10.149 |

两条的"该不该转"都由一个 0.4° 量级的估计误差决定（ACCEPTANCE 判定为噪声，**只报数、不判 FAIL**）。
**但本文件产出的 `deadZoneInsideViolations` / `deadZoneOutsideViolations` 两张表里没有带内标记**，
直接把它当 FAIL 会**把噪声记成实现方的错**——见 §7 队列项 1。

## 5. r3 → r4 逐行逐字段差（用 `git show HEAD:out/P0_output_residual.json`，指纹 `cd417a4d254ec1c2`）

110 行键集完全相同；**67 行变化**，且 67 行的 `straightenDeg` **全部**从"≈ 真值"变成 `0.0000`
——即**真值落在 10° 死区内的样本一律不再被转动**，这是产品定义变化，不是噪声：

```
c01      straighten -1.3737 -> 0.0000   primary -0.0366 -> -1.0494
c01_d+10 straighten  8.6950 -> 0.0000   primary  0.2388 ->  8.8165
c06_d-3  straighten -5.0383 -> 0.0000   primary  0.2748 -> -4.8247   ← r3 的"修复"其实是死区内的过度旋转
c11_d-10 straighten -9.6325 -> 0.0000   primary -0.5916 -> -10.1490  ← 新产生的死区外违规
c11_d+5  straighten  5.4809 -> 0.0000   primary -0.7077 ->  4.8514
p2_d+5   straighten  5.0025 -> 0.0000   primary -0.2603 -> -1.0522   （并转为 reliability_mismatch）
```

**未变的 43 行里，任何测量字段的变化数 = 0**（`primary_tilt_deg`、`m1..m4` 全等）
⇒ 变化**只**来自转动决策，量具本身没有漂。`end_to_end_status` 变化 27 行，故 `scored` 93 → 91。

**两个数的口径变了、不可跨轮比**：`primaryAbsMax` 1.377 → **10.149**、`primaryAbsMedian` 0.158 → **3.044**。
这两个是"全部 scored 行的 |成片倾角|"的描述量；死区内保留自身倾角是该定义**要求**的结果。
把它们读成"估角器变差 20 倍"就是拿 v1 的尺子量 v2 的样本。

## 5.1 修正后链里**仅存的 `1.5` 站点**，逐个说明它不是分界

这一节是给"只读产物、不读代码"的人写的：`1.5` 这个字面量在 v2 里**不再有任何分档含义**，
但它仍然散布在若干处，逐处交代清楚才不至于被当成死区分界（v2 分界是 `DEAD_ZONE_DEG = 10.0`）。

| 站点 | 是什么 | 为什么不是分界 |
|---|---|---|
| `p0_output_residual.py:45` / `p0_finalize_v1.py:39` | `RESIDUAL_TOL_DEG = 1.5` | **判据容差**，与死区无关（死区内量 `\|残余−真值\|`、死区外量 `\|残余\|`，共用这一个容差） |
| `p0_output_residual.py:50` | `V1_RETIRED_DIVIDER_DEG = 1.5` | **已退役**的 v1 分界。数值巧合与容差相同、含义完全不同，故单独命名；**只**喂名字带 `_v1_retired` 的沿革字段（`:416`、`:452`），**不得被任何 v2 判据引用** |
| `p0_output_residual.py:333` | `methodSpreadDeg > 1.5` → `low_confidence` | 量的是**方法之间的分歧**，不是残余。**但它决定 `scored` 成员**（故影响分母）—— 属"可靠性分类器"，与分档无关，本轮未动它，**改动它会动分母，需单独裁定** |
| `p0_output_residual.py:419` | 字符串：引用 `ACCEPTANCE.md:83` 的"原来的分界（\|真值\| > 1.5°）" | 纯叙述，转述被取代的旧口径，不参与计算 |
| `p0_finalize_v1.py:706`、`:713` | `abs(truthTiltDeg) > 1.5` 挑"有实际倾角的真实照片" | **取证据选择器**，不是分界。同一块的 `selectorNote` 自陈这一点，且同块的 `allPassUnderV2` 用 `RESIDUAL_TOL_DEG`、`inDeadZone` 用 `DEAD_ZONE_DEG` —— **分类路径没被污染** |
| `p0_finalize_v1.py:433/438/534/681/686/687` | 字符串里的 `≤1.5°` | 全是叙述文字，描述容差或引用旧口径 |

**结论**：修正后链里**没有任何一处裸 `1.5` 参与 v2 判档**；
两处名字带 `_v1_retired` 的是刻意保留的沿革出口，四处是文字。
**唯一还带"1.5"且真的影响判定的**是 `:333` 的方法分歧分类器 —— 它改的是**分母**不是分界，
故本轮**不动**（见 §7 队列项 6）。

## 6. 量测失效样本（逐条分类，不静默通过）

`cn_big_1inch` 100 行：`ok` 62 / `low_confidence` 29 / `reliability_mismatch` 8 / `unmeasured` 1。

**门禁的 `qa_eyeline` 回退在这 9 行上取不到读数**（`primary_tilt_deg` 为空或被判不可信）：
`c08, c08_d+10, c08_d+3, c08_d+5, c08_d-10, c08_d-5, p2_d+5, p2_d-10`（reliability_mismatch）
与 `c08_upright`（unmeasured）。这 9 行必须由门禁的眼线/SIFT 自行测出，否则会落到
`derived_identity`（用恒等式反推 = **没有测**），不是"通过"。

逐条原因（`truthConsistencyDeg` = 由成片反推的输入倾角 − 独立真值，`|·|>2.0` 即判不可信）：

- `c08_d+3`：两支可用方法自洽（spread 0.232）但**都错**：测出 +13.7°而真值 −5.01°，一致性差 18.667。
  → **方法间一致 ≠ 正确**，本行是这条的活证据。
- `c08_d-5` / `c08_d-10` / `c08_d+10` / `p2_d-10` / `p2_d+5` / `c08`：spread 5.2–27.4，
  两族方法彼此矛盾，**不取任何一个**。
- `c08_upright`（unmeasured）：主值三法（m1_pupil → m1h_pupil_haarseed → m3_haar_eyeline）全失败；
  唯一有输出的是 m2 = **16.000**。见下条。

**独立复核（不同路径）**：步骤 9 的几何配准（纯像素、无检测器、无特征点）对 78 条夹具给出
`recoveredPhiDeg`，与施加的 `−deltaDeg` 线性对应、minNCC **0.9985** ⇒ **夹具的几何真值本身被独立证实**，
失败样本的"真值"一侧不背锅；失效发生在**成片端的读数**一侧，与上面的分类一致。

**仪器缺陷（本轮实测，未修，见队列项 2）**：`p0_lib._radon_orientation` 的搜索轨是
`span=16.0`（`angs = np.arange(-span, span+1e-9, 0.1)`），峰值落在轨道端点时**返回 ±16.000 而不是报失败**。
实测 4 行命中：`c08_d+5` −16.000、`c08_d-5` 15.904、`c08_d-10` 16.000、`c08_upright` 16.000。
这些数被写进 `tiltAbsMaxDeg`（=16.0），而该字段的注释说"门禁要保守时用它"——
**拿它当保守上界会把一个搜索边界误差当成真实的大角**。

## 7. 队列（本轮只报不改：改 `test/batch/**` 会再翻指纹、作废本批全部产物）

1. `deadZoneInsideViolations` / `deadZoneOutsideViolations` 的每行**缺 `inBoundaryBand` 标记**，
   而两张表里的 2 条**恰好都落在 9–11 带内**（ACCEPTANCE 明令只报数不判 FAIL）。给每行加带内标记与豁免说明。
2. `_radon_orientation` 端点返回 ±16.000 不报失败；`m2` 的轨道值污染 `tiltAbsMaxDeg`。
   应在 `measure_m2` 里用 `span`/`peak_ratio` 拒收贴轨读数，或让它显式报 `rail_hit`。
3. `deadZoneOutsideCount`（scored 口径，=12）与 `deadZoneBoundaryBand.n`（primary 口径，=9）
   **两个相邻字段的量纲不同、名字不提示**，并列读会算出 `12−9=3`。应与 ACCEPTANCE 的 15/4/11 同口径或显式标注分母。
4. `P0.3a②` 的 `criterionB` n=12、斜率 **−0.7**、截距 **−9.404**（硬判据界是 \|斜率\|≤0.15、\|截距\|≤0.5）
   ——**但门禁的同一项样本集不同、且剔掉了边界带**（`gate_P0.dart:899-904`：
   `corpus=='rotated' && |truth|>kDeadZoneDeg && !inBoundaryBand`，n=**11**；
   该处注释点名 `c11_d-10` 一条就能把 15 条的斜率/截距一起带翻）。
   我的 12 = `deadZoneOutsideCount`（scored 口径，**含** 3 条带内的 `c02_d-10`/`c07_d-10`/`c11_d-10`，
   不含 reliability_mismatch 的 `p2_d-10`）。**两边口径不同，我那个 −0.7 不得当 FAIL 触发条件引用。**
   剔掉 2 条越界样本后 `max|残余| = 0.522`。
5. `docs/PITFALLS.md:1705` 把 `if (roll.abs() <= deadZoneDeg)` 锚到 `crop_geometry.dart:143`，实际在 `:153`；
   同文件 `:973` 记的"死区 1.0"是历史值。锚点是会腐烂的——但 PITFALLS 只追加，留给主会话定是否补注。
6. `p0_output_residual.py:333` 的 `methodSpreadDeg > 1.5` 是**唯一**还带旧字面量、且**真的决定 `scored` 成员**
   （⇒ 决定分母）的站点。它不是分界，故本轮未动；但它是"下一个会腐烂的数字"：
   要么给它名字并写明口径，要么让它在报告里显式挂牌。**改它 = 改分母，须单独裁定。**
