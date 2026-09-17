# -*- coding: utf-8 -*-
"""列出最近会话标题。"""
import sys, io
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch

pw, ctx = launch(headless=False)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(5000)
titles = page.evaluate("""() => Array.from(document.querySelectorAll('a,div[title],span'))
    .map(e => e.textContent.trim()).filter(t => t && t.length < 30 && t.length > 2)""")
seen = []
for t in titles:
    if t not in seen:
        seen.append(t)
print(" | ".join(seen[:40]))
ctx.close()
pw.stop()
