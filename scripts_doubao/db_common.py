# -*- coding: utf-8 -*-
"""豆包自动化公共工具：复用 Edge 登录态启动浏览器。"""
from playwright.sync_api import sync_playwright

OUT = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos\out\tmp\doubao"
# Edge 新版禁止对默认 User Data 目录开 CDP，用复制的 profile 副本（含登录态）
EDGE_USER_DATA = OUT + r"\edge_profile"


def launch(headless=False):
    """返回 (pw, context)。调用方结束时要 pw.stop()。"""
    pw = sync_playwright().start()
    ctx = pw.chromium.launch_persistent_context(
        user_data_dir=EDGE_USER_DATA,
        channel="msedge",
        headless=headless,
        viewport={"width": 1440, "height": 900},
        args=["--profile-directory=Default", "--disable-blink-features=AutomationControlled"],
    )
    return pw, ctx
