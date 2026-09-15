# /code-review high — baseline-p3..HEAD（G3 通过后的补充审查）

主会话产出。按 CLAUDE.md §8：**不覆盖 G3 门禁结论**（PASS 仍成立），问题记入并回派。

**状态：部分完成。** 本次审查因 API 限流（429）中断，8 个审查角度中仅"跨文件追踪"
1 个角度交出发现（5 条，质量高）。完整重跑将在阶段 4 裁判数据收齐后补做。

## 发现（跨文件追踪角度）

| # | 严重度 | 位置 | 问题 | 责任 |
|---|---|---|---|---|
| 1 | **HIGH** | `lib/core/controller.dart:185` | setCrop 的 300ms 去抖 Timer 不被 loadImage/setSpec 取消：拖 A 图后 300ms 内选 B 图，Timer 在 loadImage await 期间触发 `_recompose`（++_gen 使 loadImage 的 gen 作废），用 A 的缓存 _matting 产出 A 的候选覆盖 B 的 sourceImage——UI 永久卡在"B 图 + A 候选" | 主会话 |
| 2 | MEDIUM | `lib/core/controller.dart:151` | controller 把 spec 原样传 compose，未经 tunedSpecFor——photo_specs.dart 头注释明确把调校替换指派给接线层。默认一寸拿到调校值（0.09/0.62），但切到其他 6 个规格用的全是 api.dart 的未调校值（0.08/0.62），头顶距上边距不一致 | 主会话 |
| 3 | MEDIUM | `integration_test/e2e_eval_test.dart:133` | G3 e2e 用未调校 kBuiltInSpecs 驱动 controller.setSpec → 42 张验收证据的几何与实际产品不一致（门禁认证了另一个产品）。**#2 修复后自动消解**（controller 内部统一调校） | 随 #2 |
| 4 | MEDIUM | `lib/ui/widgets/sync_raster.dart:56` | SyncRaster 用 package:image 解码但不 bake EXIF orientation，与本 PR 刚统一的 bakeOrientation 口径相悖。orientation=6 样张在 syncRaster 场景会侧躺压扁。g01 无 EXIF 故门禁未暴露 | ui-woodcraft |
| 5 | LOW | `lib/main.dart:28` | `unawaited(engine.warmUp())` 无错误监听：模型加载失败时 MattingException 逃逸为启动期未处理 zone 错误，且无诊断留下 | 主会话 |

## 处置
- #1/#2/#5：主会话领地（接线层），待 qa-batch 释放后修复（qa-batch 可能分多会话跑设备，
  中途改 lib/ 会污染批次数据一致性）。
- #3：随 #2 自动消解，无需改 gatekeeper 的测试。
- #4：回派 ui-woodcraft。
- 完整 8 角度审查：待重跑。

---

## 补充发现（限流中断前另外 2 个角度交付，共 8 角度中 3 个）

### 高度视角（6 条）

| # | 严重度 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| A1 | 设计债 | `api.dart` AppState.copyWith + `providers.dart` WorkbenchState.copyWith | clear 布尔旗标增殖到 4 个（clearError/clearSuggestedCrop/clearPickError/clearSaveError），每加一个可空字段就要加一对旗标 | 留给 G4 后的 /simplify，不改行为 |
| A2 | MEDIUM | `controller.dart` loadImage/_recompose | 异常→中文翻译逐方法重复；catch-all 把任何阶段（detectFace/compose）的意外错误都标成"抠图失败了" | 主会话修：抽 `_guarded` 辅助，收敛翻译点 |
| A3 | MEDIUM | `controller.dart:41` | controller 为 `suggestedCropInSourcePx` 依赖具体 IdPhotoEngineImpl——该方法是纯几何、无模型依赖，应在契约面上 | **契约变更（主会话职权，§7.5）**：提升到 IdPhotoEngine 抽象类，CONTRACTS 加注 |
| A4 | 设计债 | `providers.dart` UiConfig.syncRaster | 测试确定性旗标穿透 4 个生产 widget，生产包携带死分支 | 根因在截图管线不在 widget；留给 ui-woodcraft 评估（非阻塞） |
| A5 | LOW | `lib/ui/util/error_text.dart` | 硬编码字符串复制 CONTRACTS §6 文案（"这个图片格式打不开"逐字复制 messageZh），契约改词会静默漂移 | 回派 ui-woodcraft：引用异常常量不抄字面量 |
| A6 | LOW | `lib/main.dart:26-28` | "双保险"注释误述设计——warmUp 幂等共享 Future 已保证初始化，这里只是预取 | 主会话修注释 |

### 规约视角（2 条，commit 级流程观察）

