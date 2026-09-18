# -*- coding: utf-8 -*-
"""诊断：生成候选 alpha 后处理变体，供 Dart 侧走真实 render 路径 A/B。

变体（都以 fp32 模型 @512 为底）：
  512   基线（INTER_AREA 上采样，等价现状）
  blur  512 空间高斯 sigma=0.7 后再上采样
  med   512 空间 3×3 中值后再上采样
  mg    中值 + 高斯（去斑 + 平滑轮廓）
  gf    上采样到工作分辨率后做 guided filter（引导 = 工作分辨率灰度图）
"""
import os

import cv2
import numpy as np
import onnxruntime as ort

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
W = os.path.join(REPO, ".ref_hivision", "hivision", "creator", "weights",
                 "modnet_photographic_portrait_matting.onnx")
OUT = os.path.join(REPO, "native", "bench", "out")
os.makedirs(OUT, exist_ok=True)

SESS = ort.InferenceSession(W, providers=["CPUExecutionProvider"])
IN = SESS.get_inputs()[0].name
ON = SESS.get_outputs()[0].name

PICS = {
    "p_2": r"C:\Users\liuyu\Pictures\2.jpg",
    "p_1x2": r"C:\Users\liuyu\Pictures\1 (2).jpg",
    "p_wu": r"C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg",
}
MAX_EDGE, BIG_EDGE = 2048, 1536


def working_size(w, h):
    long = max(w, h)
    if long > MAX_EDGE:
        s = BIG_EDGE / long
        return round(w * s), round(h * s)
    return w, h


def model512(work):
    im = cv2.resize(work, (512, 512), interpolation=cv2.INTER_AREA)
    im = im[:, :, ::-1].astype(np.float32)
    im = (im / 255.0 - 0.5) / 0.5
    im = im.transpose(2, 0, 1)[None]
    return np.squeeze((SESS.run([ON], {IN: im})[0][0] * 255).astype("uint8"))


def guided(gray, src, r=8, eps=0.004):
    """标准快速 guided filter。gray/src 均为 float32 [0,1]。"""
    I, p = gray, src

    def box(x):
        return cv2.boxFilter(x, -1, (2 * r + 1, 2 * r + 1), normalize=True,
                             borderType=cv2.BORDER_REFLECT)

    mI, mp = box(I), box(p)
    varI = box(I * I) - mI * mI
    cov = box(I * p) - mI * mp
    a = cov / (varI + eps)
    b = mp - a * mI
    return box(a) * I + box(b)


def main():
    for name, path in PICS.items():
        img = cv2.imread(path, cv2.IMREAD_COLOR)
        if img is None:
            print("skip", path)
            continue
        w, h = working_size(img.shape[1], img.shape[0])
        work = cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)
        m = model512(work)
        gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0

        outs = {}
        outs["512"] = cv2.resize(m, (w, h), interpolation=cv2.INTER_AREA)
        outs["blur"] = cv2.resize(
            cv2.GaussianBlur(m, (0, 0), 0.7), (w, h),
            interpolation=cv2.INTER_AREA)
        outs["med"] = cv2.resize(
            cv2.medianBlur(m, 3), (w, h), interpolation=cv2.INTER_AREA)
        outs["mg"] = cv2.resize(
            cv2.GaussianBlur(cv2.medianBlur(m, 3), (0, 0), 0.6), (w, h),
            interpolation=cv2.INTER_AREA)
        up = outs["512"].astype(np.float32) / 255.0
        outs["gf"] = np.clip(guided(gray, up) * 255.0 + 0.5, 0,
                             255).astype(np.uint8)
        # mg + guided：先去斑平滑，再在工作分辨率上用原图当引导把轮廓贴回真实边缘
        mgup = outs["mg"].astype(np.float32) / 255.0
        outs["mgf"] = np.clip(guided(gray, mgup) * 255.0 + 0.5, 0,
                              255).astype(np.uint8)
        # 只换上采样核：INTER_AREA 在放大时退化成"最近邻"（OpenCV 文档明说），
        # 这才是台阶的真正来源。线性/三次插值给的是连续曲面。
        outs["bil"] = cv2.resize(m, (w, h), interpolation=cv2.INTER_LINEAR)
        outs["bic"] = cv2.resize(m, (w, h), interpolation=cv2.INTER_CUBIC)

        for k, v in outs.items():
            p = os.path.join(OUT, f"av_{name}_{k}.png")
            cv2.imwrite(p, v)
            print(f"{name} {k} -> {p}")


main()
