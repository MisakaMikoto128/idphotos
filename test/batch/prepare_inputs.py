# -*- coding: utf-8 -*-
"""qa-batch 阶段 4：把冻结数据集 stage 成设备端输入。

- 按 test/dataset.json 把 80 项复制为 item_NNN.<ext>（规避原始路径里的
  中文/空格/花括号，decode 是按内容的，扩展名只保留原样不做依据）。
- 生成 manifest.json（原始路径 + class + 尺寸随行）。
- 用参考环境 venv 的 PIL 生成 512x512 perf 输入（黄金集 g01 缩放，q95）。

用法：
  .venv_ref/Scripts/python.exe test/batch/prepare_inputs.py
产出：test/batch/device_in/（staging，随后整目录 adb push）
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "test", "batch", "device_in")


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(ROOT, "test", "dataset.json"), encoding="utf-8") as f:
        ds = json.load(f)

    manifest = {"items": []}
    for i, item in enumerate(ds["items"]):
        src = item["path"]
        cls = item["class"]
        ext = os.path.splitext(src)[1].lower() or ".bin"
        dst = f"item_{i:03d}{ext}"
        dst_path = os.path.join(OUT, dst)
        size = 0
        try:
            with open(src, "rb") as fi, open(dst_path, "wb") as fo:
                while True:
                    chunk = fi.read(1 << 20)
                    if not chunk:
                        break
                    fo.write(chunk)
                size = fo.tell()
        except OSError as e:
            print(f"[WARN] 复制失败 {src}: {e}", file=sys.stderr)
            if os.path.exists(dst_path):
                os.remove(dst_path)
            continue
        manifest["items"].append({
            "i": i,
            "path": src,
            "file": dst,
            "class": cls,
            "w": item.get("w", 0),
            "h": item.get("h", 0),
            "bytes": size,
        })

    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)

    # 512x512 perf 输入：黄金集 g01 居中缩放
    from PIL import Image
    g01 = os.path.join(ROOT, "test", "golden", "src", "g01.jpg")
    im = Image.open(g01).convert("RGB")
    im = im.resize((512, 512), Image.LANCZOS)
    im.save(os.path.join(OUT, "perf_512.jpg"), quality=95)

    n = len(manifest["items"])
    print(f"staged {n} items -> {OUT}")
    if n != ds["total"]:
        print(f"[WARN] staged {n} != dataset total {ds['total']}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
