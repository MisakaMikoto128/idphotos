# -*- coding: utf-8 -*-
"""native/bench/ml_release_memcheck.py — ml-porting 自用的 4.7/4.8 复测编排。

规程与 tools/gate/g4_release_memcheck.py（gatekeeper 所有）一致，仅供
ml-porting 修改后的自测；判定量仍以 gatekeeper 复测为准。差异：
  - APK 用本 agent 刚构建的 build/app/outputs/flutter-apk/app-release.apk
  - 输出写 out/ml_mem_*，不碰 gate schema 文件
钉死 emulator-*，非模拟器设备一律不碰。用毕 adb emu kill。
"""
import json
import os
import statistics
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
APK = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk",
                   "app-release.apk")
PKG = "com.muzhao.muzhao"
ACT = f"{PKG}/.MainActivity"
AVD = "Pixel_3a_API_34_extension_level_7_x86_64"
EMU_EXE = r"C:\Users\liuyu\AppData\Local\Android\Sdk\emulator\emulator.exe"
BAKE_IN = "/data/local/tmp/muzhao_qa_tmp/in"
PKG_HOME = f"/data/user/0/{PKG}"
APP_OUT = "cache/qa_out"
EMULATOR_ARGS = ["-avd", AVD, "-gpu", "guest", "-feature", "-Vulkan",
                 "-no-window", "-no-snapshot-load"]

SERIAL = None


def P(msg):
    print(msg, flush=True)


def sh(cmd, timeout=120, check=False, binary=False):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout,
                       **({} if binary else {"text": True, "encoding": "utf-8",
                                             "errors": "replace"}))
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd} -> {r.returncode}\n{r.stdout!r}\n{r.stderr!r}")
    return r


def adb(*args, timeout=120, check=False, binary=False):
    assert SERIAL is not None and SERIAL.startswith("emulator-"), \
        f"refuse non-emulator device: {SERIAL!r}"
    return sh(["adb", "-s", SERIAL, *args], timeout=timeout, check=check,
              binary=binary)


def wait_emulator_serial(deadline_s=90):
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


def total_pss_kb():
    r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        s = line.strip()
        if s.startswith("TOTAL PSS"):
            toks = s.split()
            try:
                return int(toks[toks.index("PSS:") + 1])
            except (ValueError, IndexError):
                pass
    return None


def dump_breakdown(tag):
    r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
    if r.returncode == 0:
        with open(os.path.join(OUT, f"ml_mem_{tag}.txt"), "w",
                  encoding="utf-8", errors="replace") as f:
            f.write(r.stdout)


def read_marker(name):
    r = adb("shell", "cat", f"{PKG_HOME}/{APP_OUT}/{name}", timeout=15)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        return time.time()
    return None


