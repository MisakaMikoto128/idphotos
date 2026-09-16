# QA_batch_report_r3 — G4 第 2 轮 v4 终裁数据（qa-batch，2026-09-15）

设备与构建：
- 模拟器：Pixel_3a_API_34（emulator-5554，`-gpu guest -feature -Vulkan`，RAM 4096）；APK 为 `flutter clean` 后全量重建的 v4 debug（HEAD=da71686，含 301434f 人脸门槛/内存压缩 + c0aed27 WorkBufferPool + controller 修复），hostmem 预检通过（free 9.3GB / commit 39.9%）。
- 真机：vivo X21A（5bc6e093）替代小米机；v4 全自动安装链路已验证（自动代点确认框），但 **am start -W 间歇性 120-180s 挂死（两轮复现）**，按"尽力而为不恋战"纪律中止真机终裁。vivo 上留有 pre-v4 参考数据（`out/metrics_r1_realdevice.json`：4.6 p95 712.4ms / 4.8 Δ+21.5MB / 冷启动 1873ms，代码快照早于 v4 提交，仅参考）。

## v4 模拟器判定数据（r2 → r3 对照）

| 项 | 阈值 | r2（v3 码） | r3（v4 码） | 判定 |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0** | 达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 达标 |
| 4.3 非人像优雅 | 100% | 66/66（45 错误 + 21 提示+候选） | **66/66 全优雅失败**，messageZh 全部到达 | 达标（行为变化见下） |
| 4.6 抠图 p95 | ≤1500ms | 909.6ms | **731.0ms** | 达标（-20%） |
| 4.7 峰值内存 | ≤450MB | 563.1MB | **638.9MB** | **FAIL（恶化 +75.8MB）** |
| 4.8 回落 | 基线+80MB | +36.4MB | **+135.8MB**（397.7→533.5） | **FAIL（恶化 +99.4MB）** |

## 4.7 / 4.8 构成拆解（r3，如实报）

- **块内累积，非单点尖峰**：chunk 0 内 PSS 从首样 145MB 一路爬到 638.9MB（20 项）。全局峰值落在 item 19（IMG_20230115_132101.jpg）窗口，进入该条目时 PSS 已 597.5MB，**单条目自身增量仅 ~41MB**。
- 峰值时刻 dumpsys 分类（`out/memdump_r3/`）：**Private Other 303.9MB**（r2 峰值时 202.6MB，+100MB）+ Native Heap 331.8MB + Code 29.5MB + Java 6.7MB。Private Other 的异常增长与 WorkBufferPool 的跨调用缓冲保留在时间线上吻合，但**归因判定权在 gatekeeper/ml-porting**，我只报时间线相关性。
- **4.8 证据链**：同一进程连跑 20 张人像（leak_items 全 ready、全 6 候选，单张 5.0-7.4s），基线 397.7 → 回落 533.5，**Δ+135.8MB**。r2 同 workload Δ+36.4。r2→r3 唯一代码差 = 301434f + c0aed27（+controller）。**嫌疑最大者是 c0aed27 的缓冲池不收缩**（其设计目标是"复用省 30-50MB"，实测方向相反），需 ml-porting/imaging 会审池的收缩策略。
- 对照：真机 pre-v4 快照 leak Δ+21.5MB（弱机型 arm64），说明滞留不是设备固有，是 v4 模拟器路径引入/放大。

## 观察点（`out/grid_r3_watchpoints.png`，与 r2 对照）

1. item 4（五人合影）：与 r2 持平（选脸/头顶正确）。
2. item 14：邻人发梢碎块仍在（r2 同样）——未恶化未修复。
3. item 36/37（横图）：构图正常，毛巾碎片仍进 6 候选（r2 同样）。
4. **item 60（电路板）已解决**：v4 人脸门槛让无人脸图在 matting 阶段直接 NoFaceException 优雅失败，不再产出碎片候选（r1 悬案关闭）。行为变化：r2 的 21 项"提示+候选"现全部走 graceful_error，messageZh="没找到人脸，请手动框选" 全到达。是否合于 CONTRACTS 的 NoFaceException"仅提示不阻断"语义，请 gatekeeper 裁决（从 4.3 验收文字看是更优解：不崩溃、有中文提示、无诡异产出）。
5. 扫描件 4958×7017：现在 455ms 快速 NoFaceException 失败（r2 是 MattingException 1797ms）——该图本无人脸，语义更准确。

## 性能（附带）

matting p95：screenshot 878ms / landscape 748ms / portrait 2829ms（r2: 2038/2381/1782——人像类变慢 ~1s，与缓冲池首次填充成本的时间线吻合，供归因参考）/ multi_face 2661ms。total p95 全线 <6.1s。

## 结论

v4 在 4.1/4.2/4.3/4.6 上达标且 4.3/4.6 有实质改善；但 **4.7（638.9）与 4.8（+135.8）双双 FAIL 且相对 r2 恶化**，恶化方向与 WorkBufferPool 的保留策略时间线吻合。若按 ACCEPTANCE 4.7/4.8 判，第 2 轮 FAIL；回派方向建议聚焦 c0aed27 池收缩（或回退该笔单独验证）。真机通道已全自动就绪（vivo + 自动代点 + logcat 通道），只差 v4 修复版构建后一次重跑（唯一残留阻障：vivo am start 间歇挂死，重试即可）。

数据文件：`out/batch_r3.json`、`out/metrics_r3.json`、`out/mem_breakdown_r3.json`、`out/leak_r3.json`、`out/perf_r3.json`、`out/crash_r3.json`、`out/memdump_r3/`、`out/grid_r3_*.png`、logcat `out/logcat_*_r3.txt`。
