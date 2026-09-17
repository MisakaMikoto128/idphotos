# WIN_report2 — Windows 宽高比锁定 / 图标 / release 重建（2026-09-16，Windows 专员）

## 1. 宽高比没有锁定：排查结论与修法

排查结论（WM_SIZING 处理器本身是对的，真实拖拽走的是它）：

- **WM_SIZING 确实会在用户拖拽边框时触发**。临时在处理器里加文件日志（验证后已删除），
  用 PowerShell + user32 `mouse_event` 模拟真实拖拽（抓右下角、只横向移动），日志逐条记录
  `newh = cw × 2220/1080`，计算精确成立。debug 与 release 实测各 18 次触发、无一遗漏。
- 用户"实测没锁"的三个真实破口，本次全部修掉：
  1. **最大化**：屏幕工作区是横的（本机 2048x1280），最大化跟随屏幕必然破坏 1080:2220。
     修法：`WM_SIZE` 收到 `SIZE_MAXIMIZED` 时，Flutter 子视图改为**居中显示保持比例的最大
     可用尺寸**（letterbox），四周留边用 `WM_ERASEBKGND` 填 woodDark `#3E2A1B`
     （docs/DESIGN.md 色卡，非自创色值）。
  2. **拖到屏幕底边**：推算高度可能超出工作区，系统顶回时比例必破。修法：WM_SIZING 里
     用 `MonitorFromWindow` + `GetMonitorInfo(rcWork)` 把推算高度 clamp 到工作区可用高度。
     副作用（符合预期）：窗口宽度超过"工作区高 × 1080/2220"（本机约 600 逻辑 px）后
     比例让位于屏幕物理极限，窗口无法再变宽等比变高。
  3. **初始尺寸 1280x720 是横屏**（WM_SIZING 只在拖拽时触发，创建时不起作用）。
     修法：`main.cpp` 初始客户区改为 420x863 逻辑 px（= 1080:2220）；
     `WM_GETMINMAXINFO` 的最小宽从 380 调到 395（与最小高 810 同比例）。

### 自动化验证（脚本见文末留档，debug 与 release 各跑一轮）

| 测试 | 实际读数 | 判定 |
|---|---|---|
| release 拖宽（右下角横向 +80px） | 客户区 465x956，ratio 0.4864 vs 目标 0.48649，误差 **0.2px** | PASS（±8px 线） |
| release 拖窄（横向 −64px） | 客户区 401x825，ratio 0.48606，误差 **0.7px** | PASS |
| debug 同两项 | 525x1080（0.48611）/ 401x825 同上 | PASS |
| 最大化 | Flutter 子视图 588x1209，ratio **0.48635**（居中 letterbox） | PASS |
| `SetWindowPos(1200x900)` | 读回 1185x862，WM_SIZING 触发次数 0→0 | 按设计旁路，非 bug |

注意：`SetWindowPos` 等**编程式改尺寸不经过 WM_SIZING**（Win32 设计如此，只有用户交互
拖拽才发），所以"用 SetWindowPos 设非比例尺寸读回验证"这一思路本身测不出处理器——
必须用 `mouse_event` 模拟真实拖拽。本报告的验证脚本已按此实现。

## 2. 图标没有更换：exe 资源已是新图标，问题在 Windows 图标缓存

- 证据：对刚构建的 release exe 执行
  `[System.Drawing.Icon]::ExtractAssociatedIcon('...\Release\muzhao.exe')` 提取并转 PNG，
  得到的是**豆包新图标**（金色椭圆相框 + 木底 + 木木头像）。资源链
  `Runner.rc → IDI_APP_ICON → resources\app_icon.ico` 完好，ico 内含 7 档尺寸
  （16/24/32/48/64/128/256）。exe 构建时间 2026-09-16 21:41（本次重建）。
- 结论：exe 里的图标是新的，用户看到旧图标 = **Windows 图标缓存未失效**。

### 用户侧清理图标缓存（任选其一，先关掉正在运行的旧 exe）

1. 快捷方式（通常够用）：
   `ie4uinit.exe -show`（Win10/11），再刷新桌面（F5）。
2. 彻底重建缓存（管理员不需要，当前用户即可）：
   ```powershell
   Stop-Process -Name explorer -Force
   Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force
   Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
   Start-Process explorer
   ```
3. 若桌面/开始菜单的**快捷方式**指向旧路径的 exe，删掉快捷方式重建一个（快捷方式
   自带图标缓存，有时光清系统缓存不够）。

## 3. release 重建结果

- `flutter build windows --release` 成功（53.5s，未 clean，无 junction 问题）。
- 产物：`build\windows\x64\runner\Release\muzhao.exe`
  （SHA256 前 16 位 C1A80674A4532247）。
- 启动验证：脚本拉起 release exe → 主窗口句柄就位 → `EnumChildWindows` 找到 Flutter
  子视图 → 比例验证全过（上表）→ 进程正常退出（脚本 force kill）。无崩溃、无退出码异常。

## 4. 验证脚本留档

`%TEMP%\verify_win_ratio.ps1`（本机路径 `C:\Users\liuyu\AppData\Local\Temp\`，重跑：
`powershell -ExecutionPolicy Bypass -File verify_win_ratio.ps1 -ExePath <exe路径>`）。
关键段（Add-Type P/Invoke 定义从略，完整文件在 TEMP）：

- 真实拖拽：`GetWindowRect` 定位右下角 → `SetCursorPos` 到角内 4px →
  `mouse_event(0x0002)` 按下 → 分步 `SetCursorPos` 横向移动 → `mouse_event(0x0004)` 抬起
  → `GetClientRect` 读回客户区 → 与 1080/2220 比对，容差 ±8px。
- 最大化：`ShowWindow(hwnd, 3)` → `EnumChildWindows` 取 Flutter 子视图 `GetWindowRect`
  → 比对应仍为 0.4865。
- 判定函数按 `expected_h = client_w / (1080/2220)`，`|actual_h − expected_h| ≤ 8px` 出
  PASS/FAIL。

## 5. 改动文件清单

- `windows/runner/win32_window.cpp`：WM_SIZING 工作区 clamp；新增 WM_ERASEBKGND
  （letterbox 底色）；WM_SIZE 最大化分支（子视图比例居中）；最小宽 380→395。
- `windows/runner/main.cpp`：初始窗口 1280x720 → 420x863。
- 临时 WM_SIZING 日志宏已按计划删除（release 构建不含），未触碰其他目录。

## 6. 遗留/提醒

- 主会话收口时请 commit（本 agent 按纪律未 commit）。
- 用户若仍见旧图标，按 §2 清缓存；exe 本身已验证为新图标。
- 屏幕工作区限制：本机（2048x1280）上竖版窗口最大只能拖到约 600 逻辑 px 宽，这是
  物理极限不是 bug；接 4K 竖屏可等比放大。
