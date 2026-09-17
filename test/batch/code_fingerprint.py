# -*- coding: utf-8 -*-
"""被测代码的**内容指纹**（Python 侧）。

本文件是 `test/batch/code_fingerprint.dart` 的**逐字节同口径**镜像 ——
两侧必须同域、同序、同哈希，否则会算出**不同的指纹**，在跨语言比较处表现为
假漂移（`p0_finalize_v1._measured_state()` 正是拿 Dart 写的指纹与这里现算的指纹
做跨语言比较）。

**域由门禁定义**（`tools/gate/`），不是这里自定：
  - `lib/` 下全部 `.dart`
  - `test/batch/` 下全部 `.dart` 与 `.py`
  - 排除路径里含 `__pycache__` 的
  - key = 仓库相对路径、正斜杠
域比"只看 lib/core/matting + lib/core/imaging"宽是**故意的**：测量脚本本身也是
"产出这些数的代码"。门禁的校验域里缺任何一条，该产物一律判 `undecidable`。

放在独立小模块里（而不是塞进 `p0_lib.py`）是为了避免让 `p0_finalize_v1.py`
这类不需要图像处理的调用方被迫拉起 cv2 / scipy。
"""
import os
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

MEASURED_ROOTS = ("lib", "test/batch")
MEASURED_EXTS = (".dart", ".py")
MEASURED_EXCLUDE = "__pycache__"

_MAX_ARGV_CHARS = 20000


def _chunk(paths, max_chars=_MAX_ARGV_CHARS):
    """按累计字符数分块，规避 Windows 约 32k 的 argv 上限。"""
    batch, chars = [], 0
    for p in paths:
        if batch and chars + len(p) >= max_chars:
            yield batch
            batch, chars = [], 0
        batch.append(p)
        chars += len(p) + 1
    if batch:
        yield batch


