# -*- coding: utf-8 -*-
"""任务3补救：直接导航到豆包，填提示词3并发送，等出图下载。"""
import sys, io, time, os, json
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
sys.path.insert(0, os.path.dirname(__file__))
from db_common import launch, OUT
from generate import img_srcs, wait_new_images, download

PROMPTS_FILE = os.path.join(os.path.dirname(__file__), "prompts.json")

pw, ctx = launch(headless=False)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(6000)

box = page.locator('div[contenteditable="true"]').first
box.scroll_into_view_if_needed()
box.click()
page.wait_for_timeout(800)

txt = box.inner_text()
prompt = json.load(open(PROMPTS_FILE, encoding="utf-8"))["3"]["prompt"]
if len(txt) < 10:
    page.keyboard.insert_text(prompt)
    page.wait_for_timeout(800)
    txt = box.inner_text()
print("INPUT HAS:", txt[:50])

# 在元素内发送（焦点确保在输入框）
for attempt in range(3):
    box.press("Enter")
    page.wait_for_timeout(3000)
    body = page.evaluate("document.body.innerText")
    if "创建项目" in body:
        page.keyboard.press("Escape")
        page.wait_for_timeout(1000)
        box.click(); page.wait_for_timeout(500)
        continue
    if prompt[:12] in body or "正在生成" in body or "生成中" in body:
        print("SENT ok on attempt", attempt + 1)
        break
else:
    print("SEND FAILED")
    page.screenshot(path=OUT + r"\recover_3_fail.png")
    ctx.close(); pw.stop(); sys.exit(4)

before = [k for k, u in img_srcs(page)]
imgs = wait_new_images(page, before, timeout=300)
print("NEW IMAGES:", len(imgs))
saved = []
for i, url in enumerate(imgs):
    p = f"{OUT}\\task3_gen{i+1}.jpg"
    if download(ctx, url, p):
        saved.append(p)
        print("SAVED:", os.path.basename(p))
page.screenshot(path=OUT + r"\recover_3_done.png", full_page=True)
print("TOTAL:", len(saved))
ctx.close()
pw.stop()
