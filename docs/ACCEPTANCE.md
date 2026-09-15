# 验收标准（Definition of Done）

**主会话是本文件的唯一写入者。任何 agent 修改本文件 = 立即 FAIL 并终止该阶段。**

全自动模式下没有人工判断，所有 gate 必须是脚本可判的。凡是写不出判定脚本的标准，
一律不作为 gate（可以写进 RUBRIC 交给 visual-critic，但不作为硬门禁）。

判定程序：`tools/gate/gate_G<n>.dart`，退出码 0 = PASS，非 0 = FAIL。
由 `gatekeeper` 执行，**实现类 agent 无权运行也无权修改**。

---

## G1 — 环境与黄金集（阶段 1 出口）

| # | 检查项 | 判定 |
|---|---|---|
| 1.1 | `flutter build apk --debug` | 退出码 0 |
| 1.2 | `docs/ENV.md` 无 `- [ ]` 未填项 | grep 计数 = 0 |
| 1.3 | 黄金集图片 | `test/golden/src/` 下 ≥ 8 张人像 JPEG |
| 1.4 | 黄金集参考 alpha | `test/golden/ref/` 下与 src 同名的 PNG，数量一致 |
| 1.5 | 参考 alpha 有效性 | 每张前景占比在 8%–70% 之间（排除全黑/全白的废文件） |
| 1.6 | **截图流水线打通**（gatekeeper 负责建，`integration_test/` 归它） | 能在模拟器上跑起默认 App 并落盘 1 张非纯黑 PNG 到 `out/shots/` |
| 1.7 | **内存/耗时采集打通**（gatekeeper 负责建） | 能从模拟器读到进程峰值内存与单步耗时，写入 JSON |

**1.6 与 1.7 是全自动模式的生命线，必须在阶段 1 就验证通过。**
截图跑不通 → `visual-critic` 无图可看 → G2C 与 G4.5 全部失效，等于回到"agent 自己说好看"。
采集跑不通 → G4.6/4.7/4.8 全部失效。这两条不通过，后面做得再多也无法验收，**不许推迟到阶段 4 再解决**。

**黄金集来源**：用 HivisionIDPhotos 原版 Python 在本机跑一次，输出作为参考真值。
这是唯一的客观基准 —— 没有它，后续所有抠图质量指标都无法自动判定。
env-setup 需额外准备 Python 3.10 + HivisionIDPhotos 依赖（仅开发机，不进 App）。

---

## G2A — 抠图引擎（ml-porting 出口）

| # | 检查项 | 阈值 |
|---|---|---|
| 2A.1 | 抠图模型文件体积 | ≤ 10 MB |
| 2A.2 | 人脸模型文件体积 | ≤ 2 MB |
| 2A.3 | alpha 与参考的 IoU（二值化 @128） | 黄金集**每一张** ≥ 0.95 |
| 2A.4 | alpha 平均绝对误差 | 黄金集均值 ≤ 0.04（0–1 归一化） |
| 2A.5 | 边缘带误差（参考边界 ±5px 环带内 MAE） | ≤ 0.12 |
| 2A.6 | 单张耗时 512×512 | p95 ≤ 1500 ms |
| 2A.7 | 全量鲁棒性 | `C:\Users\liuyu\Pictures\` 全部文件跑完，**进程 0 崩溃**；非人像返回 null 或抛约定异常 |
| 2A.8 | 人脸检测召回 | 黄金集 8/8 检出，`chinY > headTopY` 恒成立 |

## G2B — 合成引擎（imaging 出口）

| # | 检查项 | 阈值 |
|---|---|---|
| 2B.1 | 输出尺寸 | 7 个规格逐一像素级精确匹配 CONTRACTS 第 4 节 |
| 2B.2 | JFIF DPI 字段 | 解析回读 = 300，7/7 通过 |
| 2B.3 | 头高比 | 输出图中 (chinY−headTopY)/H 与 spec.headHeightRatio 偏差 ≤ 0.02 |
| 2B.4 | 头顶留白比 | 与 spec.headTopRatio 偏差 ≤ 0.02 |
| 2B.5 | 人脸水平居中 | 人脸中心 x 与画面中心偏差 ≤ 画宽的 3% |
| 2B.6 | **溢色检测** | 换底到纯绿 `#00FF00` 后，alpha>200 的前景区域内，不得存在像素满足 `G − max(R,B) > 40`。计数必须 = 0 |
| 2B.7 | 溢色检测（反向） | 换底到纯品红 `#FF00FF` 同理，`min(R,B) − G > 40` 计数 = 0 |
| 2B.8 | 摆正 | 构造 ±10° 旋转输入，输出 rollDeg 残差 ≤ 1.5° |
| 2B.9 | 边界安全 | 人脸贴近图片边缘时不抛异常、不产生黑边 |

