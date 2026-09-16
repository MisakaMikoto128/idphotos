# -*- coding: utf-8 -*-
"""adversarial G4.4：构造对抗 fixtures + manifest（host 侧，一次性）。

产出：
  test/adversarial/fixtures/*.jpg/png/gif/...   畸形 / 极端样本（保留供回归复测）
  test/adversarial/fixtures/manifest.json        runner 用例表 + EXIF 方向参考剖面

face 检测用 .venv_ref 的 mtcnnruntime（注意 qa-batch PITFALLS：0 脸时抛
ValueError，要按空列表兜住）。不用 face 检测时忽略。
"""
import io
import json
import math
import os
import struct
import sys
import zlib

from PIL import Image, ImageOps
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIX = os.path.join(ROOT, "test", "adversarial", "fixtures")
GOLD = os.path.join(ROOT, "test", "golden", "src")

Image.MAX_IMAGE_PIXELS = None  # 我们自己就是造炸弹的人

os.makedirs(FIX, exist_ok=True)


def p(name):
    return os.path.join(FIX, name)


def save_png(path, arr):
    Image.fromarray(arr).save(path)


# ---------------------------------------------------------------- 基准人像
base = Image.open(os.path.join(GOLD, "g01.jpg")).convert("RGB")
upright = ImageOps.exif_transpose(base)  # 1080x1415，竖构图
base_g02 = Image.open(os.path.join(GOLD, "g02.jpg")).convert("RGB")

cases = []  # manifest 条目


def add(cid, file, kind, **kw):
    d = {"id": cid, "file": file, "kind": kind}
    d.update(kw)
    cases.append(d)


# ================================================================ 畸形文件
# m01 0 字节
open(p("m01_zero_byte.jpg"), "wb").close()
add("m01", "m01_zero_byte.jpg", "engine", expect="UnsupportedImageException")

# m02 文本改名 .jpg
with open(p("m02_text_as_jpg.jpg"), "wb") as f:
    f.write(("这不是图片，这是UTF-8文本。" * 40).encode("utf-8"))
add("m02", "m02_text_as_jpg.jpg", "engine", expect="UnsupportedImageException")

# m03 截断到一半的 JPEG
raw = open(os.path.join(GOLD, "g01.jpg"), "rb").read()
open(p("m03_truncated_jpg.jpg"), "wb").write(raw[: len(raw) // 2])
add("m03", "m03_truncated_jpg.jpg", "engine", expect="UnsupportedImage/Matting")

# m04 PNG 头部完好、IDAT 数据段损坏
buf = io.BytesIO()
Image.fromarray((np.random.RandomState(4).rand(64, 64, 3) * 255).astype(np.uint8)).save(buf, "PNG")
png = bytearray(buf.getvalue())
# 找到 IDAT 段，把中间 32 字节砸烂（保留 IHDR/长度结构）
i = png.find(b"IDAT")
for k in range(i + 4, i + 36):
    png[k] = 0xA5 ^ (k & 0xFF)
open(p("m04_png_corrupt_idat.png"), "wb").write(bytes(png))
add("m04", "m04_png_corrupt_idat.png", "engine", expect="UnsupportedImageException")

# m05 PNG 炸弹头：声明 100000000 x 100000000（超 8000，应在头扫描阶段拒绝）


def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)


def png_with_ihdr(w, h, bitdepth=8, colortype=2, idat=b"\x00" * 64):
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, bitdepth, colortype, 0, 0, 0))
    out += chunk(b"IDAT", idat)
    out += chunk(b"IEND", b"")
    return out


open(p("m05_png_bomb_header.png"), "wb").write(
    png_with_ihdr(100000000, 100000000))
add("m05", "m05_png_bomb_header.png", "engine", expect="ImageTooLargeException")

# m06 限内炸弹：7900x7900（<8000 不触发头扫描拒绝）但数据段只有 64 字节
open(p("m06_png_bomb_7900.png"), "wb").write(png_with_ihdr(7900, 7900))
add("m06", "m06_png_bomb_7900.png", "engine", expect="UnsupportedImage/Matting")

# m07 CMYK JPEG
base.convert("CMYK").save(p("m07_cmyk.jpg"), quality=92)
add("m07", "m07_cmyk.jpg", "engine", expect="解码成功或 UnsupportedImage，不崩溃")

