#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从 HivisionIDPhotos 的 MODNet fp32 权重生成 assets/models/modnet_portrait_int8.onnx。

这是模型的**唯一生成脚本**，跑一次就能从 25.9MB 的原始权重复现出仓库里那份
7.19MB 的模型。谁要重新量化、换阈值、换保留层，改这里，不要手工改 .onnx。

依赖（都在 `.venv_ref` 里，`onnx` / `ml_dtypes` 需要另外装到一个 --target 目录）：
    onnx>=1.16, onnxruntime, numpy
用法（仓库根目录）：
    PYTHONPATH=<装了 onnx 的目录> .venv_ref/Scripts/python.exe \
        native/quantize/build_matting_model.py

--------------------------------------------------------------------------
量化策略：**逐通道 int8 weight-only（权重量化，激活保持 fp32）**

为什么不是常规的 int8 动态/静态量化：
  · 动态量化（ConvInteger）：6.3MB，但黄金集最差 IoU 掉到 0.47，而且比 fp32 还慢
    一倍（ConvInteger 在 ORT CPU 上没有好的实现）。
  · 静态量化（QDQ，per-channel，14 张人像标定）：6.6MB、快，但 g08 只有 0.81。
  · 16bit 激活：精度够，但需要 opset 21 + ORT>=1.17，而 Flutter 插件里绑死的是
    ORT 1.15.1，加载不了。
  · weight-only：权重存 int8 + 每输出通道 scale，前面挂一个 DequantizeLinear。
    ORT 在 session 建立时会把这个 DQ 常量折叠回 fp32，所以**文件小、算得准、
    速度和 fp32 一样**（实测比原始 fp32 还快一点，因为顺带做了图优化）。

在此基础上再做一次逐层敏感度扫描（"只量化这一层，其余保持 fp32"，看黄金集
最难的 g08 掉多少），发现 MobileNetV2 stem 那几个很小的卷积最敏感
（Conv_0/4/8/9 单独量化就能让 g08 从 1.00 掉到 0.94），而占了一半体积的
Conv_191（12MB）几乎无损。所以把节点序号 < KEEP_FP32_BELOW 的卷积留在 fp32：
多花 0.8MB，换回 g08 从 0.912 到 0.993。
"""
import os
import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, ".ref_hivision", "hivision", "creator", "weights",
                   "modnet_photographic_portrait_matting.onnx")
DST = os.path.join(REPO, "assets", "models", "modnet_portrait_int8.onnx")

#: MODNet 的固定推理边长，与 HivisionIDPhotos 参考实现一致（黄金集据此生成）。
REF_SIZE = 512

#: 节点序号小于此值的 Conv/MatMul 保持 fp32（见文件头的敏感度分析）。
KEEP_FP32_BELOW = 105


def freeze_input_shape(model):
    """把动态的 NCHW 维度钉成 1x3x512x512，并升到 opset 13。

    opset 11 的 DequantizeLinear 没有 axis 属性，做不了逐通道反量化，必须升到 13。
    """
    for tensor, dims in ((model.graph.input[0], [1, 3, REF_SIZE, REF_SIZE]),
                         (model.graph.output[0], [1, 1, REF_SIZE, REF_SIZE])):
        for dim, value in zip(tensor.type.tensor_type.shape.dim, dims):
            dim.ClearField("dim_param")
            dim.dim_value = value
    model = onnx.version_converter.convert_version(model, 13)
    return onnx.shape_inference.infer_shapes(model)


def quantize_weight_only(model, keep_fp32_below):
    """把 Conv/MatMul 的权重换成 int8 + 逐通道 scale + DequantizeLinear。"""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    new_nodes, added, removed = [], [], set()
    quantized = 0
    for index, node in enumerate(graph.node):
        weight_name = node.input[1] if len(node.input) >= 2 else None
        if (node.op_type not in ("Conv", "MatMul") or weight_name not in inits
                or index < keep_fp32_below):
            new_nodes.append(node)
            continue
        w = numpy_helper.to_array(inits[weight_name]).astype(np.float32)
        # Conv 的输出通道在 0 轴；MatMul 的 [K, N] 输出通道在最后一轴。
        axis = 0 if node.op_type == "Conv" else w.ndim - 1
        reduce_axes = tuple(a for a in range(w.ndim) if a != axis)
        amax = np.abs(w).max(axis=reduce_axes)
        amax[amax == 0] = 1e-8
        scale = (amax / 127.0).astype(np.float32)
        shape = [1] * w.ndim
        shape[axis] = -1
        q = np.rint(w / scale.reshape(shape)).clip(-127, 127).astype(np.int8)

        qn, sn, zn, dn = (weight_name + s
                          for s in ("_i8", "_scale", "_zp", "_dq"))
        added += [
            numpy_helper.from_array(q, qn),
            numpy_helper.from_array(scale, sn),
            numpy_helper.from_array(np.zeros_like(scale, dtype=np.int8), zn),
        ]
        new_nodes.append(helper.make_node("DequantizeLinear", [qn, sn, zn], [dn],
                                          name=weight_name + "_DQ", axis=axis))
        node.input[1] = dn
        removed.add(weight_name)
        new_nodes.append(node)
        quantized += 1

    del graph.node[:]
    graph.node.extend(new_nodes)
    kept = [i for i in graph.initializer if i.name not in removed]
    del graph.initializer[:]
    graph.initializer.extend(kept + added)
    onnx.checker.check_model(model, full_check=False)
    return quantized


def main():
    if not os.path.exists(SRC):
        print(f"缺少参考权重: {SRC}", file=sys.stderr)
        return 2
    model = freeze_input_shape(onnx.load(SRC))
    n = quantize_weight_only(model, KEEP_FP32_BELOW)
    onnx.save(model, DST)
    print(f"量化 {n} 个权重张量 -> {DST} "
          f"({os.path.getsize(DST) / 1024 / 1024:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
