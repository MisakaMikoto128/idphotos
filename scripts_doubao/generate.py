# -*- coding: utf-8 -*-
"""向豆包发图像生成提示词并下载结果。用法:
python generate.py <task_id>   # task_id: 1-4, 从 prompts.json 读
"""
import sys, io, time, json, os, re
sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
from db_common import launch, OUT

PROMPTS_FILE = os.path.join(os.path.dirname(__file__), "prompts.json")

def dismiss_dialog(page):
    """关掉可能挡路的弹窗。"""
    for _ in range(2):
        try:
            ov = page.locator('[data-slot="dialog-overlay"]')
            if ov.count() > 0:
                page.keyboard.press("Escape")
                page.wait_for_timeout(800)
        except Exception:
            break

def type_and_send(page, text):
    dismiss_dialog(page)
    box = page.locator('div[contenteditable="true"]').first
    box.scroll_into_view_if_needed()
    box.click()
    page.wait_for_timeout(800)
    page.keyboard.insert_text(text)
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
        if text[:12] in body or "正在生成" in body or "生成中" in body:
            break
    print("SENT:", text[:40], "...")
    page.wait_for_timeout(1500)
    dismiss_dialog(page)
    page.screenshot(path=f"{OUT}\\after_send_{task_id}.png")

def img_srcs(page):
    """返回生成图 [ (key, 最大宽度的完整URL) ]"""
    rows = page.evaluate("""() => Array.from(document.images)
        .filter(im => (im.src||'').includes('/rc_gen_image/'))
        .map(im => ({ src: im.src, w: im.naturalWidth }))""")
    best = {}
    for r in rows:
        k = r["src"].split("/rc_gen_image/")[1].split("~tplv")[0]
        if k not in best or r["w"] > best[k][0]:
            best[k] = (r["w"], r["src"])
    return [(k, v[1]) for k, v in best.items()]  # [(key, url)]

def wait_new_images(page, before, timeout=240):
    """轮询生成图出现：先等'正在生成'消失，再等图连续2轮稳定。"""
    seen = set(before)
    stable = {}
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            busy = page.evaluate(
                "document.body.innerText.includes('正在生成') || document.body.innerText.includes('生成中')")
        except Exception:
            busy = False
        if not busy:
            items = img_srcs(page)
            new = [(k, u) for k, u in items if k not in seen]
            for k, u in new:
                stable[k] = stable.get(k, 0) + 1
            if new and all(stable[k] >= 2 for k, u in new):
                return [u for k, u in new]
        time.sleep(4)
    return []

def download(ctx, url, path):
    # 保留完整签名 URL（~tplv 后缀含签名，剥掉会 403）
    if url.startswith("data:"):
        import base64
        with open(path, "wb") as f:
            f.write(base64.b64decode(url.split(",", 1)[1]))
        return True
    r = ctx.request.get(url, timeout=60000)
    if r.ok and len(r.body()) > 10000:
        with open(path, "wb") as f:
            f.write(r.body())
        return True
    print("DL FAIL", r.status, len(r.body() or b""), url[:90])
    return False

def main():
    global task_id
    task_id = sys.argv[1]
    cfg = json.load(open(PROMPTS_FILE, encoding="utf-8"))[task_id]
    pw, ctx = launch(headless=False)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto("https://www.doubao.com/chat/", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(6000)

    body = page.evaluate("document.body.innerText")
    if "登录" in body[:400]:
        page.screenshot(path=f"{OUT}\\nologin_{task_id}.png")
        print("NOT LOGGED IN - stop")
        ctx.close(); pw.stop(); sys.exit(2)

    before = img_srcs(page)
    type_and_send(page, cfg["prompt"])
    imgs = wait_new_images(page, before, timeout=int(cfg.get("timeout", 240)))
    print("NEW IMAGES:", len(imgs))
    page.screenshot(path=f"{OUT}\\result_{task_id}.png", full_page=True)

    saved = []
    for i, url in enumerate(imgs):
        p = f"{OUT}\\task{task_id}_gen{i+1}.jpg"
        if download(ctx, url, p):
            saved.append(p)
            print("SAVED:", os.path.basename(p))

    # 候选不足 2 张时补发一次"换个构图再来一张"
    if len(saved) < 2:
        print("few candidates, sending follow-up...")
        before2 = img_srcs(page)
        type_and_send(page, "再画一张同一角色的图，换个构图和姿势，保持人物设定不变")
        imgs2 = wait_new_images(page, before2)
        print("FOLLOW-UP IMAGES:", len(imgs2))
        for i, url in enumerate(imgs2):
            p = f"{OUT}\\task{task_id}_gen2_{i+1}.jpg"
            if download(ctx, url, p):
                saved.append(p)
                print("SAVED:", os.path.basename(p))
        page.screenshot(path=f"{OUT}\\result_{task_id}_b.png", full_page=True)

    json.dump(saved, open(f"{OUT}\\task{task_id}_saved.json", "w", encoding="utf-8"), ensure_ascii=False)
    print("TOTAL SAVED:", len(saved))
    ctx.close()
    pw.stop()

if __name__ == "__main__":
    main()