- **C1**：`a72a648`（"主会话接线"）含约 140 行 ui-woodcraft 领地的视觉代码（FeltPainter 噪点、字体、area_c_save）。
- **C2**：`3618c54` 跨四个 agent 领地。

**主会话回应（如实）**：C1/C2 的代码**不是主会话写的**——它们是分别派给 ui-woodcraft / imaging / ml-porting / gatekeeper 的修复任务的产物，git 身份共享导致只能靠 commit message 归因，bulk 提交把多领地产物卷进了同一个 commit。这是**提交粒度纪律问题**（我的），不是"主会话替 agent 写业务代码"（宪法 §7 禁止的是后者）。改正：此后按领地分开提交。C1/C2 不构成 ACCEPTANCE 防作弊 6 条中的任何一条。

## 处置汇总
- 主会话（接线/api/契约）：#1（HIGH 计时器竞态）、#2（tunedSpecFor）、#5+A2（异常翻译收敛）、A3（契约提升）、#5+A6（warmUp 监听+注释）
- 回派 ui-woodcraft：#4（SyncRaster bake EXIF）、A5（文案复用常量）；A4 一并告知（非阻塞）
- 随 #2 自动消解：#3
- 留给 /simplify：A1、A4
- 剩余 5 个角度因限流未交付；已交付的 3 个均为横切视角，行级扫描角度由各 agent 自测与门禁覆盖。**补跑与否待阶段 4 裁决后定。**

---

## 补充发现 2（简化视角，第 4 个交付角度，6 条）

| # | 严重度 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| S1 | LOW | controller.dart:122-127 | loadImage 三个连续 `on` 分支做同一件事（前两个是 IdPhotoException 子类，死特化） | 并入主会话 A2 重构 |
| S2 | LOW | controller.dart:163-176 | _recompose 内联重写 _fail 的 gen/isClosed 守卫 + _emit，失败策略两处维护 | 并入 A2 重构 |
| S3 | LOW | controller.dart:194-199 | setSpec 绕过 _emit 直接 `_state =` 赋值，_state 出现两条写入路径 | 并入 A2 重构 |
| S4 | LOW | lib/ui/dev/charset_scan.dart | 352 行独立 CLI（自带 main，纯 dart:io，无 import）放 lib/ui/dev；应挪 tools/（分析面/索引成本） | 回派时一并处理（tools/ 根目录未分配，主会话可裁决放行） |
| S5 | LOW | imaging/dev_selfcheck.dart:723-740 | 新"越界无黑边"测试与既有 2B.9 测试重复同一套黑边扫描（阈值 210、坐标映射两处维护） | 留给 /simplify |
| S6 | **MEDIUM** | lib/ui/widgets/sync_raster.dart:42-53 | 模块级 `_cache` 无上限：注释自称"条目数 ≤8"但 candidate_card 每张缩略图都进缓存，G3 口径 42 张 distinct thumbBytes 各钉 ~10 万顶点永不释放。**当前生产路径 syncRaster=false 不受影响**（qa-batch 的 runner 也直驱 controller 不过 UI），但这是为截图/门禁场景建的部件，量级会随场景涨 | 回派 ui-woodcraft：加 LRU 上限或按 widget 生命周期失效 |

## 累计账目（4/8 角度交付，共 19 条 + 2 条流程观察）
- 主会话待修：#1(HIGH) / #2 / #5+A6 / A2(含S1/S2/S3) / A3(契约提升)
- ui-woodcraft 待修：#4(EXIF) / A5(文案常量) / S6(缓存上限) / S4(工具挪位，顺带)
- /simplify 待办：A1 / A4 / S5
- 流程：C1/C2 提交粒度（已回应，此后分领地提交）

---

## 补充发现 3（跨文件追踪角度完整版，6 条新增；含 1 条高危）

