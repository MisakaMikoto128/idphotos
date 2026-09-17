"""r3 用：把 r2（pre-fix，git HEAD 那份）与 r3（post-fix）的残余产物逐条对比。

只读两份 JSON，不改任何东西。输出差分集合。
"""
import json
import sys

PRE = "out/r3_logs/prefix/P0_output_residual.json"
POST = "out/P0_output_residual.json"

FIELDS = ["straightenDeg", "primary_tilt_deg", "rigid_residual_deg",
          "truthConsistencyDeg", "methodSpreadDeg", "methodCount",
          "end_to_end_status", "rollSource", "faceRollDeg"]


def key(r):
    return (r.get("id"), r.get("specId"))


def load(p):
    d = json.load(open(p, encoding="utf-8"))
    return {key(r): r for r in d["items"]}


pre, post = load(PRE), load(POST)
print(f"pre items={len(pre)}  post items={len(post)}")
print("key set equal:", set(pre) == set(post))
if set(pre) != set(post):
    print("  only pre :", sorted(set(pre) - set(post))[:10])
    print("  only post:", sorted(set(post) - set(pre))[:10])

diffs = []
for k in sorted(set(pre) & set(post), key=lambda t: (str(t[0]), str(t[1]))):
    a, b = pre[k], post[k]
    for f in FIELDS:
        va, vb = a.get(f), b.get(f)
        if va is None and vb is None:
            continue
        if isinstance(va, float) or isinstance(vb, float):
            if va is None or vb is None or abs(va - vb) > 1e-9:
                diffs.append((k, f, va, vb))
        elif va != vb:
            diffs.append((k, f, va, vb))

print(f"\n=== 差分条目数: {len(diffs)} （涉 {len({d[0] for d in diffs})} 个 id/spec 行）===")
for k, f, va, vb in diffs:
    if isinstance(va, float) and isinstance(vb, float):
        print(f"  {k[0]:<12} {k[1]:<14} {f:<20} {va:>12.4f} -> {vb:>12.4f}  Δ={vb - va:+.4f}")
    else:
        print(f"  {k[0]:<12} {k[1]:<14} {f:<20} {str(va):>12} -> {str(vb):>12}")

# 点名样本
print("\n=== 点名样本（门禁规格 cn_big_1inch）===")
for name in ["c06_d-3", "c08_d-10"]:
    for src, tag in ((pre, "pre "), (post, "post")):
        r = src.get((name, "cn_big_1inch"))
        if r is None:
            print(f"  {tag} {name}: 无该行")
            continue
        print(f"  {tag} {name}: truth={r.get('truthTiltDeg')} "
              f"m1={r.get('primary_tilt_deg')} straighten={r.get('straightenDeg')} "
              f"rigid_residual={r.get('rigid_residual_deg')} rollSource={r.get('rollSource')} "
              f"status={r.get('end_to_end_status')}")

# unavailable -> 有角度
print("\n=== pre 无角度 / post 有角度 ===")
n = 0
for k in sorted(set(pre) & set(post), key=lambda t: (str(t[0]), str(t[1]))):
    a, b = pre[k], post[k]
    a_has = a.get("primary_tilt_deg") is not None
    b_has = b.get("primary_tilt_deg") is not None
    if (not a_has) and b_has:
        n += 1
        err = b.get("rigid_residual_deg")
        print(f"  {k[0]:<12} {k[1]:<14} straighten={b.get('straightenDeg')} "
              f"rigid_residual={err} status={b.get('end_to_end_status')}")
print(f"  共 {n} 条")

# summary 对比
def summ(p):
    d = json.load(open(p, encoding="utf-8"))["summary"]
    return {k: d.get(k) for k in ("composedCount", "primaryCount", "scored",
                                  "primaryAbsMax", "primaryAbsMedian", "primaryAbsMean",
                                  "primaryOver1p5", "unreliableMeasurement",
                                  "lowConfidence", "unmeasured")}

print("\n=== summary pre -> post ===")
s1, s2 = summ(PRE), summ(POST)
for k in s1:
    mark = "   " if s1[k] == s2[k] else " * "
    print(f"{mark}{k:<24} {str(s1[k]):>10} -> {str(s2[k]):>10}")