## G2C — 界面（ui-woodcraft 出口）

| # | 检查项 | 阈值 |
|---|---|---|
| 2C.1 | golden 截图产出 | 用 `FakeController` 截出 `capture-shots` skill 规定的全部 **8 张**（S1–S6 + 两张小屏），每张非纯黑 |
| 2C.2 | **调色板合规** | 截图去除照片区域后，≥95% 像素与 `DESIGN.md` 色卡某一 token 的 CIEDE2000 ΔE ≤ 12 |
| 2C.3 | **无 Material 残留** | 截图中不得出现 `#6750A4` `#D0BCFF` `#EADDFF` 及其 ΔE≤6 邻域 |
| 2C.4 | **无纯黑纯白** | 照片区域外，`#000000` 与 `#FFFFFF` 像素合计占比 ≤ 2% |
| 2C.5 | 触摸热区 | widget test 断言：8 个裁剪控制点命中区 ≥ 44×44 逻辑像素 |
| 2C.6 | 宽高比锁定 | 拖拽任一角后，裁剪框宽高比与当前 spec 偏差 ≤ 0.5% |
| 2C.7 | 边界约束 | 模拟拖出图片范围，裁剪框始终被钳制在图内 |
| 2C.8 | 字体子集体积 | `assets/fonts/` 总计 ≤ 400 KB |
| 2C.9 | 无 Material ripple | 源码 grep：`splashFactory: NoSplash` 已全局设置，无裸 `InkWell` |
| 2C.10 | 无网络代码 | 全 `lib/` grep 无 `http` `dio` `Socket` `HttpClient` |

---

## G3 — 端到端贯通（阶段 3 出口）

| # | 检查项 | 阈值 |
|---|---|---|
| 3.1 | 真实照片跑通全链路 | 黄金集第一张 → 7 规格 × 6 底色 = 42 张全部产出 |
| 3.2 | 产出合法性 | 42 张全部通过 G2B 的 2B.1 / 2B.2 / 2B.6 |
| 3.3 | 保存 | 落盘路径存在且文件可被重新解码 |
| 3.4 | 冷启动 | Dart `main()` → 首帧可交互 ≤ 2000 ms（探针 `integration_test/coldstart_probe_test.dart` 实测口径）；进程级 `am start -W` TotalTime 记录入报告作参考，不作判定。**口径变更记录（2026-09-14，人工授权）**：开发机无 Android 真机；模拟器必须 `-gpu guest` 软件渲染（宿主 GPU 驱动栈损坏，见 PITFALLS），进程启动段环境地板 ~6s（G1 骨架 App 同口径基线 5988ms），且探针实测 Dart 首帧仅 427ms——超时部分全部是环境成本而非应用回归。原判定（进程 TotalTime ≤ 2000ms）在本机物理上不可达，经用户明确要求改为 Dart 首帧口径；阈值数字 2000ms 本身不变。 |

---

## G4 — 综合验收（阶段 4 出口，最严）

| # | 检查项 | 阈值 |
|---|---|---|
| 4.1 | 真实数据集 | Pictures 全 40 项跑完，**崩溃 = 0，ANR = 0** |
| 4.2 | 人像类成功率 | 100%（人像子集由 qa-batch 分类并冻结，之后不得增删） |
| 4.3 | 非人像类 | 100% 优雅失败（有中文提示，不崩溃，不产出诡异结果） |
| 4.4 | 对抗用例 | `adversarial` 的全部用例 0 崩溃、0 数据损坏、0 无响应 >5s |
| 4.5 | 视觉评分 | `visual-critic` 总分 ≥ 8.0 / 10，且**致命项 = 0** |
| 4.6 | 抠图耗时 | 真机 p95 ≤ 1500 ms |
| 4.7 | 峰值内存 | ≤ 450 MB |
| 4.8 | 内存泄漏 | 连续处理 20 张后内存回落到基线 +80MB 以内 |
| 4.9 | 无遗留 TODO | `lib/` 下 `TODO`/`FIXME`/`throw UnimplementedError` 计数 = 0 |

