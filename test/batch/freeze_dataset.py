#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
qa-batch 阶段 1：冻结真实数据集 -> test/dataset.json

用法（走参考环境解释器，不用系统 python）：
    ..\.venv_ref\Scripts\python.exe freeze_dataset.py

============================== 扫描范围 ==============================
递归扫描 C:\\Users\\liuyu\\Pictures\\，但排除以下三个目录：
    Luminar Neo Catalog\\Backups
    Luminar Neo Catalog\\CacheDocuments
    Luminar Neo Catalog\\PreviewCache
原因：这三个目录是 Luminar Neo 图库软件的内部缓存/备份，实测共约 225 个文件，
绝大多数是同一批源照片在不同分辨率下的重复缩略图（文件名为哈希值，
如 020CB1CA...D1201...jpg / ...D1501...jpg / ...D3001...jpg 明显是同一张图的
多档缓存），不是独立的真实照片。CLAUDE.md 明确写"测试素材：约 40 个文件"，
把这 225 个内部缓存文件全部当作独立测试样本会：
  1) 与"约 40 个文件"的既定事实矛盾；
  2) 让 portrait/non_image 等 class 的计数被大量近似重复项稀释，
     使批量回归的"成功率"数字失去意义（刷同一张图的 5 个缩略图变体
     不会增加真实覆盖度，只会拖慢阶段 4 的全量跑批）。
Lightroom\\*.lrdata / *.lrcat-data 内部只有 2~3 个 .db 文件（不是逐张缓存），
体量很小，予以保留（归类为 non_image，用于验证"无法解码的文件优雅处理"）。

============================== 分类方法 ==============================
1. non_image：PIL 和 OpenCV 均无法解码 -> 直接归类，不再做后续判断。
2. screenshot：路径含 "Screenshots" 目录，或文件名匹配
   "屏幕截图 *" / "QQ截图*" 前缀 -> 判定为截图（这是系统/QQ截图工具的
   固定命名规则，比内容启发式更可靠）。
3. 其余可解码图片，用 HivisionIDPhotos 依赖的 mtcnn-runtime（onnxruntime
   MTCNN，三级 P/R/O-Net）在长边缩放到 <=800px 的图上做人脸检测
   （thresholds=[0.7,0.7,0.7]），得到每张脸的 bbox 及 5 点关键点
   （左眼、右眼、鼻尖、左嘴角、右嘴角）：
     - 检测到 >=2 张脸 -> multi_face
     - 检测到 1 张脸：
         - 用关键点算"人脸朝向指标" yaw_ratio：
           设左眼到鼻尖水平距离 dl，右眼到鼻尖水平距离 dr，
           yaw_ratio = abs(dl-dr) / max(dl,dr)。
           越接近正脸，双眼到鼻尖的水平距离越接近，yaw_ratio 越小；
           侧脸时一侧被压缩，yaw_ratio 明显偏大。
           yaw_ratio > 0.45 -> profile（侧脸/半侧脸）
         - 否则算图像整体亮度（HSV 的 V 通道均值）：
           mean_v < 70 -> low_light
         - 否则 -> portrait
     - 检测到 0 张脸：
         - 宽高比或内容判断为风景/物体 -> landscape
           （0 人脸时缺省即归 landscape；MTCNN 对严重侧脸/背影/遮挡
           人像也可能漏检，此类漏检个例已人工抽查确认，见 QA 报告）

优先级顺序（自上而下命中即停）：
    non_image > screenshot > multi_face > profile > low_light > portrait > landscape

