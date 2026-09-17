# VISUAL_DOUBAO — 阶段 6 美术升级素材快审（visual-critic）

## 总分：6.5 / 10        致命项：1 项（待重拍确证）
## 结论：FAIL

审查对象：`store/doubao/icon_512_doubao.png`(512×512) / `store/demo_pair.png`(1220×850) /
`assets/images/mascot_about.jpg`(1255×1109) / `store/feature_graphic.png`(1024×500)。
`out/shots/S7_about.png` 为旧版关于页（无立绘），按指令跳过界面审查，仅审素材本体。

## 致命项

- [F1] mascot_about.jpg 嵌入 about_sheet 后预测发生"眼部以上被裁切"（RUBRIC 致命 #7 元素被裁切）。
  证据：`lib/ui/widgets/about_sheet.dart` L165-172 —— `ClipRRect(height:132, width:∞, fit:BoxFit.cover)`，
  未写 alignment，走默认 center。素材 1255×1109（比例 1.13），人脸集中在画面上部：
  眼睛约 y 260-310，嘴约 y 380（本文件配套放大图 out/tmp/mascot_head.png 可证）。
  几何推算：卡内宽 320dp（底部弹层 360dp 减 padding 20×2）时，缩放后图高约 283px，
  center 裁窗为源图 y 311-798 —— 眼睛整条被切掉，只剩鼻子以下。盒宽 >302dp 即触发。
  S7 是旧版截图无法目视确证，判"待重拍确证"；修法零成本（见修复指令 1），无论实测结果如何都应改。

## 扣分明细

- [完成度 -1.0] icon_512_doubao.png：左上角白色楔形残块，源坐标约 x 38-58, y 0-16，
  硬边锯齿状（放大证据 out/tmp/icon_TL_zoom.png）；另左下角 x 0-6, y 508-512 与右下角
  x 500-511, y 505-512 各有一撮白色残点（out/tmp/icon_BL_zoom.png / icon_BR_zoom.png）。
  全图扫描共 213 个近纯白像素，其中 y 240-272 的为眼部高光属正常，边缘这三处是生成/抠角残渣。
  圆形自适应图标遮罩会遮掉它们，但方形 legacy 图标与 .ico 会原样露出 —— 这是进 mipmap 的生产素材，必须除净。
- [角色一致性 -1.0] feature_graphic.png：主角发型与其它三图不符 —— 此图为脑后单低髻
  （头顶平滑、耳后一团发髻，证据 out/tmp/feat_head.png，源区约 x 740-960, y 0-180），
  而图标 / demo_pair 两帧 / mascot_about 均为头顶双丸子头。功能图是商店首屏，吉祥物身份对不上是品牌硬伤。
- [角色一致性 -0.5] 外套四图四款：图标立领无扣、demo_pair 左帧铜扣排扣外套、
  demo_pair 右帧银拉链夹克（x 1050-1120, y 620-720 拉链头清晰可见）、mascot_about 连帽牛角扣大衣。
  "绿外套+黄铜扣"的识别锚点在右帧被银色拉链替代。
- [风格统一 -0.5] 四张图三种画风：图标为平涂贴纸风（大椭圆眼、粗描边），
  demo_pair 为柔和水彩厚涂，mascot_about 为明亮现代日漫（眼距/五官比例均不同）。
  单看各自成立，摆进同一家店像三个画师各画各的。
- [色彩纪律 -0.5] icon_512_doubao.png 背景木板实测 (71,25,9)（采样点 20,480），
  与 DESIGN.md 最近 token woodDark #3E2A1B 的 ΔE=15.7 —— 偏红发黑，与 App 工作台的核桃棕明显两个色系。
  demo_pair 分隔条 (62,42,27) 反而与 woodDark 完全一致，说明问题只在图标。

## 已检查且合格

- 水印：四张图 4 角 + 底部水印带逐一放大（out/tmp/*_TL/TR/BL/BR.png、pair_bottom.png、
  mascot_bottom.png），均无"AI 生成"角标或任何半透明水印残留。demo_pair 上的白色楔形残块不在其上，仅图标有。
- 文字对比度（feature_graphic 实测 WCAG 公式）：标题 10.23:1、标语 6.92:1、第三行 4.69:1，全部 ≥4.5:1。
- demo_pair 文字渲染：宋体字形完整无豆腐块，笔画干净（out/tmp/pair_text_L/R.png）。
- demo_pair 构图：两帧等宽相近、棕色分隔对齐 woodDark、右帧证件照头顶留白合规，无溢出无裁切事故。
- 蓝底一致性：demo_pair 右帧底色 (92,155,206) 与 App 实际蓝底候选（S5 实测约 66,138,212）同族，属产品内容色，不违纪。
- mascot_about.jpg 底色四角实测 (252,243,226)/(251,242,225)，贴近 paper token，非纯白。
- 图标 48px 缩略（out/tmp/icon_48_x4.png）：黄铜椭圆框+深发剪影可辨，主体占画面约 78%×93%，安全区占比合格。

## 修复指令（按影响排序）

1. `lib/ui/widgets/about_sheet.dart` L167-171 的 `Image.asset` 增加 `alignment: Alignment.topCenter`，
   或交付方另出一张方形半身特写替换现素材 —— 消除 F1 裁眼风险，改后重拍 S7 送审。
2. 图标重新导出或修补：除净左上白色楔形（x38-58, y0-16）与两下角白色残点，导出后复查全图近纯白像素应仅剩眼部高光。
3. feature_graphic 用双丸子头版本重新生成（其余构图、文字、色调可保留），保证与图标/关于页同一发型。
4. 统一"绿外套 + 黄铜扣"锚点：demo_pair 右帧换回带铜扣的证件照版本，避免银拉链稀释识别特征。
5. 后续生成时收敛画风提示词（同一画风关键词 + 同一角色描述串），四张图尽量同一渲染风格；
   图标背景木色向 woodDark/woodBase 靠拢，去红调。
