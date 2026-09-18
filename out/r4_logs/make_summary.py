# -*- coding: utf-8 -*-
"""qa-batch：r4 预轮重测的**可读留证件**生成器（输出 `out/r4_logs/summary.txt`）。

为什么要有它：步骤日志本身被 `.gitignore:17` 的 `*.log` 盖掉（**不 `-f` 绕**），
所以入库的是这份**自足**的摘要 —— 它把每条日志里决定性的一行**原文摘出**，
并把每个数字的出处写在同一张表里。读的人不需要 `.log` 就能复核。

数字来源分两类，**分开标注，不混**：
  * `[机器]` = 本脚本从盘上产物 / 日志当下重新算出来的；
  * `[运行者]` = 跑链时读取的退出码，**日志里没有**（当时直接打了 stdout），
    如实标注来源，不假装是机器现算的。
    旁证：`flutter test` 的日志尾部含 `All tests passed!`、`dart run` 的含各自 PASS 串，
    本脚本**逐条断言这些串在场** —— 退出码 [运行者] 与这些串一致才印。

用法：python out/r4_logs/make_summary.py > out/r4_logs/summary.txt
"""
import hashlib
import json
import os
import re
import subprocess
import sys

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"
LOGS = os.path.join(REPO, "out", "r4_logs")

# 步骤名 -> (日志文件, 退出码[运行者], 决定性串的正则)
STEPS = [
    ("1  样本解析",        "01_resolve.log",              0, r"RESOLVE CHECK PASS"),
    ("2  成片台",          "02_compose.log",              0, r"All tests passed!"),
    ("2b 来源绑定",        "02b_prov_after_compose.log",  0, r"全部通过（3 份产物 \+ 绑定复核）"),
    ("3  alpha 落盘",      "03_alpha_dump.log",           0, r"All tests passed!"),
    ("4  端到端残余",      "04_residual.log",             0, None),
    ("5  alpha 全扫",      "05_alpha_scan.log",           0, r"All tests passed!"),
    ("6  眼带空洞",        "06_alpha_holes.log",          0, r"对照图 ->"),
    ("7  自检",            "07_selfcheck.log",            0, r"退出码=0 通过=9 失败=0 pass=true"),
    ("8  覆盖率",          "08_coverage.log",             0, r"All tests passed!"),
    ("8b 来源绑定",        "08b_prov_after_coverage.log", 0, r"全部通过（5 份产物 \+ 绑定复核）"),
    ("9  几何核验",        "09_verify_geo.log",           0, r"minNCC=0\.9985"),
    ("10 真值重建",        "10_finalize.log",             0, r"anchors=13 .* rotated=78"),
    ("10b 来源绑定",       "10b_prov_final.log",          0, r"全部通过（7 份产物 \+ 绑定复核）"),
    ("11 重建后复检",      "11_resolve_recheck.log",      0, r"RESOLVE CHECK PASS"),
]


def _tail_line(path, pattern):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        txt = fh.read()
    if pattern is None:
        return "（该步无固定断言串；见产物）"
    hits = re.findall(".*" + pattern + ".*", txt)
    return hits[-1].strip() if hits else None


def _sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def _mtime(p):
    import datetime
    return datetime.datetime.fromtimestamp(os.stat(p).st_mtime).strftime("%Y-%m-%d %H:%M:%S")


