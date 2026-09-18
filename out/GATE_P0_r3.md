## G2B-P0 第 3 轮：FAIL
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
本轮按 `r3` 编号。

### 轮次有效性判定（主会话 2026-09-17 裁定，**r2 起生效**）
> **一轮判决只能由同一个被冻结、被标识的代码状态上的测量推导出来。**任何一项判据的输入若来自另一个状态（不同工作树、不同 revision、不同测量台的上一次产出），**要么重测，要么把该项标为无效**。
机检七件：① `git status --porcelain -- lib test tools docs` 为空（`out/` 除外）；② 每条样本都解析得到、成片文件都在；③ 声明条数 == 实际解析条数；④ 样本清单里**没有解析不了的行**；⑤ **`out/` 下三份测量产出各自记录的代码指纹与当前树逐条一致**（`out/` 不受冻结约束，所以"工作树干净"推不出"盘上的数是当前代码跑的"——缺这一条，上一轮的遗留会被当成本轮读数）；⑥ **生成分母与手写分母逐条相等**（`denominatorAgreement`）；⑦ **派生块的证据溯源与盘上产物相符**（`evidenceProvenanceCheck`）。任一不过 → **整轮作废**（全部条目 pass=false、manual=true），不消耗实现方修复轮次。**加一行说明拦不住它**——r1 就是这么滑过去的，所以这里是判 `roundInvalid` 而不是写备注。⑥⑦ 有一条分工要说清楚：**「取不到」判作废（不赖实现方），「取到了但不等」判 FAIL 并点名**（那是判据分母被动过的措辞，不是输入不可信的措辞）。
**本机制晚于 r1**：r1 的 FAIL 判决（P0.3a max 11.368°、P0.3b 9 条）按主会话裁定**保留为基线测量**，不因本机制追溯作废；但它**不是对任何单一代码状态的判决**，不得用来论证"改了一轮没修好"。


### 本轮输入的一致性（读数绑在哪个版本上）
- HEAD = `c825d02`；判 selfcheck 那几条（P0.5a）编译自**工作树**，不是这个 commit。
- `git status lib/` **干净**：本轮读数可绑定到 `c825d02`。
- **冻结范围**：`lib` / `test` / `tools` / `docs` **全部在冻结内**；唯一豁免 `docs/PITFALLS.md` 这一个文件（它不进任何测量链——门禁不读它、判据不引用它、读数不经过它；且 CLAUDE.md §4 规定所有 agent 可随时只追加）。**`docs/` 里除它以外的任何改动（含 `ACCEPTANCE.md`/`RUBRIC.md`/`CONTRACTS.md`/`DESIGN.md`/`ENV.md`）仍会作废整轮。**本轮豁免条目： M docs/PITFALLS.md。
- 输入完整性：`out/P0_compose_items.jsonl` 声明 100 条、解析到 100 条，成片文件**全部存在**。注意这只说明"此刻文件在"，**不等于历史轮次可复算**。
- 成片台 summary：`crash=0`、`cases=100`、`ok=110`、`mattingFail=0`、`composeFail=0`、`noFace=0`。
- 三件套齐备，本项可判。


### 测量产出的来源绑定（`out/` 不受冻结约束，所以另有一道绑定）
- 3 份测量产出均可自证与当前树同源（受钉源码 103 个文件 = `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`；代码摘要 -32be85b2dab13e3e）；标定靶：test/golden/src/g01.jpg 与内容钉一致（sha256=25b14d07b1375bc3…）
- 指纹域（**由门禁定义，不由生产者定义**）：`lib`、`test/batch` 下全部 `.dart` / `.py`，共 103 个文件；门禁侧 git 可用 = true；代码摘要 `-32be85b2dab13e3e`。生产者记录的是超集也接受，**缺任何一个都判不可判**——域若能被生产者收窄，这个检查就形同虚设（少记一个文件 = 那个文件改了也不响）。
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
- 手写分母 `out/P0_truth_v0.json`（sha256 前缀 `7aea984c53088cb5…`） vs 生成分母 `out/P0_truth.json`（`2e46dcfe6207b0ea…`）
- **比对范围由手写件决定**（不硬编码清单名）：手写件里每个**列表**值都要在生成件里逐条对上 —— 生成件不得改动或丢掉任何一条，也不得缺少手写件写了任何一个字段。生成件**自己的派生字段**（`corpus` / `kind` / `derivedAnnotations` / `end_to_end` …）不参与比对：它们是产物，不是分母。
- 比了 anchors=12条、nonPortrait=66条、rejected=1条、rotated=78条、straight=1条、uprightSynthetic=9条；登记豁免 1 条（anchors/p2）；v0 没有、故**未比**的生成件清单：knownLimitations；因形状豁免**未逐值比**的字段：methods×13（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）
- 结论：**逐条相等**。
- **不许被读大**：这一条证明"生成件用的是手写件的分母"，**不证明**这份分母本身是对的。前者是完整性，后者要靠锚点复核与人工审查。


### 派生数字的证据溯源（叙述是不是盘上产物的函数）
- 指针（写死在门禁里，不随数据飘）：`gateInputs/rotationFailureBoundary/evidenceProvenance/sourceSha256`
- 核了 3 份源产物：out/P0_output_residual.json=一致、out/P0_compose_items.jsonl=一致、out/P0_alpha_holes.json=一致
  - `out/P0_output_residual.json`：记录 `a80d66ee4e81262f…`，盘上 `a80d66ee4e81262f…`
  - `out/P0_compose_items.jsonl`：记录 `8c39d726caaf970a…`，盘上 `8c39d726caaf970a…`
  - `out/P0_alpha_holes.json`：记录 `3ad3a37951061645…`，盘上 `3ad3a37951061645…`
- 结论：**逐份相符**。
- **边界（不许被读大）**：这证明的是「派生叙述与盘上这几份产物一致」，**不是**「产物出自当前被测代码」—— 源产物自己**没有**代码指纹。后一件事由「测量产出的来源绑定」那一节管，两件事别混。