def _git_ok(argv):
    """取 git 输出；命令非 0 退出返回 None。

    **刻意不包 try/except**：起不了 git 是环境故障，必须炸出来。若降级成 None，
    上层会报"取不到 HEAD"，把所有指纹的提交绑定静默置空还附一句错误解释 ——
    本项目反复记过的形态（仪表看不见对象时说了"没有"）。
    """
    r = subprocess.run(["git"] + argv, cwd=REPO, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def measured_paths(repo=None):
    """被测集：仓库相对路径、正斜杠、已排序。与 Dart 侧同域同序。"""
    root = repo or REPO
    out = []
    for d in MEASURED_ROOTS:
        p = os.path.join(root, *d.split("/"))
        if not os.path.isdir(p):
            continue
        for dirpath, _, names in os.walk(p):
            for n in names:
                if not n.endswith(MEASURED_EXTS):
                    continue
                full = os.path.join(dirpath, n)
                if MEASURED_EXCLUDE in full.replace("\\", "/"):
                    continue
                out.append(full)
    out.sort()
    return out


def blob_hashes(paths):
    """批量取 blob 哈希，顺序与入参一一对应。**算不出即抛，绝不返回占位值。**

    为什么必须抛：指纹由这些哈希拼成。若 git 失败时两边都得到同一个哨兵
    （例如 `'unknown'`），**两份内容不同的代码会算出同一个指纹** —— 而指纹相等
    正是"这些数出自当前代码"的唯一凭据。**算不出会暴露，算成相同会静默通过。**
    门禁口径同此：`blobHashes` 出现 ''/'unknown' 一律判 `undecidable`。

    注意：**git 在有文件读不到时仍会为读得到的文件打印哈希**，只是 exit 非 0。
    所以退出码与条数必须**同时**查，只查其中一个会把部分失败读成成功。
    """
    out = []
    for batch in _chunk(paths):
        r = subprocess.run(["git", "hash-object"] + batch, cwd=REPO,
                           capture_output=True, text=True)
        lines = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
        if r.returncode != 0 or len(lines) != len(batch):
            raise RuntimeError(
                f"git hash-object 失败（exit {r.returncode}）："
                f"要 {len(batch)} 个哈希，得到 {len(lines)} 个"
                f"（本批首个路径 {batch[0]}）。\n"
                "被测代码指纹算不出来 ⇒ 本轮'这些数字出自哪份代码'无从判定。\n"
                "**不要**退化成占位值：那会让两份算不出的指纹互相判等。\n"
                f"stderr: {r.stderr}")
        out.extend(lines)
    return out


def head_tree_blobs():
    """`HEAD` 整棵树：路径（正斜杠、仓库相对）→ blob。一次进程。

    语义与逐文件 `git rev-parse HEAD:<path>` 相同：**不在该提交里的文件**在
    map 里查不到（返回 None），上层判为未提交。
    """
    r = subprocess.run(["git", "ls-tree", "-r", "HEAD"], cwd=REPO,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git ls-tree -r HEAD 失败（exit {r.returncode}）："
                           f"{r.stderr}")
    tree = {}
    for line in r.stdout.splitlines():
        if not line.strip() or "\t" not in line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.strip().split(" ")
        if len(parts) < 3:
            continue
        tree[path] = parts[-1]
    return tree


def fnv1a64_hex(s):
    """FNV-1a 64 的十六进制，**无符号、16 字符小写**（与 Dart 侧一致）。

    Dart 侧这里踩过一次坑：`int.toRadixString(16)` 对负数给出**带负号的 17 字符**，
    与 Python 的 `format(h, "016x")` 对不上，约一半输入会分歧。Dart 已改为走
    `BigInt.toUnsigned(64)`；公开测试向量在 `fingerprint_selftest.dart` 第 7 段。
    """
    h = 0xCBF29CE484222325
    for byte in s.encode("utf-8"):
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return format(h, "016x")


def commit_binding(hashes):
    """把被测集绑定到一个 commit（与 Dart 侧 `commitBinding` 同口径）。

    按内容记的指纹能回答"变了没有"，回答不了"这是哪个版本的代码"。工作区有未提交
    改动时指纹描述的是一个**历史里不存在的状态** —— 实测未提交的估角改动把 fnv
    从 `5ba549780700fba9` 变成 `00a9fa55f822f55e`，后者在任何 commit 里都找不到。
    """
    head = _git_ok(["rev-parse", "HEAD"])
    if not head:
        return {"headCommit": None, "allCommitted": None,
                "uncommittedMeasuredFiles": [],
                "commitBindingNote": "git 正常退出但给不出 HEAD，无法绑定提交。"}
    tree = head_tree_blobs()
    uncommitted = sorted(rel for rel, blob in hashes.items()
                         if tree.get(rel) != blob)
    return {
        "headCommit": head,
        "allCommitted": not uncommitted,
        "uncommittedMeasuredFiles": uncommitted,
        "commitBindingNote": (
            f"被测集全部文件与该提交一致：本指纹即 {head} 的代码。"
            if not uncommitted else
            f"被测集有 {len(uncommitted)} 个文件与 {head} 不一致："
            "本指纹描述的**不是任何提交**，只可用于内容比对。"),
    }


def code_fingerprint(repo=None):
    """被测代码的内容指纹 + commit 绑定。未知域/异常一律抛，不返回占位值。"""
    files = measured_paths(repo)
    rels = [os.path.relpath(f, repo or REPO).replace("\\", "/") for f in files]
    blobs = blob_hashes(files)
    if len(blobs) != len(rels):
        raise RuntimeError(f"要 {len(rels)} 个哈希，得到 {len(blobs)} 个")
    hashes = dict(zip(rels, blobs))
    joined = "\n".join(f"{k}:{v}" for k, v in hashes.items())
    return {"files": len(hashes),
            "fnv1a64": fnv1a64_hex(joined),
            "blobHashes": hashes,
            **commit_binding(hashes)}