# m08 16-bit PNG
arr16 = (np.random.RandomState(8).rand(96, 128) * 65535).astype(np.uint16)
Image.fromarray(arr16, mode="I;16").save(p("m08_16bit.png"))
add("m08", "m08_16bit.png", "engine", expect="解码成功或 UnsupportedImage，不崩溃")

# m09 动图 GIF
fr = [Image.fromarray((np.random.RandomState(i).rand(80, 120, 3) * 255).astype(np.uint8)) for i in range(3)]
fr[0].save(p("m09_anim.gif"), save_all=True, append_images=fr[1:], loop=0)
add("m09", "m09_anim.gif", "engine", expect="解码成功（取首帧）或 UnsupportedImage，不崩溃")

# m10 动画 WebP
fr[0].save(p("m10_anim.webp"), save_all=True, append_images=fr[1:], loop=0)
add("m10", "m10_anim.webp", "engine", expect="解码成功（取首帧）或 UnsupportedImage，不崩溃")

# m11 多帧 TIFF
fr[0].save(p("m11_multi.tif"), save_all=True, append_images=fr[1:])
add("m11", "m11_multi.tif", "engine", expect="解码成功（取首帧）或 UnsupportedImage，不崩溃")

# m12 伪 HEIC：ftyp heic 盒头 + 垃圾
open(p("m12_fake.heic"), "wb").write(
    b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00heicmif1" + os.urandom(512))
add("m12", "m12_fake.heic", "engine", expect="UnsupportedImageException")

# m13 合法 JPEG + 尾部垃圾（宽松解码器应容忍）
open(p("m13_jpg_trailing_garbage.jpg"), "wb").write(raw + b"MZMZ" * 128)
add("m13", "m13_jpg_trailing_garbage.jpg", "engine", expect="解码成功（容忍尾部垃圾）")

# m14 PNG 内容改名 .jpg
Image.fromarray((np.random.RandomState(14).rand(120, 90, 3) * 255).astype(np.uint8)).save(p("m14_png_as_jpg.jpg"), "PNG")
add("m14", "m14_png_as_jpg.jpg", "engine", expect="解码成功（按内容嗅探）或 UnsupportedImage，不崩溃")

# m15 PE 头改名 .png
open(p("m15_exe_as_png.png"), "wb").write(b"MZ" + os.urandom(600))
add("m15", "m15_exe_as_png.png", "engine", expect="UnsupportedImageException")

# m16 中文+emoji 文件名的正常 JPEG
base.save(p("m16_中文文件名🙂.jpg"), quality=92)
add("m16", "m16_中文文件名🙂.jpg", "engine", expect="解码成功（长路径/unicode 文件名不炸）")

# ================================================================ 极端尺寸
one = np.full((1, 1, 3), 200, np.uint8)
save_png(p("s01_1x1.png"), one)
add("s01", "s01_1x1.png", "engine", expect="MattingException/优雅失败，不崩溃")
Image.fromarray(one).save(p("s02_1x1.jpg"), quality=92)
add("s02", "s02_1x1.jpg", "engine", expect="MattingException/优雅失败，不崩溃")

save_png(p("s03_strip_20x8000.png"), np.full((20, 8000, 3), 90, np.uint8))
add("s03", "s03_strip_20x8000.png", "engine", expect="不崩溃（8000 恰好不超限）")
Image.fromarray(np.full((8000, 20, 3), 90, np.uint8)).save(p("s04_strip_8000x20.jpg"), quality=85)
add("s04", "s04_strip_8000x20.jpg", "engine", expect="不崩溃")
save_png(p("s05_strip_1x8000.png"), np.full((1, 8000, 3), 120, np.uint8))
add("s05", "s05_strip_1x8000.png", "engine", expect="不崩溃")

# s06 恰好 8000x6000 真实大图（降采样路径极限）
big = upright.resize((8000, 6000), Image.LANCZOS)
big.save(p("s06_8000x6000.jpg"), quality=80)
add("s06", "s06_8000x6000.jpg", "engine", expect="成功，工作分辨率 2048x1536，不 OOM")

# s07 超限 1px
save_png(p("s07_8001x100.png"), np.full((100, 8001, 3), 80, np.uint8))
add("s07", "s07_8001x100.png", "engine", expect="ImageTooLargeException")

# s08 超限大图
Image.fromarray(np.full((9000, 12000, 3), 150, np.uint8)).save(p("s08_12000x9000.jpg"), quality=60)
add("s08", "s08_12000x9000.jpg", "engine", expect="ImageTooLargeException")

# s09 恰好等于目标规格尺寸的正方形
save_png(p("s09_square_600x600.png"), np.full((600, 600, 3), 180, np.uint8))
add("s09", "s09_square_600x600.png", "engine", expect="不崩溃")

# s10 2x3 微型
save_png(p("s10_2x3.png"), np.full((3, 2, 3), 128, np.uint8))
add("s10", "s10_2x3.png", "engine", expect="优雅失败，不崩溃")

# s11 2049x2049 恰好越过引擎工作分辨率
save_png(p("s11_2049x2049.png"), np.full((2049, 2049, 3), 160, np.uint8))
add("s11", "s11_2049x2049.png", "engine", expect="成功，走降采样路径")

# ================================================================ 内容极端
blk = np.zeros((512, 512, 3), np.uint8)
save_png(p("c01_all_black.png"), blk)
add("c01", "c01_all_black.png", "engine", expect="0 脸，不崩溃")

wht = np.full((512, 512, 3), 255, np.uint8)
save_png(p("c02_all_white.png"), wht)
add("c02", "c02_all_white.png", "engine", expect="0 脸，不崩溃")

noise = (np.random.RandomState(3).rand(512, 512, 3) * 255).astype(np.uint8)
save_png(p("c03_pure_noise.png"), noise)
add("c03", "c03_pure_noise.png", "engine", expect="0 脸，不崩溃")

# c04 强噪点人像
u = np.asarray(upright, np.float32)
rs = np.random.RandomState(5)
noisy = np.clip(u + rs.normal(0, 45, u.shape), 0, 255).astype(np.uint8)
Image.fromarray(noisy).save(p("c04_noisy_portrait.jpg"), quality=88)
add("c04", "c04_noisy_portrait.jpg", "engine", expect="脸检出/优雅失败，不崩溃")

# c05 合合影裁半（多人脸）
group = Image.open(r"C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png").convert("RGB")
half = group.resize((2016, 1512), Image.LANCZOS).crop((0, 0, 2016, 1512))
half.save(p("c05_group.jpg"), quality=88)
add("c05", "c05_group.jpg", "engine", expect="多人脸，不崩溃")

# c06 倒置人脸
ImageOps.flip(upright).save(p("c06_upside_down.jpg"), quality=92)
add("c06", "c06_upside_down.jpg", "engine", expect="脸检出/0 脸均不崩溃")

# c07 半张脸贴边
try:
    from mtcnnruntime import MTCNN
    try:
        faces, _ = MTCNN().detect(np.asarray(upright)[:, :, ::-1].copy())  # BGR
    except ValueError:
        faces, _ = [], []
    assert faces is not None and len(faces) > 0, "mtcnn 0 脸"
    fb = faces[0]
    x0, y0, x1, y1 = [int(v) for v in fb[:4]]
    cx = (x0 + x1) // 2
    W, H = upright.size
    # 裁到脸中心恰好压在左边缘：脸左半在画外
    box = (cx - (x1 - x0) // 4, max(0, y0 - (y1 - y0)), min(W, cx + 2 * (x1 - x0)), min(H, y1 + 3 * (y1 - y0)))
    half_face = upright.crop(box)
except Exception as e:  # noqa
    print("mtcnn fallback:", e)
    half_face = upright.crop((0, 0, 540, 1415))
half_face.save(p("c07_half_face_edge.jpg"), quality=92)
add("c07", "c07_half_face_edge.jpg", "engine", expect="不崩溃（检出或优雅失败）")

# c08 人占画面 <2%
canvas = np.full((2400, 2400, 3), 245, np.uint8)
tiny = upright.resize((260, 340), Image.LANCZOS)
canvas[300:640, 400:660] = np.asarray(tiny)
save_png(p("c08_tiny_person.png"), canvas)
add("c08", "c08_tiny_person.png", "engine", expect="不崩溃")

# c09 纯肤色块（接近人脸色的无脸图）
save_png(p("c09_skin_tone.png"), np.full((512, 512, 3), (224, 188, 160), np.uint8))
add("c09", "c09_skin_tone.png", "engine", expect="0 脸，不崩溃")

# c10 灰度人像
upright.convert("L").convert("RGB").save(p("c10_grayscale.jpg"), quality=92)
add("c10", "c10_grayscale.jpg", "engine", expect="解码成功")

# c11 浅背景+浅肤色人像（亮度拉满）
pale = np.clip(np.asarray(upright, np.float32) * 0.35 + 220, 0, 255).astype(np.uint8)
Image.fromarray(pale).save(p("c11_pale_portrait.jpg"), quality=92)
add("c11", "c11_pale_portrait.jpg", "engine", expect="不崩溃")

# ================================================================ EXIF 方向
# 参考：摆正后的 16x16 灰度剖面（+ 3 个旋转版本），runner 端比对
g = np.asarray(upright.convert("L").resize((64, 64), Image.BILINEAR), np.float32)


def profile16(a):
    h, w = a.shape
    out = np.zeros((16, 16), np.float32)
    for iy in range(16):
        for ix in range(16):
            out[iy, ix] = a[iy * h // 16:(iy + 1) * h // 16, ix * w // 16:(ix + 1) * w // 16].mean()
    return out


prof = profile16(g)


def rot90(a, k):
    return np.rot90(a, k)


ref = {
    "portrait": upright.size[1] > upright.size[0],
    "ref": np.round(prof.ravel()).astype(int).tolist(),
    "ref_r90": np.round(rot90(prof, 1).ravel()).astype(int).tolist(),
    "ref_r180": np.round(rot90(prof, 2).ravel()).astype(int).tolist(),
    "ref_r270": np.round(rot90(prof, 3).ravel()).astype(int).tolist(),
}


def save_exif(img_, name, ori):
    ex = img_.getexif()
    ex[0x0112] = ori
    img_.save(name, quality=92, exif=ex.tobytes())


T = Image.Transpose
variants = [
    ("e01_o1", upright, 1),
    ("e02_o2", upright.transpose(T.FLIP_LEFT_RIGHT), 2),
    ("e03_o3", upright.transpose(T.ROTATE_180), 3),
    ("e04_o4", upright.transpose(T.FLIP_TOP_BOTTOM), 4),
    ("e05_o5", upright.transpose(T.TRANSPOSE), 5),
    ("e06_o6", upright.transpose(T.ROTATE_90), 6),   # 存储横躺，摆正=竖
    ("e07_o7", upright.transpose(T.TRANSVERSE), 7),
    ("e08_o8", upright.transpose(T.ROTATE_270), 8),
    # 谎报：像素已摆正，tag 却说 6/8 —— 只要求不崩溃，方向以 tag 为准
    ("e09_lie_o6", upright, 6),
    ("e10_lie_o8", upright, 8),
    ("e11_o9_invalid", upright, 9),  # 非法 tag 值
]
for name, im_, ori in variants:
    fn = name + ".jpg"
    save_exif(im_, p(fn), ori)
    add(name, fn, "engine",
        expect="成片方向正确（orientation 摆正后与像素一致），不崩溃"
        if not name.startswith(("e09", "e10", "e11")) else "不崩溃（tag 谎报/非法值）",
        **ref)

# ================================================================ 序列用例素材
base.save(p("g01.jpg"), quality=92)
base_g02.save(p("g02.jpg"), quality=92)
add("g01", "g01.jpg", "engine", expect="基线人像")  # 基线 sanity
open(p("m02_text_as_jpg_copy.jpg"), "wb").write(open(p("m02_text_as_jpg.jpg"), "rb").read())

# ================================================================ manifest
manifest = {
    "upright_wh": upright.size,
    "cases": cases,
}
with open(p("manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=1)

# 序列用例清单（runner 里写死逻辑，这里只是给报告引用）
seq = ["q01_load_during_load", "q02_spec_during_matting", "q03_crop_during_load",
       "q04_rapid_spec7", "q05_extreme_crops", "q06_save_x20", "q07_corrupt_then_valid",
       "q08_valid_corrupt_recover", "q09_stress_30"]
print("fixtures:", len(os.listdir(FIX)), "engine cases:", len(cases), "seq:", len(seq))
print("upright size:", upright.size)
