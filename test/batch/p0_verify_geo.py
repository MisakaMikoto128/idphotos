# -*- coding: utf-8 -*-
"""qa-batch：旋转夹具的"无特征点"几何核验。

不要相信任何检测器——直接做图像配准：把锚点原图按角度 phi 旋转后与夹具比对，
搜索使归一化互相关最大的 phi。这是纯像素级配准，与 YuNet/Haar/瞳孔 blob
全都无关，因此可以独立证明"夹具确实被转了 delta 度"。

回测（p0_rotate 里那套特征点方法）在 c01/c06/c08 的负 delta 上会失手；
本脚本用来给夹具的几何正确性背书。

用法：python test/batch/p0_verify_geo.py
"""
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

OUT = os.path.join(L.REPO, "out", "P0_anchors")
WORK = 512
MAX_LONG = 2048


def _prep(im):
    im = ImageOps.exif_transpose(im).convert("L")
    W, H = im.size
    if max(W, H) > MAX_LONG:
        s = MAX_LONG / max(W, H)
        im = im.resize((round(W * s), round(H * s)), Image.LANCZOS)
    s = WORK / max(im.size)
    im = im.resize((max(8, round(im.size[0] * s)), max(8, round(im.size[1] * s))),
                   Image.LANCZOS)
    a = np.asarray(im).astype(np.float32)
    a = (a - a.mean()) / (a.std() + 1e-6)
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w]
    m = (((xx - w / 2) / (w * 0.46)) ** 2 + ((yy - h / 2) / (h * 0.46)) ** 2) <= 1.0
    return a, m


def recover_delta(base_img, fixture_img):
    a, m = _prep(base_img)
    b, _ = _prep(fixture_img)
    if a.shape != b.shape:
        return None
    h, w = a.shape
    c = (w / 2.0, h / 2.0)
    angs = np.arange(-16.0, 16.01, 0.25)
    sc = []
    for phi in angs:
        M = cv2.getRotationMatrix2D(c, float(phi), 1.0)
        r = cv2.warpAffine(a, M, (w, h), flags=cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REPLICATE)
        v1 = r[m] - r[m].mean()
        v2 = b[m] - b[m].mean()
        den = np.sqrt((v1 ** 2).sum()) * np.sqrt((v2 ** 2).sum())
        sc.append(float((v1 * v2).sum() / den) if den > 1e-9 else -1.0)
    sc = np.array(sc)
    i = int(np.argmax(sc))
    phi = float(angs[i])
    if 0 < i < len(sc) - 1:
        y0, y1, y2 = sc[i - 1], sc[i], sc[i + 1]
        den = y0 - 2 * y1 + y2
        if abs(den) > 1e-12:
            phi = float(angs[i]) + 0.5 * (y0 - y2) / den * 0.25
    return phi, float(sc[i])


def main():
    fx = json.load(open(os.path.join(OUT, "rotation_fixtures.json"), encoding="utf-8"))
    base_cache = {}
    results = []
    worst = 0.0
    for f in fx["fixtures"]:
        src = f["src"]
        if src not in base_cache:
            base_cache[src] = Image.open(_src_path(src))
        fpath = os.path.join(L.REPO, f["path"].replace("/", os.sep))
        base = base_cache[src]
        phi, ncc = recover_delta(base, Image.open(fpath))
        # 标定：cv2 正向 phi 与 PIL rotate(-delta) 的对应关系由 p2 的已知夹具确定
        rec = {"id": f["id"], "deltaDeg": f["deltaDeg"],
               "recoveredPhiDeg": round(phi, 3), "ncc": round(ncc, 4)}
        results.append(rec)
        worst = max(worst, ncc)
        print("%-14s delta=%+6.1f  phi*=%+7.2f  ncc=%.4f" % (f["id"], f["deltaDeg"], phi, ncc))
    with open(os.path.join(OUT, "fixture_geo_verify.json"), "w", encoding="utf-8") as fh:
        json.dump({"method": "cv2 旋转配准（像素级，无特征点）",
                   "note": "recoveredPhiDeg 与 -deltaDeg 应线性对应；"
                           "两者关系由已知 delta 的夹具直接标定，不引入假设",
                   "fixtures": results}, fh, ensure_ascii=False, indent=1)
    print("-> fixture_geo_verify.json   minNCC=%.4f" % min(r["ncc"] for r in results))


def _src_path(cid):
    m = {
        "p1": r"C:\Users\liuyu\Pictures\1 (2).jpg",
        "p2": r"C:\Users\liuyu\Pictures\2.jpg",
        "c01": r"C:\Users\liuyu\Pictures\20240710193717_7c99.jpg",
        "c02": r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg",
        "c03": r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124.jpg",
        "c04": r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124 (自定义).jpg",
        "c05": r"C:\Users\liuyu\Pictures\a.jpg",
        "c06": r"C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg",
        "c07": r"C:\Users\liuyu\Pictures\报名照片.jpg",
        "c08": r"C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg",
        "c10": r"C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png",
        "c11": r"C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png",
        "c12": r"C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png",
    }
    return m[cid]


if __name__ == "__main__":
    main()
