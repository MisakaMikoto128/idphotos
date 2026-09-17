# -*- coding: utf-8 -*-
"""qa-batch：用旋转夹具反推锚点真值（比单张 Delta=0 观测稳健得多）。

原理：夹具是纯几何旋转，Delta 精确已知。于是对每个方法 m 和每个夹具，
    est_base_m = measured_m(fixture) - delta
是锚点真值的一次独立观测。7 次（Delta = 0,±3,±5,±10）取中位数，
即可把单张量测噪声和偶发 gross failure 一起压掉。

再对所有方法的中位数取中位数，得到该锚点的稳健真值。
与 p0_finalize 里记的单次 M1 真值对比：差 > 0.8° 的锚点标记，人工复核。

用法：python test/batch/p0_est.py
"""
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

OUT = os.path.join(L.REPO, "out", "P0_anchors")
METHODS = ("m1_pupil", "m2_radon_yunet", "m3_haar_eyeline", "m4_radon_haar")


def main():
    base = json.load(open(os.path.join(OUT, "anchors_base.json"), encoding="utf-8"))
    fx = json.load(open(os.path.join(OUT, "rotation_fixtures.json"), encoding="utf-8"))
    raw = json.load(open(os.path.join(OUT, "measure_raw.json"), encoding="utf-8"))
    zero = {r["id"]: r.get("methods", {}) for r in raw["candidates"]}

    by_src = {}
    for f in fx["fixtures"]:
        by_src.setdefault(f["src"], []).append(f)

    out = {"anchors": [], "perMethod": {}}
    print("%-5s %8s %8s %8s %6s %6s  %s" %
          ("id", "single", "robust", "delta", "nObs", "spread", "per-method est"))
    for a in base["anchors"] + base["straight"]:
        cid = a["id"]
        per = {}
        for m in METHODS:
            ests = []
            v = zero.get(cid, {}).get(m)
            if v is not None:
                ests.append(float(v))
            for f in by_src.get(cid, []):
                mm = (f.get("measuredTiltDeg") or {}).get(m)
                if mm is not None:
                    ests.append(float(mm) - f["deltaDeg"])
            if ests:
                per[m] = {"median": round(statistics.median(ests), 3),
                          "n": len(ests), "min": round(min(ests), 2),
                          "max": round(max(ests), 2)}
        cands = [v["median"] for v in per.values()]
        robust = round(statistics.median(cands), 3) if cands else None
        single = a["trueRollDeg"]
        delta = round(robust - single, 3) if robust is not None else None
        out["anchors"].append({"id": cid, "singleObsDeg": single,
                               "robustDeg": robust, "deltaDeg": delta,
                               "perMethod": per})
        print("%-5s %8.2f %8.2f %8s      -      -  %s" % (
            cid, single, robust if robust is not None else float("nan"),
            ("%+.2f" % delta) if delta is not None else "n/a",
            "  ".join("%s=%+.2f(n=%d)" % (m.split("_")[0], v["median"], v["n"])
                      for m, v in per.items())))

    with open(os.path.join(OUT, "anchor_robust_estimate.json"), "w",
              encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print("-> anchor_robust_estimate.json")


if __name__ == "__main__":
    main()
