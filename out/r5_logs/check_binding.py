# -*- coding: utf-8 -*-
"""qa-batch：r5 产物与**当前树**的来源绑定核对（输出 `out/r5_logs/binding.txt`）。

门禁的判据（`tools/gate/provenance.dart`，读实现抄口径，不调它的代码）：
  * `currentBlobHashes` = 对每个受钉路径跑 `git hash-object <path>`（**工作树内容**，不是 HEAD）；
  * `_verifyOne` 逐条比产物 `blobHashes` 里的值：缺一条 → reasons 非空；不一致 → reasons 非空；
  * `ok => reasons.isEmpty`，`tag = OK / UNDECIDABLE`。
**有一条不一致就不是"部分可信"，是整份不可判。**

用法：python out/r5_logs/check_binding.py > out/r5_logs/binding.txt
"""
import hashlib
import json
import os
import subprocess
import sys

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"

# (产物, 指纹块指针) —— 与 tools/gate/provenance.dart:365-370 逐字一致
BOUND = [
    ("out/P0_compose_summary.json", ["provenance", "codeFingerprint"]),
    ("out/P0_output_residual.json", ["summary", "provenance", "codeFingerprint"]),
    ("out/P0_alpha_holes.json", ["provenance", "codeFingerprint"]),
]
# 其余带指纹块的产物：不参与门禁绑定，但同样核一遍（同批一致性）
EXTRA = [
    ("out/P0_coverage_post.json", ["provenance", "codeFingerprint"]),
    ("out/P0_selfcheck_provenance.json", ["codeFingerprint"]),
]


def dig(node, keys):
    for k in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(k)
    return node


def blob_of(rel):
    r = subprocess.run(["git", "hash-object", rel], cwd=REPO, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def check(path, ptr):
    try:
        doc = json.load(open(os.path.join(REPO, *path.split("/")), encoding="utf-8"))
    except FileNotFoundError:
        return None, "文件不存在", []
    fp = dig(doc, ptr)
    if not isinstance(fp, dict) or not isinstance(fp.get("blobHashes"), dict):
        return None, "缺 blobHashes", []
    rec = fp["blobHashes"]
    missing, mismatch = [], []
    for rel, want in rec.items():
        got = blob_of(rel)
        if got is None:
            missing.append(rel)
        elif got != want:
            mismatch.append(rel)
    ok = not missing and not mismatch
    return fp, ("OK" if ok else "UNDECIDABLE"), [(r, rec[r], blob_of(r)) for r in missing + mismatch]


def main():
    w = sys.stdout.write
    w("r5 产物来源绑定核对（口径抄自 tools/gate/provenance.dart，工作树为准）\n")
    w("=" * 92 + "\n\n")
    bad = 0
    for label, items in (("门禁实际绑定的三份", BOUND), ("同批其余（只核一致性）", EXTRA)):
        w(f"## {label}\n\n")
        for path, ptr in items:
            fp, tag, bads = check(path, ptr)
            if fp is None:
                w(f"- `{path}`: **{tag}**\n")
                bad += 1
                continue
            n = len(fp["blobHashes"])
            w(f"- `{path}`: **{tag}**（{n} 条，错 {len(bads)} 条）；"
              f"fnv={fp.get('fnv1a64')} allCommitted={fp.get('allCommitted')}\n")
            for rel, want, got in bads[:10]:
                w(f"    * `{rel}`: 记 {want}，现树 {got}\n")
            if bads:
                bad += 1
        w("\n")

    # 当前树指纹（与产物自报值对照，**不替代**逐条比对）
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "cf", os.path.join(REPO, "test", "batch", "code_fingerprint.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    cur = m.code_fingerprint()
    w(f"当前树指纹：`{cur['fnv1a64']}`，{cur['files']} 文件，"
      f"allCommitted={cur['allCommitted']}，head={cur['headCommit'][:8]}\n")
    w(f"（与上面各产物自报的 fnv 对照；门禁比的是 blobHashes，不是这个数。）\n\n")
    w(f"判决：绑定不合的产物 **{bad}** 份（0 = 全绑上）\n")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
