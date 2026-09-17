## G2B-P0 第 2 轮：FAIL
## 通过 10 / 12 项，MANUAL 项 1 个
## 脚本完整性：OK（本轮自报改动：19 个，见 out/GATE_P0_selfchanges.txt）
## 防作弊巡查：清白

> **条款 1 的执行史（每轮必读）**：`git()` 原用 `runInShell: true`，参数被喂给 `cmd.exe` 后 `%s` 被吃掉 → 命令 exit 255、stdout 为空，而空输出被读成"没有改动"。**条款 1 直到 `7773df4` 才真正执行**（修后同一命令在真实仓库上给出 219 条改动路径，修前 0 条）。因此 **`7773df4` 之前所有轮次的「防作弊巡查：清白」在条款 1 上是空的，不得被引用为历史**（不许写"上一轮还是清白的"）。条款 3 / 条款 5 有各自的同类失效史（`grep` 子进程被 Windows 吃掉模式字符），见第 1 轮勘误。

### 扫描区域（**含 0 与「根本没扫」**）
| 区域 | skip（条款 3） | 注释掉的断言（条款 3） | 空 catch（条款 5） |
|---|---|---|---|
| `lib` | 67 个文件 / 0 命中 | 67 个文件 / 0 命中 | 67 个文件 / 0 命中 |
| `test` | 23 个文件 / 7 命中 | 23 个文件 / 0 命中 | 23 个文件 / 0 命中 |
| `tools/gate` | 22 个文件 / 26 命中 | 22 个文件 / 0 命中 | 22 个文件 / 0 命中 |
| `integration_test` | 9 个文件 / 0 命中 | 9 个文件 / 0 命中 | 9 个文件 / 0 命中 |

**刻意不扫的区域（连同理由）** —— 「没扫」与「扫过、0 命中」在报告里长得一样，所以必须分开写：
- `native/`：主会话 2026-09-17 裁定**不纳入**条款 5。它是 ml-porting 的基准/对照试验目录（`native/bench/`），不是交付代码：不进 App、不进测量链。其中 `iris_order_control_test.dart` 刻意保留一个"已知会变红"的正向对照，那处若被条款 5 扫到会被判违规，而它恰恰是证据本身。**注意这不等价于"native/ 干净"** —— 它意味着本门禁对它没有读数。
- `android/`：release 的势力范围（构建/权限/签名），条款 3/5 不覆盖；它的风险面（联网权限、SDK 依赖）由条款与 `/security-review` 覆盖，不由源码扫描覆盖。
- `ios/`：本阶段不打包（开发机无 Xcode，见 CLAUDE.md §2.5）；同样不在扫描范围内。
- `assets/`：模型/材质/字体，非源码；无 `skip:`/`catch` 可扫。
- `out/`：共享输出目录，**每轮重生成**。扫它等于把上一轮的产物当本轮的证据，而且 `out/P0_selftest_tmp/` 里是源码的完整副本（会双倍计数）。
- `docs/`：文档，非源码。`docs/ACCEPTANCE.md` 与 `docs/RUBRIC.md` 由条款 1 的diff 与条款 2 的 SHA256 两条独立通道保护。
- `store/`：store-assets 的势力范围，非交付代码。

**三处扫描循环共用同一个常数 `kScanRoots`**（`tools/gate/anticheat.dart`）：三份列表只要有一次不同步，就会出现"条款 3 扫了某区域、条款 5 漏了它"这种没人会发现的覆盖缺口，而报告里两条都写着"命中 0"。


规格：`cn_big_1inch`（ACCEPTANCE P0.1a 指定）；真值（生成件，判据读它）：`out/P0_truth.json`；真值（手写件，内容钉钉它）：`out/P0_truth_v0.json`；生产记录：`out/P0_compose_items.jsonl`；gatekeeper 独立测量：`out/gate_P0_eyeline.json`。

### 判据版本声明（ACCEPTANCE 冻结条款要求写明）
本轮判决依据的判据 = `docs/ACCEPTANCE.md` @ commit `6f01e6e`（P0 判据冻结点）。
**第 1 轮初判作废的原因**：主会话在门禁运行期间于 03:23 / 03:24 / 03:39 / 03:47 连续四次修改 G2B-P0 判据，本门禁初版按改动前的草稿实现，且判据被从"读 `ComposeDiagnostics.straightenDeg`"改成"只认成片端到端残余"——初版判的正是新法典明令不作判据的量。故初判作废，本文件是**按冻结版判据重跑**后的第 1 轮结果，不消耗实现方的修复轮次。详见 `docs/ACCEPTANCE.md` 的「判据冻结声明」。

### 轮次记账（主会话 2026-09-17 裁定，按 CLAUDE.md §7「最多 3 轮修复」）
第 1 轮是**重写轮**（判据被中途改动致初判作废），**不消耗** ml-porting 的修复预算。
ml-porting 有 3 次修复机会，对应门禁运行 **r2 / r3 / r4**；r4 仍 FAIL → 写 `out/BLOCKED_G2B-P0.md`，全流程停止等人工，不降阈值、不删夹具、不跳门禁。
本轮按 `r2` 编号。

### 轮次有效性判定（主会话 2026-09-17 裁定，**r2 起生效**）
> **一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来。**任何一项判据的输入若来自另一个状态（不同工作树、不同 revision、不同测量台的上一次产出），**要么重测，要么把该项标为无效**。
机检七件：① `git status --porcelain -- lib test tools docs` 为空（`out/` 除外）；② 每条样本都解析得到、成片文件都在；③ 声明条数 == 实际解析条数；④ 样本清单里**没有解析不了的行**；⑤ **`out/` 下三份测量产出各自记录的代码指纹与当前树逐条一致**（`out/` 不受冻结约束，所以"工作树干净"推不出"盘上的数是当前代码跑的"——缺这一条，上一轮的遗留会被当成本轮读数）；⑥ **生成分母与手写分母逐条相等**（`denominatorAgreement`）；⑦ **派生块的证据溯源与盘上产物相符**（`evidenceProvenanceCheck`）。任一不过 → **整轮作废**（全部条目 pass=false、manual=true），不消耗实现方修复轮次。**加一行说明拦不住它**——r1 就是这么滑过去的，所以这里是判 `roundInvalid` 而不是写备注。⑥⑦ 有一条分工要说清楚：**「取不到」判作废（不赖实现方），「取到了但不等」判 FAIL 并点名**（那是判据分母被动过的措辞，不是输入不可信的措辞）。
**本机制晚于 r1**：r1 的 FAIL 判决（P0.3a max 11.368°、P0.3b 9 条）按主会话裁定**保留为基线测量**，不因本机制追溯作废；但它**不是对任何单一代码状态的判决**，不得用来论证"改了一轮没修好"。


### 本轮输入的一致性（读数绑在哪个版本上）
- HEAD = `4e33340`；判 selfcheck 那几条（P0.5a）编译自**工作树**，不是这个 commit。
- `git status lib/` **干净**：本轮读数可绑定到 `4e33340`。
- **冻结范围**：`lib` / `test` / `tools` / `docs` **全部在冻结内**；唯一豁免 `docs/PITFALLS.md` 这一个文件（它不进任何测量链——门禁不读它、判据不引用它、读数不经过它；且 CLAUDE.md §4 规定所有 agent 可随时只追加）。**`docs/` 里除它以外的任何改动（含 `ACCEPTANCE.md`/`RUBRIC.md`/`CONTRACTS.md`/`DESIGN.md`/`ENV.md`）仍会作废整轮。**本轮豁免条目： M docs/PITFALLS.md。
- 输入完整性：`out/P0_compose_items.jsonl` 声明 100 条、解析到 100 条，成片文件**全部存在**。注意这只说明"此刻文件在"，**不等于历史轮次可复算**。
- 成片台 summary：`crash=0`、`cases=100`、`ok=110`、`mattingFail=0`、`composeFail=0`、`noFace=0`。
- 三件套齐备，本项可判。


### 测量产出的来源绑定（`out/` 不受冻结约束，所以另有一道绑定）
- 3 份测量产出均可自证与当前树同源（受钉源码 103 个文件 = `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`；代码摘要 0f66aabb3c08105f）；标定靶：test/golden/src/g01.jpg 与内容钉一致（sha256=25b14d07b1375bc3…）
- 指纹域（**由门禁定义，不由生产者定义**）：`lib`、`test/batch` 下全部 `.dart` / `.py`，共 103 个文件；门禁侧 git 可用 = true；代码摘要 `0f66aabb3c08105f`。生产者记录的是超集也接受，**缺任何一个都判不可判**——域若能被生产者收窄，这个检查就形同虚设（少记一个文件 = 那个文件改了也不响）。
- **实际域文件清单（本轮逐行，可直接 diff 上一轮）**，共 103 条：

