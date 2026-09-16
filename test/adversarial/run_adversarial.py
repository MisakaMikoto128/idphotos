# -*- coding: utf-8 -*-
"""adversarial G4.4：host 侧编排（只测量，不做 PASS/FAIL 判定）。

流程：
  1. 启动模拟器（PITFALLS 固化参数，钉死 emulator-* serial）
  2. 安装 adversarial_runner APK，push fixtures
  3. 分 4 块跑（块间 force-stop 重启，单块崩溃不拖垮全局），块间拉中间结果
  4. stress 块 1s 采样 dumpsys meminfo
  5. 汇总 out/ADVERSARIAL_r1.json（含成片 JPEG 回读验证）
  6. adb emu kill 释放设备

用法： .venv_ref/Scripts/python.exe test/adversarial/run_adversarial.py
"""
import json
import os
import shutil
import subprocess
import sys
import tarfile
import threading
import time

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
FIX = os.path.join(ROOT, "test", "adversarial", "fixtures")
APK = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk", "app-debug.apk")
PKG = "com.muzhao.muzhao"
ACT = f"{PKG}/.MainActivity"
AVD = "Pixel_3a_API_34_extension_level_7_x86_64"
EMU_EXE = r"C:\Users\liuyu\AppData\Local\Android\Sdk\emulator\emulator.exe"
REMOTE_IN = "/data/local/tmp/muzhao_adv_tmp/in"
APP_OUT = "cache/adv_out"

EMULATOR_ARGS = ["-avd", AVD, "-gpu", "guest", "-feature", "-Vulkan",
                 "-no-window", "-no-snapshot-load"]
SERIAL = None

# 块定义：畸形（风险最高，单独一块）/ 尺寸 / 内容+EXIF / 序列（含内存采样）
CHUNKS = [
    ("malformed", [f"m{i:02d}" for i in range(1, 17)], 900, False),
    ("sizes", [f"s{i:02d}" for i in range(1, 12)], 900, False),
    ("content_exif", [f"c{i:02d}" for i in range(1, 12)] + ["g01"]
     + ["e01_o1", "e02_o2", "e03_o3", "e04_o4", "e05_o5", "e06_o6",
        "e07_o7", "e08_o8", "e09_lie_o6", "e10_lie_o8", "e11_o9_invalid"],
     2400, True),
    ("sequences", ["q01_load_during_load", "q02_spec_during_matting",
                   "q03_crop_during_load", "q04_rapid_spec7", "q05_extreme_crops",
                   "q06_save_x20", "q07_corrupt_then_valid",
                   "q08_valid_corrupt_recover", "q09_stress_30"], 3600, True),
]


def sh(cmd, timeout=120, check=False, binary=False):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout,
                       **({} if binary else {"text": True, "encoding": "utf-8",
                                             "errors": "replace"}))
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd} -> {r.returncode}\n{r.stdout!r}\n{r.stderr!r}")
    return r


def adb(*args, timeout=120, check=False, binary=False):
    assert SERIAL is not None and SERIAL.startswith("emulator-"), \
        f"refuse to run on non-emulator device: {SERIAL!r}"
    return sh(["adb", "-s", SERIAL, *args], timeout=timeout, check=check, binary=binary)


def run_as(*args, timeout=120, check=False, binary=False):
    return adb("shell", "run-as", PKG, *args, timeout=timeout, check=check, binary=binary)


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


class MemSampler(threading.Thread):
    def __init__(self, interval=1.0):
        super().__init__(daemon=True)
        self.interval = interval
        self.samples = []
        self.peak_kb = 0
        self.stop_flag = False

    def run(self):
        while not self.stop_flag:
            try:
                r = adb("shell", f"dumpsys meminfo {PKG}", timeout=15)
                if r.returncode == 0:
                    for line in r.stdout.splitlines():
                        s = line.strip()
                        if s.startswith("TOTAL PSS"):
                            toks = s.split()
                            try:
                                kb = int(toks[toks.index("PSS:") + 1])
                                self.peak_kb = max(self.peak_kb, kb)
                                self.samples.append((round(time.time(), 1), kb))
                            except (ValueError, IndexError):
                                pass
                            break
            except Exception:
                pass
            time.sleep(self.interval)

    def stop(self):
        self.stop_flag = True
        self.join(timeout=30)


