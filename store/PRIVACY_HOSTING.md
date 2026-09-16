# 隐私政策托管说明（PRIVACY_HOSTING）

Play Store 的"隐私政策"字段**必须填写一个公网 URL**，本地文件不被接受。
以下给出三种方案，推荐方案 A（免费、5 分钟、无需服务器）。

## 方案 A：GitHub Pages（推荐）

1. 在 GitHub 新建一个公开仓库，例如 `muzao-privacy`（也可以放进项目仓库的 `gh-pages` 分支）。
2. 把 `store/privacy_policy_zh.md` 和 `store/privacy_policy_en.md` 复制进去。
   **GitHub Pages 不渲染 `.md` 的自定义样式也可接受**（会自动用 Jekyll 渲染），
   如需更规整，可用任意 Markdown→HTML 工具转成 `privacy-zh.html` / `privacy-en.html`。
3. 仓库 Settings → Pages → Source 选 `main` 分支 `/ (root)`，保存。
4. 约 1 分钟后生效，URL 形如：
   - `https://<你的用户名>.github.io/muzao-privacy/privacy_policy_zh`
   - `https://<你的用户名>.github.io/muzao-privacy/privacy_policy_en`
5. 在 Play Console 的 App content → Privacy policy 里填上英文版 URL（中文版可放在完整描述或作为附加链接）。

**注意**：Play 政策要求隐私政策 URL 对审核员可访问，公开仓库即可满足；不要设为私有。

## 方案 B：任意静态托管

Cloudflare Pages、Netlify、Vercel 免费档均可，步骤同上（上传两个文件，得到 URL）。
国内访问 GitHub Pages 有时不稳定，若主投中国大陆商店可优先考虑 Cloudflare Pages。

## 方案 C：自有域名/服务器

上传到任何你能控制的服务器即可，要求：

- HTTPS（Play Console 会校验可访问性）
- 无需登录即可查看
- 内容与本目录的两份政策一致

## 填写位置

Play Console → 左侧"政策"（Policy）→ App content → **Privacy policy**：
填 URL，语言选英文（或与主要受众一致的语言）。

> 本文件只是操作指引，**实际托管动作需用户手动完成**（见 CHECKLIST.md"需用户手动"一节）。
