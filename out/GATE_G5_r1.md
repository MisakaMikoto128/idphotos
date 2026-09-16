# GATE G5 第 1 轮

## G5 第 1 轮：PASS

## 通过 9 / 9 项（含 2 个子项），MANUAL 项 0 个，退出码 0
（ACCEPTANCE 表内 5.1–5.7 全部机读判定；5.6 的设备端复验由 gatekeeper 独立执行后落盘证据，脚本校验证据自洽性）

## 脚本完整性：OK
- `out/hashes_prev.txt` 与本轮开跑前逐字节一致（diff exit 0），无任何 gate 脚本被外部改动。
- 本轮 gatekeeper 新建 `tools/gate/gate_G5.dart`、`tools/gate/gate_G5B.dart`（G5 首轮，此前不存在），
  并按环境实测修改 `tools/gate/gate_G5.dart`（3 次：补 import / 权限解析修正 / gradlew 调用路径）、
  `tools/gate/g4_release_memcheck.py`（PKG 改环境变量可覆盖，见下）。轮末已重算哈希并滚动 `out/hashes_prev.txt`。

## 防作弊巡查（ACCEPTANCE 6 条）：清白
1. `git diff baseline-p5..HEAD`（=350a8ee phase4 PASS 提交）：无 `test/`、`tools/gate/`、
   `docs/ACCEPTANCE.md`、`docs/RUBRIC.md` 改动。release 只碰 `android/`；store-assets 只碰 `store/`；
   主会话 = `lib/core/controller.dart`(M1) + simplify `c88854d`（仅 `lib/` + PITFALLS 追加，净 -781 行，未碰 test/tools.gate/docs.ACCEPTANCE）；
   ml-porting M3 = `lib/core/matting/image_ops.dart` + `native/bench/` 两个测试（自身势力范围）。
2. gate 脚本 SHA256 未变（上同）。
3. `grep -rn "skip:|@Skip|@Tags(['skip'])" test/ integration_test/`：0 命中；`lib/` 空 catch 扫描：0 命中。
4. `test/golden/src/`=8、`ref/`=8，与上一轮一致，无删减。
5. 空 catch-all 扫描同上，无吞异常。
6. 报告数字与 `out/gate_G5.json` 一致；判定对象为重打后的新产物
   （apk bd725851…、aab b9a7e0df…，构建时间 2026-09-16 04:51 晚于 simplify 提交 04:50:20，已核非 simplify 前旧包）。
- 瑕疵记录（不影响判定）：`out/tmp_fg_test.png` 随 88db960 入库，属 out/ 临时文件误提交，建议主会话清理。

## 逐项判定

