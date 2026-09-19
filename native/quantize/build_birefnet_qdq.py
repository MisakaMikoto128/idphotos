#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""③ 算法手段：从 fp32 导出件生成 QDQ 全量化（权重+激活 int8）候选模型。

动机（2026-09-19 提速专项）：weight-only int8 在会话建立时被 ORT 折叠回
fp32，推理是 fp32 口径——1024² 单次推理瞬态峰值 ~2.5–3.2GB RSS，4GB 模拟器
上所有 EP/运行时组合都被 LMK 杀（见 docs/PITFALLS.md「XNNPACK 的 EP 失败…」
与提速报告）。QDQ 让激活走 int8，瞬态约 4× 缩小，同时在 XNNPACK/MLAS 上
命中 int8 卷积核。

用法（仓库根目录）：
    .venv_ref/Scripts/python.exe native/quantize/build_birefnet_qdq.py

产物：native/quantize/out/birefnet_lite_1024_qdq.onnx（候选，不进 assets，
验收通过后再由报告申请替换）。

校准集：黄金集 8 张 + test/dataset.json 里 class ∈ {portrait, multi_face}
的 14 张，共 22 张，排序固定（确定性）。前处理与引擎逐位同口径：
面积重采样到 1024×1024（cv2.INTER_AREA 与 Dart areaResampleRgb 同公式）、
RGB 通道序、ImageNet mean/std 归一化、NCHW float32。

注意：校准推理在 PC CPU 上每张 ~8s（ORT 1.29），全程 ~5 分钟。
"""
import argparse
import json
import os
import sys

import cv2
import numpy as np
import onnxruntime as ort
from onnxruntime.quantization import (CalibrationDataReader, QuantFormat,
                                      QuantType, quantize_static)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "native", "quantize", "src",
                   "birefnet_lite_1024_fp32.onnx")
DST = os.path.join(REPO, "native", "quantize", "out",
                   "birefnet_lite_1024_qdq.onnx")
DATASET_JSON = os.path.join(REPO, "test", "dataset.json")
GOLDEN_SRC = os.path.join(REPO, "test", "golden", "src")

MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)
SIZE = 1024


def calib_paths():
    """确定性校准清单：黄金集 8 + 数据集 portrait/multi_face，字典序。"""
    paths = []
    for f in sorted(os.listdir(GOLDEN_SRC)):
        if f.lower().endswith((".jpg", ".jpeg", ".png")):
            paths.append(os.path.join(GOLDEN_SRC, f))
    with open(DATASET_JSON, encoding="utf-8") as fp:
        ds = json.load(fp)
    extra = [i["path"] for i in ds["items"]
             if i["class"] in ("portrait", "multi_face")
             and os.path.exists(i["path"])]
    paths.extend(sorted(extra))
    return paths


def preprocess(path):
    """与 lib/core/matting/image_ops.dart 的 birefnetInput 同口径。"""
    data = np.fromfile(path, dtype=np.uint8)  # 中文/特殊字符路径稳妥
    bgr = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError(f"decode failed: {path}")
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    resized = cv2.resize(rgb, (SIZE, SIZE), interpolation=cv2.INTER_AREA)
    x = resized.astype(np.float32) / 255.0
    x = (x - MEAN) / STD
    return np.ascontiguousarray(x.transpose(2, 0, 1)[None])  # NCHW


class _Reader(CalibrationDataReader):
    def __init__(self, paths, input_name, limit):
        self._paths = paths[:limit] if limit else paths
        self._input = input_name
        self._i = 0

    def get_next(self):
        if self._i >= len(self._paths):
            return None
        p = self._paths[self._i]
        self._i += 1
        print(f"  calib {self._i}/{len(self._paths)} "
              f"{os.path.basename(p)}", flush=True)
        return {self._input: preprocess(p)}

    def rewind(self):
        self._i = 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=DST)
    ap.add_argument("--calib-limit", type=int, default=0,
                    help="只用前 N 张校准（0=全部）")
    ap.add_argument("--exclude-tail", type=int, default=0,
                    help="图末端 N 个节点排除量化（默认 0=全量；"
                         "weight-only 脚本的 KEEP_TAIL_FP32=16 同款保险）")
    args = ap.parse_args()
    if not os.path.exists(SRC):
        print(f"缺少源模型: {SRC}", file=sys.stderr)
        return 2

    paths = calib_paths()
    print(f"校准集 {len(paths)} 张（limit={args.calib_limit or 'all'}）")

    # 输入名从模型读，不硬编码。
    sess = ort.InferenceSession(SRC, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    del sess

    exclude = []
    if args.exclude_tail > 0:
        import onnx
        model = onnx.load(SRC)
        names = [n.name for n in model.graph.node if n.name]
        exclude = names[-args.exclude_tail:]
        del model

    reader = _Reader(paths, input_name, args.calib_limit)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    quantize_static(
        model_input=SRC,
        model_output=args.out,
        calibration_data_reader=reader,
        quant_format=QuantFormat.QDQ,
        per_channel=True,
        activation_type=QuantType.QUInt8,
        weight_type=QuantType.QInt8,
        op_types_to_quantize=["Conv", "MatMul", "Gemm", "ConvTranspose"],
        nodes_to_exclude=exclude,
    )
    print(f"-> {args.out} ({os.path.getsize(args.out) / 1024 / 1024:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
