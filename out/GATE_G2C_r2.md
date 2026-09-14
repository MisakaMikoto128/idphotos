## G2C 第 2 轮：FAIL
## 通过 7 / 10 项，MANUAL 项 0 个
## 脚本完整性：OK（本轮唯一改动是 `tools/gate/gate_G2C.dart` 本身，为响应 REVIEW_G2 #7/#2 修复；`docs/ACCEPTANCE.md`/`docs/RUBRIC.md` 未变，哈希已滚动）
## 防作弊巡查：清白（`git diff baseline-p3..HEAD -- test/ tools/gate/ integration_test/ docs/ACCEPTANCE.md docs/RUBRIC.md` 除 gatekeeper 自己本轮改动外为空；imaging/ml-porting 并行改的是 `lib/core/imaging/`、`lib/core/matting/`，在其势力范围内；`docs/PITFALLS.md` 的改动是追加，无删改他人条目；`skip:`/`@Skip`/裸 catch 全 0 命中；黄金集 8/8 未减少）

真实退出码：`dart run tools/gate/gate_G2C.dart --out out/gate_G2C.json` → **exit 1（第 3 次独立重跑，结果一致）**。

### 本轮起因（REVIEW_G2 #7 + #2，both 由主会话回派）
1. **#7**：`_loadExcludeRects` 只排除 `crop_box`/`candidate_*`，没排除区域 A 的照片
   `display` 矩形（比裁剪框大，框外照片只是被 60% alpha 压暗，不是排除）。
2. **#2**：`CropMath.resize` 角点分支（tl/tr/bl/br）只把宽度 clamp 到 `[lo, hi]`，未像
   边控制点分支那样在结尾调用 `translateIntoBounds`；当最小宽度 `lo` 超过锚点朝目标
   方向的可用空间时，`hi` 被强制拉到等于 `lo`，clamp 后的矩形可能落在 `bounds` 之外。
   原 2C.7 用例只把 crop_box 边界对着**区域 A**（含大量装饰留白）校验，量级上抓不到
   这个越界。

### 处理方式与选择的方案
- **#7 选了 (b)，没走 (a)**：`docs/CONTRACTS.md` §7.2 白纸黑字写着"gatekeeper 只准用
  列出的稳定 Key"，照片 display 矩形目前没有对应 Key（挂在 `Image.memory` 外层
  `Positioned.fromRect` 上，是 ui-woodcraft 内部实现）。用 `find.byType(CropOverlay)` /
  `find.byType(Image)` 之类的类型查找技术上能算出这个矩形，但正是契约明令禁止的
  "挖内部结构"，会让门禁反过来耦合 ui-woodcraft 的实现细节——契约本身就是为了防这个。
  **没有自己去改 `lib/ui/`**。已在下面"给主会话的请求"里正式提出加 `Key('photo_display')`。
  本轮把 gate 侧管线**准备好**：`integration_test/shots_test.dart` 的
  `kStableKeysToRecord` 加了 `'photo_display'`（Key 不存在时 `_rectOf` 静默跳过，不算
  错误，行为等价于现状——不会让本已 PASS 过的东西假摔），`gate_G2C.dart` 的
  `_loadExcludeRects` 加了对这个 key 的识别。Key 落地后本文件不需要再改。
  **结果**：这个 Key 现在还不存在，所以本轮 2C.2/2C.4 的排除范围**实际上没有变化**，
  数字理论上应与 r1 相同（98.51% / 0.000%）——但本轮未能取得真实截图跑出这两个数字
  （见下方"本轮意外情况"），无法给出实测确认，如实标注为"未复核"而不是照抄旧数字。
- **#2 加强了 2C.7**：保留原有手势集成用例（验证真实交互路径），新增一条针对
  `CropMath.resize` 本身的**纯函数回归用例**（`test/gate/crop_interaction_test.dart`），
  直接构造"锚点离边界 100px、minWidth 要求 300px"的场景，不依赖手势/像素误差，
  100% 确定性复现越界。同时修了 `gate_G2C.dart` 里 `_widgetTestChecks` 的一个
  聚合 bug：原来同一 id 前缀（如 "2C.7"）只取**第一个**匹配用例的结果，加了第二条
  用例后如果不修，后面失败的用例会被静默吞掉、gate 照样报 2C.7 PASS——已改成同前缀下
  **全部**用例都得 success 才算过。

