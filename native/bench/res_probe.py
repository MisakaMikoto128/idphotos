# -*- coding: utf-8 -*-
"""ml-porting 诊断用：MODNet 输入分辨率对发丝细节的影响（fp32 参考模型）。

对比同一张图在 512 与 1024（以及 768）输入边长下的 alpha，以及换红底后的
边缘。用途是判断"发丝糊掉"里有多少来自模型输入分辨率，有多少来自后处理。

只读 .ref_hivision 的权重，产物写 native/bench/out/，不碰 App 资源。
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


def run(img, ref):
    im = cv2.resize(img, (ref, ref), interpolation=cv2.INTER_AREA)
    im = im[:, :, ::-1].astype(np.float32)          # BGR
    im = (im / 255.0 - 0.5) / 0.5
    im = im.transpose(2, 0, 1)[None]
    matte = SESS.run([ON], {IN: im})[0]
    m = (matte[0] * 255).astype("uint8")
    m = np.squeeze(m)
    return cv2.resize(m, (img.shape[1], img.shape[0]), interpolation=cv2.INTER_AREA)


def composite(img, alpha, bg):
    a = (alpha.astype(np.float32) / 255.0)[:, :, None]
    return (img.astype(np.float32) * a + np.array(bg, np.float32) * (1 - a)).astype("uint8")


def edge_strength(alpha):
    """过渡带宽度代理：alpha 在 0.05~0.95 之间的像素占图像比例。"""
    s = ((alpha > 13) & (alpha < 242)).sum()
    return s / alpha.size


def main():
    pics = [r"C:\Users\liuyu\Pictures\2.jpg",
            r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg"]
    for p in pics:
        img = cv2.imread(p, cv2.IMREAD_COLOR)
        if img is None:
            print("skip", p)
            continue
        name = os.path.splitext(os.path.basename(p))[0][:12]
        panels = []
        for ref in (512, 1024):
            a = run(img, ref)
            red = composite(img, a, (0x1B, 0x00, 0xD9))   # BGR of #D9001B
            # 头顶发梢区域
            h, w = img.shape[:2]
            y0 = int(h * 0.05)
            x0 = int(w * 0.30)
            ez = 260
            panels.append(cv2.resize(red[y0:y0 + ez, x0:x0 + ez], (520, 520),
                                     interpolation=cv2.INTER_NEAREST))
            print(f"{name} ref={ref} transitionBand={edge_strength(a)*100:.2f}%")
        strip = np.concatenate(panels, axis=1)
        cv2.imwrite(os.path.join(OUT, f"res_{name}.png"), strip)
        print("wrote", os.path.join(OUT, f"res_{name}.png"))


main()
