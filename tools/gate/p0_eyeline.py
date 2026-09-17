# tools/gate/p0_eyeline.py
#
# gatekeeper 的成片眼线量具：在成片上测眼线倾角（tilt），理想 0。
#
# 用途：**独立复核** qa-batch 的 `out/P0_output_residual.json`。
# 我不采信另一个 agent 的测量数字，尤其不采信它"这条量不出来"的自我判定——
# 那是这套判据里最容易藏东西的地方（ACCEPTANCE 计分口径第 7 条）。
#
# 独立性：
#   - 不 import 生产代码（生产是 Dart）
#   - 不走 qa-batch 的路径：他们用 YuNet 眼位开窗 + 多阈值暗色圆盘 blob + Radon 脊线
#     求多方法共识；我用 Haar 正脸级联 + Haar 眼级联取最大两个检测，
#     只用"左右瞳孔连线"这一个几何量。
#   - 不读 alpha、不读 ComposeDiagnostics。
#
# 口径：tilt = degrees(atan2(y_rightEye - y_leftEye, x_rightEye - x_leftEye))，
#       图像坐标 y 向下。左眼 = x 较小的那个。摆平当且仅当 tilt ≈ 0。

import argparse
import json
import math
import os
import sys

import cv2
import numpy as np

FACE_MIN = 60          # 最小正脸尺寸（390x567 成片上人脸远大于此）
MAX_TILT_GUARD = 30.0  # 超过这个角度说明是误检（证件照不会歪这么多）


def _pick_pair(eyes, face_w):
    """从 Haar 眼检测里取最可信的一对。

    取**尺寸最大的两个**，再按 x 分左右。
    刻意不做"更水平优先"的挑选——那会把角度系统性拉向 0，
    正是这套判据最怕的偏差。
    """
    cand = [e for e in eyes if e[2] >= 0.12 * face_w and e[3] >= 0.12 * face_w]
    if len(cand) < 2:
        return None
    cand.sort(key=lambda e: -float(e[2]) * float(e[3]))
    a, b = cand[0], cand[1]
    if max(a[2], b[2]) > 0 or min(a[2], b[2]) > 0:
        ratio = float(min(a[2], b[2])) / float(max(a[2], b[2]))
        if ratio < 0.6:
            return None
    ca = (a[0] + a[2] / 2.0, a[1] + a[3] / 2.0)
    cb = (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0)
    return (ca, cb) if ca[0] < cb[0] else (cb, ca)


def measure(img_bgr, cascade_face, cascade_eye, upscale=2.0):
    """返回 dict：tilt_deg / method / n_eyes / face / ok / reason

    检测在 **2 倍放大图**上做：Haar 框是整数，在 390x567 的原图上一像素
    量化 ≈ 0.6°（眼距约 95px），放大两倍后量化误差减半。
    实测过"框内最暗 25% 像素质心"的精修方案，反而更差
    （被眉毛/睫毛拽偏，自检最大误差从 0.51° 涨到 1.50°），故不采用。
    """
    if upscale != 1.0:
        g = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        g = cv2.resize(g, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)
    else:
        g = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    faces = cascade_face.detectMultiScale(g, 1.1, 5,
                                          minSize=(int(FACE_MIN * upscale), int(FACE_MIN * upscale)))
    if len(faces) == 0:
        return {"ok": False, "reason": "no_face", "tilt_deg": None}
    fx, fy, fw, fh = max(faces, key=lambda f: int(f[2]) * int(f[3]))
    roi = g[fy:fy + int(fh * 0.62), fx:fx + fw]
    eyes = cascade_eye.detectMultiScale(roi, 1.05, 6)
    pair = _pick_pair(list(eyes), fw)
    if pair is None:
        return {"ok": False, "reason": "no_eye_pair", "tilt_deg": None,
                "n_eyes": int(len(eyes))}
    (lx, ly), (rx, ry) = pair
    eyedist_raw = math.hypot(rx - lx, ry - ly)
    # 眼距合理性：正脸框宽度里，瞳距约占 0.22–0.55。不设这一关时，
    # Haar 会把"单只眼 + 眉毛/鼻孔"配成一对——实测 c07_d-3 就是被配成
    # 40.8px（同一个人其它成片是 95px），读出一个假 3.86°。
    ratio = eyedist_raw / float(fw)
    if not (0.22 <= ratio <= 0.55):
        return {"ok": False, "reason": "implausible_eyedist", "tilt_deg": None,
                "n_eyes": int(len(eyes)), "eyedist_ratio": round(ratio, 3)}
    tilt = math.degrees(math.atan2(ry - ly, rx - lx))
    if abs(tilt) > MAX_TILT_GUARD:
        return {"ok": False, "reason": "tilt_out_of_range", "tilt_deg": tilt,
                "n_eyes": int(len(eyes))}
    s = 1.0 / upscale
    return {"ok": True, "tilt_deg": tilt, "method": "haar_eyeline_2x",
            "n_eyes": int(len(eyes)),
            "left": [round((fx + lx) * s, 2), round((fy + ly) * s, 2)],
            "right": [round((fx + rx) * s, 2), round((fy + ry) * s, 2)],
            "eyedist": round(math.hypot(rx - lx, ry - ly) * s, 1),
            "face": [round(fx * s), round(fy * s), round(fw * s), round(fh * s)]}


