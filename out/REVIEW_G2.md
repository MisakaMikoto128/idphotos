# /code-review high — baseline-p2..HEAD（G2 通过后的补充审查）

主会话产出。按 CLAUDE.md §8：**本文件的发现不覆盖门禁结论**，
G2A/G2B/G2C 的 PASS 仍然成立；这里的问题记入并回派修复，
PASS/FAIL 仍由 gatekeeper 按 ACCEPTANCE.md 判定。

审查范围：`git diff baseline-p2..HEAD` 全量（阶段 2 三路交付 + gate 脚本）。

## 发现汇总

| # | 严重度 | 文件 | 问题 | 责任 agent |
|---|---|---|---|---|
| 1 | **HIGH** | `lib/ui/util/image_size.dart:219` / `lib/ui/areas/area_a_source.dart:223` | UI 与引擎对 EXIF 旋转照片的源坐标空间不一致 | ui-woodcraft |
| 2 | MEDIUM | `lib/ui/util/crop_geometry.dart:193` | 角点缩放可返回越界矩形，预览与成片分叉 | ui-woodcraft |
| 3 | MEDIUM | `lib/core/imaging/compose_engine.dart:300` | 摆正生效时用户框选被静默放大约 23% | imaging |
| 4 | MEDIUM | `lib/ui/areas/area_c_save.dart:58` | `save()` 失败后保存按钮永久禁用 | ui-woodcraft |
| 5 | MEDIUM | `lib/ui/areas/area_a_source.dart:92` | 选图无错误处理，权限拒绝时静默失败 | ui-woodcraft |
| 6 | LOW/MED | `lib/ui/theme/fonts.dart:77` | 28 个 UI 实际使用的字符不在字体子集里 | ui-woodcraft |
| 7 | LOW/MED | `tools/gate/gate_G2C.dart:135` | 2C.2/2C.4 只排除了裁剪框，没排除照片显示区 | gatekeeper |
| 8 | LOW | `lib/core/matting/ort_runtime.dart:108` | 成功路径上 `OrtSessionOptions` 泄漏 | ml-porting |

## 详情

### 1. HIGH — EXIF 坐标空间不一致
`readImageSize()` 只解析 JPEG SOF 头，返回的是**旋转前**尺寸；而引擎的 `decodeToRgb()`
显式调用了 `img.bakeOrientation`，所以 `MattingResult.width/height` 与 `AppState.suggestedCrop`
都在**旋转后**坐标系（Flutter 的 `Image.memory` 渲染的也是旋转后位图）。

具体后果：一张 4000×3000、EXIF orientation=6 的手机照片，引擎在 3000×4000 空间里工作并给出
建议框，`_effectiveCrop` 却拿 `Offset.zero & Size(4000,3000)` 去 `fitIntoBounds`，静默缩放/平移；
之后每次 `setCrop(r)` 都把一个转置空间里的矩形送回 `compose`。**大多数真实相机照片取景都会错。**

**为什么门禁没抓到**：qa-batch 冻结数据集时已诚实申报「全部 80 项 `exif_orientation=1`，
无真实旋转样本」。这正是那个缺口的兑现。

### 2. MEDIUM — 角点缩放越界
四个边分支结尾都调了 `translateIntoBounds(r, bounds)`，角点分支直接
`return Rect.fromLTWH(left, top, w, h)` 未钳制。当 `lo = min(minWidth, maxW)` 超过锚点可用空间时，
`hi = max(lo, …)` 会强制 `w = lo` 而无视 `availX/availY`。
`onChanged` 把这个原始矩形既存下来又转发给 `controller.setCrop`，而预览画的是
`fitIntoBounds` 修正后的版本 —— 成片里会出现用户从未见过的底色填充条。
`test/gate/crop_interaction_test.dart` 只把框对着区域 A 校验，所以 G2C.7 抓不到。

