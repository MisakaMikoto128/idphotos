# -*- coding: utf-8 -*-
"""qa-batch：P0 真值的**独立复核**——用与瞳孔法无关的特征族测倾角。

为什么需要它：`out/P0_truth.json` 的真值（code 里 `p0_finalize.py` 的 ANCHORS 表）
主值取自 M1 = 瞳孔/暗色圆盘 blob 法，而**被测引擎同样依赖瞳孔**
（`iris_roll.dart` 的 `estimatePupilRoll`）。真值与被测对象同族 ⇒ 二者会**同时错**，
门禁看不出来。本条用一条完全不同的特征族做第二读数。

方法与它的独立性：
  * 本文件用**整脸双侧对称轴**（高通后的梯度结构做镜像 NCC），不用瞳孔、
    不用眼睑关键点、不用虹膜圆盘。失效模式与瞳孔高光/鼻托反光无关。
  * ROI 由 YuNet 脸框给出——**只用于定位**，角度完全由对称性搜索决定。

自检（不依赖任何真值）：对已知旋转量的夹具 `<id>_d±N` 测量，
`meas(Δ) − meas(0)` 必须等于施加的 Δ。**这一条不通过，本文件的任何绝对读数都不得采信。**

用法：
    python test/batch/p0_independent_roll.py check  <id>     # 只跑标定自检
    python test/batch/p0_independent_roll.py report <id>...  # 标定 + 输出绝对读数
"""
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

BASE = os.path.join(L.REPO, "out", "P0_anchors")
DELTAS = (-10.0, -5.0, -3.0, 0.0, 3.0, 5.0, 10.0)


def _fixture_name(cid, delta):
    if delta == 0:
        return "%s.png" % cid
    return "%s_d%+d.png" % (cid, int(delta))


def face_roi(path, target=300):
    """返回以最大脸为中心的正方形 ROI（灰度 float32），以及是否成功。

    注意：这里**不用 cv2.warpAffine 做缩放**——本机 OpenCV 4.10 在
    `dsize` 小于源图且变换含缩放时返回**全零**（见 PITFALLS）。
    改用 crop + resize，语义相同且无此问题。
    """
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    bgr = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    H, W = bgr.shape[:2]
    d = cv2.FaceDetectorYN.create(L.YUNET, "", (W, H), score_threshold=0.5,
                                  nms_threshold=0.3, top_k=50)
    d.setInputSize((W, H))
    _, faces = d.detect(bgr)
    if faces is None or len(faces) == 0:
        return None
    f = max(faces, key=lambda r: r[2] * r[3])          # 仅定位
    x, y, w, h = [float(v) for v in f[0:4]]
    cx, cy = x + w / 2.0, y + h / 2.0
    side = max(w, h) * 1.15
    x0, y0 = int(round(cx - side / 2)), int(round(cy - side / 2))
    x1, y1 = int(round(cx + side / 2)), int(round(cy + side / 2))
    # 越界就整体平移回来（不裁掉内容）
    if x0 < 0:
        x1 -= x0; x0 = 0
    if y0 < 0:
        y1 -= y0; y0 = 0
    x1 = min(x1, W); y1 = min(y1, H)
    if x1 - x0 < 40 or y1 - y0 < 40:
        return None
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    crop = gray[y0:y1, x0:x1]
    n = target - (target % 2)
    roi = cv2.resize(crop, (n, n), interpolation=cv2.INTER_AREA)
    # 高通：去掉光照梯度，只留结构（对称性判据只该看结构）
    return roi - cv2.GaussianBlur(roi, (0, 0), n / 14.0)


def _ncc(a, b):
    a = a - a.mean()
    b = b - b.mean()
    den = float(np.sqrt((a * a).sum()) * np.sqrt((b * b).sum()))
    return float((a * b).sum() / den) if den > 1e-9 else -9.0


def symmetry_angle(roi, lo=-12.0, hi=12.0, step=0.1, max_off_frac=0.05):
    """双侧对称轴：使左右镜像最相似的角度。返回 (角度, 代价)。"""
    n = roi.shape[0]
    half = n // 2
    c = n / 2.0
    max_off = int(round(n * max_off_frac))
    yy, xx = np.mgrid[0:n, 0:n]
    circ = (((xx - c) ** 2 + (yy - c) ** 2) <= (0.47 * n) ** 2)
    best = None
    for t in np.arange(lo, hi + 1e-9, step):
        Mr = cv2.getRotationMatrix2D((c, c), -t, 1.0)
        rot = cv2.warpAffine(roi, Mr, (n, n), flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_REPLICATE)
        left = rot[:, :half]
        right = rot[:, half:][:, ::-1]
        mleft = circ[:, :half]
        mright = circ[:, half:][:, ::-1]
        for off in range(-max_off, max_off + 1):
            if off >= 0:
                a_l, a_r, m_l, m_r = (left[:, off:], right[:, :half - off],
                                      mleft[:, off:], mright[:, :half - off])
            else:
                a_l, a_r, m_l, m_r = (left[:, :half + off], right[:, -off:],
                                      mleft[:, :half + off], mright[:, -off:])
            m = m_l & m_r
            if m.sum() < 300:
                continue
            val = _ncc(a_l[m], a_r[m])
            if best is None or val > best[1]:
                best = (float(t), val, off)
    return (best[0], best[1]) if best else (float("nan"), -9.0)


def calibrate(cid, verbose=True):
    """真值无关自检：meas(Δ) − meas(0) 是否等于施加的 Δ。"""
    got = {}
    for delta in DELTAS:
        p = os.path.join(BASE, _fixture_name(cid, delta))
        if not os.path.exists(p):
            if verbose:
                print("    %-18s 缺失" % _fixture_name(cid, delta))
            continue
        roi = face_roi(p)
        if roi is None:
            if verbose:
                print("    %-18s 无脸" % _fixture_name(cid, delta))
            continue
        t, val = symmetry_angle(roi)
        got[delta] = t
        if verbose:
            print("    %-18s Δ=%+6.1f  对称轴=%+7.2f  NCC=%.4f"
                  % (_fixture_name(cid, delta), delta, t, val))
    if 0.0 not in got:
        return got, None
    errs = [abs(got[d] - got[0.0] - d) for d in got if d != 0.0]
    return got, (max(errs) if errs else None)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    ids = sys.argv[2:] or ["p1"]
    for cid in ids:
        print("=== %s ===" % cid)
        got, maxerr = calibrate(cid, verbose=(mode == "report"))
        if maxerr is None:
            print("  标定不可用（缺 d0 或夹具）")
            continue
        print("  >> 标定最大误差 = %.2f° （判据：≤0.5° 才可采信绝对读数）" % maxerr)
        if mode == "report":
            base = os.path.join(BASE, "%s.png" % cid)
            roi = face_roi(base)
            if roi is not None:
                t, val = symmetry_angle(roi)
                print("  >> %s 原图独立读数 = %+.2f°（NCC=%.4f）" % (cid, t, val))


if __name__ == "__main__":
    main()
