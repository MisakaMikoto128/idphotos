# -*- coding: utf-8 -*-
"""木照 MuZhao — 图标生成（G5B.1–5B.4）。

程序化绘制复古木制图标：木纹底 + 黄铜相框 + 证件照剪影。
色值全部来自 docs/DESIGN.md 色卡，禁止自创。
产出：
  store/icon_512.png                          512x512 RGBA
  mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png 48/72/96/144/192
  mipmap-*/ic_launcher_foreground.png         自适应前景（主体在中心 66% 安全区内）
  mipmap-anydpi-v26/ic_launcher.xml           自适应图标声明
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
STORE = os.path.join(ROOT, "store")

# ---- DESIGN.md 色卡 ----
WOOD_DARK = (0x3E, 0x2A, 0x1B)
WOOD_BASE = (0x6B, 0x4A, 0x2F)
WOOD_LIGHT = (0xA9, 0x78, 0x4F)
BRASS = (0xB0, 0x8D, 0x3F)
BRASS_HI = (0xE8, 0xCE, 0x7A)
BRASS_SHADOW = (0x6E, 0x53, 0x20)
PAPER = (0xF4, 0xE9, 0xD6)
PAPER_EDGE = (0xDC, 0xCB, 0xAE)
INK_BROWN = (0x3A, 0x2B, 0x1C)
SHADOW = (0x24, 0x16, 0x09)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def make_wood(w, h, seed=7, density=1.0):
    """竖直核桃木纹：底色 + 纵向纤维条 + 少量节疤 + 细噪点 + 上下渐变。"""
    rng = random.Random(seed)
    img = Image.new("RGB", (w, h), WOOD_BASE)
    dr = ImageDraw.Draw(img, "RGBA")
    # 纵向明暗带（低频）
    bands = rng.sample(range(0, w), max(3, int(w / 130)))
    for bx in bands:
        bw = rng.randint(int(w * 0.06), int(w * 0.16))
        col = lerp(WOOD_DARK, WOOD_BASE, rng.random() * 0.5)
        dr.rectangle([bx, 0, bx + bw, h], fill=col + (28,))
    # 纤维条（高频）
    n = int(w * 0.9 * density)
    for _ in range(n):
        x = rng.randint(0, w - 1)
        lw = rng.choice([1, 1, 1, 2, 2, 3])
        t = rng.random()
        col = WOOD_DARK if t < 0.55 else (WOOD_LIGHT if t > 0.85 else WOOD_BASE)
        a = rng.randint(18, 60)
        # 轻微弯曲
        pts = []
        amp = rng.randint(0, 6)
        ph = rng.uniform(0, 6.28)
        y0 = rng.randint(-40, 0)
        for y in range(y0, h + 40, 24):
            pts.append((x + int(amp * math.sin(y / 90.0 + ph)), y))
        dr.line(pts, fill=col + (a,), width=lw)
    # 节疤
    for _ in range(max(1, int(w / 260))):
        kx, ky = rng.randint(0, w), rng.randint(0, h)
        kr = rng.randint(int(w * 0.03), int(w * 0.05))
        for rr, aa in ((kr, 34), (int(kr * 0.6), 30), (int(kr * 0.3), 26)):
            dr.ellipse([kx - rr, ky - int(rr * 1.6), kx + rr, ky + int(rr * 1.6)],
                       outline=WOOD_DARK + (aa,), width=max(1, rr // 6))
    # 细噪点
    noise = Image.effect_noise((w, h), 14).convert("L")
    img = Image.composite(
        Image.new("RGB", (w, h), WOOD_DARK), img,
        noise.point(lambda v: 255 if v > 236 else 0))
    # 上下暗角
    vig = Image.new("L", (w, h), 0)
    dv = ImageDraw.Draw(vig)
    for y in range(h):
        d = min(y, h - 1 - y) / (h * 0.5)
        dv.line([(0, y), (w, y)], fill=int(60 * (1.0 - d)))
    img = Image.composite(Image.new("RGB", (w, h), SHADOW), img, vig)
    return img


def rounded_rect_mask(w, h, box, radius):
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=radius, fill=255)
    return m


def draw_brass_frame(img, box, width, radius, inset_highlight=True):
    """黄铜相框：垂直渐变 brassHi->brass->brassShadow，顶缘 1px 高光。"""
    x0, y0, x1, y1 = box
    w, h = img.size
    grad = Image.new("RGB", (w, h), BRASS)
    dg = ImageDraw.Draw(grad)
    for y in range(y0, y1 + 1):
        t = (y - y0) / max(1, y1 - y0)
        col = lerp(BRASS_HI, BRASS, min(1.0, t * 1.6)) if t < 0.45 else lerp(BRASS, BRASS_SHADOW, (t - 0.45) / 0.55)
        dg.line([(x0, y), (x1, y)], fill=col)
    ring = Image.new("L", (w, h), 0)
    drr = ImageDraw.Draw(ring)
    drr.rounded_rectangle(box, radius=radius, fill=255)
    drr.rounded_rectangle([x0 + width, y0 + width, x1 - width, y1 - width],
                          radius=max(1, radius - width), fill=0)
    img.paste(grad, (0, 0), ring)
    d2 = ImageDraw.Draw(img, "RGBA")
    if inset_highlight:
        d2.rounded_rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], radius=radius,
                             outline=BRASS_HI + (200,), width=1)
        d2.rounded_rectangle(box, radius=radius, outline=BRASS_SHADOW + (220,), width=1)


def draw_person(dr, cx, head_cy, head_r, color):
    """证件照剪影：头 + 肩，剪影风格，粗壮可辨识。"""
    dr.ellipse([cx - head_r, head_cy - head_r, cx + head_r, head_cy + head_r], fill=color)
    sw = head_r * 2.6
    sh = head_r * 1.35
    top = head_cy + head_r * 0.85
    dr.rounded_rectangle([cx - sw / 2, top, cx + sw / 2, top + sh * 2],
                         radius=int(sw * 0.42), fill=color)


def build_icon(size, with_bg=True, safe=1.0):
    """size 见方。with_bg=True 含木底（启动器图标）；False 为自适应前景（透明底）。"""
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    if with_bg:
        wood = make_wood(s, s, seed=11)
        img.paste(wood, (0, 0))
        # 双层边框（外 woodDark 内 woodLight，DESIGN.md 倒角）
        d = ImageDraw.Draw(img, "RGBA")
        b = max(1, s // 128)
        d.rectangle([0, 0, s - 1, s - 1], outline=WOOD_DARK + (255,), width=b * 2)
        d.rectangle([b * 2, b * 2, s - 1 - b * 2, s - 1 - b * 2],
                    outline=WOOD_LIGHT + (140,), width=b)

    # 相框几何：portrait 3:4，占中心 safe 比例
    fw = int(s * 0.56 * safe)
    fh = int(fw * 4 / 3)
    fx0 = (s - fw) // 2
    fy0 = (s - fh) // 2
    fx1, fy1 = fx0 + fw, fy0 + fh
    frame_w = max(3, int(fw * 0.075))
    rad = max(3, int(fw * 0.06))

    if not with_bg:
        # 前景投影（轻微，位于安全区内）
        sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        ds = ImageDraw.Draw(sh)
        off = max(2, s // 60)
        ds.rounded_rectangle([fx0 + off, fy0 + off, fx1 + off, fy1 + off],
                             radius=rad, fill=SHADOW + (110,))
        sh = sh.filter(ImageFilter.GaussianBlur(s / 48))
        img.alpha_composite(sh)

    draw_brass_frame(img, (fx0, fy0, fx1, fy1), frame_w, rad)

    # 相纸（照片区）
    px0, py0 = fx0 + frame_w, fy0 + frame_w
    px1, py1 = fx1 - frame_w, fy1 - frame_w
    photo = Image.new("RGBA", (px1 - px0 + 1, py1 - py0 + 1), PAPER + (255,))
    pd = ImageDraw.Draw(photo)
    # 顶部一条 paperEdge 分隔，模拟证件照衬卡
    pw, ph = photo.size
    pd.rectangle([0, int(ph * 0.86), pw - 1, ph - 1], fill=PAPER_EDGE + (255,))
    # 人像剪影
    draw_person(pd, pw // 2, int(ph * 0.40), int(pw * 0.21), INK_BROWN + (255,))
    img.paste(photo, (px0, py0))

    # 四角铜角标（L 形，粗壮）
    d3 = ImageDraw.Draw(img, "RGBA")
    cl = int(fw * 0.14)
    cw = max(2, int(fw * 0.035))
    for (cx, cy, sx, sy) in ((px0, py0, 1, 1), (px1, py0, -1, 1),
                             (px0, py1, 1, -1), (px1, py1, -1, -1)):
        d3.line([(cx, cy), (cx + sx * cl, cy)], fill=BRASS_HI + (255,), width=cw)
        d3.line([(cx, cy), (cx, cy + sy * cl)], fill=BRASS_HI + (255,), width=cw)

    return img


def non_bg_ratio(im, bg):
    """与背景色 ΔE 粗略（欧氏距离）>48 的像素占比。"""
    px = im.convert("RGB").getdata()
    cnt = 0
    total = len(px)
    for p in px:
        if abs(p[0] - bg[0]) + abs(p[1] - bg[1]) + abs(p[2] - bg[2]) > 96:
            cnt += 1
    return cnt / total


def main():
    os.makedirs(STORE, exist_ok=True)

    # G5B.1 主图标
    icon512 = build_icon(512, with_bg=True)
    icon512.save(os.path.join(STORE, "icon_512.png"))
    print("icon_512.png", icon512.size, icon512.mode)

    # G5B.2 全密度启动器图标
    dens = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for d, n in dens.items():
        out = os.path.join(RES, "mipmap-%s" % d)
        os.makedirs(out, exist_ok=True)
        icon = build_icon(n, with_bg=True)
        icon.save(os.path.join(out, "ic_launcher.png"))
        # 自适应前景：同一主体，透明底，主体缩进中心 66% 安全区
        fg = build_icon(n, with_bg=False, safe=0.60)
        fg.save(os.path.join(out, "ic_launcher_foreground.png"))
        print("mipmap-%s: ic_launcher %dpx, foreground %dpx" % (d, n, n))

    # G5B.3 自适应图标声明
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '</adaptive-icon>\n')

    # 背景：木纹垂直渐变（drawable shape，不引入位图体积）
    drw = os.path.join(RES, "drawable")
    os.makedirs(drw, exist_ok=True)
    with open(os.path.join(drw, "ic_launcher_background.xml"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<shape xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <gradient android:angle="270"\n'
                '        android:startColor="#6B4A2F"\n'
                '        android:centerColor="#5C3E27"\n'
                '        android:endColor="#3E2A1B"/>\n'
                '</shape>\n')

    # G5B.4 48x48 缩略可辨认自检
    thumb = icon512.resize((48, 48), Image.LANCZOS)
    thumb.save(os.path.join(STORE, "icon_48_thumb_check.png"))
    r = non_bg_ratio(thumb, (0x5C, 0x3E, 0x27))
    print("48x48 non-bg ratio = %.1f%% (threshold 12%%) -> %s"
          % (r * 100, "PASS" if r >= 0.12 else "FAIL"))

    # G5B.3 前景安全区自检（非透明像素外接框须在中心 66% 内）
    fg432 = build_icon(432, with_bg=False, safe=0.60)
    bbox = fg432.getbbox()
    lo, hi = 432 * 0.17, 432 * 0.83
    ok = bbox[0] >= lo and bbox[1] >= lo and bbox[2] <= hi and bbox[3] <= hi
    print("foreground bbox=%s, safe zone [%.0f..%.0f] -> %s"
          % (bbox, lo, hi, "PASS" if ok else "FAIL"))


if __name__ == "__main__":
    main()
