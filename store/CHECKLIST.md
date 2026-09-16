# 上架清单（CHECKLIST）

分两栏：**已自动完成**（本 agent 产出，附文件路径）与**需用户手动**（无法自动化，逐条写明去哪/多久/多少钱/有什么坑）。

---

## 一、已自动完成

| 事项 | 文件 |
|---|---|
| G5B.1 商店主图标 512×512 RGBA | `store/icon_512.png` |
| G5B.2 启动器图标五套密度（48/72/96/144/192px） | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` |
| G5B.3 自适应图标（前景在中心 66% 安全区内，已脚本实测） | `android/app/src/main/res/mipmap-*/ic_launcher_foreground.png`、`mipmap-anydpi-v26/ic_launcher.xml`、`drawable/ic_launcher_background.xml` |
| G5B.4 48×48 缩略自检（非背景像素 31.4% ≥ 12%） | `store/icon_48_thumb_check.png` |
| G5B.5 功能图 1024×500（重要内容居中 80%） | `store/feature_graphic.png` |
| G5B.6/7 宣传截图 1080×1920 ×6 ×2 语言（基于 out/shots 真实界面合成） | `store/screenshots/zh/01..06.png`、`store/screenshots/en/01..06.png` |
| G5B.8/9 商店文案（短描述/完整描述均实测达标） | `store/listing/zh/listing.md`、`store/listing/en/listing.md` |
| G5B.10 隐私政策（不收集/不传输/无网络权限三点齐备） | `store/privacy_policy_zh.md`、`store/privacy_policy_en.md` |
| G5B.12 合规表单答案（Data Safety 逐项/分级问卷/受众） | `store/COMPLIANCE.md` |
| 素材再生成脚本（可复跑） | `store/gen_icon.py`、`store/gen_promo.py` |

---

## 二、需用户手动（按先后顺序）

| # | 事项 | 去哪 | 要多久 | 要多少钱 | 坑 |
|---|---|---|---|---|---|
| 1 | **Google Play 开发者账号注册** | play.google.com/console → 注册 | 当天；首次发布需 14 天封闭测试+12 名测试者（2023-11 后新个人账号政策） | **$25** 一次性 | 新个人账号必须先跑封闭测试轨道：14 天、至少 12 名测试者持续选择加入，**这个周期没法压缩**，尽早开始 |
| 2 | **隐私政策挂公网 URL** | 见 `store/PRIVACY_HOSTING.md`（推荐 GitHub Pages） | 5 分钟 | 免费 | 本地文件不被接受；URL 必须无需登录可访问 |
| 3 | **内容分级问卷** | Play Console → App content → Content rating | 10 分钟 | 免费 | 按 `store/COMPLIANCE.md` 第 2 节逐题作答，预期"所有人" |
| 4 | **Data Safety 表单** | Play Console → App content → Data safety | 15 分钟 | 免费 | 全部选"不收集/不共享"；理由见 `store/COMPLIANCE.md` 第 1 节 |
| 5 | **上传 AAB 并发布** | Play Console → Production/Closed testing | 上传 10 分钟；审核 1–7 天 | 免费 | 用 release 产出的 `.aab`（G5.4）；首个版本建议走封闭测试轨道 |
| 6 | **签名密钥保管** | 本地 + 离线备份 | 10 分钟 | 免费 | 若用 Play App Signing 则上传密钥泄漏风险低，但**本地 keystore（*.jks）务必冷备份**；key.properties/`.jks` 已要求在 `.gitignore`（G5.7），不要提交仓库 |
| 7 | **中国大陆商店：软著申请**（华为/小米/OPPO/vivo/应用宝硬性前置） | 中国版权保护中心 ccopyright.com.cn 自行申请，或委托代理 | **约 30–60 天**，加急另付费 | 官方约 250–300 元；代理总价常见 300–600 元 | **无法自动化，必须线下办理**；需源代码前后各 30 页 + 用户手册；软著名义须与开发者账号实名一致。**周期最长，最先启动** |
| 8 | 中国大陆商店：App 备案（工信部） | 通过云服务商（阿里云/腾讯云）代备案 | 1–3 周 | 域名+轻量服务器约 100 元/年 | 2023 年起新 App 无备案号不能上架国内商店；备案主体须与账号实名一致 |
| 9 | 中国大陆商店：逐家注册开发者后台并提审 | 华为 AppGallery / 小米 / OPPO / vivo / 应用宝 | 每家审核 1–3 天 | 华为免注册费，其余多数免费；部分需企业资质（个人账号可发的品类有限） | 各家对个人开发者开放度不同；隐私政策 URL 同样必填 |

> 顺序建议：**1、7 并行启动**（1 有 14 天观察期、7 有 30–60 天周期，两者都是长周期项），
> 2–5 在等待期间完成。