def _rotate_full(path, theta_deg):
    """把整张成片（含背景）转出 +theta 的**眼线倾角**，用于量具自检。

    符号：cv2.getRotationMatrix2D 的正角在屏幕上逆时针，而 tilt 用 y 向下的
    atan2 —— 二者差一个负号（tilt_out = tilt_in - cv2_angle）。
    这里要的是"注入 tilt=+theta"，所以传 -theta。实测钉过，见 PITFALLS。
    """
    im = cv2.imread(path)
    h, w = im.shape[:2]
    M = cv2.getRotationMatrix2D((w / 2.0, h / 2.0), -theta_deg, 1.0)
    return cv2.warpAffine(im, M, (w, h), flags=cv2.INTER_CUBIC, borderValue=(255, 255, 255))


def cmd_selftest(args):
    cf = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    ce = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_eye.xml")
    rows = []
    for theta in (3.0, -3.0, 5.0, -5.0, 10.0, -10.0):
        r = measure(_rotate_full(args.image, theta), cf, ce)
        if not r["ok"]:
            rows.append({"injected_deg": theta, "ok": False, "reason": r["reason"]})
            print(f"  注入 {theta:+6.2f}° -> 测不出（{r['reason']}）")
            continue
        err = r["tilt_deg"] - theta
        rows.append({"injected_deg": theta, "ok": True, "recovered_deg": r["tilt_deg"],
                     "err_deg": err, "eyedist": r["eyedist"]})
        print(f"  注入 {theta:+6.2f}° -> 读回 {r['tilt_deg']:+6.2f}°  (误差 {err:+.3f}°, 眼距 {r['eyedist']})")
    good = [r for r in rows if r["ok"]]
    err = max((abs(r["err_deg"]) for r in good), default=None)
    print(f"自检可测 {len(good)}/{len(rows)}，最大误差 {err if err is None else round(err, 3)}°")
    payload = {"image": args.image, "rows": rows, "max_abs_err_deg": err,
               "pass": err is not None and err <= 0.5}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=1)
    return 0 if payload["pass"] else 1


def cmd_run(args):
    cf = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    ce = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_eye.xml")
    items = [json.loads(l) for l in open(args.items, encoding="utf-8") if l.strip()]
    rows = []
    for it in items:
        if args.spec and it.get("specId") != args.spec:
            continue
        p = it["composed"]
        if not os.path.exists(p):
            rows.append({"id": it["id"], "path": p, "ok": False, "reason": "missing_file"})
            continue
        r = measure(cv2.imread(p), cf, ce)
        r.update({"id": it["id"], "path": p, "specId": it.get("specId"),
                  "corpus": it.get("corpus"), "truthTiltDeg": it.get("truthTiltDeg"),
                  "rollSource": it.get("rollSource"),
                  "applied_straighten_deg": it.get("straightenDeg"),
                  "expectedEngineRollDeg": it.get("truthTiltDeg")})
        rows.append(r)
    ok = [r for r in rows if r.get("ok")]
    print(f"共 {len(rows)} 张，测出眼线 {len(ok)} 张")
    from collections import Counter
    print("测不出的原因：", dict(Counter(r["reason"] for r in rows if not r.get("ok"))))
    payload = {"generatedBy": "gatekeeper tools/gate/p0_eyeline.py",
               "method": "Haar 正脸级联 + Haar 眼级联，取最大两个检测按 x 分左右",
               "n": len(rows), "n_measured": len(ok), "rows": rows}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=1)
    return 0


