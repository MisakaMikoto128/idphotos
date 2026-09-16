# -*- coding: utf-8 -*-
"""tools/gate/g4_release_memcheck.py — G4.6/4.7/4.8 的 release 构建口径复测（gatekeeper 所有）。

背景（G4 r1 裁决事项，主会话 2026-09-15 指令）：
  qa-batch r2 的模拟器度量用的是 **debug** 构建（test/batch/run_device.py APK=
  app-debug.apk）。debug 的 JIT 与调试服务会显著抬高进程内存 floor，563.1MB 的
  4.7 峰值里 floor（440-510MB）占主导 —— 数字测错了工件。ACCEPTANCE 未规定构建
  类型；本脚本用 qa-batch 备好的 **release runner**（out/app-release-runner.apk，
  含 x86_64，构建于 01:42，含全部 r2 修复）在模拟器上重测：

  - 4.6: perf 模式 25 次 512x512 抠图 p95（release AOT）
  - 4.7: batch 全量 80 项（含 4958x7017 扫描件 item 21、Globe_High item 16）
         期间的进程峰值 PSS + 超 450MB 时的 dumpsys 分类拆解 + 空闲 floor
  - 4.8: leak 模式 20 连跑的基线/回落（协议与 qa-batch run_device.py 相同：
         预热 1 张 → 5s → leak_begin → 20 轮（轮间 2.5s）→ leak_end → 15s）

这是口径修正（测对工件），不是放宽阈值：450 数字不变。debug 数字记为参考。

钉死 emulator-*：真机（1e01895d）被 MIUI「USB 安装」开关阻塞，本轮绝不触碰。
判定量只输出到 out/gate_G4_release_metrics.json（gate schema + 拆解附注），
判定（阈值比较）由 tools/gate/gate_G4.dart 完成 —— 裁判不下场。
"""
import json
import os
import re
import statistics
import subprocess
import sys
import tarfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
DEV_IN = os.path.join(ROOT, "test", "batch", "device_in")
APK = os.path.join(OUT, "app-release-runner.apk")
# G4 runner APK（out/app-release-runner.apk）构建于阶段 5 包名变更之前，
# 其 applicationId 仍是 com.muzhao.muzhao —— 默认值必须与被驱动产物的实际包名
# 一致，不能跟着生产 App 的新 applicationId（com.muzhao.idphoto）走。
# 若将来用新包名重打 runner，设环境变量 MUZHAO_RUNNER_PKG=新包名 即可覆盖。
PKG = os.environ.get("MUZHAO_RUNNER_PKG", "com.muzhao.muzhao")
ACT = f"{PKG}/.MainActivity"
AVD = "Pixel_3a_API_34_extension_level_7_x86_64"
EMU_EXE = r"C:\Users\liuyu\AppData\Local\Android\Sdk\emulator\emulator.exe"
REMOTE_IN = "/data/local/tmp/muzhao_gate_rel/in"
# release runner APK 的 QA_DIR 是构建期 dart-define 烤死的（libapp.so strings 实证
# = /data/local/tmp/muzhao_qa_tmp/in，与 batch_runner.dart 源码默认值一致）。
# 运行期 qa_config.json 必须推到这个路径，否则 runner 读到别的轮次残留配置
# （本轮实测：读到 qa-batch r2 残留的 perf 配置导致跑错模式）。
BAKE_IN = "/data/local/tmp/muzhao_qa_tmp/in"
PKG_HOME = f"/data/user/0/{PKG}"
APP_OUT = "cache/qa_out"  # 相对 PKG_HOME；release 包 non-debuggable，run-as 不可用

EMULATOR_ARGS = ["-avd", AVD, "-gpu", "guest", "-feature", "-Vulkan",
                 "-no-window", "-no-snapshot-load"]

LOG_PATH = os.path.join(OUT, "GATE_G4_release_run.log")
_log = open(LOG_PATH, "a", encoding="utf-8")


