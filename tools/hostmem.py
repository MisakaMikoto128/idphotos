# -*- coding: utf-8 -*-
"""宿主机内存预检（阶段 4 起每次启动模拟器前必跑）。

背景：开发机 commit 已用 40GB+/52.6GB 上限（G2C 期间 AVD 连崩的根因之一），
且用户明确要求监控——宿主内存本身已经很满。模拟器 4GB RAM + Gradle daemon
+ flutter tool 的组合随时可能把 commit 顶爆，爆了的表现是模拟器随机崩、
APK 损坏、进程被 OOM 杀。

用法：
    python tools/hostmem.py            # 打印状态，超限退出码 1
    python tools/hostmem.py --json     # 机读输出

判据：
    - 物理可用 < 4.0 GB      → 不许起模拟器
    - commit 已用/上限 > 80% → 不许起模拟器（先 gradlew --stop / 清 dart 进程）
"""
import json
import sys

import psutil


def main() -> int:
    vm = psutil.virtual_memory()
    swap = psutil.swap_memory()
    free_gb = vm.available / (1 << 30)
    commit_used_gb = (vm.total - vm.available + swap.used) / (1 << 30)
    commit_limit_gb = (vm.total + swap.total) / (1 << 30)
    commit_pct = commit_used_gb / commit_limit_gb * 100 if commit_limit_gb else 0.0

    report = {
        "freeRAMGB": round(free_gb, 2),
        "commitUsedGB": round(commit_used_gb, 1),
        "commitLimitGB": round(commit_limit_gb, 1),
        "commitPct": round(commit_pct, 1),
        "ok": free_gb >= 4.0 and commit_pct <= 80.0,
        "advice": "OK" if (free_gb >= 4.0 and commit_pct <= 80.0) else
        "先释放：cd android && ./gradlew --stop；杀残留 dart/qemu 进程；关不用的模拟器",
    }
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
