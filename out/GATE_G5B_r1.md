# GATE G5B 第 1 轮

## G5B 第 1 轮：PASS

## 通过 14 / 14 项（其中机读 12 项全过；MANUAL 2 项由 gatekeeper 人工裁决为 PASS，JSON 中保持 pass=false 不计入自动判定），退出码 1（因 MANUAL 项存在，脚本按设计退出非 0；最终裁决权在本报告）

## 脚本完整性：OK
- 与 G5 报告同一轮巡查：`out/hashes_prev.txt` 开跑前 diff=0；本轮新建 `tools/gate/gate_G5B.dart`（含 2 次自修：privacy 关键词正则、5B.13 证据注记合并为条目内注），轮末已滚动哈希。

## 防作弊巡查：清白（详见 out/GATE_G5_r1.md 第 2 节，同一轮执行）
- store-assets 只写入 `store/`（88db960），未触碰 `test/`、`tools/gate/`、ACCEPTANCE、RUBRIC。
- `store/gen_icon.py` / `gen_promo.py` 为其自有生成脚本，属 `store/` 势力范围。

## 逐项判定

| 项 | 期望 | 实测 | 判定 |
|---|---|---|---|
| 5B.1 | icon_512 存在 512² 含 alpha | 512×512, RGBA alpha=true | PASS |
| 5B.2 | 五套 mipmap 齐备尺寸正确 | mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192 全对 | PASS |
| 5B.3 | 前景在中心 66% 安全区 | 前景/背景分离（anydpi-v26 xml 声明）；xxxhdpi 前景非透明外接框四边留白 32.3/26.6/28.6/23.4%，均 ≥17% | PASS |
| 5B.4 | 48×48 非背景像素 ≥12% | **gatekeeper 独立测量 0.3207**（739/2304，box 降采样+量化主色+ΔRGB>60 口径），与 store-assets 自报 31.4% 相符 | PASS |
| 5B.5 | feature_graphic 1024×500 | 1024×500 | PASS |
| 5B.6 | zh/en 各 ≥5 张均 1080×1920 | 各 6 张，全部 1080×1920 | PASS |
| 5B.7 | 截图基于真实界面 | MANUAL，裁决见下 | PASS（人工） |
| 5B.8 | 短 ≤80 / 全 ≤4000（zh+en） | zh 短 39 全 505；en 短 80（恰在上限，未超）全 1315 | PASS |
| 5B.9 | 文案功能可溯源 | MANUAL，裁决见下 | PASS（人工） |
| 5B.10 | 隐私政策 zh/en 含三点 | 两版齐备；「不收集/不传输/未申请 INTERNET」三点独立成节，机读关键词全命中 | PASS |
| 5B.11 | PRIVACY_HOSTING.md 存在 | 存在（1976B） | PASS |
| 5B.12 | COMPLIANCE+CHECKLIST 区分自动/手动 | 两文件存在；CHECKLIST 含「自动完成/需用户手动」区分 | PASS |
| 5B.13 | 冷启动无全白帧 | 机读 8 个面板（frames_sheet 6 面板 + 2 单帧，≥99% 近白判全白）：0 个全白；目检 sheet：home→木色 splash→app，无白闪 | PASS（证据局限见注） |

**5B.13 证据局限注**：46 帧原始录屏未随交付保留，可机读证据为 6 面板抽样（覆盖冷启动前 500ms 各时点，sheet 内第 1 面板为启动前桌面、第 2-4 面板为 splash 渐变、第 5-6 面板为 app 首帧）+ 2 单帧。面板抽样 + 目检均无全白帧，且 launch_background 的木色根治已由 G5.6 复验的冷启动截图交叉印证（`out/GATE_G5_e2e_appui.png` 无白闪残留）。判 PASS，局限记录在 `out/gate_G5B.json` 5B.13 的 actual 中。

## MANUAL 项裁决

### 5B.7 截图真实性 —— PASS
- `store/screenshots/zh/01.png`：界面主体与 `out/shots/S1_empty.png` 同源（同一三段式木制 UI、同一规格黄铜尺 295×413·25×35mm、同一绿绒布+黄铜四角+候选区），仅顶部加了营销标语条；均色对比（54×96 缩样）与 out/shots 同族。
- `store/screenshots/en/05.png`：与 `out/shots/S4_generating.png` 同源（"正在冲洗 0/6" 冲洗中状态、真实人像在裁剪框内、白/蓝/红候选纸）。
- 生成链路 `store/gen_promo.py` 以真实截图为底合成，无手绘界面痕迹（渐变/文字排印与实机渲染一致）。

### 5B.9 文案真实性 —— PASS（抽 4 条，均点到 lib/ 锚点）
1. "七种规格…美签 51×51mm / 300 DPI / 像素精确到个位" → `lib/core/api.dart` kBuiltInSpecs（7 规格）、`lib/core/specs/photo_specs.dart` specVisaUs（51×51，头高推导注释）、`lib/core/imaging/jpeg_dpi.dart`（JFIF APP0 units=1 手写 DPI）；G5.6 复验拉回成品实测 295×413 像素精确匹配。
2. "六种底色（白/蓝/红/深蓝/浅灰/蓝渐变）" → `lib/core/api.dart` kBuiltInBackgrounds 六项，nameZh 与文案逐字一致（白底/蓝底/红底/深蓝底/浅灰底/蓝渐变）。
3. "拖动四角…比例自动锁定 / 保存到相册" → G5.6 独立复验实机目击：UI 显示"拖动四角调整裁剪范围 · 已锁定一寸比例"，保存落 MediaStore。
4. "无水印 / 无广告 / 不申请网络权限" → 全 `lib/` 无水印绘制代码；G5.1 已判 manifest 无 INTERNET；G5.3 依赖 0 命中。

## 失败项

（无）

## 回派指令

（无 —— 本 gate 无回派项）