def main():
    w = sys.stdout.write
    w("r4 预轮重测 —— 留证件（由 out/r4_logs/make_summary.py 生成）\n")
    w("口径：[机器] = 现算；[运行者] = 跑链时读取、日志里没有，已如实标注。\n")
    w("=" * 100 + "\n\n")

    w("## 1. 链条（11 步）\n\n")
    w("| # | exit[运行者] | 日志里的决定性一行[机器] |\n|---|---|---|\n")
    ok = True
    for name, log, code, pat in STEPS:
        line = _tail_line(os.path.join(LOGS, log), pat)
        mark = "**缺**" if line is None else line
        if line is None:
            ok = False
        w(f"| {name} | {code} | {mark} |\n")
    w(f"\n断言串逐条在场：**{ok}**（False 表示退出码与日志内容不一致，不得采信上表）\n\n")

    w("## 2. 被钉产物（同批，[机器]）\n\n")
    w("| 产物 | mtime | sha256 |\n|---|---|---|\n")
    for p in ("out/P0_compose_summary.json", "out/P0_output_residual.json", "out/P0_alpha_holes.json",
              "out/P0_truth.json", "out/P0_coverage_post.json", "out/P0_selfcheck_provenance.json",
              "out/P0_input_hashes.json", "out/P0_anchors/fixture_geo_verify.json"):
        ap = os.path.join(REPO, *p.split("/"))
        w(f"| `{p}` | {_mtime(ap)} | `{_sha(ap)}` |\n")

    t = json.load(open(os.path.join(REPO, "out", "P0_truth.json"), encoding="utf-8"))
    gi = t["gateInputs"]
    cf = gi["inputHashes"]["byId"]  # 仅确认可读
    del cf
    res = json.load(open(os.path.join(REPO, "out", "P0_output_residual.json"), encoding="utf-8"))
    s = res["summary"]

    w("\n## 3. 语料条数[机器]\n\n")
    w(f"- anchors **{len(t['anchors'])}**（portrait {sum(1 for a in t['anchors'] if a.get('trueRollDeg') is not None)} + upright 其余）"
      f" / straight **{len(t['straight'])}** / uprightSynthetic **{len(t['uprightSynthetic'])}** / rotated **{len(t['rotated'])}**\n")
    w(f"- `distinctAnchorPhotos` = **{gi['scoringDenominators']['distinctAnchorPhotos']}**\n")
    w(f"- 成片 composedCount = {s['composedCount']}；primaryCount(cn_big_1inch) = {s['primaryCount']}；scored = {s['scored']}\n")

    w("\n## 4. v2 分档：ACCEPTANCE 的 15 / 4 / 11[机器]\n\n")
    spec = s["primarySpec"]
    prim = [r for r in res["items"] if r.get("specId") == spec]
    at = lambda r: None if r.get("truthTiltDeg") is None else abs(r["truthTiltDeg"])
    DZ = s["deadZoneDeg"]
    outside = [r for r in prim if at(r) is not None and at(r) > DZ]
    band = [r for r in prim if at(r) is not None and DZ - 1 <= at(r) <= DZ + 1]
    band_out = [r for r in band if at(r) > DZ]
    unscored = [r for r in outside if r["end_to_end_status"] not in ("ok", "low_confidence")]
    w(f"- `specId={spec}`，`deadZoneDeg={DZ}`（来源：{s['deadZoneSource']}），`residualTolDeg={s['residualTolDeg']}`\n")
    w(f"- `|truth| > {DZ}` = **{len(outside)}** 条（去重 id {len({r['id'] for r in outside})}）\n")
    w(f"- 其中 9–11 边界带 = **{len(band_out)}** 条：{sorted(r['id'] for r in band_out)}\n")
    w(f"- ⇒ 参与判定 = **{len(outside) - len(band_out)}** 条\n")
    w(f"- 边界带全部（含死区内侧）n = {len(band)}：{sorted(r['id'] for r in band)}\n")
    w(f"- `deadZoneOutsideCount` = {s['deadZoneOutsideCount']}（**scored 口径**）；"
      f"`deadZoneBoundaryBand.n` = {s['deadZoneBoundaryBand']['n']}（**primary 口径**）—— 两者分母不同，不可相减\n")
    w(f"- 未计分的死区外行（全为 reliability_mismatch）：{[(r['id'], r['truthTiltDeg']) for r in unscored]}\n")

    w("\n### 边界带逐条挂牌（真值 / 估计 / 施加 / 残余）\n\n")
    w("| id | 真值 | 估计 | 施加 | 残余 | 状态 |\n|---|---|---|---|---|---|\n")
    for r in sorted(band, key=lambda x: x["id"]):
        w(f"| `{r['id']}` | {r['truthTiltDeg']} | {r.get('faceRollDeg')} | {r.get('straightenDeg')} "
          f"| {r['primary_tilt_deg']} | {r['end_to_end_status']} |\n")

    w("\n## 5. v2 违规（各 1 条，**都在边界带内**）[机器]\n\n")
    for k in ("deadZoneInsideViolations", "deadZoneOutsideViolations"):
        for d in s[k]:
            w(f"- `{k}`: {d}\n")
    w(f"- 两张表**不带带内标记** ⇒ 不得直接当 FAIL（ACCEPTANCE：带内只报数）。见 `out/QA_r4.md` §7 队列项 1\n")

    w("\n## 6. 量测失效逐条[机器]（门禁 qa_eyeline 回退在这 9 行取不到）\n\n")
    w("| id | 状态 | primary | 真值 | 施加 | m1 | m2 | m3 | m4 | spread | 方法数 |\n|---|---|---|---|---|---|---|---|---|---|---|\n")
    def g(r, k):
        v = r.get(k)
        return v.get("deg") if isinstance(v, dict) else None
    bad = [r for r in prim if r["end_to_end_status"] != "ok"]
    for r in sorted(bad, key=lambda x: x["id"]):
        f = lambda v: "—" if v is None else f"{v:.3f}"
        w(f"| `{r['id']}` | {r['end_to_end_status']} | {f(r.get('primary_tilt_deg'))} | {r.get('truthTiltDeg')} "
          f"| {f(r.get('straightenDeg'))} | {f(g(r,'m1_pupil'))} | {f(g(r,'m2_radon_yunet'))} "
          f"| {f(g(r,'m3_haar_eyeline'))} | {f(g(r,'m4_radon_haar'))} "
          f"| {r.get('methodSpreadDeg')} | {r.get('methodCount')} |\n")
    w(f"\n状态计数（{spec}）：ok {sum(1 for r in prim if r['end_to_end_status']=='ok')} / "
      f"low_confidence {sum(1 for r in prim if r['end_to_end_status']=='low_confidence')} / "
      f"reliability_mismatch {sum(1 for r in prim if r['end_to_end_status']=='reliability_mismatch')} / "
      f"unmeasured {sum(1 for r in prim if r['end_to_end_status']=='unmeasured')}\n")

    w("\n## 7. Radon 搜索轨端点被当成读数[机器]（span=16.0 是搜索边界，不是测量）\n\n")
    for r in res["items"]:
        m2 = r.get("m2_radon_yunet")
        if isinstance(m2, dict) and abs(float(m2.get("deg", 0))) > 15.0:
            w(f"- `{r['id']}` @ {r['specId']}: deg={m2['deg']:.4f} peak_ratio={m2.get('peak_ratio')} "
              f"span={m2.get('span')}\n")
    w("- 这些值进 `tiltAbsMaxDeg`；该字段自称'保守上界' ⇒ 拿它当上界是把搜索边界当真实大角\n")


if __name__ == "__main__":
    main()