```
lib/core/api.dart
lib/core/controller.dart
lib/core/engine_impl.dart
lib/core/image_header.dart
lib/core/imaging/compose_engine.dart
lib/core/imaging/compose_only_engine.dart
lib/core/imaging/crop_geometry.dart
lib/core/imaging/dev_compose_memprofile.dart
lib/core/imaging/dev_gate_repro.dart
lib/core/imaging/dev_pool_audit.dart
lib/core/imaging/dev_pool_bitcheck.dart
lib/core/imaging/dev_repro_g4.dart
lib/core/imaging/dev_roll_ab.dart
lib/core/imaging/dev_roll_markers.dart
lib/core/imaging/dev_roll_probe.dart
lib/core/imaging/dev_roll_probe2.dart
lib/core/imaging/dev_roll_repro.dart
lib/core/imaging/dev_roll_scale.dart
lib/core/imaging/dev_selfcheck.dart
lib/core/imaging/dev_synth.dart
lib/core/imaging/jpeg_dpi.dart
lib/core/imaging/matte_clean.dart
lib/core/imaging/render.dart
lib/core/matting/flutter_decode.dart
lib/core/matting/image_header.dart
lib/core/matting/image_ops.dart
lib/core/matting/iris_roll.dart
lib/core/matting/matting_engine.dart
lib/core/matting/matting_worker.dart
lib/core/matting/ort_runtime.dart
lib/core/matting/session_factory.dart
lib/core/matting/yunet_decoder.dart
lib/core/specs/photo_specs.dart
lib/main.dart
lib/ui/app.dart
lib/ui/areas/area_a_source.dart
lib/ui/areas/area_b_candidates.dart
lib/ui/areas/area_c_save.dart
lib/ui/dev/fake_controller.dart
lib/ui/dev/fake_thumbs.dart
lib/ui/dev/mouse_wheel_scroller_selftest.dart
lib/ui/dev/sample_photo.dart
lib/ui/dev/shot_app.dart
lib/ui/dev/shot_harness.dart
lib/ui/state/photo_source.dart
lib/ui/state/providers.dart
lib/ui/theme/brass.dart
lib/ui/theme/fonts.dart
lib/ui/theme/noise.dart
lib/ui/theme/paper_painter.dart
lib/ui/theme/surfaces.dart
lib/ui/theme/tokens.dart
lib/ui/theme/typography.dart
lib/ui/theme/wood_painter.dart
lib/ui/util/crop_geometry.dart
lib/ui/util/error_text.dart
lib/ui/util/image_size.dart
lib/ui/widgets/about_sheet.dart
lib/ui/widgets/candidate_card.dart
lib/ui/widgets/crop_overlay.dart
lib/ui/widgets/developing.dart
lib/ui/widgets/metal.dart
lib/ui/widgets/mouse_wheel_scroller.dart
lib/ui/widgets/press_effect.dart
lib/ui/widgets/spec_drawer.dart
lib/ui/widgets/spec_ruler.dart
lib/ui/widgets/sync_raster.dart
test/batch/batch_runner.dart
test/batch/build_golden.py
test/batch/build_grid.py
test/batch/code_fingerprint.dart
test/batch/code_fingerprint.py
test/batch/fingerprint_selftest.dart
test/batch/freeze_dataset.py
test/batch/merge_results.py
test/batch/p0_alpha_dump_test.dart
test/batch/p0_alpha_holes.py
test/batch/p0_alpha_scan_test.dart
test/batch/p0_c08_sensitivity.py
test/batch/p0_cases.dart
test/batch/p0_compose_test.dart
test/batch/p0_coverage_split.py
test/batch/p0_coverage_test.dart
test/batch/p0_diff_rounds.py
test/batch/p0_est.py
test/batch/p0_finalize.py
test/batch/p0_finalize_v1.py
test/batch/p0_independent_roll.py
test/batch/p0_lib.py
test/batch/p0_measure.py
test/batch/p0_output_residual.py
test/batch/p0_provenance_check.py
test/batch/p0_residual.py
test/batch/p0_resolve_check.dart
test/batch/p0_rotate.py
test/batch/p0_selfcheck_run.dart
test/batch/p0_sheet.py
test/batch/p0_verify_geo.py
test/batch/prepare_inputs.py
test/batch/run_device.py
test/batch/run_realdevice.py
test/batch/sha256_selftest.dart
test/batch/sha256_util.dart
```

  - `out/P0_compose_summary.json` → **OK**：out/P0_compose_summary.json[provenance.codeFingerprint] OK：103/103 个受钉源码文件的 blob 哈希与当前树逐条一致
  - `out/P0_output_residual.json` → **OK**：out/P0_output_residual.json[summary.provenance.codeFingerprint] OK：103/103 个受钉源码文件的 blob 哈希与当前树逐条一致
  - `out/P0_alpha_holes.json` → **OK**：out/P0_alpha_holes.json[provenance.codeFingerprint] OK：103/103 个受钉源码文件的 blob 哈希与当前树逐条一致
- **量具标定靶**（`tools/gate/p0_eyeline.py selftest` 注入已知角用的那张图，`test/golden/src/g01.jpg`）：test/golden/src/g01.jpg 与内容钉一致（sha256=25b14d07b1375bc3…）。
  - 标定靶是 `test/` 下的**冻结夹具源**（入库、被条款 1 的 `test/` 冻结与 git 历史双重覆盖）——**不是** `out/P0_anchors/composed/` 的成片。后者是可再生的混合态：2026-09-17 实测只剩 93/110（一次脏树轮的覆盖顶掉了 17 张）。把量具的自证挂在一张随时可能不在的成片上，「量具没自证」与「量具不准」会报成同一个结果。
  - 钉里同时记「当时是哪份代码」（代码摘要）：只钉内容的话，代码一改、产物跟着重生成，读数天天变，这个钉会退化成噪声；配上代码摘要才能把「换份代码重跑」（预期）与「代码没动但文件被换」（不允许）分开。
  - **重钉只发生在前一条成立时**（测量产出确实绑上了当前代码）；产出绑不上时盘上的标定靶是**上一版代码**留下的，把它钉到当前代码摘要上就是就地洗白，下一轮再也看不见。
- 结论：**绑定成立**，本轮读数可用于判人。


### 判据分母的内容钉（out/P0_truth_v0.json 手写件）与**豁免清单**
缺少 `truthDriftResult`，**无法证明判据分母未被改动** → 判不可判，不判通过。

### 判据分母的一致性（生成的 out/P0_truth.json 是不是手写件的分母）
- 手写分母 `out/P0_truth_v0.json`（sha256 前缀 `7aea984c53088cb5…`） vs 生成分母 `out/P0_truth.json`（`9ed47a791f161f90…`）
- **比对范围由手写件决定**（不硬编码清单名）：手写件里每个**列表**值都要在生成件里逐条对上 —— 生成件不得改动或丢掉任何一条，也不得缺少手写件写了任何一个字段。生成件**自己的派生字段**（`corpus` / `kind` / `derivedAnnotations` / `end_to_end` …）不参与比对：它们是产物，不是分母。
- 比了 anchors=12条、nonPortrait=66条、rejected=1条、rotated=78条、straight=1条、uprightSynthetic=9条；登记豁免 1 条（anchors/p2）；v0 没有、故**未比**的生成件清单：knownLimitations；因形状豁免**未逐值比**的字段：methods×13（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）
- 结论：**逐条相等**。
- **不许被读大**：这一条证明"生成件用的是手写件的分母"，**不证明**这份分母本身是对的。前者是完整性，后者要靠锚点复核与人工审查。


### 派生数字的证据溯源（叙述是不是盘上产物的函数）
- 指针（写死在门禁里，不随数据飘）：`gateInputs/rotationFailureBoundary/evidenceProvenance/sourceSha256`
- 核了 3 份源产物：out/P0_output_residual.json=一致、out/P0_compose_items.jsonl=一致、out/P0_alpha_holes.json=一致
  - `out/P0_output_residual.json`：记录 `249a56ec358f9f5a…`，盘上 `249a56ec358f9f5a…`
  - `out/P0_compose_items.jsonl`：记录 `aea8b3cc9ab95f75…`，盘上 `aea8b3cc9ab95f75…`
  - `out/P0_alpha_holes.json`：记录 `67497012047ee087…`，盘上 `67497012047ee087…`
- 结论：**逐份相符**。
- **边界（不许被读大）**：这证明的是「派生叙述与盘上这几份产物一致」，**不是**「产物出自当前被测代码」—— 源产物自己**没有**代码指纹。后一件事由「测量产出的来源绑定」那一节管，两件事别混。


### 硬判据出自哪支量具（避免把量具差异读成分歧）
- **P0.1a / P0.2 / P0.3a② / P0.5b** 的成片残余：gatekeeper 的 **Haar 眼线量具**（`tools/gate/p0_eyeline.py`，自检最大误差见上）为第一读出；它测不出的样本改由 **SIFT 源图↔成片配准**（`tools/gate/p0_rigid_check.py align`）读出，逐条出处写在样本账里。
- **交叉复核**用的第二支是 qa-batch 的瞳孔法（`out/P0_output_residual.json`），两者是独立量具：同一张成片上读数可以不同（共同可测 **87** 条上 |差| 中位 **0.397°**、最大 **1.017°**，逐条与口径见下节「交叉复核」），但只要两者都远超阈值就不构成分歧。**报告里的硬指标一律注明出自哪支**。

> **2026-09-17 更正（勘误 11）**：本行原先写"本轮最大差 **1.414°**"，与下节「交叉复核」的
> **1.017°** 是同一个量却给了两个数。按产物现值复算：**87 条、中位 0.3974°、最大 1.0171°**
> （最大那对是 `c05_d+5`：门禁 1.1233° / qa 0.1062°）。**1.414° 无法从当前 `out/` 产物复现**，
> 按"数不出处即作废"处理，以下节为准。
- 口径无关性：SIFT 只量"管线实际转了多少度"，不读眼线、不读 alpha、不读生产诊断，是符号约定出错时唯一不会跟着一起错的路径。

### 量具自检（量不准的量具没有资格判别人）
- 眼线量具：最大误差 0.4101256717524797°，门槛 0.5° → 合格
- 刚体配准量具：最大误差 0.5°，门槛 1.0° → 合格
- 两条路径的独立测量一致性：见「交叉复核」一节
- 门槛由**门禁**定（不是工具自报）：眼线量具喂亚度级统计，故要求 0.5°；刚体量具只用于 ≥1.5° 量级的分歧复核，1.0° 够用。

### 交叉复核（gatekeeper 眼线量具 vs qa-batch 眼线测量）
共同可测 87 条：|差| 中位 0.397°，最大 1.017°。**原始读数** |成片倾角| > 1.5° 的集合（不是违规计数，违规还要按条件覆盖率口径折算）：gatekeeper 2 条 / qa-batch 1 条，qa-batch 的集合**是** gatekeeper 的子集——它报出的每一条超标本量具都独立复现；双方一致判定达标的 85 条。两条路径的系统性差异约 0.40°（不同方法：Haar 眼级联 vs YuNet 眼位+暗色圆盘+Radon 共识），小于判据容差 1.5° 的 1/3，足以互相印证，不足以单独定案——故凡两条路径读数相差 > 1° 的样本，判定一律回退到独立第三方证据（生产记录 + 已验证恒等式）。

SIFT 路径：可配准 98 条，**实测施加角 vs 生产记录 |差| 最大 0.077°，超 1.5° 的 0 条** —— 这条说的是"源图→成片这一跳有没有被正确施加"，与成片最终歪不歪是两件事。

> **2026-09-17 更正（勘误 10）**：本句原先写"它测出**残余**超 1.5° 的样本 0 条（）"，**口径含混**。
> 按该量具的 `residual_deg` 字段（= 真值 − 实测施加角 = **成片最终倾角**）实测：
> **98 条里有 1 条超 1.5°，正是 `c06_d-3`（−4.7419°）**。
> 两种读法一真一假，而**假的那个方向刚好把我的最强证据埋掉了** ——
> `c06_d-3` 的 −4.7419° 正是"这张成片真歪"的**免眼**独立证据（勘误 8）。
> 根因同上一轮记的「字段只用名字宣称口径」：`施加角与记录的差` 与 `成片残余`
> 是两个不同的量，都被我叫作"残余"。**数字必须与它的定义同句出现。**

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

没有样本"因为量不出来而不算数"：眼线量具测不出的 12 条中，**10 条**改由 SIFT 源图↔成片配准独立测出（残余 = 真值 − 实测施加角），**另 2 条（`c08_d-10`、`c08_d+3`）两条路径都测不出**，其残余由已验证恒等式推出，**不是实测值**，已单列在 P0.5c（MANUAL）里待人工介入。逐条如下。

> **2026-09-17 更正（勘误 9）**：本句原先写的是"**全部改由 SIFT 独立测出**"，
> 与紧邻下方的表格**直接矛盾**（表里 10 条 `gate_sift_align`、2 条 `derived_identity`）。
> 同勘误 7 的成因：散文写于 SIFT 尚能配上那两条之时，产物重生成后表格跟着变了、散文没变。
> **方向尤其要不得**：这句话把**样本账的覆盖说大了**，
> 而 ACCEPTANCE 计分口径第 7 条（样本不得静默消失）恰恰是防这个的 ——
> **假绿不是假红**。核对方式：`out/gate_P0_sift_align.json` 现为 `n_ok=98/100`，
> 失败的两条正是 `c08_d-10`（`inl=67, scale=0.000`）与 `c08_d+3`（`inl=63, scale=0.000`）。

