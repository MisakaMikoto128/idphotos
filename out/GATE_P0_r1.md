## G2B-P0 第 1 轮：**作废（本轮无效，不是对代码的判决）**
## 通过 0 / 10 项，MANUAL 项 10 个（全部条目因本轮输入不可信而作废）
## 脚本完整性：OK（本轮自报改动：11 个，见 out/GATE_P0_selfchanges.txt）
## 防作弊巡查：清白

### 事后勘误（2026-09-17 追加；不推翻下方任何原始结论，只标注哪些证据当时是空的）
1. **「防作弊巡查：清白」这句话在条款 3 / 条款 5 上当时是空的。** 本轮用的扫描器是 `grep` 子进程，而本机从 Dart 起 `grep` 时 Windows 会在参数传递途中吃掉模式里的 `\` `{` `}` `,`：`catch\s*\(...\)\s*\{[\s\S]{0,80}?\}` 到达 grep 时已变成 `catchs*(s*[A-Za-z_]*s*)s*{[sS]80?}`，grep 直接报 exit 2；`skip:|@Skip|@skip` 里的 `|` 还被 shell 当管道，报 `'Skip' is not recognized`、exit 255。**也就是说条款 3/5 的扫描从未真正跑过，而报告写的是"命中 0"。**这正是本项目反复出现的那同一个形态：**仪表看不见对象时说了"没有"，而不是"我看不见"。**
2. **改用纯 Dart 正则后（`tools/gate/anticheat.dart`，同一提交内自报）的复核读数**：`lib/` 67 个文件、`test/` 22 个、`tools/gate/` 20 个、`integration_test/` 9 个；skip 命中仅出现在 `tools/gate/`（16 条，全是扫描器自己的模式常量与 gate_G4 里的字样）；空 catch 命中仅出现在 `test/gate/anticheat_test.dart`（3 条，全是自检的正例夹具）。**`lib/` 与 `integration_test/` 两项均为 0 命中。**
3. 由此新增一条口径：命中落在巡检自身领地（`tools/gate/`、`test/gate/`）时**逐条登记但不判违规**——扫描器扫不了自己，而这两个目录本就只有 gatekeeper 能写，别人往里写已先被条款 1 拦下。登记并公开 ≠ 隐去。
4. 本文件是**再生成**（`--reuse`），不是一次新判决；第 1 轮的「作废」结论原样保留，也不会因为再生成而变成对某个代码状态的判决。
5. 判据第 6 条的表述在上游被订正过（`6f01e6e` → `98f3331`）：不同照片数是 **11**（12 条锚点 − `c03`/`c04` 这一对真重复），`c10`/`c11`/`c12` 是**三张不同照片**各自计数，`p2` 归 `straight` 不在锚点栏。数字未变，变的是理由与算式。

规格：`cn_big_1inch`（ACCEPTANCE P0.1a 指定）；真值：`out/P0_truth.json`；生产记录：`out/P0_compose_items.jsonl`；gatekeeper 独立测量：`out/gate_P0_eyeline.json`。

### 判据版本声明（ACCEPTANCE 冻结条款要求写明）
本轮判决依据的判据 = `docs/ACCEPTANCE.md` @ commit `6f01e6e`（P0 判据冻结点）。
**第 1 轮初判作废的原因**：主会话在门禁运行期间于 03:23 / 03:24 / 03:39 / 03:47 连续四次修改 G2B-P0 判据，本门禁初版按改动前的草稿实现，且判据被从"读 `ComposeDiagnostics.straightenDeg`"改成"只认成片端到端残余"——初版判的正是新法典明令不作判据的量。故初判作废，本文件是**按冻结版判据重跑**后的第 1 轮结果，不消耗实现方的修复轮次。详见 `docs/ACCEPTANCE.md` 的「判据冻结声明」。

### 轮次记账（主会话 2026-09-17 裁定，按 CLAUDE.md §7「最多 3 轮修复」）
第 1 轮是**重写轮**（判据被中途改动致初判作废），**不消耗** ml-porting 的修复预算。
ml-porting 有 3 次修复机会，对应门禁运行 **r2 / r3 / r4**；r4 仍 FAIL → 写 `out/BLOCKED_G2B-P0.md`，全流程停止等人工，不降阈值、不删夹具、不跳门禁。
本轮按 `r1` 编号。

### 轮次有效性判定（主会话 2026-09-17 裁定，**r2 起生效**）
> **一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来。**任何一项判据的输入若来自另一个状态（不同工作树、不同 revision、不同测量台的上一次产出），**要么重测，要么把该项标为无效**。
机检三件：① `git status --porcelain -- lib test tools docs` 为空（`out/` 除外）；② 每条样本都解析得到、成片文件都在；③ 声明条数 == 实际解析条数。任一不过 → **整轮作废**（全部条目 pass=false、manual=true），不消耗实现方修复轮次。**加一行说明拦不住它**——r1 就是这么滑过去的，所以这里是判 `roundInvalid` 而不是写备注。
**本机制晚于 r1**：r1 的 FAIL 判决（P0.3a max 11.368°、P0.3b 9 条）按主会话裁定**保留为基线测量**，不因本机制追溯作废；但它**不是对任何单一代码状态的判决**，不得用来论证"改了一轮没修好"。


### 本轮输入的一致性（读数绑在哪个版本上）
- HEAD = `7193ba2`；判 selfcheck 那几条（P0.5a）编译自**工作树**，不是这个 commit。
- `git status lib/` **不干净**（1 个文件）：`M lib/core/matting/iris_roll.dart`。
- **结论：本轮读数绑定不到任何 commit。** 其中 P0.1a / P0.2 / P0.3a / P0.3b 来自 `out/P0_compose_items.jsonl`（qa-batch 在它自己那一版工作树上产出），P0.5a 来自本机**当前**工作树编译的 `dev_selfcheck` —— 两半可能不是同一版代码。修掉的办法只有一个：运行期间冻结 `lib/`，开跑前 `git status lib/` 必须干净。
- **冻结范围**：`lib` / `test` / `tools` / `docs` **全部在冻结内**；唯一豁免 `docs/PITFALLS.md` 这一个文件（它不进任何测量链——门禁不读它、判据不引用它、读数不经过它；且 CLAUDE.md §4 规定所有 agent 可随时只追加）。**`docs/` 里除它以外的任何改动（含 `ACCEPTANCE.md`/`RUBRIC.md`/`CONTRACTS.md`/`DESIGN.md`/`ENV.md`）仍会作废整轮。**本轮无豁免条目。
- **输入完整性：100 条里有 13 条的成片文件不存在**（读数对应的文件已被覆盖或删除，**本轮不可复现**）：p1、c01、c02、c03、c04、c05、c06、c07、c08、c10、c11、c12、p2
- 后果：这些条目的读数来自**上一轮当时的文件**，现在既不能重测也不能复核。出这一条本身不代表判决错，但读者必须知道哪些数字是**不可追溯**的。**不要拿当前成片目录去重新推导历史轮次的残余**——那会得到一份看着像、其实是假的数字。
- 成片台 summary：`crash=0`、`cases=100`、`ok=110`、`mattingFail=0`、`composeFail=0`、`noFace=0`。
- **该 summary 缺 `casesAttempted`/`missing`/`complete` 三件套 → 不能作为完整性证据**（`crash == 0` 本身不是证据：静默跳过的运行同样 crash 0）。本轮改由门禁**自己数条数**（见上一条），不依赖它。另外 `cases=100` 与 `ok=110` 本身就对不上。


### 硬判据出自哪支量具（避免把量具差异读成分歧）
- **P0.1a / P0.2 / P0.3a② / P0.5b** 的成片残余：gatekeeper 的 **Haar 眼线量具**（`tools/gate/p0_eyeline.py`，自检最大误差见上）为第一读出；它测不出的样本改由 **SIFT 源图↔成片配准**（`tools/gate/p0_rigid_check.py align`）读出，逐条出处写在样本账里。
- **交叉复核**用的第二支是 qa-batch 的瞳孔法（`out/P0_output_residual.json`），两者是独立量具：同一张成片上读数可以不同（本轮最大差 1.414°），但只要两者都远超阈值就不构成分歧。**报告里的硬指标一律注明出自哪支**。
- 口径无关性：SIFT 只量"管线实际转了多少度"，不读眼线、不读 alpha、不读生产诊断，是符号约定出错时唯一不会跟着一起错的路径。

### 量具自检（量不准的量具没有资格判别人）
- 眼线量具：最大误差 0.4131760767771411°，门槛 0.5° → 合格
- 刚体配准量具：最大误差 0.5500000000000007°，门槛 1.0° → 合格
- 两条路径的独立测量一致性：见「交叉复核」一节
- 门槛由**门禁**定（不是工具自报）：眼线量具喂亚度级统计，故要求 0.5°；刚体量具只用于 ≥1.5° 量级的分歧复核，1.0° 够用。

### 交叉复核（gatekeeper 眼线量具 vs qa-batch 眼线测量）
共同可测 90 条：|差| 中位 0.408°，最大 1.414°。**原始读数** |成片倾角| > 1.5° 的集合（不是违规计数，违规还要按条件覆盖率口径折算）：gatekeeper 10 条 / qa-batch 9 条，qa-batch 的集合**是** gatekeeper 的子集——它报出的每一条超标本量具都独立复现；双方一致判定达标的 80 条。两条路径的系统性差异约 0.41°（不同方法：Haar 眼级联 vs YuNet 眼位+暗色圆盘+Radon 共识），小于判据容差 1.5° 的 1/3，足以互相印证，不足以单独定案——故凡两条路径读数相差 > 1° 的样本，判定一律回退到独立第三方证据（生产记录 + 已验证恒等式）。

SIFT 路径：可配准 100 条，实测施加角与生产记录 |差| 最大 0.070°；它测出残余超 1.5° 的样本 1 条（c08_d-5）——其中 c08_d-5 是另两台都量不出来的那条。

### 去重口径（法典条款 6 的同性质要求：不得用未去重的计数虚增覆盖）
- 锚点条目 **12** 条（`corpus == anchor`，**不含 `p2`**——法典条款 6 订正后明写 p2 归入 `straight`、不计入锚点栏）。本量具测出**同图重复 1 对**：`c03` ≡ `c04`（MAE 2.33）。
- **去重后 = 12 − 1 = 11 张不同照片**，与法典条款 6 订正后的算式「12 − `c03`/`c04` 这一对真重复 = 11」**独立吻合**。
- 黄金集 8 张中 **8 张在非旋转源照片里有同图**（**全部 8 张都是锚点/竖直样本的照片**，黄金集不是独立样本）：
  - `g01.jpg` ≡ `p2`（straight，MAE 0.15）
  - `g02.jpg` ≡ `c01`（anchor，MAE 0.03）
  - `g03.jpg` ≡ `c02`（anchor，MAE 0.06）
  - `g04.jpg` ≡ `c06`（anchor，MAE 0.07）
  - `g05.jpg` ≡ `c07`（anchor，MAE 0.05）
  - `g06.jpg` ≡ `p1`（anchor，MAE 0.66）
  - `g07.jpg` ≡ `c03`（anchor，MAE 0.10）
  - `g08.jpg` ≡ `c08`（anchor，MAE 0.11）
- **本量具的局限（必须写明）**：整幅签名法**测不出"同一场景的不同裁切/不同取景"**，所以 `c10`/`c11`/`c12` 这类它分辨不了。**法典条款 6 已于 2026-09-17 订正：三者是同一场景的三张不同照片，不去重、各自计数**（依据是"只统计结构像素"的ECC 对齐复核，`c10`/`c11` 结构像素 ≤5 灰阶仅 11.3%，而已知同图对 `c03`/`c04` 为 95.2%）。本门**不推翻也不重复验证**该结论，只声明本量具对这个量级不敏感、不参与该判定。
- 同一订正还排除了 `c07`↔`p2`（全图相似度一度很高，限制到结构像素后仅 24.2%）。这与本门的观察一致：该对 MAE 9.10，比同图簇（≤2.4）高一个量级，本门当时就**没有**按同图计。
- **结论**：`P0.4` 的 `RollSource` 分布里，"黄金集"与"锚点"两列**讲的是同一批照片**，不得相加当作独立覆盖数；凡涉及"覆盖了多少张不同照片"的表述，本报告一律按去重口径写。


### 样本账（ACCEPTANCE 计分口径第 7 条：样本不得静默消失）
原始样本总数 100 条（全部来自 `out/P0_compose_items.jsonl` 的 `cn_big_1inch` 记录），扣除 0 条，可计分 100 条。

没有样本"因为量不出来而不算数"：眼线量具测不出的 10 条，全部改由 SIFT 源图↔成片配准独立测出（残余 = 真值 − 实测施加角），逐条如下。

| 样本 | 眼线量具为何失效 | 归类 | SIFT 独立复核 | 最终取值 |
|---|---|---|---|---|
| c08 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -7.350°，与生产记录差 -0.020° → 残余 -0.660°；qa-batch 读数 0.096°（ok） | -0.660°（gate_sift_align） |
| c08_upright | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 0.019°，与生产记录差 0.019° → 残余 -0.019° | -0.019°（gate_sift_align） |
| c07_d-3 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -3.584°，与生产记录差 -0.019° → 残余 0.234°；qa-batch 读数 0.268°（ok） | 0.234°（gate_sift_align） |
| c08_d-10 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -18.107°，与生产记录差 -0.032° → 残余 0.097°；qa-batch 读数 7.915°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | 0.097°（gate_sift_align） |
| c08_d-5 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -0.015°，与生产记录差 -0.015° → 残余 -12.995°；qa-batch 读数 -2.998°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -12.995°（gate_sift_align） |
| c08_d-3 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -10.739°，与生产记录差 -0.005° → 残余 -0.271°；qa-batch 读数 0.574°（ok） | -0.271°（gate_sift_align） |
| c08_d+3 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -4.656°，与生产记录差 -0.003° → 残余 -0.354° | -0.354°（gate_sift_align） |
| c08_d+5 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -2.840°，与生产记录差 0.011° → 残余 -0.170°；qa-batch 读数 5.755°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.170°（gate_sift_align） |
| c08_d+10 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 1.852°，与生产记录差 0.017° → 残余 0.138°；qa-batch 读数 -2.765°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | 0.138°（gate_sift_align） |
| c12_d-3 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -5.121°，与生产记录差 -0.004° → 残余 0.031°；qa-batch 读数 0.345°（ok） | 0.031°（gate_sift_align） |

**条款 7 点名的那条（`c08_d+10`）的定论**：它的 alpha 是干净的（qa-batch 扫到 eyeBandZeroFrac 0.002），却被 qa-batch 的自证式检查判为 unreliable，正是"把真实缺陷归成量不出来"的现成嫌疑。本门用 SIFT 独立量了源图→成片这一跳：实测施加角 1.852°，与生产记录 1.834° 差 0.017°，残余 = 真值 1.990 − 实测施加角 = **0.138°**，|残余| ≤ 1.5° → **不构成违规**。qa-batch 那一支的 -2.765° 是量测假象，它自己也已标注 reliability_mismatch。（顺带纠正一处易错：`c08_d+10` 的真值是 −8.01+10 = 1.990°，不是 18.01°；18.01° 是 `d-10` 那条，它反而被正常摆平到 0.097°。）

三台量具在 c08 家族上的对照（同一批成片，互不调用）：眼线量具全部失效；SIFT 全部配得上；qa-batch 的 pupil 法在 4 条上给出被它自己否掉的数。值得一提：`c08_d-10` 的眼区被抠图打掉 96.8%，SIFT 仍给出与生产记录差 0.032° 的读数——它配的是整个头部的特征，不吃眼睛那一块。

**顺带发现：1 条须回派，1 条经代码复核后关掉**
1. **【独立的 G2B 缺陷｜归属 imaging｜处置时序"P0 PASS 后"】紧取景源图的裁剪框落到源图之外，成片留下底色填充的切口。****它不是 P0 的失败项**——P0 判的是摆正估计的准确性，本条与摆正无关；记在这里，只是因为本门为了量摆正把成片逐张渲染出来时看见了它。
   本门**渲染成片逐张看过**，不是只看指标：真实照片 `C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_11_Pro.jpg`（`c08`）的成片人头占满上部、**下巴被下边缘切掉**、下缘约三成是空白底色；它的竖直副本 `c08_upright`（`straightened=false`，**没做任何旋转**）同样坏，越界 29.0%。
   **疑似是两种不同的缺陷，请 imaging 逐张判、别统一成一条**：① **裁剪**——`c08` 下缘是**水平**切口（取景框伸到图片下边界之外）；② **抠图**——同一张成片左侧中部与右侧中部**各有一团孤立碎屑**（浮在空白背景里、与人物不连通），属 G2A/2A 口径，不是裁剪。`p1` 的切口则是**斜的**（左下），与 `c08` 的水平切口形态不同，所以**可能不止一种机制**。
   指标分布（`cn_big_1inch` 100 条）：越界 >0 共 73 条、>0.10 共 40 条、>0.20 共 26 条，中位 0.0423，最大 `c05_upright` 43.5%；用户自己的照片 `p1` 15.4%、`p2` 2.1%。
   **两条必须写清楚，免得被读歪**：① **不是旋转造成的**——最坏的两条 `c05_upright` / `c08_upright` 恰恰没旋转，`c05` 家族跨 Δ 无单调趋势（Δ=0 → 0.360，d+3 → 0.429，d+10 → 0.323，d−5 → 0.272）；② **越界比例本身不等于可见破损**——`c05` 越界 36.0% 成片仍然正常，真正肉眼可见破损的是 `c08` 与 `c08_upright`。**不要拿一个数字去推断严重程度。**
2. **`c08` 旋转夹具的眼区 alpha 空洞 = 夹具伪影 / 无用户影响**（不复判、不回派）。现象：源图先旋转再喂给管线时，c08 的旋转夹具眼区被 alpha 打掉（`c08_d-10` 96.8%、`c08_d-5` 75.5%、`c08_upright` 61.9%），而 Pictures 里 14 张未旋转人像的空洞率全为 0.0000（`out/P0_alpha_holes.json`）。裁定它不是产品缺陷，依据是生产路径**永远不会**把面内旋转过的图喂给抠图引擎——四条都由本门独立复核过，不是转述：`lib/core/controller.dart:137` 把用户原始 `bytes` 直传 `removeBackground`，同一份 `bytes` 在 `:146` 传给 `detectFace`，中间无预处理；`lib/core/matting/matting_engine.dart` 与 `matting_worker.dart` 内**没有任何**旋转/转置/仿射调用（grep 命中 0）；抠图前的唯一朝向处理是 `lib/core/matting/image_ops.dart` 的 EXIF `bakeOrientation`，它只可能是 90° 整数倍的转置，不产生任意面内角；面内旋转只出现在 `lib/core/imaging/compose_engine.dart:232` 的 `planRotation`，而 compose 跑在抠图**之后**。推论：该空洞需要"输入被任意角旋转过"这一前提，用户碰不到，故**既不进 P0 判据，也不进 G2A 判据，不回派**。本门采信它的唯一后果是：那几条不得不用 SIFT 兜底，不影响任何一条 P0 结论。


### 贴线项（余量 vs 量具误差）
| 项 | 子量 | 本轮实测 | 余量 | 该量具自检误差 | 结论 |
|---|---|---|---|---|---|
| P0.5b | **判据量** ① 施加几何 | 实测 0.070° | 1.430° | 0.550° | 余量 > 量具误差，稳过 |
| P0.5b | 辅助量 ② 跨量具一致性 | 实测 1.450° | 0.050° | 0.413° | **贴线**（余量 < 量具误差） |

- ① 施加几何（判据量）实测 0.070°，余量 1.430° → 余量充足。

- **P0.5b 的复核口径**：margin > instrumentErr 才是确定性违规；若 margin < instrumentErr，须 SIFT 路径独立复现同一超线才计违规，否则记「边界噪声 / 证据不足」，不消耗实现方修复轮次（本条不适用 P0.3a：P0.3a 超阈值 7 倍以上，两支量具均独立复现，按原样记 FAIL）（本轮第二支量具 未超线 → 若本项翻 FAIL 即属边界噪声）

规则（主会话 2026-09-17 裁定，与条款 7 同源）：余量 < 量具误差的条目，**单支量具的 FAIL 不足以定罪** —— 必须第二支独立量具复现同一超线才计违规；只有一支超线则记「边界噪声 / 证据不足」，不消耗实现方修复轮次。**本规则不适用于 P0.3a**：它超阈值 7 倍以上且两支量具独立复现，是确定性违规。


### 判定明细
#### P0.1a FAIL [MANUAL]
- 期望：|residual| ≤ 1.5，中位 ≤ 1.0，样本 ≥ 8 张不同照片（数**不同照片**，不数行数）
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  可计分锚点 11 条 = **10 张不同照片**，下限 8 张不同照片
  去重口径出自 `out/gate_P0_overlap.json`（48×48 灰度签名逐对 MAE，≤5.0 记同图）：本轮判定 `c03≡c04` 为同一张照片（同图不同分辨率），故 11 行 → 10 张。**该量具分辨不了 `c10`/`c11`/`c12` 这类"同一场景的不同取景"**，声明不参与那三者的判定；法典条款 6 @ `98f3331` 裁定它们是**三张不同照片**、各自计数。量具不去重它们，方向上是保守的（只会让计数偏高、更容易过下限），因此不会制造假 FAIL，但也**不能**反过来用它论证"三张里有两张其实是同一张"。原始锚点栏 12 条，`p2` 不在锚点栏——它同现于 anchors 与 straight，成片台按 id 合并后归入 straight。
  max|残余| = 0.714，中位 = 0.476
  残余出处：{gate_eyeline: 10, gate_sift_align: 1}（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）
  p1: truth=-4.400 applied=-4.416 resid=0.484 src=pupil by=gate_eyeline
  c01: truth=-1.300 applied=-1.364 resid=0.303 src=pupil by=gate_eyeline
  c02: truth=-0.250 applied=0.000 resid=-0.144 src=pupil by=gate_eyeline
  c03: truth=-3.720 applied=-3.729 resid=0.158 src=pupil by=gate_eyeline
  c04: truth=-3.820 applied=-3.900 resid=0.644 src=pupil by=gate_eyeline
  c05: truth=-3.910 applied=-3.936 resid=0.476 src=pupil by=gate_eyeline
  c06: truth=-1.730 applied=-1.843 resid=0.714 src=pupil by=gate_eyeline
  c07: truth=-0.350 applied=0.000 resid=-0.451 src=pupil by=gate_eyeline
  c08: truth=-8.010 applied=-7.330 resid=-0.660 src=pupil by=gate_sift_align
  c10: truth=-3.440 applied=-3.313 resid=0.603 src=pupil by=gate_eyeline
  c12: truth=-2.090 applied=-2.116 resid=0.151 src=pupil by=gate_eyeline
#### P0.1b FAIL [MANUAL]
- 期望：需要摆正的 8 条锚点上 unavailable = 0
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  需要摆正（|truth| > 1.5°）的锚点 8 条，其中 unavailable 0 条
  |truth| ≤ 1.5° 而返回 unavailable 的 1 条，按口径 2 可接受：c11(-0.110)
#### P0.2 FAIL [MANUAL]
- 期望：|residual| ≤ 1.5 且 9 张 uprightSynthetic 全部 source=pupil
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  竖直样本 10 条（用户 2.jpg 1 条 + 合成竖直 9 条，后者下限 9 条），max|残余| = 0.637
  uprightSynthetic 来源分布：{pupil: 9}（全部 pupil）
  p2: truth=-0.200 applied=0.000 resid=-0.160 src=pupil by=gate_eyeline
  p1_upright: truth=0.000 applied=0.000 resid=0.487 src=pupil by=gate_eyeline
  c01_upright: truth=0.000 applied=0.000 resid=0.454 src=pupil by=gate_eyeline
  c03_upright: truth=0.000 applied=0.000 resid=-0.161 src=pupil by=gate_eyeline
  c04_upright: truth=0.000 applied=0.000 resid=0.479 src=pupil by=gate_eyeline
  c05_upright: truth=0.000 applied=0.000 resid=0.637 src=pupil by=gate_eyeline
  c06_upright: truth=0.000 applied=0.000 resid=0.582 src=pupil by=gate_eyeline
  c08_upright: truth=0.000 applied=0.000 resid=-0.019 src=pupil by=gate_sift_align
  c10_upright: truth=0.000 applied=0.000 resid=0.597 src=pupil by=gate_eyeline
  c12_upright: truth=0.000 applied=0.000 resid=0.000 src=pupil by=gate_eyeline
#### P0.3a FAIL [MANUAL]
- 期望：② 斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  ② 硬判据：残余 vs 真值 斜率 = -0.013（|·| ≤ 0.15），截距 = 0.279°（|·| ≤ 0.5），max|残余| = 11.368°（≤ 1.5）
  超 1.5° 的夹具 1 条：c06_d-3(11.368°)
  只用 pupil 夹具 89 条（原始 100 条）
  ① 诊断：估计值 vs 真值 斜率 = 1.007（带 [0.85, 1.15]，不参与 PASS/FAIL）
  按口径 1 排除在残余统计外的 unavailable 样本 11 条（它们的账由 P0.3b 条件覆盖率算，不许在这里被悄悄算成通过）：c11、c01_d+10、c04_d-10、c04_d-5、c06_d+3、c08_d-5、c11_d-10、c11_d-5、c11_d-3、c11_d+5、c11_d+10
  残余出处：{gate_eyeline: 80, gate_sift_align: 9}（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）
#### P0.3b FAIL [MANUAL]
- 期望：需要摆正的 67 条夹具上 unavailable = 0
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  违规 9 条（需要摆正 |truth| > 1.5° 却返回 unavailable）：c01_d+10(truth 8.700°)、c04_d-10(truth -13.820°)、c04_d-5(truth -8.820°)、c08_d-5(truth -13.010°)、c11_d-10(truth -10.110°)、c11_d-5(truth -5.110°)、c11_d-3(truth -3.110°)、c11_d+5(truth 4.890°)、c11_d+10(truth 9.890°)——这 9 条成片未施加任何旋转，仍歪着对应角度
  旋转夹具原始总数 78 条，需要摆正 67 条
  |truth| ≤ 1.5° 而 unavailable 的 1 条，按口径 2 可接受
  分母：可计分 78 条 / 原始 78 条（无样本因量测失效被扣除，见条款 7 样本账）
#### P0.4 FAIL [MANUAL]
- 期望：unavailable 样本施加角 = 0 的违规数 = 0，且不得出现 source=given
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  全量可合成样本 100 条，来源分布：{pupil: 89, unavailable: 11}
  锚点：{pupil: 11, unavailable: 1}；竖直：{pupil: 10}；夹具：{pupil: 68, unavailable: 10}
  unavailable 的施加角 ≠ 0 的违规 0 条；夹具里 source=given 的 0 条
#### P0.5a FAIL [MANUAL]
- 期望：退出码 0 且 通过 ≥ 9、失败 = 0
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  退出码=0；解析到 通过=9 失败=0（命中「+9」）
  ...(截断)...
  
  [2B.6/2B.7 验收口径]
    灰矩形画布 cn_1inch             绿=0 品红=0
    灰矩形画布 cn_small_1inch       绿=0 品红=0
    灰矩形画布 cn_big_1inch         绿=0 品红=0
    灰矩形画布 cn_2inch             绿=0 品红=0
    灰矩形画布 cn_small_2inch       绿=0 品红=0
    灰矩形画布 cn_social_security   绿=0 品红=0
    灰矩形画布 visa_us              绿=0 品红=0
    黄金集 g01 绿=0 品红=0
    黄金集 g02 绿=0 品红=0
    黄金集 g03 绿=0 品红=0
    黄金集 g04 绿=0 品红=0
    黄金集 g05 绿=0 品红=0
    黄金集 g06 绿=0 品红=0
    黄金集 g07 绿=0 品红=0
    黄金集 g08 绿=0 品红=0
    合计溢色像素=0 (阈值 0)
  00:19 +4: 2B.8 摆正（±10° 输入的残差角）
  [2B.8]
    输入 roll=-10.0° → 成片残差 -0.039°
    输入 roll=-6.0° → 成片残差 -0.034°
    输入 roll=6.0° → 成片残差 0.034°
    输入 roll=10.0° → 成片残差 0.039°
    输入 roll=0.8°（死区内）→ 是否旋转=false
    最差残差=0.039° (阈值 1.5°)
  00:21 +5: 用户框选 × 摆正：主体尺度守恒（REVIEW_G2 #3 回归）
  [用户框选×摆正]
    roll=0.0° 摆正=false 裁剪框=460.0×644.0（用户框 460×644） 成片头高=243.0px（理想 243.7） 保留比例=99.7%
    roll=2.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=6.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=-10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=20.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    最差偏离=0.5% (阈值 3%)
  00:23 +6: 用户框选 × 摆正 × 越界：无黑边（2B.9 的反旋转新路径）
  [用户框选×摆正×越界]
    roll=10° 框心=(40,40) 裁剪框=460.0×644.0 越界=50.7% 图外非白像素=0
    roll=10° 框心=(960,40) 裁剪框=460.0×644.0 越界=42.8% 图外非白像素=0
    roll=10° 框心=(40,1360) 裁剪框=460.0×644.0 越界=0.0% 图外非白像素=0
    roll=10° 框心=(960,1360) 裁剪框=460.0×644.0 越界=39.9% 图外非白像素=0
    roll=10° 框心=(500,-800) 裁剪框=460.0×644.0 越界=100.0% 图外非白像素=0
    roll=-10° 框心=(40,40) 裁剪框=460.0×644.0 越界=42.8% 图外非白像素=0
    roll=-10° 框心=(960,40) 裁剪框=460.0×644.0 越界=50.7% 图外非白像素=0
    roll=-10° 框心=(40,1360) 裁剪框=460.0×644.0 越界=39.9% 图外非白像素=0
    roll=-10° 框心=(960,1360) 裁剪框=460.0×644.0 越界=0.0% 图外非白像素=0
    roll=-10° 框心=(500,-800) 裁剪框=460.0×644.0 越界=100.0% 图外非白像素=0
    最大越界比例=100.0% 图外非白像素（最差单张）=0 (阈值 0)
  00:23 +7: 2B.9 边界安全（贴边人脸不抛异常、无黑边）
  [2B.9]
    setup0 完成，越界比例=26.0% 缩小=false 说明=裁剪框越界 26.0%（越出部分按 alpha=0 填底色）
    setup1 完成，越界比例=28.7% 缩小=false 说明=裁剪框越界 28.7%（越出部分按 alpha=0 填底色）
    setup2 完成，越界比例=0.0% 缩小=false 说明=裁剪框完全在图内
    setup3 完成，越界比例=7.6% 缩小=true 说明=人脸过于贴边/过大，已按头顶锚点缩到越界 ≤ 45%：头高比 1.307（目标 0.640），越界 7.6% 填底色
    setup4 完成，越界比例=31.0% 缩小=false 说明=裁剪框越界 31.0%（越出部分按 alpha=0 填底色）
    图外区域出现的非底色像素总数（最差单张）=0 (阈值 0)
  00:26 +8: 渐变底与去色边质量（蓝渐变 / 白底，合成原片）
  [渐变] 顶部=(97,138,206) 期望≈(98,139,206) 底部=(43,89,160) 期望≈(43,90,160)
  [去色边] 换白底后残留蓝边像素=0 (阈值 0)
  00:27 +9: All tests passed!
  
  stderr:
  
#### P0.5b FAIL [MANUAL]
- 期望：两个**分开报**的子量都要过：① 施加几何 —— SIFT 实测施加角 vs 生产记录 |差| ≤ 1.5°；② 跨量具一致性 —— 眼线实测残余 vs (真值−施加角) ≤ 1.5°
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  ①【判据量·施加几何】SIFT 源图↔成片配准，可配准 100 条，实测施加角 vs 生产记录 |差| 最大 0.070° （阈值 1.5°，余量 1.430°）—— 此项不读眼线、不读 alpha、不读生产诊断，是 2B.8 本体的直接测量
  ②【辅助量·跨量具一致性】眼线路径，可实测夹具 90 条，|眼线实测残余 − (真值−施加角)| 最大 1.450° （阈值 1.5°，余量 0.050°，眼线量具自检误差 0.413°）—— 这个量把**量具噪声**和几何误差混在一起，余量小于量具误差，**不作为定罪依据**
  说明：本项不注入夹具，而是用真值已知的旋转夹具反查同一件事；施加几何一旦出问题（符号反了/没转），① 会立刻爆到 2 倍真值
#### P0.5c FAIL [MANUAL]
- 期望：原本通过的项重跑后仍 PASS；本项需重跑才能判定
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  本轮未重跑设备端（上游 P0.3a/P0.3b 未修好时重跑不产生新信息，一轮约 40 分钟）。
  既有 gate 结果里的未过项：G4/4.7
  注意：这些是**本轮之前就存在的**未过项，不是 P0 引入的退化；逐条原因见各自的 out/GATE_*_r*.md，不计在 ml-porting 账上。
#### AC FAIL [MANUAL]
- 期望：0 命中
- 实测：
  **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在**
  原判定依据（**不作为判决**）：
  清白（黄金集 src=8 ref=8；skip/catch 扫描：条款 3：skip 命中 28（其中 28 条落在巡检自身领地，已登记不判违规）；注释掉的断言命中 0；**被放宽的阈值常量：无独立扫描器，靠基线 tag diff 结构性覆盖**（阈值只在 ACCEPTANCE.md 与 tools/gate/ 两处，分别受条款 1、条款 2 保护）；条款 5：无说明的空 catch 命中 0；**带注释理由的吞异常 2 处已逐条登记、不自动定罪**（脚本分不出"有理由的降级"与"作弊的吞"，这一层留给人/adversarial；它们每次都会印在报告里，藏不掉）；判据定义：体内剥掉注释与字符串后，除空白与 `;` 外没有任何语句 ⇒ 空实现。**含注释体与 `catch (_) { ; }`**，不是只认 `{}`。；**判据分母（out/P0_truth.json）**：out/P0_truth.json 相对基线无变化（2217 个数值叶）；受钉文件 40 个；基线 baseline-p6p0 以来 test/ tools/gate/ ACCEPTANCE/RUBRIC 无实现类 agent 改动；门禁自身未提交改动 11 个，已在 out/GATE_P0_selfchanges.txt 逐条自报）

### 失败项
| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| P0.1a 锚点残差（只用 pupil 锚点）：成片端到端残余 |residual| ≤ 1.5°，中位 ≤ 1.0° | /residual/ ≤ 1.5，中位 ≤ 1.0，样本 ≥ 8 张不同照片（数**不同照片**，不数行数） | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.1b 条件覆盖率：真值 |tilt| > 1.5° 的锚点必须给出 pupil 估计，unavailable 必须 = 0 | 需要摆正的 8 条锚点上 unavailable = 0 | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.2 不引入歪斜：已知竖直样本残余 ≤ 1.5°，且 uprightSynthetic 必须返回 pupil | /residual/ ≤ 1.5 且 9 张 uprightSynthetic 全部 source=pupil | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.3a 旋转等变：① 估计值 vs 真值斜率 ∈[0.85,1.15]（只作诊断）；② 成片残余 vs 真值斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°（硬判据，口径无关） | ② 斜率 /·/ ≤ 0.15、/截距/ ≤ 0.5°、max/残余/ ≤ 1.5° | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.3b 旋转夹具条件覆盖率：真值 |tilt| > 1.5° 的夹具上 unavailable 必须 = 0 | 需要摆正的 67 条夹具上 unavailable = 0 | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.4 诚实性与分布：报告 RollSource 分布；unavailable 的施加角必须 = 0.0；禁止回退到 YuNet 眼睑路径（夹具里不得出现 given） | unavailable 样本施加角 = 0 的违规数 = 0，且不得出现 source=given | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.5a 不回归：dev_selfcheck 9/9 | 退出码 0 且 通过 ≥ 9、失败 = 0 | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.5b 不回归：2B.8 摆正几何（成片实测旋转 = 真值 − 施加角） | 两个**分开报**的子量都要过：① 施加几何 —— SIFT 实测施加角 vs 生产记录 /差/ ≤ 1.5°；② 跨量具一致性 —— 眼线实测残余 vs (真值−施加角) ≤ 1.5° | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| P0.5c 不回归：2B.8 之外的 G2B 项 / G4 已过项不退化（判据只覆盖"原本通过的项"） | 原本通过的项重跑后仍 PASS；本项需重跑才能判定 | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |
| AC ACCEPTANCE 防作弊条款 1–6 | 0 命中 | **本轮无效：工作树未冻结（`git status --porcelain -- lib test tools docs` 非空，唯一豁免 `docs/PITFALLS.md`）：M lib/core/matting/iris_roll.dart、M test/batch/code_fingerprint.dart、M test/batch/p0_finalize_v1.py、M test/gate/anticheat_test.dart、M tools/gate/anticheat.dart、M tools/gate/gate_P0.dart、?? tools/gate/sha256.dart；100 条样本里有 13 条的成片文件不存在** | gatekeeper（本轮输入不可信，不计实现方责任） |

### 回派指令
- gatekeeper（本轮输入不可信，不计实现方责任）：P0.1a、P0.1b、P0.2、P0.3a、P0.3b、P0.4、P0.5a、P0.5b、P0.5c、AC 未达标，详见上面各项「实测」。

### 哈希（本轮 pre-run 快照）
```
88168ba872229f3af1ea3c93e3218f65a9387fb269ae46174f878b1ed98a8cf5 *docs/ACCEPTANCE.md
5a894bf3ec6c312a964e1171419cc4db3d3f939f4500f4286bd50e5d83172e8a *docs/RUBRIC.md
026fcafbd8cec1d7f4f16565d5ccdda46637d824fabc6109acf0b347ae8ad7e2 *integration_test/_generated_compose_harness.dart
735056b60fc7c8a6e5b0032c6539c69aba12ac807ff43ab3bae53cc2ea1eae96 *integration_test/_generated_matting_harness.dart
0d43fe17f0815b31985832314e830ef9f8ea4f98a086ea181aede9fcfe9661eb *integration_test/coldstart_probe_test.dart
88ce7f72c0ade43b4a3129102cc2fd08a9d461259a67103b2468801853287da9 *integration_test/compose_eval_test.dart
7a7f57d14179995c08381c4f540ff1821691bcfff9981791edb6d43e304d52a4 *integration_test/e2e_eval_test.dart
48d5d518a4b3575caac9d17a3c0dbec5767cef3ec108e9e54ccc62e330554dd7 *integration_test/g4_memcheck_test.dart
b1bf96c11240cfa22ebe2a8060d19589e5d468e5ffe2eee62285b7f1b57dbb24 *integration_test/g4_spotcheck_test.dart
78bf239f5fdb50b89db9dadf0e1d3ab1d9bbec5514a7e7d5731c22bc9d59e559 *integration_test/matting_eval_test.dart
f154b9531c2f64c7def1c492a46d82dc095f7b2dbd76c0d4334720f24a4f71ee *integration_test/shots_test.dart
af371627b429da5d1f3a79d1a4099019260e1715818c7378f305d15bda1a52fd *out/P0_truth.json
4ccae0dec979ecb666140a502e14fcbad22625274efba262125ff3140b9bdc50 *test/gate/anticheat_test.dart
cab1484dc6ec589ff2dee840d86e5eac100b7397d7d1a75cefb4783f969734c7 *test/gate/crop_interaction_test.dart
c1e46c1451fd1d20d8590cf63c567c2ae24c8f57121e3d5aacc68189ddd679a2 *test/gate/p0_gate_judgment_test.dart
e70252c19e753eabb2b7e90d0d0580092df7e2af239de2acfbffb42b56a62ad0 *tools/gate/anticheat.dart
be3b1bc435e52c78d1bb9fcf43b8947a8a7a6d11dc83f473cf6e417ed531056c *tools/gate/capture_shots.dart
b9b238773350d61d5dedb08011f5594a327839c73b78bd068589f9a3e06dd232 *tools/gate/collect_metrics.dart
9ef0e19a1f5eed8ec0c5775b6c64afa21ddcd2a345251b6bad203f7d4d2ac828 *tools/gate/color_utils.dart
b675395b6742cac303b5fe35aaf257de2f135331174f4cfe18d8203c5944c93a *tools/gate/compose_check_utils.dart
0627a197f1037cf989d8ecef9cf10d48cc5521d3acdd65cb6600e3438bf2c8db *tools/gate/device_harness_common.dart
14a866ce0afa322b663fcdf74a4bc59dffee300ef3b3d886754e0ddb44354087 *tools/gate/g4_release_memcheck.py
ef5b216cd07fec30e73db7aae255a3df0c825d6b11a83fb60f09948be774b224 *tools/gate/gate_G1.dart
0dd1c12ca3ac307879c332ccc0bbac77acaa3643d54371bbbfe27c14cc30972b *tools/gate/gate_G2A.dart
c0374529ba4044e60df9ba1b0d7136946ab0e1ebfe849691ac324c8c9ff5999b *tools/gate/gate_G2B.dart
d5657019230268e08e994eede53a4e3cc2a8a04ddaea71c77e8dd7985ea2aea0 *tools/gate/gate_G2C.dart
5be8abb0e457d1a26952a994cf7e9850ce79fc11f301b44e4f248a53cbaa3606 *tools/gate/gate_G3.dart
f2e6744265cc246b9f1ba498dc875e069fdfebbea29f677cbeefd51c109071e6 *tools/gate/gate_G4.dart
5ee6d8c75e22df71db5af180865203fae88056c7b4901f8fba4bb263e09f701b *tools/gate/gate_G5.dart
c1048040824c8bb00487a73e44b6df60b479347fddbfac78940635b3625ecfe0 *tools/gate/gate_G5B.dart
998a87b0383f722a78053428e9935c2cb9c6cfe295b10b506fd3d8720f0724b1 *tools/gate/gate_P0.dart
527e5584750f517d3f8ecb4767c804027b24a5bea1b9523ce6ee2673b67279a5 *tools/gate/gate_common.dart
55a02caf2e5ba3b329ce1448fc4669dc52da2cf4796f1d439c575db929009f75 *tools/gate/jpeg_utils.dart
9bf78e113a34a2c9e90197bc842f2fca1a8999ae3507176f95b1fa1306889be4 *tools/gate/p0_eyeline.py
7c30c6ee828d02f77159392a4aae0d979884f8dbf48f9bcd5b61033823be13ef *tools/gate/p0_overlap.py
8a46d89c013acfb61a209e467036ffaf32eb734463e8cda4ba1082b8a96a5b08 *tools/gate/p0_rigid_check.py
8fc0270be7475a702d4d71735b3f327db72ffd116091ba739e343c73249d81f0 *tools/gate/p0_roll_probe_test.dart
fb0711446e483b8a1fc72f549516fec7fcd2fcbaf6eaf4d933456a59587c3ae2 *tools/gate/png_utils.dart
45ada1647fc0766a7dbf594d015274b5252850a8b43f62925db9ba629fb712b0 *tools/gate/rot_dir_check.dart
86ccf34ec2b960f74727cd0bf528a42f4337fcf8b92c35a2c6ab15675d167c0a *tools/gate/sha256.dart
```