### 结果明细
| 项 | 期望 | 实测 | 备注 |
|---|---|---|---|
| 2C.1 截图产出 | 8张非纯黑 | 1/8（`S1_fallback_adb.png`，degraded=true） | 见下方"本轮意外情况"，非代码缺陷 |
| 2C.2 调色板合规 | ≥95% | 无法判定（截图未凑齐） | 同上 |
| 2C.3 无Material紫 | 0命中 | 无法判定（截图未凑齐） | 同上 |
| 2C.4 无纯黑纯白 | ≤2% | 无法判定（截图未凑齐） | 同上 |
| 2C.5 触摸热区 | success | success | 不依赖模拟器，host 端跑，稳定 |
| 2C.6 宽高比锁定 | success | success | 同上 |
| **2C.7 边界约束** | **两条用例均 success** | **手势用例 success；纯函数回归用例 failure** | **真实缺陷，责任 ui-woodcraft** |
| 2C.8 字体体积 | ≤400KB | 172,888B | PASS |
| 2C.9 无ripple | 满足 | 满足 | PASS |
| 2C.10 无网络代码 | 0命中 | 0命中 | PASS |

### 本轮意外情况：主 AVD 反复崩溃（host 资源问题，非代码缺陷）
连续 3 次独立跑 `runFullShotsPipeline()`，主 AVD（`Pixel_3a_API_34...`）每次都在
`flutter drive` 过程中整个退出（`adb.exe: device 'emulator-5554' not found`），触发
adb 兜底（只拿 1 张全屏截图，凑不齐 8 张，2C.1-2C.4 被迫判 FAIL）。事后确认：
- 每次崩溃后 `adb devices -l` 都发现主 AVD 的 qemu 进程真的消失了（不是卡住）；
- `systeminfo` 显示当时可用物理内存持续走低：3322MB → 3049MB → 2880MB（总 28GB）；
- 本轮 `capture_shots.dart` / `tools/gate/device_harness_common.dart` **未做任何改动**，
  与本轮修改的代码无关；重启 adb server、重新冷启动主 AVD、清理 gatekeeper 自己遗留的
  `flutter_tester.exe`/`dart.exe` 进程后仍复现同样结果。
详情记入 `docs/PITFALLS.md`。判断是 host 内存被其他进程挤占导致 AEHD 加速的模拟器不稳，
不是"为了避免 FAIL 而找借口"——2C.7 该 FAIL 的地方已经如实 FAIL 了，这里只是如实说明
2C.1-2C.4 本轮**没有**被复核，不是"复核后仍然 98.51%"。

### 结论
**G2C 第 2 轮：FAIL。** 不是环境问题导致的 FAIL——即使抛开截图管线的意外情况，
**2C.7 单独就已经是真实、可复现的 FAIL**（两次独立跑 `flutter test`，结果一致），
这是本轮修正判据后暴露出的真实缺陷，不是之前的 PASS 变成了假的"变差"，而是
**之前 2C.7 的判据不够严，PASS 本身就没有真正验证到这类越界**——如实回派，
不因为"上一轮已经 PASS 过"而放水。

### 回派指令
- **ui-woodcraft（REVIEW_G2 #2，本轮定性为阻塞 G2C 的缺陷）**：
  `lib/ui/util/crop_geometry.dart` 的 `CropMath.resize` 角点分支（topLeft/topRight/
  bottomLeft/bottomRight）缺少边界钳制。复现条件：`current`/`pointer` 使得
  `lo`（`min(minWidth, maxW)`）超过锚点（拖拽点对角的固定角）朝目标方向的可用空间
  （`availX`/`availY`），此时 `hi = max(lo, min(availX, availY*aspect))` 被强制拉到
  `lo`，`w.clamp(lo, hi)` 恒为 `lo`，但 `left = anchor.dx - w`（或对应边）完全可能
  探出 `bounds`。四个边控制点分支结尾都调用了 `translateIntoBounds(r, bounds)`，
  角点分支没有——建议同样收尾。具体复现用例见
  `test/gate/crop_interaction_test.dart` 新增的 "2C.7 边界约束(纯函数回归)"。
- **无需回派 imaging/ml-porting**：本轮未涉及其势力范围，未发现新问题。

### 给主会话的请求
在 `docs/CONTRACTS.md` §7.2 追加一个稳定 Key：`Key('photo_display')`，挂在
`lib/ui/widgets/crop_overlay.dart` 里 `Positioned.fromRect(rect: display, child:
Image.memory(...))` 的那个 `Positioned`（或其直接子节点）上，语义是"照片在区域 A
里实际显示的矩形（BoxFit.contain 结果），区别于裁剪框 `crop_box`"。
用途：`gate_G2C.dart` 的 2C.2/2C.4 需要用它把"裁剪框外、照片内"的被压暗像素也排除，
否则换成饱和度高的真实照片后这两项会被拖累（详见 REVIEW_G2 #7）。gate 侧管线
（`integration_test/shots_test.dart` 的 `kStableKeysToRecord`、`gate_G2C.dart` 的
`_loadExcludeRects`）本轮已经就位，Key 落地后不需要再改任何 gatekeeper 文件。
