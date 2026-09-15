# GATE G3 — 第 1 轮（2026-09-14）

## G3 第 1 轮：FAIL

- 通过 **3 / 4** 项；MANUAL 项 **0** 个（无项目缺判定脚本）
- **真实退出码：1**（`dart run tools/gate/gate_G3.dart --out out/gate_G3.json`，机器可读结果 `out/gate_G3.json`）
- 本轮是第 **1** 轮 / 3 轮预算。**注意：即使完美实现，第 2 轮在本机原样重跑也必然 FAIL（见 3.4 的环境基线证据），不建议盲目重跑。**

## 脚本完整性

- `sha256sum tools/gate/*.dart docs/ACCEPTANCE.md docs/RUBRIC.md` 与 `out/hashes_prev.txt` 逐条一致（ACCEPTANCE/RUBRIC 哈希未变）。
- 本轮 gatekeeper 自己**新增**：`tools/gate/gate_G3.dart`、`integration_test/e2e_eval_test.dart`、`integration_test/coldstart_probe_test.dart`（属势力范围，正常）。

## 防作弊巡查：清白

1. `git diff baseline-p3..HEAD -- test/ tools/gate/ integration_test/ test_driver/ docs/ACCEPTANCE.md docs/RUBRIC.md`：命中的 4 个文件（shots_test / crop_interaction_test / capture_shots / gate_G2C）全部改动于 **3618c54（G2C r3 复判，gatekeeper 本人）**；**阶段 3 提交 a72a648 未触碰任何受保护路径**。
2. gate 脚本 SHA256 与上轮记录一致（见上）。
3. `skip:` / `@Skip` / 空catch：无。`catch (_) {}` / `catch (e) {}` in lib/：无。
4. 黄金集 8+8，无增删。
5. `docs/PITFALLS.md` 仅追加（diff 无删除行）。
6. 报告数字与 `out/gate_G3.json` 一致（本文所引均出自该文件）。

## 通过项

| 项 | 结果 | 关键数字 |
|---|---|---|
| 3.1 全链路 | PASS | 真实 `IdPhotoEngineImpl`+`MuZhaoController`，黄金集 g01 → **42/42** 张产出且全部可解码；7 规格候选底色 id 与 CONTRACTS §5 顺序一致；loadImage 6561ms（模拟器推理 ~1.5s/次） |
| 3.2 产出合法性 | PASS | 2B.1 尺寸 42/42 精确匹配 CONTRACTS §4；2B.2 DPI 300 42/42；2B.6 绿底溢色 **7/7 规格 = 0**（口径：绿底成片 vs 白底成片逐像素基线校正，见 `gate_G3.dart` 头注释；每规格前景采样 1.2万–14.5万像素） |
| 3.3 保存 | PASS | `controller.save()` 返回 `/data/user/0/com.muzhao.muzhao/cache/muzhao_*.jpg`，存在、68KB、JPEG 重解码 600×600 成功（112ms，含 Gal 写相册）。run-as 交叉验证不可用（release 包 non-debuggable，`run-as: unknown package`），以设备端存在性+重解码为准 |

## 失败项

| 项 | 期望 | 实测 | 责任 |
|---|---|---|---|
| 3.4 冷启动 ≤2000ms | 中位数 ≤ 2000ms 且可交互 | **中位数 7235ms**（7235/7104/7345）→ FAIL | 环境为主（见下），非接线层回归的证据链完整 |

**3.4 口径与证据链（主会话请完整阅读）**：

- 口径：**release(AOT) 构建 + `am start -W` TotalTime**，3 轮 force-stop 后冷启动取中位数。debug 为 JIT，物理上不可能达标（G1 实测 5988ms），不作为口径。
- 本宿主 GPU 驱动栈损坏（PITFALLS 已有记录），**任何以 Impeller GLES 渲染真实 UI 的 App 都会直接杀死 qemu 宿主进程**：release/profile 直启秒死（4 次复现）、debug main.dart 启动后 ~45s 内死（1 次）、2 台 AVD、2 种客户机内存（4096/2560MB）均复现，无 WER、无 minidump、logcat 无任何 guest 侧痕迹。**必须带 `--ez enable-impeller false`（Skia）启动**——这是 flutter 工具链 `drive/run --no-enable-impeller` 注入同一开关的官方途径（flutter_tools `android_device.dart:662-667` 实证）；`flutter build apk` 不接受该 CLI flag（实测 exit 64）。
- **拆分证据**（`integration_test/coldstart_probe_test.dart`，profile(AOT)+Skia）：真实工作台 Dart 侧 main→首帧栅格化仅 **427ms**。即 7.2s 里 **~6.8s 是进程/引擎启动段** —— 与 G1 骨架 App 同口径实测 5988ms 的环境基线一致（当时骨架无任何业务代码）。**结论：本机该口径的环境基线本身就 ~3 倍超标，与阶段 3 接线无关。**
- 可交互性：`out/GATE_G3_coldstart.png`（1080×2220，中心为木色 UI 像素，非纯黑）证明界面真实渲染；第 1 轮 mResumedActivity 探测命中失败疑为 dumpsys 采样时序，不影响时间判定。

## 回派指令

- **不回派 ml-porting / imaging / ui-woodcraft**：3.1–3.3 全绿，3.4 的失败分解证明 App 自身 Dart 侧贡献仅 427ms。
- **给主会话的决策请求**（非 agent 回派）：3.4 在本机是**环境受限项**——环境基线（G1 骨架 5988ms）已超阈值 3 倍。可选路径：
  1. 接一台 Android 真机（arm64、硬件 GPU）在真机上重测 3.4（推荐，数字才对"真机优先上架"有代表性）；
  2. 或由主会话人工裁定本机环境偏差后明确豁免/改阈值（阈值只有你能在人工要求下改，gatekeeper 不动）。
- 若不做上述任一项而原样进入第 2 轮，3.4 将确定性 FAIL 并在第 3 轮触发 BLOCKED 终止。

## 本轮环境事故记录（非门禁判定内容）

本轮共 5 次 gate 执行/试运行，前 2 次因模拟器宿主进程死亡中止（当时 3.4 还在用直启 release 的口径）。定位过程与解法已固化进 `gate_G3.dart` 头注释与 PITFALLS（见追加条目），复现证据：`out/GATE_emu_console.log`、`out/GATE_probe_test.log`、`out/GATE_logcat.txt`。
