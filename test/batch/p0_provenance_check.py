# -*- coding: utf-8 -*-
"""链路里的**早期出口**：产出物带没带"可归属"的代码指纹，以及域对不对。

为什么要有它：整条链里最贵的一步是覆盖率台（约 85 分钟）。若它跑完才发现
成片台的产物没盖指纹，那就是拿 85 分钟换一个"整轮作废"。本脚本按阶段跑，
**在前面就判死**，不把错误带到最贵的那一步之后。

    python test/batch/p0_provenance_check.py after-compose    # ~17 分钟后就跑
    python test/batch/p0_provenance_check.py after-coverage   # 覆盖率台跑完再跑
    python test/batch/p0_provenance_check.py final            # 收尾，出逐文件清单

判什么（每条都是"能不能被机器核对"，不是"看起来对不对"）：

  1. 文件在、能解析出 JSON 对象；
  2. 门禁定死的指针能取到指纹对象，且有 `files` / `fnv1a64` / `blobHashes`；
  3. `blobHashes` 里**没有占位值**（形状必须是 git 的 40/64 位十六进制）
     —— 算不出的指纹若退化成 `''`/`'unknown'`，两份不同的代码会互相判等；
  4. 记录的文件集与**当前树**枚举出的被测集**逐条相同**（不是数目相同）；
  5. 记录的 `fnv1a64` 与"拿它记录的哈希重算"一致，且与"当前树现算"一致
     —— 后者说明**被测代码自测量以来没变**；
  6. 逐行 jsonl（自己没有 provenance）用 summary 里记的 `itemsSha256` 复核
     —— "同一个 run 写的所以应该没问题"是推断，摘要对得上才是记录。
  7. **成片真的在盘上**（`after-compose` 起就查）：`outcome == 'ok'` 的行，
     它的 `composed` 路径必须存在且非空。**"记录了 ok" 与 "文件真的在" 是两件事**
     —— `out/P0_anchors/composed/` 现存 93/110，而 `P0_compose_items.jsonl` 里
     110 行全是 `ok`、`P0_compose_summary.json` 也写着 `ok: 110`（两次事故同形）。
     jsonl 与 summary 是同一次运行一起写的，**它们互相自洽与文件是否存在无关**，
     所以上面 1–6 条全过，17 张成片照样可以不在。

退出码非 0 = 不要往下跑。它**不判 PASS/FAIL**，只判"这份数据能不能被归属、
以及它声称产出的东西是不是真的在"。
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import code_fingerprint as CF  # noqa: E402

REPO = CF.REPO
OUT = os.path.join(REPO, "out")

# 门禁的 `OutputBinding`（tools/gate/provenance.dart）定死的指针。
BOUND = {
    "P0_compose_summary.json": ["provenance", "codeFingerprint"],
    "P0_output_residual.json": ["summary", "provenance", "codeFingerprint"],
    "P0_alpha_holes.json": ["provenance", "codeFingerprint"],
    "P0_coverage_post.json": ["provenance", "codeFingerprint"],
}

# 逐行 jsonl：自己没有 provenance，靠它所属 summary 里的 `itemsSha256` 绑定。
# 注意指针指向整个 `provenance` 对象，**不是** `codeFingerprint` ——
# `itemsSha256` 是 `codeFingerprint` 的兄弟键，指到指纹对象上会永远取不到。
BIND = {
    "P0_compose_summary.json": ["provenance"],
    "P0_coverage_post.json": ["provenance"],
}
ITEMS = {
    "P0_compose_items.jsonl": "P0_compose_summary.json",
    "P0_coverage_items.jsonl": "P0_coverage_post.json",
}

STAGES = {
    "after-compose": ["P0_compose_summary.json"],
    "after-coverage": ["P0_compose_summary.json", "P0_coverage_post.json"],
    "final": list(BOUND),
}

_HEX40 = set("0123456789abcdef")


def _load(name):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        return None, "文件不存在"
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh), None
    except Exception as e:  # noqa: BLE001
        return None, f"存在但解析不出 JSON：{e}"


def _dig(obj, ptr):
    cur = obj
    for k in ptr:
        if not isinstance(cur, dict):
            return None, f"路径在 {k!r} 处断掉（上层不是对象）"
        if k not in cur:
            return None, f"缺键 {k!r}"
        cur = cur[k]
    return cur, None


def _is_blob(s):
    return isinstance(s, str) and len(s) in (40, 64) and set(s) <= _HEX40


def _check_bound(name, fp_now):
    """返回 (问题列表, 该产物记录的文件集 或 None, 记录指纹 或 None)。"""
    prob = []
    doc, err = _load(name)
    if doc is None:
        return [f"{name}: {err}"], None, None
    ptr = BOUND[name]
    fp, err = _dig(doc, ptr)
    if fp is None:
        return [f"{name}: `{'/'.join(ptr)}` 取不到 —— {err}"], None, None
    if not isinstance(fp, dict):
        return [f"{name}: `{'/'.join(ptr)}` 不是对象（{type(fp).__name__}）"], None, None

    files, fnv, blobs = fp.get("files"), fp.get("fnv1a64"), fp.get("blobHashes")
    if not isinstance(blobs, dict) or not blobs:
        return [f"{name}: `blobHashes` 缺失或为空"], None, fp
    bad = sorted(k for k, v in blobs.items() if not _is_blob(v))
    if bad:
        prob.append(f"{name}: blobHashes 里有 {len(bad)} 个占位/非法值"
                    f"（例如 {bad[0]}={blobs[bad[0]]!r}）—— 算不出的指纹会互相判等")
    if isinstance(files, int) and files != len(blobs):
        prob.append(f"{name}: `files`={files} 与 blobHashes 条数 {len(blobs)} 不一致")

    # 4. 域逐条比对（不是比数目）
    recorded = set(blobs)
    current = set(fp_now["blobHashes"])
    missing = sorted(current - recorded)      # 当前树有、记录没有
    extra = sorted(recorded - current)        # 记录有、当前树没有
    if missing:
        prob.append(f"{name}: 域**少记 {len(missing)} 条**（当前树有、记录没有）："
                    + "、".join(missing[:6]) + (" …" if len(missing) > 6 else ""))
    if extra:
        prob.append(f"{name}: 域**多记 {len(extra)} 条**（记录有、当前树没有）："
                    + "、".join(extra[:6]) + (" …" if len(extra) > 6 else ""))
    # 记录的哈希与当前树同路径的 blob 是否相同
    diff = sorted(k for k in (recorded & current) if blobs[k] != fp_now["blobHashes"][k])
    if diff:
        prob.append(f"{name}: 有 {len(diff)} 个文件的 blob 与当前树不同"
                    f"（例如 {diff[0]}）—— 测量之后被测代码改过")

    # 5. fnv 自洽（拿记录的哈希重算）+ 与当前树一致
    joined = "\n".join(f"{k}:{blobs[k]}" for k in sorted(recorded))
    recomputed = CF.fnv1a64_hex(joined)
    if isinstance(fnv, str) and fnv != recomputed:
        prob.append(f"{name}: 记录的 fnv1a64={fnv} 与**拿记录的哈希重算**的 "
                    f"{recomputed} 不一致 —— 指纹字段与哈希集不是同一份")
    if isinstance(fnv, str) and fnv != fp_now["fnv1a64"]:
        prob.append(f"{name}: 记录的 fnv1a64={fnv} ≠ 当前树现算的 "
                    f"{fp_now['fnv1a64']} —— 被测代码自测量以来变过")
    return prob, recorded, fp


def _check_items(name, summary_name, prob):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        prob.append(f"{name}: 文件不存在")
        return
    doc, err = _load(summary_name)
    if doc is None:
        prob.append(f"{name}: 无法复核 —— 所属 summary {summary_name} {err}")
        return
    fp, err = _dig(doc, BIND[summary_name])
    if fp is None:
        prob.append(f"{name}: 无法复核 —— {summary_name} 取不到 provenance（{err}）")
        return
    want = fp.get("itemsSha256")
    if not isinstance(want, str) or not want:
        prob.append(f"{name}: {summary_name} 里没有 `itemsSha256` —— 这份 jsonl "
                    "**没有任何东西把它绑定到当轮运行**，下游不得当成当轮数据")
        return
    with open(p, "rb") as fh:
        got = hashlib.sha256(fh.read()).hexdigest()
    if got != want:
        prob.append(f"{name}: 字节摘要对不上 —— summary 记 {want[:16]}…，"
                    f"盘上实测 {got[:16]}…；这份 jsonl 不属于本次运行")


def _load_jsonl(name):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        return None, "文件不存在"
    rows = []
    try:
        with open(p, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception as e:  # noqa: BLE001
                    return None, f"第 {i} 行解析不出 JSON：{e}"
    except Exception as e:  # noqa: BLE001
        return None, f"读不出：{e}"
    return rows, None


def _check_compose_artifacts(prob):
    """成片存在性 + 条数一致性。**这是"记录了 ok"与"文件真的在"之间的那道缝。**

    为什么必须在早期出口就查：`out/P0_anchors/composed/` 现为 93/110，而 jsonl 的
    110 行 `outcome` 全是 `ok`、summary 写着 `ok: 110`。截断类事故（脏树轮覆盖，
    见 `docs/PITFALLS.md`）产出的正是这种状态 —— 一路自洽，只是文件不在。
    若等到成片残余测完才发现，已经烧掉了后面每一步。
    """
    rows, err = _load_jsonl("P0_compose_items.jsonl")
    if rows is None:
        prob.append(f"P0_compose_items.jsonl: {err}")
        return
    summary, serr = _load("P0_compose_summary.json")

    ok_rows = [r for r in rows if r.get("outcome") == "ok"]
    # 7a. 逐条查成片存在且非空 —— **逐条打印，不只报个数**
    bad = []
    for r in ok_rows:
        rel = r.get("composed")
        if not rel:
            bad.append((r.get("id"), r.get("specId"), "(缺 composed 字段)"))
            continue
        p = os.path.join(REPO, *str(rel).replace("\\", "/").split("/"))
        if not os.path.exists(p):
            bad.append((r.get("id"), r.get("specId"), f"{rel} —— **不存在**"))
        elif os.path.getsize(p) == 0:
            bad.append((r.get("id"), r.get("specId"), f"{rel} —— **0 字节**"))
    if bad:
        prob.append(
            f"P0_compose_items.jsonl: {len(bad)}/{len(ok_rows)} 行 `outcome=ok` "
            "但成片不在盘上或为空（**记录了 ok ≠ 文件真的在**）：")
        for i, s, d in bad[:40]:
            prob.append(f"      {i} [{s}] {d}")
        if len(bad) > 40:
            prob.append(f"      …另有 {len(bad) - 40} 条")

    # 7b. 条数与 summary 声明的一致（声明缺了就报"无法核对"，不当成通过）
    ids = [r.get("id") for r in rows]
    pairs = [(r.get("id"), r.get("specId")) for r in rows]
    if len(set(pairs)) != len(pairs):
        dup = sorted({p for p in pairs if pairs.count(p) > 1})
        prob.append(f"P0_compose_items.jsonl: (id, specId) 有重复：{dup[:8]}")

    def declared(key):
        if not isinstance(summary, dict):
            return None
        return summary.get(key)

    exp, nids, nok = declared("expectedOutputs"), declared("cases"), declared("ok")
    if exp is None or nids is None or nok is None:
        prob.append(
            "P0_compose_summary.json: 缺 "
            + "、".join(k for k, v in (("expectedOutputs", exp), ("cases", nids),
                                      ("ok", nok)) if v is None)
            + " —— **完整性无从核对**（不能把「读不到」当成「条数对」）")
    else:
        if len(rows) != exp:
            prob.append(f"P0_compose_items.jsonl: 行数 {len(rows)} ≠ summary "
                        f"expectedOutputs {exp}")
        if len(set(ids)) != nids:
            prob.append(f"P0_compose_items.jsonl: 去重后 id 数 {len(set(ids))} "
                        f"≠ summary.cases {nids}")
        if len(ok_rows) != nok:
            prob.append(f"P0_compose_items.jsonl: outcome=ok 行数 {len(ok_rows)} "
                        f"≠ summary.ok {nok} —— 两个消费者读的是同一件事却说不同数")
    print(f"  {'OK  ' if not bad else 'FAIL'} 成片存在性："
          f"{len(ok_rows) - len(bad)}/{len(ok_rows)} 张在盘上（行数 {len(rows)}，"
          f"去重 id {len(set(ids))}）")


def main():
    global OUT
    argv = sys.argv[1:]
    # `--out <dir>` 只给自测用：把同一套判据指向一份**合成**产物目录，
    # 好让"能变绿"也被证明过一次 —— 只红过、从没绿过的检查，与没接线的检查
    # 报出来是同一个结果。
    if "--out" in argv:
        i = argv.index("--out")
        OUT = os.path.abspath(argv[i + 1])
        del argv[i:i + 2]
    stage = argv[0] if argv else "final"
    if stage not in STAGES:
        print(f"未知阶段 {stage!r}，可用：{'、'.join(STAGES)}")
        return 2

    fp_now = CF.code_fingerprint()
    print(f"阶段 [{stage}]　当前树被测集 {fp_now['files']} 个文件，"
          f"fnv={fp_now['fnv1a64']}，HEAD={(fp_now['headCommit'] or '?')[:9]}")
    print(f"被测代码全部已提交：{fp_now['allCommitted']}"
          + (f"　未提交：{'、'.join(fp_now['uncommittedMeasuredFiles'])}"
             if fp_now["uncommittedMeasuredFiles"] else ""))
    print()

    prob, done = [], []
    for name in STAGES[stage]:
        p, _, _ = _check_bound(name, fp_now)
        prob += p
        done.append(name)
        print(f"  {'OK  ' if not p else 'FAIL'} {name}")
    # jsonl 绑定：只查与本次阶段相关的那份
    for items, summary in ITEMS.items():
        if summary not in STAGES[stage]:
            continue
        before = len(prob)
        _check_items(items, summary, prob)
        ok = len(prob) == before
        print(f"  {'OK  ' if ok else 'FAIL'} {items}  ← {summary}#itemsSha256")
        if ok:
            done.append(items)
    # 成片存在性：凡本轮要看成片台的阶段都查（三个阶段都含 compose_summary）
    if "P0_compose_summary.json" in STAGES[stage]:
        before = len(prob)
        _check_compose_artifacts(prob)
        if len(prob) == before:
            done.append("成片存在性")

    print()
    if prob:
        print(f"**{len(prob)} 项不通过 —— 不要继续往下跑：**")
        for x in prob:
            print("  - " + x)
        return 1
    print(f"全部通过（{len(done)} 份产物 + 绑定复核）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
