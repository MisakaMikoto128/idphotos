# -*- coding: utf-8 -*-
"""用真 Edge 进程(手动拉起,带调试端口) + connect_over_cdp 测试登录态。"""
import subprocess, time, sys, io
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from playwright.sync_api import sync_playwright

OUT = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\tmp\doubao"
PROFILE = OUT + r"\edge_profile"
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

proc = subprocess.Popen([EDGE, "--user-data-dir=" + PROFILE,
                         "--profile-directory=Default",
                         "--remote-debugging-port=9222",
                         "--no-first-run", "--no-default-browser-check",
                         "about:blank"])
time.sleep(6)

pw = sync_playwright().start()
try:
    browser = pw.chromium.connect_over_cdp("http://127.0.0.1:9222", timeout=20000)
    ctx = browser.contexts[0]
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(8000)
    body = page.evaluate("document.body.innerText.slice(0,300)")
    print("BODY:", body.replace("\n", " | "))
    page.screenshot(path=OUT + r"\cdp_login_check.png")
finally:
    pw.stop()
    proc.terminate()
