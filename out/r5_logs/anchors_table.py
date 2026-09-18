# -*- coding: utf-8 -*-
"""qa-batch：r5 的 13 条锚点——真值 vs 实测（输出 `out/r5_logs/anchors_table.txt`）。

给 team-lead 第 3 项要的**逐 id 读数**，不是"通过"两个字。
口径：真值 = `out/P0_truth.json` 的 `anchors[*].trueRollDeg`（输入照片的倾角，纸面真值）；
      实测 = `out/P0_output_residual.json` 里同 id 且 `specId=cn_big_1inch` 的行：
        `faceRollDeg`（估角器读数）、`straightenDeg`（死区内应为 0）、
        `primary_tilt_deg`（成片反推）、`truthConsistencyDeg`（成片反推 − 真值）。

**全部 13 条真值都在死区内**（最大 |−8.01°| 是 c08）⇒ 这一栏是**覆盖证据**，
不是死区外的读数，两者不可混为一谈，故本表头写明。
"""
import json
import os
import sys

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"


def main():
    w = sys.stdout.write
    t = json.load(open(os.path.join(REPO, "out", "P0_truth.json"), encoding="utf-8"))
    res = json.load(open(os.path.join(REPO, "out", "P0_output_residual.json"), encoding="utf-8"))
    spec = res["summary"]["primarySpec"]
    dz = res["summary"]["deadZoneDeg"]
    tol = res["summary"]["residualTolDeg"]
    prim = {r["id"]: r for r in res["items"] if r.get("specId") == spec}

    w("r5 锚点：真值 vs 实测（`out/P0_truth.json` × `out/P0_output_residual.json`）\n")
    w(f"specId={spec}；死区 deadZoneDeg={dz}；容差 residualTolDeg={tol}\n")
    w("**13 条真值全部落在死区内**（最大 |真值| = 8.01°，c08）⇒ 本表是覆盖证据，"
      "不是死区外读数。\n")
    w("=" * 100 + "\n\n")
    w("| id | trueRollDeg | faceRollDeg | straightenDeg | primary_tilt_deg | "
      "truthConsistencyDeg | 状态 |\n|---|---|---|---|---|---|---|\n")
    n = 0
    outside = []
    for a in t["anchors"]:
        tr = a.get("trueRollDeg")
        if tr is None:
            continue
        n += 1
        r = prim.get(a["id"])
        if r is None:
            w(f"| `{a['id']}` | {tr} | — | — | — | — | **无该 specId 行** |\n")
            continue
        if abs(tr) > dz:
            outside.append(a["id"])
        w(f"| `{a['id']}` | {tr} | {r.get('faceRollDeg')} | {r.get('straightenDeg')} | "
          f"{r.get('primary_tilt_deg')} | {r.get('truthConsistencyDeg')} | "
          f"{r['end_to_end_status']} |\n")
    mx = max(abs(a["trueRollDeg"]) for a in t["anchors"] if a.get("trueRollDeg") is not None)
    w(f"\n有真值的锚点：**{n}** 条；最大 |真值| = **{mx}°**；"
      f"落在死区外（|真值| > {dz}）的：{outside if outside else '0 条'}\n")
    st = {}
    for a in t["anchors"]:
        if a.get("trueRollDeg") is None:
            continue
        r = prim.get(a["id"])
        if r:
            st[r["end_to_end_status"]] = st.get(r["end_to_end_status"], 0) + 1
    w(f"状态分布：{st}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
