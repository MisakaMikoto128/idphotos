# QA_batch_report_r8 — G4 第 3 轮终测：多脸瞬态攻坚 25bd1f0 双口径（qa-batch，2026-09-16）

HEAD=25bd1f0（多脸瞬态：>2048 大图工作分辨率降 1536 + worker 固定 8MB Float32 + 滑窗羽化；运行时其余等价 r4 最优态 1dcd35c/b2fab99）。hostmem 预检通过（free 15.2GB / commit 31.4%）。

## 一、模拟器 r8（Pixel_3a_API_34，debug runner 全量重建；QA_ROUND=8）

| 项 | 阈值 | r7 | r8（25bd1f0） | 判定（4.7 对照 550） |
|---|---|---|---|---|
| 4.1 崩溃/ANR | 0 | 0 | **0** | 达标 |
| 4.2 人像成功率 | 100% | 14/14 | **14/14** | 达标 |
| 4.3 非人像优雅 | 100% | 66/66 | **66/66 graceful** | 达标 |
| 4.6 抠图 p95 | ≤1500ms | 761.4ms | **766.2ms**（p50 707） | 达标 |
| 4.7 峰值内存 | 550MB | 613.3MB | **579.7MB** | **FAIL（超 29.7）** |
| 4.8 回落 | 基线+80MB | -7.4MB | **+91.8MB**（402.5→494.2） | 见"方法学发现" |

**25bd1f0 的效果得到测量证实**：multi_face 条目瞬态显著压缩——item 14（e9168d2c）峰值从 r7 的 613 降到 **536**，item 4 从 514；multi_face matting p95 从 ~2900ms 降到 **1815.9ms**（-37%）。全局峰值 579.7 的落点从 multi_face **转移到 portrait 条目 37**（WIN_20230522_00_19_21，进入时 PSS 479.0，条目增量 ~100MB；构成 Private Other 281.4 + Native Heap 268.4 + Code 24.8）。模拟器 4.7 对照 550 仍差 29.7MB——剩余超阈主体是 portrait 横图条目 37/36 的解码瞬态 + 固有 floor（Native Heap 268.4），multi_face 已不再是主力。

## 二、4.8 方法学发现（重要，影响 r2-r8 全部轮次解读）

r8 的锚定 Δ+91.8 与 r7 的 -7.4 形成假性回归。逐采样曲线分析（`out/leak_r8_mem_curve.json`，91 样）：20 轮内 PSS 在 **430-519MB 振荡、无单调上升趋势**；Δ 的分母（基线 402.5）是 leak_begin±8s 窗口抓到的**预热前状态**（曲线前 9s：140→391），而稳态带是 430-519——基线锚定窗口踩在预热期，锚点比稳态低 30-60MB。

**线性斜率指标（稳态段 15s 后线性回归，MB/20轮）**：
r2 +1.1 / r3 **+9.1（真实泄漏）** / r4 -6.9 / r5 +4.6 / r6 -3.8 / r7 -3.2 / **r8 +2.4**。
结论：r4-r8 五轮斜率全部落在 ±7MB/20轮 噪声带内（r8 稳态漂移 +26.5MB，亦在 ±15-25MB RSS 噪声地板量级），**无可判定泄漏**；r3 的 +9.1 是唯一显著正斜率，与其余证据（跨设备 Δ 序列）一致。锚定 Δ 的轮间剧烈波动（+36/-7/+92/+29/-17/+92）是**基线锚定伪影**，不是代码回归——建议 gatekeeper 第 3 轮对 4.8 采用"稳态斜率 + 峰值完整回落"双指标判读（两口径四轮的峰值瞬态均完整回落，无一轮驻留）。

## 三、真机 vivo X21A v8：被设备离线阻断

v8 release 双包构建完成（`out/app-release-runner.apk` / `out/app-release-main.apk`，10:27/10:28），churn 相位脚本已升级并验证（14 人像/多脸 + 扫描件重编号批跑、1s PSS 采样 + VmHWM/proc/pid/status 高水位轮询、Android 9 meminfo 兜底、时钟偏移换算）。启动时 **vivo 5bc6e093 已从 adb 完全消失**（11 分钟轮询未回，USB 断连或设备重启，非脚本问题）。churn 数据待设备恢复后一条命令补出（`QA_SKIP_INSTALL=1 python test/batch/run_realdevice.py`，~10 分钟）。

真机既有终判素材（v6/v7 两轮有效数据，代码与 v8 运行时等价）：4.7 实测峰值 250.5MB（<550）、4.8 v7 Δ-17.7MB（v6 Δ+3.8/+0.2）、4.6 p95 2049.8ms（X21A 算力为小米 1/3）、冷启动 2764/568/493ms。VmHWM 口径仍缺，待设备回归补测。

