# -*- coding: utf-8 -*-
"""qa-batch：生成目视复核用的联络表（contact sheet）。

每行一张候选图：以双眼连线中点为中心的 3x 放大裁剪，
画出 M1 检出的瞳孔、各方法的过中点直线、以及过左瞳孔的水平参考线。
判读方法：瞳孔圈是否落在真实瞳孔上；连线是否与真实瞳孔连线重合。

用法：python test/batch/p0_sheet.py <out.png> <id>:<path> ...
"""
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math  # noqa: E402

import p0_lib as L  # noqa: E402

ROW_H = 300
COL_W = 1180


def row_image(cid, path):
    im, scale, faces = L.detect_faces(path)
    if not faces:
        return None, {"id": cid, "error": "no face"}
    f = L.pick_face(faces, im.size)
    gray = L.gray_of(im)
    res = L.measure_all(gray, f)
    degs = L.methods_deg(res)
    il, ir = L.eye_pair(f["kps"])
    ed = math.hypot(ir[0] - il[0], ir[1] - il[1])
    mx, my = (il[0] + ir[0]) / 2.0, (il[1] + ir[1]) / 2.0
    # 裁剪中心优先用 M1 实测瞳孔中点（YuNet 眼位本身可能就是错的，不能拿它定位）
    m1v = res.get("m1_pupil")
    if isinstance(m1v, dict) and "left" in m1v:
        mx = (m1v["left"][0] + m1v["right"][0]) / 2.0
        my = (m1v["left"][1] + m1v["right"][1]) / 2.0
    pad = 0.55 * ed
    x0 = int(max(0, mx - 1.45 * ed)); x1 = int(min(im.size[0], mx + 1.45 * ed))
    y0 = int(max(0, my - pad)); y1 = int(min(im.size[1], my + pad))
    crop = im.crop((x0, y0, x1, y1))
    k = max(1, int(COL_W / max(1, crop.size[0])))
    crop = crop.resize((crop.size[0] * k, crop.size[1] * k), Image.LANCZOS)
    crop = crop.crop((0, 0, COL_W, min(ROW_H, crop.size[1])))
    # 顶部留 22px 写读数
    out = Image.new("RGB", (COL_W, ROW_H + 22), (16, 16, 16))
    out.paste(crop, (0, 22))
    d = ImageDraw.Draw(out)

    def X(v):
        return (v - x0) * k

    def Y(v):
        return (v - y0) * k + 22

    # 水平参考线（黄）：过左瞳孔
    m1 = res.get("m1_pupil")
    if isinstance(m1, dict) and "left" in m1:
        yy = Y(m1["left"][1])
        d.line([0, yy, COL_W, yy], fill=(255, 255, 0), width=1)
    if m1 and "left" in m1:
        for p in (m1["left"], m1["right"]):
            d.ellipse([X(p[0]) - 5, Y(p[1]) - 5, X(p[0]) + 5, Y(p[1]) + 5],
                      outline=(0, 255, 0), width=2)
    m3 = res.get("m3_haar_eyeline")
    if isinstance(m3, dict) and "left" in m3:
        for p in (m3["left"], m3["right"]):
            d.ellipse([X(p[0]) - 9, Y(p[1]) - 9, X(p[0]) + 9, Y(p[1]) + 9],
                      outline=(255, 60, 60), width=2)
    # 各方法过眼中点的直线
    for name, col in (("m1_pupil", (0, 255, 0)), ("m2_radon_yunet", (0, 190, 255)),
                      ("m3_haar_eyeline", (255, 60, 60)), ("m4_radon_haar", (255, 0, 255))):
        v = res.get(name)
        if isinstance(v, dict) and "deg" in v:
            t = math.radians(v["deg"])
            cxp, cyp = X(mx), Y(my)
            Lp = COL_W
            d.line([cxp - Lp * math.cos(t), cyp - Lp * math.sin(t),
                    cxp + Lp * math.cos(t), cyp + Lp * math.sin(t)], fill=col, width=1)
    txt = "%s  " % cid + "  ".join("%s=%.2f" % (n.split("_")[0], v)
                                   for n, v in degs.items())
    txt += "  | yunet=%.2f ed=%.0f" % (res["yunet_eyeline"], ed)
    d.text((4, 5), txt, fill=(255, 255, 255))
    return out, {"id": cid, "methods": degs, "yunet": res["yunet_eyeline"], "ed": ed}


def main():
    out_path = sys.argv[1]
    pairs = [a.split(":", 1) for a in sys.argv[2:]]
    rows = []
    for cid, path in pairs:
        img, meta = row_image(cid, path)
        if img is None:
            print("SKIP", meta)
            continue
        rows.append(img)
        print(meta)
    if not rows:
        return
    sheet = Image.new("RGB", (COL_W, (ROW_H + 22) * len(rows)), (16, 16, 16))
    for i, r in enumerate(rows):
        sheet.paste(r, (0, i * (ROW_H + 22)))
    sheet.save(out_path)
    print("->", out_path, sheet.size)


if __name__ == "__main__":
    main()
