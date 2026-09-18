# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 真值锚点测量库（纯 Python，绝不调用被测 Dart 代码）。

角度约定（与 out/tmp/roll_repro/step12_verify.py 一致，主会话已验证）：
    tiltDeg = degrees(atan2(y_imgRight - y_imgLeft, x_imgRight - x_imgLeft))
  * 图像坐标系 y 向下；
  * 正值 = 图像右侧的眼更低（头向左肩倾）；
  * 与生产契约 FaceInfo.rollDeg 的关系：**rollDeg == tiltDeg，不取负**
    （CONTRACTS §6 符号口径，2026-09-17 三方独立复核）。
    实现侧恒等式 `输出倾角 = tilt - rollDeg`，故摆平当且仅当 rollDeg == tilt。
    ⚠️ 本库早先写过 `rollDeg = -tiltDeg`，**那是错的**，会把 p1 残差从 0.02
    变成 8.82。不要再按"顺/逆时针"口头描述推符号，只认 atan2 公式。

测量方法（各自可单独失败；两两之间尽量少共享依赖）：
    M1 pupil-centroid   YuNet 眼位开窗 → 阈值化暗色圆盘 blob（圆度+尺寸约束）
    M2 radon-eye-band   YuNet 眼带 → Radon 行投影脊线取向（整带，不受单眼误差支配）
    M3 haar-eyeline     Haar 人脸+眼睛级联（与 YuNet 完全不同的检测器）→ 双眼连线
    M4 haar-radon       Haar 眼带 → Radon 脊线取向
    V  visual           人（多模态）直接看 overlay 图判读