| 项 | 期望 | 实测 | 判定 |
|---|---|---|---|
| 5.1 | merged manifest 无 INTERNET | APK aapt xmltree：0 次（权威口径，见 PITFALLS badging 失真条）；AAB 全文件扫描：0 次 | PASS |
| 5.2 | 权限 ⊆ 白名单 | xmltree 实测平台权限 = READ_MEDIA_IMAGES + WRITE_EXTERNAL_STORAGE(maxSdk=32)，无 READ_EXTERNAL_STORAGE（badging 显示的该条为旧中间产物失真，xmltree+源码 `tools:node="remove"` 双证） | PASS（裁决见下） |
| 5.2.adjudication | 留痕 | DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION：1 处 uses-permission + 1 处 `<permission>` 声明（protectionLevel=0x2 signature） | PASS |
| 5.3 | 依赖树无 Google/统计 | `gradlew :app:dependencies` 全配置输出，play-services/firebase/mlkit/crashlytics 0 命中（仅 com.google.guava:listenablefuture、com.google.android:annotations，均为纯注解/工具件，非运行时 SDK） | PASS |
| 5.4 | 产物齐备 | apk 63,232,974B + aab 59,336,593B 均存在 | PASS |
| 5.5 | aab ≤ 60MB | 59,336,593B = 56.58 MiB（按 60,000,000 字节严格口径） | PASS |
| 5.6 | release 可运行 | gatekeeper 独立复验全链路通过（见下） | PASS |
| 5.7 | 无密钥泄漏 | git check-ignore 双验通过（android/.gitignore:12,14）；`git ls-files` 无 key.properties/*.jks/*.keystore；全仓明文口令扫描 0 命中（build.gradle.kts 仅属性引用） | PASS |

## 5.2 裁决：DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION 判不违规（PASS）

**裁决：PASS，不违反 5.2 白名单。** 依据：
1. **非威胁模型内对象**：5.2 白名单的立法本意是 CLAUDE.md §6 的"100% 离线"红线——拦截可触网或可读用户数据的**平台危险权限**。该权限是 androidx.core≥1.9 在 TARGET SDK≥34 下为 `RECEIVER_NOT_EXPORTED` 动态注册接收器自动注入的**应用自身包名下的自定义保护权限**（`com.muzhao.idphoto.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`，protectionLevel=signature=0x2，manifest 实测），全系统仅本 App 能持有，不授予任何数据/资源/网络访问，用户不可见，无数据含义。
2. **字面读法自相矛盾**：若按字面子集判 FAIL，则一切使用 androidx.core 的应用物理上无法满足 5.2——与 ACCEPTANCE 前言"所有 gate 必须是脚本可判（且可达成）"的前提冲突。逐字读会把门槛变成不可达，不是"从严"，是标准的失效。
3. **一致性**：平台权限部分仍按**严格**子集判定（本条同时把 image_picker AAR 想合并进来的 READ_EXTERNAL_STORAGE 用 `tools:node="remove"` 剔除后的结果验证为真）。
留痕：`out/gate_G5.json` 的 5.2 / 5.2.adjudication 两条 + `out/GATE_g5_apk_manifest.txt`。

## 5.6 独立复验（gatekeeper 亲测，不采信 release 自报）

- 判定对象：x86_64 验证版 release（`MUZHAO_EXTRA_ABIS=x86_64` 注入，同一代码基线 c88854d，R8+AOT+资源收缩；正式产物 arm-only 装不上 x86_64 模拟器，验证版不含于正式产物）。
- 环境：Pixel_3a_API_34 AVD，`-no-window -gpu guest -feature -Vulkan -no-snapshot-load`；hostmem 预检通过（free 13.4GB）；全程钉死 `emulator-5556`，**未触碰在线真机 5bc6e093**；用完 `emu kill`。
- 链路：install exit 0 → `am start -W --ez enable-impeller false`（PITFALLS 直启必带）LaunchState=COLD TotalTime=5506ms（符合 G3.4 已记录的 ~6s 环境地板），topResumedActivity 确认 → 系统照片选择器选中真实人像 g01.jpg（push+MEDIA_SCANNER_SCAN_FILE，MSYS 改写已规避）→ **"已完成 6 张"**（白/蓝/红候选目视确认）→ 保存 → MediaStore Row 98（Pictures/木照/，33175B）→ adb pull 回宿主 PIL 解码 **295×413 RGB JPEG**（一寸规格精确匹配）。
- 证据：`out/GATE_G5_e2e_result.json` + `out/GATE_G5_e2e_appui.png` / `_candidates.png` / `_saved.png`。

## 包名变更连带（裁决与执行）

- `tools/gate/g4_release_memcheck.py`（gatekeeper 资产）：其驱动对象是 G4 期构建的 `out/app-release-runner.apk`，该产物构建于改名**之前**、包名实际就是 com.muzhao.muzhao——盲目改成新包名反而会与被驱动产物脱钩。已改为 `MUZHAO_RUNNER_PKG` 环境变量可覆盖 + 注释说明，默认值保持与现产物一致。
- `test/adversarial/adversarial_runner.dart:8` 的旧包名（归 adversarial，裁判不下场不改）：实为**注释**中的示例命令，非可执行逻辑，无判定影响。提请主会话转告 adversarial 在下次动该文件时顺手更新，不构成本轮 FAIL 项。
- G5.6 复验已按新包名 com.muzhao.idphoto 执行（MainActivity 类名仍为 com.muzhao.muzhao.MainActivity，namespace 未变，无需改码）。

## 失败项

（无）

## 回派指令

（无 —— 本 gate 无回派项）
