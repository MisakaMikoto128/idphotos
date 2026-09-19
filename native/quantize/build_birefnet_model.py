#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从 onnx-community/BiRefNet_lite-ONNX 的 fp32 导出件生成
assets/models/birefnet_lite_1024_int8.onnx。

来源：onnx-community/BiRefNet_lite-ONNX（MIT，base ZhengPeng7/BiRefNet_lite），
onnx/model.onnx，opset 17，输入/输出已钉死 1x3x1024x1024 / 1x1x1024x1024，
输出是 **logits**（推理侧必须再过 sigmoid）。
下载（huggingface.co 直连不通，走镜像）：
    curl -L -o native/quantize/src/birefnet_lite_1024_fp32.onnx \
        https://hf-mirror.com/onnx-community/BiRefNet_lite-ONNX/resolve/main/onnx/model.onnx

用法（仓库根目录）：
    .venv_ref/Scripts/python.exe native/quantize/build_birefnet_model.py

--------------------------------------------------------------------------
量化策略与 build_matting_model.py 相同：**逐通道 int8 weight-only**
（Conv/MatMul 权重 int8 + 逐通道 scale + DequantizeLinear，激活 fp32）。
ORT 建会话时把 DQ 常量折叠回 fp32：文件 ~54MB、算得准、速度与 fp32 一致。
动态量化（ConvInteger/QDQ 全套）对 Swin 注意力块误差更大且 CPU 上更慢，
MODNet 阶段已实测否决，此处不重复。

