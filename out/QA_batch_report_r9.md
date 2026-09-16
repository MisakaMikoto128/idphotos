# QA_batch_report_r9 — alt-AVD 交叉确认（MuZhao_Alt；qa-batch，2026-09-16）

摘要见 `out/QA_batch_report_r8.md` 第五节。数据：`out/batch_r9.json`、`out/metrics_r9.json`、`out/mem_breakdown_r9.json`、`out/leak_r9.json`、`out/leak_r9_mem_curve.json`、`out/perf_r9.json`、`out/crash_r9.json`、`out/grid_r9_*.png`、logcat `out/logcat_*_r9.txt`。
4.7=587.3MB（>550）、4.8 斜率 +5.3MB/20轮（噪声带内）、4.2 14/14、4.3 66/66、4.6 p95 897.6ms、4.1=0。与主 AVD r8（579.7 / +2.4 / 全达标）一致——测量结论不依赖单一 AVD。