| # | 严重度 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| X1 | **HIGH（隐私）** | controller.dart:87 | **加载失败后 _matting/_face 缓存不清除**：loadImage 已 emit sourceImage=B 后 removeBackground 抛异常，_matting 仍是 A。用户在 B 图上拖框 → compose 用 A 的像素 + B 的坐标 → 区域 B 显示 A 的脸、保存可用——**用户把错误的人的照片当成 B 存走** | 主会话修（loadImage 入口清缓存；失败路径一并清） |
| X2 | HIGH | controller.dart:74 | = 此前 #1 的完整版：另发现 _matting 为 null（首图）时 Timer 触发 `_matting!` 抛异常 → _fail 进 error 态且无重试路径 | 主会话修（同 #1） |
| X3 | MEDIUM | controller.dart:166 | 成功的 _recompose 不 clearError：失败→拖框→成功后，红色"抠图失败了"残留；且 setSpec 的 emit 有 clearError 而 setCrop 路径没有，行为不一致 | 主会话修 |
| X4 | MEDIUM（隐私） | controller.dart:230 | save() 先写私有文件后写 Gal：Gal 失败时文件已落盘但路径被异常丢弃——**每次失败保存永久泄漏一张全分辨率用户照片在 temp 目录**，无清理 | 主会话修（调整顺序/失败时删除临时文件） |
| X5 | MEDIUM | matting/ort_runtime.dart:79 | `_envInitialized` 是 isolate 局部而 createSession 只在瞬态 Isolate.run 里跑——"每进程一个 env"不变式失效：每次 warmUp 重试泄漏一个 native env（ml-porting 自己在 G2A 报告里预警过的残留项，本条坐实了泄漏路径） | 回派 ml-porting |
| X6 | MEDIUM | ui/areas/area_a_source.dart:312 | matting 期间（1-2s）CropOverlay 已可交互：用户无意触碰会把 crop 存进 workbenchProvider 且 token 与新图匹配 → suggestedCrop 到达时被静默覆盖，引擎算的自动取景永远不出现 | 回派 ui-woodcraft（matting 期禁用拖拽交互） |

该角度同时**主动核清**了 4 项疑点（无发现）：MuZhaoController 实现契约完整；clearSuggestedCrop 无误用；compose 的图外采样确有底色填充兜底（_mapCropToRotated 的 alpha=0 声明成立）；onnxruntime 1.4.1 纯 FFI 无 NativeFinalizer，跨 isolate 会话地址不悬垂。

## 最终账目（4/8 角度交付：跨文件×2轮 + 高度 + 规约 + 简化 = 25 条 + 2 流程观察）
- **主会话修（接线层，qa-batch 释放后动手）**：X1(HIGH 隐私) / X2(=#1) / #2(tunedSpecFor) / X3 / X4(隐私) / #5+A6(warmUp) / A2+S1+S2+S3(_guarded 重构) / A3(契约提升)
- **ui-woodcraft**：#4(EXIF bake) / A5(文案常量) / S6(缓存上限) / S4(工具挪位) / X6(matting 期禁交互)
- **ml-porting**：X5(env 泄漏)
- /simplify：A1 / A4 / S5
- 流程：C1/C2（已回应）

---

## 补充发现 4（移除行为审计角度，4 条 + 9 项核清）

| # | 严重度 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| B1 | MEDIUM | ort_runtime.dart:82 | = X5 的确认版：`_envInitialized` per-isolate 把双重 CreateEnv 泄漏**收窄到每次 _loadModels 一次**而非消除；warmUp 失败重试路径持续累积 native env，无释放通道 | 回派 ml-porting（与 X5 合并处理） |
| B2 | MEDIUM | imaging/compose_engine.dart:300 | 刚体反旋转（#3 修复）的代价坐实：用户贴边框选 + ~10° roll 时框出旋转画布，出界区渲染为平色底——**outOfBoundsFraction 只进诊断，UI 无警示、保存无拦截**，用户框选的内容被静默丢弃且无法察觉 | 记录为已知取舍；UI 警示留待 /simplify 或后续迭代（需要 AppState 加提示通道，属契约变更，不在阶段 4 强推） |
| B3 | LOW | tools/gate/capture_shots.dart:70 | 模拟器启动从 `flutter emulators --launch`（有退出码、快速失败）换成 detached Process.start 且 stdout/stderr 全弃、不留 PID：flag 不兼容时 gate 日志零诊断，白烧 3 分钟 bootTimeout | 回派 gatekeeper（它自己的文件，它修） |
| B4 | LOW | main.dart:28 | = #5 确认版：移除的占位 home 不会失败，新的 unawaited warmUp 引入"启动期静默未处理拒绝"模式 | 主会话修（已在队列） |

**该角度核清的 9 项**（摘关键）：G1.6 不依赖已删除的占位 home（shots_test 已不 import main.dart）；copyWith(clearSuggestedCrop) 加法安全；ort options finally-release 正确修复真实泄漏；crop_geometry 角点修复数学成立且有回归测试；fonts 新字符集是旧集严格超集（0 删 148 增，无豆腐回归）；gate 脚本改动均为加强非放松（gate_G2C 从 first-match 改为全 case 必过）。

## 最终账目（5/8 角度交付：共 29 条 + 2 流程观察）
主会话修：X1(HIGH) X2 X3 X4 #2 #5+A6 A2+S1+S2+S3 A3 ｜ ui-woodcraft：#4 A5 S6 S4 X6 ｜ ml-porting：X5+B1 ｜ gatekeeper：B3 ｜ /simplify：A1 A4 S5 B2 ｜ 流程：C1/C2（已回应）
