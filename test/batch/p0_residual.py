# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0.1/0.2/0.3 判定数据（不判 PASS/FAIL，只出数字与分布）。

输入：out/P0_coverage_items.jsonl（test/batch/p0_coverage_test.dart 产出）
      out/P0_truth.json（真值）
输出：out/P0_residuals.json

关键定义
  trueRollDeg        = 实测倾角 tilt（正 = 图像右侧的眼更低）
  expectedEngineRollDeg = tilt（实测：引擎 rollDeg 数值 == 实测倾角）
  P0.1 残差          = production.rollDeg - expectedEngineRollDeg
  P0.3 斜率          = production.rollDeg 对 deltaDeg 的线性回归系数（每张锚点各一条，
                       并分正/负 delta 两向各算一条以查方向性衰减）

用法：python test/batch/p0_residual.py
"""
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

OUT = os.path.join(L.REPO, "out")
ITEMS = os.path.join(OUT, "P0_coverage_items.jsonl")


def load_items():
    rows = []
    with open(ITEMS, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def slope(xs, ys):
    n = len(xs)
    if n < 2:
        return None, None
    mx, my = sum(xs) / n, sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den = sum((x - mx) ** 2 for x in xs)
    if den < 1e-12:
        return None, None
    b = num / den
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((y - (my + b * (x - mx))) ** 2 for x, y in zip(xs, ys))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 1e-12 else None
    return b, r2


def main():
    items = {r["id"]: r for r in load_items()}
    report = {"inputState": None, "P0_1_anchors": [], "P0_2_straight": [],
              "P0_3_rotation": [], "summary": {}}

    st = os.path.join(OUT, "P0_anchors", "_baseline_state.txt")
    if os.path.exists(st):
        txt = open(st, encoding="utf-8").read()
        report["inputState"] = {
            "headCommit": txt.splitlines()[0].strip(),
            "note": "生产引擎来自该 commit + 当时未提交的工作树；逐文件 sha256 见 "
                    "out/P0_anchors/_baseline_state.txt",
        }

    # ---- P0.1 / P0.2：直接残差
    for r in items.values():
        if "expectedEngineRollDeg" not in r or "rollDeg" not in r:
            continue
        resid = r["rollDeg"] - r["expectedEngineRollDeg"]
        rec = {"id": r["id"], "src": r.get("deltaDeg") and r["id"].split("_d")[0] or None,
               "trueTiltDeg": r.get("trueTiltDeg"),
               "expectedEngineRollDeg": r["expectedEngineRollDeg"],
               "prodRollDeg": r["rollDeg"],
               "rollSource": r.get("rollSource"),
               "residualDeg": round(resid, 3),
               "absResidualDeg": round(abs(resid), 3),
               "pass_1p5deg": abs(resid) <= 1.5}
        if r["id"].startswith("rot_"):
            continue
        if r["id"].startswith("anchor_") and not r["id"].endswith("_upright"):
            report["P0_1_anchors"].append(rec)
        else:
            report["P0_2_straight"].append(rec)

    # ---- P0.3：旋转等变斜率
    by_src = {}
    for r in items.values():
        if not r["id"].startswith("rot_") or "rollDeg" not in r:
            continue
        src = r["id"][4:].split("_d")[0]
        by_src.setdefault(src, []).append(r)
    for src, rows in sorted(by_src.items()):
        rows.sort(key=lambda r: r["deltaDeg"])
        # delta=0 的观测不在夹具里（夹具只做 ±3/±5/±10），回退到锚点原始观测
        base = items.get("anchor_%s" % src)
        d0 = base["rollDeg"] if base and "rollDeg" in base else None
        xs = [r["deltaDeg"] for r in rows]
        ys = [r["rollDeg"] - d0 for r in rows] if d0 is not None else None
        b_all, r2_all = slope(xs, ys) if ys else (None, None)
        ent = {"src": src, "nFixtures": len(rows), "prodAtDelta0": d0}
        if b_all is not None:
            ent["slopeAll"] = round(b_all, 4)
            ent["r2All"] = round(r2_all, 4) if r2_all is not None else None
        for tag, sel in (("Pos", lambda d: d > 0), ("Neg", lambda d: d < 0)):
            sub = [r for r in rows if sel(r["deltaDeg"])]
            if len(sub) >= 2 and d0 is not None:
                bx, r2x = slope([r["deltaDeg"] for r in sub],
                                [r["rollDeg"] - d0 for r in sub])
                if bx is not None:
                    ent["slope%s" % tag] = round(bx, 4)
                    ent["r2%s" % tag] = round(r2x, 4) if r2x is not None else None
        # 只统计引擎真的给了 pupil 的夹具：把"覆盖率缺口"与"估角不准"分开
        est = [r for r in rows if r.get("rollSource") == "pupil"]
        ent["nEstimated"] = len(est)
        ent["nUnavailable"] = len(rows) - len(est)
        if d0 is not None and len(est) >= 2:
            bx, r2x = slope([r["deltaDeg"] for r in est],
                            [r["rollDeg"] - d0 for r in est])
            if bx is not None:
                ent["slopeEstimatedOnly"] = round(bx, 4)
                ent["r2EstimatedOnly"] = round(r2x, 4) if r2x is not None else None
        vals = [v for k, v in ent.items()
                if k in ("slopeAll", "slopePos", "slopeNeg")]
        ent["inRange_0.85_1.15"] = all(0.85 <= v <= 1.15 for v in vals) if vals else None
        seo = ent.get("slopeEstimatedOnly")
        ent["inRangeEstimatedOnly"] = (0.85 <= seo <= 1.15) if seo is not None else None
        if "slopePos" in ent and "slopeNeg" in ent:
            ent["directionAsymmetry"] = round(abs(ent["slopePos"] - ent["slopeNeg"]), 4)
        report["P0_3_rotation"].append(ent)

    # ---- P0.4：覆盖率（真实语料上的 pupil 成功率）
    np_items = json.load(open(os.path.join(OUT, "P0_anchors", "non_portrait.json"),
                             encoding="utf-8"))
    non_paths = {p.replace("\\", "/") for p in np_items["paths"]} \
        if "paths" in np_items else {i["path"] for i in np_items["items"]}
    corp = {"pictures_portrait": [], "pictures_nonportrait": [],
            "golden": [], "anchor": [], "rotated": []}
    for r in items.values():
        c = r.get("corpus")
        if c == "pictures":
            corp["pictures_nonportrait" if r["path"] in non_paths
                 else "pictures_portrait"].append(r)
        elif c in ("golden", "anchor", "rotated"):
            corp[c].append(r)
    cov = {}
    for name, rows in corp.items():
        n = len(rows)
        by = {}
        for r in rows:
            by[r.get("rollSource", "none")] = by.get(r.get("rollSource", "none"), 0) + 1
        with_face = sum(1 for r in rows if r.get("outcome") == "face")
        cov[name] = {
            "total": n,
            "faceDetected": with_face,
            "rollSource": by,
            "pupilRate_overAll": round(by.get("pupil", 0) / n, 4) if n else None,
            "pupilRate_overFaceDetected": round(by.get("pupil", 0) / with_face, 4)
            if with_face else None,
            "unavailableRate_overFaceDetected": round(
                by.get("unavailable", 0) / with_face, 4) if with_face else None,
        }
    report["P0_4_coverage"] = cov

    # ---- 汇总
    a = report["P0_1_anchors"]
    s = report["P0_2_straight"]
    rot = report["P0_3_rotation"]
    report["summary"] = {
        "P0_1_anchorCount": len(a),
        "P0_1_passCount": sum(1 for r in a if r["pass_1p5deg"]),
        "P0_1_maxAbsResidualDeg": round(max((r["absResidualDeg"] for r in a), default=0), 3),
        "P0_1_medianAbsResidualDeg": round(statistics.median(
            [r["absResidualDeg"] for r in a]), 3) if a else None,
        "P0_2_sampleCount": len(s),
        "P0_2_passCount": sum(1 for r in s if r["pass_1p5deg"]),
        "P0_2_maxAbsResidualDeg": round(max((r["absResidualDeg"] for r in s), default=0), 3),
        "P0_3_anchorCount": len(rot),
        "P0_3_inRangeCount": sum(1 for r in rot if r["inRange_0.85_1.15"]),
        "P0_3_inRangeEstimatedOnlyCount": sum(
            1 for r in rot if r.get("inRangeEstimatedOnly")),
        "P0_3_maxDirectionAsymmetry": round(max(
            (r.get("directionAsymmetry", 0) for r in rot), default=0), 4),
        "P0_3_fixtureUnavailableCount": sum(r.get("nUnavailable", 0) for r in rot),
        "P0_3_fixtureCount": sum(r.get("nFixtures", 0) for r in rot),
    }

    dst = os.path.join(OUT, "P0_residuals.json")
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)

    print("== P0.1 锚点残差（成片摆正角 vs 期望）==")
    print("%-22s %8s %8s %9s %9s %6s" % ("id", "tilt", "expCorr", "prod", "resid", "<=1.5"))
    for r in sorted(a, key=lambda r: -r["absResidualDeg"]):
        print("%-22s %8.2f %8.2f %9.2f %9.2f %6s" % (
            r["id"], r["trueTiltDeg"], r["expectedEngineRollDeg"], r["prodRollDeg"],
            r["residualDeg"], "OK" if r["pass_1p5deg"] else "FAIL"))
    print("== P0.2 竖直样本 ==")
    for r in sorted(s, key=lambda r: -r["absResidualDeg"]):
        print("%-22s %8.2f %8.2f %9.2f %9.2f %6s" % (
            r["id"], r["trueTiltDeg"] or 0.0, r["expectedEngineRollDeg"],
            r["prodRollDeg"], r["residualDeg"], "OK" if r["pass_1p5deg"] else "FAIL"))
    print("== P0.3 旋转斜率 ==")
    print("%-8s %8s %8s %8s %8s %8s %8s %5s %s" %
          ("src", "base", "slopeAll", "slopePos", "slopeNeg", "asym",
           "estOnly", "est/n", "strict"))
    for r in rot:
        def f(v):
            return "%8.3f" % v if isinstance(v, (int, float)) else "%8s" % "n/a"
        print("%-8s %s %s %s %s %s %s %5s %s" % (
            r["src"], f(r.get("prodAtDelta0")), f(r.get("slopeAll")),
            f(r.get("slopePos")), f(r.get("slopeNeg")),
            f(r.get("directionAsymmetry")), f(r.get("slopeEstimatedOnly")),
            "%d/%d" % (r.get("nEstimated", 0), r.get("nFixtures", 0)),
            "OK" if r["inRange_0.85_1.15"] else "FAIL"))
    print("== SUMMARY ==")
    print(json.dumps(report["summary"], ensure_ascii=False, indent=1))
    print("== P0.4 覆盖率（真实语料）==")
    for k, v in report["P0_4_coverage"].items():
        print("%-22s n=%-4d face=%-4d %s  pupil/face=%s" % (
            k, v["total"], v["faceDetected"], v["rollSource"],
            v["pupilRate_overFaceDetected"]))
    print("->", dst)


if __name__ == "__main__":
    main()
