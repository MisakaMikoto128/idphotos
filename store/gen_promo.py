# -*- coding: utf-8 -*-
"""木照 MuZhao — 功能图与宣传截图生成（G5B.5–5B.7）。

宣传截图基于 out/shots/ 的真实界面截图合成（不得手绘伪造界面）：
1080x1920，木纹背景 + 顶部卖点标题 + 带黄铜边框的真实界面截图。
功能图 1024x500，重要内容置于中心 80%。
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---- DESIGN.md 色卡 ----
WOOD_DARK = (0x3E, 0x2A, 0x1B)
WOOD_BASE = (0x6B, 0x4A, 0x2F)
WOOD_LIGHT = (0xA9, 0x78, 0x4F)
BRASS = (0xB0, 0x8D, 0x3F)
BRASS_HI = (0xE8, 0xCE, 0x7A)
BRASS_SHADOW = (0x6E, 0x53, 0x20)
PAPER = (0xF4, 0xE9, 0xD6)
INK_BROWN = (0x3A, 0x2B, 0x1C)
CREAM = (0xF0, 0xE4, 0xCE)
SHADOW = (0x24, 0x16, 0x09)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "out", "shots")
STORE = os.path.join(ROOT, "store")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_icon import make_wood  # noqa: E402


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


_FONT_ZH = os.path.join(ROOT, "assets", "fonts", "NotoSerifSC-Subset-Bold.ttf")
_FONT_ZH_FULL = r"C:\Windows\Fonts\NotoSerifSC-VF.ttf"


def _has_glyph(f, c):
    m = f.getmask(c)
    b = m.getbbox()
    return b is not None and b[2] > b[0] and b[3] > b[1]


def font_zh(size):
    """宣传图专用：优先 App 内子集字体；缺字（如 免/费/证）则回退系统全量
    Noto Serif SC（同一字族，仅用于宣传 PNG，不进 App 包）。"""
    f = ImageFont.truetype(_FONT_ZH, size)
    probe = "完全离线照片不出手机种证件规格比例自动锁定拖拽四角精确裁剪一键换底色任选本地智能抠图秒级出片免费保存无水印广告木照"
    if all(_has_glyph(f, c) for c in probe):
        return f
    full = ImageFont.truetype(_FONT_ZH_FULL, size)
    try:
        full.set_variation_by_name("Bold")
    except Exception:
        pass
    return full


def font_en(size):
    for p in (r"C:\Windows\Fonts\georgiab.ttf", r"C:\Windows\Fonts\timesbd.ttf",
              r"C:\Windows\Fonts\georgia.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.truetype(_FONT_ZH_FULL, size)


def draw_text_fit(dr, xy_center_x, y, text, font_path_fn, max_w, fill,
                  anchor="ma", min_size=30, start=84):
    size = start
    while size > min_size:
        f = font_path_fn(size)
        w = dr.textbbox((0, 0), text, font=f)[2]
        if w <= max_w:
            break
        size -= 4
    dr.text((xy_center_x, y), text, font=font_path_fn(size), fill=fill, anchor=anchor)
    f = font_path_fn(size)
    return dr.textbbox((0, 0), text, font=f)[3] - f.getbbox(text)[1]


def brass_hrule(dr, cx, y, half, weight=4):
    dr.line([(cx - half, y), (cx + half, y)], fill=BRASS_SHADOW + (180,), width=weight + 2)
    dr.line([(cx - half, y - 1), (cx + half, y - 1)], fill=BRASS_HI + (255,), width=weight)


def frame_screenshot(scr, target_h):
    """真实界面截图 + 木质外框 + 黄铜内边。返回带框图。"""
    w = round(scr.width * target_h / scr.height)
    scr = scr.resize((w, target_h), Image.LANCZOS)
    pad = 14  # 木框厚
    bw = 5    # 铜边厚
    W = w + (pad + bw + 4) * 2
    H = target_h + (pad + bw + 4) * 2
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(out, "RGBA")
    # 投影
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sh)
    ds.rounded_rectangle([10, 14, W - 6, H - 2], radius=8, fill=SHADOW + (150,))
    out.alpha_composite(sh)
    # 木框（双层倒角）
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=8, fill=WOOD_BASE + (255,))
    d.rounded_rectangle([0, 0, W - 1, H - 1], radius=8, outline=WOOD_DARK + (255,), width=3)
    d.rounded_rectangle([4, 4, W - 5, H - 5], radius=6, outline=WOOD_LIGHT + (160,), width=2)
    # 黄铜内边（垂直渐变）
    x0, y0 = pad, pad
    x1, y1 = W - pad - 1, H - pad - 1
    for y in range(y0, y1 + 1):
        t = (y - y0) / (y1 - y0)
        col = lerp(BRASS_HI, BRASS, min(1.0, t * 1.6)) if t < 0.45 else lerp(BRASS, BRASS_SHADOW, (t - 0.45) / 0.55)
        d.line([(x0, y), (x1, y)], fill=col)
    d.rectangle([x0, y0, x1, y1], outline=BRASS_SHADOW + (230,), width=1)
    # 贴截图
    out.paste(scr.convert("RGB"), (pad + bw + 2, pad + bw + 2))
    return out


def compose_shot(src_path, title, out_path, lang, footer):
    src = Image.open(src_path).convert("RGB")
    W, H = 1080, 1920
    canvas = make_wood(W, H, seed=lang == "zh" and 21 or 23).convert("RGBA")
    d = ImageDraw.Draw(canvas, "RGBA")

    # 标题
    fnt = font_zh if lang == "zh" else font_en
    th = draw_text_fit(d, W // 2, 96, title, fnt, 960, CREAM + (255,),
                       start=80 if lang == "zh" else 66)
    brass_hrule(d, W // 2, 96 + th + 44, 240)

    # 真实界面截图（带框）
    framed = frame_screenshot(src, 1400)
    canvas.alpha_composite(framed, ((W - framed.width) // 2, 288))

    # 底部落款
    f_app = fnt(46) if lang == "zh" else font_en(40)
    d.text((W // 2, H - 62), footer, font=f_app, fill=CREAM + (220,), anchor="ma")

    canvas.convert("RGB").save(out_path, quality=92)
    print("saved", out_path, canvas.size)


SHOTS_ZH = [
    ("S1_empty.png", "完全离线，照片不出手机"),
    ("S2_loaded.png", "7 种证件规格，比例自动锁定"),
    ("S3_dragging.png", "拖拽四角，精确裁剪"),
    ("S5_ready.png", "一键换底色，6 种底色任选"),
    ("S4_generating.png", "本地智能抠图，秒级出片"),
    ("S6_saved.png", "免费保存，无水印无广告"),
]

SHOTS_EN = [
    ("S1_empty.png", "Fully offline — photos never leave your phone"),
    ("S2_loaded.png", "7 ID photo sizes with auto-locked ratios"),
    ("S3_dragging.png", "Drag the corners to crop with precision"),
    ("S5_ready.png", "One tap to swap the background colour"),
    ("S4_generating.png", "On-device AI cutout in seconds"),
    ("S6_saved.png", "Free to save — no watermark, no ads"),
]


def feature_graphic():
    W, H = 1024, 500
    canvas = make_wood(W, H, seed=31).convert("RGBA")
    d = ImageDraw.Draw(canvas, "RGBA")
    # 装饰双框（可被裁切的边缘装饰，非重要内容）
    d.rectangle([14, 14, W - 15, H - 15], outline=WOOD_DARK + (255,), width=4)
    d.rectangle([22, 22, W - 23, H - 23], outline=WOOD_LIGHT + (150,), width=2)

    icon = Image.open(os.path.join(STORE, "icon_512.png")).resize((230, 230), Image.LANCZOS)
    canvas.alpha_composite(icon, (150, 120))
    # 铭牌托底
    d.rounded_rectangle([142, 350, 388, 394], radius=6, fill=BRASS + (255,))
    d.rounded_rectangle([142, 350, 388, 394], radius=6, outline=BRASS_SHADOW + (255,), width=2)
    d.text((265, 372), "MuZhao", font=font_en(30), fill=(0x33, 0x26, 0x0C, 255), anchor="mm")

    d.text((420, 178), "木照", font=font_zh(118), fill=CREAM + (255,), anchor="lm")
    d.text((422, 262), "OFFLINE ID PHOTO", font=font_en(28),
           fill=(0xE8, 0xCE, 0x7A, 235), anchor="lm")
    brass_hrule(d, 662, 300, 170, weight=3)
    d.text((420, 340), "完全离线 · 免费证件照 · 无水印", font=font_zh(38),
           fill=CREAM + (255,), anchor="lm")

    canvas.convert("RGB").save(os.path.join(STORE, "feature_graphic.png"))
    print("saved feature_graphic.png", canvas.size)


def main():
    for lang, shots in (("zh", SHOTS_ZH), ("en", SHOTS_EN)):
        outdir = os.path.join(STORE, "screenshots", lang)
        os.makedirs(outdir, exist_ok=True)
        footer = "木照 MuZhao" if lang == "zh" else "MuZhao"
        for i, (fn, title) in enumerate(shots, 1):
            compose_shot(os.path.join(SHOTS, fn), title,
                         os.path.join(outdir, "%02d.png" % i), lang, footer)
    feature_graphic()

    # 字体覆盖自检：标题文案中每个中文字必须真实渲染（非零轮廓）
    f = font_zh(48)
    need = "".join(t for _, t in SHOTS_ZH) + "木照免费证件无水印"
    missing = [c for c in set(need) if not _has_glyph(f, c)]
    print("zh glyph missing:", "".join(sorted(missing)) if missing else "NONE")


if __name__ == "__main__":
    main()
