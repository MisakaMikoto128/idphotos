# QA_batch_report_r5 — G4 第 2 轮 r5 复测：compose 流式化 c669d36 双口径（qa-batch，2026-09-15）

设备与构建：
- 模拟器 Pixel_3a_API_34（hostmem 预检通过 free 5.5GB / commit 50.4%），APK `flutter clean` 全量重建 debug（HEAD=c669d36，含 08144ab ORT arena 探针/EXIF 快路径 + c669d36 compose 流式化 + 1dcd35c 池纪律）。
- vivo X21A 真机：v5 release 双包自动安装成功（自动代点 ×2），leak 20 轮 app 侧完成（全 ready、6 候选、单张 ~5-7s），但 **batch 阶段 am start -W 两连超时（120s+180s 重试均挂）致脚本中止，真机 v5 数字未产出**（第三次于同一位置失败；详见 PITFALLS vivo 三连坑条目）。`out/metrics_r1_realdevice.json` 维持 pre-v4 参考版（4.6 p95 712.4 / 4.8 Δ+21.5 / 冷启 1873ms，快照早于 301434f/c0aed27/c669d36，不可用于 v5 终裁）。

## 模拟器 r4 → r5（c669d36 前后对照）

| 项 | 阈值 | r4 | r5 | 判定 |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0** | 达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 达标 |
| 4.3 非人像优雅 | 100% | 66/66 | **66/66 graceful**（扫描件 455ms 快速 NoFaceException，messageZh 到达） | 达标 |
| 4.6 抠图 p95 | ≤1500ms | 781.6ms | **783.2ms** | 达标 |
| 4.7 峰值内存 | ≤450MB | 570.4MB | **663.5MB** | **FAIL（恶化 +93.1MB）** |
| 4.8 回落 | 基线+80MB | +42.3MB | **+87.9MB**（421.5→509.4） | **FAIL（破线 +7.9MB）** |

## r5 回归定性（与 imaging 的"记账峰值 14.3MB"申报矛盾，如实报）

- 峰值 663.5 落在 chunk 0 的 item 17 窗口；进入时 PSS 511.2MB，条目增量 ~152MB（远超 r4 的 ~60MB）。
- 峰值 dumpsys：**Private Other 297.2MB**（r4 峰值 239.9）+ **Native Heap 332.7MB**（r4 283.6）——两个类目同时抬升。
- **瞬态性仍在**：批后末份 dump Private Other 174.3 / Native Heap 288.7，均回到首样水平——不是新驻留，而是**瞬态峰值被抬高**；但 4.8 的 Δ+87.9 又显示 leak 路径上确有 ~45MB 相对 r4 的额外滞留（421.5→509.4 的 settle 抬升）。两条证据合起来：流式化把"单点大缓冲"拆成了"更多小缓冲"，**峰值记账下降但进程实际 RSS 上升**（分配器碎片 + 并发存活 chunk），且 leak 路径多留了一份。
- imaging 申报口径（编码器记账峰值 12MP 60.2→14.3MB）与进程 PSS 口径（+93MB）背离——记账测的是"单时刻最大未释放分配"，进程看的是"分配器实际持有"。这本身就是回派给 imaging 的定位依据：**记账口径不能作为 4.7 的验收口径**。

## 结论

1. r5 模拟器：4.1/4.2/4.3/4.6 无回归达标；**4.7/4.8 双 FAIL，且相对 r4（池修复后最优态）双双恶化**——c669d36 在进程 PSS 口径上是净回归。
2. 各轮峰值/回落总表（模拟器同 workload）：r2 563.1/+36.4 → r3 638.9/+135.8 → r4 **570.4/+42.3（最优）** → r5 663.5/+87.9。
3. 给 gatekeeper 第 2 轮的裁决数据建议：4.7/4.8 以 **r4（1dcd35c）为当前最优已验证态**；c669d36 需回退或修复后重测（重测口径 = 本脚本 QA_ROUND 重跑，模拟器 12 分钟全自动）。
4. 模拟器固有 floor ~505MB（Native Heap ~282 模型/ORT 常驻 + Private Other ~175）在 r2-r5 四轮稳定复现，450 线在模拟器口径的可达性取决于 floor 压缩（ml-porting ORT 会话侧），与 compose 层无关——r4/r5 双轮数据反复证实。
5. 真机：v5 链路零人工但被 vivo am start 挂死阻断（三连，PITFALLS 已记）。pre-v4 真机参考（floor 389 / Δ+21.5）不支持"真机 floor 440+"假设，若 v5 修复后重跑，4.7 真机达标概率高（真机 floor ~390-420 + 流式化后瞬态），值得在 vivo 修复后补一次。

数据文件：`out/batch_r5.json`、`out/metrics_r5.json`、`out/mem_breakdown_r5.json`、`out/leak_r5.json`、`out/perf_r5.json`、`out/crash_r5.json`、`out/memdump_r5/`、`out/grid_r5_*.png`、logcat `out/logcat_*_r5.txt`。
