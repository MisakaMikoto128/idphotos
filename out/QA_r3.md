# QA r3 —— 修复后同批重测（qa-batch）

**本轮边界**：`test/batch/**` 未改一行（冻结轮规则）。开跑前 `git status --porcelain -- lib test tools docs` 为空；
收尾时唯一脏文件是 `docs/PITFALLS.md`（宪法 §4 豁免，且非本次改动）。
被测集内容指纹全批一致：**`cd417a4d254ec1c2`**（103 文件：`lib` 67 + `test/batch` 36）。

---

## 1. 链条与读数（10 步，日志在 `out/r3_logs/`）

| # | 步骤 | 调用 | 结果 |
|---|---|---|---|
| 1 | 样本解析 | `dart run test/batch/p0_resolve_check.dart` | PASS，exit 0（**不是** `flutter test`，见 §6） |
| 2 | 成片台 | `flutter test test/batch/p0_compose_test.dart` | exit 0，`All tests passed`，测试时钟 2:13 |
| 2b | 来源绑定 | `python test/batch/p0_provenance_check.py after-compose` | 3 份产物 + 绑定复核全过 |
| 3 | alpha 落盘 | `flutter test test/batch/p0_alpha_dump_test.dart` | exit 0 |
| 4 | 端到端残余 | `python test/batch/p0_output_residual.py` | exit 0，产物 09:03:08 |
| 5 | alpha 全扫 | `flutter test test/batch/p0_alpha_scan_test.dart` | exit 0，测试时钟 0:50，manifest 09:04:31 |
| 6 | 眼带空洞 | `python test/batch/p0_alpha_holes.py` | exit 0，产物 09:06:35 |
| 7 | 自检 | `dart run test/batch/p0_selfcheck_run.dart` | exit 0，通过 9 / 失败 0 |
| 8 | 覆盖率 | `flutter test test/batch/p0_coverage_test.dart` | exit 0，测试时钟 2:19 |
| 8b | 来源绑定 | `… after-coverage` | 5 份产物 + 绑定复核全过 |
| 9 | 几何校验 | `python test/batch/p0_verify_geo.py` | exit 0，minNCC=0.9985 |
| 10 | 真值重建 | `python test/batch/p0_finalize_v1.py --strict` | exit 0，anchors=13 / straight=1 / uprightSynthetic=9 / rotated=78 |
| 10b | 来源绑定 | `… final` | **7 份产物 + 绑定复核全过** |
| 11 | 重建后复检 | `dart run … p0_resolve_check.dart` | PASS（真值被步骤 10 重建过，故重跑） |

## 2. 三份被钉产出

| 产物 | mtime | 记录指纹 | 与当前树不符文件 |
|---|---|---|---|
| `out/P0_compose_summary.json` | 08:56:23 | `cd417a4d254ec1c2` | 0 |
| `out/P0_output_residual.json` | 09:03:08 | `cd417a4d254ec1c2` | 0 |
| `out/P0_alpha_holes.json` | 09:06:35 | `cd417a4d254ec1c2` | 0 |

三份**同一批、同一次运行**产出，指纹逐条一致，`allCommitted=true`、`uncommittedMeasuredFiles=[]`。
成片存在性 110/110（110 行 / 去重 id 100）。
自检的开跑/收尾指纹一致，且与成片台同一内容：`sameCodeStateAsCompose: true`。

> 提醒：这三份的 `headCommit` 记的是跑那一刻的 HEAD（`f56f417`）。收尾时 HEAD 已被
> gatekeeper 推进到 `fb2f161`。判据走 `blobHashes` 逐条比，所以**不要把 `headCommit`
> 与当前 HEAD 比**，那会读出假不符。

## 3. 修复效果：pre(a9cb… 之前，`0f66aabb3c08105f`) → post(`cd417a4d254ec1c2`)

把 r2 那份产物（`git show HEAD:out/…`，记 `0f66aabb…`）与 r3 逐条对比（110 行）：

**整批 110 行里只有 3 个夹具、5 个 id×spec 行发生了变化；其余 105 行逐字段相同。**
差分全集（含 0.1° 量级，一条不漏）：