| 样本 | 眼线量具为何失效 | 归类 | SIFT 独立复核 | 最终取值 |
|---|---|---|---|---|
| c08 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -7.865°，与生产记录差 -0.014° → 残余 -0.145°；qa-batch 读数 0.465°（ok） | -0.145°（gate_sift_align） |
| c08_upright | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效）**且眼带被 alpha 打掉 61.9%** | SIFT 实测施加角 0.019°，与生产记录差 0.019° → 残余 -0.019° | -0.019°（gate_sift_align） |
| c08_d-10 | no_face | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 也配不上——这条仍未测出，须人工介入。 | -18.010°（derived_identity） |
| c08_d-5 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效）**且眼带被 alpha 打掉 75.5%** | SIFT 实测施加角 -12.801°，与生产记录差 -0.009° → 残余 -0.209°；qa-batch 读数 2.028°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.209°（gate_sift_align） |
| c08_d-3 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -10.892°，与生产记录差 0.002° → 残余 -0.118°；qa-batch 读数 0.522°（ok） | -0.118°（gate_sift_align） |
| c08_d+3 | no_face | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 也配不上——这条仍未测出，须人工介入。 | -0.417°（derived_identity） |
| c08_d+5 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -2.840°，与生产记录差 0.011° → 残余 -0.170°；qa-batch 读数 5.755°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.170°（gate_sift_align） |
| c08_d+10 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 2.169°，与生产记录差 -0.002° → 残余 -0.179°；qa-batch 读数 -3.445°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.179°（gate_sift_align） |
| c11_d-3 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -2.694°，与生产记录差 -0.009° → 残余 -0.416°；qa-batch 读数 -0.487°（ok） | -0.416°（gate_sift_align） |
| c12_d-10 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -12.011°，与生产记录差 0.007° → 残余 -0.079°；qa-batch 读数 0.005°（low_confidence） | -0.079°（gate_sift_align） |
| c12_d-3 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -5.121°，与生产记录差 -0.004° → 残余 0.031°；qa-batch 读数 0.345°（ok） | 0.031°（gate_sift_align） |
| c12_d+10 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 7.913°，与生产记录差 -0.001° → 残余 -0.003°；qa-batch 读数 -0.059°（ok） | -0.003°（gate_sift_align） |

**条款 7 点名的那条（`c08_d+10`）的定论**：它的 alpha 是干净的（qa-batch 扫到 eyeBandZeroFrac 0.002），却被 qa-batch 的自证式检查判为 unreliable，正是"把真实缺陷归成量不出来"的现成嫌疑。本门用 SIFT 独立量了源图→成片这一跳：实测施加角 2.169°，与生产记录 2.171° 差 -0.002°，残余 = 真值 1.990 − 实测施加角 = **-0.179°**，|残余| ≤ 1.5° → **不构成违规**。qa-batch 那一支的 -3.445° 是量测假象，它自己也已标注 reliability_mismatch。（顺带纠正一处易错：`c08_d+10` 的真值是 −8.01+10 = 1.990°，不是 18.01°；18.01° 是 `d-10` 那条，它反而被正常摆平到 -18.010°。）

三台量具在 c08 家族上的对照（同一批成片，互不调用）：眼线量具全部失效；SIFT 配得上其中 10 条、配不上 `c08_d-10` 与 `c08_d+3`；qa-batch 的 pupil 法在 4 条上给出被它自己否掉的数。

> **2026-09-17 更正（勘误 7）**：本段原先写的是"**SIFT 全部配得上**"，并称
> "`c08_d-10` 的眼区被抠图打掉 96.8%，SIFT 仍给出与生产记录差 0.032° 的读数"。
> **该说法与同一页上方样本账表格互相矛盾，且按当前产物是错的。**
> 以 `out/gate_P0_sift_align.json` 现值为准：`n=100`、`n_ok=98`，
> **失败的两条正是 `c08_d-10` 与 `c08_d+3`**，原因均为
> `weak_alignment(inl=67/63, scale=0.000)`。**这两条的残余是 `derived_identity` 推出来的，
> 不是测出来的**，已在样本账表与 P0.5c（MANUAL）里如实标注。
> **错因**：本段散文写于 SIFT 尚能配上 `c08_d-10` 之时（当时读数与生产记录差 0.032°），
> 其后 `gate_P0_sift_align.json` 被重新生成、行为改变，**而这段散文没有跟着失效**。
> 一个自洽但过期的陈述比一个明显错误的数字难发现 —— 本门在别处反复讲这句话，
> 自己却犯了同一种。详见 `docs/PITFALLS.md`。

**顺带发现：1 条须回派，1 条经代码复核后关掉**
1. **【独立的 G2B 缺陷｜归属 imaging｜处置时序"P0 PASS 后"】紧取景源图的裁剪框落到源图之外，成片留下底色填充的切口。****它不是 P0 的失败项**——P0 判的是摆正估计的准确性，本条与摆正无关；记在这里，只是因为本门为了量摆正把成片逐张渲染出来时看见了它。
   本门**渲染成片逐张看过**，不是只看指标：真实照片 `C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_11_Pro.jpg`（`c08`）的成片人头占满上部、**下巴被下边缘切掉**、下缘约三成是空白底色；它的竖直副本 `c08_upright`（`straightened=false`，**没做任何旋转**）同样坏，越界 29.0%。
   **疑似是两种不同的缺陷，请 imaging 逐张判、别统一成一条**：① **裁剪**——`c08` 下缘是**水平**切口（取景框伸到图片下边界之外）；② **抠图**——同一张成片左侧中部与右侧中部**各有一团孤立碎屑**（浮在空白背景里、与人物不连通），属 G2A/2A 口径，不是裁剪。`p1` 的切口则是**斜的**（左下），与 `c08` 的水平切口形态不同，所以**可能不止一种机制**。
   指标分布（`cn_big_1inch` 100 条）：越界 >0 共 73 条、>0.10 共 40 条、>0.20 共 26 条，中位 0.0423，最大 `c05_upright` 43.5%；用户自己的照片 `p1` 15.4%、`p2` 2.1%。
   **两条必须写清楚，免得被读歪**：① **不是旋转造成的**——最坏的两条 `c05_upright` / `c08_upright` 恰恰没旋转，`c05` 家族跨 Δ 无单调趋势（Δ=0 → 0.360，d+3 → 0.429，d+10 → 0.323，d−5 → 0.272）；② **越界比例本身不等于可见破损**——`c05` 越界 36.0% 成片仍然正常，真正肉眼可见破损的是 `c08` 与 `c08_upright`。**不要拿一个数字去推断严重程度。**
2. **`c08` 旋转夹具的眼区 alpha 空洞 = 夹具伪影 / 无用户影响**（不复判、不回派）。现象：源图先旋转再喂给管线时，c08 的旋转夹具眼区被 alpha 打掉（`c08_d-10` 96.8%、`c08_d-5` 75.5%、`c08_upright` 61.9%），而 Pictures 里 14 张未旋转人像的空洞率全为 0.0000（`out/P0_alpha_holes.json`）。裁定它不是产品缺陷，依据是生产路径**永远不会**把面内旋转过的图喂给抠图引擎——四条都由本门独立复核过，不是转述：`lib/core/controller.dart:137` 把用户原始 `bytes` 直传 `removeBackground`，同一份 `bytes` 在 `:146` 传给 `detectFace`，中间无预处理；`lib/core/matting/matting_engine.dart` 与 `matting_worker.dart` 内**没有任何**旋转/转置/仿射调用（grep 命中 0）；抠图前的唯一朝向处理是 `lib/core/matting/image_ops.dart` 的 EXIF `bakeOrientation`，它只可能是 90° 整数倍的转置，不产生任意面内角；面内旋转只出现在 `lib/core/imaging/compose_engine.dart:232` 的 `planRotation`，而 compose 跑在抠图**之后**。推论：该空洞需要"输入被任意角旋转过"这一前提，用户碰不到，故**既不进 P0 判据，也不进 G2A 判据，不回派**。本门采信它的唯一后果是：那几条不得不用 SIFT 兜底。

> **2026-09-17 更正（勘误 12）**：本段原先以"**不影响任何一条 P0 结论**"收尾 ——
> **该结论已被勘误 8 推翻，此处必须改口。** `c08_d-10` 正是 P0.3b 的**两条违规之一**，
> 而其 `unavailable` 的成因就是本段描述的这个眼区空洞。
> 即：本段论证的空洞，**恰恰是 P0 判据里一条违规的直接原因**，
> 不能一边说它"不影响 P0 结论"、一边用它定罪。
> 准确的表述见勘误 8：`c06_d-3` 的违规**与空洞无关、独立成立**（眼区干净）；
> `c08_d-10` 的违规**与空洞同源**，其是否计入已提请主会话裁定。


### 贴线项（余量 vs 量具误差）
| 项 | 子量 | 本轮实测 | 余量 | 该量具自检误差 | 结论 |
|---|---|---|---|---|---|
| P0.5b | **判据量** ① 施加几何 | 实测 0.077° | 1.423° | 0.500° | 余量 > 量具误差，稳过 |
| P0.5b | 辅助量 ② 跨量具一致性 | 实测 1.096° | 0.404° | 0.410° | **贴线**（余量 < 量具误差） |

- ① 施加几何（判据量）实测 0.077°，余量 1.423° → 余量充足。

- **P0.5b 的复核口径**：margin > instrumentErr 才是确定性违规；若 margin < instrumentErr，须 SIFT 路径独立复现同一超线才计违规，否则记「边界噪声 / 证据不足」，不消耗实现方修复轮次（本条不适用 P0.3a：P0.3a 超阈值 7 倍以上，两支量具均独立复现，按原样记 FAIL）（本轮第二支量具 未超线 → 若本项翻 FAIL 即属边界噪声）

规则（主会话 2026-09-17 裁定，与条款 7 同源）：余量 < 量具误差的条目，**单支量具的 FAIL 不足以定罪** —— 必须第二支独立量具复现同一超线才计违规；只有一支超线则记「边界噪声 / 证据不足」，不消耗实现方修复轮次。**本规则不适用于 P0.3a**：它超阈值 7 倍以上且两支量具独立复现，是确定性违规。


