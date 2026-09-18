# -*- coding: utf-8 -*-
"""诊断：给 Dart 侧 A/B 用，产出 fp32 模型在 512 / 1024 输入下的 alpha。

尺寸按引擎的工作分辨率口径给出（长边 >2048 降到 1536，否则原样），
重采样与参考实现一致（INTER_AREA 进出），这样唯一变量就是**模型输入边长**。

产物：native/bench/out/alpha_<name>_<ref>.png（单通道灰度，工作分辨率）
"""
import os
import sys

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
    "p_29": r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg",
}

MAX_EDGE = 2048
BIG_EDGE = 1536


def working_size(w, h):
    long = max(w, h)
    if long > MAX_EDGE:
        s = BIG_EDGE / long
        return round(w * s), round(h * s)
    return w, h


def main():
    for name, p in PICS.items():
        img = cv2.imread(p, cv2.IMREAD_COLOR)
        if img is None:
            print("skip", p)
            continue
        w, h = working_size(img.shape[1], img.shape[0])
        work = cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)
        for ref in (512, 1024):
            im = cv2.resize(work, (ref, ref), interpolation=cv2.INTER_AREA)
            im = im[:, :, ::-1].astype(np.float32)
            im = (im / 255.0 - 0.5) / 0.5
            im = im.transpose(2, 0, 1)[None]
            matte = SESS.run([ON], {IN: im})[0]
            m = np.squeeze((matte[0] * 255).astype("uint8"))
            a = cv2.resize(m, (w, h), interpolation=cv2.INTER_AREA)
            fp = os.path.join(OUT, f"alpha_{name}_{ref}.png")
            cv2.imwrite(fp, a)
            print(f"{name} work={w}x{h} ref={ref} -> {fp}")


main()