```
c06_d+3   cn_big_1inch  rollSource      unavailable -> pupil
c06_d+3   cn_big_1inch  faceRollDeg        0.0000 -> 0.7924   Δ=+0.7924
c06_d-3   cn_big_1inch  straightenDeg      0.0000 -> -5.0383  Δ=-5.0383
c06_d-3   cn_big_1inch  primary_tilt_deg  -4.8247 -> 0.2748   Δ=+5.0995
c06_d-3   cn_big_1inch  rigid_residual    -4.8247 -> -4.7635  Δ=+0.0612
c06_d-3   cn_big_1inch  truthConsistency  -0.0950 -> -0.0330  Δ=+0.0620
c06_d-3   cn_big_1inch  methodSpreadDeg    3.1370 -> 1.1080   Δ=-2.0290
c06_d-3   cn_big_1inch  status      low_confidence -> ok
c06_d-3   cn_big_1inch  rollSource      unavailable -> pupil
c06_d-3   cn_big_1inch  faceRollDeg        0.0000 -> -5.0383  Δ=-5.0383
c08_d-10  cn_1inch      straightenDeg      0.0000 -> -17.8222 Δ=-17.8222
c08_d-10  cn_1inch      rollSource      unavailable -> pupil
c08_d-10  cn_1inch      faceRollDeg        0.0000 -> -17.8222 Δ=-17.8222
c08_d-10  cn_big_1inch  straightenDeg      0.0000 -> -17.8222 Δ=-17.8222
c08_d-10  cn_big_1inch  primary_tilt_deg   3.8518 -> 3.3345   Δ=-0.5172
c08_d-10  cn_big_1inch  rigid_residual     3.8518 -> -14.4877 Δ=-18.3395
c08_d-10  cn_big_1inch  truthConsistency  21.8620 -> 3.5220   Δ=-18.3400
c08_d-10  cn_big_1inch  methodSpreadDeg    2.1530 -> 12.6650  Δ=+10.5120
c08_d-10  cn_big_1inch  rollSource      unavailable -> pupil
c08_d-10  cn_big_1inch  faceRollDeg        0.0000 -> -17.8222 Δ=-17.8222
c08_d-10  visa_us       straightenDeg      0.0000 -> -17.8222 Δ=-17.8222
c08_d-10  visa_us       primary_tilt_deg -14.1459 -> None
c08_d-10  visa_us       rigid_residual   -14.1459 -> None
c08_d-10  visa_us       truthConsistency   3.8640 -> None
c08_d-10  visa_us       methodSpreadDeg   19.4210 -> None
c08_d-10  visa_us       methodCount             2 -> 1
c08_d-10  visa_us       status   reliability_mismatch -> unmeasured
c08_d-10  visa_us       rollSource      unavailable -> pupil
c08_d-10  visa_us       faceRollDeg        0.0000 -> -17.8222 Δ=-17.8222
```

### 3.1 主会话点名要的两个数（门禁规格 `cn_big_1inch`）

| 样本 | 真值 | pre 施加角 | post 施加角 | pre 残余 | post 残余 | post 端到端误差 |
|---|---|---|---|---|---|---|
| `c06_d-3` | −4.730° | **0.0°**（`unavailable`） | **−5.0383°**（`pupil`） | −4.8247 | −4.7635 | **0.034°** |
| `c08_d-10` | −18.010° | **0.0°**（`unavailable`） | **−17.8222°**（`pupil`） | +3.8518 | −14.4877 | **3.522°**（>2°，该行仍被 `reliability_mismatch` 排除） |

`c06_d-3` 的变化是**真的修好了**：pre 时估角器完全不工作（`straightenDeg=0`），成片就歪着 4.8247°——
这正是 r2 里 P0.3a **唯一**的越界项（`primaryOver1p5: ['c06_d-3']`）。post 时估到并施加 −5.038°，成片倾角落到
+0.2748°，`primaryOver1p5` 变为 **`[]`**，`primaryAbsMax` 4.825 → **1.377**，`primaryAbsMedian` 0.158 不变。