def remote_marker(marker):
    r = run_as("ls", f"{APP_OUT}/{marker}", timeout=15)
    return r.returncode == 0 and r.stdout.strip() != ""


def launch_app():
    adb("shell", "am force-stop " + PKG, timeout=30)
    adb("logcat", "-c", timeout=30)
    run_as("mkdir", "-p", APP_OUT, timeout=15)
    return adb("shell", f"am start -W --ez enable-impeller false -n {ACT}", timeout=120)


def clear_app_out():
    run_as("rm", "-rf", APP_OUT, timeout=15)


def pull_adv_out(dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    r = adb("exec-out", "run-as", PKG, "tar", "-cf", "-", "-C", "cache", "adv_out",
            timeout=600, binary=True)
    tar_path = os.path.join(dest_dir, "_pull.tar")
    with open(tar_path, "wb") as f:
        f.write(r.stdout)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest_dir)
    os.remove(tar_path)


def grab_logcat(name):
    lc = adb("logcat", "-d", timeout=60, binary=True)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(lc.stdout)


def begun_without_end():
    """归因：哪些 begin_ marker 没有对应的 end_。"""
    r = run_as("ls", APP_OUT, timeout=15)
    names = set(r.stdout.split())
    return sorted(n[6:] for n in names
                  if n.startswith("begin_") and ("end_" + n[6:]) not in names)


