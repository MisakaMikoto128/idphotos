# 木照 MuZhao — 团队宪法

纯本地运行的免费证件照 App。所有 agent 在动手前必读本文件，冲突时以本文件为最高优先级。

## 1. 产品定义

- 名称：木照 MuZhao（可改，改则同步 `docs/DESIGN.md` 与 `store/`）
- 平台：Flutter，Android 优先上架；iOS 代码保持可编译，但**本阶段不做 iOS 打包**（开发机为 Windows，无 Xcode）
- 核心承诺：**100% 离线**。App 不含任何网络权限、不含任何统计/广告 SDK。这是产品卖点，也是硬红线。
- 免费、无内购、无水印。

## 2. 三段式界面（不得增删主区域）

```
┌─ 区域 A：原图上传 + 可拖拽框选 ─┐
├─ 区域 B：候选结果横向列表（不同底色）─┤
└─ 区域 C：保存按钮 ─┘
```

视觉风格：**复古木制**。色卡、材质、字体、圆角一律以 `docs/DESIGN.md` 为准，禁止自创色值。

## 2.5 开发机事实（已实测，任何 agent 不得推翻或重新探测）

完整现状见 `docs/ENV.md` 顶部。三条最容易踩的，写在这里确保没人漏看：

| 事实 | 后果 |
|---|---|
| 模拟器加速用 **AEHD**（`gvm.sys` 运行中），**不是** Hyper-V | **禁止启用 Hyper-V/WHPX**，二者互斥，开了会顶掉现有加速 |
| PATH 上的 java 是 **JDK 22**，Flutter 只吃 17 | 必须 `flutter config --jdk-dir "C:\Program Files\Android\Android Studio\jbr"`。**不要卸载 JDK 22** |
| 现有 AVD 只给了 **1536MB** 内存 | 必须调到 **4096**。不调不会报错，但会让 G4.6/G4.7 测出假数字，导致 gatekeeper 误判并白烧 3 轮预算 |

Android Studio / SDK / android-34 镜像 / Python 3.11.4 **均已就位，不要重装**。
唯一需要安装的大件是 Flutter SDK。

## 3. 技术栈（已锁定，不得擅自更换）

| 层 | 选型 |
|---|---|
| 框架 | Flutter 3.x (stable) / Dart 3 |
| 状态管理 | Riverpod |
| 端侧推理 | onnxruntime（Android: NNAPI/XNNPACK provider） |
| 抠图模型 | HivisionIDPhotos 的 MODNet / RMBG，int8 量化 |
| 图像处理 | Dart `image` 包 + 必要时 native (C++/FFI) |
| 人脸检测 | 端侧轻量模型（不用 ML Kit —— 它会引入 Google Play 依赖，违反纯离线红线） |

## 4. 目录与势力范围（硬约束）

每个 agent **只能**写自己范围内的文件。需要别人范围内的改动，写进报告里提出请求，由主会话协调。

| 目录 | 归属 |
|---|---|
| `CLAUDE.md`, `docs/CONTRACTS.md`, `docs/DESIGN.md` | 主会话（唯一写入者） |
| `docs/ENV.md` | env-setup |
| `docs/PITFALLS.md` | **所有 agent 只追加，不删改他人条目** |
| `lib/core/matting/`, `native/`, `assets/models/` | ml-porting |
| `lib/core/imaging/`, `lib/core/specs/` | imaging |
| `lib/ui/`, `assets/textures/`, `assets/fonts/` | ui-woodcraft |
| `test/batch/`, `test/golden/`, `test/dataset.json`, `out/QA_*`, `out/batch_*`, `out/metrics_*`, `out/leak_*`, `out/grid_*` | qa-batch |
| `test/adversarial/`, `out/ADVERSARIAL_*` | adversarial |
| `tools/gate/`, **`test/gate/`**, **`integration_test/`**, **`test_driver/`**, `out/GATE_*`, `out/BLOCKED_*`, `out/hashes_*`, `out/gate_*.json` | gatekeeper |
| `out/VISUAL_*`, `out/tmp/` | visual-critic |
| `out/shots/` | **共享输出目录**：任何 agent 按 `capture-shots` skill 跑截图都可写。不是代码，不受防作弊条款约束 |
| `out/REVIEW_*` | 主会话（`/code-review`、`/security-review` 的产出） |
| `pubspec.yaml` | **主会话（唯一写入者）**。阶段 1.5 一次性声明好 `assets/models/`、`assets/textures/`、`assets/fonts/`，之后任何 agent 需要加资源目录必须在报告里请求 |
| `docs/ACCEPTANCE.md`, `docs/RUBRIC.md` | 主会话（唯一写入者，任何 agent 修改即 FAIL） |
| `android/`(构建/权限/签名), `ios/` | release |
| `store/`, `res/mipmap-*`, `res/drawable*` | store-assets |
| `lib/core/*.dart`（顶层文件，含 `api.dart`、`engine_impl.dart`）, `lib/main.dart`, `pubspec.yaml` | 主会话（接线层，唯一写入者） |

