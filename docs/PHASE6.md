# 阶段 6 — 开源发布工程（规划）

主会话写入。阶段 5（G5/G5B PASS）之后的开源化与多平台阶段。
验收不走 ACCEPTANCE 门禁（那套是商店上架口径），走本文件的工作流验收 + 既有裁判复核。

## W1 App 关于页面（ui-woodcraft + 主会话接线）
- 三段式外的新路由/入口（设置区或长按 logo），不得破坏三段式布局红线
- 内容：应用名/版本、**作者：刘沅林**、隐私承诺（不收集/不传输/无网络）、
  开源许可（OFL 字体）、GitHub 仓库链接
- 验收：visual-critic 复审风格一致性（材质/色卡不破）；dart analyze 干净

## W2 Windows 桌面版（ml-porting + release + 主会话平台适配）
- `flutter config --enable-windows-desktop` + windows/ 脚手架
- 平台适配（接线层）：相册取图 → file_selector（Windows 无系统相册）；
  保存 → 文件另存为对话框（gal 不支持 Windows）
- ORT on Windows：onnxruntime 插件不支持 Windows——ml-porting 评估
  FFI 直连 onnxruntime.dll 或官方 C API 封装；模型资产复用
- 窗口：标题"木照"、最小尺寸、DPI 适配
- 验收：Windows release 构建成功 + 完整出图 e2e + 黄金集回归

## W3 GitHub Pages 发布页（store-assets + web）
- 单页站点（纯静态 HTML/CSS，无构建依赖），复古木制风格与 App 一致
- 响应式（桌面/手机）、演示截图轮播、功能特性、**下载 APK 按钮**
  （指向 GitHub Releases）、隐私承诺、作者署名
- 素材：store/screenshots 真实界面 + 官方截图
- 验收：visual-critic 审风格；链接可达性检查（本地校验）

## W4 仓库现代化（主会话）
- README.md（zh 为主 + en 节选）：截图、特性表、构建方法、隐私承诺
- LICENSE（代码 MIT，作者刘沅林；字体 OFL 单列）
- .github/workflows：CI（analyze+test）与 release（tag 触发，附 APK）
- CONTRIBUTING.md、issue/PR 模板、.gitignore 复核
- **提交史清除 Claude co-author 痕迹**（git filter-repo 剥离
  Co-Authored-By 尾注，保留作者刘沅林身份）——在全部阶段 6 提交完成、
  打 v1.0.0 tag 之后执行（仓库无远程，重写安全）

## 顺序与验证
W1 ∥ W3 ∥ W4 并行 → W2（最长）→ 裁判验证（visual-critic / qa-batch /
gatekeeper 复核）→ v1.0.0 tag + release notes → filter-repo 清史 → 收官。
推送到 GitHub 需用户提供仓库 URL（主会话不擅自 push）。
