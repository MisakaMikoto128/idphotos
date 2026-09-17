# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 端到端成片残余倾角（口径无关的独立测量）。

输入：out/P0_anchors/composed/*.jpg —— 由生产引擎（test/batch/p0_compose_test.dart）
产出的真实成片；本脚本**只读像素**，不调用任何生产 Dart 代码。
输入：out/P0_compose_items.jsonl —— 每张成片的 truth / straightenDeg / rollSource。

主判据（ACCEPTANCE G2B-P0 计分口径第 5 条）：
    output_tilt_deg = 成片眼线的实测倾角。**理想值 0**（摆正了就是摆正了）。
    与符号约定无关：只要管线测的角等于真值倾角、且按它旋转，成片就该是平的。
    若符号写反，成片会朝反方向转 2×真值 —— 这个量直接把它照出来。

次判据（诊断用，不作判据）：
    rigid_residual = output_tilt_deg - applied_tilt_deg
    其中 applied_tilt_deg = -straightenDeg（实现侧恒等式 输出=输入-rollDeg，
    而 straightenDeg == rollDeg）。纯旋转几何残差，去掉"角度测得准不准"这一层。

可靠性标定（回答 team-lead 的"瞳孔法在小成片上还测得动吗"）：
    取 600×600 成片，按人脸框高度等比缩放到与各规格成片同尺度，再施加已知
    Δ ∈ {0,±2,±5}，用同一套 Python 瞳孔法测回。误差 = 测得 -(原测+Δ)。
    这一步不含生产代码，纯粹标定**测量方法本身**在 256px 头高下的精度。
"""
import glob
import json
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

REPO = L.REPO
OUT = REPO + r"\out"
COMPOSED = OUT + r"\P0_anchors\composed"


def _j(v):
    if isinstance(v, dict):
        return {k: _j(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_j(x) for x in v]
    if isinstance(v, (np.floating, np.integer)):
        return float(v)
    return v


def pupil_with_seed(gray, il, ir):
    """给定左右眼种子，跑 M1 瞳孔配对。返回 deg / 两点 / 配对代价。"""
    ed = math.hypot(ir[0] - il[0], ir[1] - il[1])
    if ed < 12:
        return None
    r = max(8.0, 0.30 * ed)
    cl = L.m1_pupil(gray, il, r, ed)
    cr = L.m1_pupil(gray, ir, r, ed)
    if not cl or not cr:
        return None
    best = None
    for a in cl:
        for b in cr:
            c = L._pair_cost(a, b, il, ir, ed)
            if best is None or c < best[0]:
                best = (c, a, b)
    if best is None or not math.isfinite(best[0]):
        return None
    _, a, b = best
    return {"deg": L._angle_from_pair(a["xy"], b["xy"]),
            "left": list(a["xy"]), "right": list(b["xy"]),
            "pairCost": round(best[0], 3), "eyedist": round(ed, 1)}


def haar_seeds(gray):
    """Haar 人脸框 → 人类学比例眼种子（0.32/0.68 宽、0.42 高）。
    完全不碰 YuNet，用作 M1 的第二种种子来源。"""
    box, eyes = L.haar_eyes(gray)
    if box is None:
        return None
    x, y, w, h = box
    return (x + 0.32 * w, y + 0.42 * h), (x + 0.68 * w, y + 0.42 * h)


def measure_composed(path):
    """成片上的多方法测量。返回 dict（含每法的 deg 与失败原因）。"""
    im, _ = L.load_rgb(path)
    gray = L.gray_of(im)
    rec = {"path": path.replace("\\", "/"), "size": list(im.size),
           "H": im.size[1], "W": im.size[0]}

    # --- 种子来源 A：cv2 YuNet（与生产用的模型同源，但独立 Python 运行时）
    _, _, faces = L.detect_faces(path)
    fa = L.pick_face(faces, im.size)
    if fa is not None:
        kps = fa["kps"]
        il, ir = L.eye_pair(kps)
        rec["yunet_eyeline_deg"] = L.yunet_eyeline(kps)
        rec["yunet_eyedist"] = round(math.hypot(ir[0] - il[0], ir[1] - il[1]), 1)
        rec["yunet_score"] = fa["score"]
        m1 = pupil_with_seed(gray, il, ir)
        if m1:
            m1["seed"] = "yunet"
            rec["m1_pupil"] = m1
        else:
            rec["m1_pupil"] = {"error": "no_pair"}
        m2 = L.measure_m2(gray, kps, rec["yunet_eyedist"])
        rec["m2_radon_yunet"] = m2 if m2 else {"error": "no_band"}
    else:
        rec["m1_pupil"] = {"error": "no_yunet_face"}
        rec["m2_radon_yunet"] = {"error": "no_yunet_face"}

    # --- 种子来源 B：Haar（独立检测器）
    hs = haar_seeds(gray)
    if hs:
        m1h = pupil_with_seed(gray, hs[0], hs[1])
        rec["m1h_pupil_haarseed"] = m1h if m1h else {"error": "no_pair"}
    else:
        rec["m1h_pupil_haarseed"] = {"error": "no_haar_face"}

    # --- 独立方法 C/D：Haar 眼线 / Haar-Radon
    m3 = L.measure_m3(gray)
    rec["m3_haar_eyeline"] = m3 if m3 else {"error": "no_pair"}
    m4 = L.measure_m4(gray)
    rec["m4_radon_haar"] = m4 if m4 else {"error": "no_band"}

    # 主值：优先 YuNet 种子的 M1，退化到 Haar 种子的 M1
    for k in ("m1_pupil", "m1h_pupil_haarseed", "m3_haar_eyeline"):
        v = rec.get(k) or {}
        if isinstance(v, dict) and "deg" in v:
            rec["primary_tilt_deg"] = float(v["deg"])
            rec["primary_method"] = k
            break
    return rec


def _norm_angle(a):
    while a > 90:
        a -= 180
    while a < -90:
        a += 180
    return a


def reliability_probe(base_jpg_600, tag):
    """在 600×600 成片上做已知旋转 + 等比缩放的测量精度标定。

    等比缩放（不是改规格裁剪）——只有等比才不改变角度。
    缩放基准取 **spec 锁定的头高比 0.62**（compose 的
    achievedHeadHeightRatio 实测恒为 0.62，见 P0_compose_items.jsonl），
    不取 Haar 人脸框高（Haar 框只覆盖眉—口，不等于头顶—下巴）。
    """
    im0 = Image.open(base_jpg_600).convert("RGB")
    out = {"base": base_jpg_600.replace("\\", "/"), "tag": tag, "scales": {}}
    # 各规格成片的头高（headHeightRatio=0.62 由 spec 锁定）
    targets = {"cn_1inch_295x413": (295, 413),
               "cn_big_1inch_390x567": (390, 567),
               "visa_us_600x600": (600, 600)}
    for name, (w, h) in targets.items():
        # 等比缩放到与目标规格相同的"头顶—下巴"像素高度
        side = int(round(h * (0.62 * h) / (0.62 * 600)))
        ims = im0.resize((side, side), Image.LANCZOS)
        recs = {}
        for d in (0.0, 2.0, -2.0, 5.0, -5.0):
            # PIL.rotate(+a) 逆时针 → 使 tilt 减少 a；要得到 tilt+d 需转 -d
            rot = ims.rotate(-d, resample=Image.BICUBIC, center=(side / 2, side / 2))
            g = L.gray_of(rot)
            hs2 = haar_seeds(g)
            if not hs2:
                recs[f"{d:+.0f}"] = {"error": "no_haar_face"}
                continue
            m = pupil_with_seed(g, hs2[0], hs2[1])
            recs[f"{d:+.0f}"] = ({"deg": float(m["deg"]), "eyedist": m["eyedist"],
                                  "pairCost": m["pairCost"]} if m
                                 else {"error": "no_pair"})
        out["scales"][name] = {"sidePx": side,
                               "headHeightPx": round(0.62 * h, 1),
                               "rotations": recs}
    return out


def alpha_hole_evidence():
    """读 out/P0_anchors/alpha/*_magenta.jpg，检测"底色侵入头部"（alpha 空洞）。

    洋红底重合成：alpha=0 处成片呈纯洋红 #FF00FF。头部区域（spec 锁定：
    头顶 0.08H、头高 0.62H、水平居中）内若出现成片洋红，就是抠图把脸挖掉了
    —— 与旋转无关的判定，且是用户肉眼可见的缺陷。
    """
    d = os.path.join(REPO, "out", "P0_anchors", "alpha")
    out = {}
    for p in sorted(glob.glob(os.path.join(d, "*_magenta.jpg"))):
        cid = os.path.basename(p)[:-len("_magenta.jpg")]
        im = Image.open(p).convert("RGB")
        W, H = im.size
        a = np.asarray(im).astype(int)
        mag = (a[:, :, 0] > 190) & (a[:, :, 1] < 80) & (a[:, :, 2] > 190)
        x0, x1 = int(0.12 * W), int(0.88 * W)
        y0, y1 = int(0.06 * H), int(0.72 * H)
        head = mag[y0:y1, x0:x1]
        from scipy import ndimage as ndi
        lab, n = ndi.label(head)
        big = 0
        if n:
            sizes = ndi.sum(head, lab, range(1, n + 1))
            big = int(sizes.max())
        frac = float(head.mean())
        out[cid] = {
            "magentaInHeadFrac": round(frac, 4),
            "largestBlobPx": big,
            "alphaHole": bool(frac > 0.05),
            "magentaOverallFrac": round(float(mag.mean()), 4),
            "evidence": f"out/P0_anchors/alpha/{cid}_magenta.jpg",
        }
    return out


def main():
    items = {}
    with open(OUT + r"\P0_compose_items.jsonl", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("outcome") != "ok":
                continue
            items[f"{r['id']}__{r['specId']}"] = r

    holes = alpha_hole_evidence()

    results = []
    for path in sorted(glob.glob(COMPOSED + r"\*.jpg")):
        key = os.path.basename(path)[:-4]
        it = items.get(key, {})
        rec = measure_composed(path)
        rec["id"] = it.get("id", key.split("__")[0])
        rec["specId"] = it.get("specId", key.split("__")[-1])
        rec["corpus"] = it.get("corpus")
        rec["truthTiltDeg"] = it.get("truthTiltDeg")
        rec["rollSource"] = it.get("rollSource")
        rec["faceRollDeg"] = it.get("faceRollDeg")
        rec["straightenDeg"] = it.get("straightenDeg")
        rec["outOfBoundsFraction"] = it.get("outOfBoundsFraction")
        applied = it.get("straightenDeg")
        if rec.get("primary_tilt_deg") is not None and applied is not None:
            # 实现侧恒等式：输出倾角 = 输入倾角 - 施加角，施加角 == straightenDeg
            rec["rigid_residual_deg"] = _norm_angle(
                rec["primary_tilt_deg"] + applied)
        # 可信度 1：独立方法之间的分歧（跨方法族才有意义）
        degs = []
        for k in ("m1_pupil", "m1h_pupil_haarseed", "m2_radon_yunet",
                  "m3_haar_eyeline", "m4_radon_haar"):
            v = rec.get(k)
            if isinstance(v, dict) and "deg" in v:
                degs.append(float(v["deg"]))
        rec["methodSpreadDeg"] = round(max(degs) - min(degs), 3) if len(degs) > 1 else None
        rec["methodCount"] = len(degs)
        # 保守上界：所有可用方法里 |tilt| 的最大值。门禁要保守时用它，
        # 用 primary 时会漏掉"另一族方法其实测出大角"的情形。
        if degs:
            rec["tiltAbsMaxDeg"] = round(max(abs(d) for d in degs), 3)
        hv = holes.get(rec["id"])
        if hv:
            # 原始证据，仅供排查；**不作判定**（"头部矩形内洋红占比"对头部
            # 偏小/偏心的构图会误报，实测 c04_d-10 被误报过）
            rec["alphaHoleHint"] = hv
        # 可信度 2（决定性）：测量出的"输入倾角"必须与独立测得的真值吻合。
        # 刚性残差 = 输出倾角 + 施加角，它等价于"通过生产管线回看输入图的倾角"。
        # 若它与真值差 > 2°，说明成片上的瞳孔测量落到了别的东西上（脸被抠没了、
        # 眼镜反光等），该数值不可信，不得进判据。
        if rec.get("rigid_residual_deg") is not None and rec.get("truthTiltDeg") is not None:
            rec["truthConsistencyDeg"] = round(
                _norm_angle(rec["rigid_residual_deg"] - rec["truthTiltDeg"]), 3)
        if "primary_tilt_deg" not in rec:
            rec["end_to_end_status"] = "unmeasured"
        elif rec.get("truthConsistencyDeg") is not None \
                and abs(rec["truthConsistencyDeg"]) > 2.0:
            rec["end_to_end_status"] = "reliability_mismatch"
            rec["end_to_end_note"] = (
                "成片瞳孔测量隐含的输入倾角与独立真值差 "
                f"{rec['truthConsistencyDeg']}°，测量落到异物上，本项残余不可信")
        elif rec["methodSpreadDeg"] is not None and rec["methodSpreadDeg"] > 1.5:
            rec["end_to_end_status"] = "low_confidence"
        else:
            rec["end_to_end_status"] = "ok"
        results.append(rec)

    primary = [r for r in results
               if os.path.basename(r["path"]).endswith("__cn_big_1inch.jpg")]
    scored = [r for r in primary if r["end_to_end_status"] in ("ok", "low_confidence")]
    vals = [abs(r["primary_tilt_deg"]) for r in scored]
    summary = {
        "generatedBy": "qa-batch test/batch/p0_output_residual.py",
        "note": "成片眼线残余（口径无关）：理想 0。测量只用 Python/PIL/OpenCV。",
        "primarySpec": "cn_big_1inch",
        "composedCount": len(results),
        "primaryCount": len(primary),
        "scored": len(scored),
        "primaryAbsMax": round(max(vals), 3) if vals else None,
        "primaryAbsMedian": round(float(np.median(vals)), 3) if vals else None,
        "primaryAbsMean": round(float(np.mean(vals)), 3) if vals else None,
        "primaryOver1p5": sorted(
            r["id"] for r in scored if abs(r["primary_tilt_deg"]) > 1.5),
        "unreliableMeasurement": sorted(
            r["id"] for r in primary
            if r["end_to_end_status"] == "reliability_mismatch"),
        "lowConfidence": sorted(
            r["id"] for r in primary if r["end_to_end_status"] == "low_confidence"),
        "unmeasured": sorted(
            r["id"] for r in primary if r["end_to_end_status"] == "unmeasured"),
        "alphaHoleVisualEvidence": {k: v for k, v in holes.items()
                                    if v["magentaInHeadFrac"] > 0.20},
    }
    # 按语料分组（P0.1a 只判锚点，P0.2 判 straight+uprightSynthetic）
    bycorpus = {}
    for r in primary:
        c = r.get("corpus") or "?"
        d = bycorpus.setdefault(c, {"n": 0, "scored": 0, "absMax": None,
                                    "ids": [], "over1p5": [],
                                    "unreliable": [], "unmeasured": []})
        d["n"] += 1
        if r["end_to_end_status"] in ("ok", "low_confidence"):
            d["scored"] += 1
            v = abs(r["primary_tilt_deg"])
            d["absMax"] = max(d["absMax"] or 0.0, v)
            d["ids"].append(r["id"])
            if v > 1.5:
                d["over1p5"].append(r["id"])
        elif r["end_to_end_status"] == "reliability_mismatch":
            d["unreliable"].append(r["id"])
        else:
            d["unmeasured"].append(r["id"])
    for c, d in bycorpus.items():
        if d["absMax"] is not None:
            d["absMax"] = round(d["absMax"], 3)
    summary["byCorpusPrimarySpec"] = bycorpus

    rel = {}
    for tag in ("p1", "p2", "c05"):
        p600 = COMPOSED + f"\\{tag}__visa_us.jpg"
        if os.path.exists(p600):
            rel[tag] = reliability_probe(p600, tag)
        else:
            p600b = COMPOSED + f"\\{tag}__cn_big_1inch.jpg"
            if os.path.exists(p600b):
                rel[tag] = reliability_probe(p600b, tag + "@390")
    summary["reliabilityProbeBases"] = sorted(rel.keys())

    payload = {"summary": summary, "items": results,
               "smallImageReliability": rel}
    with open(OUT + r"\P0_output_residual.json", "w", encoding="utf-8") as fh:
        json.dump(_j(payload), fh, ensure_ascii=False, indent=1)

    print(json.dumps(_j(summary), ensure_ascii=False, indent=1))
    print("\n--- cn_big_1inch 逐项 ---")
    for r in primary:
        print(f"{r['id']:<16} truth={r['truthTiltDeg']!s:<7} "
              f"src={r['rollSource']!s:<12} applied={r['straightenDeg']!s:<20} "
              f"out={r.get('primary_tilt_deg')} via={r.get('primary_method')} "
              f"m1={r.get('m1_pupil', {}).get('deg') if isinstance(r.get('m1_pupil'), dict) else None} "
              f"m1h={r.get('m1h_pupil_haarseed', {}).get('deg') if isinstance(r.get('m1h_pupil_haarseed'), dict) else None} "
              f"m3={r.get('m3_haar_eyeline', {}).get('deg') if isinstance(r.get('m3_haar_eyeline'), dict) else None}")
    print("\n--- 多规格一致（spotlight）---")
    for r in results:
        if r["id"] in ("p1", "p2", "p1_upright", "p1_d-10", "c08_d-10") \
                and "__" in os.path.basename(r["path"]):
            print(f"{r['id']:<16}{r['specId']:<14} out={r.get('primary_tilt_deg')} "
                  f"m1={r.get('m1_pupil', {}).get('deg') if isinstance(r.get('m1_pupil'), dict) else None} "
                  f"m1h={r.get('m1h_pupil_haarseed', {}).get('deg') if isinstance(r.get('m1h_pupil_haarseed'), dict) else None}")
    if rel:
        print("\n--- 瞳孔法小尺度可靠性（成片等比缩放 + 已知旋转）---")
        for tag, probe in rel.items():
            for name, s in probe.get("scales", {}).items():
                print(f"[{tag}] {name}  side={s['sidePx']}  headH≈{s['headHeightPx']}px")
                base = s["rotations"].get("+0", {})
                b0 = base.get("deg")
                for d, v in s["rotations"].items():
                    err = (f"{v['deg'] - (b0 + float(d)):+.2f}"
                           if "deg" in v and b0 is not None else "-")
                    print(f"    Δ={d:>4}  {v}   errVsBase={err}")


if __name__ == "__main__":
    main()
