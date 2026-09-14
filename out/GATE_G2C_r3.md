## G2C 第 3 轮（最后一轮预算）：PASS
## 通过 10 / 10 项，MANUAL 项 0 个
## 脚本完整性：OK（`tools/gate/*.dart` 中本轮仅 gatekeeper 自己改了 `capture_shots.dart`——
为修复截图流水线在 host GPU 驱动损坏下的启动方式加了 `-gpu guest`/`-no-window`/`-feature -Vulkan`
detached 启动与 `--no-enable-impeller`，并加了"主 AVD 跑完先关再起小屏 AVD"的节流逻辑；
其余脚本与 `out/hashes_prev.txt` 一致。`docs/ACCEPTANCE.md`/`docs/RUBRIC.md` 未变。
哈希已滚动至 `out/hashes_prev.txt`）
## 防作弊巡查：清白
- `git diff baseline-p3..HEAD -- test/ tools/gate/ integration_test/ test_driver/ docs/ACCEPTANCE.md docs/RUBRIC.md` 为空；
  未提交改动中，`integration_test/shots_test.dart`（photo_display 接线）、
  `test/gate/crop_interaction_test.dart`（2C.7 纯函数回归用例）、`tools/gate/gate_G2C.dart`
  （photo_display 排除 + 同前缀多用例聚合修复）三个受保护文件的 diff 与本裁判 r2 报告
  记录的自身改动逐行吻合，无他人越界痕迹。
- 实现 agent 本轮改动均在各自势力范围：ml-porting(`lib/core/matting/`)、imaging(`lib/core/imaging/`)、
  ui-woodcraft(`lib/ui/`、`assets/fonts/`、`native/bench/`)；`docs/PITFALLS.md` 全部为追加。
- `skip:`/`@Skip`/`catch (_) {}`/`catch (e) {}` 命中 0；黄金集 src 8 + ref 8 未减少。
- 报告数字与 `out/gate_G2C.json` / `out/gate_G2A.json` 一致。

真实退出码：`dart run tools/gate/gate_G2C.dart --out out/gate_G2C.json` → **exit 0**（2026-09-14T08:51）。
截图为官方 `flutter drive` 真跑（S1–S6 主 AVD + S2/S5 小屏 AVD，degraded=false，非 adb 兜底）。

### 结果明细（对比 r1 / r2）
| 项 | 期望 | r3 实测 | 备注 |
|---|---|---|---|
| 2C.1 截图产出 | 8张非纯黑 | **8/8，degraded=false** | r2 仅 1/8（host 资源），本轮修复后官方跑通 |
| 2C.2 调色板合规 | ≥95% | **99.86%**（采样 1,164,465 px） | r1 为 98.51%——`photo_display` 排除生效后，被压暗照片像素不再污染色卡比对，数字如实上升 |
| 2C.3 无Material紫 | 0 | 0 | PASS |
| 2C.4 无纯黑纯白 | ≤2% | **0.000%**（全量扫描 10,477,475 px） | 与 r1 持平；扫描像素从 1248 万降到 1048 万，减少的 200 万 px ≈ photo_display − crop_box 的环带面积，证明排除真实生效 |
| 2C.5 触摸热区 | success | success | host 端 widget test |
| 2C.6 宽高比锁定 | success | success | 同上 |
| **2C.7 边界约束** | 全部用例 success | **两条均 success**（手势集成 + 纯函数回归） | **r2 唯一 FAIL 项确认修复**：`CropMath.resize` 角点分支已补 `translateIntoBounds` 钳制（lib/ui/util/crop_geometry.dart:201），本裁判 r2 构造的必现越界用例（锚点距边 100px、minWidth 300px）通过 |
| 2C.8 字体体积 | ≤400KB | 302,240B（Regular 151,052 + Bold 151,040 + .gitkeep 148） | 新字符集重做后仍远低于阈值 |
| 2C.9 无ripple | 满足 | hasNoSplash=true，裸InkWell=0 | PASS |
| 2C.10 无网络代码 | 0命中 | 0命中 | PASS |

### `photo_display` 接缝核实
`_rects.json` 中 7/8 场景记录了 `photo_display`（S1_empty 空态无照片，无此 Key 属正确），
实测矩形 (319,327)-(761,906) 严格大于 `crop_box` (346,338)-(734,882)，证明排除的是
"裁剪框外、照片内"的被压暗区域，符合 CONTRACTS §7.2/§7.3 语义。

### 本轮环境事故（如实记录，未影响判定有效性）
host GPU 驱动栈已彻底损坏（GL/Vulkan 初始化全失败；回溯 emulator crash DB 的 minidump
证实 r2 的三次 AVD 崩溃真因是 GPU 驱动崩溃而非内存不足）。此外发现 Windows 上 Flutter
**增量 assembleDebug 会产出损坏 APK**（`Invalid kernel binary`，全量构建必好），
以及 Impeller GLES 在软件渲染下 takeScreenshot 会把 qemu 宿主进程带走。
三条均已解决并固化进截图流水线（`-gpu guest` + `-feature -Vulkan` + `--no-window` +
detached 启动 + `--no-enable-impeller` + 每次全量构建），详见 docs/PITFALLS.md 追加条目。
注：渲染路径换成 Skia 软件渲染仅影响测试环境，真机不受影响；2C.2/2C.3/2C.4 的判定
对象是像素而非渲染器，阈值未动。

### 结论
**G2C 第 3 轮：PASS（10/10，无 MANUAL，无失败项，无需回派）。** 未触及 BLOCKED。

### 遗留给主会话的事项
- REVIEW_G2 #1/#4/#5/#6（EXIF orientation、save try/finally、选图错误处理、字体子集重做）
  本轮已随修复落盘并通过上述检查，但属实现类 agent 自改自验范围，G2C 判定不为其背书，
  G3/G4 端到端验收时自然会覆盖。
