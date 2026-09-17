# -*- coding: utf-8 -*-
"""从指定会话收割全部生成图 (img[src*=rc_gen_image])。用法:
python harvest.py <会话标题关键词> <输出前缀>
"""
import sys, io, time, os
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch, OUT

def gen_urls(page):
    srcs = page.evaluate(
        """() => Array.from(document.images)
             .filter(im => (im.src||'').includes('/rc_gen_image/'))
             .sort((a,b) => b.naturalWidth - a.naturalWidth)
             .map(im => im.src)""")
    seen, out = set(), []
    for s in srcs:
        key = s.split("/rc_gen_image/")[1].split("~tplv")[0]
        if key not in seen:
            seen.add(key)
            out.append(s)  # 保留完整签名 URL，签名不能剥
    return out

def download(ctx, url, path):
    r = ctx.request.get(url, timeout=60000)
    if r.ok and len(r.body()) > 10000:
        with open(path, "wb") as f:
            f.write(r.body())
        return True
    print("DL FAIL", r.status, len(r.body() or b""), url[:90])
    return False

def harvest(page, ctx, keyword, prefix):
    page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(5000)
    page.get_by_text(keyword).first.click(timeout=8000)
    page.wait_for_timeout(6000)
    page.keyboard.press("End")
    page.wait_for_timeout(4000)
    urls = gen_urls(page)
    print("FOUND", len(urls), "generated images")
    saved = []
    for i, u in enumerate(urls):
        p = os.path.join(OUT, f"{prefix}_h{i+1}.jpg")
        if download(ctx, u, p):
            saved.append(p)
            print("SAVED:", os.path.basename(p))
    page.screenshot(path=os.path.join(OUT, f"{prefix}_harvest.png"), full_page=True)
    return saved

if __name__ == "__main__":
    keyword, prefix = sys.argv[1], sys.argv[2]
    pw, ctx = launch(headless=False)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    body = page.evaluate("document.body.innerText") if False else None
    saved = harvest(page, ctx, keyword, prefix)
    print("TOTAL:", len(saved))
    ctx.close()
    pw.stop()
