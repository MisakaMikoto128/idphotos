# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 真值锚点测量（探索/落盘）。

产出：
  out/P0_anchors/measure_raw.json   每个候选的全部方法读数与一致性
  out/P0_anchors/<id>.png           目视复核 overlay

用法：python test/batch/p0_measure.py [--candidates FILE]
"""
import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

REPO = L.REPO
OUT = os.path.join(REPO, "out", "P0_anchors")

# 候选：Pictures 中 dataset.json 判定为人像/多人的全部条目（golden 源图含在内）
CANDIDATES = [
    ("p1", r"C:\Users\liuyu\Pictures\1 (2).jpg"),
    ("p2", r"C:\Users\liuyu\Pictures\2.jpg"),
    ("c01", r"C:\Users\liuyu\Pictures\20240710193717_7c99.jpg"),
    ("c02", r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg"),
    ("c03", r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124.jpg"),
    ("c04", r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124 (自定义).jpg"),
    ("c05", r"C:\Users\liuyu\Pictures\a.jpg"),
    ("c06", r"C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg"),
    ("c07", r"C:\Users\liuyu\Pictures\报名照片.jpg"),
    ("c08", r"C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg"),
    ("c09", r"C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_21_Pro.jpg"),
    ("c10", r"C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png"),
    ("c11", r"C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png"),
    ("c12", r"C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png"),
]


def _j(v):
    """numpy 标量 → python 原生，保证 JSON 可序列化。"""
    if isinstance(v, (np.integer,)):
        return int(v)
    if isinstance(v, (np.floating,)):
        return float(v)
    if isinstance(v, (list, tuple)):
        return [_j(x) for x in v]
    if isinstance(v, dict):
        return {str(k): _j(x) for k, x in v.items()}
    return v


def analyse(cid, path, save_overlay=True):
    rec = {"id": cid, "path": path.replace("\\", "/"), "ok": False}
    if not os.path.exists(path):
        rec["error"] = "file missing"
        return rec
    try:
        im, scale, faces = L.detect_faces(path)
    except Exception as e:  # noqa: BLE001
        rec["error"] = f"detect {type(e).__name__}: {e}"
        return rec
    rec["work_wh"] = list(im.size)
    rec["n_faces"] = len(faces)
    rec["scale"] = round(scale, 4)
    if not faces:
        rec["error"] = "no face"
        return rec
    f = L.pick_face(faces, im.size)
    rec["face_box"] = [round(v, 1) for v in f["box"]]
    rec["face_score"] = round(f["score"], 4)
    rec["kps"] = [round(v, 2) for v in f["kps"]]
    gray = L.gray_of(im)
    res = L.measure_all(gray, f)
    res["_face"] = f
    degs = L.methods_deg(res)
    rec["methods"] = {k: round(v, 3) for k, v in degs.items()}
    rec["method_detail"] = {}
    for k in L.METHOD_KEYS:
        v = res.get(k)
        if isinstance(v, dict):
            rec["method_detail"][k] = _j({kk: vv for kk, vv in v.items()
                                          if kk in ("n", "circ", "peak_ratio", "n_cand",
                                                    "source", "sizes", "box", "error", "pairCost")})
        else:
            rec["method_detail"][k] = None
    rec["yunet_eyeline"] = round(res["yunet_eyeline"], 3)
    rec["eyedist"] = round(res["eyedist"], 1)
    # 眼距太小的图（<40px）尺度依赖偏差大，标注低置信
    rec["low_res_eye"] = res["eyedist"] < 40
    if degs:
        vals = list(degs.values())
        rec["spread"] = round(max(vals) - min(vals), 3)
        rec["median"] = round(float(sorted(vals)[len(vals) // 2]), 3)
        rec["primary_m1"] = round(degs["m1_pupil"], 3) if "m1_pupil" in degs else None
    rec["ok"] = bool(degs)
    if save_overlay:
        title = "%s  %s" % (cid, " ".join("%s=%.2f" % (k.replace("m", "M").split("_")[0], v)
                                          for k, v in degs.items()))
        L.save_overlay(im, res, os.path.join(OUT, "%s.png" % cid), title)
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(OUT, "measure_raw.json"))
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    recs = [analyse(cid, path) for cid, path in CANDIDATES]
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"candidates": recs}, fh, ensure_ascii=False, indent=1)
    hdr = "%-5s %-7s %-7s %-7s %-7s %-7s %7s %7s %s" % (
        "id", "M1", "M2", "M3", "M4", "YU", "spread", "eye", "note")
    print(hdr)
    for r in recs:
        if not r.get("ok"):
            print("%-5s  FAILED: %s" % (r["id"], r.get("error")))
            continue
        m = r["methods"]
        print("%-5s %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.0f %s" % (
            r["id"], m.get("m1_pupil", float("nan")),
            m.get("m2_radon_yunet", float("nan")),
            m.get("m3_haar_eyeline", float("nan")),
            m.get("m4_radon_haar", float("nan")),
            r["yunet_eyeline"], r["spread"], r["eyedist"],
            "LOWRES" if r.get("low_res_eye") else ""))
    print("-> %s" % args.out)


if __name__ == "__main__":
    main()