### 判定明细
#### P0.1a PASS
- 期望：|residual| ≤ 1.5，中位 ≤ 1.0，样本 ≥ 8 张不同照片（数**不同照片**，不数行数）
- 实测：
  可计分锚点 12 条 = **11 张不同照片**，下限 8 张不同照片
  去重口径出自 `out/gate_P0_overlap.json`（48×48 灰度签名逐对 MAE，≤5.0 记同图）：本轮判定 `c03≡c04` 为同一张照片（同图不同分辨率），故 11 行 → 10 张。**该量具分辨不了 `c10`/`c11`/`c12` 这类"同一场景的不同取景"**，声明不参与那三者的判定；法典条款 6 @ `98f3331` 裁定它们是**三张不同照片**、各自计数。量具不去重它们，方向上是保守的（只会让计数偏高、更容易过下限），因此不会制造假 FAIL，但也**不能**反过来用它论证"三张里有两张其实是同一张"。原始锚点栏 12 条，`p2` 不在锚点栏——它同现于 anchors 与 straight，成片台按 id 合并后归入 straight。
  max|残余| = 0.725，中位 = 0.312
  残余出处：{gate_eyeline: 11, gate_sift_align: 1}（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）
  p1: truth=-4.400 applied=-4.463 resid=0.162 src=pupil by=gate_eyeline
  c01: truth=-1.300 applied=-1.374 resid=0.305 src=pupil by=gate_eyeline
  c02: truth=-0.250 applied=0.000 resid=-0.144 src=pupil by=gate_eyeline
  c03: truth=-3.720 applied=-3.773 resid=0.640 src=pupil by=gate_eyeline
  c04: truth=-3.820 applied=-3.900 resid=0.644 src=pupil by=gate_eyeline
  c05: truth=-3.910 applied=-3.919 resid=0.318 src=pupil by=gate_eyeline
  c06: truth=-1.730 applied=-1.711 resid=0.725 src=pupil by=gate_eyeline
  c07: truth=-0.350 applied=0.000 resid=-0.451 src=pupil by=gate_eyeline
  c08: truth=-8.010 applied=-7.850 resid=-0.145 src=pupil by=gate_sift_align
  c10: truth=-3.440 applied=-3.624 resid=0.606 src=pupil by=gate_eyeline
  c11: truth=-0.110 applied=0.000 resid=0.286 src=pupil by=gate_eyeline
  c12: truth=-2.090 applied=-2.144 resid=0.297 src=pupil by=gate_eyeline
#### P0.1b PASS
- 期望：需要摆正的 8 条锚点上 unavailable = 0
- 实测：
  需要摆正（|truth| > 1.5°）的锚点 8 条，其中 unavailable 0 条
  |truth| ≤ 1.5° 而返回 unavailable 的 0 条，按口径 2 可接受：
#### P0.2 PASS
- 期望：|residual| ≤ 1.5 且 9 张 uprightSynthetic 全部 source=pupil
- 实测：
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
#### P0.3a PASS
- 期望：② 斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°
- 实测：
  ② 硬判据：残余 vs 真值 斜率 = -0.003（|·| ≤ 0.15），截距 = 0.230°（|·| ≤ 0.5），max|残余| = 0.000°（≤ 1.5）
  超 1.5° 的夹具 0 条：
  只用 pupil 夹具 97 条（原始 100 条）
  ① 诊断：估计值 vs 真值 斜率 = 1.001（带 [0.85, 1.15]，不参与 PASS/FAIL）
  按口径 1 排除在残余统计外的 unavailable 样本 3 条（它们的账由 P0.3b 条件覆盖率算，不许在这里被悄悄算成通过）：c06_d-3、c06_d+3、c08_d-10
  残余出处：{derived_identity: 1, gate_eyeline: 86, gate_sift_align: 10}（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）
#### P0.3b FAIL
- 期望：需要摆正的 67 条夹具上 unavailable = 0
- 实测：
  违规 2 条（需要摆正 |truth| > 1.5° 却返回 unavailable）：c06_d-3(truth -4.730°)、c08_d-10(truth -18.010°)——这 2 条成片未施加任何旋转，仍歪着对应角度
  旋转夹具原始总数 78 条，需要摆正 67 条
  |truth| ≤ 1.5° 而 unavailable 的 1 条，按口径 2 可接受
  分母：可计分 78 条 / 原始 78 条（无样本因量测失效被扣除，见条款 7 样本账）
#### P0.4 PASS
- 期望：unavailable 样本施加角 = 0 的违规数 = 0，且不得出现 source=given
- 实测：
  全量可合成样本 100 条，来源分布：{pupil: 97, unavailable: 3}
  锚点：{pupil: 12}；竖直：{pupil: 10}；夹具：{pupil: 75, unavailable: 3}
  unavailable 的施加角 ≠ 0 的违规 0 条；夹具里 source=given 的 0 条
#### P0.5a PASS
- 期望：退出码 0 且 通过 ≥ 9、失败 = 0
- 实测：
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
  00:16 +4: 2B.8 摆正（±10° 输入的残差角）
  [2B.8]
    输入 roll=-10.0° → 成片残差 -0.039°
    输入 roll=-6.0° → 成片残差 -0.034°
    输入 roll=6.0° → 成片残差 0.034°
    输入 roll=10.0° → 成片残差 0.039°
    输入 roll=0.8°（死区内）→ 是否旋转=false
    最差残差=0.039° (阈值 1.5°)
  00:17 +5: 用户框选 × 摆正：主体尺度守恒（REVIEW_G2 #3 回归）
  [用户框选×摆正]
    roll=0.0° 摆正=false 裁剪框=460.0×644.0（用户框 460×644） 成片头高=243.0px（理想 243.7） 保留比例=99.7%
    roll=2.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=6.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=-10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=20.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    最差偏离=0.5% (阈值 3%)
  00:19 +6: 用户框选 × 摆正 × 越界：无黑边（2B.9 的反旋转新路径）
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
  00:20 +7: 2B.9 边界安全（贴边人脸不抛异常、无黑边）
  [2B.9]
    setup0 完成，越界比例=26.0% 缩小=false 说明=裁剪框越界 26.0%（越出部分按 alpha=0 填底色）
    setup1 完成，越界比例=28.7% 缩小=false 说明=裁剪框越界 28.7%（越出部分按 alpha=0 填底色）
    setup2 完成，越界比例=0.0% 缩小=false 说明=裁剪框完全在图内
    setup3 完成，越界比例=7.6% 缩小=true 说明=人脸过于贴边/过大，已按头顶锚点缩到越界 ≤ 45%：头高比 1.307（目标 0.640），越界 7.6% 填底色
    setup4 完成，越界比例=31.0% 缩小=false 说明=裁剪框越界 31.0%（越出部分按 alpha=0 填底色）
    图外区域出现的非底色像素总数（最差单张）=0 (阈值 0)
  00:22 +8: 渐变底与去色边质量（蓝渐变 / 白底，合成原片）
  [渐变] 顶部=(97,138,206) 期望≈(98,139,206) 底部=(43,89,160) 期望≈(43,90,160)
  [去色边] 换白底后残留蓝边像素=0 (阈值 0)
  00:22 +9: All tests passed!
  
  stderr:
  
#### P0.5b PASS
- 期望：两个**分开报**的子量都要过：① 施加几何 —— SIFT 实测施加角 vs 生产记录 |差| ≤ 1.5°；② 跨量具一致性 —— 眼线实测残余 vs (真值−施加角) ≤ 1.5°
- 实测：
  ①【判据量·施加几何】SIFT 源图↔成片配准，可配准 98 条，实测施加角 vs 生产记录 |差| 最大 0.077° （阈值 1.5°，余量 1.423°）—— 此项不读眼线、不读 alpha、不读生产诊断，是 2B.8 本体的直接测量
  ②【辅助量·跨量具一致性】眼线路径，可实测夹具 88 条，|眼线实测残余 − (真值−施加角)| 最大 1.096° （阈值 1.5°，余量 0.404°，眼线量具自检误差 0.410°）—— 这个量把**量具噪声**和几何误差混在一起，余量小于量具误差，**不作为定罪依据**
  说明：本项不注入夹具，而是用真值已知的旋转夹具反查同一件事；施加几何一旦出问题（符号反了/没转），① 会立刻爆到 2 倍真值
#### P0.5c FAIL [MANUAL]
- 期望：原本通过的项重跑后仍 PASS；本项需重跑才能判定
- 实测：
  本轮未重跑设备端（上游 P0.3a/P0.3b 未修好时重跑不产生新信息，一轮约 40 分钟）。
  既有 gate 结果里的未过项：G4/4.7
  注意：这些是**本轮之前就存在的**未过项，不是 P0 引入的退化；逐条原因见各自的 out/GATE_*_r*.md，不计在 ml-porting 账上。
#### PIN PASS
- 期望：逐条相等（唯一允许的差：anchors/p2）
- 实测：
  逐条相等。比了 anchors=12条、nonPortrait=66条、rejected=1条、rotated=78条、straight=1条、uprightSynthetic=9条；登记豁免 1 条（anchors/p2）；v0 没有、故**未比**的生成件清单：knownLimitations；因形状豁免**未逐值比**的字段：methods×13（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）
#### EVID PASS
- 期望：逐份相符（**只证"叙述与产物一致"，不证"产物出自当前代码"**）
- 实测：
  相符。核了 3 份源产物：out/P0_output_residual.json=一致、out/P0_compose_items.jsonl=一致、out/P0_alpha_holes.json=一致
#### AC PASS
- 期望：0 命中
- 实测：
  清白（**条款 1 自 `7773df4` 起才真正执行 —— 该 commit 之前各轮的「清白」在条款 1 上是空的，不得引用为历史**；黄金集 src=8 ref=8；skip/catch 扫描：条款 3：skip 命中 33（其中 33 条落在巡检自身领地，已登记不判违规）；注释掉的断言命中 0；**被放宽的阈值常量：无独立扫描器，靠基线 tag diff 结构性覆盖**（阈值只在 ACCEPTANCE.md 与 tools/gate/ 两处，分别受条款 1、条款 2 保护）；条款 5：空 catch 命中 0（无注释）+ 0（体内只有注释）＝ **共 0 处，一律计违规**（主会话 2026-09-17 改口径：注释不该决定任何事 —— "加一句注释就降级"是一条能被扩写的洗白通道。让那几处清白的不是注释，是它们周围的代码，所以修法是改掉它们，不是给注释体开后门）；判据定义：体内剥掉注释与字符串后，除空白与 `;` 外没有任何语句 ⇒ 空实现。**含注释体与 `catch (_) { ; }`**，不是只认 `{}`。；**判据分母内容钉（out/P0_truth_v0.json 手写件）**：out/P0_truth_v0.json 相对基线无变化（949 个数值叶参与比对）。数值叶排除集：**空**（一个都不排，全部逐叶比对） 钉子对象：`out/P0_truth_v0.json`（本轮未变）；换靶历史（**只增不删**）：`out/P0_truth.json -> out/P0_truth_v0.json`；**分母一致性（生成件 vs 手写件）**：比了 anchors=12条、nonPortrait=66条、rejected=1条、rotated=78条、straight=1条、uprightSynthetic=9条；登记豁免 1 条（anchors/p2）；v0 没有、故**未比**的生成件清单：knownLimitations；因形状豁免**未逐值比**的字段：methods×13（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）；**派生数字证据溯源**：核了 3 份源产物：out/P0_output_residual.json=一致、out/P0_compose_items.jsonl=一致、out/P0_alpha_holes.json=一致；**测量产出同源**：3 份测量产出均可自证与当前树同源（受钉源码 103 个文件 = `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`；代码摘要 0f66aabb3c08105f）；标定靶：test/golden/src/g01.jpg 与内容钉一致（sha256=25b14d07b1375bc3…）；受钉文件 43 个；基线 baseline-p6p0 以来 test/ tools/gate/ ACCEPTANCE/RUBRIC 无实现类 agent 改动；门禁自身未提交改动 19 个，已在 out/GATE_P0_selfchanges.txt 逐条自报）