---

## G5 — 发布（阶段 5 出口）

| # | 检查项 | 阈值 |
|---|---|---|
| 5.1 | **无 INTERNET 权限** | 解析 release 的 merged manifest，`android.permission.INTERNET` 不存在 |
| 5.2 | 权限白名单 | 最终权限集 ⊆ {READ_MEDIA_IMAGES, WRITE_EXTERNAL_STORAGE(≤32)} |
| 5.3 | 无 Google/统计依赖 | `gradlew :app:dependencies` 无 `play-services` `firebase` `mlkit` `crashlytics` |
| 5.4 | 产物 | `.aab` 与 `.apk` 均存在 |
| 5.5 | 包体积 | `.aab` ≤ 60 MB |
| 5.6 | release 可运行 | 装到模拟器，冷启动 + 完成一次完整出图 |
| 5.7 | 无密钥泄漏 | `key.properties`、`*.jks` 在 `.gitignore` 中；仓库内无明文口令 |

## G5B — 上架材料（store-assets 出口，与 G5 并行）

| # | 检查项 | 阈值 |
|---|---|---|
| 5B.1 | 图标 | `store/icon_512.png` 存在，512×512，含 alpha 通道 |
| 5B.2 | 图标全密度 | mipmap-{m,h,xh,xxh,xxxh}dpi 五套齐备，尺寸各自正确 |
| 5B.3 | 自适应图标 | 前景/背景分离，前景主体在中心 66% 安全区内（脚本量非透明像素外接框） |
| 5B.4 | **缩略可辨认** | 图标缩到 48×48 后，非背景色像素占比 ≥12%（太细的线条缩小后会消失） |
| 5B.5 | 功能图 | `store/feature_graphic.png` 恰好 1024×500 |
| 5B.6 | 宣传截图 | `store/screenshots/zh/` 与 `/en/` 各 ≥5 张，均为 1080×1920 |
| 5B.7 | 截图真实性 | 宣传截图必须基于 `out/shots/` 的真实界面合成，**不得手绘伪造界面** |
| 5B.8 | 文案长度 | 短描述 ≤80 字符；完整描述 ≤4000 字符；两种语言均满足 |
| 5B.9 | 文案真实性 | 文案中提到的每个功能，都能在 `lib/` 中找到对应实现（逐条人工列举核对） |
| 5B.10 | 隐私政策 | zh/en 两版齐备，且明确包含"不收集/不传输/无网络权限"三点 |
| 5B.11 | 托管说明 | `store/PRIVACY_HOSTING.md` 存在（Play Store 要求公网 URL，本地文件不被接受） |
| 5B.12 | 合规与清单 | `store/COMPLIANCE.md` 与 `store/CHECKLIST.md` 存在；CHECKLIST 明确区分"已自动完成"与"需用户手动" |
| 5B.13 | 启动图无白闪 | 截取冷启动前 500ms 的帧，不得出现全白帧 |

---

## 防作弊条款（全自动模式的核心保护）

以下任一情形直接判定该阶段 **FAIL** 并计入循环预算，不得申辩：

1. 实现类 agent（ml-porting / imaging / ui-woodcraft / release）写入了 `test/`、`tools/gate/`、`docs/ACCEPTANCE.md`、`docs/RUBRIC.md`。
2. gate 脚本的 SHA256 与 gatekeeper 上一轮记录的不一致，且变更不是由 gatekeeper 自己做的。
   （首轮无 `out/hashes_prev.txt` 属正常，直接建立基线，不判 FAIL。）
3. 测试中出现 `skip:`、`@Skip`、注释掉的断言、被放宽的阈值常量。
4. 黄金集被删减、被替换成更容易的图片，或 `test/golden/` 下文件数减少。
5. 通过 catch-all 吞异常来让"0 崩溃"成立（`catch (_) {}` 空实现）。
6. 报告中声称达标但 gate 脚本未实际运行，或运行结果与报告不符。

## 循环预算

每个 gate **最多 3 轮**修复。第 3 轮仍 FAIL：
- 停止该阶段，产出 `out/BLOCKED_G<n>.md`，写清失败项、已尝试的方案、卡在哪
- **不得**降低阈值、**不得**跳过该 gate 继续下一阶段
- 全流程终止，等人工介入
