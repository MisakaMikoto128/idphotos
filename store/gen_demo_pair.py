# -*- coding: utf-8 -*-
"""效果示意插画对：生活照（杂乱背景）→ 证件照成品（蓝底规格裁切）。
全部原创绘制；复用 avatar 的部件函数，两帧同一角色。"""
from PIL import Image, ImageDraw, ImageFilter
import math

def draw_character(d, CX, HEAD_CY, S=1.0, coat=(47,79,58), skin=(247,205,172), body_dy=0):
    """在画布 d 上以 (CX, HEAD_CY) 为脸心、S 为缩放画角色（头发/脸/衣）。"""
    def E(cx, cy, rx, ry, fill):
        d.ellipse([cx-rx, cy-ry, cx+rx, cy+ry], fill=fill)
    HAIR=(62,42,27)
    s=lambda v: int(v*S)
    # 身体
    BY=HEAD_CY+s(720)+body_dy
    d.polygon([(CX-s(560), BY+s(460)), (CX-s(470), BY+s(130)), (CX-s(260), BY),
               (CX+s(260), BY), (CX+s(470), BY+s(130)), (CX+s(560), BY+s(460))], fill=coat)
    d.polygon([(CX-s(150), BY+s(5)), (CX, BY+s(130)), (CX+s(150), BY+s(5)),
               (CX+s(90), BY+s(460)), (CX-s(90), BY+s(460))], fill=(244,233,214))
    for cy in (BY+s(210), BY+s(310)):
        E(CX, cy, s(22), s(22), (176,141,63))
    E(CX, HEAD_CY+s(680)+body_dy//2, s(95), s(130), skin)
    # 脸
    E(CX, HEAD_CY, s(300), s(345), skin)
    E(CX-s(295), HEAD_CY+s(40), s(42), s(62), skin)
    E(CX+s(295), HEAD_CY+s(40), s(42), s(62), skin)
    # 头发
    d.pieslice([CX-s(320), HEAD_CY-s(390), CX+s(320), HEAD_CY+s(120)], 180, 360, fill=HAIR)
    d.pieslice([CX-s(330), HEAD_CY-s(360), CX-s(150), HEAD_CY+s(240)], 120, 250, fill=HAIR)
    d.pieslice([CX+s(150), HEAD_CY-s(360), CX+s(330), HEAD_CY+s(240)], 290, 60, fill=HAIR)
    E(CX-s(260), HEAD_CY-s(260), s(130), s(150), HAIR)
    E(CX+s(260), HEAD_CY-s(260), s(130), s(150), HAIR)
    E(CX-s(140), HEAD_CY-s(165), s(105), s(85), skin)
    E(CX+s(140), HEAD_CY-s(165), s(105), s(85), skin)
    E(CX, HEAD_CY-s(195), s(130), s(75), skin)
    # 五官
    BROW=(74,52,32)
    d.rounded_rectangle([CX-s(215), HEAD_CY-s(45), CX-s(85), HEAD_CY-s(15)], s(15), fill=BROW)
    d.rounded_rectangle([CX+s(85), HEAD_CY-s(45), CX+s(215), HEAD_CY-s(15)], s(15), fill=BROW)
    for sx in (-150, 150):
        E(CX+sx, HEAD_CY+s(60), s(62), s(42), (255,255,255))
        E(CX+sx, HEAD_CY+s(64), s(30), s(30), (58,43,28))
        E(CX+sx+s(9), HEAD_CY+s(56), s(10), s(10), (255,255,255))
    d.line([CX, HEAD_CY+s(95), CX-s(12), HEAD_CY+s(150)], fill=(219,168,134), width=max(4,s(14)))
    E(CX-s(16), HEAD_CY+s(158), s(16), s(11), (219,168,134))
    d.arc([CX-s(95), HEAD_CY+s(185), CX+s(95), HEAD_CY+s(290)], 20, 160, fill=(163,96,82), width=max(5,s(16)))
    for sx in (-225, 225):
        E(CX+sx, HEAD_CY+s(147), s(55), s(27), (238,177,158))

# ---------- 帧 1：生活照（室内、杂乱温暖背景）----------
W,H = 1200,1600
img = Image.new("RGB",(W,H),(196,178,152))
d = ImageDraw.Draw(img)
# 背景墙 + 窗光 + 植物剪影（示意"生活场景"）
d.rectangle([0,0,W,int(H*0.62)], fill=(214,199,176))
d.rectangle([0,int(H*0.62),W,H], fill=(176,158,132))
for x0 in (80, 940):
    d.rounded_rectangle([x0,120,x0+180,640], 18, fill=(226,216,198), outline=(150,134,110), width=8)
    d.line([x0+90,120,x0+90,640], fill=(150,134,110), width=6)
    d.line([x0,380,x0+180,380], fill=(150,134,110), width=6)
leaf=(96,116,84)
for i,(px,py,r) in enumerate([(180,900,150),(1020,860,170),(300,1120,120),(880,1150,140)]):
    for a in range(0,360,30):
        ex,ey = px+r*math.cos(math.radians(a)), py+r*0.5*math.sin(math.radians(a))
        d.ellipse([ex-40,ey-70,ex+40,ey+70], fill=leaf)
d = ImageDraw.Draw(img)
# 玩偶/相框摆件（增加生活感）
d.rounded_rectangle([520,880,690,1120], 20, fill=(228,214,192), outline=(150,134,110), width=8)
img = img.filter(ImageFilter.GaussianBlur(1))  # 背景轻微虚化
d = ImageDraw.Draw(img)
draw_character(d, W//2, int(H*0.34))
img.save("store/demo_before.png")
print("before saved")

# ---------- 帧 2：证件照成品（S=1.0 大幅蓝底 → 裁规格窗口 → 白边相纸）----------
BIG_W, BIG_H = 1200, 1600
big = Image.new("RGB", (BIG_W, BIG_H), (67, 142, 219))  # app blue #438EDB
d2 = ImageDraw.Draw(big)
HEAD_CY2 = 640          # 脸心：头顶(640-390=250) 之后按 9% 留白裁
draw_character(d2, BIG_W//2, HEAD_CY2, body_dy=-260)
# ID 窗口：头高 735px = 0.62*Hc -> Hc=1185, Wc=1185*295/413≈846
Hc = 1185; Wc = int(Hc*295/413)
top = (HEAD_CY2-390) - int(0.055*Hc)  # 与 S5 真实输出构图对齐：头顶余量收窄，完整含入双丸子头
left = BIG_W//2 - Wc//2
crop = big.crop((left, top, left+Wc, top+Hc))
# 白边相纸
m = 42
card = Image.new("RGB", (Wc+2*m, Hc+2*m), (247, 244, 238))
card.paste(crop, (m, m))
card.save("store/demo_after.png")
print("after saved", card.size)