### 失败项
| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| P0.3b 旋转夹具条件覆盖率：真值 |tilt| > 1.5° 的夹具上 unavailable 必须 = 0 | 需要摆正的 67 条夹具上 unavailable = 0 | 违规 2 条（需要摆正 /truth/ > 1.5° 却返回 unavailable）：c06_d-3(truth -4.730°)、c08_d-10(truth -18.010°)——这 2 条成片未施加任何旋转，仍歪着对应角度 | ml-porting |
| P0.5c 不回归：2B.8 之外的 G2B 项 / G4 已过项不退化（判据只覆盖"原本通过的项"） | 原本通过的项重跑后仍 PASS；本项需重跑才能判定 | 本轮未重跑设备端（上游 P0.3a/P0.3b 未修好时重跑不产生新信息，一轮约 40 分钟）。 | gatekeeper（本轮未重跑，无法判定是否退化；留待上游修好后补跑） |

### 回派指令
- ml-porting：P0.3b 未达标，详见上面各项「实测」。
- gatekeeper（本轮未重跑，无法判定是否退化；留待上游修好后补跑）：P0.5c 未达标，详见上面各项「实测」。

### 哈希（本轮 pre-run 快照）
```
88168ba872229f3af1ea3c93e3218f65a9387fb269ae46174f878b1ed98a8cf5 *docs/ACCEPTANCE.md
5a894bf3ec6c312a964e1171419cc4db3d3f939f4500f4286bd50e5d83172e8a *docs/RUBRIC.md
026fcafbd8cec1d7f4f16565d5ccdda46637d824fabc6109acf0b347ae8ad7e2 *integration_test/_generated_compose_harness.dart
735056b60fc7c8a6e5b0032c6539c69aba12ac807ff43ab3bae53cc2ea1eae96 *integration_test/_generated_matting_harness.dart
0d43fe17f0815b31985832314e830ef9f8ea4f98a086ea181aede9fcfe9661eb *integration_test/coldstart_probe_test.dart
88ce7f72c0ade43b4a3129102cc2fd08a9d461259a67103b2468801853287da9 *integration_test/compose_eval_test.dart
7a7f57d14179995c08381c4f540ff1821691bcfff9981791edb6d43e304d52a4 *integration_test/e2e_eval_test.dart
f1cb7d0034695a4ff67f69ab51ff11ce17647f8a50de640a1df05cc180a6cc14 *integration_test/g4_memcheck_test.dart
0887da21b8d8fca53e89890d4695777926193cbcdac96d4600e3da9c0842f8e9 *integration_test/g4_spotcheck_test.dart
78bf239f5fdb50b89db9dadf0e1d3ab1d9bbec5514a7e7d5731c22bc9d59e559 *integration_test/matting_eval_test.dart
f154b9531c2f64c7def1c492a46d82dc095f7b2dbd76c0d4334720f24a4f71ee *integration_test/shots_test.dart
7aea984c53088cb5129c01712b7f4ad948dab7b95a58962bf3246b4a66e5ed29 *out/P0_truth_v0.json
1be07eb83bc94b174e2a1319db61eed9691532a942dcee945d46416cb9ec93d8 *out/hashes_P0_truth_leaves_baseline.txt
fb290ed367a9820135ccd532ecf54e33c2482de388415baa73731567f0b66434 *test/gate/anticheat_test.dart
cab1484dc6ec589ff2dee840d86e5eac100b7397d7d1a75cefb4783f969734c7 *test/gate/crop_interaction_test.dart
fdf7b74633f7013d48c986471fe8aec8b2d9eefac0afe2d417e3314f281c4b15 *test/gate/p0_gate_judgment_test.dart
23db2efe255ba77900d9fac3c27bba037d05b19222de8bd4efe85919ae8e03a6 *test/gate/provenance_test.dart
b60723b7ddfbc2761cc81a0f9243a23c6a710b097f8f5e28c3f99e92af0813ce *tools/gate/anticheat.dart
be3b1bc435e52c78d1bb9fcf43b8947a8a7a6d11dc83f473cf6e417ed531056c *tools/gate/capture_shots.dart
b9b238773350d61d5dedb08011f5594a327839c73b78bd068589f9a3e06dd232 *tools/gate/collect_metrics.dart
9ef0e19a1f5eed8ec0c5775b6c64afa21ddcd2a345251b6bad203f7d4d2ac828 *tools/gate/color_utils.dart
b675395b6742cac303b5fe35aaf257de2f135331174f4cfe18d8203c5944c93a *tools/gate/compose_check_utils.dart
14fac3f75f9bb4d5c7144a58cf51c495ab28d0216a2fee255c51603fd28954ef *tools/gate/device_harness_common.dart
14a866ce0afa322b663fcdf74a4bc59dffee300ef3b3d886754e0ddb44354087 *tools/gate/g4_release_memcheck.py
ef5b216cd07fec30e73db7aae255a3df0c825d6b11a83fb60f09948be774b224 *tools/gate/gate_G1.dart
0dd1c12ca3ac307879c332ccc0bbac77acaa3643d54371bbbfe27c14cc30972b *tools/gate/gate_G2A.dart
c0374529ba4044e60df9ba1b0d7136946ab0e1ebfe849691ac324c8c9ff5999b *tools/gate/gate_G2B.dart
d5657019230268e08e994eede53a4e3cc2a8a04ddaea71c77e8dd7985ea2aea0 *tools/gate/gate_G2C.dart
5be8abb0e457d1a26952a994cf7e9850ce79fc11f301b44e4f248a53cbaa3606 *tools/gate/gate_G3.dart
29d561269228c03272ecc71d54f730396ae256da79f52c504a866f125d32208d *tools/gate/gate_G4.dart
186ea8c020703998bb8964bbe9ac6b74af53f73521b61326291afb4ba8de1cce *tools/gate/gate_G5.dart
c1048040824c8bb00487a73e44b6df60b479347fddbfac78940635b3625ecfe0 *tools/gate/gate_G5B.dart
09186f98c0a39b65bef8355ed6e1b595e7f51ea38d15f8d941bafcb5b1f7d04d *tools/gate/gate_P0.dart
05d9b6610c7732f871e30cb5ef67a47312fcfa6a5585d4bb2928671784accd8b *tools/gate/gate_common.dart
55a02caf2e5ba3b329ce1448fc4669dc52da2cf4796f1d439c575db929009f75 *tools/gate/jpeg_utils.dart
9bf78e113a34a2c9e90197bc842f2fca1a8999ae3507176f95b1fa1306889be4 *tools/gate/p0_eyeline.py
7c30c6ee828d02f77159392a4aae0d979884f8dbf48f9bcd5b61033823be13ef *tools/gate/p0_overlap.py
8a46d89c013acfb61a209e467036ffaf32eb734463e8cda4ba1082b8a96a5b08 *tools/gate/p0_rigid_check.py
8fc0270be7475a702d4d71735b3f327db72ffd116091ba739e343c73249d81f0 *tools/gate/p0_roll_probe_test.dart
fb0711446e483b8a1fc72f549516fec7fcd2fcbaf6eaf4d933456a59587c3ae2 *tools/gate/png_utils.dart
5452451ef5a6e617b26fc65cce7ab79427b267c4dab076e64d5b223864764a9c *tools/gate/provenance.dart
45ada1647fc0766a7dbf594d015274b5252850a8b43f62925db9ba629fb712b0 *tools/gate/rot_dir_check.dart
86ccf34ec2b960f74727cd0bf528a42f4337fcf8b92c35a2c6ab15675d167c0a *tools/gate/sha256.dart
```

---

# gatekeeper 判决层

（上半部分由 `dart run tools/gate/gate_P0.dart --round 2` 生成；以下是门禁官签署的判决与回派。）

## 结论

**G2B-P0 第 2 轮：FAIL。通过 10 / 12 项，MANUAL 1 项。不得进入阶段 3。**

本文件取代同日早先因**门禁自身两处缺陷**产生的作废版 —— 作废版原样存于
`out/GATE_P0_r2_VOID_by_gate_bug.md` / `out/gate_P0_r2_VOID_by_gate_bug.json`，
两处缺陷见文末「门禁自修」。作废版不消耗实现方修复轮次。

## 失败项

| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| P0.3b | 真值 \|tilt\| > 1.5° 的 67 条夹具上 `unavailable` = 0 | **违规 2 条**：`c06_d-3`(truth −4.730°)、`c08_d-10`(truth −18.010°)，两条成片**未施加任何旋转**，仍歪着真值角度 | ml-porting |
| P0.5c | 原本通过的项重跑后仍 PASS | 未重跑，无读数 | gatekeeper（r3 补跑） |

## MANUAL 项（显式列出，**未**当作通过）

- **P0.5c**：判据要求"原本通过的项重跑后不退化"，须等上游修好后再跑，本轮取不到读数。
  记 MANUAL，**不计入通过数**。r3 补跑。

## 脚本完整性

- 自动行报 `OK（本轮自报改动：19 个）`。
- **该行在自报文件上是盲的，这是一个已知洞**：`_hashVerdict()` 会跳过
  `out/GATE_P0_selfchanges.txt` 里列出的路径，而**这个清单自身不在受钉哈希集内**
  （`grep -c GATE_P0_selfchanges out/hashes_P0_prev.txt` = 0）。
  即"改门禁脚本 + 往清单加一行"⇒ 自动行仍报 OK。**本轮未修，r3 前处理**（见文末）。
- **本轮的补偿控制是外部信号**：`out/hashes_r2_pretag.txt`（开跑前 41 条快照）对当前盘面
  逐条比对，检出 **2 处变更**，与 `out/hashes_gatefix_before.txt` 逐字一致：

  | 文件 | pre-tag | 修复后 |
  |---|---|---|
  | `tools/gate/gate_P0.dart` | `fc76d7ab…1ce1e` | `09186f98…7d04d` |
  | `tools/gate/provenance.dart` | `a65ca83b…44fe4` | `5452451e…64a9c` |

  两处均为 **gatekeeper 本人**本轮的输入完整性修复，已 commit `4e33340`，
  **判据、阈值、分母一律未动**。

## 防作弊巡查（条款 1–6，逐条，每轮必做）