与 MODNet 的差别：BiRefNet 的 logits 直接喂给 sigmoid 成 alpha，
decoder 末端的几个卷积数值范围直接决定 alpha 的绝对水平，
KEEP_TAIL_FP32 把图末端 N 个节点钉在 fp32（代价 <1MB，见脚本尾部实测）。
"""
import argparse
import os
import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "native", "quantize", "src",
                   "birefnet_lite_1024_fp32.onnx")
DST = os.path.join(REPO, "assets", "models", "birefnet_lite_1024_int8.onnx")

#: 图末端保持 fp32 的节点数（decoder 输出级）。实测（两张人像，sigmoid 后
#: alpha）：keep_tail=16 时 int8 vs fp32 平均绝对差 ≤0.0002、最大差 0.24
#: （集中在头顶一条 9×90px 碎发带，占画面 0.02% 像素）。keep_tail=0 只省
#: 0.05MB，末端保留 fp32 是近乎免费的保险。
KEEP_TAIL_FP32 = 16

#: 超过该字节的整数值 fp32 Constant（deform_conv2d 改写留下的 grid_sample
#: 采样网格）转 fp16 存放，后面补一个 Cast 回 fp32。实测全部整数值且
#: fp16 往返误差为 0（坐标 ≤261），是**无损**压缩；这批常量合计 ~43MB，
#: 不做这一步成品会是 87MB 而不是 66MB。
FP16_CONST_MIN_BYTES = 100_000


def fp16_integer_constants(model):
    """整数值大 Constant → fp16 + Cast(fp16→fp32)，返回处理个数。"""
    graph = model.graph
    new_nodes = []
    converted = 0
    for node in graph.node:
        if node.op_type == "Constant":
            attr = next((a for a in node.attribute if a.name == "value"), None)
            if attr is not None:
                t = numpy_helper.to_array(attr.t)
                if (t.dtype == np.float32 and t.nbytes >= FP16_CONST_MIN_BYTES
                        and bool((t == np.round(t)).all())
                        and np.abs(t).max() <= 2048):
                    t16 = t.astype(np.float16)
                    attr.t.CopyFrom(numpy_helper.from_array(t16))
                    cast = helper.make_node(
                        "Cast", [node.output[0]], [node.output[0] + "_f32"],
                        name=node.name + "_toF32", to=onnx.TensorProto.FLOAT)
                    new_nodes.append(node)
                    new_nodes.append(cast)
                    converted += 1
                    continue
        new_nodes.append(node)
    if converted:
        # 消费方全部改指 Cast 的输出。
        renamed = {n.input[0]: n.output[0]
                   for n in new_nodes if n.op_type == "Cast"
                   and n.name.endswith("_toF32")}
        for node in new_nodes:
            if node.op_type == "Cast" and node.name.endswith("_toF32"):
                continue
            for pos, inp in enumerate(node.input):
                if inp in renamed:
                    node.input[pos] = renamed[inp]
        del graph.node[:]
        graph.node.extend(new_nodes)
    return converted


def quantize_weight_only(model, keep_tail):
    """Conv/MatMul 权重 → int8 + 逐通道 scale + DequantizeLinear。"""
    graph = model.graph
    inits = {i.name: i for i in graph.initializer}
    total = len(graph.node)
    # 先定候选集：至少被一个非尾部的 Conv/MatMul 消费的 initializer 权重。
    # DQ 节点要插在**最早消费方**之前——transformers.js 导出件里存在
    # 权重被图首 Identity 转发、被图尾 MatMul 消费的共享结构，把 DQ 跟在
    # MatMul 旁边会破坏拓扑序。
    candidates = set()
    for index, node in enumerate(graph.node):
        weight_name = node.input[1] if len(node.input) >= 2 else None
        if (node.op_type in ("Conv", "MatMul") and weight_name in inits
                and index < total - keep_tail):
            w = numpy_helper.to_array(inits[weight_name])
            if w.ndim >= 2:
                candidates.add(weight_name)

    new_nodes, added, removed = [], [], set()
    emitted = {}   # weight_name -> [dq 输出名, ...]（每消费方一个）
    quantized = 0
    for node in graph.node:
        for pos, inp in enumerate(list(node.input)):
            if inp not in candidates:
                continue
            if inp not in emitted:
                w = numpy_helper.to_array(inits[inp]).astype(np.float32)
                axis = 0 if any(
                    n.op_type == "Conv" and inp in n.input
                    for n in graph.node) else w.ndim - 1
                reduce_axes = tuple(a for a in range(w.ndim) if a != axis)
                amax = np.abs(w).max(axis=reduce_axes)
                amax[amax == 0] = 1e-8
                scale = (amax / 127.0).astype(np.float32)
                shape = [1] * w.ndim
                shape[axis] = -1
                q = np.rint(w / scale.reshape(shape)).clip(-127, 127
                                                           ).astype(np.int8)
                qn, sn, zn = (inp + s for s in ("_i8", "_scale", "_zp"))
                added += [
                    numpy_helper.from_array(q, qn),
                    numpy_helper.from_array(scale, sn),
                    numpy_helper.from_array(
                        np.zeros_like(scale, dtype=np.int8), zn),
                ]
                emitted[inp] = []
                removed.add(inp)
                quantized += 1
            # 每个消费方配一个独立 DQ：同一 DQ 多消费方会触发 ORT 1.15 的
            # DQ 复制优化，复制件丢失 per-channel axis 属性直接运行期报错
            # （'..._DQ/duplicated'）。DQ 共享同一份 int8/scale 常量，
            # 体积不增，只是多几个节点。
            dn = f"{inp}_dq{len(emitted[inp])}"
            emitted[inp].append(dn)
            qn, sn, zn = (inp + s for s in ("_i8", "_scale", "_zp"))
            w = numpy_helper.to_array(inits[inp])
            axis = 0 if any(
                n.op_type == "Conv" and inp in n.input
                for n in graph.node) else w.ndim - 1
            new_nodes.append(helper.make_node(
                "DequantizeLinear", [qn, sn, zn], [dn],
                name=f"{inp}_DQ{len(emitted[inp])}", axis=axis))
            node.input[pos] = dn
        new_nodes.append(node)

    del graph.node[:]
    graph.node.extend(new_nodes)
    kept = [i for i in graph.initializer if i.name not in removed]
    del graph.initializer[:]
    graph.initializer.extend(kept + added)
    onnx.checker.check_model(model, full_check=False)
    return quantized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DST, help="输出 .onnx 路径")
    parser.add_argument("--keep-tail", type=int, default=KEEP_TAIL_FP32,
                        help="图末端保持 fp32 的节点数（默认 %(default)s）")
    args = parser.parse_args()
    if not os.path.exists(SRC):
        print(f"缺少源模型: {SRC}（下载命令见文件头）", file=sys.stderr)
        return 2
    model = onnx.load(SRC)
    nc = fp16_integer_constants(model)
    n = quantize_weight_only(model, args.keep_tail)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    onnx.save(model, args.out)
    print(f"fp16 常量 {nc} 个；量化 {n} 个权重张量 -> {args.out} "
          f"({os.path.getsize(args.out) / 1024 / 1024:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