`c08_d-10` **不能据此判好**：估角器确实从"测不出"变成"测出 −17.82° 并施加"，但残余量具 m1 在被施加了
−17.82° 的成片上仍读 +3.3345°，与几何预期（−18.01° 输入 + 17.82° 回正 ⇒ 成片应约 −0.19°）差 ~3.5°。
**这是量具在此样本上不可信**，不是引擎失败的证据。该行仍应排除；但**"排除"意味着 r3 对 `c08_d-10` 没有读数**，
不是"它好了"。见 §5。

### 3.2 新增的可用性回退

`c08_d-10 @ visa_us`：pre 有一行读数（−14.1459，`methodCount=2`），post **整行变成 `unmeasured`**
（`primary_tilt_deg=None`，`methodCount=1`）。同一夹具在 `cn_1inch` 上仍是 `no_pair`。
⇒ 修复让引擎在该规格上动了，却让**残余量具在这两个非门禁规格上失去读数**。门禁用 `cn_big_1inch`，故不影响判决，但这是一处可复现的测量可用性回退。

### 3.3 未被"修好"的相邻项

`c06_d+3`（真值 +1.27°）：估角器现在给出 `faceRollDeg=0.7924`（pre 为 `unavailable`/0.0），但
**`straightenDeg` 仍是 0.0** —— 0.79° 落在 1.0° 死区内，引擎按设计不动。成片倾角逐位不变（+1.3767°）。
即：**估到了，但没施加**。这是设计行为，不是回归，但它意味着 ≤1° 的倾角在成片上依旧保留。

## 4. `out/P0_alpha_scan/` 的两问（主会话）

1. **会被重新生成吗？会。** `test/batch/p0_alpha_scan_test.dart:78` 写 `out/P0_alpha_scan/<slug>_alpha.png`，
   `:160-161` 以 `writeAsStringSync` **整份覆盖** `manifest.jsonl`。全文无缓存/跳过分支，逐条无条件重跑。
   本次运行：测试时钟 0:50，alpha 文件 09:03:43–09:04:30，manifest 09:04:31，共 87 行。
2. **旧的 `P0_alpha_holes.json` 是不是修复前的数据？是，且早 70 分钟。**
   它写于 07:40:39，读的是 07:39:32–07:40:15 写出的 alpha；而修复 `12dd24f` 提交于 **08:50:09**。
   另：目录里 4 张 03:45–03:46 的图（`_c08_alpha_cmp.png`、`_c08_inputs.png`、`_fixture_alpha_cmp.png`、
   `_sheet_c08_magenta.png`）**不是扫描产出**，是别的手工对照图，所以"扫描跨度 4 小时"是把目录 mtime
   当扫描时长读出来的假象 —— **扫描本身只有 43 秒**。`p0_alpha_holes.py:62,74` 按 manifest 取文件，
   那 4 张陈图不参与测量。

## 5. 修复后的眼带空洞：`answer` 的结论仍不被数据支持

post-fix 数据（同批）：`total=87`、`assessable=21`、`eyeBandHoleCount=4`、占比 0.19。

脚本自己的对照组（`controlComparison`）：

| 组 | 脚本的名字 | n | 有洞 | max eyeBandZeroFrac |
|---|---|---|---|---|
| 组A | `unrotatedRealPhotos` | 14 | 0 | 0.0 |
| 组B | `rotatedFixtures` | 7 | 4 | 0.9677 |

**问题出在组A的名字。** 组A 的 14 条里我能逐条对到真值的 13 条（`anchors` + `straight`）是
**真实照片，但倾角并不为 0**：`c08` **−8.01°**、`p1` −4.40°、`c05` −3.91°、`c04` −3.82°、`c03` −3.72°……
**它们全部 0 洞**。而组B 里真值倾角 **0.0°** 的 `c08_upright` 有 **0.6193** 的洞。

⇒ **"洞由旋转诱导"不成立**：一张真值 −8.01° 的真实照片没有洞，而它的 0° 回正副本有 62% 的洞。
按倾角大小看也不单调、且不对称（`c08_d+3` −5.01°→0.5277，`c08_d-3` −11.01°→**0.0**）。
两组之间真正同时变了**两个**变量——**真实照片 vs 合成派生件**、以及**有无做过旋转重采样**——
而扫描里**既没有"合成但从未旋转"的臂，也没有"真实但被重采样过"的臂**，所以这两个变量在这份数据里分不开。

