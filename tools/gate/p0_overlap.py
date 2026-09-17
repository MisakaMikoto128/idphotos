# tools/gate/p0_overlap.py
#
# ACCEPTANCE 计分口径第 6/7 条的同性质要求：**不得用未去重的计数虚增覆盖**。
# 本工具测两件事，输出给 gate_P0.dart 的判定与报告：
#   1. 锚点集内部有哪些 id 其实是同一张照片（同图不同分辨率 / 同合影不同裁切）
#   2. 黄金集 g01–g08 与锚点集之间的重叠
#
# 方法：把每张源图缩到 48×48 灰度做签名，逐对算平均绝对差（MAE）。
# 判定阈值取 **MAE ≤ 5** 记 "同图"（实测同图不同分辨率副本在 0.0–2.4，
# 同一人的不同照片在 30+，二者之间有数量级的空档，阈值不敏感）。
# 这个方法**测不出"同合影的不同裁切"**（裁切后整幅签名差异很大），
# 所以对 c10/c11/c12 这类只能标注"本量具测不出，采信法典口径 6"。
#
# 独立性：不 import 生产代码，只读源图文件本身。

import argparse
import glob
import itertools
import json
import os
import sys

import cv2
import numpy as np

SIG = 48
SAME_THRESHOLD = 5.0


def sig(path):
    im = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if im is None:
        return None
    return cv2.resize(im, (SIG, SIG)).astype(np.float32)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--items", default="out/P0_compose_items.jsonl")
    ap.add_argument("--golden", default="test/golden/src")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)

    rows = []
    with open(args.items, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))

    # 锚点集 = corpus==anchor 的条目（含 p1/p2），按 id 取源图
    anchor_src = {}
    for r in rows:
        if r.get("corpus") == "anchor" or r["id"] in ("p1", "p2"):
            anchor_src.setdefault(r["id"], r.get("path"))

    def read_all(mapping):
        out = {}
        for k, v in mapping.items():
            if v and os.path.exists(v):
                s = sig(v)
                if s is not None:
                    out[k] = (s, v)
        return out

    anchors = read_all(anchor_src)
    gold = read_all({os.path.basename(p): p for p in sorted(glob.glob(
        os.path.join(args.golden, "*")))})

    # ---- 1. 锚点内部重复 ----
    intra = []
    for a, b in itertools.combinations(sorted(anchors), 2):
        mae = float(np.abs(anchors[a][0] - anchors[b][0]).mean())
        if mae <= SAME_THRESHOLD:
            intra.append({"a": a, "b": b, "mae": mae,
                          "a_path": anchors[a][1], "b_path": anchors[b][1]})

    # ---- 2. 黄金集 ↔ 锚点 ----
    cross = []
    for g in sorted(gold):
        best = None
        for a in sorted(anchors):
            mae = float(np.abs(gold[g][0] - anchors[a][0]).mean())
            if best is None or mae < best[1]:
                best = (a, mae)
        cross.append({"golden": g, "nearest_anchor": best[0],
                      "mae": best[1],
                      "same_photo": best[1] <= SAME_THRESHOLD,
                      "golden_path": gold[g][1],
                      "anchor_path": anchors[best[0]][1]})

    same = [c for c in cross if c["same_photo"]]
    # 去重后的不同照片数 = 锚点条目 - 内部重复 - （黄金集里属于锚点的那部分不再另算）
    n_anchor_entries = len(anchor_src)
    n_intra_dedup = len(intra)
    photos = n_anchor_entries - n_intra_dedup

    payload = {
        "generatedBy": "gatekeeper tools/gate/p0_overlap.py",
        "method": f"缩到 {SIG}x{SIG} 灰度签名，逐对 MAE；≤{SAME_THRESHOLD} 记同图",
        "limitation": "测不出同合影的不同裁切（c10/c11/c12 这类），那部分采信法典口径 6",
        "anchor_entries": n_anchor_entries,
        "golden_n": len(gold),
        "golden_all_in_anchor": len(same) == len(gold) and len(gold) > 0,
        "golden_same_photo_n": len(same),
        "intra_duplicates": intra,
        "golden_overlap": cross,
        "distinct_photos_after_dedup": photos,
    }

    print(f"锚点条目 {n_anchor_entries}，内部重复 {n_intra_dedup} 对")
    for d in intra:
        print(f"  {d['a']} ≡ {d['b']}  MAE {d['mae']:.2f}")
    print(f"黄金集 {len(gold)} 张，其中 {len(same)} 张在锚点集里有同图")
    for c in cross:
        mark = "同图" if c["same_photo"] else "不同"
        print(f"  {c['golden']} → {c['nearest_anchor']}  MAE {c['mae']:6.2f}  {mark}")
    print(f"去重后不同照片数（本量具可判的部分）= {photos}")

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
