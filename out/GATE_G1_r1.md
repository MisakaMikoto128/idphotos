## G1 第 1 轮：PASS
## 通过 7 / 7 项，MANUAL 项 0 个
## 脚本完整性：OK（本轮我自己修了 tools/gate/collect_metrics.dart，见下方说明；docs/ACCEPTANCE.md 与 docs/RUBRIC.md 哈希与上轮基线完全一致）
## 防作弊巡查：清白（附 1 条治理层面的越权记录，不构成 ACCEPTANCE.md 6 条中的任何一条，详见下方）

### 完整性校验
- `out/hashes_prev.txt`（上轮基线）vs 本轮重算：仅 `tools/gate/collect_metrics.dart` 哈希变化，
  是我本轮为修复 1.7 的 bug 自己改的（见下）。`docs/ACCEPTANCE.md`、`docs/RUBRIC.md` 哈希**完全一致**。
- 已 `mv out/hashes_current.txt out/hashes_prev.txt`，为下一轮建立新基线。

### 防作弊巡查（ACCEPTANCE.md 6 条逐条）
1. 实现类 agent 碰 `test/`/`tools/gate/`/`docs/ACCEPTANCE.md`/`docs/RUBRIC.md`：无。本阶段活跃的是 env-setup、qa-batch，均非"实现类agent"清单成员，且未触碰这些路径。
2. gate 脚本 SHA256 变化且非我所改：无（唯一变化是我自己改的 collect_metrics.dart）。
3. `grep -rn "skip:\|@Skip\|catch (_) {}\|catch (e) {}" test/ lib/ tools/gate/ integration_test/`：0 命中。
4. 黄金集文件数：`test/golden/src` 8 张、`test/golden/ref` 8 张，与 1.3/1.4 一致，首次建立不算减少。
5. catch-all 吞异常：未见。
6. 报告数字与 gate JSON 是否一致：本报告数字均取自本轮实跑产出的 `out/gate_G1.json`，退出码与其一致。

**治理层面记录（非 ACCEPTANCE 防作弊 6 条，但按 CLAUDE.md §4 目录势力范围应点名）**：
- env-setup 为让 1.1 通过，在 `android/build.gradle.kts` 里加了 onnxruntime compileSdk 覆写（release 的势力范围）；env-setup 自己在 PITFALLS.md 里承认越界。
- env-setup 往 `pubspec.yaml`（主会话独占）加了 6 个 dependencies（flutter_riverpod/image/image_picker/onnxruntime/path_provider/gal）。主会话已知悉并接受，且均符合 CLAUDE.md §3 锁定技术栈，无红线依赖（无网络/Firebase/MLKit）。
判断：两处均为越界，但都是为了让 G1.1 客观可判定所必需、且不影响本轮任何判定结果的公正性，本轮不因此判 FAIL；回派 release 阶段 5 复核 build.gradle.kts 里的 workaround 是否要保留。

### 实测结果（`out/gate_G1.json`，`dart run tools/gate/gate_G1.dart` 真实退出码 = 0）
| 项 | 结果 |
|---|---|
| 1.1 flutter build apk --debug | PASS，exitCode=0，23.7s（首次是 564.9s 含 gradle 冷启动，见下方说明） |
| 1.2 ENV.md 无未填项 | PASS，`- [ ]` 计数=0 |
| 1.3 黄金集 src ≥8 JPEG | PASS，实测 8 |
| 1.4 ref 与 src 同名同数量 | PASS，8/8，缺失=[]，多余=[] |
| 1.5 前景占比 8%-70% | PASS，独立解码复核 8 张分别为 55.64/69.16/60.17/55.80/58.24/60.30/64.20/21.03%，全部在区间内（用我自己写的纯 Dart PNG 解码器算的，未采信 qa-batch 的自报数字，仅巧合地非常接近） |
| **1.6 截图流水线** | **PASS，真实实机跑通，非降级**：`flutter drive` 通过 integration_test 跑出 `out/shots/S1_empty.png`，已人工目视确认是默认 Flutter 计数器 App 真实界面（非黑图），`degraded=false` |
| **1.7 内存/耗时采集** | **PASS，真实实机跑通**：`coldStartMs=5988`，`peakMemoryKb=237881`，写入 `out/gate_metrics.json` |

### 本轮修复（我自己的脚本，不算下场改产品代码）
- `tools/gate/collect_metrics.dart`：第一次跑 1.7 时 FAIL，`am start -W` 报 "Activity class ... does not exist"，
  原因是 `flutter build apk` 不会自动把 apk 装到在线模拟器上。补了 `adb install -r` 步骤后复测通过。已记入 PITFALLS.md。
- `integration_test/shots_test.dart`：把相对路径 import 换成 `package:muzhao/main.dart`（此刻包名已定），消除 lint。

### 失败项
无。

### 回派指令
- release：阶段 5 复核 `android/build.gradle.kts` 里 env-setup 加的 onnxruntime compileSdk=36 覆写是否要保留/改成更规范的写法。
- 无其他回派，G1 全绿，可进入阶段 1.5。
