# -*- coding: utf-8 -*-
"""qa-batch 阶段 4：对比网格图（人看的，也是 visual-critic 输入）。

每行：原图缩略 + alpha mask + 6 个底色结果（white/blue/red/deep_blue/gray/blue_gradient）。
素材来自设备端拉回的 out/tmp_pull/artifacts/a<i>_<style>.jpg 与 a<i>_alpha.png。

输出：
  out/grid_r1_portrait.png   全部 portrait+multi_face 行
  out/grid_r1_extra.png      非 6 候选但值得目检的行（weird/失败的，若有）
"""
import json
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
ART = os.path.join(OUT, "tmp_pull", "artifacts")
STYLES = ["white", "blue", "red", "deep_blue", "gray", "blue_gradient"]
TH = 150          # 单元格缩略边
LABEL_H = 18

R = sys.argv[1] if len(sys.argv) > 1 else "1"  # 轮次后缀


def cell(img_or_none, label):
    c = Image.new("RGB", (TH, TH + LABEL_H), (40, 40, 40))
    d = ImageDraw.Draw(c)
    if img_or_none is not None:
        im = img_or_none.convert("RGB")
        im.thumbnail((TH, TH))
        c.paste(im, ((TH - im.width) // 2, (TH - im.height) // 2))
    else:
        d.text((4, TH // 2), "MISSING", fill=(255, 80, 80))
    d.text((3, TH + 2), label[:24], fill=(230, 230, 230))
    return c


def row_for(item, i):
    src = Image.open(item["path"])
    cells = [cell(src, os.path.basename(item["path"])[:22])]
    alpha_path = os.path.join(ART, f"a{i}_alpha.png")
    am = Image.open(alpha_path) if os.path.exists(alpha_path) else None
    if am is not None:
        fg = "fg?"
    cells.append(cell(am, "alpha"))
    for st in STYLES:
        p = os.path.join(ART, f"a{i}_{st}.jpg")
        im = Image.open(p) if os.path.exists(p) else None
        cells.append(cell(im, st))
    return cells


def build_grid(items, out_name, title):
    rows = []
    for it, i in items:
        try:
            rows.append(row_for(it, i))
        except Exception as e:
            print(f"[WARN] row {i} ({it['path']}): {e}")
    if not rows:
        print(f"[grid] {out_name}: 无行，跳过")
        return
    ncell = len(rows[0])
    W = ncell * (TH + 2) + 2
    H = len(rows) * (TH + LABEL_H + 2) + 2 + 20
    g = Image.new("RGB", (W, H), (15, 15, 15))
    d = ImageDraw.Draw(g)
    d.text((4, 3), title, fill=(255, 255, 120))
    y = 22
    for r in rows:
        x = 2
        for c in r:
            g.paste(c, (x, y))
            x += TH + 2
        y += TH + LABEL_H + 2
    g.save(os.path.join(OUT, out_name))
    print(f"[grid] {out_name}: {len(rows)} 行 x {ncell} 列")


def main():
    manifest = json.load(open(os.path.join(ROOT, "test", "batch",
                                           "device_in", "manifest.json"),
                              encoding="utf-8"))
    items = {m["i"]: m for m in manifest["items"]}
    # 找出设备端实际产出了 artifact 的条目
    have = set()
    for f in os.listdir(ART):
        if f.endswith("_alpha.png"):
            have.add(int(f[1:].split("_")[0]))
    portrait = [(items[i], i) for i in sorted(have)
                if items[i]["class"] in ("portrait", "multi_face")]
    others = [(items[i], i) for i in sorted(have)
              if items[i]["class"] not in ("portrait", "multi_face")]
    build_grid(portrait, f"grid_r{R}_portrait.png",
               f"MuZhao G4 r{R}: portrait/multi_face rows (src | alpha | 6 bg)")
    if others:
        build_grid(others, f"grid_r{R}_extra.png",
                   f"MuZhao G4 r{R}: non-portrait rows that produced candidates")
    # r2 观察点：win11/21 横图（36/37）、multi_face 选脸（4/14）、电路板（60）
    watch = [i for i in (4, 14, 36, 37, 60) if i in items and i in have]
    if watch:
        build_grid([(items[i], i) for i in watch], f"grid_r{R}_watchpoints.png",
                   f"MuZhao G4 r{R}: watchpoints 4/14/36/37/60 "
                   f"(src | alpha | 6 bg)")


if __name__ == "__main__":
    main()
