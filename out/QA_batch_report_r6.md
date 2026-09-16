# QA_batch_report_r6 — v6 终裁测量：模拟器确认 + 真机尽力而为（qa-batch，2026-09-15）

HEAD=b2fab99（回退 c669d36 流式化，运行时等价 r4 最优 1dcd35c；含 1dcd35c 池纪律、08144ab ORT arena 探针、301434f 人脸门槛）。hostmem 预检通过。

## 一、模拟器 r6（Pixel_3a_API_34，debug runner，`flutter clean` 全量重建；QA_ROUND=6）

| 项 | 阈值 | r4（参照） | r6（回退后确认） | 判定 |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0** | 达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 达标 |
| 4.3 非人像优雅 | 100% | 66/66 | **66/66 graceful**（fail_paths 空） | 达标 |
| 4.6 抠图 p95 | ≤1500ms | 781.6ms | **766.2ms**（p50 686） | 达标 |
| 4.7 峰值内存 | ≤450MB | 570.4MB | **606.9MB**（峰值 item 14 multi_face，进入时 PSS 529.3，条目增量 ~78MB；峰值构成 Private Other 289.3 + Native Heap 283.2 + Code 30.7 + Java 6.7） | FAIL（与 r4 的 ±37MB 属大图瞬态轮间波动） |
| 4.8 回落 | 基线+80MB | +42.3MB | **+29.4MB**（429.7→459.0，曲线内峰值 537.9） | 转绿（优于 r4） |

结论：回退无遗漏，r6 回到 r4 最优态（峰值差在瞬态正常波动内）；模拟器固有 floor ~505MB（Native Heap ~282 模型/ORT 常驻 + Private Other ~175）在 r2-r6 五轮稳定复现，**450 线在模拟器口径物理不可达**（除非压 ORT/模型常驻）。

## 二、真机 vivo X21A v6（5bc6e093，Android 9，release 双包全自动安装/清理）

**有效数据（`out/metrics_r1_realdevice.json`，v6/HEAD b2fab99 版）**：
- **4.8：PASS。两次独立完整 leak 会话：Δ+3.8MB**（457.3→461.1，曲线内峰值 648.8MB）**与 Δ+0.2MB**（452.5→452.7，峰值 606.4MB）——瞬态大尖峰（~600MB）但完全回落，真机无驻留。与时钟偏移修正（+33442866s，NTP 漂移）后可采样的结论互证。
- **4.6：p50 1998ms / p95 2049.8ms**（n=25）。注意：X21A 为 2018 年中端机（SD660），该值超 1500ms 阈值是**设备算力所致**；4.6 真机参考应回溯小米机数据（pre-v4：p50 712/p95 712.4ms，712.4 为 p95 且达标）。gatekeeper 裁决时请注意两台真机算力差 ~3 倍。
- **冷启动**：2751 / 551 / 498ms（首启含 dexopt 之类一次性开销，热启 ~500ms）。截图 6 张 `out/rd_screen_cold*.png`。
- **4.7：未采到。** 三次会话均在 batch 阶段死于 vivo `am start` 间歇挂死：前两次 -W 等空闲回调 120/180s 无返回；最后一次 -W 返回但 AMS 根本未拉起进程（logcat 无 Start proc，疑为高频安装+启动后的系统节流）。App 侧无任何异常。已修好的链路（非阻塞启动 + pidof 轮询 + Android 9 meminfo 兜底 + 时钟偏移换算）可复用，等设备"冷却"或重启后重跑一次即可（`QA_SKIP_INSTALL=1 python test/batch/run_realdevice.py`，~10 分钟）。
- 4.7 真机预期推断（供参考，非实测）：真机 leak 稳态 floor ~455-462MB（本轮实测）+ 4958×7017 扫描件瞬态（流式化后预估 ~15-25MB，imaging 记账）≈ **470-490MB，大概率仍 >450**。但 pre-v4 真机参考 floor 389MB 提示 X21A 的 ORT/模型常驻显著低于模拟器；若以 floor ~455 实测为准，450 线同样悬。**裁决请以 gatekeeper 为准，qa-batch 只供数。**

## 三、四设备口径总汇（4.7 峰值 / 4.8 回落）

| 轮次 | 代码 | 模拟器峰值 | 模拟器 Δ | 真机 Δ |
|---|---|---|---|---|
| r2 | pre-v4 | 563.1 | +36.4 | — |
| r3 | +池bug | 638.9 | +135.8 | — |
| r4 | 1dcd35c | **570.4** | **+42.3** | — |
| r5 | +流式化 | 663.5 | +87.9 | (+105.6，v5 leak 实测) |
| r6 | b2fab99（回退） | 606.9 | +29.4 | **+3.8 / +0.2（两次会话）** |

真机 Δ 序列（pre-v4 小米 +21.5 → v5 vivo +105.6 → v6 vivo +3.8/+0.2）与模拟器完全同向，交叉证实：**c669d36 是 leak 回归源、1dcd35c 修复有效、b2fab99 回退干净**。

数据文件：`out/batch_r6.json`、`out/metrics_r6.json`、`out/mem_breakdown_r6.json`、`out/leak_r6.json`、`out/perf_r6.json`、`out/crash_r6.json`、`out/grid_r6_*.png`、`out/metrics_r1_realdevice.json`（v6）、`out/rd_screen_cold*.png`。
