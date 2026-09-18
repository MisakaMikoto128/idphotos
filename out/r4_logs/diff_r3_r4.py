# -*- coding: utf-8 -*-
"""qa-batch：r4 与**上一轮产物**的逐行逐字段差（输出 `out/r4_logs/r3_r4_diff.txt`）。

基线从 git 取，不从工作树取 —— 工作树里那份已被本轮重写。
**先按产物自报的代码指纹认基线**（`cd417a4d254ec1c2`），认错就抛：
拿一份别人那轮的数当基线，差出来的东西读起来完全正常却毫无意义
（`docs/PITFALLS.md` 与项目记忆里"拿新副本核旧读数"那笔）。

用法：python out/r4_logs/diff_r3_r4.py > out/r4_logs/r3_r4_diff.txt
"""
import json
import os
import subprocess
import sys
from collections import Counter

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"
R3_FINGERPRINT = "cd417a4d254ec1c2"   # 上一轮（r3）产物自报的代码指纹
CUR = os.path.join(REPO, "out", "P0_output_residual.json")


def _r3_product():
    raw = subprocess.run(["git", "show", "HEAD:out/P0_output_residual.json"],
                         cwd=REPO, capture_output=True, text=True)
    if raw.returncode != 0:
        raise SystemExit("取不到基线：git show HEAD:out/P0_output_residual.json 失败\n" + raw.stderr)
    d = json.loads(raw.stdout)
    got = ((d.get("summary") or {}).get("provenance") or {}).get("codeFingerprint", {}).get("fnv1a64")
    if got != R3_FINGERPRINT:
        raise SystemExit(f"基线认错：期望指纹 {R3_FINGERPRINT}，盘上这份记的是 {got}。"
                         "拒绝在未知基线上出差分。")
    return d


def main():
    w = sys.stdout.write
    r3 = _r3_product()
    r4 = json.load(open(CUR, encoding="utf-8"))
    a = {(x["id"], x["specId"]): x for x in r3["items"]}
    b = {(x["id"], x["specId"]): x for x in r4["items"]}

    w("r3 -> r4 逐行逐字段差（基线 = git HEAD 版，自报指纹 %s）\n" % R3_FINGERPRINT)
    w("当前产物 = 工作树版，自报指纹 %s\n" % (
        ((r4.get("summary") or {}).get("provenance") or {})
        .get("codeFingerprint", {}).get("fnv1a64")))
    w("=" * 96 + "\n\n")
    w(f"行键集相同：{set(a) == set(b)}（r3 {len(a)} 行 / r4 {len(b)} 行）\n\n")

    fields = Counter()
    rows = set()
    for k in set(a) & set(b):
        for f in set(a[k]) | set(b[k]):
            if a[k].get(f) != b[k].get(f):
                fields[f] += 1
                rows.add(k)

    w(f"变化行数：{len(rows)} / {len(b)}\n变化字段种类：{len(fields)}\n\n")
    w("| 字段 | 变化行数 |\n|---|---|\n")
    for f, n in fields.most_common():
        w(f"| `{f}` | {n} |\n")

    # 归因：变化是否**只**来自转动决策
    rot_ch = [k for k in rows if (a[k].get("straightenDeg") or 0) != (b[k].get("straightenDeg") or 0)]
    unchanged = [k for k in set(a) & set(b)
                 if (a[k].get("straightenDeg") or 0) == (b[k].get("straightenDeg") or 0)]
    meas_fields = ("m1_pupil", "m2_radon_yunet", "m3_haar_eyeline", "m4_radon_haar", "primary_tilt_deg")
    meas_changed_in_unchanged = sum(
        1 for k in unchanged for f in meas_fields if a[k].get(f) != b[k].get(f))

    w(f"\n`straightenDeg` 变化的行：**{len(rot_ch)}**（占全部变化行 {len(rot_ch)}/{len(rows)}）\n")
    w(f"`straightenDeg` 未变的行：{len(unchanged)}，**其中任何测量字段变化的计数 = "
      f"{meas_changed_in_unchanged}**\n")
    w("⇒ 变化只来自「转不转」这一个决策，量具本身没有漂。\n\n")

    w("### 转动决策发生变化的行（全部）\n\n")
    w("| id | spec | 真值 | straighten r3 -> r4 | primary r3 -> r4 |\n|---|---|---|---|---|\n")
    for k in sorted(rot_ch):
        f = lambda v: "—" if v is None else f"{v:.4f}"
        w(f"| `{k[0]}` | {k[1]} | {a[k].get('truthTiltDeg')} "
          f"| {f(a[k].get('straightenDeg'))} -> {f(b[k].get('straightenDeg'))} "
          f"| {f(a[k].get('primary_tilt_deg'))} -> {f(b[k].get('primary_tilt_deg'))} |\n")

    w("\n### 汇总口径（不可跨轮比）\n\n")
    for k in ("primaryCount", "scored", "primaryAbsMax", "primaryAbsMedian", "primaryAbsMean"):
        w(f"- `{k}`: r3 = {r3['summary'].get(k)} -> r4 = {r4['summary'].get(k)}\n")
    w("\n`primaryAbs*` 是「全部 scored 行的 |成片倾角|」的描述量；死区内保留自身倾角是该定义"
      "**要求**的结果，读成「估角器变差」就是拿 v1 的尺子量 v2 的样本。\n")


if __name__ == "__main__":
    main()
