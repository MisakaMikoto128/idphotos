# -*- coding: utf-8 -*-
"""木照吉祥物：扁平插画风卡通人像（原创程序化绘制，零版权）。
风格：暖色扁平插画风，主体-背景高对比（利于 MODNet），边缘平滑。"""
from PIL import Image, ImageDraw, ImageFilter
import math

W, H = 1200, 1600
img = Image.new("RGB", (W, H), (233, 226, 214))  # 暖纸灰背景
d = ImageDraw.Draw(img)

# 轻微背景渐晕（让主体更突出）
vig = Image.new("L", (W, H), 0)
dv = ImageDraw.Draw(vig)
dv.ellipse([-W*0.25, -H*0.15, W*1.25, H*1.1], fill=60)
vig = vig.filter(ImageFilter.GaussianBlur(120))
img = Image.composite(Image.new("RGB", (W, H), (214, 205, 190)), img, vig)
d = ImageDraw.Draw(img)

CX = W // 2
def E(cx, cy, rx, ry, fill, outline=None, width=0):
    d.ellipse([cx-rx, cy-ry, cx+rx, cy+ry], fill=fill, outline=outline, width=width)

# ---- 肩膀/身体（木青绿外套，呼应 feltGreen）----
COAT = (47, 79, 58)
d.polygon([(CX-560, H), (CX-470, H-330), (CX-260, H-460),
           (CX+260, H-460), (CX+470, H-330), (CX+560, H)], fill=COAT)
# 领口白衬
d.polygon([(CX-150, H-455), (CX, H-330), (CX+150, H-455), (CX+90, H), (CX-90, H)],
          fill=(244, 233, 214))
# 黄铜扣子
for i, cy in enumerate([H-250, H-150]):
    E(CX, cy, 22, 22, (176, 141, 63))

# ---- 脖子 ----
E(CX, H-500, 95, 130, (238, 190, 160))

# ---- 头部 ----
HEAD_CY = int(H*0.40)
E(CX, HEAD_CY, 300, 345, (247, 205, 172))          # 脸
# 耳朵
E(CX-295, HEAD_CY+40, 42, 62, (247, 205, 172))
E(CX+295, HEAD_CY+40, 42, 62, (247, 205, 172))

# ---- 头发（深棕，圆弧刘海 + 侧发，覆盖头顶利于 MODNet 轮廓）----
HAIR = (62, 42, 27)
d.pieslice([CX-320, HEAD_CY-390, CX+320, HEAD_CY+120], 180, 360, fill=HAIR)
d.pieslice([CX-330, HEAD_CY-360, CX-150, HEAD_CY+240], 120, 250, fill=HAIR)
d.pieslice([CX+150, HEAD_CY-360, CX+330, HEAD_CY+240], 290, 60, fill=HAIR)
E(CX-260, HEAD_CY-260, 130, 150, HAIR)
E(CX+260, HEAD_CY-260, 130, 150, HAIR)
# 刘海下缘的圆弧缺口（更自然）
E(CX-140, HEAD_CY-165, 105, 85, (247, 205, 172))
E(CX+140, HEAD_CY-165, 105, 85, (247, 205, 172))
E(CX, HEAD_CY-195, 130, 75, (247, 205, 172))

# ---- 眉毛/眼睛/鼻/嘴 ----
BROW = (74, 52, 32)
d.rounded_rectangle([CX-215, HEAD_CY-45, CX-85, HEAD_CY-15], 15, fill=BROW)
d.rounded_rectangle([CX+85, HEAD_CY-45, CX+215, HEAD_CY-15], 15, fill=BROW)
# 眼白+瞳孔
for sx in (-150, 150):
    E(CX+sx, HEAD_CY+60, 62, 42, (255, 255, 255))
    E(CX+sx, HEAD_CY+64, 30, 30, (58, 43, 28))
    E(CX+sx+9, HEAD_CY+56, 10, 10, (255, 255, 255))
# 鼻
d.line([CX, HEAD_CY+95, CX-12, HEAD_CY+150], fill=(219, 168, 134), width=14)
E(CX-16, HEAD_CY+158, 16, 11, (219, 168, 134))
# 微笑
d.arc([CX-95, HEAD_CY+185, CX+95, HEAD_CY+290], 20, 160, fill=(163, 96, 82), width=16)

# ---- 腮红 ----
blush = Image.new("RGBA", (W, H), (0, 0, 0, 0))
db = ImageDraw.Draw(blush)
for sx in (-225, 225):
    db.ellipse([CX+sx-55, HEAD_CY+120, CX+sx+55, HEAD_CY+175], fill=(238, 150, 130, 90))
blush = blush.filter(ImageFilter.GaussianBlur(18))
img = Image.alpha_composite(img.convert("RGBA"), blush).convert("RGB")

img.save("store/avatar_photo.png")
print("avatar_photo.png saved", img.size)
