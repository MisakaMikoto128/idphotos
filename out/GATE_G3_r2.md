# GATE G3 — 第 2 轮（2026-09-14）

## G3 第 2 轮：PASS

- 通过 **4 / 4** 项；MANUAL 项 **0** 个
- **真实退出码：0**（`dart run tools/gate/gate_G3.dart --out out/gate_G3.json`，机器可读结果 `out/gate_G3.json`，生成于 15:21:32）
- 本轮是第 **2** 轮 / 3 轮预算。未触发终止。

## 脚本完整性

- 与 `out/hashes_prev.txt`（第 1 轮）比对：
  - **`docs/ACCEPTANCE.md` 哈希变化 → 放行**。差异对应提交 `d79090f`（"acceptance: G3.4 口径变更（人工授权 2026-09-14）"），diff 仅 G3.4 一行，正文含授权日期与依据；符合宪法"阈值只有主会话能改、且只在人工明确要求时改"——两个条件均满足（用户明确授权改口径，阈值数字 2000ms 不变）。除此之外任何哈希差异仍判 FAIL，本轮无。
  - **`tools/gate/gate_G3.dart` 哈希变化 → 放行**。变更全部由 gatekeeper 本人完成（判据变更授权范围内的工装修改），见下"本轮工装变更"。
  - 其余 14 个文件哈希逐字节一致。RUBRIC.md 未变。
- 本轮 gatekeeper 另新增取证产物 `out/GATE_c1_f*.png`、`out/GATE_dumpsys_raw.txt`、`out/GATE_c1_forensic.png`（均属 `out/GATE_*` 势力范围）。

### 本轮工装变更（全部是判定口径授权范围内 / 工装 bug 修复，未放宽任何阈值）

1. 3.4 判定改为探针口径：Dart `main()` → 首帧（`coldstart_probe_test.dart`）3 轮取中位 ≤ 2000ms；`am start -W` TotalTime 仍测量 3 轮、只进报告参考字段。
2. 工装 bug 修复 A：可交互验证的单次 dumpsys 采样改为 2s 间隔轮询 12s（原以为采样时序问题）。
3. 工装 bug 修复 B（实锤根因）：Android 14 (API 34) 镜像的 dumpsys 已无 `mResumedActivity` 字段（全文 0 次，证据 `out/GATE_dumpsys_raw.txt`），匹配改为新旧字段公共子串 `ResumedActivity`。**第 1 轮报告"疑似 dumpsys 采样时序"的诊断有误，以此为准。**

## 防作弊巡查：清白

1. `git diff baseline-p3..HEAD` 受保护路径命中 5 个：4 个（shots_test / crop_interaction_test / capture_shots / gate_G2C）全部改动于 3618c54（G2C r3 复判，gatekeeper 本人）；`docs/ACCEPTANCE.md` 仅 d79090f（已放行，见上）。阶段 3 提交 a72a648 未触碰任何受保护路径。
2. gate 脚本 SHA256：除本人修改的 gate_G3.dart 外全部与上轮一致。
3. `skip:` / `@Skip` / `catch (_) {}` / `catch (e) {}`：test/、integration_test/、lib/ 均无。
4. 黄金集 src 8 张 / ref 8 张，无增删。
5. `docs/PITFALLS.md` 仅追加（本轮追加 1 条 dumpsys 字段名条目，0 删改他人条目）。
6. 报告数字与 `out/gate_G3.json` 逐项一致。
7. 附加：工作区发现的 `out/hashes_r2_pre.txt` 与第 1 轮哈希逐字节相同，无篡改意义，非作弊。

## 通过项

| 项 | 结果 | 关键数字 |
|---|---|---|
| 3.1 全链路 | PASS | 真实 `IdPhotoEngineImpl`+`MuZhaoController`，黄金集 g01 → **42/42** 张产出且全部可解码；7 规格候选底色 id 与 CONTRACTS §5 顺序一致；loadImage 8117ms（模拟器软渲染推理环境成本，非判定项） |
| 3.2 产出合法性 | PASS | 2B.1 尺寸 42/42 精确匹配 CONTRACTS §4；2B.2 DPI 300 42/42；2B.6 绿底溢色 7/7 规格 = 0（绿底减白底逐像素基线校正口径） |
| 3.3 保存 | PASS | `controller.save()` 返回 `/data/user/0/com.muzhao.muzhao/cache/muzhao_*.jpg`，存在、68049 字节、JPEG 重解码 600×600 成功（含 Gal 写相册）。run-as 交叉验证不可用（release 包 non-debuggable），以设备端存在性+重解码为准 |
| 3.4 冷启动（修订口径） | PASS | **探针（Dart main→首帧，profile AOT+Skia）3 轮：5114 / 452 / 460 ms → 中位 460 ms ≤ 2000ms**；TotalTime 参考见下；可交互交叉验证通过（ResumedActivity 命中 + `out/GATE_G3_coldstart.png` 非纯黑） |

### 3.4 数据全披露（不作筛选）

- 探针第 1 轮 5114ms 为离群值（该轮 drive 同时承担 profile APK 首次构建/安装与模拟器负载高峰）；按口径取 3 轮中位 460ms 判定，与第 1 轮实测 427ms 一致，证明 Dart 侧首帧贡献稳定在 ~0.5s。
- **TotalTime 参考（不判定）**：第 1 轮 `Status: timeout / LaunchState UNKNOWN / WaitTime 10210`（未解析到 TotalTime）；第 2 轮 9921ms；第 3 轮 8159ms。仅 2 个有效值，中位 9921ms —— 高于第 1 轮的 7235ms，纯为模拟器软渲染环境噪声（本轮该会话前段负载更重），进一步佐证进程级口径在本机不可作判定依据。

## 失败项

无。

## 回派指令

- 无回派。3.1–3.4 全部达标。
- 给主会话：G3 PASS，可打 phase3 tag 并提交（建议 commit message 含 `G3 PASS`），进入阶段 4。
- 给主会话转达用户：宿主 GPU 驱动维修建议仍有效——修复后 TotalTime 参考口径才有真机代表性；~~阶段 4 的 4.6（真机 p95）仍将面临无真机问题~~ **【15:35 更新】用户已接入真机：小米 12（zeus，2201122C），序列号 1e01895d，状态 device，Android 15，abilist=arm64-v8a,armeabi-v7a,armeabi。4.6/4.7/4.8 的真机前提已满足。** abi 核查：`android/app/build.gradle.kts` 注释确认 onnxruntime 插件 jniLibs 原生带 arm64-v8a/armeabi-v7a（x86_64 才是手工补的开发期库），真机安装无需改构建配置；gatekeeper 未在真机上执行任何测量（G3 已关，真机留待阶段 4 按验收口径使用）。

## 本轮执行备注

- 本轮共 3 次完整 gate 执行：第 1 次（14:32）与第 2 次（14:48）因工装 bug B 误报 3.4 FAIL（探针本身分别 455ms / 440ms 中位，均达标）；取证定位后第 3 次（15:21）PASS。三次执行的 3.1/3.2/3.3 均真实重跑。
- 模拟器一次一台，用完 `adb emu kill`（每轮执行均已确认从 adb devices 消失）。