| 条款 | 读数 | 判定 |
|---|---|---|
| 1 实现类 agent 未碰 `test/`、`tools/gate/`、ACCEPTANCE、RUBRIC | `git diff --name-only baseline-p6p0-r2..HEAD -- test tools/gate docs/ACCEPTANCE.md docs/RUBRIC.md` 仅 `tools/gate/gate_P0.dart`、`tools/gate/provenance.dart`，二者均属 gatekeeper 且在自报清单内 | 清白 |
| 2 gate 脚本 SHA256 | 2 处变更，全部出自 gatekeeper，前后哈希逐条公开（见上表） | 清白（附上述洞） |
| 3 `skip:` / 注释掉的断言 | `lib/` 独立复扫 **0 命中**；全仓命中均落在 `tools/gate/`、`test/gate/` 巡检自身领地 | 清白 |
| 4 `test/golden/` 文件数 | src=8 / ref=8，与上一轮记录一致，**未减少** | 清白 |
| 5 空 catch | `lib/` 25 个 catch，剥注释与字符串后空实现 **0 处**（独立复扫脚本，不调用 `anticheat.dart`）；全仓 21 处命中全在 `test/gate/anticheat_test.dart`，是扫描器的正向对照夹具 | 清白 |
| 6 报告数字 vs `out/gate_P0_r2.json` | `pass=false`、`10/12`、`manual=1`，逐项一致 | 清白 |

## 回派指令

- **ml-porting — P0.3b（唯一实质失败项）**
  67 条需摆正夹具上有 2 条返回 `unavailable`，成片未施加任何旋转：
  `c06_d-3`（真值 −4.730°）、`c08_d-10`（真值 −18.010°）。
  两条的**独立复核**（本门，路径与 qa-batch 不同）已写在 §样本账：
  - `c06_d-3`：Haar 眼线量得输入 **−4.051°**（真值 −4.73°，误差 0.68°）
    ⇒ **其 `unavailable` 不能用"量不准"开脱**；
  - `c08_d-10`：输入与成片 Haar 均 `no_face`，改由 SIFT 刚体配准在 `visa_us` 规格上
    读出成片残余 **−17.985°**（150 匹配 / 128 内点）。
  按主会话裁定：`c08_d-10` **计入违规，不从分母扣除**。

- **imaging — 非 P0 项（时序：P0 PASS 之后）**
  见 §顺带发现 第 1 条：紧取景源图的裁剪框落到源图之外，`c08` / `c08_upright`
  成片肉眼可见破损（下缘水平切口 + 两团孤立抠图碎屑）。**不阻塞本轮 P0 判决**，
  但不得因"P0 与它无关"而丢案。

## 门禁自修（本轮两处，已公开）

1. `gate_P0.dart` `_roundState()`：porcelain 行先 `trim()` 再 `substring(3)`。
   未暂存修改的 XY 首字符是空格，被吃掉后 `substring(3)` 会切掉路径首字母
   （` M docs/PITFALLS.md` → `ocs/PITFALLS.md`），`kFreezeExemptPath` **永不命中**
   ⇒ 只有 PITFALLS 被改（正是要豁免的情形）时 `frozen` 反为 false，**整轮作废**。
2. `provenance.dart` `_verifyOne()`：从**指纹块内部**读 `roundValid`/`codeStableDuringRun`，
   而生产侧写在**指纹块的父层**（`codeFingerprint()` 与 `roundVerdict()` 是两个函数、两张表）。
   深了一层 ⇒ 永远读到 null ⇒ 三份产出被判"无法自证来源" ⇒ `allBound=false`
   ⇒ **每一轮无条件作废**，与被测代码无关。
   修后实测：三份产出 **103/103** 条 blob 与当前树相符、`invalidReasons=[]`
   （独立重算脚本，不调用 qa-batch 的任何函数）。

两处都只改"输入完整性检查怎么读盘"，**未动任何判据、阈值、分母**。

## r3 前应处理（不阻塞本轮判决）

- 把 `out/hashes_*_pretag.txt` 提升为**条款 2 的权威基线并自动比对**，
  取代 `_selfTouched()` 的自我豁免；`out/GATE_P0_selfchanges.txt` 自身应进受钉集。
  否则"自报即免疫"这条通道始终开着。

## 附：P0.2 分母裁定（主会话 2026-09-17 提问，门禁官裁定）

**问**：qa-batch 报 `P0.2 竖直合成残余 n=1 / absMax 0.21`，但产物里竖直样本不止 1 条。分母该是多少？

**裁定：P0.2 的分母 = 10，不是 1。本门 P0.2 的判决本就按 10 出，不因本条改变。**

**依据一（法典）**：`docs/ACCEPTANCE.md:73` 原句写死样本构成 ——
「已知竖直样本（用户 `2.jpg` **+ 9 张**由大倾角锚点反向旋转合成的竖直样本）」⇒ 1 + 9 = **10**。

**依据二（产物逐条数）**：`out/P0_compose_items.jsonl` 实际行：

| corpus | 行数 | 不同 id | rollSource | straightenDeg | outcome |
|---|---|---|---|---|---|
| `uprightSynthetic` | 11 | **9**（`p1_upright`、`c01/c03/c04/c05/c06/c08/c10/c12_upright`） | 全 `pupil` | 全 `0.0` | 全 `ok` |
| `straight` | 3 | **1**（`p2`） | 全 `pupil` | 全 `0.0` | 全 `ok` |

9 + 1 = **10**，与法典一致（11 行是因为 `p1_upright` 有 3 个规格，其余各 1，按**不同夹具**去重）。

**本门 P0.2 的实际读数**（见上「#### P0.2 PASS」，**10 条逐条列出**，每条都记了残余与量具出处）：

- `uprightSynthetic` 来源分布 `{pupil: 9}` —— 法典"必须返回 `pupil`"这一半 **9/9 满足**；
- 残余 max = **0.637**（`c05_upright`，`gate_eyeline`），阈值 1.5°；
- 10 条里**没有一条**因量测失效被静默丢掉：9 条由 `gate_eyeline` 量出，`c08_upright` 由
  `gate_sift_align` 兜底（其眼带被抠图打掉），逐条写在上面。

**对 qa-batch 记账的两点要求**（属其 `out/QA_r2.md`，本门不改他人文件）：

1. `QA_r2.md:50` 那一行 **`n=1` 不是 P0.2 的分母**，且标签「竖直合成」与法典口径不一致。
   该行在 `QA_r2.md` 中**只出现这一次**，无推导、无逐条清单 —— 按 ACCEPTANCE:105
   （样本不得静默消失）它**不可审计**。请改为按法典口径的 10 出，或明确标注它是哪个更窄的子口径
   （并写清这个子口径的定义与它排除了谁）。
2. **`absMax 0.21` 与本法典口径下的 max 0.637 必须对齐**（不同量具可以给出不同值，
   但须写明是量具差异，且**不得让读者以为 0.21 是这 10 条的上界**）。

**这两点是记账完整性缺陷，不是判决变更**：无论取 0.21 还是 0.637，都 ≤ 1.5°，**P0.2 保持 PASS**。

### P0.2 量具署名更正（2026-09-17，qa-batch 指认，门禁官复核后确认）

qa-batch 指出本报告 P0.2 那句「max|残余| = 0.637」**没署量具**，与它 `QA_r2.md` 的引擎口径
不可并列。**该指认成立，措辞之责在我**——这正是本报告反复点的那一类：
一个数读起来像"这条判据的上界"，实际只是"某一支量具在这条判据上的读数"。

逐条核后的事实（可复现、可指认）：

- **0.637 的出处**：id = **`c05_upright`**，字段 =
  `out/GATE_P0_r2_eyeline.json` → `rows` 里 `id == "c05_upright"` 那一行的 **`tilt_deg`
  = 0.6365935759634865**；同行为 `truthTiltDeg = 0.0`、`applied_straighten_deg = 0.0`、
  `corpus = "uprightSynthetic"`、`path = out/P0_anchors/composed/c05_upright__cn_big_1inch.jpg`。
  **量具 = `haar_eyeline_2x`（gatekeeper 自己的 Haar 眼线）**，不是引擎读数。
- **引擎口径的上界是 0.290**（`c10_upright`，`m1_pupil`）。**两者不是同一个量**：
  前者是门禁独立量具对**成片像素**的读数，后者是引擎自报的 `output_tilt` 残余。
- **交叉佐证（支持 0.637 不是伪影）**：qa-batch 自己的 Haar 实现 `m3_haar_eyeline`
  在 `c05_upright` 上读 **0.616**，与门禁 Haar 的 0.6366 相差 **0.02°**。
  **两个互不调用的 Haar 实现给出同一读数** ⇒ 该 ~0.62° 更可能是**成片像素的真实性质**，
  不是某一支量具的伪影。
- **判决不受影响**：两种口径下 10 条全部 ≤ 1.5°，**P0.2 保持 PASS**。

`c08_upright` 的兜底出处（qa-batch 问）：`out/GATE_P0_r2_rigid.json` → `rows` 里
`id == "c08_upright"` 那行，`ok = true`、`residual_deg = -0.0192`、
`measured_applied_deg = 0.0192`、`inliers = 48` / `matches = 117`。
它在**门禁的 SIFT 产物**里，不在 qa-batch 的产物里——所以它在 `m1_pupil`/`m3_haar_eyeline`
那些字段上看到 `null` 是对的，两处不是同一份文件。

---

# 事后勘误（2026-09-17 追加，不推翻任何原始结论，只标注哪些表述当时是错的）

> 未写进 `kRoundErrata[2]` 而直接落在这里：改该常量要动量具脚本的 SHA256，
> 而 r3 判决前不应再动量具。r2 报告不会由 r3 重生成，故直接落盘是等价的。
> 若主会话希望它进 `kRoundErrata[2]`，下次触碰 `gate_P0.dart` 时一并折进去。

**勘误 1：`c08_upright` 的"兜底"是量具侧，不是引擎侧。**
引擎在该样本上 `roll_source = "pupil"`，**引擎侧本就没有兜底**。兜底发生在门禁的量具链上：
我的眼线量具 `rows[19]` = `ok:false / reason:"no_face"`，改由
`out/GATE_P0_r2_rigid.json` 的 `rows[19]`（SIFT 刚体配准）`ok:true`、`measured_applied_deg 0.0192` 读出。
**原报告没写死"兜底"指哪一侧** —— 读成"引擎没备选"和读成"门禁换了量具"都站得住，这正是要消掉的歧义。

**勘误 2：两个量具量的是不同的量，不能并列。**
我的 SIFT 量的是**施加角**（源图→成片配准，`measured_applied_deg`）；
qa-batch 的 `output_tilt` 量的是**成片绝对倾角**。二者**只在 `truth_apply_deg == 0` 时重合**。

**勘误 3（我自己的错误，撤回一句话）：**
我曾对 qa-batch 说「qa-batch 自己的 Haar 实现在 `c05_upright` 上读 0.616、与门禁 Haar 的 0.6366 相差 0.02°，
**两个互不调用的实现给出同一读数 ⇒ 该 ~0.62° 更像成片像素的真实性质**」。**这句是错的，撤回。**
逐步复算（每步可验）：

