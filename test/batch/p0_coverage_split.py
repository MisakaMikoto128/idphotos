# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 条件覆盖率按 |真值 tilt| 拆分的对照表。

给 gatekeeper 做**独立交叉校验**用：它自己实跑一遍作权威，本文件是另一条独立路径，
两条路径给出同一结论才算数。

四组 = {锚点, 旋转夹具} × {|tilt| > 阈值, |tilt| ≤ 阈值}，每组报 pupil / unavailable 计数。

⚠️ 阈值取两个都算：
  * 1.5° —— `docs/ACCEPTANCE.md` **当前** HEAD(b3518ba) P0.1b/P0.3b 的原文；
  * 2.0° —— 上一版(5b567b1)的阈值。
两份都给，避免口径错位导致"交叉校验不通过"这种假警报。

数据源：out/P0_coverage_items.jsonl（生产引擎 detectFace 直读）。
另与 out/P0_compose_items.jsonl 交叉核对 rollSource 是否一致，不一致会单列。
"""
import json
import os

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"


def load_jsonl(p):
    out = []
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def split(items, corpus, thr):
    sel = [r for r in items
           if r.get("corpus") == corpus
           and r.get("trueTiltDeg") is not None]
    above = [r for r in sel if abs(r["trueTiltDeg"]) > thr]
    below = [r for r in sel if abs(r["trueTiltDeg"]) <= thr]

    def tally(rs):
        return {
            "n": len(rs),
            "pupil": sum(1 for r in rs if r.get("rollSource") == "pupil"),
            "unavailable": sum(1 for r in rs
                               if r.get("rollSource") == "unavailable"),
            "other": sum(1 for r in rs if r.get("rollSource") not in
                         ("pupil", "unavailable")),
            "unavailableIds": sorted(r["id"] for r in rs
                                     if r.get("rollSource") == "unavailable"),
        }

    return {"above": tally(above), "below": tally(below),
            "aboveThreshold_deg": thr}


def main():
    cov = load_jsonl(os.path.join(REPO, "out", "P0_coverage_items.jsonl"))
    comp = load_jsonl(os.path.join(REPO, "out", "P0_compose_items.jsonl"))

    # 覆盖率语料里没有 uprightSynthetic（真值恒 0，不参与条件覆盖率），
    # 只拆 team-lead 点名的两组。
    payload = {"generatedBy": "qa-batch test/batch/p0_coverage_split.py",
               "source": "out/P0_coverage_items.jsonl（生产引擎 detectFace）",
               "note": "P0.1a/P0.3a 只用 pupil 样本；unavailable 从判据剔除，"
                       "不是当 0 观测。本表只做计数，不含 PASS/FAIL。",
               "splits": {}}
    for thr in (1.5, 2.0):
        key = f"threshold_{thr}"
        payload["splits"][key] = {
            "anchor": split(cov, "anchor", thr),
            "rotated": split(cov, "rotated", thr),
        }

    # 两条独立路径（覆盖率台 vs 合成台）在 rollSource 上是否一致
    c_by_id = {}
    for r in comp:
        if r.get("specId") == "cn_big_1inch":
            c_by_id[r["id"]] = r.get("rollSource")
    mism = []
    for r in cov:
        i = r["id"]
        if i.startswith("anchor_"):
            i = i[len("anchor_"):]
        elif i.startswith("rot_"):
            i = i[len("rot_"):]
        else:
            continue
        a, b = r.get("rollSource"), c_by_id.get(i)
        if b is not None and a != b:
            mism.append({"id": i, "coverageRun": a, "composeRun": b})
    payload["crossPathRollSourceMismatch"] = mism

    out_p = os.path.join(REPO, "out", "P0_coverage_split.json")
    with open(out_p, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    # 同步一份到 out/P0_residuals.json（team-lead 指定的落点）
    rp = os.path.join(REPO, "out", "P0_residuals.json")
    if os.path.exists(rp):
        with open(rp, encoding="utf-8") as fh:
            res = json.load(fh)
        res["coverageSplit"] = payload["splits"]
        res["coverageSplitCrossPathMismatch"] = mism
        with open(rp, "w", encoding="utf-8") as fh:
            json.dump(res, fh, ensure_ascii=False, indent=1)

    print(f"wrote {out_p} (+ out/P0_residuals.json:coverageSplit)")
    for thr, blk in payload["splits"].items():
        for corpus in ("anchor", "rotated"):
            b = blk[corpus]
            for zone in ("above", "below"):
                z = b[zone]
                print(f"{thr:<14}{corpus:<9}{zone:<7} n={z['n']:<4} "
                      f"pupil={z['pupil']:<4} unavailable={z['unavailable']:<3} "
                      f"{'' if not z['unavailableIds'] else z['unavailableIds']}")
    print(f"cross-path rollSource mismatch: {len(mism)} {mism[:5]}")


if __name__ == "__main__":
    main()
