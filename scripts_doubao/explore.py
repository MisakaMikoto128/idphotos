# -*- coding: utf-8 -*-
"""探查豆包网页：登录态、输入框、发送按钮 DOM。"""
import sys, io
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch, OUT

pw, ctx = launch(headless=False)
page = ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(8000)
print("URL:", page.url)
print("TITLE:", page.title())
page.screenshot(path=OUT + r"\explore_1.png")

# 找输入框
for sel in ["textarea", "[contenteditable=true]", "[data-testid*='input']", "input[type=text]"]:
    els = page.query_selector_all(sel)
    for e in els[:3]:
        try:
            ph = e.get_attribute("placeholder") or e.get_attribute("data-placeholder")
            box = e.bounding_box()
            print(f"SEL={sel} tag={e.evaluate('el=>el.tagName')} placeholder={ph!r} box={box}")
        except Exception as ex:
            print("ERR", sel, ex)

# 可能的登录提示
body_text = page.evaluate("document.body.innerText.slice(0,600)")
print("BODY:", body_text[:600].replace("\n", " | "))

# 找发送按钮
for sel in ["[data-testid*='send']", "button:has(svg)", "[class*='send']"]:
    els = page.query_selector_all(sel)
    print(f"{sel}: {len(els)} hits")

page.screenshot(path=OUT + r"\explore_2.png")
ctx.close()
pw.stop()
