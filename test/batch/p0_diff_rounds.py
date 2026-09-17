# -*- coding: utf-8 -*-
"""qa-batch：两轮 P0 测量结果的逐项比对。

用法（项目根）：
    python test/batch/p0_diff_rounds.py <上轮目录> [本轮目录]

`<上轮目录>` 里放同名的快照文件（如 `out/P0_r1_backup/`），默认本轮目录是 `out/`。
只读，不改任何东西。

为什么要它：重跑之后要报的东西全是**差分**（哪些 id 的 rollSource 变了、
样本在判据之间迁移了、分母怎么变），手工比对容易漏项，而"漏掉一条迁移"
正是条款 7 要防的事（样本静默消失）。
"""
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = "cn_big_1inch"


def _load(d, name):
    p = os.path.join(d, name)
    if not os.path.exists(p):
        return None
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def _items(doc):
    if not doc:
        return {}
    return {r["id"]: r for r in doc.get("items", []) if r.get("specId") == SPEC}


def _jsonl(d, name):
    p = os.path.join(d, name)
    if not os.path.exists(p):
        return {}
    out = {}
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            if r.get("specId") == SPEC:
                out[r["id"]] = r
    return out


def _jsonl_cov(d, name):
    """覆盖率工件：**没有 specId 字段**，不能套用 _jsonl 的那个过滤条件
    （否则会静默返回空表，看着像"这一侧缺文件"）。"""
    p = os.path.join(d, name)
    if not os.path.exists(p):
        return {}
    out = {}
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            out[r["id"]] = r
    return out


def _truth_by_id(doc):
    """{id: (truthTiltDeg, straightenDeg, primary_tilt_deg, rollSource)}"""
    out = {}
    if not doc:
        return out
    for key in ("anchors", "straight", "uprightSynthetic", "rotated"):
        for a in doc.get(key, []) or []:
            e = a.get("end_to_end") or {}
            out[a["id"]] = {
                "truth": a.get("truth_apply_deg"),
                "applied": e.get("applied_straighten_deg"),
                "out": e.get("output_tilt_deg"),
                "src": e.get("roll_source"),
                "status": e.get("status"),
                "truthConsistency": e.get("truth_consistency_deg"),
            }
    return out


def _tag(kind):
    """给每一节标注它的结论强度。

    r1 **自身是拼起来的**：P0.1a/2/3a/3b 来自当时那份工作树产出的
    `P0_compose_items.jsonl`，而 P0.5a（dev_selfcheck）由 gatekeeper 用**本机当前**
    工作树编译。所以 r1 不是一个对任何单一代码状态的判决 —— **版本不可标识**。

    后果：`r1 -> r2` 的**集合归属**结论（某个样本从哪一栏移到哪一栏）是定性事实，
    不依赖版本标识，**可靠**；而**数值差**（rollDeg 差了多少、分母变了几个）会同时
    混进"代码变了"和"基准本来就不可标识"两个成因，**只能作指示性用途**，
    不得据此说"这个改动导致了 ±X"。
    """
    return {"可靠": "【可靠：集合归属，不依赖版本标识】",
            "指示": "【指示性：数值差，版本不可标识，不得作因果证据】",
            "字节": "【可靠：输入字节哈希】"}[kind]