def main():
    os.makedirs(OUT, exist_ok=True)
    # argv[1] = 只跑这些块（逗号分隔，如 "sequences"）；ADV_OUT_JSON = 输出 json 文件名
    only = sys.argv[1].split(",") if len(sys.argv) > 1 else None
    out_json = os.environ.get("ADV_OUT_JSON", "ADVERSARIAL_r1.json")
    chunks = CHUNKS if only is None else [c for c in CHUNKS if c[0] in only]
    log = open(os.path.join(OUT, out_json.replace(".json", "_run.log")),
               "a", encoding="utf-8")

    def P(msg):
        print(msg, flush=True)
        log.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        log.flush()

    global SERIAL
    tp = os.path.join(OUT, "tmp_pull_adv")
    if os.path.exists(tp):
        shutil.rmtree(tp)

    r = sh(["adb", "devices"], timeout=10)
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[1] == "device" and not p[0].startswith("emulator-"):
            P(f"[0] 警告：非模拟器设备 {p[0]} 在线，全程拒绝在其上执行")

    P("[1] 启动模拟器 " + " ".join(EMULATOR_ARGS))
    emu_log = open(os.path.join(OUT, "emu_adv_r1.log"), "w", encoding="utf-8")
    emu = subprocess.Popen([EMU_EXE] + EMULATOR_ARGS,
                           stdout=emu_log, stderr=subprocess.STDOUT,
                           creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    serial = wait_emulator_serial()
    if serial is None:
        P("FATAL: 模拟器进程未出现（见 out/emu_adv_r1.log）")
        return 2
    SERIAL = serial
    P(f"[1] serial={SERIAL}，等待 boot ...")
    if not wait_boot():
        P("FATAL: boot 超时")
        return 2
    time.sleep(10)

    P("[2] adb install")
    r = adb("install", "-r", APK, timeout=900)
    P("    install: " + r.stdout.strip().replace("\n", " | ")[:200])
    if "Success" not in r.stdout:
        P("FATAL: install 失败 " + (r.stderr or "")[:300])
        return 2

    tar_path = os.path.join(OUT, "adv_fixtures.tar")
    with tarfile.open(tar_path, "w") as tf:
        tf.add(FIX, arcname="in")
    adb("shell", "rm -rf /data/local/tmp/muzhao_adv_tmp", timeout=60)
    adb("push", tar_path, "/data/local/tmp/adv_fixtures.tar", timeout=900)
    r = adb("shell",
            f"mkdir -p /data/local/tmp/muzhao_adv_tmp && "
            f"cd /data/local/tmp/muzhao_adv_tmp && tar -xf /data/local/tmp/adv_fixtures.tar && "
            f"ls {REMOTE_IN} | wc -l", timeout=120)
    P(f"[2] push 完成（条目 {r.stdout.strip()}）")

    summary = {"chunks": []}
    sampler = None
    for name, ids, timeout_s, mem in chunks:
        P(f"[3] 块 {name}: {len(ids)} 用例")
        clear_app_out()
        cfg_path = os.path.join(OUT, "tmp_adv_config.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump({"mode": "cases", "cases": ids,
                       "out_dir": f"/data/user/0/{PKG}/{APP_OUT}"}, f)
        adb("push", cfg_path, f"{REMOTE_IN}/adv_config.json", timeout=60)
        if mem and sampler is None:
            sampler = MemSampler(interval=1.0)
            sampler.start()
        launch_app()
        t0 = time.time()
        done = False
        while time.time() - t0 < timeout_s:
            if remote_marker("done_cases"):
                done = True
                break
            time.sleep(5)
        chunk_info = {"chunk": name, "cases": ids, "done_marker": done,
                      "elapsed_s": round(time.time() - t0)}
        if not done:
            # 进程可能已崩：查活体 + 归因
            r = adb("shell", "pidof " + PKG, timeout=15)
            chunk_info["pid_alive"] = r.stdout.strip() != ""
            chunk_info["begun_without_end"] = begun_without_end()
            P(f"    !!! done marker 未出现：pid_alive={chunk_info['pid_alive']} "
              f"未完成用例={chunk_info['begun_without_end']}")
        pull_adv_out(os.path.join(OUT, f"pull_adv_{name}"))
        grab_logcat(f"logcat_adv_{name}_r1.txt")
        summary["chunks"].append(chunk_info)
        P(f"    done={done} ({time.time()-t0:.0f}s)")

    if sampler:
        sampler.stop()
        with open(os.path.join(OUT, out_json.replace(".json", "_mem.json")), "w") as f:
            json.dump({"peak_kb": sampler.peak_kb, "samples": sampler.samples}, f)

    # ---- 汇总 + 成片回读验证 ----
    P("[4] 汇总")
    items = []
    art_dirs = []
    for name, _, _, _ in chunks:
        p = os.path.join(OUT, f"pull_adv_{name}", "adv_out", "adv_items.jsonl")
        if os.path.exists(p):
            for line in open(p, encoding="utf-8"):
                line = line.strip()
                if line:
                    items.append(json.loads(line))
        d = os.path.join(OUT, f"pull_adv_{name}", "adv_out", "artifacts")
        if os.path.isdir(d):
            art_dirs.append(d)
    recs = {r["rec"]["id"]: r["rec"] for r in items if r.get("event") == "item"}

    # 成片回读：PIL 独立解码（不信任设备端结论）
    artifact_check = {}
    for art_dir in art_dirs:
        for fn in sorted(os.listdir(art_dir)):
            if not fn.endswith("_cand.jpg"):
                continue
            try:
                im = Image.open(os.path.join(art_dir, fn))
                im.load()
                artifact_check[fn] = {"decoded": True, "size": list(im.size)}
            except Exception as e:
                artifact_check[fn] = {"decoded": False, "error": str(e)}

    result = {
        "round": out_json.replace("ADVERSARIAL_", "").replace(".json", ""),
        "chunks": summary["chunks"],
        "cases": recs,
        "n_cases_recorded": len(recs),
        "artifact_check": artifact_check,
    }
    with open(os.path.join(OUT, out_json), "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    P(f"[4] 用例记录 {len(recs)}，成片回读 {len(artifact_check)} -> {out_json}")

    P("[5] 释放设备 adb emu kill")
    adb("emu", "kill", timeout=30)
    time.sleep(5)
    emu.terminate()
    emu_log.close()
    P("DONE")
    log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