exif_orientation：从 PIL 的 EXIF tag 0x0112 读取，缺失则记为 1（正常方向）。
w/h：PIL Image.size 给出的原始存储像素尺寸（未按 EXIF 方向旋转）。
"""
import os
import sys
import json
import hashlib
import time

ROOT = r"C:\Users\liuyu\Pictures"
EXCLUDE_DIRS = {
    os.path.normcase(os.path.join(ROOT, "Luminar Neo Catalog", "Backups")),
    os.path.normcase(os.path.join(ROOT, "Luminar Neo Catalog", "CacheDocuments")),
    os.path.normcase(os.path.join(ROOT, "Luminar Neo Catalog", "PreviewCache")),
}

OUT_JSON = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "dataset.json"
)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def get_exif_orientation(pil_img):
    try:
        exif = pil_img.getexif()
        if exif is not None:
            val = exif.get(0x0112)
            if val:
                return int(val)
    except Exception:
        pass
    return 1


def try_decode(path):
    """返回 (w, h, exif_orientation, cv2_bgr_array_or_None)"""
    from PIL import Image
    import numpy as np

    w = h = None
    orientation = 1
    bgr = None
    try:
        with Image.open(path) as im:
            im.load()
            w, h = im.size
            orientation = get_exif_orientation(im)
            rgb = im.convert("RGB")
            arr = np.array(rgb)
            bgr = arr[:, :, ::-1].copy()
    except Exception:
        pass

    if bgr is None:
        try:
            import cv2

            arr = cv2.imread(path, cv2.IMREAD_COLOR)
            if arr is not None:
                bgr = arr
                h, w = arr.shape[:2]
        except Exception:
            pass

    return w, h, orientation, bgr


def is_screenshot(path):
    base = os.path.basename(path)
    parts = os.path.normpath(path).split(os.sep)
    if "Screenshots" in parts:
        return True
    if base.startswith("屏幕截图"):
        return True
    if base.startswith("QQ截图"):
        return True
    return False


def classify_face(bgr, mtcnn):
    """返回 (n_faces, is_profile, mean_v) 用 <=800px 长边缩放图检测。"""
    import cv2
    import numpy as np

    h, w = bgr.shape[:2]
    scale = max(1, max(h, w) // 800)
    small = cv2.resize(bgr, (max(1, w // scale), max(1, h // scale)))

    try:
        faces, landmarks = mtcnn.detect(small, thresholds=[0.7, 0.7, 0.7])
    except ValueError:
        faces, landmarks = [], []

    n = len(faces)
    is_profile = False
    if n == 1:
        lm = landmarks[0]
        # lm: x1..x5, y1..y5  (左眼,右眼,鼻尖,左嘴角,右嘴角)
        lx, rx, nx = lm[0], lm[1], lm[2]
        dl = abs(nx - lx)
        dr = abs(rx - nx)
        denom = max(dl, dr, 1e-6)
        yaw_ratio = abs(dl - dr) / denom
        is_profile = yaw_ratio > 0.45

    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    mean_v = float(np.mean(hsv[:, :, 2]))

    return n, is_profile, mean_v, (faces, landmarks)


def main():
    from mtcnnruntime import MTCNN

    mtcnn = MTCNN()

    records = []
    t_start = time.time()
    count = 0

    for dirpath, dirnames, filenames in os.walk(ROOT):
        norm_dir = os.path.normcase(dirpath)
        if norm_dir in EXCLUDE_DIRS:
            dirnames[:] = []
            continue
        # 也防止 os.walk 继续下钻进已排除目录的子目录
        dirnames[:] = [
            d
            for d in dirnames
            if os.path.normcase(os.path.join(dirpath, d)) not in EXCLUDE_DIRS
        ]

        for fn in filenames:
            path = os.path.join(dirpath, fn)
            count += 1
            rec = {
                "path": path,
                "sha256": None,
                "class": None,
                "w": 0,
                "h": 0,
                "exif_orientation": 1,
            }
            try:
                rec["sha256"] = sha256_of(path)
            except Exception as e:
                rec["sha256"] = None
                rec["class"] = "non_image"
                rec["_error"] = f"sha256 failed: {e}"
                records.append(rec)
                continue

            w, h, orientation, bgr = try_decode(path)
            rec["w"] = w or 0
            rec["h"] = h or 0
            rec["exif_orientation"] = orientation

            if bgr is None:
                rec["class"] = "non_image"
                records.append(rec)
                continue

            if is_screenshot(path):
                rec["class"] = "screenshot"
                records.append(rec)
                continue

            try:
                n, is_profile, mean_v, raw = classify_face(bgr, mtcnn)
            except Exception as e:
                rec["class"] = "non_image"
                rec["_error"] = f"face detect crashed: {e}"
                records.append(rec)
                continue

            rec["_n_faces"] = n
            rec["_mean_v"] = round(mean_v, 1)

            if n >= 2:
                rec["class"] = "multi_face"
            elif n == 1:
                if is_profile:
                    rec["class"] = "profile"
                elif mean_v < 70:
                    rec["class"] = "low_light"
                else:
                    rec["class"] = "portrait"
                    # 记下人脸 bbox 面积占比，供后面挑黄金集用
                    fb = raw[0][0]
                    fw = fb[2] - fb[0]
                    fh = fb[3] - fb[1]
                    img_area = (bgr.shape[0] * bgr.shape[1])
                    face_area_ratio = (fw * fh) / max(1, img_area)
                    rec["_face_area_ratio"] = round(float(face_area_ratio), 4)
            else:
                rec["class"] = "landscape"

            records.append(rec)

    elapsed = time.time() - t_start

    summary = {}
    for r in records:
        c = r["class"]
        summary[c] = summary.get(c, 0) + 1

    out = {
        "root": ROOT,
        "excluded_dirs": sorted(EXCLUDE_DIRS),
        "total": len(records),
        "summary": summary,
        "scan_seconds": round(elapsed, 1),
        "items": records,
    }

    out_path = os.path.abspath(OUT_JSON)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"扫描 {len(records)} 个文件，用时 {elapsed:.1f}s")
    print("分类统计:", summary)
    print(f"写入: {out_path}")


if __name__ == "__main__":
    main()