def push_config(cfg):
    p = os.path.join(OUT, "ml_mem_qa_config.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f)
    adb("push", p, f"{BAKE_IN}/qa_config.json", timeout=60)


def launch_app():
    adb("shell", "am force-stop " + PKG, timeout=30)
    uid = adb("shell",
              f"stat -c '%U:%G' {PKG_HOME}/cache", timeout=15).stdout.strip()
    adb("shell", f"rm -rf {PKG_HOME}/{APP_OUT}", timeout=15)
    adb("shell", f"mkdir -p {PKG_HOME}/{APP_OUT}", timeout=15)
    if uid:
        adb("shell", f"chown -R {uid} {PKG_HOME}/{APP_OUT}", timeout=15)
    return adb("shell", f"am start -W --ez enable-impeller false -n {ACT}",
               timeout=120)


def wait_marker(name, deadline_s):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        if read_marker(name) is not None:
            return time.time()
        time.sleep(2)
    return None


def pull_qa_out(dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    r = adb("exec-out", f"tar -cf - -C {PKG_HOME}/cache qa_out",
            timeout=300, binary=True)
    with open(os.path.join(dest_dir, "_pull.tar"), "wb") as f:
        f.write(r.stdout)
    subprocess.run(["python", "-c",
                    "import tarfile,sys; tarfile.open(sys.argv[1])"
                    ".extractall(sys.argv[2])",
                    os.path.join(dest_dir, "_pull.tar"), dest_dir], check=True)
    os.remove(os.path.join(dest_dir, "_pull.tar"))


class Sampler(threading.Thread):
    DUMP_THRESHOLD_KB = 450 * 1024
    DUMP_CAP = 120

    def __init__(self, phase):
        super().__init__(daemon=True)
        self.phase = phase
        self.samples = []
        self.peak_kb = 0
        self.stop_flag = False
        self.dump_n = 0

    def run(self):
        while not self.stop_flag:
            kb = total_pss_kb()
            t = time.time()
            if kb:
                self.peak_kb = max(self.peak_kb, kb)
                self.samples.append((round(t, 1), kb))
                if kb >= self.DUMP_THRESHOLD_KB and self.dump_n < self.DUMP_CAP:
                    self.dump_n += 1
                    try:
                        dump_breakdown(f"{self.phase}{self.dump_n:04d}")
                    except Exception:
                        pass
            time.sleep(1.0)

    def stop(self):
        self.stop_flag = True
        self.join(timeout=30)

    def window_median_mb(self, t0, t1):
        xs = [kb / 1024.0 for (t, kb) in self.samples if t0 <= t <= t1]
        return round(statistics.median(xs), 1) if xs else None


def p95(values):
    if not values:
        return None
    xs = sorted(values)
    return xs[max(0, min(len(xs) - 1, int(0.95 * len(xs) + 0.999999) - 1))]


def main():
    global SERIAL
    only = sys.argv[1] if len(sys.argv) > 1 else "all"
    r = sh(["adb", "devices"], timeout=10)
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[1] == "device" and not p[0].startswith("emulator-"):
            P(f"[0] 警告：非模拟器设备 {p[0]} 在线，全程拒绝在其上执行")

    SERIAL = wait_emulator_serial(5)
    launched = False
    if SERIAL is None:
        P("[1] 启动模拟器 " + " ".join(EMULATOR_ARGS))
        emu_log = open(os.path.join(OUT, "ml_mem_emu.log"), "w",
                       encoding="utf-8")
        subprocess.Popen([EMU_EXE] + EMULATOR_ARGS, stdout=emu_log,
                         stderr=subprocess.STDOUT,
                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
        SERIAL = wait_emulator_serial()
        if SERIAL is None:
            P("FATAL: 模拟器未出现")
            return 2
        launched = True
    P(f"[1] serial={SERIAL}，等 boot ...")
    if not wait_boot():
        P("FATAL: boot 超时")
        return 2
    time.sleep(10)

    res = {}
    try:
        P("[2] adb root")
        r = adb("root", timeout=30)
        P("    " + (r.stdout or r.stderr).strip()[:120])
        time.sleep(3)

        P("[2] install release runner (本 agent 构建)")
        r = adb("install", "-r", APK, timeout=900)
        P("    " + r.stdout.strip().replace("\n", " | ")[:200])
        if "Success" not in r.stdout:
            P("FATAL: install 失败")
            return 2

        tar_path = os.path.join(OUT, "device_in.tar")
        adb("shell", "rm -rf /data/local/tmp/muzhao_qa_tmp", timeout=60)
        adb("push", tar_path, "/data/local/tmp/device_in_ml.tar", timeout=900)
        r = adb("shell",
                f"mkdir -p /data/local/tmp/muzhao_qa_tmp && "
                f"cd /data/local/tmp/muzhao_qa_tmp && "
                f"tar -xf /data/local/tmp/device_in_ml.tar && "
                f"ls {BAKE_IN} | wc -l", timeout=180)
        P(f"[2] push 条目数 {r.stdout.strip()}")
        if r.stdout.strip() != "82":
            P("FATAL: push 条目数不为 82")
            return 2

        if only in ("all", "batch"):
            P("[3] batch 全量 80 项（4.7 峰值）")
            s = Sampler("rel")
            s.start()
            t0 = time.time()
            push_config({"mode": "batch", "from": 0, "to": 79,
                         "out_dir": f"{PKG_HOME}/{APP_OUT}"})
            launch_app()
            if not wait_marker("done_batch", 3600):
                P("FATAL: batch 未完成")
                s.stop()
                return 2
            time.sleep(5)
            s.stop()
            json.dump(s.samples, open(
                os.path.join(OUT, "ml_mem_batch_curve.json"), "w"))
            pull_qa_out(os.path.join(OUT, "ml_pull_batch_rel"))
            res["batchPhase"] = {
                "wall_s": round(time.time() - t0, 1),
                "peak_mb": round(s.peak_kb / 1024.0, 1),
                "n_samples": len(s.samples),
            }
            P(f"    batch 峰值 {res['batchPhase']['peak_mb']}MB")

        if only in ("all", "leak"):
            P("[4] leak 20 轮（4.8）")
            s = Sampler("leak")
            s.start()
            push_config({"mode": "leak",
                         "out_dir": f"{PKG_HOME}/{APP_OUT}"})
            launch_app()
            b_obs = wait_marker("leak_begin", 2400)
            e_obs = wait_marker("leak_end", 2400)
            if e_obs is None:
                P("FATAL: leak 未完成")
                s.stop()
                return 2
            time.sleep(5)
            s.stop()
            json.dump(s.samples, open(
                os.path.join(OUT, "ml_mem_leak_curve.json"), "w"))
            baseline = s.window_median_mb(b_obs - 6, b_obs) if b_obs else None
            after = s.window_median_mb(e_obs, e_obs + 14) if e_obs else None
            res["leakPhase"] = {
                "baseline_mb": baseline, "after20_mb": after,
                "delta_mb": round(after - baseline, 1)
                if baseline is not None and after is not None else None,
                "peak_during_mb": round(s.peak_kb / 1024.0, 1),
            }
            P(f"    leak baseline={baseline} after20={after} "
              f"delta={res['leakPhase']['delta_mb']}")

        if only in ("all", "perf"):
            P("[5] perf 25 次（4.6）")
            push_config({"mode": "perf", "perf_n": 25,
                         "out_dir": f"{PKG_HOME}/{APP_OUT}"})
            launch_app()
            if not wait_marker("done_perf", 1200):
                P("FATAL: perf 未完成")
                return 2
            pull_qa_out(os.path.join(OUT, "ml_pull_perf_rel"))
            pj = os.path.join(OUT, "ml_pull_perf_rel", "qa_out", "perf_ms.json")
            if os.path.exists(pj):
                ms = json.load(open(pj, encoding="utf-8"))["ms"]
                res["perfPhase"] = {"n": len(ms), "p95_ms": p95(ms),
                                    "p50_ms": sorted(ms)[len(ms) // 2]}
                P(f"    perf p95={res['perfPhase']['p95_ms']}ms "
                  f"p50={res['perfPhase']['p50_ms']}ms (n={len(ms)})")

        json.dump(res, open(os.path.join(OUT, "ml_mem_results.json"), "w"),
                  indent=1)
        P("[6] out/ml_mem_results.json 已写出")
        return 0
    finally:
        if launched:
            adb("emu", "kill", timeout=30)
            time.sleep(5)
            P("[7] adb emu kill 已执行")


if __name__ == "__main__":
    sys.exit(main())