### 3. MEDIUM — 摆正时用户框选被放大
`_solveCrop` 用 `_mapRectToRotated` 把 `cropOverride` 映射进旋转空间，取的是四个旋转后角点的
**轴对齐外接框**，恒大于原框。`rollDeg=10°` + 295×413 的用户框 → AABB 362×458，
`normalizeToAspect` 再把高拉到 507 以恢复比例。主体比用户框的小约 23%，且无法纠正
（框得更紧只会再次被放大）。建议改为**反旋转**裁剪框，或 `cropOverride != null` 时跳过摆正。

### 4. MEDIUM — 保存失败后按钮永久禁用
`_save` 置 `_busy = true` 后 `await ... save(c)`，**没有 try/finally**。
`save` 可能因无存储权限、磁盘满、MediaStore 插入失败而 reject；
异常从 `VoidCallback` 逃逸成未处理异步错误，`_busy` 永不复位，
`enabled` 恒为 false —— 按钮退回哑光"请先选择照片"态，不重启 App 无法重试。

### 5. MEDIUM — 选图无错误处理
`_pick` 直接 await `photoSourceProvider.pick()`。`ImagePicker().pickImage` 在用户拒绝
`READ_MEDIA_IMAGES` 或 picker activity 被杀时抛 `PlatformException`（Android 13+ 首次运行的常见路径）。
无人捕获，用户只看到空态、没有任何提示。
**违反 CONTRACTS §6**：所有异常必须在 controller 层转成 `AppState.errorMessage`。

### 6. LOW/MED — 字体子集漏字
比对 `coveredCharset` 与 `lib/ui/` 下全部字符串字面量，缺 28 字：
`　乘前可四围场定实当截拖整景段毫注现盖真米范被覆见调锁阶`（含 U+3000 表意空格）。
可见文案 `'拖动四角调整裁剪范围　·　已锁定${spec.nameZh}比例'` 里的
拖/四/调/整/范/围/锁/定 加 U+3000 **全部缺失**。
`fontFamilyFallback: ['serif']` 挡住了豆腐块，但同一句话会一半是子集字体、
一半是系统衬线，字重与字宽不一致。fonts.dart 自己的文档就写了改文案必须重生成字符集，没做。

### 7. LOW/MED — 门禁排除区域不足
`_loadExcludeRects` 只保留 `crop_box` 和 `candidate_*`。区域 A 里照片是铺满整个 `display` 矩形的
（比裁剪框大），框外只是压暗（`Shade.scrim`，60% alpha）而非排除。
换成饱和度高的真实照片后，这些压暗的照片像素仍会被拿去和木色卡比对 ——
2C.2 可能掉到 95% 以下、2C.4 的黑白预算被照片内容吃掉，
**造成一个本该只评 chrome 的门禁误判 FAIL**。应排除 `area_a` 的照片 `display` 矩形。

### 8. LOW — ORT 句柄泄漏
`options?.release()` 只在 catch 分支调用。`OrtSession.fromBuffer` 成功后直接 return，
native options 对象永不释放 —— 每次成功 `warmUp()` 泄漏两个，
`disposeMattingEngine()` 后重新 warm 还会累加。

## 已核对、确认无问题（审查者主动申明）
- ORT session 指针跨 `Isolate.run` 边界是安全的：`OrtEnv.instance` 在每个 isolate 里
  从 dylib 重新推导 `_ortApiPtr`，`run`/`SessionGetInputCount` 都不碰 `OrtEnv.instance.ptr`
- `writeJpegDpi`/`_findApp0`、`readImageSize` 的 WebP VP8/VP8L/VP8X 与 JPEG SOF 解析、
  `deltaE2000`、`readJfifDensity`、`_AreaWeights` 的 INTER_AREA 移植，逐一对照规格无误
- `renderComposite` 的 else 分支（`render.dart:418-423`）不可达（`ah` 只会是 0.0 或 1.0），
  是死代码而非 bug
