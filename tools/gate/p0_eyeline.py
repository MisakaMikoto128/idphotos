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
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