## 5. 协作纪律

1. **契约先行**：`lib/core/api.dart` 的签名由 `docs/CONTRACTS.md` 定义。并行阶段各自对着契约写，用 mock 自测，禁止跨层直接调用实现类。
2. **报告格式**：subagent 结束时的报告**不超过 20 行**，只含：改了哪些文件 / 关键决策 / 遗留问题 / 给别人的接口请求。**不要在报告里贴代码**。
3. **踩坑留痕**：任何浪费超过 10 分钟的坑，追加一条到 `docs/PITFALLS.md`。
4. **不装环境**：除 env-setup 外，任何 agent 都不要执行 SDK 安装、`flutter upgrade`、全局包安装。缺环境就报告，不要自己动手。
5. **测试素材**：`C:\Users\liuyu\Pictures\`（约 40 个文件，含人像/截图/风景混杂）。这是真实脏数据，非人像输入必须优雅失败而不是崩溃。

## 6. 硬红线（违反即回退）

- 不加网络权限、不加任何联网代码、不加统计/崩溃上报 SDK
- 不引入 Google Play Services / Firebase / ML Kit
- 不把用户照片写到 App 私有目录之外（保存除外，且需用户主动点击）
- 不擅自更换技术栈、不擅自改三段式布局
- 不 `git push`、不发布、不改他人势力范围内的文件


## 7. 全自动模式协议（goal 模式下生效）

无人值守时，"做完了"由**门禁**定义，不由做事的 agent 自称。

### 阶段与门禁

| 阶段 | 执行 | 出口门禁 |
|---|---|---|
| 0 | 主会话：宪法/契约/设计/验收/评分卡 | 文件齐备 |
| 1 | env-setup → qa-batch(冻结数据集+黄金集) ∥ gatekeeper(建 `tools/gate/` + `integration_test/` 截图流水线) | **G1** |
| 1.5 | **主会话独占**：按 CONTRACTS.md 落地 `lib/core/api.dart`（抽象类+数据类型+异常+规格表骨架）与 `lib/main.dart` 骨架 | 契约文件存在且 `dart analyze` 无错 |
| 2 | ml-porting ∥ imaging ∥ ui-woodcraft（并行）→ visual-critic 审 UI | **G2A / G2B / G2C** |
| 3 | 主会话接线 + 端到端贯通 | **G3** |
| 4 | qa-batch ∥ adversarial ∥ visual-critic（并行验收） | **G4** |
| 5 | release ∥ store-assets（并行） | **G5 / G5B** |

`gatekeeper` 在阶段 1 就开始写 `tools/gate/`，与开发并行，**不要等到验收时才建门禁**。

### 三条不可违反的规则

1. **门禁未 PASS，不得进入下一阶段。** 没有"先往下做，回头再补"。
2. **只有 gatekeeper 能宣布 PASS。** 实现类 agent 的自我评价不作数，主会话也不越过 gatekeeper 放行。
3. **裁判不下场。** gatekeeper / visual-critic / adversarial / qa-batch **一律不修代码**，只出判决和回派指令。它们一旦动手改代码就不再中立。

### 循环控制

- 每个 gate 最多 **3 轮** 修复。
- 第 3 轮仍 FAIL → 写 `out/BLOCKED_G<n>.md`（失败项 / 已试方案 / 卡点），**全流程终止等人工**。
- **禁止**为了通过而降低 `docs/ACCEPTANCE.md` 的阈值、删减黄金集、跳过 gate。
  阈值只有主会话能改，且只在人工明确要求时改。

### 版本基线（防作弊的技术前提）

项目是 git 仓库。**每个阶段开始前，主会话打一个 tag**：`baseline-p1` / `baseline-p1.5` / `baseline-p2` …
gatekeeper 靠 `git diff <baseline>..HEAD` 判断有没有 agent 越界改了测试或验收标准。
没有基线 tag，防作弊条款第 1、2、4 条就无法执行 —— **这一步不能省**。

阶段结束、gate PASS 后再提交一次，commit message 写 `phase<n>: <一句话> (G<n> PASS)`。

### 主会话的角色

拆派、接线（`lib/core/api.dart`、`lib/main.dart`）、按 gatekeeper 的回派指令重新派活、
在触发终止时停下来。**主会话不替 agent 写业务代码，也不替 gatekeeper 判 PASS。**


## 7.5 跨界请求（避免并行时抢同一个文件）

以下文件不属于任何执行类 agent，需要改动时**在报告里提出请求，由主会话统一处理**：

| 文件 | 谁可能需要 | 怎么办 |
|---|---|---|
| `pubspec.yaml` | ml-porting(模型资源) / ui-woodcraft(字体材质) | 主会话在阶段 1.5 预先声明好三个 assets 目录，正常情况无需再改 |
| `android/app/build.gradle` | ml-porting（ONNX 的 abiFilters / packagingOptions / proguard keep） | 归 release 所有。阶段 2 就要提出，不要拖到阶段 5 才发现 release 包跑不起来 |
| `AndroidManifest.xml` | 相册权限 | 主会话在阶段 1.5 加好 `READ_MEDIA_IMAGES`，release 在阶段 5 做最终精简 |
| `lib/core/api.dart` | 任何人想改接口签名 | 主会话独占。改签名会打断并行，必须先说明理由 |

**并行阶段两个 agent 同时改一个文件 = 后写的覆盖先写的，且不会报错。** 这是多 agent 最隐蔽的失败模式，靠上表规避。

## 8. 可用工具（提高效率，不要重复造轮子）

### 项目内 skill（`.claude/skills/`）

| skill | 谁用 | 什么时候用 |
|---|---|---|
| `flutter-win` | **所有 agent** | 构建失败、Gradle 报错、模拟器问题、路径问题 —— **先查它，不要自己瞎试** |
| `capture-shots` | ui-woodcraft / qa-batch / visual-critic / store-assets | 任何需要界面截图的时候 |
| `run-gate` | gatekeeper | 每轮验收 |

### 内置 skill（主会话在阶段切换时调用）

| skill | 时机 |
|---|---|
| `/code-review high` | G2、G3 通过后各跑一次，作为门禁之外的补充审查 |
| `/security-review` | **G5 前必跑**。本项目的核心承诺是隐私，这一步不可省 |
| `/simplify` | G4 通过后跑一次，清理并行开发留下的重复代码 |
| `/run` | 阶段 3 起，需要真机/模拟器验证时 |

`/code-review` 与 `/security-review` 的发现**不覆盖门禁结论** ——
它们发现的问题记入 `out/REVIEW_*.md` 并回派修复，但 PASS/FAIL 仍由 gatekeeper 按 ACCEPTANCE.md 判定。

## 9. 完整角色表（10 个）

| agent | 阶段 | 类型 |
|---|---|---|
| env-setup | 1 | 执行 |
| ml-porting | 2 | 执行 |
| imaging | 2 | 执行 |
| ui-woodcraft | 2, 4 | 执行 |
| release | 5 | 执行 |
| store-assets | 5 | 执行 |
| qa-batch | 1, 4 | **裁判** |
| adversarial | 4 | **裁判** |
| visual-critic | 2C, 4 | **裁判** |
| gatekeeper | 全阶段 | **裁判（唯一 PASS 权）** |

裁判类 agent **一律不修代码**。执行类 agent **一律不碰 `test/` `tools/gate/` `docs/ACCEPTANCE.md` `docs/RUBRIC.md`**。