def main():
    prev = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "out", "P0_r1_backup")
    cur = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "out")
    print(f"prev = {prev}\ncur  = {cur}\n")
    print("=" * 72)
    print("限定：上一轮（r1）**版本不可标识** —— 它是拼起来的：")
    print("  P0.1a/2/3a/3b 来自当时工作树产出的 P0_compose_items.jsonl，")
    print("  P0.5a(dev_selfcheck) 来自本机**当前**工作树编译。")
    print("  因此 r1->r2 的**数值差**只能作【指示性】用途（'这段代码前后变了'），")
    print("  **不得**作【证据性】用途（'这个改动导致了 ±X'）。")
    print("  **集合归属**的迁移（某样本换栏、新增/移出）是定性事实，仍然可靠。")
    print("  每一节上方都标注了它的结论强度。")
    print("=" * 72)
    print()

    pt, ct = _load(prev, "P0_truth.json"), _load(cur, "P0_truth.json")
    pr, cr = _load(prev, "P0_output_residual.json"), _load(cur, "P0_output_residual.json")
    pc, cc = _load(prev, "P0_coverage_post.json"), _load(cur, "P0_coverage_post.json")
    ph, ch = _load(prev, "P0_input_hashes.json"), _load(cur, "P0_input_hashes.json")

    # ---- 1. 输入字节是否没变 ----
    print("=" * 72)
    print("1. 输入字节（夹具是否被重新生成）" + _tag("字节"))
    a, b = (ph or {}).get("byId") or {}, (ch or {}).get("byId") or {}
    if not a or not b:
        print("   [跳过] 有一侧缺 byId")
    else:
        changed = sorted(k for k in a if k in b and a[k] != b[k])
        only_prev = sorted(set(a) - set(b))
        only_cur = sorted(set(b) - set(a))
        print(f"   prev={len(a)} cur={len(b)} 变动={len(changed)} "
              f"仅上轮={len(only_prev)} 仅本轮={len(only_cur)}")
        for k in changed:
            print(f"     CHANGED {k}: {a[k][:16]} -> {b[k][:16]}")
        for k in only_prev:
            print(f"     仅上轮有: {k}")
        for k in only_cur:
            print(f"     仅本轮有: {k}")
        if not (changed or only_prev or only_cur):
            print("   -> 完全一致，夹具未被重新生成")

    # ---- 2. rollSource 逐 id 迁移 ----
    print("=" * 72)
    print("2. rollSource 迁移（逐 id）" + _tag("可靠"))
    pi, ci = _truth_by_id(pt), _truth_by_id(ct)
    if not pi or not ci:
        print("   [跳过] 有一侧 truth 缺 end_to_end")
    else:
        mig = [(k, pi[k]["src"], ci[k]["src"]) for k in sorted(ci)
               if k in pi and pi[k]["src"] != ci[k]["src"]]
        print(f"   迁移 {len(mig)} 条：")
        for k, o, n in mig:
            print(f"     {k:<12} {o:<12} -> {n}")
        if not mig:
            print("   -> 无迁移")

        # ---- 3. 判据归属迁移（P0.3a 精度栏 <-> P0.3b 覆盖率栏）----
        print("=" * 72)
        print("3. 判据归属迁移（条款 7：样本不得在栏间静默消失）" + _tag("可靠"))

        def precision_viol(d):
            # 第 7 条：不可计分的样本要扣除，否则会把"量不出来"混进"量出来是错的"。
            return {k for k, v in d.items()
                    if v["src"] == "pupil" and v["out"] is not None
                    and v.get("status") in ("ok", "low_confidence")
                    and abs(v["out"]) > 1.5}
        def coverage_viol(d):
            return {k for k, v in d.items()
                    if v["truth"] is not None and abs(v["truth"]) > 1.5
                    and v["src"] != "pupil"}
        for name, fn in (("P0.3a 精度违规", precision_viol),
                         ("P0.3b 覆盖率违规", coverage_viol)):
            s_old, s_new = fn(pi), fn(ci)
            print(f"   {name}: {len(s_old)} -> {len(s_new)}")
            for k in sorted(s_new - s_old):
                print(f"      [+新增] {k}")
            for k in sorted(s_old - s_new):
                print(f"      [-移出] {k}")
            print(f"      本轮集合: {sorted(s_new)}")

        # ---- 4. 分母变化 ----
        print("=" * 72)
        print("4. 分母变化（计分口径第 1/7 条）" + _tag("指示"))
        pg = (pt or {}).get("gateInputs", {}).get("scoringDenominators")
        cg = (ct or {}).get("gateInputs", {}).get("scoringDenominators")
        print(f"   prev: {json.dumps(pg, ensure_ascii=False)}")
        print(f"   cur : {json.dumps(cg, ensure_ascii=False)}")

        # ---- 5. 不可计分样本变化 ----
        print("=" * 72)
        print("5. 不可计分样本（第 7 条：逐条列出并归类）" + _tag("可靠") + "（计数部分" + _tag("指示") + "）")
        pn = (pt or {}).get("gateInputs", {}).get("notScorableClassification", {}).get("items", [])
        cn = (ct or {}).get("gateInputs", {}).get("notScorableClassification", {}).get("items", [])
        pd = {i["id"]: i["class"] for i in pn}
        cd = {i["id"]: i["class"] for i in cn}
        print(f"   prev n={len(pd)} {pd}")
        print(f"   cur  n={len(cd)} {cd}")
        for k in sorted(set(pd) - set(cd)):
            print(f"      [-不再不可计分] {k} ({pd[k]})")
        for k in sorted(set(cd) - set(pd)):
            print(f"      [+新不可计分]   {k} ({cd[k]})")
        for k in sorted(set(pd) & set(cd)):
            if pd[k] != cd[k]:
                print(f"      [归类变化] {k}: {pd[k]} -> {cd[k]}")

    # ---- 6. 语料 rollSource 分布 ----
    print("=" * 72)
    print("6. rollSource 分布（按 corpus）" + _tag("指示"))
    for label, doc in (("prev", pc), ("cur", cc)):
        if not doc:
            print(f"   {label}: [缺]")
            continue
        print(f"   {label}: {json.dumps(doc.get('byCorpus'), ensure_ascii=False)}")

    # ---- 7. 重点 id 明细 ----
    print("=" * 72)
    print("7. 重点 id 明细（成片台命名空间；golden 在覆盖率台，见第 9 节）" + _tag("指示"))
    watch = ["c06_d-3", "c01_d+10", "c04_d-5", "c04_d-10", "c08_d+5", "c07"]
    print(f"   {'id':<12}{'src(prev->cur)':<28}{'applied':<22}{'out':<22}{'status'}")
    for k in watch:
        o, n = pi.get(k), ci.get(k)
        if not o and not n:
            print(f"   {k:<12} [两轮都无 end_to_end]")
            continue
        so = (o or {}).get("src", "-")
        sn = (n or {}).get("src", "-")
        ao = "None" if not o or o.get("applied") is None else f"{o['applied']:.3f}"
        an = "None" if not n or n.get("applied") is None else f"{n['applied']:.3f}"
        oo = "None" if not o or o.get("out") is None else f"{o['out']:.3f}"
        on = "None" if not n or n.get("out") is None else f"{n['out']:.3f}"
        print(f"   {k:<12}{(so + ' -> ' + sn):<28}{(ao + ' -> ' + an):<22}"
              f"{(oo + ' -> ' + on):<22}{(n or o).get('status')}")

    # ---- 9. 覆盖率命名空间：rollDeg 数值变化（竞争者门的影响面）----
    #
    # 注意两套 id 命名空间不同，别混：
    #   覆盖率台：`anchor_c07` / `rot_c07_d-3` / `golden_g01` / `<pictures slug>`
    #   成片台  ：`c07` / `c07_d-3` / （不含 golden 与 pictures）
    # 竞争者门只影响**估角值**，在覆盖率台才看得到。
    print("=" * 72)
    print("9. 覆盖率台 rollDeg 数值变化（新竞争者门的影响面）" + _tag("指示"))
    pcov, ccov = _jsonl_cov(prev, "P0_coverage_items.jsonl"), _jsonl_cov(cur, "P0_coverage_items.jsonl")
    if not pcov or not ccov:
        print("   [跳过] 有一侧缺 coverage items")
    else:
        watch_cov = ["golden_g01", "golden_g02", "golden_g03", "golden_g04",
                     "golden_g05", "golden_g06", "golden_g07", "golden_g08",
                     "anchor_c07", "anchor_c11"]
        print(f"   {'id':<14}{'src(prev->cur)':<28}{'rollDeg(prev->cur)'}")
        for k in watch_cov:
            o, n = pcov.get(k), ccov.get(k)
            if not o and not n:
                print(f"   {k:<14}[两轮都缺]")
                continue
            so, sn = (o or {}).get("rollSource", "-"), (n or {}).get("rollSource", "-")
            ro = (o or {}).get("rollDeg")
            rn = (n or {}).get("rollDeg")
            fo = "None" if ro is None else f"{ro:.3f}"
            fn = "None" if rn is None else f"{rn:.3f}"
            star = ""
            if ro is not None and rn is not None and abs(ro - rn) > 1e-9:
                star = f"   <== 变了 {rn - ro:+.3f}"
            print(f"   {k:<14}{(so + ' -> ' + sn):<28}{fo} -> {fn}{star}")
        # 全体 flip 汇总
        flips = [(k, pcov[k].get("rollSource"), ccov[k].get("rollSource"))
                 for k in sorted(set(pcov) & set(ccov))
                 if pcov[k].get("rollSource") != ccov[k].get("rollSource")]
        print(f"\n   全局 rollSource 迁移 {len(flips)} 条：")
        for k, o, n in flips:
            print(f"     {k:<26} {o} -> {n}")
        if not flips:
            print("     -> 无迁移")
        moved = [(k, pcov[k].get("rollDeg"), ccov[k].get("rollDeg"))
                 for k in sorted(set(pcov) & set(ccov))
                 if pcov[k].get("rollDeg") is not None
                 and ccov[k].get("rollDeg") is not None
                 and abs(pcov[k]["rollDeg"] - ccov[k]["rollDeg"]) > 0.05]
        print(f"   估角值变化 >0.05° 的 {len(moved)} 条（前 20）：")
        for k, o, n in moved[:20]:
            print(f"     {k:<26} {o:+.3f} -> {n:+.3f}  ({n - o:+.3f})")

    # ---- 10. 汇总数字 ----
    print("=" * 72)
    print("10. 汇总" + _tag("指示"))
    for label, doc in (("prev", pr), ("cur", cr)):
        if not doc:
            print(f"   {label}: [缺]")
            continue
        s = doc.get("summary", {})
        print(f"   {label}: {json.dumps(s, ensure_ascii=False)[:400]}")


if __name__ == "__main__":
    main()