def P(msg):
    print(msg, flush=True)
    _log.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    _log.flush()


SERIAL = None  # 钉死 emulator-*


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
    return sh(["adb", "-s", SERIAL, *args], timeout=timeout, check=check,
              binary=binary)


def run_as(*args, timeout=120, check=False, binary=False):
    """release 包 non-debuggable，run-as 一律失败 —— 保留函数名，走 adb root。
    前提：main() 里已执行 adb root（AVD 非 playstore 镜像支持）。"""
    return adb("shell", *args, timeout=timeout, check=check, binary=binary)


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


def dump_breakdown(tag, dump_dir):
    r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
    if r.returncode == 0:
        os.makedirs(dump_dir, exist_ok=True)
        with open(os.path.join(dump_dir, f"{tag}.txt"), "w",
                  encoding="utf-8", errors="replace") as f:
            f.write(r.stdout)


def read_marker(name):
    """返回 (设备epoch秒, host观测秒)。设备时钟与 host 可能漂移，
    采样窗一律以 host 观测时刻为锚。"""
    r = run_as("cat", f"{PKG_HOME}/{APP_OUT}/{name}", timeout=15)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        return int(r.stdout.strip()) / 1000.0, time.time()
    return None, None


def push_config(cfg):
    p = os.path.join(OUT, "tmp_gate_qa_config.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f)
    # 双份：BAKE_IN 是 runner 烤死路径（必须），REMOTE_IN 留档。
    adb("push", p, f"{BAKE_IN}/qa_config.json", timeout=60)
    adb("push", p, f"{REMOTE_IN}/qa_config.json", timeout=60)


def launch_app():
    # release 包 non-debuggable：qa_out 清理用 adb root（adbd 已 root），
    # 目录重建后要 chown 回 app 的 uid，否则 untrusted_app 写不进。
    adb("shell", "am force-stop " + PKG, timeout=30)
    uid = adb("shell",
              f"stat -c '%U:%G' {PKG_HOME}/cache", timeout=15).stdout.strip()
    adb("shell", f"rm -rf {PKG_HOME}/{APP_OUT}", timeout=15)
    adb("shell", f"mkdir -p {PKG_HOME}/{APP_OUT}", timeout=15)
    if uid:
        adb("shell", f"chown -R {uid} {PKG_HOME}/{APP_OUT}", timeout=15)
    r = adb("shell", f"am start -W --ez enable-impeller false -n {ACT}",
            timeout=120)
    return r


def wait_marker(name, deadline_s):
    """轮询 marker；返回首次观测到它的 host 时刻（采样窗锚点），未出现返回 None。"""
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        dev_s, obs = read_marker(name)
        if dev_s is not None:
            return obs
        time.sleep(2)
    return None


def pull_qa_out(dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    r = adb("exec-out", f"tar -cf - -C {PKG_HOME}/cache qa_out",
            timeout=300, binary=True)
    tar_path = os.path.join(dest_dir, "_pull.tar")
    with open(tar_path, "wb") as f:
        f.write(r.stdout)
    with tarfile.open(tar_path) as tf:
        tf.extractall(dest_dir)
    os.remove(tar_path)


class Sampler(threading.Thread):
    """1s 间隔采 TOTAL PSS；超阈值存完整 dumpsys 分类明细。"""

    DUMP_THRESHOLD_KB = 450 * 1024
    DUMP_CAP = 300

    def __init__(self):
        super().__init__(daemon=True)
        self.samples = []       # (epoch_s, kb)
        self.peak_kb = 0
        self.stop_flag = False
        self.dump_dir = os.path.join(OUT, "memdump_gate_release")
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
                        dump_breakdown(
                            f"rel{self.dump_n:04d}_t{t:.0f}", self.dump_dir)
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


def _write_final(res):
    """合并分阶段结果（batch/leak/perf 可分次跑），写 gate schema 输出。
    缺的阶段从上一份输出里继承（不覆盖已取得的真实测量）。"""
    prev_path = os.path.join(OUT, "gate_G4_release_metrics.json")
    prev = {}
    if os.path.exists(prev_path):
        try:
            prev = json.load(open(prev_path, encoding="utf-8"))
        except Exception:
            prev = {}
    detail = dict(prev.get("gateReleaseDetail") or {})
    for k in ("batchPhase", "leakPhase", "perfPhase"):
        if k in res and res[k] is not None:
            detail[k] = res[k]
    batch = detail.get("batchPhase") or {}
    leak = detail.get("leakPhase") or {}
    perf = detail.get("perfPhase") or {}
    out = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "device": res["device"] + " | build=" + res["build"],
        "matting512P95Ms": perf.get("p95_ms"),
        "matting512Samples": perf.get("n"),
        "peakMemoryMb": batch.get("peak_mb"),
        "leakBaselineMb": leak.get("baseline_mb"),
        "leakAfter20Mb": leak.get("after20_mb"),
        "build": "release",
        "note": res.get("note", ""),
        "gateReleaseDetail": detail,
    }
    with open(prev_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)


def main():
    global SERIAL
    res = {"generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
           "device": f"{AVD} (emulator, -gpu guest -feature -Vulkan, RAM 4096)",
           "build": "release (out/app-release-runner.apk, batch_runner 入口)",
           "note": "G4 r1 构建口径修正复测：qa-batch r2 的模拟器度量为 debug 构建，"
                   "本文件为 release 口径正式判定源；qa-batch debug 数字记为参考"}

    r = sh(["adb", "devices"], timeout=10)
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[1] == "device" and not p[0].startswith("emulator-"):
            P(f"[0] 警告：检测到非模拟器设备 {p[0]} 在线，全程拒绝在其上执行（真机本轮不碰）")

    SERIAL = wait_emulator_serial(5)
    if SERIAL is None:
        P("[1] 无在线模拟器，启动 " + " ".join(EMULATOR_ARGS))
        emu_log = open(os.path.join(OUT, "GATE_G4_rel_emu.log"), "w",
                       encoding="utf-8")
        emu = subprocess.Popen([EMU_EXE] + EMULATOR_ARGS, stdout=emu_log,
                               stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
        SERIAL = wait_emulator_serial()
        if SERIAL is None:
            P("FATAL: 模拟器进程未出现")
            return 2
        launched = True
    else:
        launched = False
        P(f"[1] 复用在线模拟器 {SERIAL}")
    P(f"[1] serial={SERIAL}，等 boot ...")
    if not wait_boot():
        P("FATAL: boot 超时")
        return 2
    time.sleep(10)

    only = sys.argv[1] if len(sys.argv) > 1 else "all"  # all | leak
    try:
        # release 包 non-debuggable，一切私有目录读取/清理走 adb root。
        P("[2] adb root")
        r = adb("root", timeout=30)
        P("    " + (r.stdout or r.stderr).strip()[:120])
        time.sleep(3)

        P("[2] install release runner")
        r = adb("install", "-r", APK, timeout=900)
        P("    " + r.stdout.strip().replace("\n", " | ")[:200])
        if "Success" not in r.stdout:
            P("FATAL: install 失败 " + (r.stderr or "")[:300])
            return 2

        tar_path = os.path.join(OUT, "device_in.tar")
        # runner 的 QA_DIR 是烤死的 BAKE_IN —— 输入与运行期配置都必须在这里。
        adb("shell", "rm -rf /data/local/tmp/muzhao_qa_tmp", timeout=60)
        adb("shell", "rm -rf /data/local/tmp/muzhao_gate_rel", timeout=60)
        adb("push", tar_path, "/data/local/tmp/device_in_gate.tar", timeout=900)
        r = adb("shell",
                f"mkdir -p /data/local/tmp/muzhao_qa_tmp /data/local/tmp/muzhao_gate_rel && "
                f"cd /data/local/tmp/muzhao_qa_tmp && "
                f"tar -xf /data/local/tmp/device_in_gate.tar && "
                f"ls {BAKE_IN} | wc -l", timeout=180)
        P(f"[2] push 条目数 {r.stdout.strip()}")
        if r.stdout.strip() != "82":
            P("FATAL: push 条目数不为 82")
            return 2

        sampler = Sampler()
        sampler.stop_flag = True  # 先不启动，模式内再启动

        # ---- 模式 1：batch 全量（4.7 峰值 + 拆解）----
        if only in ("all", "batch"):
            P("[3] batch 全量 80 项（release，4.7 峰值测量）")
            sampler = Sampler()
            sampler.start()
            batch_t0 = time.time()
            push_config({"mode": "batch", "from": 0, "to": 79,
                         "out_dir": f"{PKG_HOME}/{APP_OUT}"})
            launch_app()
            if not wait_marker("done_batch", 3600):
                P("FATAL: batch 未在时限内完成")
                sampler.stop()
                return 2
            batch_t1 = time.time()
            time.sleep(5)
            sampler.stop()
            with open(os.path.join(OUT, "gate_G4_release_batch_curve.json"),
                      "w", encoding="utf-8") as f:
                json.dump(sampler.samples, f)
            pull_qa_out(os.path.join(OUT, "gate_pull_batch_rel"))
            res["batchPhase"] = {
                "wall_s": round(batch_t1 - batch_t0, 1),
                "peak_mb": round(sampler.peak_kb / 1024.0, 1),
                "n_samples": len(sampler.samples),
            }
            P(f"    batch 峰值 {res['batchPhase']['peak_mb']}MB")
        if only == "batch":
            _write_final(res)
            return 0

        # ---- 模式 2：leak 20 轮（4.8）----
        if only in ("all", "leak"):
            P("[4] leak 模式 20 轮（release，4.8）")
            sampler = Sampler()
            sampler.start()
            push_config({"mode": "leak",
                         "out_dir": f"{PKG_HOME}/{APP_OUT}"})
            launch_app()
            leak_begin_obs = wait_marker("leak_begin", 2400)
            leak_end_obs = wait_marker("leak_end", 2400)
            if leak_end_obs is None:
                P("FATAL: leak 未在时限内完成")
                sampler.stop()
                return 2
            time.sleep(5)
            sampler.stop()
            with open(os.path.join(OUT, "gate_G4_release_leak_curve.json"),
                      "w", encoding="utf-8") as f:
                json.dump(sampler.samples, f)
            pull_qa_out(os.path.join(OUT, "gate_pull_leak_rel"))
            # 基线 = leak_begin 观测前 6s 窗（协议：预热+5s 后打 leak_begin，轮次未开始）；
            # 回落 = leak_end 观测后 14s 窗（协议：leak_end 后 runner 空闲 15s 再退出）。
            baseline = sampler.window_median_mb(leak_begin_obs - 6, leak_begin_obs) \
                if leak_begin_obs else None
            after = sampler.window_median_mb(leak_end_obs, leak_end_obs + 14) \
                if leak_end_obs else None
            res["leakPhase"] = {
                "baseline_mb": baseline, "after20_mb": after,
                "delta_mb": round(after - baseline, 1)
                if baseline is not None and after is not None else None,
                "peak_during_mb": round(sampler.peak_kb / 1024.0, 1),
            }
            P(f"    leak: baseline={baseline} after20={after} "
              f"delta={res['leakPhase']['delta_mb']}")
        if only == "leak":
            _write_final(res)
            return 0

        _write_final(res)
        P("[6] 已写出 out/gate_G4_release_metrics.json")
        return 0
    finally:
        if launched:
            adb("emu", "kill", timeout=30)
            time.sleep(5)
            P("[7] adb emu kill 已执行")


if __name__ == "__main__":
    sys.exit(main())