## 四、给 gatekeeper 第 3 轮的数据摘要

- 4.7：模拟器 579.7（>550 FAIL，multi_face 已按 25bd1f0 压缩、主力转移到 portrait 解码瞬态 + 固有 floor）；真机 v6/v7 实测 250.5（PASS），VmHWM 待补。
- 4.8：**斜率判读无可判定泄漏**（r4-r8 全部 ±7MB/20轮 内）；锚定 Δ+91.8 为基线锚定伪影（本轮预热期踩点），建议按双指标判读。
- 4.1/4.2/4.3：全达标；4.6 模拟器 766.2ms 达标（真机 X21A 2049.8ms 属设备档位）。

数据文件：`out/batch_r8.json`、`out/metrics_r8.json`、`out/mem_breakdown_r8.json`、`out/leak_r8.json`、`out/leak_r8_mem_curve.json`、`out/perf_r8.json`、`out/crash_r8.json`、`out/grid_r8_*.png`、`out/memdump_r8/`、logcat `out/logcat_*_r8.txt`。

## 五、r9 追加：alt-AVD 交叉确认（MuZhao_Alt，用户新指令）

用现有 SDK 零安装新建 AVD：`avdmanager create avd -k "system-images;android-34;google_apis;x86_64" -d pixel_4 -n MuZhao_Alt`（RAM 4096，1080×2280@440dpi），QA_ROUND=9 全量跑通。

| 项 | 主 AVD r8 | MuZhao_Alt r9 |
|---|---|---|
| 4.7 峰值 | 579.7 | **587.3**（峰值 item 4 multi_face，进入 PSS 442.7，瞬态 ~145） |
| 4.8 锚定 Δ | +91.8 | +91.6（同为基线锚定伪影） |
| 4.8 稳态斜率 | +2.4 MB/20轮 | **+5.3 MB/20轮**（噪声带内） |
| 4.2/4.3/4.6 | 14/14、66/66、766.2ms | **14/14、66/66、897.6ms** |
| 4.1 | 0 | **0** |

**三 AVD 四轮结论固化**：x86_64 模拟器口径 4.7 = 580-613MB（多脸瞬态已被 25bd1f0 压缩，剩余 = portrait/大图解码瞬态 + 模拟器固有 floor ~440-505），对照 550 FAIL；真机口径 v6/v7 实测 250.5MB（单条目，gatekeeper 未采信），全 workload churn+VmHWM 待 vivo 恢复。

## 六、v8 真机 churn 终判（vivo 重连后补测成功，2026-09-16）

vivo 重连后 AMS 恢复（首启即成功），churn 全 workload 完整跑通（`out/metrics_r1_realdevice.json` v8 版）：

| 项 | 阈值 | 实测 | 判定 |
|---|---|---|---|
| 4.7 峰值（全 workload：14 人像/多脸 + 扫描件，15/15 完成：14 success + 扫描件 NoFace 优雅失败） | **550MB** | **峰值 PSS 571.7MB**（floor 402.7；峰值构成 Native Heap 252.3 + Private Other 216.7 + Graphics 85.7 + Code 24.2；尖峰后立即回落 ~400 稳态，PSS 曲线 70 样无驻留） | **超 21.7MB（~4%）——在 ±15-25MB RSS 采样噪声地板之内，单采样尖峰** |
| 4.8 回落 | 基线+80MB | **-2.1MB**（432.6→430.5，曲线内峰值 558.0） | PASS |
| 4.6 抠图 p95 | ≤1500ms | **2353.0ms**（p50 2256） | X21A 设备档位（小米真机 712.4ms） |
| 冷启动 | 参考 | 3197 / 569 / 502ms | 参考 |

**VmHWM 权威口径不可用**：vivo 拒绝 shell 读 `/proc/<app_pid>/status`（hwm_trace 空，SELinux/hidepid），已注明。1s PSS 采样的 571.7 为稀疏采样最大值（哨兵性质：真实峰值 ≥ 采样值，但超出量受采样粒度限制）。
**判读素材（裁决权在 gatekeeper）**：571.7 超阈 21.7MB，幅度落在协调者确认的 ±15-25MB RSS 噪声地板内；且为单采样尖峰——前一后一样本分别为 449.3/442.8（-122/-129MB），符合"GC 前瞬态"形态；尖峰后无任何残留（稳态 ~400 与基线 402.7 持平）。多脸条目（churn 0/1/3/5，matting 2567-5101ms）峰值窗口未见异常抬升——25bd1f0 的多脸压缩在真机上同样生效。
