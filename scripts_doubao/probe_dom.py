# -*- coding: utf-8 -*-
"""探查会话里生成图的 DOM 特征。"""
import sys, io, json, time
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch, OUT

pw, ctx = launch(headless=False)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(5000)

# 点开最近的"木木动漫立绘"会话
try:
    page.get_by_text("木木动漫立绘").first.click(timeout=5000)
    page.wait_for_timeout(6000)
    print("opened conversation")
except Exception as e:
    print("open conv fail:", e)

# 滚到底
page.keyboard.press("End")
page.wait_for_timeout(3000)

info = page.evaluate("""() => Array.from(document.images).map(im => ({
  src: im.src.slice(0, 120),
  w: im.naturalWidth, h: im.naturalHeight,
  rw: im.width, rh: im.height,
  cls: (im.className||'').slice(0,80),
  alt: (im.alt||'').slice(0,40),
  parentCls: ((im.parentElement && im.parentElement.className)||'').slice(0,80),
}))""")
print(json.dumps(info, ensure_ascii=False, indent=1))

# 也找 background-image 元素
bg = page.evaluate("""() => Array.from(document.querySelectorAll('*'))
  .filter(e => { const s = getComputedStyle(e).backgroundImage;
                 return s && s.includes('url(') && s.length > 30; })
  .slice(0, 20).map(e => ({
    tag: e.tagName, cls: (e.className||'').toString().slice(0,60),
    bg: getComputedStyle(e).backgroundImage.slice(0,120),
    rect: (() => { const r = e.getBoundingClientRect(); return [r.width|0, r.height|0]; })(),
  }))""")
print("BG IMAGES:", json.dumps(bg, ensure_ascii=False, indent=1))

page.screenshot(path=OUT + r"\probe_conv.png", full_page=True)
ctx.close()
pw.stop()