### 硬判据出自哪支量具（避免把量具差异读成分歧）
- **P0.1a / P0.2 / P0.3a② / P0.5b** 的成片残余：gatekeeper 的 **Haar 眼线量具**（`tools/gate/p0_eyeline.py`，自检最大误差见上）为第一读出；它测不出的样本改由 **SIFT 源图↔成片配准**（`tools/gate/p0_rigid_check.py align`）读出，逐条出处写在样本账里。
- **交叉复核**用的第二支是 qa-batch 的瞳孔法（`out/P0_output_residual.json`），两者是独立量具：同一张成片上读数可以不同（本轮最大差 1.414°），但只要两者都远超阈值就不构成分歧。**报告里的硬指标一律注明出自哪支**。
- 口径无关性：SIFT 只量"管线实际转了多少度"，不读眼线、不读 alpha、不读生产诊断，是符号约定出错时唯一不会跟着一起错的路径。

### 量具自检（量不准的量具没有资格判别人）
- 眼线量具：最大误差 0.4101256717524797°，门槛 0.5° → 合格
- 刚体配准量具：最大误差 0.5°，门槛 1.0° → 合格
- 两条路径的独立测量一致性：见「交叉复核」一节
- 门槛由**门禁**定（不是工具自报）：眼线量具喂亚度级统计，故要求 0.5°；刚体量具只用于 ≥1.5° 量级的分歧复核，1.0° 够用。

### 交叉复核（gatekeeper 眼线量具 vs qa-batch 眼线测量）
共同可测 87 条：|差| 中位 0.382°，最大 1.017°。**原始读数** |成片倾角| > 1.5° 的集合（不是违规计数，违规还要按条件覆盖率口径折算）：gatekeeper 1 条 / qa-batch 0 条，qa-batch 的集合**是** gatekeeper 的子集——它报出的每一条超标本量具都独立复现；双方一致判定达标的 86 条。两条路径的系统性差异约 0.38°（不同方法：Haar 眼级联 vs YuNet 眼位+暗色圆盘+Radon 共识），小于判据容差 1.5° 的 1/3，足以互相印证，不足以单独定案——故凡两条路径读数相差 > 1° 的样本，判定一律回退到独立第三方证据（生产记录 + 已验证恒等式）。

SIFT 路径：可配准 99 条，实测施加角与生产记录 |差| 最大 0.077°；它测出残余超 1.5° 的样本 0 条（）——其中 c08_d-5 是另两台都量不出来的那条。

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

没有样本"因为量不出来而不算数"：眼线量具测不出的 12 条，全部改由 SIFT 源图↔成片配准独立测出（残余 = 真值 − 实测施加角），逐条如下。

| 样本 | 眼线量具为何失效 | 归类 | SIFT 独立复核 | 最终取值 |
|---|---|---|---|---|
| c08 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -7.865°，与生产记录差 -0.014° → 残余 -0.145°；qa-batch 读数 0.465°（ok） | -0.145°（gate_sift_align） |
| c08_upright | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 0.019°，与生产记录差 0.019° → 残余 -0.019° | -0.019°（gate_sift_align） |
| c08_d-10 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -17.844°，与生产记录差 -0.022° → 残余 -0.166°；qa-batch 读数 3.335°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.166°（gate_sift_align） |
| c08_d-5 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -12.801°，与生产记录差 -0.009° → 残余 -0.209°；qa-batch 读数 2.028°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.209°（gate_sift_align） |
| c08_d-3 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 -10.892°，与生产记录差 0.002° → 残余 -0.118°；qa-batch 读数 0.522°（ok） | -0.118°（gate_sift_align） |
| c08_d+3 | no_face | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 也配不上——这条仍未测出，须人工介入。 | -0.417°（derived_identity） |
| c08_d+5 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -2.840°，与生产记录差 0.011° → 残余 -0.170°；qa-batch 读数 5.755°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.170°（gate_sift_align） |
| c08_d+10 | no_face | 成片被裁坏（人脸出画/过大，正脸级联失效；**非抠图空洞**） | SIFT 实测施加角 2.169°，与生产记录差 -0.002° → 残余 -0.179°；qa-batch 读数 -3.445°（reliability_mismatch） —— 已被 qa-batch 自己声明不可靠，不采信 | -0.179°（gate_sift_align） |
| c11_d-3 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 -2.694°，与生产记录差 -0.009° → 残余 -0.416°；qa-batch 读数 -0.487°（ok） | -0.416°（gate_sift_align） |
| c12_d-10 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -12.011°，与生产记录差 0.007° → 残余 -0.079°；qa-batch 读数 0.005°（low_confidence） | -0.079°（gate_sift_align） |
| c12_d-3 | implausible_eyedist | 量测失效（本量具在该图上配错眼对，已由瞳距/脸宽筛拦下） | SIFT 实测施加角 -5.121°，与生产记录差 -0.004° → 残余 0.031°；qa-batch 读数 0.345°（ok） | 0.031°（gate_sift_align） |
| c12_d+10 | no_eye_pair | 抠图失效（眼区被 alpha 空洞打掉） | SIFT 实测施加角 7.913°，与生产记录差 -0.001° → 残余 -0.003°；qa-batch 读数 -0.059°（ok） | -0.003°（gate_sift_align） |

