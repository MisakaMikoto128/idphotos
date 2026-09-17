# -*- coding: utf-8 -*-
"""任务5：与证件照同角色的生活照。发提示词→等图→下载 task5_h*.jpg"""
import sys, io, time, os
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
sys.path.insert(0, os.path.dirname(__file__))
from db_common import launch, OUT
from generate import img_srcs, wait_new_images, download, dismiss_dialog

PROMPT = ("日本动漫风格少女，深棕色双丸子头，暖肤色，深绿色立领外套配米白色高领内搭，"
          "温馨室内窗光场景，正面微微侧身微笑，生活感构图，柔和光影，高质量动漫插画")

pw, ctx = launch(headless=False)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(6000)

dismiss_dialog(page)
box = page.locator('div[contenteditable="true"]').first
box.scroll_into_view_if_needed()
box.click()
page.wait_for_timeout(800)
page.keyboard.insert_text(PROMPT)
page.wait_for_timeout(800)

for attempt in range(3):
    box.press("Enter")
    page.wait_for_timeout(3000)
    body = page.evaluate("document.body.innerText")
    if "创建项目" in body:
        page.keyboard.press("Escape")
        page.wait_for_timeout(1000)
        box.click(); page.wait_for_timeout(500)
        continue
    if PROMPT[:12] in body or "正在生成" in body or "生成中" in body:
        print("SENT ok on attempt", attempt + 1)
        break
else:
    print("SEND FAILED")
    page.screenshot(path=OUT + r"\task5_fail.png")
    ctx.close(); pw.stop(); sys.exit(4)

before = [k for k, u in img_srcs(page)]
imgs = wait_new_images(page, before, timeout=300)
print("NEW IMAGES:", len(imgs))
saved = []
for i, url in enumerate(imgs):
    p = f"{OUT}\\task5_h{i+1}.jpg"
    if download(ctx, url, p):
        saved.append(p)
        print("SAVED:", os.path.basename(p))
page.screenshot(path=OUT + r"\task5_done.png", full_page=True)
print("TOTAL:", len(saved))
ctx.close()
pw.stop()
