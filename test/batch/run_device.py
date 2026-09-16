# -*- coding: utf-8 -*-
"""qa-batch 阶段 4：host 侧编排脚本（只测量，不做 PASS/FAIL 判定）。v2

v2 变更（第 1 轮实测踩坑后修正）：
  - 模拟器参数改为逐个 argv 传参（v1 把 "-avd X" 揉进一个字符串导致 emu 秒退，
    随后 dev_serial 抓到第一台在线设备 —— 用户的真机 —— 险些把回归跑在真机上）。
  - 全程钉死 emulator-* serial，拒绝在任何非 emulator 设备上执行。
  - 输出目录改走 App 私有 cache（/data/local/tmp 对 untrusted_app 只读，SELinux
    拒写，即使 chmod 777），用 run-as tar 流拉回。

流程：
  1. 启动模拟器（PITFALLS 固化参数）并等待 boot（只认 emulator-* serial）
  2. 安装 batch_runner APK，push 数据集 staging 目录（输入只读 OK）
  3. batch 分 4 块跑（每块 20 项，块间 pull 中间结果）
  4. leak 模式（20 连跑，host 1s 采样 dumpsys meminfo）
  5. perf 模式（512x512 抠图 25 次采样）
  6. adb emu kill 释放设备

用法：
  .venv_ref/Scripts/python.exe test/batch/run_device.py
"""
import json
import os
import shutil
import subprocess
import sys
import tarfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
R = os.environ.get("QA_ROUND", "2")  # 输出文件轮次后缀，r1 数据不得被覆盖
DEV_IN = os.path.join(ROOT, "test", "batch", "device_in")
APK = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk", "app-debug.apk")
PKG = "com.muzhao.muzhao"
ACT = f"{PKG}/.MainActivity"
AVD = os.environ.get("QA_AVD", "Pixel_3a_API_34_extension_level_7_x86_64")
EMU_EXE = r"C:\Users\liuyu\AppData\Local\Android\Sdk\emulator\emulator.exe"
REMOTE_IN = "/data/local/tmp/muzhao_qa_tmp/in"
APP_OUT = "cache/qa_out"  # 相对 run-as 的 cwd（/data/user/0/<pkg>）

EMULATOR_ARGS = ["-avd", AVD, "-gpu", "guest", "-feature", "-Vulkan",
                 "-no-window", "-no-snapshot-load"]

SERIAL = None  # 钉死：只允许 emulator-*


def sh(cmd, timeout=120, check=False, binary=False):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout,
                       **({} if binary else {"text": True, "encoding": "utf-8",
                                             "errors": "replace"}))
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd} -> {r.returncode}\n{r.stdout!r}\n{r.stderr!r}")
    return r


def adb(*args, timeout=120, check=False, binary=False):
    # 钉死设备：任何命令都不允许落到非 emulator 设备上
    assert SERIAL is not None and SERIAL.startswith("emulator-"), \
        f"refuse to run on non-emulator device: {SERIAL!r}"
    return sh(["adb", "-s", SERIAL, *args], timeout=timeout, check=check,
              binary=binary)


def run_as(*args, timeout=120, check=False, binary=False):
    return adb("shell", "run-as", PKG, *args, timeout=timeout, check=check,
               binary=binary)


def wait_emulator_serial(deadline_s=60):
    """等 emulator-* 出现在 adb devices（不依赖 boot 完成）。"""
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        r = sh(["adb", "devices"], timeout=10)
        for line in r.stdout.splitlines()[1:]:
            p = line.split()
            if len(p) >= 2 and p[1] == "device" and p[0].startswith("emulator-"):
                return p[0]
        time.sleep(2)
    return None


def wait_boot(deadline_s=420):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        r = adb("shell", "getprop sys.boot_completed", timeout=10)
        if r.returncode == 0 and r.stdout.strip() == "1":
            return True
        time.sleep(3)
    return False