**条款 7 点名的那条（`c08_d+10`）的定论**：它的 alpha 是干净的（qa-batch 扫到 eyeBandZeroFrac 0.002），却被 qa-batch 的自证式检查判为 unreliable，正是"把真实缺陷归成量不出来"的现成嫌疑。本门用 SIFT 独立量了源图→成片这一跳：实测施加角 2.169°，与生产记录 2.171° 差 -0.002°，残余 = 真值 1.990 − 实测施加角 = **-0.179°**，|残余| ≤ 1.5° → **不构成违规**。qa-batch 那一支的 -3.445° 是量测假象，它自己也已标注 reliability_mismatch。（顺带纠正一处易错：`c08_d+10` 的真值是 −8.01+10 = 1.990°，不是 18.01°；18.01° 是 `d-10` 那条，它反而被正常摆平到 -0.166°。）

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
#### P0.3a FAIL
- 期望：② 斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°
- 实测：
  ② 硬判据：残余 vs 真值 斜率 = 0.000（|·| ≤ 0.15），截距 = 0.251°（|·| ≤ 0.5），max|残余| = 1.753°（≤ 1.5）
  超 1.5° 的夹具 1 条：c06_d+3(1.753°)
  只用 pupil 夹具 100 条（原始 100 条）
  ① 诊断：估计值 vs 真值 斜率 = 0.999（带 [0.85, 1.15]，不参与 PASS/FAIL）
  按口径 1 排除在残余统计外的 unavailable 样本 0 条（它们的账由 P0.3b 条件覆盖率算，不许在这里被悄悄算成通过）：
  残余出处：{derived_identity: 1, gate_eyeline: 88, gate_sift_align: 11}（derived_identity = 两条量具都测不出，用已验证恒等式 残余=真值−施加角 推出）
#### P0.3b PASS
- 期望：需要摆正的 67 条夹具上 unavailable = 0
- 实测：
  需要摆正（|truth| > 1.5°）的 67 条夹具上 unavailable = 0
  旋转夹具原始总数 78 条，需要摆正 67 条
  |truth| ≤ 1.5° 而 unavailable 的 0 条，按口径 2 可接受
  分母：可计分 78 条 / 原始 78 条（无样本因量测失效被扣除，见条款 7 样本账）
#### P0.4 PASS
- 期望：unavailable 样本施加角 = 0 的违规数 = 0，且不得出现 source=given
- 实测：
  全量可合成样本 100 条，来源分布：{pupil: 100}
  锚点：{pupil: 12}；竖直：{pupil: 10}；夹具：{pupil: 78}
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
  00:23 +4: 2B.8 摆正（±10° 输入的残差角）
  [2B.8]
    输入 roll=-10.0° → 成片残差 -0.039°
    输入 roll=-6.0° → 成片残差 -0.034°
    输入 roll=6.0° → 成片残差 0.034°
    输入 roll=10.0° → 成片残差 0.039°
    输入 roll=0.8°（死区内）→ 是否旋转=false
    最差残差=0.039° (阈值 1.5°)
  00:25 +5: 用户框选 × 摆正：主体尺度守恒（REVIEW_G2 #3 回归）
  [用户框选×摆正]
    roll=0.0° 摆正=false 裁剪框=460.0×644.0（用户框 460×644） 成片头高=243.0px（理想 243.7） 保留比例=99.7%
    roll=2.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=6.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=-10.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    roll=20.0° 摆正=true 裁剪框=460.0×644.0（用户框 460×644） 成片头高=245.0px（理想 243.7） 保留比例=100.5%
    最差偏离=0.5% (阈值 3%)
  00:27 +6: 用户框选 × 摆正 × 越界：无黑边（2B.9 的反旋转新路径）
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
  00:28 +7: 2B.9 边界安全（贴边人脸不抛异常、无黑边）
  [2B.9]
    setup0 完成，越界比例=26.0% 缩小=false 说明=裁剪框越界 26.0%（越出部分按 alpha=0 填底色）
    setup1 完成，越界比例=28.7% 缩小=false 说明=裁剪框越界 28.7%（越出部分按 alpha=0 填底色）
    setup2 完成，越界比例=0.0% 缩小=false 说明=裁剪框完全在图内
    setup3 完成，越界比例=7.6% 缩小=true 说明=人脸过于贴边/过大，已按头顶锚点缩到越界 ≤ 45%：头高比 1.307（目标 0.640），越界 7.6% 填底色
    setup4 完成，越界比例=31.0% 缩小=false 说明=裁剪框越界 31.0%（越出部分按 alpha=0 填底色）
    图外区域出现的非底色像素总数（最差单张）=0 (阈值 0)
  00:31 +8: 渐变底与去色边质量（蓝渐变 / 白底，合成原片）
  [渐变] 顶部=(97,138,206) 期望≈(98,139,206) 底部=(43,89,160) 期望≈(43,90,160)
  [去色边] 换白底后残留蓝边像素=0 (阈值 0)
  00:31 +9: All tests passed!
  
  stderr:
  