| 读数 | 来源 | 反解出的眼点位移 | `atan2` |
|---|---|---|---|
| `+0.6365935759634865` | 我的 `c05_upright`（`left=[134.25,239.75] right=[224.25,240.75]`） | dx=90, dy=**+1** | ✓ 逐位相符 |
| `+0.6437457141753808` | 我的 `c04`（`left=[134.75,239.25] right=[223.75,240.25]`） | dx=89, dy=+1 | ✓ 逐位相符 |
| `+0.6365935759634865` | qa-batch 的 `c04`（`P0_truth.json`） | dx=**90**, dy=+1 | 与我的 c04 差 **1 像素** |
| `−0.658543177563603` | qa-batch 的 `c05_upright` | dx=**87**, dy=**−1** | 与我的差 3px(dx) / **2px(dy)** |

结论三条：
1. **那个"跨样本逐位相同"不是串样本。** `atan2(1.0, 90.0)` 是一个常数——
   两边落在同一整数像素位移上，自然逐位相同。我先前与主会话同感"要么巧合要么串样本"，
   **真正的解释是第三种：同一个公式 + 同样的整数输入**。
2. **符号相反不是符号约定**，是右眼 y 相差 **1 像素**（`+1` vs `−1`）。
3. **该量具的量化步长 = 0.6366°**：在 `cn_big_1inch`（`eyedist ≈ 90 px`）上，眼距-法向差 1 像素即 0.6366°。

**对 P0.2 表述的影响（对判决没有影响）：**
本报告 P0.2 的 `max|残余| = 0.637` **恰好等于该量具的一个量化步长**（= 右眼比左眼低 1 像素），
它**不是一个可分辨的测量值**；本门那 10 条读数（0.454–0.637）**全部 ≤ 一个量化步长**，
即这支量具**无法把它们与 0 区分开**。**判决不变**（两种口径下全部 ≤1.5°，P0.2 保持 PASS），
但"上界 = 0.637"必须降级读作"= 1 像素"。
同理，该量具在 `c06_d-3` 上给出的 `−4.354°`（真值 `−4.73°`）之所以看着精细，
是因为那条 `eyedist` 更大、`dy` 大得多；**量化步长随 `eyedist` 变化，不能跨样本比"精度"**。

**勘误 4（2026-09-17 追加，更正上面勘误 3 里"量化步长"那一段 —— 那段是我写错的）：**

勘误 3 里我写「1 像素眼距-法向位移 = 0.6366°，该量具步长 = 0.6366°，
故 `max|残余| = 0.637` 恰好是一个步长、10 条读数全 ≤ 一个步长、该量具无法把它们与 0 区分」。
**这四个数全错**：它们默认了 `dy` 只能取整数。**实盘不是。**

按 `out/GATE_P0_r2_eyeline.json` 逐条反解（`dx = right.x − left.x`、`dy = right.y − left.y`）：

| id | dx | dy | tilt_deg | 步长 `atan(0.25/dx)` | **量化数** `|dy|/0.25` |
|---|---|---|---|---|---|
| `p2` | 89.75 | −0.25 | −0.1596 | 0.1596 | **1** |
| `p1_upright` | 88.25 | +0.75 | 0.4869 | 0.1623 | 3 |
| `c01_upright` | 94.75 | +0.75 | 0.4535 | 0.1512 | 3 |
| `c03_upright` | 88.75 | −0.25 | −0.1614 | 0.1614 | **1** |
| `c04_upright` | 89.75 | +0.75 | 0.4788 | 0.1596 | 3 |
| `c05_upright` | 90.00 | +1.00 | 0.6366 | 0.1592 | **4** |
| `c06_upright` | 98.50 | +1.00 | 0.5817 | 0.1454 | **4** |
| `c10_upright` | 96.00 | +1.00 | 0.5968 | 0.1492 | **4** |
| `c12_upright` | 97.50 | 0.00 | 0.0000 | 0.1469 | **0** |

**该量具坐标是 0.25 像素的倍数，步长 ≈ 0.15–0.16°**（不是 0.6366°）。因此：
- **`max|残余| = 0.637` 是 4 个量化步的真实读数**，**不是**分辨率地板 —— 勘误 3 把它降级为"= 1 像素"是**错的**，此处更正回来；
- 但 **`c12`（0 步）、`p2` 与 `c03`（各 1 步）确实在或贴近地板**，这三条不可分辨；
  中间的 3 步几条（0.45–0.49°）只能算勉强分辨。
- **判决不变**：P0.2 保持 PASS，两种口径下 10 条全部 ≤ 1.5°。

**错因记录**：我谈量化时**没有先量自己产物的坐标精度**，而是套了一个"眼点是整数"的假设 ——
而 `atan2(1,90)` 恰好又逐位等于我先前报的 0.637，让这个假设看起来被"验算通过"了。
**这正是本报告从头到尾在防的那件事：一个自洽的错误比一个明显的错误难发现。**

---

# 勘误 5：用**免眼路径**了结"两支 Haar 量具分歧 4.4°"的悬案

## 5.1 我先前发出的警告，与它为什么不成立

勘误 3/4 之后我核对了两支眼线量具（我的 `gate_eyeline` 与 qa-batch 的 `m3_haar_eyeline`），
在成片上比出中位 0.4535°、最大 4.3987°，**>1.0° 的有 16/88**，并据此向主会话发出一条警告：

> "若在这类样本上错的是 `gate_eyeline`，**P0.3a 的残余就被低报了 —— 那是假 PASS**。"

**这条警告的前提是错的，我现在撤回它。** 原因：`m3_haar_eyeline` **不是** qa-batch 的主用量具。
实盘 `out/P0_output_residual.json` 里 **97/97 条的 `primary_method` 都是 `m1_pupil`** —— m3 只是他们的附加列。
**我拿别人的一个非主用列当成了"另一支独立量具"，去质疑他们（和我自己）的主用结论。**
这是我自己在上一轮反复要求别人的那件事的反面：**比较之前先确认比较对象的口径与地位**。

## 5.2 免眼路径的一锤定音

本项目里已经存在一条**不碰眼点、不碰 alpha** 的独立测量路径：`tools/gate/p0_rigid_check.py align`
（SIFT 把源图配到成片，解出相似变换的旋转分量 = 生产管线**实际施加**的旋转角，于是
`成片倾角 = 真值 − 实测施加角`）。它正是本门给"眼线量具失效样本"准备的第二支量具。
把它从"只给失效样本兜底"提到"仲裁所有分歧样本"，读数如下（单位：度）：

| 夹具 | **SIFT 免眼（成片倾角）** | 门禁 `gate_eyeline` | qa `m3_haar_eyeline` | qa 主用 `m1_pupil` |
|---|---|---|---|---|
| `p2_d-3` | **−0.1778** | +0.0000 | −4.3987 | −0.2719 |
| `c02_d-3` | **−0.0193** | +0.1436 | +3.4239 | −0.0914 |
| `c02_d+10` | **+0.0282** | +0.1520 | +3.2397 | −0.0608 |
| `c07_d-10` | **−0.0422** | +0.3016 | +3.3665 | −0.1463 |
| `c06_d-3`（**真歪**，P0.3b 的失败样本） | **−4.7419** | −4.3542 | −4.3542 | −4.8247 |

读法：前四张**已被摆平**（免眼路径读数 |·| ≤ 0.18°），此时 **m3 却报出 ≈ −4.4° 或 ≈ +3.3°**；
第五张**确实没被摆平**（−4.74°），此时三支量具一致指向 −4.4 ~ −4.8°。
**即 m3 的错法不是"噪声"，是"在摆平的图上稳定地报出一个系统性假角"。**

## 5.3 结论：P0.3a 不动，不翻

| 比较 | n | 中位 \|差\| | 最大 \|差\| | >1.5° 的条数 |
|---|---|---|---|---|
| 门禁 `gate_eyeline` vs 免眼 SIFT | 88 | 0.3872° | 1.1048° | **0** |
| qa 主用 `m1_pupil` vs 免眼 SIFT | 97 | 0.0945° | 17.8695° | 4 |
| qa `yunet_eyeline_deg` vs 免眼 SIFT | 98 | 2.5039° | 7.0429° | **74** |

- **两支主用量具（我的 `gate_eyeline`、qa 的 `m1_pupil`）都与免眼路径显著一致**，
  门禁量具在 88 条里**没有一条**超过 1.5°。**P0.3a 的 PASS 站得住，不翻。**
- qa 另有 4 条（`p2_d-10` −17.9375 / `c08_d+5` +5.7549 / `c08_d+10` −3.4445 / `c08_d-5` +2.0284）
  的 **主用量具**与免眼路径差 >1.5°。这 4 条不在本门判据的争议范围内，**列为给 qa-batch 的观察项**。

## 5.4 量具自身的能力边界（必须写明，免得下次高估它）

免眼 SIFT 量具自检 `out/gate_P0_rigid_selftest.json`：注入 ±3/±5/±10° 全部读回，`pass=true`，
但**最大误差 0.5000° 恰好等于它自己的容差 0.5°** —— 是压线通过。
分档看：±3° 时误差 0.01–0.05°（很准），±10° 时误差 0.26–0.50°（明显变钝）。
**故它足以分辨 1.5° 量级的差异，不足以支撑亚度级的结论。** 本节所有结论都只用它做"0 还是 4.4°"这种量级判断。

## 5.5 本节的自评

我发出 5.1 那条警告时，证据是**真测出来的**（两支量具确实差 4.4°），
但**比较对象选错了**（把非主用列当成对等量具），于是结论方向反了。
**代价是让主会话和实现方为一件不成立的事紧张了一轮。**
记入 `docs/PITFALLS.md`。

---

# 勘误 6（工具能力）：`probe` 子命令 —— 把眼候选决策链落盘（r3 ② 交付）

## 6.1 它是什么

`tools/gate/p0_eyeline.py` 新增**只读**子命令 `probe`。它把 `measure()` 的内部决策
整个摊开落盘，供实现方（ml-porting）**自己复算**，不必依赖我的口头转述：

- 每个**正脸候选**的框、面积、以及被选中的那一个（规则：取面积最大）；
- **全部**眼候选（不预筛）：`box_full` / `center_full` / 面积 / 长宽比 /
  `size_ratio` / 圆度 / 框内平均亮度；
- 每个候选**逐步的 keep/drop 及命中的规则名**（`below_size_gate`、
  `not_in_top2_by_area`、`aspect_ratio_guard`、`eyedist` 闸、`MAX_TILT_GUARD`）；
- 被选中那一对的**原始 `dx` / `dy`** 与复算提示（`tilt = degrees(atan2(dy, dx))`），
  任何人不看我的代码也能算出同一个角。

`circularity_desc` / `mean_luma_desc` 是**纯描述量，不参与 keep/drop**，已在输出里显式标注。

## 6.2 先证明它说真话：已知答案对照

`probe` **每次运行都先跑对照**，不过则退出码非 0、后续结论不可信。本次（控制图
`out/P0_anchors/c05_upright.png`）：

| 对照 | 结果 |
|---|---|
| 探针重放 == `measure()`（同图同 code path） | **通过**，两侧同为 `0.6250200740174968` |
| 注入 +3.0° → 期望 +3.625° | **通过**，读回 +3.715°（误差 0.090°） |
| 注入 −3.0° → 期望 −2.375° | **通过**，读回 −2.004°（误差 0.371°） |

