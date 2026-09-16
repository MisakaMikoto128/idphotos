# QA_batch_report_r4 — G4 第 2 轮 r4 复测：池修复 1dcd35c（qa-batch，2026-09-15）

设备与构建：模拟器 Pixel_3a_API_34（`-gpu guest -feature -Vulkan`，RAM 4096），hostmem 预检通过（free 7.9GB / commit 42.5%）；APK 为 `flutter clean` 全量重建 v5 debug（HEAD=1dcd35c，池生命周期纪律）。一次一台，跑完 `adb emu kill`。真机：因 4.7 未转绿，按指示未启动 vivo 重跑（链路全自动就绪，随时可补）。

## r3 → r4 判定数据

| 项 | 阈值 | r3（池 bug） | r4（1dcd35c） | 判定 |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0** | 达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 达标 |
| 4.3 非人像优雅 | 100% | 66/66 | **66/66 graceful**（messageZh 全到达，fail_paths 空） | 达标 |
| 4.6 抠图 p95 | ≤1500ms | 731.0ms | **781.6ms** | 达标（波动正常） |
| 4.7 峰值内存 | ≤450MB | 638.9MB | **570.4MB** | **仍 FAIL（回落 68.5MB）** |
| 4.8 回落 | 基线+80MB | +135.8MB | **+42.3MB**（413.5→455.8） | **转绿**（曲线内峰值 553.2） |

## 4.7 剩余超阈的细粒度归因（memdump_r4 109 份，分类目/跨时间对比）

- 峰值 570.4 落在 chunk 0 的 item 4（1979d869，4032×3024 multi_face PNG）窗口；进入该条目时 PSS 已 509.8MB（floor），条目增量 ~60MB。
- **floor（首份 >450MB dump，item 4 早段）：505.0MB** = Native Heap 282.4 + Private Other 175.7 + Code 29.0 + Java 6.5。其中 Native Heap 282MB 与 r2/r3 同期持平——模型/ORT arena/分配器滞留的固有 floor，非池引入。
- **峰值增量 +65.6MB 全部落在 Private Other（175.7 → 239.9）**；Native Heap 仅 +1.2，Java/Code/Stack 恒定。即 r4 的尖峰是**瞬态的图解码 + 抠图工作缓冲**（4032×3024 RGBA 解码 ≈ 48.8MB + matting 工作集），不是驻留。
- **瞬态性证明**：批处理结束后末份 dump Private Other 153.5MB，**低于首份 175.7**——spike 已完整释放，与 4.8 转绿（Δ+42.3）互为印证。
- 详细分配行未见单行 >8MB 的增长（Private Other 由大量 <8MB 映射组成，未细分到单一来源）。
- 块内轨迹：142（首样）→ 497（item 2）→ 570（item 4）→ 之后 470-560 波动。前 4 项是 floor 建立期（warmUp + 首批大图），其后稳定在 470-570 区间。

## 结论与回派建议

1. **4.8 转绿**：1dcd35c 池修复有效（+135.8 → +42.3），r3 的回归关闭。
2. **4.7 仍 FAIL（570.4 > 450）**，但性质已变：不再是"驻留累积"（4.8 已证），而是**固有 floor ~505MB + 大图瞬态 +65MB**。要过 450 线只剩两条路：(a) 压 floor（模型/ORT arena ~282MB Native Heap + ~175MB Private Other 常驻，是 ml-porting 的 ORT 会话配置/量化布局问题）；(b) 压瞬态峰值（大图处理路径的峰值并发缓冲，premul 数据流重设计属于此列）。数据支持 gatekeeper 在第 2 轮就 4.7 出 FAIL、4.8 出 PASS。
3. 4.3/4.2/4.1/4.6 无回归（人脸门槛/NoFaceException 语义沿用 r3 结论：66/66 graceful + messageZh，item 60 已优雅失败）。
4. 观察点网格 `out/grid_r4_watchpoints.png` 与 r3 持平（14 发梢碎块、36/37 毛巾碎片仍在，非本轮回派范围）。

数据文件：`out/batch_r4.json`、`out/metrics_r4.json`、`out/mem_breakdown_r4.json`、`out/leak_r4.json`、`out/perf_r4.json`、`out/crash_r4.json`、`out/memdump_r4/`（109 份）、`out/leak_curve_r3_vs_r4.png`（池修复前后 leak 曲线对比）、`out/grid_r4_*.png`。