class MemSampler(threading.Thread):
    """每 interval 秒采一次进程 TOTAL PSS（KB），记录峰值。

    r2 新增：PSS 超 450MB 时保存完整 dumpsys meminfo 分类明细
    （out/memdump_r2/），供 4.7 峰值构成拆解（floor/解码/matting 增量）。
    """

    DUMP_THRESHOLD_KB = 450 * 1024
    DUMP_CAP = 400

    def __init__(self, interval=2.0):
        super().__init__(daemon=True)
        self.interval = interval
        self.samples = []  # (t_s, total_pss_kb or None)
        self.peak_kb = 0
        self.stop_flag = False
        self.dump_dir = os.path.join(OUT, f"memdump_r{R}")
        self.dump_n = 0

    def _dump_breakdown(self, t):
        if self.dump_n >= self.DUMP_CAP:
            return
        try:
            os.makedirs(self.dump_dir, exist_ok=True)
            r = adb("shell", f"dumpsys meminfo {PKG}", timeout=15)
            if r.returncode == 0:
                self.dump_n += 1
                with open(os.path.join(
                        self.dump_dir,
                        f"seq{self.dump_n:04d}_t{t:.0f}.txt"), "w",
                        encoding="utf-8", errors="replace") as f:
                    f.write(r.stdout)
        except Exception:
            pass

    def run(self):
        while not self.stop_flag:
            t = time.time()
            kb = None
            try:
                r = adb("shell", f"dumpsys meminfo {PKG}", timeout=15)
                if r.returncode == 0:
                    for line in r.stdout.splitlines():
                        s = line.strip()
                        # 形如 "TOTAL PSS:  123456   TOTAL RSS: ..."（取 PSS 列）
                        if s.startswith("TOTAL PSS"):
                            toks = s.split()
                            try:
                                kb = int(toks[toks.index("PSS:") + 1])
                            except (ValueError, IndexError):
                                pass
                            break
            except Exception:
                pass
            if kb:
                self.peak_kb = max(self.peak_kb, kb)
                if kb >= self.DUMP_THRESHOLD_KB:
                    self._dump_breakdown(t)
            self.samples.append((round(t, 1), kb))
            time.sleep(self.interval)

    def stop(self):
        self.stop_flag = True
        self.join(timeout=30)


def push_config(cfg):
    p = os.path.join(OUT, "tmp_qa_config.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f)
    adb("push", p, f"{REMOTE_IN}/qa_config.json", timeout=60)


def remote_marker(marker):
    r = run_as("ls", f"{APP_OUT}/{marker}", timeout=15)
    return r.returncode == 0 and r.stdout.strip() != ""


def launch_app():
    # 按 PITFALLS：直启必须 --ez enable-impeller false
    adb("shell", "am force-stop " + PKG, timeout=30)
    adb("logcat", "-c", timeout=30)
    run_as("mkdir", "-p", APP_OUT, timeout=15)
    r = adb("shell", f"am start -W --ez enable-impeller false -n {ACT}",
            timeout=120)
    return r


def clear_app_out():
    run_as("rm", "-rf", APP_OUT, timeout=15)


def pull_qa_out(dest_dir):
    """run-as tar 流拉回 App 私有输出目录。"""
    os.makedirs(dest_dir, exist_ok=True)
    r = adb("exec-out", "run-as", PKG, "tar", "-cf", "-", "-C", "cache", "qa_out",
            timeout=300, binary=True)
    tar_path = os.path.join(dest_dir, "_pull.tar")
    with open(tar_path, "wb") as f:
        f.write(r.stdout)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest_dir)
    os.remove(tar_path)


def read_errors():
    r = run_as("cat", f"{APP_OUT}/qa_errors.jsonl", timeout=30)
    return r.stdout.strip() if r.returncode == 0 else ""


def grab_logcat(name):
    lc = adb("logcat", "-d", timeout=60, binary=True)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(lc.stdout)


