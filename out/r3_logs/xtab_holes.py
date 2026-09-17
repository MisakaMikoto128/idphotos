"""r3：把 alpha_holes 的命中与真值倾角/语料交叉列表，检查'旋转'是否被识别。

只读两份 JSON。
"""
import json
import os

d = json.load(open("out/P0_alpha_holes.json", encoding="utf-8"))
truth = json.load(open("out/P0_truth.json", encoding="utf-8"))

tilt = {}
for k in ("anchors", "uprightSynthetic", "rotated", "straight"):
    for e in truth.get(k, []):
        base = os.path.basename(str(e.get("path", "")).replace("\\", "/"))
        t = e.get("truthTiltDeg")
        if t is None:
            t = e.get("truth_apply_deg")
        tilt[base] = (e.get("id"), t, k)

rows = []
for r in d["items"]:
    base = os.path.basename(str(r.get("path", "")).replace("\\", "/"))
    t = tilt.get(base)
    if t is None:
        continue
    frac = r.get("eyeBandZeroFrac")
    rows.append((t[0], t[1], t[2], None if frac is None else round(frac, 4)))

print("扫描里能对上真值的条目:", len(rows))
print()
print("%-14s %10s %-18s %9s" % ("id", "truthTilt", "corpus", "holeFrac"))
for r in sorted(rows, key=lambda x: -(x[3] or 0)):
    print("%-14s %10s %-18s %9s" % r)

print()
print("=== 未对上真值的扫描条目（=真实照片侧）===")
matched = set()
for r in d["items"]:
    base = os.path.basename(str(r.get("path", "")).replace("\\", "/"))
    if base in tilt:
        matched.add(base)
holes_unknown = [r for r in d["items"]
                 if os.path.basename(str(r.get("path", "")).replace("\\", "/")) not in tilt]
print("条数:", len(holes_unknown))
print("其中有洞的:", sum(1 for r in holes_unknown
                        if r.get("eyeBandHole") or (r.get("eyeBandZeroFrac") or 0) > 0.35))
fr = [r.get("eyeBandZeroFrac") for r in holes_unknown if r.get("eyeBandZeroFrac") is not None]
print("eyeBandZeroFrac 最大值: %.6f  非零条数: %d/%d" % (max(fr), sum(1 for x in fr if x > 0), len(fr)))