#### P0.5b PASS
- 期望：两个**分开报**的子量都要过：① 施加几何 —— SIFT 实测施加角 vs 生产记录 |差| ≤ 1.5°；② 跨量具一致性 —— 眼线实测残余 vs (真值−施加角) ≤ 1.5°
- 实测：
  ①【判据量·施加几何】SIFT 源图↔成片配准，可配准 99 条，实测施加角 vs 生产记录 |差| 最大 0.077° （阈值 1.5°，余量 1.423°）—— 此项不读眼线、不读 alpha、不读生产诊断，是 2B.8 本体的直接测量
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
  清白（**条款 1 自 `7773df4` 起才真正执行 —— 该 commit 之前各轮的「清白」在条款 1 上是空的，不得引用为历史**；黄金集 src=8 ref=8；skip/catch 扫描：条款 3：skip 命中 33（其中 33 条落在巡检自身领地，已登记不判违规）；注释掉的断言命中 0；**被放宽的阈值常量：无独立扫描器，靠基线 tag diff 结构性覆盖**（阈值只在 ACCEPTANCE.md 与 tools/gate/ 两处，分别受条款 1、条款 2 保护）；条款 5：空 catch 命中 0（无注释）+ 0（体内只有注释）＝ **共 0 处，一律计违规**（主会话 2026-09-17 改口径：注释不该决定任何事 —— "加一句注释就降级"是一条能被扩写的洗白通道。让那几处清白的不是注释，是它们周围的代码，所以修法是改掉它们，不是给注释体开后门）；判据定义：体内剥掉注释与字符串后，除空白与 `;` 外没有任何语句 ⇒ 空实现。**含注释体与 `catch (_) { ; }`**，不是只认 `{}`。；**判据分母内容钉（out/P0_truth_v0.json 手写件）**：out/P0_truth_v0.json 相对基线无变化（949 个数值叶参与比对）。数值叶排除集：**空**（一个都不排，全部逐叶比对） 钉子对象：`out/P0_truth_v0.json`（本轮未变）；换靶历史（**只增不删**）：`out/P0_truth.json -> out/P0_truth_v0.json`；**分母一致性（生成件 vs 手写件）**：比了 anchors=12条、nonPortrait=66条、rejected=1条、rotated=78条、straight=1条、uprightSynthetic=9条；登记豁免 1 条（anchors/p2）；v0 没有、故**未比**的生成件清单：knownLimitations；因形状豁免**未逐值比**的字段：methods×13（定义在 `kDenominatorShapeAllowance`，受条款 2 保护）；**派生数字证据溯源**：核了 3 份源产物：out/P0_output_residual.json=一致、out/P0_compose_items.jsonl=一致、out/P0_alpha_holes.json=一致；**测量产出同源**：3 份测量产出均可自证与当前树同源（受钉源码 103 个文件 = `lib/` 全部 `.dart` + `test/batch/` 全部 `.dart`/`.py`；代码摘要 -32be85b2dab13e3e）；标定靶：test/golden/src/g01.jpg 与内容钉一致（sha256=25b14d07b1375bc3…）；受钉文件 43 个；基线 baseline-p6p0 以来 test/ tools/gate/ ACCEPTANCE/RUBRIC 无实现类 agent 改动；门禁自身未提交改动 19 个，已在 out/GATE_P0_selfchanges.txt 逐条自报）

### 失败项
| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| P0.3a 旋转等变：① 估计值 vs 真值斜率 ∈[0.85,1.15]（只作诊断）；② 成片残余 vs 真值斜率 |·| ≤ 0.15、|截距| ≤ 0.5°、max|残余| ≤ 1.5°（硬判据，口径无关） | ② 斜率 /·/ ≤ 0.15、/截距/ ≤ 0.5°、max/残余/ ≤ 1.5° | ② 硬判据：残余 vs 真值 斜率 = 0.000（/·/ ≤ 0.15），截距 = 0.251°（/·/ ≤ 0.5），max/残余/ = 1.753°（≤ 1.5） | ml-porting |
| P0.5c 不回归：2B.8 之外的 G2B 项 / G4 已过项不退化（判据只覆盖"原本通过的项"） | 原本通过的项重跑后仍 PASS；本项需重跑才能判定 | 本轮未重跑设备端（上游 P0.3a/P0.3b 未修好时重跑不产生新信息，一轮约 40 分钟）。 | gatekeeper（本轮未重跑，无法判定是否退化；留待上游修好后补跑） |