def main():
    os.makedirs(OUT, exist_ok=True)
    log = open(os.path.join(OUT, f"run_device_r{R}.log"), "a", encoding="utf-8")

    def P(msg):
        print(msg, flush=True)
        log.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        log.flush()

    global SERIAL

    # ---- 0. 前置检查：真机在线没关系，但绝不能被误用 ----
    # r2：清掉上一轮 tmp_pull，避免新旧 batch_items/artifacts 混在一起
    tp = os.path.join(OUT, "tmp_pull")
    if os.path.exists(tp):
        shutil.rmtree(tp)
        P("[0] 已清空 out/tmp_pull（防 r1/r2 数据混淆）")
    r = sh(["adb", "devices"], timeout=10)
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[1] == "device" and not p[0].startswith("emulator-"):
            P(f"[0] 警告：检测到非模拟器设备 {p[0]} 在线，全程将拒绝在其上执行")

    # ---- 1. 模拟器 ----
    P("[1] 启动模拟器 " + " ".join(EMULATOR_ARGS))
    emu_log = open(os.path.join(OUT, f"emu_qa_r{R}.log"), "w", encoding="utf-8")
    emu = subprocess.Popen([EMU_EXE] + EMULATOR_ARGS,
                           stdout=emu_log, stderr=subprocess.STDOUT,
                           creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    serial = wait_emulator_serial()
    if serial is None:
        P("FATAL: 模拟器进程未出现（见 out/emu_qa_r1.log）")
        return 2
    SERIAL = serial
    P(f"[1] emulator serial={SERIAL}，等待 boot ...")
    if not wait_boot():
        P("FATAL: 模拟器 boot 超时")
        return 2
    P(f"[1] boot 完成 ({time.time():.0f})")
    time.sleep(10)  # boot 后稳定期

    # ---- 2. 安装 + push ----
    P("[2] adb install")
    r = adb("install", "-r", APK, timeout=600)
    P("    install: " + r.stdout.strip().replace("\n", " | ")[:200])
    if "Success" not in r.stdout:
        P("FATAL: install 失败 " + (r.stderr or "")[:300])
        return 2
    # tar 打包 push 再解压：adb push 目录会落在 dest/<basename>/ 而不是 dest，
    # v2 就是这么把 manifest 推丢的（app 报 manifest.json 不存在）。
    tar_path = os.path.join(OUT, "device_in.tar")
    if not os.path.exists(tar_path):
        with tarfile.open(tar_path, "w") as tf:
            tf.add(DEV_IN, arcname="in")
    adb("shell", "rm -rf /data/local/tmp/muzhao_qa_tmp", timeout=60)
    adb("push", tar_path, "/data/local/tmp/device_in.tar", timeout=900)
    r = adb("shell",
            f"mkdir -p /data/local/tmp/muzhao_qa_tmp && "
            f"cd /data/local/tmp/muzhao_qa_tmp && tar -xf /data/local/tmp/device_in.tar && "
            f"ls {REMOTE_IN} | wc -l", timeout=120)
    P(f"[2] push 完成（输入 {REMOTE_IN}，条目数 {r.stdout.strip()}）")
    if r.stdout.strip() != "82":
        P("FATAL: push 条目数不为 82")
        return 2
    r = run_as("ls", "cache", timeout=15)

    sampler = MemSampler(interval=2.0)
    sampler.start()

    # ---- 3. batch 分块 ----
    manifest = json.load(open(os.path.join(DEV_IN, "manifest.json"),
                              encoding="utf-8"))
    n = len(manifest["items"])
    chunk = 20
    chunks = [(a, min(a + chunk - 1, n - 1)) for a in range(0, n, chunk)]
    for ci, (a, b) in enumerate(chunks):
        P(f"[3] batch 块 {ci}: [{a},{b}]")
        clear_app_out()
        push_config({"mode": "batch", "from": a, "to": b,
                     "out_dir": f"/data/user/0/{PKG}/{APP_OUT}",
                     # r2 观察点：item 60 红色电路板截图（诡异候选复核）
                     "artifacts": [60]})
        launch_app()
        # 轮询 marker
        t0 = time.time()
        ok = False
        while time.time() - t0 < 1800:
            if remote_marker("done_batch"):
                ok = True
                break
            time.sleep(5)
        P(f"    done_batch marker: {ok} ({time.time()-t0:.0f}s)")
        err = read_errors()
        if err:
            P(f"    qa_errors: {err[:500]}")
        pull_qa_out(os.path.join(OUT, f"pull_chunk{ci}"))
        grab_logcat(f"logcat_chunk{ci}_r{R}.txt")
        # 合并 batch_items.jsonl 到 tmp_pull（块间追加，去 begin 事件无妨）
        dst = os.path.join(OUT, "tmp_pull")
        os.makedirs(dst, exist_ok=True)
        src = os.path.join(OUT, f"pull_chunk{ci}", "qa_out", "batch_items.jsonl")
        if os.path.exists(src):
            with open(src, "r", encoding="utf-8") as fi, \
                 open(os.path.join(dst, "batch_items.jsonl"), "a",
                      encoding="utf-8") as fo:
                fo.write(fi.read())
        # 合并 artifacts
        sart = os.path.join(OUT, f"pull_chunk{ci}", "qa_out", "artifacts")
        dart = os.path.join(dst, "artifacts")
        if os.path.isdir(sart):
            os.makedirs(dart, exist_ok=True)
            for f2 in os.listdir(sart):
                if not os.path.exists(os.path.join(dart, f2)):
                    os.rename(os.path.join(sart, f2), os.path.join(dart, f2))

    # ---- 4. leak ----
    P("[4] leak 模式")
    sampler.stop()
    leak_sampler = MemSampler(interval=1.0)
    leak_sampler.start()
    clear_app_out()
    push_config({"mode": "leak",
                 "out_dir": f"/data/user/0/{PKG}/{APP_OUT}"})
    launch_app()
    t0 = time.time()
    ok = False
    while time.time() - t0 < 1800:
        if remote_marker("done_leak"):
            ok = True
            break
        time.sleep(3)
    P(f"    done_leak marker: {ok} ({time.time()-t0:.0f}s)")
    time.sleep(18)  # batch_runner 结束前留 15s 采"回落"读数
    leak_sampler.stop()
    with open(os.path.join(OUT, f"leak_r{R}_mem_curve.json"), "w") as f:
        json.dump({"interval_s": 1.0, "peak_kb": leak_sampler.peak_kb,
                   "samples": leak_sampler.samples}, f)
    pull_qa_out(os.path.join(OUT, "pull_leak"))
    # leak 逐轮耗时（供 merge_results.py 的 G4.8 基线/回落判定）
    src_leak = os.path.join(OUT, "pull_leak", "qa_out", "leak_items.jsonl")
    if os.path.exists(src_leak):
        shutil.copyfile(src_leak, os.path.join(OUT, f"leak_r{R}_raw.jsonl"))
    grab_logcat(f"logcat_leak_r{R}.txt")

    # ---- 5. perf ----
    P("[5] perf 模式")
    clear_app_out()
    push_config({"mode": "perf", "perf_n": 25,
                 "out_dir": f"/data/user/0/{PKG}/{APP_OUT}"})
    launch_app()
    t0 = time.time()
    ok = False
    while time.time() - t0 < 900:
        if remote_marker("done_perf"):
            ok = True
            break
        time.sleep(3)
    P(f"    done_perf marker: {ok} ({time.time()-t0:.0f}s)")
    pull_qa_out(os.path.join(OUT, "pull_perf"))
    src_perf = os.path.join(OUT, "pull_perf", "qa_out", "perf_ms.json")
    if os.path.exists(src_perf):
        shutil.copyfile(src_perf, os.path.join(OUT, f"perf_r{R}_raw.json"))
    grab_logcat(f"logcat_perf_r{R}.txt")

    # ---- 收尾 ----
    with open(os.path.join(OUT, f"mem_r{R}.json"), "w") as f:
        json.dump({"interval_s": 2.0, "peak_kb": sampler.peak_kb,
                   "samples": sampler.samples}, f)
    P("[6] 释放设备 adb emu kill")
    adb("emu", "kill", timeout=30)
    time.sleep(5)
    emu.terminate()
    emu_log.close()
    P("DONE")
    log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
