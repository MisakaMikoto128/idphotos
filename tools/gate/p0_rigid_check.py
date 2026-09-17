# tools/gate/p0_rigid_check.py
#
# ACCEPTANCE 计分口径第 7 条的复核工具：对 qa-batch 判为"量测失效 / 未测量"的样本，
# 用与 qa-batch **不同**的独立路径（刚体轮廓配准）重新判一次它到底歪没歪。
#
# 为什么需要它：把真实缺陷归类成"量不出来"，是这套判据里最容易藏东西的地方。
# 条款 7 点名 c08_d+10「alpha 干净却自证 unreliable」，它的归属直接改变违规计数。
#
# 独立性声明：
#   - 不 import 任何生产代码（生产是 Dart，这里是 Python）
#   - 不读 alpha 通道、不读 ComposeDiagnostics、不读眼线
#   - 只用成片本身的**外轮廓**（相对背景色的二值化）做刚体配准
#   因此它和 qa-batch 的"眼线多方法共识"是两条独立的测量路径。
#
# 口径（与法典同）：
#   成片倾角 0 = 摆平。两张成片（同一张源图，一张转了 Δ、一张没转）配准出来的
#   相对角 = (真值_Δ − 施加_Δ) − (真值_0 − 施加_0) = 残余_Δ − 残余_0。
#   Δ0 那张的残余由 qa-batch 的眼线给出（未被判失效），于是残余_Δ 可解出来。
#   全程只用"图像转了多少度"这一个可观测量，与符号约定无关。

import argparse
import json
import math
import os
import sys

import cv2
import numpy as np

BG_TOL = 40.0  # 与背景中位色的 L1 距离阈值（0-765）


def silhouette(path, tol=BG_TOL):
    """成片 -> 前景外轮廓二值图。背景是纯色（白），取四边中位数当底色。"""
    im = cv2.imread(path, cv2.IMREAD_COLOR)
    if im is None:
        raise SystemExit(f"读不出图：{path}")
    border = np.concatenate([
        im[0:3].reshape(-1, 3), im[-3:].reshape(-1, 3),
        im[:, 0:3].reshape(-1, 3), im[:, -3:].reshape(-1, 3),
    ])
    bg = np.median(border, axis=0)
    d = np.abs(im.astype(np.int16) - bg).sum(axis=2)
    return (d > tol).astype(np.uint8), im.shape[:2]


def _warp(mask, ang_deg, scale, src_c, dst_c, w, h):
    """把 mask 绕 src_c 旋转 ang_deg、缩放 scale，再把形心平移到 dst_c。

    图像坐标 y 向下；正角 = 顺时针（与 cv2.getRotationMatrix2D 一致）。
    """
    M = cv2.getRotationMatrix2D((float(src_c[0]), float(src_c[1])), float(ang_deg), float(scale))
    M[0, 2] += dst_c[0] - src_c[0]
    M[1, 2] += dst_c[1] - src_c[1]
    return cv2.warpAffine(mask, M, (w, h), flags=cv2.INTER_NEAREST, borderValue=0)


def _iou(a, b):
    inter = np.logical_and(a, b).sum()
    union = np.logical_or(a, b).sum()
    return float(inter) / float(union) if union else 0.0