### 回派指令
- ml-porting：P0.3a 未达标，详见上面各项「实测」。
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
ecc8d4da98a29f4ba134228dcf66efe665ac149614f358167ed1d95948a02ec8 *tools/gate/p0_eyeline.py
7c30c6ee828d02f77159392a4aae0d979884f8dbf48f9bcd5b61033823be13ef *tools/gate/p0_overlap.py
8a46d89c013acfb61a209e467036ffaf32eb734463e8cda4ba1082b8a96a5b08 *tools/gate/p0_rigid_check.py
8fc0270be7475a702d4d71735b3f327db72ffd116091ba739e343c73249d81f0 *tools/gate/p0_roll_probe_test.dart
fb0711446e483b8a1fc72f549516fec7fcd2fcbaf6eaf4d933456a59587c3ae2 *tools/gate/png_utils.dart
5452451ef5a6e617b26fc65cce7ab79427b267c4dab076e64d5b223864764a9c *tools/gate/provenance.dart
45ada1647fc0766a7dbf594d015274b5252850a8b43f62925db9ba629fb712b0 *tools/gate/rot_dir_check.dart
86ccf34ec2b960f74727cd0bf528a42f4337fcf8b92c35a2c6ab15675d167c0a *tools/gate/sha256.dart
```

---
---

# 门禁官判决层（r3 · 冻结后正式轮）

## 结论

**G2B-P0 第 3 轮：FAIL。通过 10 / 12 项，MANUAL 1 项。退出码 = 1（实测）。**

本轮为**冻结后的正式轮**（窗口 09:19:12–09:24:42）。前两次运行均已作废另存：
`out/GATE_P0_r3_VOID_inputsPreRemeasure.{md,json}`（qa-batch 重测产物尚未生成）、
`out/GATE_P0_r3_VOID2_truthRewrittenMidWindow.{md,json}`（`out/P0_truth.json` 在窗口内 09:12:41 被改写）。

**唯一实质失败项是 P0.3a，而它带一个必须由主会话裁定的问题**（见下）。**P0.3b 已 PASS。**

## 本轮有效性的披露（**不隐瞒**）

门禁自身的 7 条轮次有效性检查**全部通过**（无 `roundInvalid`），三条被钉产出均自证与当前树同源
（103 个文件逐条比对 0 不一致，指纹 `cd417a4d254ec1c2`）。

**但有一件事必须写出来**：本窗口内 `out/P0_truth.json` 与 `out/P0_input_hashes.json`
于 **09:22:10** 被写入过。**已排除本门**：gate 只 spawn `p0_eyeline.py` / `p0_rigid_check.py` /
`p0_overlap.py` / `flutter test dev_selfcheck.dart`，四者均不写这两个文件（逐个 grep 过）。
写入方是 `test/batch/p0_finalize_v1.py`。

**而门禁无法证明它没变过** —— `out/hashes_P0_r3_pre.txt` 与 `out/hashes_P0_r3.txt`（各 43 条）
逐条比对**只有 `golden_src`/`golden_ref` 两行新增、无任何文件哈希变化**，
但两份快照里只有 `out/P0_truth_v0.json`（手写件）与 `out/P0_truth_leaves_baseline.txt`，
**没有被判据实际读取的生成件 `out/P0_truth.json`** —— 它在 2026-09-17 换靶时被移出了快照集。
**⇒ 门禁一直在读一个自己不核窗口稳定性的文件。**

**仍判本轮有效的证据是间接的，列出来供你复核**：
(a) 所有由真值派生的读数在改写的两侧**逐项一致** —— 改写前那轮与本轮在
P0.1a / P0.1b / P0.2 / **P0.3a（同为 1.7534°）** / P0.3b / P0.4 / PIN 上完全相同；
(b) 文件大小两侧同为 **199403** 字节；
(c) 唯一翻转的是 **EVID** —— 改写前那轮 **9/12** 且 EVID 报「不相符」，本轮 **10/12** 且 EVID 报「相符」
（两份 JSON 逐条比对过），与 finalize 重跑刷新了摘要一致。
**这三条都是旁证，不是证明。** 我的判断是可用，但我把判断依据摆出来，不要求你采信。
**本轮唯一实质失败项 P0.3a 的读数在改写两侧完全相同，故本次污染不影响该失败成立与否。**

## 失败项

| 项 | 期望 | 实测 | 责任 agent |
|---|---|---|---|
| **P0.3a** | max\|成片残余\| ≤ 1.5° | **1.7534°**，超线 **1 条**：`c06_d+3` | ml-porting（**归属待裁定，见下**） |

## MANUAL 项（显式列出，**未**当作通过）

- **P0.5c**：本轮仍未重跑设备端。生成层条件为「上游 P0.3a/P0.3b 未修好时不重跑」——
  P0.3b 已修好、**P0.3a 未定**，故条件仍成立，**记 MANUAL，不计入通过数**。
  **若主会话裁定 P0.3a 属边界噪声 ⇒ 上游视为已修好 ⇒ 应补跑**（届时打印两侧 `generatedAt`）。

## P0.3a：排除它适用贴线规则的那两条理由，本轮一条也不成立

### 事实（逐条可复现）

1. **超线只有 1 条**：`c06_d+3` = **1.7534°**（`out/gate_P0_eyeline.json`）。
   **第二差 `c12_d+3` = 1.4764°，距阈值仅 0.0236°。** 68 条 rotated 行里再无其它超线。
2. **第二支量具不复现这条超线**：SIFT（`out/gate_P0_sift_align.json`）给 `c06_d+3` = **1.2610°**，在阈值之下。
3. **余量 = 1.5 − 1.7534 = −0.2534°**；量具**自检误差 0.41°（眼线）/ 0.500°（刚体）**。**余量 < 量具误差。**
4. 两支量具在**同一张成片**上相差 **0.4924°**，与其各自的自检误差同量级。

### 规则冲突

主会话 2026-09-17 的贴线规则（`tools/gate/gate_P0.dart:275`、`:892-900`）：

> 余量 < 量具误差的条目，**单支量具的 FAIL 不足以定罪** —— 须第二支独立量具复现同一超线才计违规；
> 只有一支超线则记「边界噪声 / 证据不足」，**不消耗实现方修复轮次**。
> **本规则不适用于 P0.3a**：它**超阈值 7 倍以上**且**两支量具独立复现**，是确定性违规。

**本轮按字面正好落进这条规则的射程**（余量 −0.2534 < 0.41；单支超线）；
**但同段明文排除 P0.3a，而排除所依据的两条本轮都不成立**：超阈值 **1.17 倍**（非 7 倍以上），
第二支量具**未复现**（SIFT 1.2610° < 1.5°）。**那段理由描述的是 r1 的状态（11.368°），没有被更新。**

**⇒ 我不自行适用**（明文排除；`tools/gate/**` 冻结；阈值与判据只有主会话能动）。
**按冻结判据记 FAIL，冲突原样上交。这一条决定本轮是否消耗 ml-porting 的修复预算 —— 请先裁定再派活。**

### 机理（独立于裁定）

三条最差的成片残余，**恰好是三条「引擎施加 0.0°」的样本**：

| id | 真值 | 生产施加 | 眼线 \|成片倾角\| | SIFT 残余 | 与死区 |
|---|---|---|---|---|---|
| `c06_d+3` | 1.27 | **0.0** | **1.7534** | 1.2610 | 外 0.27° |
| `c12_d+3` | 0.91 | **0.0** | 1.4764 | 0.8995 | **内** |
| `p1_d+5` | 0.60 | **0.0** | 1.3020 | 0.6070 | **内** |

小倾角组（|真值| ≤ 3.0）n=18 → max **1.7534**，中位 0.3710；大倾角组（> 3.0）n=50 → max **0.8725**，中位 0.3115。
**死区把「不施加旋转」换成了「成片保留原倾角」，而那个倾角本身就是残余。**
**非本轮引入的回归**（r2 这三条同样施加 0.0）—— 是死区 1.0°（`crop_geometry.dart:125`）与 1.5° 判据之间余量本来就薄。

## P0.3b：**PASS**

| | 分母（`rotated` 且 \|真值\| > 1.5） | `unavailable` | SIFT 配准 |
|---|---|---|---|
| r2 | 67 | **2** | 98 / 100，max \|施加角差\| 5.036° |
| **r3** | 67 | **0** | **99 / 100，max \|施加角差\| 0.077°** |

110 行里只有 **5 行**的施加角或来源变化。**`unavailable` → 误差 > 1.5° 的样本：0 条。**
**P0.3b 的适用范围见 `out/GATE_P0_r3.caveats.json` 的 `C1-p03b-scope`** —— 该 0 只对分母内 67 条成立，
不含 `|真值| ≤ 1.5`、不含 `27670b3` 之前的历史违规。**不得读成「摆正问题已全解」。**

## 两处我自己的更正（**都指向我自己，不是别人**）

### 更正一：撤回对 ml-porting 的指控，并撤回我推断它的那条依据

我在作废轮报告里写过「推断是刚改完 `iris_roll.dart` 的 ml-porting 在自查」，
并据此写了「**被判方在判定中改写判据输入，结构上让证据由被证者控制**」。

**两处都错，撤回。**

1. **归属错**：08:56:22/08:56:23 那两笔是 **qa-batch 按主会话指令重跑被钉产出**，ml-porting 当时 idle、这轮没动过手。
   （qa-batch 已在自己报告 §6 里逐条对上：`out/r3_logs/02_compose.log` 尾部 `All tests passed!` 与两份产物的 mtime 一一对应。）
2. **依据也错，而且更该记**：我写「gate 只调 `git`、故必是外部进程」时，**只 grep 了 `Process.runSync`**。
   gate 实际通过 `runProcess(...)` **spawn 了四个外部进程**
   （`p0_eyeline.py` selftest+run、`p0_rigid_check.py` selftest+align、`p0_overlap.py`、`flutter test dev_selfcheck.dart`）。
   **我的「排除本门」这一步从来没成立过** —— 我只是没搜到那些调用。
   **一次 grep 漏了一种调用方式，就得出一句关于进程归属的结论。**
   （本轮重做时按正确范围查过：上述四个脚本**都不写** `P0_truth.json` / `P0_input_hashes.json`，
   所以本轮的排除是成立的 —— 但那是**这一轮**才查的。）

真正的问题是**协调**：我判读的窗口与产出的再生成窗口没有互斥。**根因在主会话，已由其认领并定了新纪律**（测量冻结窗口由主会话宣布）。

### 更正二：`out/P0_alpha_holes.json` **有判据读它**，我先前说没有是错的

我写过「门禁里没有任何判据读它……进不了 PASS/FAIL」。**错的。**
我只在 `tools/gate/` 里搜，看到它只出现在 `:2776` 一处且是 `writeln` 的字符串字面量就下了结论。
**真正的通路在生产者那一侧**：

```
test/batch/p0_finalize_v1.py:172-180  读它，取 assessable 行的 eyeBandZeroFrac
test/batch/p0_finalize_v1.py:539-540  把结论写进 out/P0_truth.json
                                      （gateInputs.alphaHoleIndependentOfRotation）
out/P0_truth.json 的 gateInputs.rotationFailureBoundary.evidenceProvenance.sourceSha256 记下它的 sha256
tools/gate/gate_P0.dart 的 EVID 项逐份比对这组摘要 -> 进 PASS/FAIL
```

**本轮 EVID 正因为对不上而 FAIL 过一次（改写前那轮 9/12），重跑 finalize 后才转 PASS。**
**⇒ 这解释了一个反直觉的耦合：重生成 `out/P0_alpha_holes.json` 会让第 ⑤ 条（钉）变绿，却会让 EVID 变红**
——因为 finalize 记的摘要还是旧的。**两份检查方向相反，必须连 finalize 一起重跑才能同时成立。**

**同一个错今天第三次**：`inputProvenance`（搜了 `tools/`+`lib/`，生产者在 `test/batch/`）、
`bakeOrientation`（搜了两个文件，第三个同目录文件里有）、现在这个。
**范围要由命题的主语给，不是由结论旁边最近的文件给。**

## 盲区（量不出来的必须挂牌）

- **`c08_d-10`：残余无法独立确认，记盲区。** 真值自标 `lowConfidence`
  （`out/P0_truth.json` → `/anchors/8/note`：「仅 2 法可用且互差 **1.69**」），**真值自身不确定度 ~1.7° > 判据 1.5°**。
  本轮施加 −17.8222（`pupil`，不再是 `unavailable`），方向必然更好，但「准不准」**没有独立路径**。
- **`derived_identity` 1 条**：两条量具都测不出，恒等式回填，不是测出来的。

## 覆盖缺口（本门禁对此没有读数）

1. **「成片看起来被切了一刀」无任何判据覆盖**（`out/GATE_P0_r2.caveats.json` 的 C3）。
   imaging 提出的替代判据**本门禁不采纳**，理由不是「不归我管」：
   **该阈值由提出方自己给出，又由同一方报出「cn_big_1inch 有 50 条可见」——
   提出者与计数者是同一个主体，阈值本身需要独立标定。** 阈值只在 `docs/ACCEPTANCE.md`，只有主会话能改。
   支撑事实（imaging 报）：`outOfBoundsFraction` **两个方向都会错** ——
   漏（oob 记 0.000 却有 130–218px 长直切口）与虚（oob=0.43 的 `c05_d+5` 成片里没有切痕）。
2. **`|真值| ≤ 1.5°` 的样本无残余判据**：`kCoverageMinTruthDeg = 1.5`（`gate_P0.dart:180`）
   既是 P0.3b 门槛又挡掉小倾角残余 —— **而死区恰好在这个区间留下最大的成片倾角**。**结构性盲区。**
3. **生成件 `out/P0_truth.json` 不在窗口稳定性快照内**（见上）。

## 另行更正两处转述

- **「跨度 4 小时」撤回**：`out/P0_alpha_scan/` 那次扫描只有 **43 秒**；4 小时是把**目录 mtime** 当扫描时长读出的假象。
  目录里 03:45–03:46 的 4 张图是**别的手工对照图、不参与测量**（`test/batch/p0_alpha_holes.py:62,74` 按 manifest 取文件）。
  qa-batch 已在 `out/QA_r3.md` §4 独立确认同一点。**「无指纹」这一点不受影响。**
  已在 `out/GATE_P0_r2.caveats.json` 的 C4 内加了 `evidenceCorrection`。
- **`-32be85b2dab13e3e` 与 `cd417a4d254ec1c2` 是同一个 64 位 FNV**：
  `0x10000000000000000 − 0xcd417a4d254ec1c2 = 0x32be85b2dab13e3e`，差异来自 Dart 有符号 `toRadixString(16)`。
  **判据走 `blobHashes` 逐条比对（正确），但并排印在人读的报告行上会被读成「代码变了」。** 解冻后统一打无符号。

## 脚本完整性 / 防作弊巡查（条款 1–6，逐条）

| 条款 | 读数 | 判定 |
|---|---|---|
| 1 实现类 agent 未碰受保护路径 | 自 `baseline-p6p0-r2` 起受保护路径仅 3 条改动，作者均为 gatekeeper（`f676e19`/`4e33340`） | 清白 |
| 2 gate 脚本 SHA256 | 26 个脚本全量重算，**仅 `p0_eyeline.py` 一处**，gatekeeper 且已声明（`out/GATE_P0_r2.md:966`） | 清白 |
| 3 `skip:` / 注释掉的断言 | `lib/` 0 命中 | 清白 |
| 4 `test/golden/` 文件数 | src=8 / ref=8，未减少 | 清白 |
| 5 空 catch | `lib/` 0 处 | 清白 |
| 6 报告数字 vs `out/gate_P0_r3.json` | `pass=false`、`10/12`、`manual=1`、退出码 1，逐项一致 | 清白 |

**条款 2 的已知洞仍在**（自报清单自身一度不在受钉集内）；本轮由主会话的 33 条冻结基线**独立**补上。

## 回派指令

1. **主会话（最优先）**：裁定 P0.3a 是否适用贴线规则。**排除它所依据的两条理由本轮均不成立。**
   **裁定前不要给 ml-porting 派 P0.3a 的活。** 另：裁定为边界噪声 ⇒ P0.5c 应补跑。
2. **qa-batch**：EVID 已随 finalize 重跑转 PASS，**本次无需动作**。
   但请注意 `alpha_holes` 与 finalize 的**反向耦合**（见上），今后两者必须成对重跑。
3. **imaging**：死区 1.0° 与小倾角成片残余的关系（机理见上）。**是否调死区是产品/阈值决定。**
4. **ml-porting**：**P0.3b 已达标；本轮无待修项**（P0.3a 待裁定）。
5. **解冻后（gatekeeper 自己）**：① 把生成件 `out/P0_truth.json` 加回窗口稳定性快照；
   ② 统一摘要打印为无符号；③ 把 `P0.3b` 的适用范围写进 gate 的 `actual`（现由 `out/GATE_P0_r3.caveats.json` 的 C1 承担）。

## 轮次账

| 轮 | 结果 | 消耗 ml-porting 预算 |
|---|---|---|
| r1 | 作废（门禁自身缺陷） | 否 |
| r2 | FAIL（10/12，P0.3b = 2 条） | **是 —— 第 1 次** |
| r3 预跑 | 作废（重测产物未生成） | 否 |
| r3 第二跑 | 作废（truth 在窗口内被改写） | 否 |
| **r3 本轮** | **FAIL（10/12，P0.3a）** | **取决于上述裁定** |

**未触发终止**：`out/BLOCKED_G2B-P0.md` 只在**第 3 次消耗性 FAIL** 时写。**未写、未降任何阈值。**

---
---

# 门禁官补记（r3 · 裁定并入 · **正文不改**）

本文件正文（`:1–:489` 门禁生成层、`:490–` 判决层）**保持提交时原样，一字不改** —— 裁决记录事后改写即为篡改。
以下为提交**之后**到达的裁定与复核，按只增不改并入。机器可读版见 `out/GATE_P0_r3.caveats.json` 的 C10–C12。

## 补记 1：P0.3a 的账 —— 主会话裁定为**边界噪声**，**不消耗**修复预算

裁定出处：主会话 `e71e1d2a` / `94a575a6`。

- `gate_P0.dart:275` / `:892-900` 里那句「本规则不适用于 P0.3a」是**描述性的**（描述 r1 当时的状态），**不是永久豁免**。理由：照字面读成豁免，则 P0.3a 上任何小于量具误差的超线都会自动定罪，而 1.5° 阈值只有两支量具自身误差（0.41 / 0.5）三倍余量 —— 那样记账的是噪声，不是实现方的错。
  ⇒ **P0.3a 与其他项一样受贴线规则约束。**
- 本轮那条超线：`c06_d+3` 余量 1.7534 − 1.5 = **0.2534 < 量具误差 0.41/0.5**；第二支量具 SIFT 读 **1.2610**，**未复现**超线；该夹具真值由构造给出 **1.27**（`geoRecoveredDeltaDeg 2.999` / `geoNcc 0.9994`，成片施加角 0.0），**与 SIFT 一致、与 eyeline 的 1.7534 差 0.48**（正是 eyeline 的自检误差）。
- ⇒ 记 **边界噪声 / 证据不足**，**不消耗 ml-porting 的修复轮次**（仍为**已用 1 次、剩 2 次**，那一次是 r2）。

**判决正文仍写 FAIL（按冻结判据），但记账为不消耗。**
**「算不算一轮有效」与「消不消耗预算」是两件事，必须分开写** —— 压成一句「r3 FAIL」会把它们指向完全不同的动作。

**两句照写，不许软化**：

1. `c06_d+3` 成片**确实保留了约 1.27° 倾角**，成因是死区（引擎估 0.79° < `kRollDeadZoneDeg` = 1.0 ⇒ 施加 0.0°）。它是覆盖缺口 **C3** 的成员，**不是「修好了」**。
2. 若下次第二支量具**复现**同一超线 ⇒ **那是真 FAIL，且照常消耗轮次**。裁定的只是「单支量具、余量小于其误差」这一种情形。

## 补记 2：P0.5c 的理由更正 —— 是**主会话决定推迟**，不是「上游未修好」

我正文写的理由是「上游 P0.3a/P0.3b 未修好时重跑不产生新信息」。**在 P0.3a 被裁定为边界噪声之后，这句已不成立，撤回。**

正确表述：**P0.5c 按主会话决定推迟至下一轮。** 原因：`lib/core/imaging/**` 已解冻、imaging 正在改死区与裁剪回退（用户裁定「一律出图、缺口缩到最小」），一轮约 40 分钟，现在跑完代码一变就要重跑。

MANUAL 状态不变，**仍不计入通过数**。下一轮随完整 r3 一起跑，**两侧 `generatedAt` 都打印**。

## 补记 3：09:22:10 那次真值重写的实质影响 —— **判据值零变化**（本门禁独立复核）

`git show HEAD:out/P0_truth.json` 与工作树逐叶比对：**两侧各 4374 个叶，集合完全相同，仅 2 个叶变化**：

| 叶 | HEAD | 工作树 |
|---|---|---|
| `/evaluatedState/codeFingerprintAtFinalize/headCommit` | `fb2f161a…` | `c825d021…` |
| `/evaluatedState/headAtFinalize` | `fb2f161` | `c825d02` |

**两个都是自述性 provenance（记的是「跑 finalize 那一刻 HEAD 在哪」），其余 4372 个判据值逐位相同。**
⇒ **这一轮读哪一版，判决都不变。** 本门禁独立复算，与主会话的数字一致。

**从此写死这条口径：作废的判据是「判据值会不会变」，不是「文件有没有被碰」。**
两者分开写 —— 否则会把一次**实质变更**和一次**纯 provenance 变更**报成同一件事。
（09:15 那次作废**成立**，因为当时尚未做这个叶级比对；本次比对证明本轮属后者。
**这不追溯翻案**：作废轮按当时掌握的信息处置是正确的，且其重跑成本由流程承担、不消耗实现方预算。）

## 补记 4：本轮的账

| 项 | 账 |
|---|---|
| P0.3a | FAIL（按冻结判据）／**边界噪声，不消耗预算**（主会话裁定） |
| P0.5c | MANUAL／**主会话决定推迟至下一轮** |
| EVID | PASS（qa-batch 重跑 finalize 后转绿） |
| 其余 9 项 | PASS |
| **合计** | **10 / 12 PASS，MANUAL 1，exit 1** |
| ml-porting 预算 | **未消耗**（已用 1 次、剩 2 次） |
| `out/BLOCKED_G2B-P0.md` | **未写**（未达第 3 次消耗性 FAIL） |

**下一轮为最终判决**：imaging 报完成 → qa-batch 重测报完成 → **主会话宣布冻结** → 本门禁开跑完整 r3（含 P0.5c）。
**主会话说「冻结」之前不开跑。**

## 补记 5：给我自己的流程纪律（主会话要求，本轮违反过）

**先写文件，后发报告。报告里点名的路径，必须在发报告那一刻存在于盘上。**

本轮违反：我发报告时，`out/GATE_P0_r3.md` 在 HEAD 与 staged 改名下读作两种状态，主会话核到两个互斥的世界。
归档件的**正文与文件名互斥是作废处置的固有形态**（原样另存、不删不改），但**报告里必须把它讲清楚**，不能让人自己去猜 ——
**一份需要读者自行推断「它到底有效没效」的报告，和一份自相矛盾的报告，读起来是一样的。**

---

## 补记 6：轮次命名与归属口径（主会话定，防 r1 那个坑复现）

**下一轮叫 `r4`。不另存改名，也不覆盖。**

- 写 `out/GATE_P0_r4.md` / `out/gate_P0_r4.json` / `out/GATE_P0_r4.caveats.json`。
- **本轮这份 10/12 留在 `out/GATE_P0_r3.*` 原地不动**（撤回我先前"先另存为 `_PARTIAL_noP05c` 再覆盖"的提议）。
- 理由（主会话）：**「另存再覆盖」会让「r3 到底是哪一轮」变模糊** —— 而文件名歧义今天已经付过一次代价（`out/GATE_P0_r3_VOID2_truthRewrittenMidWindow.md` 正文写着「本轮有效」，核的时候读到两个互斥的世界）。**轮次号本来就该往前推，用编号区分比用改名区分干净。**

**档位（定死，别让 r1 那个坑再出现）**

| 轮 | 性质 | 消耗 ml-porting 预算 |
|---|---|---|
| r1 | 重写轮 | 否（作废） |
| r2 | FAIL（P0.3b 2 条） | **是 —— 第 1 次** |
| r3 | 本轮 10/12（P0.3a 裁定为边界噪声） | **否**（主会话裁定） |
| **r4** | **下一轮，含 P0.5c，最终判决** | 仅当 FAIL **且失败项归 ml-porting** 才计 |

**账按「消耗」算，不按名额的名字算。** 门禁那 3 个名额的名字是 r2/r3/r4，但目前**已消耗 1 次（r2）**，r3 未消耗 ——
**即使 r4 也用掉一个名额，ml-porting 账上仍有余量。**
⇒ **禁止把「最后一轮」读成「预算用尽」。**

**归属口径（写进报告，不许一律记在 ml-porting 头上）**：
r4 若 FAIL，**先看失败项归谁** —— **死区与裁剪回退是 `imaging` 的代码，不是 ml-porting 的**
（matting 本轮未动，ml-porting 只领了一件只读诊断）。

**冻结**：imaging（死区四档全库 + 裁剪三档实渲）与 qa-batch **都报完成后**，主会话才宣布冻结。**冻结前不开跑。**
冻结消息会附**当时**的 `out/P0_truth.json` mtime 与 sha256 前缀；
`09:22:10` / `d9948802cb08e98a` 是**旧值，重测后会变，不得引用**。
