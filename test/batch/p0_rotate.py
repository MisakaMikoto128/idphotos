# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 旋转等变法夹具生成（P0.3 的输入）。

deltaDeg 的定义（关键，别搞混）：
    夹具的"应有 tilt" = 锚点真值 tilt + deltaDeg
    tilt 约定见 p0_lib 头部。
    生成方式：PIL.Image.rotate(-deltaDeg, BICUBIC)。
    实测标定：PIL rotate(+a) → tilt 变化 -a（见 out/P0_anchors/rotation_calib.json）。

落盘 PNG（无损，避免二次 JPEG 量化污染量测）：
    out/P0_anchors/<id>_d<±N>.png
每个夹具同时用 Python 方法回测，记录 measuredTilt，供 gatekeeper 确认
"夹具本身确实是这个角度"（夹具错了，斜率判定就无意义）。

用法：python test/batch/p0_rotate.py
"""
import json
import math
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

OUT = os.path.join(L.REPO, "out", "P0_anchors")
DELTAS = [-10.0, -5.0, -3.0, 3.0, 5.0, 10.0]
MAX_LONG = 2048


def make_fixture(src, delta, dst):
    im = Image.open(src)
    im = ImageOps_exif(im).convert("RGB")
    W, H = im.size
    if max(W, H) > MAX_LONG:
        s = MAX_LONG / max(W, H)
        im = im.resize((round(W * s), round(H * s)), Image.LANCZOS)
    rot = im.rotate(-delta, resample=Image.BICUBIC, expand=False,
                    fillcolor=(255, 255, 255))
    rot.save(dst)
    return rot.size


def ImageOps_exif(im):
    from PIL import ImageOps
    return ImageOps.exif_transpose(im)


def measure(path):
    im, scale, faces = L.detect_faces(path)
    if not faces:
        return None
    f = L.pick_face(faces, im.size)
    gray = L.gray_of(im)
    res = L.measure_all(gray, f)
    d = L.methods_deg(res)
    d["_yunet"] = res["yunet_eyeline"]
    return d


def main():
    truth = json.load(open(os.path.join(OUT, "anchors_base.json"), encoding="utf-8"))
    anchors = {a["id"]: a for a in truth["anchors"] + truth.get("straight", [])}
    out = {"deltas": DELTAS, "fixtures": []}
    for cid, a in anchors.items():
        if a.get("excluded"):
            continue
        base = float(a["trueRollDeg"])
        for delta in DELTAS:
            tag = "%s_d%+d" % (cid, int(delta)) if delta == int(delta) else \
                  "%s_d%+.1f" % (cid, delta)
            dst = os.path.join(OUT, "%s.png" % tag)
            size = make_fixture(a["path"], delta, dst)
            m = measure(dst)
            rec = {"id": tag, "src": cid, "deltaDeg": delta,
                   "baseTrueRollDeg": base,
                   "expectedTiltDeg": round(base + delta, 3),
                   "path": dst.replace("\\", "/").replace(L.REPO.replace("\\", "/") + "/", ""),
                   "wh": list(size)}
            if m:
                rec["measuredTiltDeg"] = {k: round(v, 3) for k, v in m.items()}
                vals = [v for k, v in m.items() if k != "_yunet"]
                cons = float(sorted(vals)[len(vals) // 2])
                rec["measuredConsensusDeg"] = round(cons, 3)
                rec["measuredSpreadDeg"] = round(max(vals) - min(vals), 3)
                rec["verifyDeltaDeg"] = round(cons - (base + delta), 3)
                # 回测失败：夹具本身没错（纯几何旋转），错的是回测方法在
                # 该图上不可靠。标出来，别让 gatekeeper 误判成"夹具角度不对"。
                rec["verifyOk"] = abs(cons - (base + delta)) <= 1.5
                if not rec["verifyOk"]:
                    rec["verifyNote"] = ("Python 回测与几何期望不符：该图上回测方法"
                                         "不可靠（非夹具角度错误，旋转为纯几何变换）")
            else:
                rec["measuredTiltDeg"] = None
                rec["verifyOk"] = False
                rec["verifyNote"] = "回测未检出人脸"
            out["fixtures"].append(rec)
            print("%-14s exp=%7.2f  spread=%5s  verify=%s  %s" % (
                tag, base + delta,
                "%s" % rec.get("measuredSpreadDeg"),
                "OK " if rec["verifyOk"] else "BAD",
                " ".join("%s=%.2f" % (k.split("_")[0], v) for k, v in (m or {}).items())))
    with open(os.path.join(OUT, "rotation_fixtures.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print("->", os.path.join(OUT, "rotation_fixtures.json"))


if __name__ == "__main__":
    main()