# ---------------------------------------------------------------------------
# probe：**只观测、不改判**。把 measure() 的内部决策机械化摊开。
#
# 为什么需要它：实现方（ml-porting）对 c06_d-3 为什么测不出/测错是"盲"的 ——
# 他们只能看到最终 ok/reason，看不到中间有哪几个候选、谁被丢、按什么规则丢。
# 靠 gatekeeper 用嘴描述候选，等于让实现方依赖我的转述（转述会失真，也会被我
# 的成见污染）。所以这里把**全部**候选连同几何量一次性落盘，任何人都能自己复算。
#
# 独立性/边界（重要）：
#   - 本子命令**不参与判决**。gate_P0.dart 不调用它，改它不影响任何 PASS/FAIL。
#   - 它**不修改** measure() / _pick_pair() / run：候选重放用的是同一组常量与
#     同一个 detectMultiScale 参数，且**每张图都断言重放选出的那一对与
#     measure() 实际用的那一对逐位相同**。对不上就把 control.ok 置 false 并报错——
#     探针一旦与量具不一致，它说的任何话都不作数。
#   - `circularity_desc` / `mean_luma` 是**纯描述量，不参与 keep/drop 判定**，
#     仅为让实现方判断"这对特征像不像眼睛"。注意 Haar 框本身没有轮廓，
#     圆度是对框内 Otsu 前景最大的轮廓算的，定义见我方 PITFALLS。
# ---------------------------------------------------------------------------