`out/P0_alpha_holes.json` 的 `answer` 是**写死的字面量**（`test/batch/p0_alpha_holes.py` 里那句 f-string
的结论部分不是现算的，只有旁边的计数是现算的）。它写"否。未旋转的真实照片一张都没有洞……
故这是旋转诱导的抠图失效"。前半句（14 张 0.0）我用交叉表**验证为真**；**后半句"故…"是推论，不被数据支持**。

**结论我只报到这里**：洞只出现在 c08 合成派生族的 4/7 条上；与该族真值倾角不单调、且符号不对称；
成因**未识别**。任何"旋转诱导"的写法都应降级为待验假设。

## 6. 过程事故：gatekeeper r3 与本次授权重测撞在同一窗口

`out/GATE_P0_r3.md` 判 `roundInvalid`，根因（两份产物早于修复）**成立**，我确认：
`P0_output_residual.json` 07:39:05 / `P0_alpha_holes.json` 07:40:39 都记 `0f66aabb3c08105f`，
早于 `12dd24f`(08:50:09)。本轮 §1–§2 就是这条的补救。

**但该报告里的归因是错的**：它写"是 gate 之外的一个进程（推断为刚改完 `iris_roll.dart` 的 ml-porting）
在我判定到一半时把 compose 产物重写了"。实际是我（qa-batch，裁判）在跑主会话授权的 r3 重测：
我的 compose 于 08:54–08:56:23 跑完，`out/r3_logs/02_compose.log` 尾部 `All tests passed!` 与
`P0_compose_items.jsonl`(08:56:22)/`P0_compose_summary.json`(08:56:23) 的 mtime 逐一对应，
整个区间落在报告自述的 08:51:26–08:57:30 窗口内。
⇒ **不是"被判的一方改写判据输入"，是"裁判与门禁同时写读同一个共享产出目录"**。
结构性风险仍在（谁都不该在别人判定时换输入），但它指向的是**缺乏占用约定**，不是实现方越界。
建议：验收窗口内任何 agent 重跑产出脚本前，先在共享位置登记；或给 `out/` 的产物加写入者标记。

另：`out/GATE_P0_r3.md` 自己的两处"当前树指纹"数值不同 —— `:55/:168` 写 `-32be85b2dab13e3e`，
`:558` 的逐文件核对却把 `cd417a4d254ec1c2` 判为 0 处不符。两个值**是同一个 64 位 FNV 值**：
Dart `tools/gate/provenance.dart:385` 用 `h.toRadixString(16)` 打**有符号**十六进制（高位置 1 时带 `-`），
Python 侧打无符号。`0x10000000000000000 − 0xcd417a4d254ec1c2 = 0x32be85b2dab13e3e`。**不是漂移，是显示口径**，
但两处并排出现会被读成"代码变了"。

## 7. 队列（本轮不做，供主会话排期）

1. `p0_output_residual.py` 的 `answer`/`controlComparison` 组名（`unrotatedRealPhotos` 名不副实）。
2. 上一条同源：给扫描加"合成但未旋转"对照臂，否则该问题永远分不开。
3. `out/P0_alpha_scan/manifest.jsonl` 无指纹（87 行只有 `err/outcome/path/zh`）；"钉住了包装没钉住内容"仍在。
4. `out/P0_alpha_scan/` 下 4 张 03:45 手工陈图，与本扫描无关，易被误读为扫描产物。
5. `p0_selfcheck_run.dart` / `p0_resolve_check.dart` 是 CLI 程序却常被用 `flutter test` 跑：
   `main(List<String>)` 与 harness 期望的 `main()` 不兼容，`flutter test` 必报
   `Connection closed before test suite loaded` / `The argument type 'void Function(List<String>)'…`。
   r3 的两处假失败都是这个。**这两个文件的正确调用是 `dart run`**，建议写进文件头或改名。
6. `methodSpreadDeg` 的 m3 标签污染、`qa_spread` 无消费方、`m1_pupil.eyedist` 是种子回显等 r2 已列项，均未变。
