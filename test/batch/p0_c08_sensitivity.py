# -*- coding: utf-8 -*-
"""qa-batch：c08 真值不确定性的**敏感性分析**（G2B-P0）。

背景：c08 的真值 −8.01° 是 `p0_finalize.py` 手写表里的值。`p0_est.py` 的独立
稳健估计给出 −6.56°（M1 法 −6.805°），相差 **+1.45°**，越过了脚本自己的 0.8° 复核线，
而当时无人复核（见报告）。

裁定（主会话）：**真值不改**。理由是替代候选（−6.56 / −6.805）来自**瞳孔法**，
而瞳孔法正是被测估角器的同族——换真值在结构上是循环的；且 c08 的
`corroborationOk=false`（两法互差 1.69°），说明稳健值本身也没被佐证。
要做的不是换真值，而是**量化"真值若不同"会影响哪些判定**。

本脚本对三档假设各算一遍门禁判据：
    H1 = −8.01   （现用手写值）
    H2 = −6.56   （稳健估计）
    H3 = −9.389  （YuNet 眼线原始读数）
并回答：**P0.1a / P0.1b / P0.3a / P0.3b / P0.2 里有没有任何一条的判定发生翻转。**

为什么线性：门禁的残余定义是 `residual = truth_apply_deg − measured_applied_deg`
（见 `out/gate_P0_sift_align.json` 的逐条数据与 `gate_P0.dart` 的注释）。
真值挪 δ，该样本残余**恰好挪 δ**，所以本分析可以精确重算，不需要重跑成片。

判据与常量照抄 `tools/gate/gate_P0.dart`（本脚本只读它，不改它）。

用法：python test/batch/p0_c08_sensitivity.py
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

# ---- 照抄 gate_P0.dart 的常量与判据 ----
K_RESIDUAL_MAX = 1.5          # |residual| 上限
K_RESIDUAL_MEDIAN_MAX = 1.0   # 中位残余上限
K_SLOPE_ABS_MAX = 0.15
K_INTERCEPT_ABS_MAX = 0.5
K_COVERAGE_MIN_TRUTH = 1.5    # |truth| > 1.5 必须给出 pupil
K_MIN_DISTINCT = 8
K_UPRIGHT_MIN = 9

C08_RECORDED = -8.01
HYPOTHESES = [("H1 手写值", -8.01), ("H2 稳健估计", -6.56), ("H3 YuNet 眼线", -9.389)]


def _median(xs):
    if not xs:
        return float("nan")
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _slope(pts):
    if len(pts) < 2:
        return float("nan")
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    num = sum((p[0] - mx) * (p[1] - my) for p in pts)
    den = sum((p[0] - mx) ** 2 for p in pts)
    return float("nan") if den == 0 else num / den


def _intercept(pts):
    if not pts:
        return float("nan")
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    return my - _slope(pts) * mx


def _delta_of(sid):
    """夹具 id -> 相对锚点真值的旋转量；锚点本身为 0。"""
    if "_d" not in sid:
        return 0.0
    tag = sid.split("_d")[1]
    if tag == "upright":      # 合成竖直样本：其"应有 tilt"就是 0，不随假设平移
        return None
    return float(tag.replace("+", ""))


def load():
    """按 `gate_P0.dart::buildSamples` 的**取数优先级**重建样本表。

    这一步必须照抄，否则复算不出门禁的数（我第一版就是直接全用 SIFT 的残余，
    得到 max 0.660 / 中位 0.101，与门禁报告的 0.714 / 0.476 对不上）。

    优先级：门禁自己的眼线量具 → SIFT 配准 → qa-batch 量测 → 恒等式兜底。

    ⚠️ **两条路径对真值的依赖不同，这正是本分析的关键**：
      * `gate_eyeline` / `qa_eyeline` 量的是**成片本身的倾角**，**与 truth 无关**；
      * `gate_sift_align` 的残余 = `truth − 实测施加角`，**与 truth 线性相关**；
      * `derived_identity` 同理。
    所以只有走后两条路径的样本，才会随 c08 真值假设一起平移。
    """
    eyeline = {r["id"]: r for r in json.load(
        open(os.path.join(L.REPO, "out", "gate_P0_eyeline.json"),
             encoding="utf-8"))["rows"]}
    sift = {r["id"]: r for r in json.load(
        open(os.path.join(L.REPO, "out", "gate_P0_sift_align.json"),
             encoding="utf-8"))["rows"]}
    comp = {i["id"]: i for i in json.load(
        open(os.path.join(L.REPO, "out", "P0_output_residual.json"),
             encoding="utf-8"))["items"]}

    out = {}
    for cid, c in comp.items():
        truth = float(c["truthTiltDeg"])
        applied = float(c["straightenDeg"])
        g = eyeline.get(cid)
        r = sift.get(cid)
        if g is not None and g.get("ok") is True:
            residual, by = float(g["tilt_deg"]), "gate_eyeline"
        elif r is not None and r.get("ok") is True:
            residual, by = float(r["residual_deg"]), "gate_sift_align"
        elif (c.get("primary_tilt_deg") is not None
              and c.get("end_to_end_status") not in ("reliability_mismatch", "unmeasured")):
            residual, by = float(c["primary_tilt_deg"]), "qa_eyeline"
        else:
            residual, by = truth - applied, "derived_identity"
        out[cid] = {
            "id": cid,
            "corpus": c["corpus"],
            "source": c["rollSource"],
            "truth": truth,
            "residual": residual,
            "residualBy": by,
            "applied": applied,
        }
    return out


def apply_hypothesis(samples, t_c08):
    """返回换了 c08 真值后的样本副本。非 c08 家族原样不动。

    残余只在**真值相关**的路径上平移（见 load() 的说明）；眼线直测的样本
    量的是成片倾角，换真值不影响它。
    """
    shift = t_c08 - C08_RECORDED
    out = {}
    for cid, s in samples.items():
        s2 = dict(s)
        if (cid == "c08" or cid.startswith("c08_")) and s["residualBy"] in (
                "gate_sift_align", "derived_identity"):
            d = _delta_of(cid)
            if d is not None:
                s2["truth"] = t_c08 + d
                s2["residual"] = s["residual"] + shift
        out[cid] = s2
    return out


def verdicts(samples):
    anchors = [s for s in samples.values() if s["corpus"] == "anchor"]
    rotated = [s for s in samples.values() if s["corpus"] == "rotated"]
    upright = [s for s in samples.values() if s["corpus"] == "uprightSynthetic"]
    pupils = [s for s in samples.values() if s["source"] == "pupil"]

    # P0.1a
    co = [s for s in anchors if s["source"] == "pupil"]
    res = [abs(s["residual"]) for s in co]
    p1a = (len(co) >= K_MIN_DISTINCT and max(res) <= K_RESIDUAL_MAX
           and _median(res) <= K_RESIDUAL_MEDIAN_MAX) if res else False
    p1a_detail = dict(n=len(co), max=max(res) if res else None,
                      median=_median(res) if res else None)

    # P0.1b
    need = [s for s in anchors if abs(s["truth"]) > K_COVERAGE_MIN_TRUTH]
    bad = [s for s in need if s["source"] == "unavailable"]
    p1b = not bad
    p1b_detail = dict(need=len(need), bad=[s["id"] for s in bad])

    # P0.3a
    cohort = pupils if pupils else list(samples.values())
    pts = [(s["truth"], s["residual"]) for s in cohort]
    sl, ic = _slope(pts), _intercept(pts)
    over = [s["id"] for s in cohort if abs(s["residual"]) > K_RESIDUAL_MAX]
    p3a = (math.isfinite(sl) and abs(sl) <= K_SLOPE_ABS_MAX
           and math.isfinite(ic) and abs(ic) <= K_INTERCEPT_ABS_MAX and not over)
    p3a_detail = dict(slope=sl, intercept=ic, n_over=len(over), over=over[:6])

    # P0.3b
    rneed = [s for s in rotated if abs(s["truth"]) > K_COVERAGE_MIN_TRUTH]
    rbad = [s for s in rneed if s["source"] == "unavailable"]
    p3b = not rbad
    p3b_detail = dict(need=len(rneed), bad=[s["id"] for s in rbad])

    # P0.2
    notp = [s for s in upright if s["source"] != "pupil"]
    p02 = len(upright) >= K_UPRIGHT_MIN and not notp
    return dict(p1a=p1a, p1b=p1b, p3a=p3a, p3b=p3b, p02=p02), dict(
        p1a=p1a_detail, p1b=p1b_detail, p3a=p3a_detail, p3b=p3b_detail)


def main():
    base = load()
    print("样本 %d 条（成片台语料）\n" % len(base))
    results = {}
    for name, t in HYPOTHESES:
        v, d = verdicts(apply_hypothesis(base, t))
        results[name] = (v, d)
        print("=== %s：c08 真值 = %.3f ===" % (name, t))
        print("  P0.1a %s  n=%d max=%.3f 中位=%.3f" % (
            "PASS" if v["p1a"] else "FAIL", d["p1a"]["n"],
            d["p1a"]["max"] or 0, d["p1a"]["median"] or 0))
        print("  P0.1b %s  需摆正 %d 条，其中 unavailable %d %s" % (
            "PASS" if v["p1b"] else "FAIL", d["p1b"]["need"],
            len(d["p1b"]["bad"]), d["p1b"]["bad"] or ""))
        print("  P0.3a %s  斜率=%.4f 截距=%.4f 超限 %d 条 %s" % (
            "PASS" if v["p3a"] else "FAIL", d["p3a"]["slope"],
            d["p3a"]["intercept"], d["p3a"]["n_over"], d["p3a"]["over"]))
        print("  P0.3b %s  需摆正 %d 条，其中 unavailable %d %s" % (
            "PASS" if v["p3b"] else "FAIL", d["p3b"]["need"],
            len(d["p3b"]["bad"]), d["p3b"]["bad"] or ""))
        print("  P0.2  %s" % ("PASS" if v["p02"] else "FAIL"))
        print()

    print("=== 翻转检查（相对 H1 现用值）===")
    base_v = results[HYPOTHESES[0][0]][0]
    flipped_any = False
    for name, _ in HYPOTHESES[1:]:
        v = results[name][0]
        flips = [k for k in base_v if v[k] != base_v[k]]
        print("  %-16s 翻转的判据：%s" % (name, flips or "无"))
        flipped_any = flipped_any or bool(flips)
    print("\n  结论：%s" % ("有判据随 c08 真值改变" if flipped_any
                          else "**三条判据均不翻转**（c08 真值取 −8.01/−6.56/−9.389 判定一致）"))

    # c08 家族明细
    print("\n=== c08 家族逐条（残余随真值整体平移）===")
    print("%-14s %10s %10s %10s %8s %10s" % ("id", "H1残余", "H2残余", "H3残余", "source", "H1真值"))
    for cid in sorted(base):
        if cid == "c08" or cid.startswith("c08_"):
            s = base[cid]
            sh = [t - C08_RECORDED for _, t in HYPOTHESES]
            print("%-14s %10.3f %10.3f %10.3f %8s %10.2f" % (
                cid, s["residual"] + sh[0], s["residual"] + sh[1],
                s["residual"] + sh[2], s["source"], s["truth"]))


if __name__ == "__main__":
    main()