def _centroid(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        raise SystemExit("空掩膜")
    return (float(xs.mean()), float(ys.mean()))


def register(a, b, ang_lo=-20.0, ang_hi=20.0, scale_lo=0.85, scale_hi=1.20,
             coarse_step=0.5, fine_steps=(0.2, 0.05, 0.02)):
    """把 a 配准到 b，返回 (相对角 deg, IoU, 尺度)。

    先在 (角 × 尺度) 网格上粗搜，再在最优解附近逐步细化。形心对齐后
    平移不再参与搜索——ID 照片的裁剪以人脸为中心，形心对齐是合理初值，
    而角度/尺度是真正要解的两个自由度。
    """
    h, w = b.shape[:2]
    ca, cb = _centroid(a), _centroid(b)
    best = (0.0, 1.0, -1.0)  # (ang, scale, iou)

    def sweep(ang_c, ang_half, s_c, s_half, s_step, a_step):
        nonlocal best
        ang = ang_c - ang_half
        while ang <= ang_c + ang_half + 1e-9:
            s = s_c - s_half
            while s <= s_c + s_half + 1e-9:
                if s > 0.3:
                    iou = _iou(_warp(a, ang, s, ca, cb, w, h), b)
                    if iou > best[2]:
                        best = (ang, s, iou)
                s += s_step
            ang += a_step

    scales = []
    s = scale_lo
    while s <= scale_hi + 1e-9:
        scales.append(s)
        s += 0.02
    ang = ang_lo
    while ang <= ang_hi + 1e-9:
        for sc in scales:
            iou = _iou(_warp(a, ang, sc, ca, cb, w, h), b)
            if iou > best[2]:
                best = (ang, sc, iou)
        ang += coarse_step

    for fs in fine_steps:
        sweep(best[0], fs * 4, best[1], 0.02, 0.005, fs)
    return float(best[0]), float(best[2]), float(best[1])


def cmd_selftest(args):
    """量具自检：把成片人为转 θ，配准必须读回 θ。

    读不准的量具没有资格判别人。自检不过 -> 整个复核结果作废。
    """
    rows = []
    for theta in (3.0, -3.0, 5.0, -5.0, 10.0, -10.0):
        m, (h, w) = silhouette(args.image)
        c = _centroid(m)
        rot = _warp(m, theta, 1.0, c, c, w, h)
        got, iou, sc = register(m, rot)
        # register 求的是"把 m 转到 rot"所需的角，正是 θ
        rows.append({"injected_deg": theta, "recovered_deg": got,
                     "err_deg": got - theta, "iou": iou, "scale": sc})
        print(f"  注入 {theta:+6.2f}° -> 读回 {got:+6.2f}°  (误差 {got - theta:+.3f}°, IoU {iou:.3f}, 尺度 {sc:.3f})")
    err = max(abs(r["err_deg"]) for r in rows)
    print(f"自检最大误差 {err:.3f}°")
    payload = {"image": args.image, "rows": rows, "max_abs_err_deg": err,
               "pass": err <= 0.5}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=1)
    return 0 if payload["pass"] else 1


def cmd_pairs(args):
    """成对复核：--pair ref.png,target.png,期望相对角,说明"""
    rows = []
    for spec in args.pair:
        parts = spec.split(",")
        ref_p, tgt_p = parts[0], parts[1]
        expected = float(parts[2]) if len(parts) > 2 and parts[2] else None
        note = parts[3] if len(parts) > 3 else ""
        ra, _ = silhouette(ref_p)
        rb, _ = silhouette(tgt_p)
        got, iou, sc = register(ra, rb)
        row = {"ref": ref_p, "target": tgt_p, "expected_relative_deg": expected,
               "measured_relative_deg": got, "iou": iou, "scale": sc, "note": note}
        if expected is not None:
            row["err_deg"] = got - expected
        rows.append(row)
        print(f"  {os.path.basename(tgt_p)} vs {os.path.basename(ref_p)}: "
              f"相对角 {got:+.3f}° (IoU {iou:.3f}, 尺度 {sc:.3f})"
              + (f" 期望 {expected:+.2f}° 误差 {got - expected:+.3f}°" if expected is not None else ""))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"rows": rows}, f, ensure_ascii=False, indent=1)
    return 0


