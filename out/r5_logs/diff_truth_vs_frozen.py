# -*- coding: utf-8 -*-
"""qa-batch：r5 重建的 `out/P0_truth.json` 与 r4 冻结版的**逐条比对**（输出 `out/r5_logs/truth_diff.txt`）。

为什么要它：team-lead 明令——真值（输入照片的倾角）**不是**对代码的测量，代码没改它就不该变。
指纹/溯源字段（`evaluatedState.*`）本来就该变，不算差异。**真值有一条对不上就停下报**。

三组分开列，不混：
  A 组 = 真值域（顶层除 `evaluatedState`/`endToEndResidual`/`gateInputs` 之外的全部）
         —— **必须零差异**，有差异即 exit 1；
  B 组 = `evaluatedState.**` —— 溯源，预期变；
  C 组 = `endToEndResidual.**` 与 `gateInputs.**` —— 派生块（内含重建后的产物摘要、
        产物 sha256、指纹）。这里**允许变的是"出处"类叶子**；若**数字叶子**变了，
        说明重测的读数动了，逐条列出来给人看。

冻结版的身份**先按 sha256 认**（`30f96c16…`），认错即抛：拿一份不是冻结版的快照当基线，
差出来的东西读起来完全正常却毫无意义。

用法：python out/r5_logs/diff_truth_vs_frozen.py > out/r5_logs/truth_diff.txt
"""
import hashlib
import json
import os
import re
import sys

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"
FROZEN = os.path.join(REPO, "out", "r5_logs", "truth_frozen_r4.json")
NEW = os.path.join(REPO, "out", "P0_truth.json")
FROZEN_SHA = "30f96c16e3d9b74ca26aa620be92a00f5228c76cf29b77e1cd317b07865070a4"

DERIVED = ("evaluatedState", "endToEndResidual", "gateInputs")
_HEX40 = re.compile(r"^[0-9a-f]{40}$")
_PROV_KEY = re.compile(
    r"sha256|sha1|fingerprint|fnv|blobHash|blobHashes|headCommit|headAt|commit|"
    r"roundValid|roundSelfValid|roundVerdict|generatedBy|generatedAt|mtime|"
    r"provenance|sourceSha|note", re.I)


def flat(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from flat(v, f"{path}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from flat(v, f"{path}[{i}]")
    else:
        yield path, node


def main():
    w = sys.stdout.write
    got = hashlib.sha256(open(FROZEN, "rb").read()).hexdigest()
    if got != FROZEN_SHA:
        raise SystemExit(f"冻结版认错：期望 {FROZEN_SHA}，盘上快照是 {got}。"
                         "拒绝在未知基线上出差分。")

    a = dict(flat(json.load(open(FROZEN, encoding="utf-8"))))
    b = dict(flat(json.load(open(NEW, encoding="utf-8"))))
    w("r5 `out/P0_truth.json` 对 r4 冻结版逐条比对\n")
    w(f"冻结版 sha256 = {FROZEN_SHA}（已按此值认基线）\n")
    w(f"新产物 sha256 = {hashlib.sha256(open(NEW, 'rb').read()).hexdigest()}\n")
    w("=" * 92 + "\n\n")

    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    diff = [(p, a[p], b[p]) for p in sorted(set(a) & set(b)) if a[p] != b[p]]

    def grp(p):
        top = p.split("/")[1] if p.startswith("/") else p
        return top if top in DERIVED else "A"

    ga = [d for d in diff if grp(d[0]) == "A"]
    gb = [d for d in diff if grp(d[0]) == "evaluatedState"]
    gc = [d for d in diff if grp(d[0]) in ("endToEndResidual", "gateInputs")]

    w(f"叶子总数：冻结版 {len(a)} / 新版 {len(b)}\n")
    w(f"仅冻结版有：{len(only_a)}；仅新版有：{len(only_b)}\n")
    if only_a:
        w("".join(f"  - 消失 {p}\n" for p in only_a[:20]))
    if only_b:
        w("".join(f"  + 新增 {p}\n" for p in only_b[:20]))

    w(f"\n## A 组 —— 真值域，**必须零差异**：{len(ga)} 条\n\n")
    for p, o, n in ga:
        w(f"- `{p}`: {o!r} -> {n!r}\n")
    w("（空 = 逐条一致）\n" if not ga else "")

    w(f"\n## B 组 —— `evaluatedState.**` 溯源，预期变：{len(gb)} 条\n\n")
    for p, o, n in gb:
        w(f"- `{p}`: {str(o)[:60]} -> {str(n)[:60]}\n")

    w(f"\n## C 组 —— 派生块（`endToEndResidual` / `gateInputs`）：{len(gc)} 条\n")
    w("其中**非出处类**（即数字读数）的差异单列在下面，必须逐条解释：\n\n")
    value_changes = []
    for p, o, n in gc:
        leaf = p.rsplit("/", 1)[-1]
        is_prov = bool(_PROV_KEY.search(leaf)) or (isinstance(o, str) and _HEX40.match(o or ""))
        if not is_prov:
            value_changes.append((p, o, n))
        w(f"- {'[出处]' if is_prov else '[**读数**]'} `{p}`: {str(o)[:60]} -> {str(n)[:60]}\n")
    w(f"\nC 组里读数字叶子变化的条数：**{len(value_changes)}**\n")
    for p, o, n in value_changes:
        w(f"  * `{p}`: {o} -> {n}\n")

    w("\n" + "=" * 92 + "\n")
    if ga:
        w(f"判决：**真值域有 {len(ga)} 条差异 —— 停，报 team-lead。**\n")
        return 1
    w("判决：真值域零差异；溯源字段如预期变化；"
      f"C 组读数叶子变化 {len(value_changes)} 条。\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
