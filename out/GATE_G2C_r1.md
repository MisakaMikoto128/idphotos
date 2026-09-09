## G2C 第 1 轮：PASS
## 通过 10 / 10 项，MANUAL 项 0 个
## 脚本完整性：OK（`gate_G2C.dart` 本轮哈希与上一轮一致，未改动；`docs/ACCEPTANCE.md`/`docs/RUBRIC.md` 未变）
## 防作弊巡查：清白（同 G2A 报告；另确认 ui-woodcraft 未触碰 `test/`、`tools/gate/`、`integration_test/`）

真实退出码：`dart run tools/gate/gate_G2C.dart --out out/gate_G2C.json` → **首次跑 exit 1（截图流水线 0/8），修复 gatekeeper 自己的测试基建 bug 后重跑 exit 0**。

### 截图流水线：官方 `flutter drive` 跑通（非降级）
**本轮过程中发现并修复了一个 gatekeeper 自己的测试基建 bug**（属于我的势力范围 `integration_test/`，非产品代码，按纪律允许我自己修）：
`integration_test/shots_test.dart` 在收尾处用 `binding.reportData = {'rects': allRects}` **整体覆盖**了 `reportData`。但 Flutter `integration_test` 包的 `takeScreenshot()` 内部把每张截图 append 进 `reportData['screenshots']`，整体覆盖会把已经拍好的 8 张全部冲掉——`flutter drive` 侧因为 `response.data['screenshots']` 变成 null 而直接跳过落盘回调，全程不报错，"All tests passed" 照样打印，但 `out/shots/` 空無一物。首次运行因此判 2C.1/2C.2/2C.3/2C.4 全部 FAIL（0/8 张）。改成 `reportData!['rects'] = allRects`（合并写入而非整体替换）后重跑，主 AVD（Pixel_3a_API_34，1080×2220）+ 小屏 AVD（MuZhao_Small，720×1280）两次 `flutter drive` 全部 exit 0，`degraded=false`，8/8 张全部非纯黑落盘。已追加到 `docs/PITFALLS.md`。

### 结果明细
| 项 | 期望 | 实测 |
|---|---|---|
| 2C.1 截图产出 | 8张非纯黑 | 8/8，degraded=false |
| 2C.2 调色板合规 | ≥95% | 98.51%（采样138万像素，步进3） |
| 2C.3 无Material紫 | 0命中 | 0 |
| 2C.4 无纯黑纯白 | ≤2% | 0.000%（全量扫描1248万像素） |
| 2C.5 触摸热区 | widget test success | success |
| 2C.6 宽高比锁定 | widget test success | success |
| 2C.7 边界约束 | widget test success | success |
| 2C.8 字体体积 | ≤400KB | 172,888B |
| 2C.9 无ripple | hasNoSplash且0裸InkWell | 满足 |
| 2C.10 无网络代码 | 0命中 | 0命中 |

ui-woodcraft 自报的 2C.2 数字（空态99.84%/就绪态99.01%，逐场景分别统计）与本轮官方合并统计（98.51%，8张一起采样）统计口径不同但结论一致，均达标，未发现自报造假。ui-woodcraft 此前提交的自查图（`out/shots/dev_S*.png`，adb 兜底、含状态栏）已不作为判定依据，判定完全基于本轮官方流水线产物。

本轮是第 1 轮，PASS。