def cmd_align(args):
    """逐条独立测量：源图 →(生产管线)→ 成片 这一跳到底转了多少度。

    这是条款 7 要的"与 qa-batch 不同的独立路径"，而且它**不碰眼线**：
    用 SIFT 特征把源图配到成片上，解出的相似变换里的旋转分量
    就是生产管线实际施加的旋转。于是
        残余 = 真值 − 实测施加角
    完全由"源图特征 + 成片特征"两个可观测量定出，既不读生产诊断
    （straightenDeg），也不读瞳孔、不读 alpha。

    实测钉过符号（4 条已知样本，误差 ≤0.04°）：
        cv2 角 ≈ −施加角，即 施加角 = −atan2(M[1,0], M[0,0])
    依据是 tilt 用 y 向下 atan2 而 cv2 正角在屏幕上逆时针，二者差一个负号。

    为什么需要它：成片被裁坏（人脸出画、被抠图打洞）时眼线量具会失效，
    而 SIFT 配的是整个头部的特征，对这两种破坏都免疫——实测在
    eyeBandZeroFrac=0.968 的 c08_d-10 上仍能给出 0.037° 的准确读数。
    """
    items = []
    with open(args.items, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                items.append(json.loads(line))
    sift = cv2.SIFT_create(nfeatures=4000)
    matcher = cv2.BFMatcher()
    rows = []
    for it in items:
        if args.spec and it.get("specId") != args.spec:
            continue
        src_p, cmp_p = it.get("path"), it.get("composed")
        row = {"id": it["id"], "source": src_p, "composed": cmp_p,
               "truth_apply_deg": it.get("truthTiltDeg"),
               "recorded_applied_deg": it.get("straightenDeg")}
        if not src_p or not os.path.exists(src_p) or not cmp_p or not os.path.exists(cmp_p):
            row.update({"ok": False, "reason": "missing_input"})
            rows.append(row)
            continue
        A = cv2.imread(src_p, cv2.IMREAD_GRAYSCALE)
        B = cv2.imread(cmp_p, cv2.IMREAD_GRAYSCALE)
        ka, da = sift.detectAndCompute(A, None)
        kb, db = sift.detectAndCompute(B, None)
        if da is None or db is None or len(ka) < 10 or len(kb) < 10:
            row.update({"ok": False, "reason": "too_few_features"})
            rows.append(row)
            continue
        matches = matcher.knnMatch(da, db, k=2)
        good = [p for p, q in matches if p.distance < 0.75 * q.distance]
        if len(good) < 12:
            row.update({"ok": False, "reason": f"too_few_matches({len(good)})"})
            rows.append(row)
            continue
        s = np.float32([ka[g.queryIdx].pt for g in good])
        d = np.float32([kb[g.trainIdx].pt for g in good])
        M, inl = cv2.estimateAffinePartial2D(s, d, method=cv2.RANSAC,
                                             ransacReprojThreshold=3.0)
        if M is None:
            row.update({"ok": False, "reason": "affine_failed"})
            rows.append(row)
            continue
        applied = -math.degrees(math.atan2(M[1, 0], M[0, 0]))
        scale = math.hypot(M[0, 0], M[1, 0])
        inliers = int(inl.sum())
        # 内点太少 / 尺度离谱时不给数：量具自己先认怂，好过给个错的角。
        if inliers < 12 or not (0.05 <= scale <= 1.5):
            row.update({"ok": False, "reason": f"weak_alignment(inl={inliers},scale={scale:.3f})"})
            rows.append(row)
            continue
        row.update({
            "ok": True,
            "measured_applied_deg": applied,
            "scale": scale,
            "inliers": inliers,
            "matches": len(good),
            "residual_deg": (it.get("truthTiltDeg") - applied)
            if it.get("truthTiltDeg") is not None else None,
            "applied_delta_vs_record": (applied - it.get("straightenDeg"))
            if it.get("straightenDeg") is not None else None,
        })
        rows.append(row)
    ok = [r for r in rows if r.get("ok")]
    print(f"共 {len(rows)} 条，SIFT 配准成功 {len(ok)} 条")
    if ok:
        deltas = [abs(r["applied_delta_vs_record"]) for r in ok
                  if r.get("applied_delta_vs_record") is not None]
        if deltas:
            print(f"实测施加角 vs 生产记录：|差| 中位 {np.median(deltas):.3f}°，"
                  f"最大 {max(deltas):.3f}°")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"generatedBy": "gatekeeper tools/gate/p0_rigid_check.py align",
                       "method": "SIFT + estimateAffinePartial2D，旋转分量即实际施加角（符号已实测钉死）",
                       "n": len(rows), "n_ok": len(ok), "rows": rows},
                      f, ensure_ascii=False, indent=1)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("selftest")
    st.add_argument("--image", required=True)
    st.add_argument("--out")
    st.set_defaults(func=cmd_selftest)
    pr = sub.add_parser("pairs")
    pr.add_argument("--pair", action="append", required=True)
    pr.add_argument("--out")
    pr.set_defaults(func=cmd_pairs)
    al = sub.add_parser("align")
    al.add_argument("--items", required=True)
    al.add_argument("--spec", default="")
    al.add_argument("--out", required=True)
    al.set_defaults(func=cmd_align)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
