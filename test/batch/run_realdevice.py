# -*- coding: utf-8 -*-
"""qa-batch 真机补测 v3（2026-09-15，主会话追加任务）。

钉死真机 serial 1e01895d（用户手动重新授权后）。拒绝任何 emulator-*。
产出 out/metrics_r1_realdevice.json（gatekeeper gate_G4 的"真机优先"通道）：
  - 4.6: 512x512 抠图 p95（>=20 次）
  - 4.7: 含 4958x7017 扫描件的进程峰值（floor 与增量分开报 + dumpsys 分类）
  - 4.8: 20 张连续处理后回落
  - coldStartRealDeviceTotalMs: 主入口 release APK am start -W（参考字段）

v3 关键变更（v1/v2 实测踩坑，详见 docs/PITFALLS.md）：
  - release 包不可调试：run-as 全线拒绝；
  - MIUI FUSE 连 App 自己的 /sdcard/Android/data/<pkg> 都不让 File API 建
    （框架 getExternalFilesDir 才会预建；shell 代建的目录属主 shell，App 仍拒写）；
  - 最终通道：batch_runner.dart 把 marker/JSONL 打到 logcat（QA_MARKER/QA_JSONL
    分块），host 用 `logcat -d -v epoch -s flutter` 解析重组。每阶段前 logcat -c
    清缓冲，天然免 marker 新鲜度校验。

流程：
  1. install runner release APK（QA_SKIP_INSTALL=1 可跳过，须已侧载同构建）
  2. leak 模式（20 连跑，1s 采样 dumpsys）
  3. batch 模式单跑大图条目（扫描件 4958x7017）+ 峰值采样
  4. perf 模式 25 次
  5. install main release -> am start -W x3 + 截图 -> uninstall 清理
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
DEV_IN = os.path.join(ROOT, "test", "batch", "device_in")
PKG = "com.muzhao.muzhao"
ACT = f"{PKG}/.MainActivity"
REAL_SERIAL = os.environ.get("QA_SERIAL", "5bc6e093")  # 钉死：vivo X21A（小米机退休）
REMOTE_IN = "/data/local/tmp/muzhao_qa_tmp/in"
REMOTE_TOP = "/data/local/tmp/muzhao_qa_tmp"
PERF_N = 25

LOG_PATH = os.path.join(OUT, "run_realdevice.log")
_log = open(LOG_PATH, "a", encoding="utf-8")


def P(msg):
    print(msg, flush=True)
    _log.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    _log.flush()


def sh(cmd, timeout=120, check=False, binary=False):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout,
                       **({} if binary else {"text": True, "encoding": "utf-8",
                                             "errors": "replace"}))
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd} -> {r.returncode}\n{r.stdout!r}\n{r.stderr!r}")
    return r


def adb(*args, timeout=120, check=False, binary=False):
    # 安全钉死：拒绝模拟器与旧小米机，仅允许当前测试真机
    assert REAL_SERIAL == "5bc6e093", f"refuse non-target device: {REAL_SERIAL}"
    return sh(["adb", "-s", REAL_SERIAL, *args], timeout=timeout, check=check,
              binary=binary)


def total_pss_kb():
    try:
        r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
    except Exception:
        return None  # vivo 负载下 dumpsys 偶发超时：单样丢失可容忍
    if r.returncode != 0:
        return None
    # Android 13+ 摘要行："TOTAL PSS:  123  TOTAL RSS: ..."
    for line in r.stdout.splitlines():
        s = line.strip()
        if s.startswith("TOTAL PSS"):
            toks = s.split()
            try:
                return int(toks[toks.index("PSS:") + 1])
            except (ValueError, IndexError):
                pass
    # Android 9 兜底：App Summary/明细表的 "TOTAL    33459    18188 ..." 行
    for line in r.stdout.splitlines():
        m = re.match(r"TOTAL\s+(\d+)\s+", line.strip())
        if m:
            return int(m.group(1))
    return None


def device_clock_offset():
    """host_epoch - device_epoch。vivo 的 NTP 会把设备钟拉得和宿主差一年，
    logcat -v epoch 的时间戳必须加偏移才能与 host 采样对齐。"""
    try:
        r = adb("shell", "date +%s", timeout=20)
        return time.time() - float(r.stdout.strip())
    except Exception:
        return 0.0


def dump_breakdown(tag):
    r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
    if r.returncode == 0:
        d = os.path.join(OUT, "memdump_realdevice")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{tag}.txt"), "w", encoding="utf-8",
                  errors="replace") as f:
            f.write(r.stdout)


def sample_loop(stop_flag, interval, out_list, dump_dir=None, dump_cap=200):
    """持续采样 TOTAL PSS；可选每样存完整 dumpsys（floor/增量拆解证据）。"""
    n = 0
    while not stop_flag.is_set():
        try:
            kb = total_pss_kb()
            t = time.time()
        except Exception:
            time.sleep(interval)
            continue
        try:
            if kb:
                out_list.append((round(t, 1), kb))
            if dump_dir and kb and n < dump_cap:
                try:
                    os.makedirs(dump_dir, exist_ok=True)
                    r = adb("shell", f"dumpsys meminfo {PKG}", timeout=20)
                    if r.returncode == 0:
                        n += 1
                        with open(os.path.join(
                                dump_dir, f"seq{n:04d}_t{t:.0f}.txt"), "w",
                                encoding="utf-8", errors="replace") as f:
                            f.write(r.stdout)
                except Exception:
                    pass
        except Exception:
            pass
        time.sleep(interval)


def screencap(name):
    scr = sh(["adb", "-s", REAL_SERIAL, "exec-out", "screencap", "-p"],
             timeout=60, binary=True)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(scr.stdout)
    P(f"    截图 out/{name} ({len(scr.stdout)}B)")


def _current_focus():
    r = adb("shell", "dumpsys window", timeout=30)
    m = re.search(r"mCurrentFocus=Window{[^}]* (\S+)", r.stdout)
    return m.group(1) if m else ""


def install_with_autoconfirm(apk, timeout_s=300):
    """vivo/安卓 9：adb install 会弹系统确认框（"继续安装"），无人值守时
    被自动取消。代点流程：后台跑 install，轮询焦点窗口，出现确认框时
    在按钮坐标 tap（vivo X21A 1080x2280，"继续安装"固定在 (540,2098)，
    由截图目检定位，见 out/vivo_dialog.png）。"""
    adb("shell", "input keyevent KEYCODE_WAKEUP", timeout=15)
    result = {}

    def do_install():
        result["out"] = adb("install", "-r", apk, timeout=timeout_s)

    th = threading.Thread(target=do_install, daemon=True)
    th.start()
    t0 = time.time()
    tapped = 0
    while th.is_alive() and time.time() - t0 < timeout_s:
        focus = _current_focus()
        if "packageinstaller.PackageInstallerActivity" in focus:
            time.sleep(1.5)  # 等 dialog 完全呈现
            adb("shell", f"input tap 540 2098", timeout=15)
            tapped += 1
            P(f"    自动确认框代点 #{tapped}")
            time.sleep(2)
        else:
            time.sleep(1.5)
    th.join(timeout=30)
    out = result.get("out")
    txt = (out.stdout + (out.stderr or "")) if out else "install thread lost"
    P("    install: " + txt.strip().replace("\n", " | ")[:200])
    return "Success" in txt


def launch_app():
    adb("shell", "input keyevent KEYCODE_WAKEUP", timeout=15)
    time.sleep(1)
    adb("shell", "am force-stop " + PKG, timeout=30)
    adb("logcat", "-c", timeout=30)   # v3：清缓冲，阶段内 logcat 即本阶段数据
    for attempt in range(3):
        try:
            r = adb("shell", f"am start -W --ez enable-impeller false -n {ACT}",
                    timeout=90)
        except subprocess.TimeoutExpired:
            r = None
            # vivo：-W 等活动空闲回调间歇性挂死。改非阻塞 am start。
            adb("shell", f"am start --ez enable-impeller false -n {ACT}",
                timeout=60)
        # 启动验证：vivo 上 -W 可能静默无效（AMS 不拉起进程）
        spawned = None
        for _ in range(12):
            spawned = adb("shell", "pidof " + PKG,
                          timeout=15).stdout.strip()
            if spawned:
                break
            time.sleep(3)
        if spawned:
            P(f"    App 进程已起（pid {spawned}，attempt {attempt+1}），继续")
            time.sleep(3)
            return r
        P(f"    attempt {attempt+1} 未拉起进程，重试")
        adb("shell", "am force-stop " + PKG, timeout=30)
        time.sleep(3)
    P("    警告：3 次尝试均未拉起 App（该阶段将无数据）")
    return None


def push_config(cfg):
    p = os.path.join(OUT, "tmp_qa_config_rd.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f)
    adb("push", p, f"{REMOTE_IN}/qa_config.json", timeout=60)


_LINE_RE = re.compile(
    r"\s*(\d{9,12}\.\d+)\s+\d+\s+\d+\s+[IWE]\s*flutter\s*:\s(.*)")


def collect_logcat(timeout=90):
    """dump flutter tag logcat，重组 QA_MARKER/QA_JSONL。

    返回 (markers: [(name, epoch_s)], recs: {filename: [obj]}).
    """
    r = adb("logcat", "-d", "-v", "epoch", "-s", "flutter", timeout=timeout)
    markers = []
    chunks = {}
    for line in r.stdout.splitlines():
        m = _LINE_RE.match(line)
        if not m:
            continue
        ts = float(m.group(1))
        msg = m.group(2)
        if msg.startswith("QA_MARKER|"):
            markers.append((msg.split("|", 1)[1], ts))
        elif msg.startswith("QA_JSONL|"):
            parts = msg.split("|", 4)
            if len(parts) != 5:
                continue
            _, name, rid, seq, piece = parts
            i_n = seq.split("/")
            if len(i_n) != 2:
                continue
            chunks.setdefault((name, rid), []).append(
                (int(i_n[0]), int(i_n[1]), piece))
    recs = {}
    for (name, rid), lst in chunks.items():
        lst.sort(key=lambda x: x[0])
        payload = "".join(p for _, _, p in lst)
        try:
            obj = json.loads(payload)
        except Exception:
            obj = {"_unparsed": payload[:400]}
        recs.setdefault(name, []).append(obj)
    return markers, recs


def wait_marker(name, deadline_s):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        markers, _ = collect_logcat()
        if any(n == name for n, _ in markers):
            return True
        time.sleep(3)
    return False


def marker_ts(markers, name):
    return next((ts for n, ts in markers if n == name), None)


def main():
    # 0. 前置：确认目标真机 authorized，拒绝模拟器
    r = sh(["adb", "devices"], timeout=10)
    ok = False
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[0] == REAL_SERIAL and p[1] == "device":
            ok = True
    if not ok:
        P(f"FATAL: {REAL_SERIAL} 不在 device 状态，中止")
        return 2
    for line in r.stdout.splitlines()[1:]:
        p = line.split()
        if len(p) >= 2 and p[0].startswith("emulator-") and p[1] == "device":
            P(f"警告：检测到模拟器 {p[0]} 在线，本脚本拒绝在其上执行")

    runner_apk = os.path.join(OUT, "app-release-runner.apk")
    main_apk = os.path.join(OUT, "app-release-main.apk")
    if not (os.path.exists(runner_apk) and os.path.exists(main_apk)):
        P("FATAL: 缺 out/app-release-runner.apk / out/app-release-main.apk")
        return 2

    res = {"device": REAL_SERIAL,
           "note": "真机补测 v3（logcat 通道），serial 钉死 1e01895d；"
                   "runner/main 为侧载构建（ml-porting G4 修复前代码）"}

    # 1. install runner + push 输入
    skip_install = os.environ.get("QA_SKIP_INSTALL") == "1"
    P("[1] install runner release APK" +
      ("（QA_SKIP_INSTALL=1，假定已侧载同构建）" if skip_install else ""))
    if not skip_install:
        adb("uninstall", PKG, timeout=60)
        ok = install_with_autoconfirm(runner_apk)
        if not ok:
            P("FATAL: install 失败")
            return 2
    tar_path = os.path.join(OUT, "device_in.tar")
    adb("shell", f"rm -rf {REMOTE_TOP}", timeout=60)
    adb("push", tar_path, "/data/local/tmp/device_in.tar", timeout=900)
    r = adb("shell",
            f"mkdir -p {REMOTE_TOP} && cd {REMOTE_TOP} && "
            f"tar -xf /data/local/tmp/device_in.tar && ls {REMOTE_IN} | wc -l",
            timeout=300)
    P(f"[1] push 条目数 {r.stdout.strip()}")
    # vivo 上链式命令偶发 stdout 丢失：解包其实已成功，单独复核计数
    if r.stdout.strip() != "82":
        for _ in range(3):
            r = adb("shell", f"ls {REMOTE_IN} | wc -l", timeout=60)
            if r.stdout.strip() == "82":
                P("[1] 复核计数 82（此前为偶发 stdout 丢失）")
                break
        else:
            P(f"FATAL: push 条目数不为 82（复核 {r.stdout.strip()!r}）")
            return 2

    # 2. leak 模式（4.8）
    P("[2] leak 模式（20 连跑）")
    push_config({"mode": "leak", "out_dir": "/dev/null_unused"})
    launch_app()
    stop = threading.Event()
    samples = []
    th = threading.Thread(target=sample_loop,
                          args=(stop, 1.0, samples,
                                os.path.join(OUT, "memdump_realdevice")),
                          daemon=True)
    th.start()
    ok = wait_marker("done_leak", 1800)
    P(f"    done_leak: {ok}")
    time.sleep(16)
    stop.set()
    th.join(timeout=60)
    dump_breakdown("leak_after")
    markers, recs = collect_logcat()
    rounds = recs.get("leak_items.jsonl", [])
    with open(os.path.join(OUT, "rd_leak_items.jsonl"), "w",
              encoding="utf-8") as f:
        for x in rounds:
            f.write(json.dumps(x, ensure_ascii=False) + "\n")
    beg = marker_ts(markers, "leak_begin")
    end = marker_ts(markers, "leak_end")
    # 设备钟 → 宿主钟换算（NTP 漂移可达一年，不换算窗口必空）
    off = device_clock_offset()
    if beg:
        beg += off
    if end:
        end += off
    P(f"    时钟偏移 {off:.1f}s")
    base_win = [kb for (t, kb) in samples if kb and beg and beg - 8 <= t <= beg + 8]
    settle_win = [kb for (t, kb) in samples if kb and end and t >= end]
    base = sorted(base_win)[len(base_win) // 2] if base_win else None
    settle = min(settle_win) if settle_win else None
    during = [kb for (t, kb) in samples
              if kb and beg and end and beg <= t <= end + 3]
    res["G4_8_leak"] = {
        "n_rounds": len(rounds),
        "baseline_mb": round(base / 1024, 1) if base else None,
        "settle_min_mb": round(settle / 1024, 1) if settle else None,
        "delta_settle_mb": round((settle - base) / 1024, 1)
        if (base and settle) else None,
        "peak_during_mb": round(max(during) / 1024, 1) if during else None,
        "samples_mb": [[t, round(kb / 1024, 1)] for t, kb in samples],
    }
    P(f"    4.8: rounds {len(rounds)}, base {res['G4_8_leak']['baseline_mb']}MB"
      f" -> settle {res['G4_8_leak']['settle_min_mb']}MB, delta "
      f"{res['G4_8_leak']['delta_settle_mb']}MB, peak_during "
      f"{res['G4_8_leak']['peak_during_mb']}MB")
    for e in recs.get("qa_errors.jsonl", []):
        P(f"    qa_errors: {json.dumps(e, ensure_ascii=False)[:400]}")

    # 3. churn batch：全部人像/多脸 + 4958x7017 扫描件（4.7 终判主口径）
    P("[3] churn batch：14 人像/多脸 + 扫描件")
    manifest = json.load(open(os.path.join(DEV_IN, "manifest.json"),
                              encoding="utf-8"))
    sel = [it for it in manifest["items"]
           if it["class"] in ("portrait", "multi_face")
           or "Online Verification Report" in it["path"]]
    sub = {"items": [dict(it, i=k) for k, it in enumerate(sel)]}
    sub_path = os.path.join(OUT, "manifest_churn.json")
    with open(sub_path, "w", encoding="utf-8") as f:
        json.dump(sub, f, ensure_ascii=False)
    adb("push", sub_path, f"{REMOTE_IN}/manifest.json", timeout=60)
    P(f"    churn manifest {len(sel)} 项（重编号 0..{len(sel)-1}）")
    push_config({"mode": "batch", "from": 0, "to": 999999,
                 "out_dir": "/dev/null_unused"})
    stop = threading.Event()
    samples2 = []
    hwms = []

    def hwm_loop():
        # VmHWM（/proc/pid/status 高水位，单调）是 RSS 噪声地板下的唯一可信终判
        while not stop.is_set():
            try:
                r = adb("shell",
                        "'cat /proc/$(pidof " + PKG + ")/status' | grep VmHWM",
                        timeout=20)
                m = re.search(r"VmHWM:\s+(\d+)", r.stdout)
                if m:
                    hwms.append((round(time.time(), 1), int(m.group(1))))
            except Exception:
                pass
            time.sleep(2)

    th = threading.Thread(target=sample_loop,
                          args=(stop, 1.0, samples2,
                                os.path.join(OUT, "memdump_realdevice")),
                          daemon=True)
    th.start()
    th2 = threading.Thread(target=hwm_loop, daemon=True)
    th2.start()
    launch_app()
    ok = wait_marker("done_batch", 1200)
    P(f"    done_batch: {ok}")
    time.sleep(4)
    stop.set()
    th.join(timeout=60)
    th2.join(timeout=60)
    # 阶段 3 自己的 logcat 数据（不 collect 会拿到阶段 2 的陈旧 recs）
    markers, recs = collect_logcat()
    P("    recs 计数: " + str({k: len(v) for k, v in recs.items()}))
    for e in recs.get("qa_errors.jsonl", []):
        P(f"    qa_errors: {json.dumps(e, ensure_ascii=False)[:400]}")
    kbvals = [kb for _, kb in samples2 if kb]
    # floor：稳态估计 = 去掉最高 10% 采样后的中位（排除峰值窗口与启动爬坡）
    srt = sorted(kbvals)
    trim = srt[:int(len(srt) * 0.9)] if len(srt) >= 10 else srt
    floor = trim[len(trim) // 2] if trim else None
    peak = max(kbvals) if kbvals else None
    # 峰值时刻 dumpsys 分类
    peak_t = max(samples2, key=lambda x: x[1])[0] if samples2 else None
    cats = {}
    if peak_t:
        best, bestdt = None, None
        for name in os.listdir(os.path.join(OUT, "memdump_realdevice")):
            m = re.match(r"seq\d+_t(\d+)\.txt", name)
            if not m:
                continue
            dt = abs(int(m.group(1)) - peak_t)
            if bestdt is None or dt < bestdt:
                best, bestdt = name, dt
        if best:
            for line in open(os.path.join(OUT, "memdump_realdevice", best),
                             encoding="utf-8", errors="replace"):
                m = re.match(r"\s*(Native Heap|Graphics|Java Heap|Code|Stack|"
                             r"Private Other|TOTAL PSS):\s+(\d+)", line)
                if m:
                    cats[m.group(1)] = round(int(m.group(2)) / 1024, 1)
            P(f"    峰值分类({best}, dt={bestdt}s): {cats}")
    items = [x for x in recs.get("batch_items.jsonl", [])
             if x.get("event") == "item"]
    with open(os.path.join(OUT, "rd_batch_churn.json"), "w",
              encoding="utf-8") as f:
        json.dump(recs.get("batch_items.jsonl", []), f,
                  ensure_ascii=False, indent=1)
    hwm_final = max((v for _, v in hwms), default=None)  # KB，单调高水位
    peak_hwm_t = next((t for t, v in hwms if v == hwm_final), None)
    res["G4_7_peak"] = {
        "churn_n": len(sel),
        "churn_paths": [it["path"] for it in sel],
        "floor_mb": round(floor / 1024, 1) if floor else None,
        "peak_mb": round(peak / 1024, 1) if peak else None,
        "increment_over_floor_mb": round((peak - floor) / 1024, 1)
        if (peak and floor) else None,
        "vmhwm_mb": round(hwm_final / 1024, 1) if hwm_final else None,
        "vmhwm_samples": len(hwms),
        "dumpsys_at_peak": cats,
        "item_results": [{"i": x.get("rec", {}).get("i"),
                          "result": x.get("rec", {}).get("result"),
                          "matting_ms": x.get("rec", {}).get("engine", {})
                          .get("matting_ms")} for x in items],
        "samples_mb": [[t, round(kb / 1024, 1)] for t, kb in samples2],
        "hwm_trace_kb": hwms,
    }
    P(f"    4.7: floor {res['G4_7_peak']['floor_mb']}MB, peakPSS "
      f"{res['G4_7_peak']['peak_mb']}MB, VmHWM "
      f"{res['G4_7_peak']['vmhwm_mb']}MB (n={len(hwms)}), "
      f"items_ok={sum(1 for x in res['G4_7_peak']['item_results'] if x['result']=='success')}")

    # 4. perf 模式（4.6）
    P("[4] perf 模式 512x512 x25")
    push_config({"mode": "perf", "perf_n": PERF_N,
                 "out_dir": "/dev/null_unused"})
    launch_app()
    ok = wait_marker("done_perf", 900)
    P(f"    done_perf: {ok}")
    markers, recs = collect_logcat()
    ms = []
    for x in recs.get("perf_ms.json", []):
        if isinstance(x.get("ms"), list):
            ms = sorted(x["ms"])
    if ms:
        def pct(p):
            k = (len(ms) - 1) * p / 100.0
            f_, c_ = int(k), min(int(k) + 1, len(ms) - 1)
            return ms[f_] * (c_ - k) + ms[c_] * (k - f_) if f_ != c_ else ms[f_]
        res["G4_6_perf"] = {"n": len(ms), "p50_ms": pct(50), "p95_ms": pct(95),
                            "min_ms": ms[0], "max_ms": ms[-1],
                            "all_ms": sorted(ms)}
        P(f"    4.6: p50 {res['G4_6_perf']['p50_ms']}ms, p95 "
          f"{res['G4_6_perf']['p95_ms']}ms")
    dump_breakdown("perf_steady")

    # 5. install main release -> cold start x3 + 截图 -> uninstall 清理
    P("[5] cold start（主入口 release）")
    main_ok = install_with_autoconfirm(main_apk)
    if not main_ok:
        chk = adb("shell", "pm path " + PKG, timeout=30)
        if chk.returncode == 0 and chk.stdout.strip().startswith("package:"):
            P("    main install 被拒但设备上有包（可能是 runner 构建），"
              "冷启动数字将标注为 runner 入口")
        else:
            P("    cold start 跳过（无包）")
            main_ok = None
    if main_ok:
        cold = []
        for i in range(3):
            r = adb("shell", f"am start -W --ez enable-impeller false -n {ACT}",
                    timeout=120)
            m = re.search(r"TotalTime: (\d+)", r.stdout)
            if m:
                cold.append(int(m.group(1)))
            # 用户要求截图：首帧后 2s / 6s 各一张（白屏还是真 UI，肉眼可核）
            time.sleep(2)
            screencap(f"rd_screen_cold{i}_t2.png")
            time.sleep(4)
            screencap(f"rd_screen_cold{i}_t6.png")
            time.sleep(2)
            adb("shell", "input keyevent KEYCODE_HOME", timeout=15)
        res["coldStartRealDeviceTotalMs"] = cold
        res["coldStartNote"] = "主入口 release 构建，am start -W TotalTime"
        P(f"    am start -W TotalTime x3: {cold}")
    adb("uninstall", PKG, timeout=60)
    P("[5] 已 uninstall 清理")

    # 清理 /data/local/tmp 残留
    adb("shell", f"rm -rf {REMOTE_TOP} /data/local/tmp/device_in.tar",
        timeout=60)

    out_path = os.path.join(OUT, "metrics_r1_realdevice.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    P(f"DONE -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