def _desc_stats(gray, box_roi):
    """框内描述量：Otsu 前景最大轮廓的圆度 + 框内平均亮度。**不参与判定**。"""
    x, y, w, h = [int(v) for v in box_roi]
    x = max(x, 0); y = max(y, 0)
    patch = gray[y:y + h, x:x + w]
    if patch.size == 0:
        return {"circularity_desc": None, "mean_luma_desc": None}
    mean_luma = float(patch.mean())
    _, bw = cv2.threshold(patch, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    cnts, _ = cv2.findContours(bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    circ = None
    if cnts:
        c = max(cnts, key=cv2.contourArea)
        a = float(cv2.contourArea(c))
        p = float(cv2.arcLength(c, True))
        if p > 0:
            circ = 4.0 * math.pi * a / (p * p)
    return {"circularity_desc": None if circ is None else round(circ, 4),
            "mean_luma_desc": round(mean_luma, 2)}


def probe_image(img_bgr, cf, ce, upscale=2.0):
    """把 measure() 的整条决策链摊开成可审计的记录。只读。"""
    if upscale != 1.0:
        g = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        g = cv2.resize(g, None, fx=upscale, fy=upscale, interpolation=cv2.INTER_CUBIC)
    else:
        g = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    s = 1.0 / upscale

    faces = cf.detectMultiScale(g, 1.1, 5,
                                minSize=(int(FACE_MIN * upscale), int(FACE_MIN * upscale)))
    face_recs = [{"box_full": [round(float(fx) * s, 2), round(float(fy) * s, 2),
                               round(float(fw) * s, 2), round(float(fh) * s, 2)],
                  "area_full_px": round(float(fw) * float(fh) * s * s, 1)}
                 for (fx, fy, fw, fh) in faces]
    out = {"n_faces_detected": int(len(faces)), "face_candidates": face_recs}
    if len(faces) == 0:
        out.update({"ok": False, "reason": "no_face", "tilt_deg": None,
                    "decision": "no_face"})
        return out
    fx, fy, fw, fh = max(faces, key=lambda f: int(f[2]) * int(f[3]))
    out["face_kept"] = {"rule": "取面积最大的正脸框（detectMultiScale 的原始顺序不参与）",
                        "box_full": [round(float(fx) * s, 2), round(float(fy) * s, 2),
                                     round(float(fw) * s, 2), round(float(fh) * s, 2)],
                        "roi_full": [round(float(fx) * s, 2), round(float(fy) * s, 2),
                                     round(float(fw) * s, 2), round(float(fh * 0.62) * s, 2)],
                        "roi_rule": "g[fy : fy + fh*0.62, fx : fx + fw]（只取上 62%）"}

    roi = g[fy:fy + int(fh * 0.62), fx:fx + fw]
    eyes = list(ce.detectMultiScale(roi, 1.05, 6))
    size_floor = 0.12 * fw

    # 重放 _pick_pair 的挑选链，逐步记录 keep/drop 与规则名
    recs = []
    for (ex, ey, ew, eh) in eyes:
        passes = bool(ew >= size_floor and eh >= size_floor)
        r = {
            "box_roi": [int(ex), int(ey), int(ew), int(eh)],
            "box_full": [round((fx + ex) * s, 2), round((fy + ey) * s, 2),
                         round(ew * s, 2), round(eh * s, 2)],
            "center_full": [round((fx + ex + ew / 2.0) * s, 2),
                            round((fy + ey + eh / 2.0) * s, 2)],
            "area_roi_px": int(ew) * int(eh),
            "aspect_desc": round(float(ew) / float(eh), 4),
            "size_ratio_desc": round(float(ew) / float(fw), 4),
            "size_floor_roi_px": round(size_floor, 2),
            "passes_size_gate": passes,
        }
        r.update(_desc_stats(roi, (ex, ey, ew, eh)))
        recs.append(r)

    cand = [e for e in eyes if e[2] >= size_floor and e[3] >= size_floor]
    for r in recs:
        if not r["passes_size_gate"]:
            r["decision"] = "dropped:below_size_gate(0.12*face_w)"
            r["rank_by_area"] = None
    # _pick_pair 的实际次序：按 -w*h 排序（Python sort 稳定）
    order = sorted(range(len(eyes)), key=lambda i: -float(eyes[i][2]) * float(eyes[i][3]))
    rank = {}
    for pos, i in enumerate(order):
        if eyes[i][2] >= size_floor and eyes[i][3] >= size_floor:
            rank[i] = pos
    for i, r in enumerate(recs):
        if r["passes_size_gate"]:
            r["rank_by_area"] = rank.get(i)
            r["decision"] = ("kept:top2" if rank.get(i) is not None and rank[i] < 2
                             else "dropped:not_in_top2_by_area")
    out["n_eyes_detected_note"] = "detectMultiScale 原始输出个数"
    out["n_eyes_detected"] = int(len(eyes))
    out["eye_candidates"] = recs
    out["size_gate"] = {"rule": "ew >= 0.12*face_w AND eh >= 0.12*face_w",
                        "floor_roi_px": round(size_floor, 2),
                        "n_passing": int(len(cand))}

    pair = _pick_pair(eyes, fw)
    if pair is None:
        reason = ("no_eye_pair" if len(cand) < 2 else
                  "no_eye_pair:aspect_ratio_guard(min/max < 0.6)")
        out.update({"ok": False, "reason": reason, "tilt_deg": None,
                    "decision": "no_pair -> " + reason,
                    "note_aspect_guard":
                        "_pick_pair 里 `if max(a[2],b[2]) > 0 or min(a[2],b[2]) > 0:` "
                        "在宽度 >0 时恒真，故该守卫实际等价于无条件执行；"
                        "此处按实际行为标注，未改动量具。"})
        return out

    (lx, ly), (rx, ry) = pair
    eyedist_raw = math.hypot(rx - lx, ry - ly)
    ratio = eyedist_raw / float(fw)
    out["pair_kept"] = {
        "left_center_full": [round((fx + lx) * s, 2), round((fy + ly) * s, 2)],
        "right_center_full": [round((fx + rx) * s, 2), round((fy + ry) * s, 2)],
        "eyedist_full_px": round(eyedist_raw * s, 2),
        "eyedist_raw_roi_px": round(eyedist_raw, 2),
        "eyedist_ratio": round(ratio, 4),
        "eyedist_gate": "0.22 <= eyedist_raw/face_w <= 0.55",
        "passes_eyedist_gate": bool(0.22 <= ratio <= 0.55),
        "dx_roi_px": round(float(rx - lx), 4),
        "dy_roi_px": round(float(ry - ly), 4),
        "recompute_hint": "tilt = degrees(atan2(dy_roi, dx_roi))，"
                          "dy_roi = right.y - left.y（y 向下），left = x 较小者",
    }
    if not (0.22 <= ratio <= 0.55):
        out.update({"ok": False, "reason": "implausible_eyedist", "tilt_deg": None,
                    "decision": "pair rejected by eyedist gate"})
        return out
    tilt = math.degrees(math.atan2(ry - ly, rx - lx))
    if abs(tilt) > MAX_TILT_GUARD:
        out.update({"ok": False, "reason": "tilt_out_of_range", "tilt_deg": tilt,
                    "decision": "pair rejected by MAX_TILT_GUARD(30deg)"})
        return out
    out.update({"ok": True, "tilt_deg": tilt, "method": "haar_eyeline_2x",
                "decision": "kept"})
    m = measure(img_bgr, cf, ce, upscale=upscale)
    out["measure_agrees"] = bool(
        m.get("ok") == out["ok"] and m.get("tilt_deg") == out["tilt_deg"]
        and m.get("left") == [out["pair_kept"]["left_center_full"][0],
                              out["pair_kept"]["left_center_full"][1]]
        and m.get("right") == [out["pair_kept"]["right_center_full"][0],
                               out["pair_kept"]["right_center_full"][1]])
    out["measure_tilt_deg"] = m.get("tilt_deg")
    return out


def cmd_probe(args):
    """落盘全部候选 + 先跑已知答案对照。对照不过 -> 退出码非 0，别信后面的数。"""
    cf = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    ce = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_eye.xml")

    # ---- 已知答案对照（先证明探针说真话，再拿它看争议样本）----
    ctrl_img = cv2.imread(args.control_image) if args.control_image else None
    checks = []
    control_ok = True
    if ctrl_img is not None:
        base = probe_image(ctrl_img, cf, ce)
        m0 = measure(ctrl_img, cf, ce)
        c1 = (base.get("ok") == m0.get("ok")
              and base.get("tilt_deg") == m0.get("tilt_deg"))
        checks.append({"check": "探针重放 == measure()（同一张图，同 code path）",
                       "pass": bool(c1),
                       "probe": base.get("tilt_deg"), "measure": m0.get("tilt_deg")})
        control_ok = control_ok and c1
        for theta in (3.0, -3.0):
            rot = _rotate_full(args.control_image, theta)
            pb = probe_image(rot, cf, ce)
            if base.get("tilt_deg") is None or pb.get("tilt_deg") is None:
                checks.append({"check": f"注入 {theta:+.1f}° 后读数", "pass": False,
                               "note": "有一侧测不出，对照不可判"})
                control_ok = False
                continue
            expect = base["tilt_deg"] + theta
            got = pb["tilt_deg"]
            ok = abs(got - expect) <= 0.5
            checks.append({"check": f"注入 {theta:+.1f}° -> 期望 {expect:+.3f}°",
                           "pass": bool(ok), "probe": round(got, 3),
                           "err_deg": round(got - expect, 3)})
            control_ok = control_ok and ok
    else:
        checks.append({"check": "已知答案对照", "pass": False,
                       "note": "未提供 --control-image，对照未跑"})
        control_ok = False

    cases = []
    items = [json.loads(l) for l in open(args.items, encoding="utf-8") if l.strip()]
    for it in items:
        if args.id and it["id"] not in args.id:
            continue
        p = it.get("composed")
        if not p or not os.path.exists(p):
            cases.append({"id": it["id"], "path": p, "ok": False,
                          "reason": "missing_file", "decision": "missing_file"})
            continue
        rec = probe_image(cv2.imread(p), cf, ce)
        rec.update({"id": it["id"], "path": p, "specId": it.get("specId"),
                    "corpus": it.get("corpus"), "truthTiltDeg": it.get("truthTiltDeg"),
                    "applied_straighten_deg": it.get("straightenDeg")})
        cases.append(rec)
        print(f"  {it['id']:16s} ok={str(rec.get('ok')):5s} "
              f"tilt={rec.get('tilt_deg')} 面孔 {rec.get('n_faces_detected')} "
              f"眼候选 {rec.get('n_eyes_detected')} -> {rec.get('decision')}")

    print(f"已知答案对照：{'通过' if control_ok else '**未通过 —— 后面的数不可信**'}")
    for c in checks:
        print(f"  [{'OK' if c['pass'] else '!!'}] {c['check']}  {c}")
    payload = {"generatedBy": "gatekeeper tools/gate/p0_eyeline.py probe",
               "role": "只观测、不改判；不参与任何 PASS/FAIL",
               "control": {"ok": bool(control_ok), "checks": checks},
               "cases": cases}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=1)
    return 0 if control_ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("selftest")
    st.add_argument("--image", required=True)
    st.add_argument("--out")
    st.set_defaults(func=cmd_selftest)
    rn = sub.add_parser("run")
    rn.add_argument("--items", required=True)
    rn.add_argument("--spec", default="cn_big_1inch")
    rn.add_argument("--out", required=True)
    rn.set_defaults(func=cmd_run)
    pb = sub.add_parser("probe")
    pb.add_argument("--items", required=True)
    pb.add_argument("--id", action="append", default=[])
    pb.add_argument("--control-image", default="")
    pb.add_argument("--out", required=True)
    pb.set_defaults(func=cmd_probe)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