## 6.3 零漂移证据（关键）：加了 `probe` 没有移动 r2 的任何一个读数

用**同一份** `out/P0_compose_items.jsonl`（`--spec cn_big_1inch`，100 条）重跑 `run`，
与 r2 判据实际使用的 `out/GATE_P0_r2_eyeline.json` 逐条比对：

| 比对项 | 结果 |
|---|---|
| `n` / `n_measured` | 100 / 88 == 100 / 88 |
| 除 `rows` 外全部顶层字段 | **完全相同** |
| id 集合 | 相同 |
| **逐条 `rows` 不同数** | **0** |

`measure()` / `_pick_pair()` / `run` 一行未动；`gate_P0.dart` 不调用 `probe`。
SHA256 `9bf78e11…89be4` → `ecc8d4da…02ec8`。已记入 `out/GATE_P0_selfchanges.txt` 第五批。

## 6.4 用它看 `c06_d-3`（P0.3b 的失败样本之一）

```
真值 truthTiltDeg = -4.73   引擎记录施加角 applied = 0.0
正脸：1 个，box_full = [75.5, 139.5, 256, 256]，ROI = 上 62%
眼候选：3 个（尺寸闸下限 0.12*face_w = 61.44 ROI px）
  ① box_full=[139,193,23,23]  尺寸比 0.0898  rank=—   dropped:below_size_gate
  ② box_full=[220,203,50,50]  尺寸比 0.1953  rank=0   kept:top2
  ③ box_full=[123,212,47,47]  尺寸比 0.1836  rank=1   kept:top2
选中对：左 [146.5, 235.5]  右 [245.0, 228.0]
原始 dx = 197.0  dy = -15.0   →  atan2(-15, 197) = -4.3542°
眼距比 0.3859 ∈ [0.22, 0.55] 通过；measure_agrees = true
```

**三条独立证据同时指向同一结论：这张成片是真的歪着 4.5° 左右。**

| 路径 | 读数 | 是否碰眼点 |
|---|---|---|
| 门禁 Haar 眼线（本 dump 可复算） | **−4.3542°** | 是 |
| 免眼 SIFT 刚体配准（源图↔成片） | **−4.7419°** | **否** |
| qa-batch 主用 `m1_pupil` | −4.8247° | 是（独立实现） |

而**引擎记录 `applied = 0.0`、`rollSource = unavailable`** —— 即它自认"量不出来"、
**一步没转**，把一张歪 −4.73° 的图原样交了出去。**这是引擎的决策失败，不是量具的失败。**
`probe` 的 dump 让"我的量具是不是也错了"这个疑问**在数据上被排除**：
候选链每一步都可复算，且与一条完全不碰眼点的路径吻合到 0.39°。

## 6.5 同批落盘的其它样本

| 夹具 | 探针读数 | 正脸数 | 眼候选数 | 备注 |
|---|---|---|---|---|
| `c06_d-3` | −4.3542°（kept） | 1 | 3 | 见 6.4；引擎 `unavailable` |
| `p2_d-3` | +0.0000°（kept） | 1 | 6 | 已摆平 |
| `c02_d-3` | +0.1436°（kept） | 1 | 6 | 已摆平 |
| `c07_d-10` | +0.3016°（kept） | 1 | 11 | 已摆平 |
| `c08_d-10` | **测不出（`no_face`，3 个 specId 均 0 张正脸）** | **0** | — | 走免眼 SIFT 兜底 |

`c08_d-10` 是本门"眼线量具失效 → 免眼路径兜底"设计的实例：Haar 在成片上找不到正脸，
而免眼 SIFT 对该图仍给出读数。**两条路径的覆盖并集正是 P0.3b 分母的来源。**

落盘：`out/GATE_P0_r2_probe.json`（本次五张，含对照记录）。

---

# 勘误 8：P0.3b 两条违规的**可及性不对称** —— 请主会话裁定 `c08_d-10` 是否计入

## 8.1 事实

P0.3b 的违规是 2 条：`c06_d-3`（truth −4.730°）与 `c08_d-10`（truth −18.010°）。
两者的**用户可及性完全不同**，我却把它们并列了，这是本勘误要纠正的。

证据出自 qa-batch 的 `out/P0_alpha_holes.json`（**不是转述，我读了产物本身**）：

| 夹具 | 眼带 alpha 全零比例 | 我的眼线量具 | 免眼 SIFT | 判定 |
|---|---|---|---|---|
| **`c06_d-3`** | **不在洞名单里** | **ok，−4.3542°**（3 候选，链条可复算） | **ok，−4.7419°** | 眼区**干净**，引擎仍返 `unavailable` |
| `c08_d-10` | **0.9677** | `no_face`（0 张正脸） | **失败**（`scale=0.000`） | 眼区**被打掉 96.8%** |

同一份产物里 qa-batch 的结论（`answer` 字段）写得很清楚：
> "**未旋转的真实照片一张都没有洞**（Pictures 可评估人像 14 张，eyeBandZeroFrac 全部 = 0.0）。
> 洞只出现在**被旋转过的输入**上：c08 夹具家族 4/7 命中。"

而我自己的报告在 c08 证据那一段已经裁定过：该空洞需要"输入被任意角旋转过"这一前提，
而生产路径**永远不会**把面内旋转过的图喂给抠图引擎（四条证据独立复核，见该段），故用户碰不到。

## 8.2 由此产生的矛盾（我先前没有看见）

**`c08_d-10` 的违规，其触发条件正是我自己已经判定"用户碰不到"的那个前提。**
即：我一边写"该空洞用户碰不到、不进 P0 判据、不回派"，一边在 P0.3b 里
用**同一个空洞造成的 `unavailable`** 给它定了一条违规，**且没有标注这层张力**。

## 8.3 我的处置（**不自行减项**）

**我不删这一条，也不改判 P0.3b 的结论。** 理由：ACCEPTANCE 的 P0.3b 明文是
"旋转夹具上真值 |tilt| > 1.5° 的样本，`unavailable` 必须 = 0"。
`c08_d-10` 满足该条所有字面条件且返回 `unavailable`，**按法典就是违规**。
"它是否公平"是**阈值/口径问题，只有主会话能改**（CLAUDE.md §7：「禁止为了通过而降低阈值」；
阈值只有主会话能改，且只在人工明确要求时改）。**我若自行剔除，就是我在替法典做减法。**

**但必须让裁定者看见这层不对称**，因为它的实际后果不同：

- **`c06_d-3` 是"取消不掉"的违规。** 眼区干净、我的量具给出可复算的 −4.3542°、
  免眼路径独立给出 −4.7419°、qa 主用 m1 给出 −4.8247°，三方吻合。
  **引擎在这张图上说"量不出来"没有任何客观理由** —— 这是**用户真能撞上**的缺陷。
  **P0.3b 的 FAIL 即使剔掉 `c08_d-10` 也依然成立。**
- **`c08_d-10` 的违规可能落在夹具伪影上。** 若主会话裁定"夹具伪影造成的 `unavailable`
  不计入条件覆盖率"，则违规数由 2 降为 1 —— **但 P0.3b 仍为 FAIL**。

## 8.4 请裁定

1. `c08_d-10` 计入 P0.3b 违规数（现状，2 条）**还是**豁免为夹具伪影（1 条）？
   **两种口径下 P0.3b 都是 FAIL**，故**不影响本门结论，也不影响 ml-porting 要修的东西**；
   影响的是**给 ml-porting 的工单描述**与 r3 的违规计数表述。
2. 若豁免，我需要主会话**以明确文字**写下该口径（我不自行推断），
   否则 r3 我仍按 2 条记。
3. **不论如何裁定，`c06_d-3` 都必须修** —— 它是可及缺陷，不是伪影。

---

# 勘误 13：勘误 8 的**前提被推翻**，据此撤回裁定请求；并订正样本账两处错标

## 13.1 勘误 8 依赖的那个前提，是错的

勘误 8 请求主会话裁定"`c08_d-10` 是否因夹具伪影而豁免"，论据是
`out/P0_alpha_holes.json` 的 `answer` 字段：

> "**未旋转的真实照片一张都没有洞**（Pictures 可评估人像 14 张，全 0.0），
> 洞只出现在**被旋转过的输入**上。"

**qa-batch 的 `d66de4d` 指出该结论被它自己的数据否掉，我读产物复算后确认 qa-batch 是对的。**
`controlComparison.rotatedFixtures.perFixture` 原文：

```
c08_upright.png  0.6193   <- 名字即"竖直"，0 度，未旋转，却在这个"rotatedFixtures"桶里且有大洞
c08_d-10.png     0.9677
c08_d-5.png      0.7549
c08_d+3.png      0.5277
c08_d+3/... 其余 0.0 ~ 0.1966
```

**一个 0 度夹具眼带被打掉 61.9%，却被归入"旋转夹具"桶，再据以得出"洞只出现在旋转输入上"。**
分组与结论互相拆台。**该结论不成立。**

## 13.2 我的处置：撤回请求，不拿未知成因去请求豁免

- 我原论证链是"洞需要输入被面内旋转 → 生产路径从不这样做 → 用户碰不到"。
  **既然 0 度也有洞，这条链断了。**
- 替代解释（夹具构造本身，如夹具管线的裁剪/缩放）**同样没有证据** ——
  **成因目前是未知的，不是我先前断言的"夹具伪影"**。
- **基于未知成因请求豁免，我不做。撤回勘误 8 的裁定请求**，已同步主会话请其不要据此裁定。
- **r3 仍按法典字面记 2 条违规**，并在报告里标注"`c08_d-10` 成因未查清"。
  **不许把"没查清"写成"已排除"。**

## 13.3 不受影响的部分（勘误 8 里唯一站得住的那条）

**`c06_d-3` 的违规从头就没有依赖这个产物。** 它**不在 4 条洞名单里**
（洞是 `c08_d-10` / `c08_d-5` / `c08_upright` / `c08_d+3`，`c08_d-3` 与 `c08_d+10` 均为 0.0）。
三方测量吻合：门禁 Haar **−4.3542°**、免眼 SIFT **−4.7419°**、qa 主用 m1 **−4.8247°**。
**P0.3b 的 FAIL 只靠 `c06_d-3` 就成立，与本次撤回无关。**

## 13.4 顺带订正样本账里两处错标（同一类：标签与产物不符）

样本账表原先把 `c08_upright` 与 `c08_d-5` 都标成
"成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**）"。
**这两条恰恰在洞名单里**（61.9% / 75.5%）。已改为
"成片被裁坏…**且眼带被 alpha 打掉 61.9%（75.5%）**"。

**并说明我为什么会标错**：我当时的分类依据是"哪种失效让**眼线量具**测不出"，
而不是"这张成片有没有洞" —— 对前者而言"裁坏"确实是主因，但**我把成因栏写成了"非抠图空洞"，
那是两个不同的问题**。同一个坑：**用一个量（量具失效原因）去回答另一个量（是否抠图空洞）**。
这正是勘误 10 那条"字段只用名字宣称口径"的又一次复发。
