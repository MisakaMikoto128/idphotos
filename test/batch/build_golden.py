#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
qa-batch 阶段 1：从冻结的 portrait 子集里挑 8 张最标准正面清晰人像，
构建黄金集 test/golden/src/g01.jpg..g08.jpg，并调用 HivisionIDPhotos 参考
脚本 run_matting.py 生成 test/golden/ref/g0N.png（单通道 alpha 参考真值）。

挑选依据（人工目检 + 分辨率/清晰度过滤，详见 out/QA_golden_report.md）：
覆盖 3 种纯色证件照底（蓝底 x3 张不同人/年龄）、1 张白底+镜框+卷发、
2 张真实复杂背景+眼镜（不同角度/构图）、1 张低分辨率证件照小图、
1 张真实场景网络摄像头照片（暗光室内、杂乱背景）——尽量覆盖不同光照/
背景/发型，不全用同一批同人同景的近似重复照。

原图 > 2048px 长边的按等比缩放到长边 2048（JPEG quality=95）后再定案，
缩放后的文件才是黄金集正式内容，其 sha256 与原图不同（原图 sha256 已在
test/dataset.json 中记录，此处另行记录映射关系）。
"""
import os
import json
import hashlib
import subprocess
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
GOLDEN_SRC = os.path.join(ROOT, "test", "golden", "src")
GOLDEN_REF = os.path.join(ROOT, "test", "golden", "ref")
PY_REF = os.path.join(ROOT, ".venv_ref", "Scripts", "python.exe")
RUN_MATTING = os.path.join(ROOT, ".ref_hivision", "run_matting.py")

MAX_LONG_SIDE = 2048

# (源路径, 目标文件名, 说明)
PICKS = [
    (r"C:\Users\liuyu\Pictures\2.jpg", "g01.jpg", "蓝底标准证件照，短发无镜框"),
    (r"C:\Users\liuyu\Pictures\20240710193717_7c99.jpg", "g02.jpg", "白底证件照，镜框+卷发"),
    (r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg", "g03.jpg", "蓝底标准证件照，镜框"),
    (r"C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg", "g04.jpg", "蓝底证件照，中年男性，不同年龄段"),
    (r"C:\Users\liuyu\Pictures\报名照片.jpg", "g05.jpg", "蓝底证件照，低分辨率(295x413)小图"),
    (r"C:\Users\liuyu\Pictures\1 (2).jpg", "g06.jpg", "真实复杂背景（楼道），镜框+自然发型，原图超大需缩放"),
    (r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124.jpg", "g07.jpg", "真实复杂背景（楼道），镜框+蓬松碎发（发丝抠图难点）"),
    (r"C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg", "g08.jpg", "网络摄像头暗光室内自拍，杂乱背景，非正规证件照场景"),
]


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def foreground_ratio(alpha_path):
    from PIL import Image
    import numpy as np

    im = Image.open(alpha_path)
    arr = np.array(im)
    if arr.ndim == 3:
        arr = arr[:, :, 0]
    fg = (arr >= 128).sum()
    total = arr.size
    return fg / total


def main():
    os.makedirs(GOLDEN_SRC, exist_ok=True)
    os.makedirs(GOLDEN_REF, exist_ok=True)

    mapping = []

    for src_path, dst_name, note in PICKS:
        if not os.path.exists(src_path):
            print(f"[ERROR] 源文件不存在: {src_path}")
            sys.exit(1)

        src_sha256 = sha256_of(src_path)
        im = Image.open(src_path)
        orig_w, orig_h = im.size
        resized = False

        dst_path = os.path.join(GOLDEN_SRC, dst_name)

        long_side = max(orig_w, orig_h)
        if long_side > MAX_LONG_SIDE:
            scale = MAX_LONG_SIDE / long_side
            new_w = round(orig_w * scale)
            new_h = round(orig_h * scale)
            im_rgb = im.convert("RGB")
            im_resized = im_rgb.resize((new_w, new_h), Image.LANCZOS)
            im_resized.save(dst_path, "JPEG", quality=95)
            resized = True
            final_w, final_h = new_w, new_h
        else:
            im_rgb = im.convert("RGB")
            im_rgb.save(dst_path, "JPEG", quality=95)
            final_w, final_h = orig_w, orig_h

        dst_sha256 = sha256_of(dst_path)

        mapping.append(
            {
                "golden_name": dst_name,
                "source_path": src_path,
                "source_sha256": src_sha256,
                "source_wh": [orig_w, orig_h],
                "golden_sha256": dst_sha256,
                "golden_wh": [final_w, final_h],
                "resized": resized,
                "note": note,
            }
        )
        print(f"{dst_name} <- {src_path}  ({orig_w}x{orig_h} -> {final_w}x{final_h}, resized={resized})")

    # 跑参考抠图
    for item in mapping:
        src = os.path.join(GOLDEN_SRC, item["golden_name"])
        ref = os.path.join(GOLDEN_REF, item["golden_name"].replace(".jpg", ".png"))
        print(f"抠图参考: {src} -> {ref}")
        result = subprocess.run(
            [PY_REF, RUN_MATTING, src, ref],
            capture_output=True,
            text=True,
            cwd=os.path.dirname(RUN_MATTING),
        )
        print(result.stdout.strip())
        if result.returncode != 0:
            print(f"[ERROR] 参考抠图失败 (exit={result.returncode}): {result.stderr}")
            item["matting_ok"] = False
            item["matting_error"] = result.stderr
            continue
        item["matting_ok"] = True
        ratio = foreground_ratio(ref)
        item["foreground_ratio"] = round(ratio, 4)
        print(f"  前景占比: {ratio*100:.1f}%")

    out_path = os.path.join(ROOT, "test", "golden", "mapping.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(mapping, f, ensure_ascii=False, indent=2)
    print(f"写入映射: {out_path}")

    # 自检 8%-70%
    bad = [m for m in mapping if not (0.08 <= m.get("foreground_ratio", -1) <= 0.70)]
    if bad:
        print("\n[WARN] 以下黄金集图片前景占比不在 8%-70% 区间，需要更换:")
        for b in bad:
            print(" ", b["golden_name"], b.get("foreground_ratio"))
    else:
        print("\n全部 8 张前景占比均在 8%-70% 区间内。")


if __name__ == "__main__":
    main()