M1/M2 共享 YuNet 的"眼大致在哪"，但 M1 依赖单眼 blob 定位、M2 只用对称带；
M3/M4 完全不碰 YuNet。方法间一致性由调用方判定。
"""
import math
import os
import re

import cv2
import numpy as np
from PIL import Image, ImageOps
from scipy import ndimage as ndi

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"
YUNET = REPO + r"\assets\models\face_yunet_2023mar.onnx"

# 工作分辨率：长边缩到 1536（与主会话 step12/step15 同口径）
WORK_LONG = 1536

# 摆正死区（v2，2026-09-17 起为 10°）。**只有一个来源：生产源码。**
# 曾经这里是写死的 `1.0`，常量改成 10 之后脚本仍按 1.0 分档 —— 那正是
# "名字/字段声称的口径宽于实际"的形态，产物读起来完全正常却按旧口径算。
# 故此处不设默认值：读不到就抛，不许静默退回任何一个数。
_DEAD_ZONE_RE = re.compile(
    r"const\s+double\s+kRollDeadZoneDeg\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;")


def dead_zone_deg(path=None):
    """从 `lib/core/imaging/crop_geometry.dart` 读 `kRollDeadZoneDeg`。

    不硬编码行号、不设默认值。找不到或找到多处一律抛异常 ——
    "读不到就用一个数凑"会让下一轮又变成静默的旧口径。
    """
    p = path or os.path.join(REPO, "lib", "core", "imaging", "crop_geometry.dart")
    with open(p, encoding="utf-8") as fh:
        src = fh.read()
    hits = _DEAD_ZONE_RE.findall(src)
    if len(hits) != 1:
        raise RuntimeError(
            f"在 {p} 里找到 {len(hits)} 处 kRollDeadZoneDeg 定义，期望恰好 1 处")
    return float(hits[0])


# ---------------------------------------------------------------- 基础 I/O

def load_rgb(path, work_long=WORK_LONG):
    """返回 (PIL.Image 工作分辨率 RGB, scale)。EXIF orientation 已应用。"""
    im = Image.open(path)
    im = ImageOps.exif_transpose(im).convert("RGB")
    W, H = im.size
    s = 1.0
    if max(W, H) > work_long:
        s = work_long / max(W, H)
        im = im.resize((max(1, round(W * s)), max(1, round(H * s))), Image.LANCZOS)
    return im, s


def gray_of(im):
    return np.asarray(im.convert("L")).astype(np.float64)


_det_cache = {}


def detect_faces(path, score=0.5):
    """cv2.FaceDetectorYN 原版（Python 侧，非生产 Dart）。返回 [x,y,w,h,5×(x,y),score]。"""
    im, s = load_rgb(path)
    bgr = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    h, w = bgr.shape[:2]
    key = (YUNET, w, h, score)
    if key not in _det_cache:
        d = cv2.FaceDetectorYN.create(YUNET, "", (w, h),
                                      score_threshold=float(score),
                                      nms_threshold=0.3, top_k=50)
        d.setInputSize((w, h))
        _det_cache[key] = d
    _, faces = _det_cache[key].detect(bgr)
    out = []
    if faces is not None:
        for f in faces:
            out.append({
                "box": [float(v) for v in f[0:4]],
                "kps": [float(v) for v in f[4:14]],
                "score": float(f[14]),
            })
    out.sort(key=lambda r: -r["score"])
    return im, s, out


def pick_face(faces, img_wh):
    """选主体：面积最大者优先，面积接近时取更靠中心的。"""
    if not faces:
        return None
    W, H = img_wh

    def key(f):
        x, y, w, h = f["box"]
        cx, cy = x + w / 2, y + h / 2
        d = math.hypot(cx - W / 2, cy - H / 2 / 1.0) / max(W, H)
        return (-(w * h), d)

    return sorted(faces, key=key)[0]


# ---------------------------------------------------------------- 工具

def _win(gray, cx, cy, r):
    H, W = gray.shape
    x0, x1 = max(0, int(round(cx - r))), min(W, int(round(cx + r)))
    y0, y1 = max(0, int(round(cy - r))), min(H, int(round(cy + r)))
    if x1 - x0 < 4 or y1 - y0 < 4:
        return None
    return gray[y0:y1, x0:x1], x0, y0


def _angle_from_pair(left_xy, right_xy):
    """tiltDeg。left/right 按图像 x 排序，保证分母为正。"""
    (x1, y1), (x2, y2) = left_xy, right_xy
    if x1 > x2:
        (x1, y1), (x2, y2) = (x2, y2), (x1, y1)
    return math.degrees(math.atan2(y2 - y1, x2 - x1))


# ---------------------------------------------------------------- M1

def m1_pupil(gray, seed, r, eyedist, topk=5):
    """阈值化暗色圆盘 blob：多阈值 + 圆度 + 尺寸窗口，返回按分数排序的候选表。

    返回前 topk 个候选，由调用方做左右配对（单眼独立取最优会在眼位种子偏移时
    锁到眉毛/镜框上，配对能显著压掉这类 gross failure）。
    """
    w = _win(gray, seed[0], seed[1], r)
    if w is None:
        return []
    win, x0, y0 = w
    lo, hi = float(win.min()), float(win.max())
    if hi - lo < 8:
        return []
    cands = []
    thrs = list(np.percentile(win, [1, 2, 3, 5, 8, 12, 16]))
    thrs += [lo + (hi - lo) * f for f in (0.10, 0.18, 0.26, 0.35)]
    for thr in thrs:
        m = win <= thr
        lab, n = ndi.label(m)
        for i in range(1, n + 1):
            ys, xs = np.nonzero(lab == i)
            npx = len(xs)
            if npx < 8:
                continue
            bw = xs.max() - xs.min() + 1
            bh = ys.max() - ys.min() + 1
            circ = npx / (bw * bh * math.pi / 4.0)
            if circ < 0.60:
                continue
            if not (0.03 * eyedist < max(bw, bh) < 0.32 * eyedist):
                continue
            cands.append({"score": npx * circ, "xy": (x0 + float(xs.mean()),
                                                      y0 + float(ys.mean())),
                          "n": int(npx), "w": int(bw), "h": int(bh),
                          "circ": round(float(circ), 3)})
    out = []
    for c in sorted(cands, key=lambda t: -t["score"]):
        if all(math.hypot(c["xy"][0] - o["xy"][0], c["xy"][1] - o["xy"][1])
               > 0.10 * eyedist for o in out):
            out.append(c)
    return out[:topk]


def _pair_cost(cl, cr, seed_l, seed_r, eyedist):
    """左右瞳孔配对代价：尺寸失配 + 相对种子的位移 + 轻微偏向大 blob。"""
    if cl["n"] <= 0 or cr["n"] <= 0:
        return float("inf")
    ratio = max(cl["n"], cr["n"]) / min(cl["n"], cr["n"])
    if ratio > 2.2:                      # 两眼瞳孔大小不该差这么多
        return float("inf")
    size_term = abs(math.log(ratio))
    off = (math.hypot(cl["xy"][0] - seed_l[0], cl["xy"][1] - seed_l[1])
           + math.hypot(cr["xy"][0] - seed_r[0], cr["xy"][1] - seed_r[1])) / eyedist
    # 两眼瞳孔的 y 差不应超过眼距的 1/3（约 18°），否则一定是配错了
    dy = abs(cl["xy"][1] - cr["xy"][1])
    if dy > 0.33 * eyedist:
        return float("inf")
    # 权重经 6 张样本标定：尺寸项过强会让"两只眉毛"配成对（c05 实测 -22.6°），
    # 位移项主导才稳定；尺寸只作否决式的弱约束。
    return 0.3 * size_term + 1.0 * off


def measure_m1(gray, kps, eyedist):
    il, ir = eye_pair(kps)
    r = max(10.0, 0.30 * eyedist)
    cl = m1_pupil(gray, il, r, eyedist)
    cr = m1_pupil(gray, ir, r, eyedist)
    if not cl or not cr:
        return None
    best = None
    for a in cl:
        for b in cr:
            c = _pair_cost(a, b, il, ir, eyedist)
            if best is None or c < best[0]:
                best = (c, a, b)
    if best is None or not math.isfinite(best[0]):
        return None
    _, a, b = best
    return {"deg": _angle_from_pair(a["xy"], b["xy"]),
            "left": a["xy"], "right": b["xy"],
            "pairCost": round(best[0], 3),
            "detail": {"left": {k: v for k, v in a.items() if k != "xy"},
                       "right": {k: v for k, v in b.items() if k != "xy"}}}


# ---------------------------------------------------------------- Radon 脊线

def _radon_orientation(win, span=16.0, step=0.1):
    """行投影方差最大的旋转角 = 暗脊线的取向（图像坐标，与 tiltDeg 同号）。"""
    if win is None or win.size < 64:
        return None
    g = (win.max() - win).astype(np.float64)
    g = g - g.mean()
    if not np.isfinite(g).all() or g.std() < 1e-6:
        return None
    h, w = g.shape
    c = (w / 2.0, h / 2.0)
    angs = np.arange(-span, span + 1e-9, step)
    sc = np.empty(angs.size)
    for i, a in enumerate(angs):
        M = cv2.getRotationMatrix2D(c, float(a), 1.0)
        r = cv2.warpAffine(g, M, (w, h), flags=cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REPLICATE)
        p = r.sum(axis=1)
        sc[i] = ((p - p.mean()) ** 2).mean()
    i = int(np.argmax(sc))
    a0 = float(angs[i])
    if 0 < i < len(sc) - 1:  # 抛物线亚度插值
        y0s, y1s, y2s = sc[i - 1], sc[i], sc[i + 1]
        den = y0s - 2 * y1s + y2s
        if abs(den) > 1e-12:
            a0 = float(angs[i]) + 0.5 * (y0s - y2s) / den * step
    base = float(np.median(sc))
    peak = float(sc[i]) / base if base > 1e-12 else float("inf")
    return {"deg": a0, "peak_ratio": round(peak, 3), "span": span}


def _eye_band(gray, il, ir, hw=1.05, hf=0.34):
    """以双眼连线中点为中心的对称带。裁剪保持中心不变（越界则整体平移）。"""
    ed = math.hypot(ir[0] - il[0], ir[1] - il[1])
    mx, my = (il[0] + ir[0]) / 2.0, (il[1] + ir[1]) / 2.0
    H, W = gray.shape
    bw, bh = int(2 * hw * ed), int(2 * hf * ed)
    if bw < 24 or bh < 8:
        return None
    x0 = int(round(mx - bw / 2)); y0 = int(round(my - bh / 2))
    x0 = max(0, min(W - bw, x0)); y0 = max(0, min(H - bh, y0))
    if x0 < 0 or y0 < 0 or bw > W or bh > H:
        return None
    return gray[y0:y0 + bh, x0:x0 + bw]


def measure_m2(gray, kps, eyedist):
    il, ir = eye_pair(kps)
    band = _eye_band(gray, il, ir)
    if band is None:
        return None
    r = _radon_orientation(band)
    if r is None:
        return None
    r["source"] = "yunet-band"
    return r


# ---------------------------------------------------------------- Haar（独立检测器）

FACE_CASCADE = cv2.CascadeClassifier(
    cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
EYE_CASCADES = [
    cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_eye_tree_eyeglasses.xml"),
    cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_eye.xml"),
]


def haar_eyes(gray):
    """Haar 人脸 → 上 60% 区域内找眼，合并两套级联的候选。返回 (face_box, [(cx,cy,size)])。"""
    g8 = np.asarray(np.clip(gray, 0, 255), dtype=np.uint8)
    faces = FACE_CASCADE.detectMultiScale(g8, 1.1, 5, minSize=(60, 60))
    if len(faces) == 0:
        return None, []
    x, y, w, h = max(faces, key=lambda t: t[2] * t[3])
    roi = g8[y:y + int(h * 0.65), x:x + w]
    cands = []
    for c in EYE_CASCADES:
        for (ex, ey, ew, eh) in c.detectMultiScale(roi, 1.05, 5, minSize=(12, 12)):
            cands.append((x + ex + ew / 2.0, y + ey + eh / 2.0, max(ew, eh)))
    if not cands:
        return [int(x), int(y), int(w), int(h)], []
    # 左半 / 右半各取最大者，避免同一只眼出多个框
    cx_f = x + w / 2.0
    left = [c for c in cands if c[0] < cx_f]
    right = [c for c in cands if c[0] >= cx_f]
    if not left or not right:
        return [int(x), int(y), int(w), int(h)], []
    return [int(x), int(y), int(w), int(h)], [
        max(left, key=lambda c: c[2]), max(right, key=lambda c: c[2])]


def measure_m3(gray):
    """Haar 双眼连线（检测器与特征都与 M1/M2 不同）。"""
    box, eyes = haar_eyes(gray)
    if len(eyes) != 2:
        return None
    L, R = eyes if eyes[0][0] <= eyes[1][0] else (eyes[1], eyes[0])
    return {"deg": _angle_from_pair((L[0], L[1]), (R[0], R[1])),
            "left": (L[0], L[1]), "right": (R[0], R[1]),
            "box": box, "sizes": (L[2], R[2])}


def measure_m4(gray):
    """Haar 眼带 → Radon 脊线。"""
    box, eyes = haar_eyes(gray)
    if len(eyes) != 2:
        return None
    L, R = eyes if eyes[0][0] <= eyes[1][0] else (eyes[1], eyes[0])
    il, ir = (L[0], L[1]), (R[0], R[1])
    ed = math.hypot(ir[0] - il[0], ir[1] - il[1])
    if ed < 24:
        return None
    band = _eye_band(gray, il, ir)
    if band is None:
        return None
    r = _radon_orientation(band)
    if r is None:
        return None
    r["source"] = "haar-band"
    return r


# ---------------------------------------------------------------- 组合

def eye_pair(kps):
    """契约序：kps[0:2]=图像右眼, kps[2:4]=图像左眼（step12 已核）。

    本函数按 x 实际大小再排一次，避免契约序理解错导致符号翻转。
    """
    a = (kps[0], kps[1])
    b = (kps[2], kps[3])
    return (a, b) if a[0] <= b[0] else (b, a)


def yunet_eyeline(kps):
    il, ir = eye_pair(kps)
    return _angle_from_pair(il, ir)


def measure_all(gray, face):
    kps = face["kps"]
    il, ir = eye_pair(kps)
    eyedist = math.hypot(ir[0] - il[0], ir[1] - il[1])
    res = {"eyedist": eyedist, "yunet_eyeline": yunet_eyeline(kps)}
    for name, fn in (("m1_pupil", lambda: measure_m1(gray, kps, eyedist)),
                     ("m2_radon_yunet", lambda: measure_m2(gray, kps, eyedist)),
                     ("m3_haar_eyeline", lambda: measure_m3(gray)),
                     ("m4_radon_haar", lambda: measure_m4(gray))):
        try:
            res[name] = fn()
        except Exception as e:  # noqa: BLE001 —— 测量失败要显式记下，不静默
            res[name] = {"error": f"{type(e).__name__}: {e}"}
    return res


METHOD_KEYS = ("m1_pupil", "m2_radon_yunet", "m3_haar_eyeline", "m4_radon_haar")


def methods_deg(res):
    """抽出成功方法的 {name: deg}。"""
    out = {}
    for k in METHOD_KEYS:
        v = res.get(k)
        if isinstance(v, dict) and "deg" in v:
            out[k] = float(v["deg"])
    return out


# ---------------------------------------------------------------- overlay

def save_overlay(im, res, path, title=""):
    from PIL import ImageDraw
    base = im.copy()
    sc = max(1.0, 900.0 / max(base.size))
    if sc > 1.0:
        base = base.resize((int(base.size[0] * sc), int(base.size[1] * sc)), Image.LANCZOS)
    d = ImageDraw.Draw(base)
    W, H = base.size
    cx, cy = W / 2.0, H / 2.0
    L = max(W, H) * 0.42

    def line(deg, color, wdt, dash=False):
        # 画一条过画面中心、倾角 deg 的直线（图像坐标，y 向下）
        t = math.radians(deg)
        dx, dy = math.cos(t), math.sin(t)
        d.line([cx - dx * L, cy - dy * L, cx + dx * L, cy + dy * L], fill=color, width=wdt)

    line(0.0, (255, 255, 0), 1)                 # 水平参考（黄）
    for name, col in (("m1_pupil", (0, 255, 0)),
                      ("m2_radon_yunet", (0, 200, 255)),
                      ("m3_haar_eyeline", (255, 0, 0)),
                      ("m4_radon_haar", (255, 0, 255))):
        v = res.get(name)
        if isinstance(v, dict) and "deg" in v:
            line(v["deg"], col, 2)
    # 关键点与瞳孔位置
    face = res.get("_face")
    if face:
        for i in range(0, 10, 2):
            x, y = face["kps"][i], face["kps"][i + 1]
            d.ellipse([x - 3, y - 3, x + 3, y + 3], outline=(255, 255, 255), width=2)
        x, y, w, h = face["box"]
        d.rectangle([x, y, x + w, y + h], outline=(255, 255, 255), width=1)
    for name, col in (("m1_pupil", (0, 255, 0)), ("m3_haar_eyeline", (255, 0, 0))):
        v = res.get(name)
        if isinstance(v, dict) and "left" in v:
            for p in (v["left"], v["right"]):
                d.ellipse([p[0] - 5, p[1] - 5, p[0] + 5, p[1] + 5], outline=col, width=2)
    if title:
        d.rectangle([0, 0, 700, 20], fill=(0, 0, 0))
        d.text((4, 5), title, fill=(255, 255, 255))
    base.save(path)
    return base
