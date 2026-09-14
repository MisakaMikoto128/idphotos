## G2A 第 2 轮（REVIEW 修复后重跑）：PASS
## 通过 8 / 8 项，MANUAL 项 0 个
## 脚本完整性：OK（`tools/gate/*.dart` 哈希与 `out/hashes_prev.txt` 完全一致；本轮 gatekeeper 未改 gate_G2A 相关脚本；ACCEPTANCE/RUBRIC 未变）
## 防作弊巡查：清白（详见 G2C 第 3 轮报告，同一次巡查覆盖）

真实退出码：`dart run tools/gate/gate_G2A.dart --out out/gate_G2A.json` → **exit 0**（2026-09-14T07:48 设备端实测，emulator-5554）。

### 本轮性质
ml-porting 为修 out/REVIEW_G2.md #8 改了 `lib/core/matting/ort_runtime.dart`（OrtSessionOptions
在 finally 中释放 + 成功路径不再泄漏；OrtEnv 双重初始化守卫）。修复后的 `out/gate_G2A.json`
不存在（旧 JSON 比修复早 5 小时，不能充当证据），故按流程全量重跑，非抽查。
第 1 轮结论（out/GATE_G2A_r1.md）仍有效，本报告只写变化项。

### 结果明细（对比 r1）
| 项 | 期望 | r2 实测 | r1 实测 | 变化 |
|---|---|---|---|---|
| 2A.1 抠图模型 | ≤10MB | 7,537,642B | 同 | 无变化 |
| 2A.2 人脸模型 | ≤2MB | 232,589B | 同 | 无变化 |
| 2A.3 IoU 每张≥0.95 | 全达标 | 全达标（无不达标项） | 同 | 无回归 |
| 2A.4 MAE 均值 | ≤0.04 | 0.0017 | 0.0017 | 无回归 |
| 2A.5 边缘带每张≤0.12 | 全达标 | 全达标 | 同 | 无回归 |
| 2A.6 p95 耗时 | ≤1500ms | 1044.0ms（样本24） | 1010.0ms | +34ms，波动范围内，远低于阈值 |
| 2A.7 全量鲁棒性 | 0崩溃 | 80/80 全跑完，0 push 失败，非人像违规 0 | 同 | 无回归 |
| 2A.8 人脸检测 | 8/8 | 8/8，无违规 | 同 | 无回归 |

### 环境备注（非代码问题，如实记录）
本轮 host GPU 驱动栈 GL/Vulkan 初始化全部失败（GLES context 创建不了、
vkGetDeviceQueue 报 Invalid device，见 out/tmp/emu_verbose.log），模拟器只能用
`-no-window -gpu swiftshader_indirect -feature -Vulkan`（软件渲染 + 禁用 Vulkan 宿主仿真）
启动。推理在 CPU 上跑，与 r1 同路径，2A.6 的 34ms 波动与渲染路径无关。
已记入 docs/PITFALLS.md。

无失败项，无需回派。G2A 维持 PASS。
