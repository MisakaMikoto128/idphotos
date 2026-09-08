# QA 数据集冻结 + 黄金集报告（阶段 1）

生成脚本：`test/batch/freeze_dataset.py`（数据集扫描+分类）、
`test/batch/build_golden.py`（黄金集构建+参考抠图+自检）。
参考抠图用 `.venv_ref` + `.ref_hivision/run_matting.py`（HivisionIDPhotos 原版 MODNet）。

## 1. 数据集扫描范围与排除说明

递归扫描 `C:\Users\liuyu\Pictures\`，**排除** `Luminar Neo Catalog\{Backups,CacheDocuments,PreviewCache}`
三个目录（共约 225 个文件）。这些是 Luminar Neo 图库软件的内部缩略图缓存，
文件名为哈希值，同一源图有多档分辨率重复缓存（如 `020CB1CA...D1201...jpg` /
`...D1501...jpg` / `...D3001...jpg` 明显是同一张图），不是独立真实照片。
全部纳入会与 CLAUDE.md 写明的"约 40 个文件"矛盾，也会用重复缩略图稀释
class 计数、拖慢阶段 4 全量跑批。`Lightroom\*.lrdata` 内部只有 2~3 个
`.db` 文件（非逐张缓存），体量小予以保留，归 `non_image`。

## 2. 数据集分类结果（`test/dataset.json`，共 80 项）

| class | 数量 |
|---|---|
| screenshot | 37 |
| landscape | 16 |
| **portrait** | **11** |
| non_image | 13 |
| multi_face | 3 |
| profile | 0 |
| low_light | 0 |

**诚实说明两个空类别**：
- `profile`（侧脸）：真实数据里没有一张能明确判定为侧脸/半侧脸的人像，0 项。
- `low_light`（低光）：分类脚本用 HSV V 通道均值 <70 判定低光，真实数据集里没有
  一张低于该阈值（最暗的是 `Camera Roll\WIN_2023...jpg` 系列，均值≈124，
  室内暗光但未到判定线）。**这意味着 G4 跑批里 low_light/profile 两类将是
  0/0（成功率无意义，不是"100%通过"）**，如果后续要验证这两类的鲁棒性，
  需要 adversarial 或主会话额外构造用例，qa-batch 不会为了凑数把普通照片
  硬归为 low_light/profile。
- **EXIF Orientation**：全数据集 80 项 `exif_orientation` 全部为 `1`（正常方向），
  **没有一张 orientation=6/3/8 的真实竖拍图**。CLAUDE.md 提醒"手机竖拍图
  orientation=6，真实数据里一定有"，但本机这批素材里确实没有——多数竖拍
  照片的 EXIF 已被微信/相册/工具重新编码为像素级旋转（orientation=1）。
  **这是一个已知覆盖缺口**：G4 无法靠真实数据验证 orientation 处理，需要
  adversarial 用合成图覆盖。

### 分类方法（诚实披露，含人工修正）
用 mtcnn-runtime（HivisionIDPhotos 依赖的同款 ONNX MTCNN）在缩放至长边
≤800px 的图上做人脸检测：0 张脸→landscape；≥2 张→multi_face；1 张脸按
关键点算 yaw_ratio 判 profile，否则按亮度判 low_light/portrait。
screenshot 按路径（`Screenshots` 目录）或文件名前缀（`屏幕截图`/`QQ截图`）
判定，优先级最高（在人脸判定之前）。

**人工修正了 6 处 MTCNN/命名规则误判**（脚本跑完后逐张目检 `portrait`/
`multi_face` 全部 14 张候选，发现问题后手工改判，理由记在
`test/dataset.json` 对应条目的 `_manual_reclass_reason` 字段）：
- `IMG_20230115_130634.jpg`、`IMG_20230115_133511.jpg`、
  `Online Verification Report...00.jpg`：MTCNN 检出的"人脸"其实是文档/
  网页截图里内嵌的证件照缩略图（学籍验证报告页面），不是独立人像照，
  portrait → landscape。
- `)T@WU8]6Q}21RVC5RUROQ]G.jpeg` / `.png`：实为同一份网页截图（文件名被
  混淆，没有匹配到"屏幕截图/QQ截图"命名规则），portrait → screenshot。
- `8D861A29F86CE7464865EFEB3C9B4124 (自定义).jpg`：MTCNN 误检出 2 张脸
  （疑似眼镜反光/发丝纹理触发），目检确认只有 1 人，multi_face → portrait。

未发现其他误判（抽查了全部 16 张 landscape 里的 9 张、3 张 multi_face
里的全部 4 张原始候选、11 张最终 portrait）。

## 3. 黄金集（`test/golden/src/g01.jpg`..`g08.jpg` + `test/golden/ref/g0N.png`）

全部来自冻结后的 `portrait` 子集（11 项选 8 项），刻意覆盖不同底色/背景/
发型/年龄，不全用同一批同人同景的近似重复照：

| 文件 | 来源 | 尺寸(src) | 前景占比 | 说明 |
|---|---|---|---|---|
| g01.jpg | `Pictures\2.jpg` | 1080×1415 | **55.6%** | 蓝底标准证件照，短发无镜框 |
| g02.jpg | `Pictures\20240710193717_7c99.jpg` | 480×640 | **69.2%** | 白底证件照，镜框+卷发（贴近上限，仍在区间内） |
| g03.jpg | `Pictures\29EDA59B...096.jpg` | 1282×1920 | **60.2%** | 蓝底标准证件照，镜框 |
| g04.jpg | `Pictures\吴港+通信工程+...11.jpg` | 480×640 | **55.8%** | 蓝底证件照，中年男性（年龄段多样性） |
| g05.jpg | `Pictures\报名照片.jpg` | 295×413 | **58.2%** | 蓝底证件照，低分辨率小图 |
| g06.jpg | `Pictures\1 (2).jpg` | 2880×4982 → 缩放至 1184×2048 | **60.3%** | 真实复杂背景（楼道），原图超大按等比缩放至长边≤2048、JPEG q95 重存，sha256 已随之改变（记录在 `test/golden/mapping.json`） |
| g07.jpg | `Pictures\8D861A29...4124.jpg` | 1159×1920 | **64.2%** | 真实复杂背景，镜框+蓬松碎发（发丝抠图难点，肉眼看参考 alpha 边缘已有轻微毛刺） |
| g08.jpg | `Pictures\Camera Roll\WIN_2023...11_Pro.jpg` | 1280×720 | **21.0%** | 网络摄像头暗光室内自拍，杂乱背景（蚊帐/上铺），远低于其余 7 张——**连参考 alpha 本身在此图上也有明显噪点**（背景蚊帐/衣物边缘被误纳入前景），后续拿这张做 IoU 对比时如果分数偏低，不能排除是参考真值本身不够干净，不完全是被测实现的锅 |

**前景占比区间：21.0% ~ 69.2%，全部落在 8%–70% 自检要求内。**

其余 3 张 `portrait` 未入选（`8D861A29...4124 (自定义).jpg` 是 g07 的
裁切近重复版；`a.jpg` 是 g06/g07 同人同景同姿态的近重复帧；
`WIN_...19_21_Pro.jpg` 是 g08 的连续下一帧，画面几乎相同）——保留在
`test/dataset.json` 的 portrait 子集里参与阶段 4 全量回归，但不重复占
黄金集名额。

### 抠图困难点预判（人工目检）
- g02/g07：镜框反光 + 碎发边缘，蓝/绿底测试时最容易出现白边/绿边残留。
- g06/g07：背景非纯色（走廊墙面+窗户），依赖模型对复杂背景的区分能力。
- g08：暗光 + 低对比度 + 背景有大片浅色织物（蚊帐），前景/背景亮度接近，
  是本黄金集里最难的一张；且如上所述参考真值本身含噪声，需谨慎解读。

## 4. 产出文件清单
- `test/dataset.json`：80 项全量分类 + summary + 人工改判记录
- `test/batch/freeze_dataset.py`：扫描分类脚本（含排除目录理由、分类方法注释）
- `test/batch/build_golden.py`：黄金集构建脚本（含挑选/缩放/参考抠图/自检逻辑）
- `test/golden/src/g01.jpg`..`g08.jpg`：黄金集原图（JPEG）
- `test/golden/ref/g01.png`..`g08.png`：参考 alpha（单通道 8-bit PNG，同分辨率）
- `test/golden/mapping.json`：黄金集文件名 → 来源路径/sha256/是否缩放的映射

## 5. 遗留问题 / 给其他 agent 的信息
1. `profile`、`low_light` 两个 class 在真实数据集里各为 0 项，G4 按 class
   分组算成功率时这两类会是 0/0，不代表验证充分。
2. 全数据集 80 项 `exif_orientation` 全为 1，没有真实的旋转 EXIF 样本，
   orientation 处理只能靠 adversarial 合成用例验证。
3. g08 的参考 alpha 本身含噪声（暗光场景下 MODNet 参考实现表现也不佳），
   后续 IoU/MAE 指标如果这张明显偏低，需要人工复核是否是参考真值问题。
