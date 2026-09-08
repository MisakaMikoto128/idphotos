---
name: capture-shots
description: 统一的界面截图流程。ui-woodcraft、qa-batch、visual-critic、store-assets 都用这个，保证截图场景、分辨率、命名一致，否则视觉评审无法横向对比。
---

# 截图流程（唯一标准）

截图不一致 = visual-critic 无法对比 = 视觉门禁失效。所有人必须用这套流程。

## 场景清单（`docs/RUBRIC.md` 定义，不得增删）

| 文件名 | 场景 |
|---|---|
| `out/shots/S1_empty.png` | 空态，未选照片 |
| `out/shots/S2_loaded.png` | 已加载照片，裁剪框默认位置 |
| `out/shots/S3_dragging.png` | 按住右下角控制点拖拽中 |
| `out/shots/S4_generating.png` | 候选区生成中 |
| `out/shots/S5_ready.png` | 6 个候选就绪，选中蓝底 |
| `out/shots/S6_saved.png` | 保存成功反馈态 |
| `out/shots/S2_small.png` | S2 在小屏（1080×1920 以下）的样子 |
| `out/shots/S5_small.png` | S5 在小屏的样子 |

固定输入照片：`test/golden/src/` 按文件名排序的**第一张**。换图会让轮次之间无法对比。

## 实现方式

`integration_test/shots_test.dart`，用 `IntegrationTestWidgetsFlutterBinding`：

```dart
final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
await binding.convertFlutterSurfaceToImage();   // 关键，否则截出来是黑的
await tester.pumpAndSettle();
await binding.takeScreenshot('S1_empty');
```

`takeScreenshot` 的落盘由 `test_driver/` 里的 driver 负责写到 `out/shots/`。

## 硬性要求

1. **每次截图前 `pumpAndSettle()`**，否则会截到动画中间帧，导致轮次间无谓差异。
2. **S3/S4 是瞬时状态**，用 `tester.startGesture` 保持按压 / 用 mock 卡住生成过程再截，不要靠时序碰运气。
3. **分辨率固定，用这两个 AVD，不要每轮换：**

   | 用途 | AVD | 分辨率 |
   |---|---|---|
   | 主截图 S1–S6 | `Pixel_3a_API_34_extension_level_7_x86_64`（已存在，RAM 须调至 4096） | 1080×2220 |
   | 小屏 S2/S5 | `MuZhao_Small`（env-setup 新建，API 34 x86_64） | 720×1280 |

   Play Store 宣传图要 1080×1920，由 store-assets 从 1080×2220 裁切合成，不需要第三个 AVD。
4. 截完立刻校验：文件存在、非 0 字节、不是纯黑（采样中心 100 个像素，全为 `#000000` 即失败）。
   **纯黑截图是最常见的失败模式，漏检会让 visual-critic 对着黑图打分。**
5. 每轮截图先清空 `out/shots/`，避免上一轮残留被当成本轮结果。

## 兜底

`integration_test` 截图失败时，降级用 `adb exec-out screencap -p > out/shots/Sx.png`
（注意必须 `exec-out`，`shell` 会因 CRLF 转换损坏 PNG）。
降级要在报告里写明，因为 adb 截图包含系统状态栏，与 integration_test 的结果不完全可比。
