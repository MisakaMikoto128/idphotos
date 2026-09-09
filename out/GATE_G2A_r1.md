## G2A 第 1 轮：PASS
## 通过 8 / 8 项，MANUAL 项 0 个
## 脚本完整性：OK（`tools/gate/gate_G2A.dart`、`device_harness_common.dart` 与上一轮记录（`baseline-p2`）相比有差异，但差异内容与本轮 gatekeeper 自己在中断前所做的未提交修改完全一致，非他人越界；`docs/ACCEPTANCE.md`/`docs/RUBRIC.md` 哈希与基线一致，未被改动）
## 防作弊巡查：清白
- `git diff --name-only baseline-p2..HEAD` 中 `tools/gate/`、`integration_test/`、`test/gate/`、`docs/PITFALLS.md` 的改动全部可追溯到 gatekeeper 自身（PITFALLS.md 有对应条目佐证），无 ml-porting/imaging/ui-woodcraft 越界痕迹。
- `docs/ACCEPTANCE.md`、`docs/RUBRIC.md` 哈希未变。
- `grep catch(_){}/catch(e){}` 命中 0；`grep skip:/@Skip` 命中 0；`test/golden/src|ref` 仍各 8 个文件，与 G1 一致。
- `docs/PITFALLS.md` 本轮 diff 只有追加（`@@ -63,3 +63,148 @@` 纯新增段落），未删改他人条目。

真实退出码：`dart run tools/gate/gate_G2A.dart --out out/gate_G2A.json` → **exit 0**。评测在设备端（`emulator-5554`，Pixel_3a_API_34 x86_64，RAM 4096）用 `flutter drive` 真跑，非估算。

### 结果明细
| 项 | 期望 | 实测 |
|---|---|---|
| 2A.1 模型体积 | ≤10MB | 7,537,642B PASS |
| 2A.2 人脸模型体积 | ≤2MB | 232,589B PASS |
| 2A.3 IoU | 每张≥0.95 | 全部达标（无不达标项） |
| 2A.4 MAE 均值 | ≤0.04 | 0.0017 PASS |
| 2A.5 边缘带 MAE | 每张≤0.12 | 全部达标 |
| 2A.6 512² p95 耗时 | ≤1500ms | 1010.0ms（样本24）PASS，设备端比 ml-porting 自报的宿主机 465ms 慢，符合预期（模拟器 CPU 推理慢于宿主机原生） |
| 2A.7 全量鲁棒性 | 0崩溃，非人像null/异常 | 数据集80项全部推送成功、全部跑完，0跳过，非人像违规0 |
| 2A.8 人脸检测 | 8/8 且 chinY>headTopY | 8/8 检出，无违规 |

无失败项，无需回派。ml-porting 自报数字（IoU最差0.9673 g08、边缘带最大0.1085 g08）与本轮设备端独立评测结论一致（均在阈值内），未发现自报与实测不符。

本轮是第 1 轮。
