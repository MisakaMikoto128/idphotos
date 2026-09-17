# -*- coding: utf-8 -*-
"""打开豆包登录窗口，等用户扫码登录。自动勾协议+自动刷新二维码，等12分钟。"""
import sys, io, time
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch, OUT

pw, ctx = launch(headless=False)
page = ctx.pages[0] if ctx.pages else ctx.new_page()
page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
page.wait_for_timeout(3000)
try:
    page.get_by_text("登录", exact=True).first.click(timeout=5000)
except Exception:
    pass
page.wait_for_timeout(2000)

# 勾选协议
try:
    page.locator("input[type=checkbox]").first.check(timeout=3000)
    print("agreement checked")
except Exception:
    try:
        page.get_by_text("已阅读并同意").first.click(timeout=3000)
        print("agreement clicked")
    except Exception as e:
        print("agreement tick skipped:", e)

def refresh_qr():
    try:
        page.get_by_text("点击刷新").first.click(timeout=3000)
        return True
    except Exception:
        return False

deadline = time.time() + 720
ok = False
last_shot = 0
while time.time() < deadline:
    time.sleep(5)
    if time.time() - last_shot > 60:
        page.screenshot(path=OUT + r"\login_window.png")
        last_shot = time.time()
    if refresh_qr():
        print("QR refreshed")
        time.sleep(3)
        continue
    try:
        body = page.evaluate("document.body.innerText.slice(0,400)")
        if "登录" not in body:
            ok = True
            break
    except Exception:
        pass
print("LOGGED IN" if ok else "LOGIN TIMEOUT")
page.screenshot(path=OUT + r"\login_result.png")
ctx.close()
pw.stop()
sys.exit(0 if ok else 3)
