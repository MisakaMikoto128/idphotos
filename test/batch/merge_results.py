# -*- coding: utf-8 -*-
"""qa-batch 阶段 4：host 侧汇总脚本（只汇总测量数据，产出判定依据）。

输入：out/tmp_pull/batch_items.jsonl、out/mem_r1.json、out/leak_r1_mem_curve.json、
      out/leak_r1_raw.jsonl、out/perf_r1_raw.json、test/dataset.json
输出：
  out/batch_r1.json        逐项结果（ACCEPTANCE 4.1-4.3 的判定数据）
  out/metrics_r1.json      按 class 分组的 p50/p95 耗时、成功率、峰值内存
  out/leak_r1.json         G4.8 内存曲线判定数据
  out/perf_r1.json         G4.6 p95 判定数据
  out/crash_r1.json        logcat FATAL/ANR 扫描结果
"""
import glob
import json
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
PULL = os.path.join(OUT, "tmp_pull", "batch_items.jsonl")

R = sys.argv[1] if len(sys.argv) > 1 else "1"  # 轮次后缀

PORTRAIT_CLASSES = {"portrait", "multi_face"}


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] * (c - k) + sorted_vals[c] * (k - f)


def load_items():
    items = {}
    if not os.path.exists(PULL):
        return items
    with open(PULL, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("event") == "item":
                items[rec["rec"]["i"]] = rec["rec"]
    return items


def merge_batch():
    items = load_items()
    ds = json.load(open(os.path.join(ROOT, "test", "dataset.json"),
                        encoding="utf-8"))
    out = []
    for it in ds["items"]:
        path = it["path"]
        r = next((v for v in items.values() if v.get("path") == path), None)
        cls = it["class"]
        base = {"path": path, "class": cls, "w": it.get("w"),
                "h": it.get("h")}
        if r is None:
            base.update({"ok": False, "result": "not_run", "stage_failed":
                         "harness", "error": "no record"})
            out.append(base)
            continue
        eng = r.get("engine", {})
        ctrl = r.get("controller", {})
        base.update({
            "result": r.get("result"),
            "ok": r.get("result") in ("success", "graceful_error"),
            "stage": ctrl.get("stage"),
            "stage_failed": None if r.get("result") == "success" else
            ("matting" if eng.get("matting_error") else
             "face" if eng.get("face_error") else
             "compose" if eng.get("compose_error") else
             "controller" if ctrl.get("stage") == "error" else None),
            "error": eng.get("matting_error") or eng.get("face_error") or
            eng.get("compose_error") or ctrl.get("error_message"),
            "message_zh": eng.get("message_zh") or ctrl.get("error_message"),
            "matting_ms": eng.get("matting_ms"),
            "face_ms": eng.get("face_ms"),
            "compose_ms": eng.get("compose_ms"),
            "load_ms": ctrl.get("load_ms"),
            "total_ms": r.get("total_ms"),
            "candidates": ctrl.get("candidates"),
            "weird": r.get("weird"),
            "fg_ratio": eng.get("fg_ratio"),
        })
        out.append(base)
    with open(os.path.join(OUT, f"batch_r{R}.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    return out


def metrics(batch):
    by_cls = {}
    for r in batch:
        c = r["class"]
        g = by_cls.setdefault(c, {"n": 0, "success": 0, "graceful_error": 0,
                                  "other": 0, "matting_ms": [], "compose_ms": [],
                                  "total_ms": [], "paths_fail": []})
        g["n"] += 1
        if r["result"] == "success":
            g["success"] += 1
        elif r["result"] == "graceful_error":
            g["graceful_error"] += 1
        else:
            g["other"] += 1
            g["paths_fail"].append(r["path"])
        for k in ("matting_ms", "compose_ms", "total_ms"):
            if isinstance(r.get(k), int):
                g[k].append(r[k])
    summary = {}
    for c, g in by_cls.items():
        for k in ("matting_ms", "compose_ms", "total_ms"):
            g[k].sort()
        summary[c] = {
            "n": g["n"],
            "success": g["success"],
            "graceful_error": g["graceful_error"],
            "other": g["other"],
            "success_rate": round(g["success"] / g["n"], 4) if g["n"] else 0,
            "graceful_rate": round((g["success"] + g["graceful_error"]) / g["n"],
                                   4) if g["n"] else 0,
            "matting_p50_ms": pct(sorted(g["matting_ms"]), 50),
            "matting_p95_ms": pct(sorted(g["matting_ms"]), 95),
            "total_p50_ms": pct(sorted(g["total_ms"]), 50),
            "total_p95_ms": pct(sorted(g["total_ms"]), 95),
            "fail_paths": g["paths_fail"],
        }
    # 整体人像类（4.2 口径）
    pr = [r for r in batch if r["class"] in PORTRAIT_CLASSES]
    pr_ok = [r for r in pr if r["result"] == "success"]
    # 非人像类（4.3 口径）
    non = [r for r in batch if r["class"] not in PORTRAIT_CLASSES]
    non_ok = [r for r in non if r["result"] == "graceful_error"]
    mem = json.load(open(os.path.join(OUT, f"mem_r{R}.json")))
    res = {
        "per_class": summary,
        "portrait_union": {"n": len(pr), "success": len(pr_ok),
                           "rate": len(pr_ok) / len(pr) if pr else None},
        "non_portrait_union": {"n": len(non), "graceful": len(non_ok),
                               "rate": len(non_ok) / len(non) if non else None,
                               "fail_paths": [r["path"] for r in non
                                              if r["result"] != "graceful_error"]},
        "peak_mem_mb": round(mem["peak_kb"] / 1024, 1),
    }
    with open(os.path.join(OUT, f"metrics_r{R}.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def peak_breakdown():
    """4.7 峰值构成拆解：峰值时刻 / 所属条目 / dumpsys 分类明细。"""
    mem_path = os.path.join(OUT, f"mem_r{R}.json")
    if not os.path.exists(mem_path):
        return None
    mem = json.load(open(mem_path))
    samples = [(t, kb) for (t, kb) in mem["samples"] if kb]
    if not samples:
        return None
    peak_t, peak_kb = max(samples, key=lambda x: x[1])
    top10 = sorted((kb for _, kb in samples), reverse=True)[:10]

    # 用 begin 事件时间轴归属峰值时刻的条目
    begins = []
    if os.path.exists(PULL):
        with open(PULL, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    rec = json.loads(line)
                    if rec.get("event") == "begin":
                        begins.append((rec["t"] / 1000.0, rec["i"]))
    begins.sort()
    peak_item = None
    if begins:
        prev = None
        for t, i in begins:
            if t > peak_t:
                break
            prev = (t, i)
        peak_item = prev[1] if prev else begins[0][1]
    peak_path = None
    if os.path.exists(PULL) and peak_item is not None:
        with open(PULL, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    rec = json.loads(line)
                    if rec.get("event") == "item" and rec["rec"]["i"] == peak_item:
                        peak_path = rec["rec"]["path"]
                        break

    # 峰值前后的 PSS 阶梯：条目开始时的 PSS（floor 参考）
    pss_at_peak_item_begin = None
    if begins:
        cand = [(abs(t - peak_t), kb) for (t, kb) in samples
                for bt, i in [next((b for b in begins if b[1] == peak_item),
                                   (None, None))]
                if bt is not None and t <= bt]
        if cand:
            pss_at_peak_item_begin = min(cand)[1]

    # 峰值时刻的 dumpsys 分类明细（memdump_r<R>/ 里时间最近的）
    dump_info = None
    dump_dir = os.path.join(OUT, f"memdump_r{R}")
    if os.path.isdir(dump_dir):
        best = None
        for name in os.listdir(dump_dir):
            m = re.match(r"seq\d+_t(\d+)\.txt", name)
            if not m:
                continue
            dt = abs(int(m.group(1)) - peak_t)
            if best is None or dt < best[0]:
                best = (dt, os.path.join(dump_dir, name))
        if best:
            cats = {}
            with open(best[1], encoding="utf-8", errors="replace") as f:
                for line in f:
                    m = re.match(
                        r"\s*(Native Heap|Graphics|Java Heap|Code|Stack|"
                        r"Private Other|TOTAL PSS):\s+(\d+)", line)
                    if m:
                        cats[m.group(1)] = int(m.group(2))
            dump_info = {"file": os.path.basename(best[1]),
                         "delta_t_s": best[0], "categories_kb": cats}

    res = {
        "peak_mb": round(peak_kb / 1024, 1),
        "peak_t": peak_t,
        "peak_item_index": peak_item,
        "peak_item_path": peak_path,
        "top10_samples_mb": [round(k / 1024, 1) for k in top10],
        "pss_at_peak_item_begin_kb": pss_at_peak_item_begin,
        "dumpsys_at_peak": dump_info,
    }
    with open(os.path.join(OUT, f"mem_breakdown_r{R}.json"), "w",
              encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def leak():
    curve = os.path.join(OUT, f"leak_r{R}_mem_curve.json")
    raw = os.path.join(OUT, f"leak_r{R}_raw.jsonl")
    if not (os.path.exists(curve) and os.path.exists(raw)):
        return None
    c = json.load(open(curve))
    rounds = []
    with open(raw, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                rounds.append(json.loads(line))
    # marker 时间点（run-as tar 内容在 qa_out/ 下）
    beg = end = None
    missing_markers = []
    pull_dir = os.path.join(OUT, "pull_leak", "qa_out")
    for name, var in (("leak_begin", "beg"), ("leak_end", "end")):
        p = os.path.join(pull_dir, name)
        if not os.path.exists(p):
            # 不静默：marker 文件缺失会让下面的 baseline/settle 变成 null，
            # 而 null 读起来像"这一轮没有可用的泄漏判断"，不像"切点丢了"。
            missing_markers.append(name)
            continue
        ts = int(open(p).read().strip()) / 1000.0
        if var == "beg":
            beg = ts
        else:
            end = ts
    if missing_markers:
        print(f"  [leak r{R}] WARNING marker 文件缺失: "
              f"{', '.join(missing_markers)}（{pull_dir}）→ "
              f"baseline_kb/delta_settle_kb 将为 null。"
              f" 若 batch_runner 侧写失败，logcat 里有 "
              f"QA_MARKER_FILE_FAIL|<name>|<ts>|<err> 带出时间戳与原因。")
    samples = c["samples"]
    base_win = [kb for (t, kb) in samples
                if kb and beg and beg - 8 <= t <= beg + 8]
    settle_win = [kb for (t, kb) in samples
                  if kb and end and t >= end]
    base = sorted(base_win)[len(base_win) // 2] if base_win else None
    settle = min(settle_win) if settle_win else None
    during = [kb for (t, kb) in samples if kb and beg and end and beg <= t <= end + 3]
    res = {
        "n_rounds": len(rounds),
        "marker_files_missing": missing_markers,
        "baseline_kb": base,
        "settle_min_kb": settle,
        "peak_during_kb": max(during) if during else c["peak_kb"],
        "delta_settle_kb": (settle - base) if (base and settle) else None,
        "rounds": rounds,
    }
    with open(os.path.join(OUT, f"leak_r{R}.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def perf():
    p = os.path.join(OUT, f"perf_r{R}_raw.json")
    if not os.path.exists(p):
        return None
    d = json.load(open(p))
    ms = sorted(d["ms"])
    res = {"n": len(ms), "input": d["input"],
           "p50_ms": pct(ms, 50), "p95_ms": pct(ms, 95),
           "min_ms": ms[0], "max_ms": ms[-1], "all_ms": d["ms"]}
    with open(os.path.join(OUT, f"perf_r{R}.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def crashes():
    pat_fatal = re.compile(r"FATAL EXCEPTION|Force finishing activity|"
                           r"ANR in com\.muzhao", re.I)
    res = {}
    # r2 起轮次后缀文件名，只扫本轮的 logcat，避免混入历史轮数据
    pat = (f"logcat_*_r{R}.txt" if R != "1" else "logcat_*.txt")
    for f in glob.glob(os.path.join(OUT, pat)):
        name = os.path.basename(f)
        hits = []
        with open(f, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if pat_fatal.search(line):
                    hits.append(f"{i}: {line.strip()[:200]}")
        res[name] = hits
    with open(os.path.join(OUT, f"crash_r{R}.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


if __name__ == "__main__":
    b = merge_batch()
    m = metrics(b)
    l = leak()
    p = perf()
    cr = crashes()
    bd = peak_breakdown()
    print(json.dumps({"portrait_union": m["portrait_union"],
                      "non_portrait": m["non_portrait_union"],
                      "peak_mem_mb": m["peak_mem_mb"],
                      "peak_breakdown": bd,
                      "leak_delta_kb": l["delta_settle_kb"] if l else None,
                      "perf_p95": p["p95_ms"] if p else None,
                      "crash_files": {k: len(v) for k, v in cr.items() if v}},
                     ensure_ascii=False, indent=1))
