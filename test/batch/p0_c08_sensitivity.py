# -*- coding: utf-8 -*-
"""qa-batch：c08 真值不确定性的**敏感性分析**（G2B-P0）。

背景：c08 的真值 −8.01° 是 `p0_finalize.py` 手写表里的值。`p0_est.py` 的独立
稳健估计给出 −6.56°（M1 法 −6.805°），相差 **+1.45°**，越过了脚本自己的 0.8° 复核线，
而当时无人复核（见报告）。

裁定（主会话）：**真值不改**。理由是替代候选（−6.56 / −6.805）来自**瞳孔法**，
而瞳孔法正是被测估角器的同族——换真值在结构上是循环的；且 c08 的
`corroborationOk=false`（两法互差 1.69°），说明稳健值本身也没被佐证。
要做的不是换真值，而是**量化"真值若不同"会影响哪些判定**。

本脚本对三档假设各算一遍门禁判据：
    H1 = −8.01   （现用手写值）
    H2 = −6.56   （稳健估计）
    H3 = −9.389  （YuNet 眼线原始读数）
并回答：**P0.1a / P0.1b / P0.3a / P0.3b / P0.2 里有没有任何一条的判定发生翻转。**

⚠️ 读法（2026-09-17 订正）：**"不翻转"不等于"不受影响"**。P0.2 的判据量是
`[...straight, ...upright]` 整队的 `max|残余|` 对比 1.5°，而 c08_upright 的残余
随 c08 真值整体平移——所以正确的说法是"**P0.2 在竞争真值下的通过余量还剩多少**"，
不是"P0.2 与真值无关"。见 `verdicts()` 里 P0.2 段的订正说明。
在**现用真值**下顶门的是 c05_upright（0.637，余量 0.863）；c08_upright（−0.019）
要到 H2 才成为顶门项（1.431，余量 0.069）。

⚠️ **本文件的斜率/截距数字经过一次订正**（commit `9ad2e22`），不要只看订正后的值：
初版把竖直夹具的真值写成 `t_c08`，H1/H2/H3 三档的 P0.3a 回归都因此被污染。
订正前后：H1 −0.0116/0.2797 → **−0.0125/0.2787**（门禁 −0.013/0.279），
H2 −0.0247/0.3653 → **−0.0223/0.3730**，H3 0.0076/0.2179 → **0.0039/0.2083**。
H1 修完**更贴门禁**，这是修对了的旁证——修之前是"更远离门禁却无人察觉"。

⚠️ **行选取规则也订正过一次**（team-lead 2026-09-17 指出）。成片记录的行键是
**`(id, specId)`**，不是 `id`：110 行 / 100 个 id，5 个 id（`p1`/`p2`/`p1_d-10`/
`p1_upright`/`c08_d-10`）各按 spec 展开成 `cn_1inch`/`cn_big_1inch`/`visa_us` 三行。
初版写的是 `{i["id"]: i for i in items}`——**最后一行胜出，静默丢 10 行**。
没出事**纯属侥幸**：那 5 个 id 的三行在 truth/rollSource/straightenDeg 上完全一致。
现按门禁的口径（`gate_P0.dart:318` 是按 spec 过滤，不是按 id 合并）先定 spec 再选行，
spec 从**量测文件自带的 specId** 解出（不写死），并加守卫：过滤后仍有重复 id 就抛错。
**教训**：按 id 单独去重/计数的消费方都会数错——这与"引用会过期的 id 清单"是同一类错。

════════════════════════════════════════════════════════════════════════════
**未自证清单**（team-lead 2026-09-17 要求逐项交代；凡不在此列的，都别当成已验过）

自证过的（1 项）：
  * `_delta_of` + `apply_hypothesis` 的**真值赋值**，仅在 δ=0 上（`selfcheck()`）。

**没有**任何自检覆盖的（7 项）：
  1. `instrumentsOk` —— 未建模（门禁的运行期门），报告已声明。
  2. **平移集合**（`residualBy` 过滤）—— 自检只在 δ=0 跑，该过滤只在 δ≠0 起作用。
     实测：整条过滤删掉，`selfcheck()` 仍 PASS，而 H2 斜率不变——因为当前**它本来就是空转**：
     c08 家族 8 条残余**全部**出自 `gate_sift_align`，走眼线的 **0 条**。
     即这道守卫今天不排除任何东西；将来真出现眼线测得的 c08 样本，它才会变成承重墙，
     而那时它没有测试。
  3. **四级取数优先级里的两级从未执行**：100 条样本按出处只有 `gate_eyeline`(90) 与
     `gate_sift_align`(10)；`qa_eyeline` 与 `derived_identity` 两条分支**一次都没跑到**，
     等于未测代码。
  4. `load()` 的**逐条路径选择** —— 只靠五个聚合数与门禁对得上（P0.1a/P0.2/P0.3a/P0.3b/P0.1b），
     没有任何逐条检查、没有负向对照。若某条走错路径却不扰动这五个数，看不出来。
  5. `_median` / `_slope` / `_intercept` —— 没有对已知答案的单元检验。它们"对"是因为
     与门禁打印的聚合数一致；但这三个函数是**从门禁抄来的**，共用同一个错误时仍会自我一致，
     所以"一致"不构成独立验证。
  6. ~~**七个常量** —— 本文件不校验它们与 `gate_P0.dart` 是否同步。~~
     **已由构造消除**（2026-09-17）：改为从 `gate_P0.dart` 正则抽取，找不到就抛错、
     不回退内置值。运行时会打印指纹，报告可据此注明用了哪一版阈值。
     指纹用 **git blob 哈希**（对行尾不敏感），并同时打印 HEAD blob：
     **两者不等 = 我读的是未落库的工作区状态**，此时指纹绑不到 commit，不得当版本号引用。
     另存 `--strict`，未落库时直接拒绝出数——开跑时必须用它。
     注意仍有**未消除**的一半：**判据的语义**仍是手抄镜像，抽常量管不到它。见下条。
  7. **上游输入**（`gate_P0_eyeline.json` / `gate_P0_sift_align.json` /
     `P0_output_residual.json`）整体继承。其中眼线那份与门禁复核成片用的是**同族**量具，
     它的系统误差本文件无法察觉（即 `m3_haar_eyeline` 那条已知局限）。
  8. **判据的语义**是手抄镜像，抽常量管不到。已知一例：P0.1a 门禁写
     `cohort.length >= kMinDistinctPhotos`（数**行数**），而同项 expected 写的是
     "样本 ≥ 8 张**不同照片**"。当前 11 行 / 10 张不同照片（`c03`≡`c04`），都 ≥ 8 故不改结论。
     **本文件已改为按语义数不同照片**（`count_distinct_photos()`），并配**已知答案检验**
     （`selftest_distinct()`，含 12 条 → 11 张、去掉真照片 c05 → 10 张、重复 c03 不重复计数
     等个案，且要求至少 2 个个案具备鉴别力——即朴素 `len()` 蒙不对）。
     这套检验**只依赖本文件**、不抄门禁，故不落第 4 条的陷阱，与门禁那边互为独立见证。
     门禁落库后仍需人工确认两边口径一致：**那一步没有自检能替你发现漏做**，
     但至少本文件的计数本身已被钉住。

**关于本脚本"复算与门禁一致"的正确口径**（team-lead 2026-09-17 裁定，别引用错）：
一致性是**转录正确性检查**，**不是**独立验证。理由就是第 4 条——`_median`/`_slope`/
`_intercept` 与判据都是抄门禁的，共用同一个错误时仍会自我一致。
它挣到的是"**暴露自己的错**"（`_delta_of` 死代码、取数优先级抄漏），
**不是**"第二方确认了门禁的数"。报告里一律写"复算一致性（转录核对）"。
════════════════════════════════════════════════════════════════════════════

为什么线性：门禁的残余定义是 `residual = truth_apply_deg − measured_applied_deg`
（见 `out/gate_P0_sift_align.json` 的逐条数据与 `gate_P0.dart` 的注释）。
真值挪 δ，该样本残余**恰好挪 δ**，所以本分析可以精确重算，不需要重跑成片。

判据的**语义**镜像 `tools/gate/gate_P0.dart`（本脚本只读它，不改它）；
七个数**直接抽**自它，不再手抄（见 `load_constants()`）。

用法：python test/batch/p0_c08_sensitivity.py
"""
import hashlib
import json
import math
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

# ---- 常量：从 gate_P0.dart **直接抽取**，不手抄 ----
#
# 为什么不手抄（team-lead 2026-09-17 指出）：本文件初版把七个常量抄了一遍，
# "与门禁保持同步"全靠人记得核对——而抄本会在门禁改阈值后**静默漂移**，
# 后果是敏感性分析与门禁判的是两套判据，且看不出来。改成解析后，**漂移由构造消除**，
# 不再依赖纪律。这与本脚本 `load()` 照抄取数优先级的理由相反——那里的"照抄"是
# 有意的（要复现门禁的语义），这里的"照抄数值"是无意的耦合。区别在于：
# 语义必须镜像，数值必须引用。
GATE_SRC = os.path.join(L.REPO, "tools", "gate", "gate_P0.dart")

_CONST_RE = re.compile(r"^const\s+(double|int)\s+(\w+)\s*=\s*([0-9.]+)\s*;", re.M)

# 本脚本用的名字 -> 门禁里的名字
_CONST_NAMES = {
    "K_RESIDUAL_MAX": "kResidualMaxDeg",
    "K_RESIDUAL_MEDIAN_MAX": "kResidualMedianMaxDeg",
    "K_SLOPE_ABS_MAX": "kResidSlopeAbsMax",
    "K_INTERCEPT_ABS_MAX": "kResidInterceptAbsMax",
    "K_COVERAGE_MIN_TRUTH": "kCoverageMinTruthDeg",
    "K_MIN_DISTINCT": "kMinDistinctPhotos",
    "K_UPRIGHT_MIN": "kUprightSyntheticMin",
}


def load_constants(path=GATE_SRC):
    """读 `gate_P0.dart`，抽回七个阈值。**找不到就抛错，绝不回退到内置值。**

    静默回退等于把刚拆掉的隐患原样装回去：门禁改了阈值、本脚本却还在用旧值，
    而且报告上看不出来。宁可让脚本红掉，也不要让它拿一套过期判据算出好看的数字。
    """
    with open(path, encoding="utf-8") as f:
        src = f.read()
    found = {m.group(2): (m.group(1), float(m.group(3)))
             for m in _CONST_RE.finditer(src)}
    missing = [k for k in _CONST_NAMES.values() if k not in found]
    if missing:
        raise RuntimeError(
            "gate_P0.dart 里找不到这些常量，拒绝用内置值兜底：%s\n（源文件 %s）"
            % ("、".join(missing), path))
    vals = {}
    for mine, gate in _CONST_NAMES.items():
        kind, v = found[gate]
        vals[mine] = int(v) if kind == "int" else v
    vals["_src_path"] = path
    return vals


def _git(args):
    """跑一条 git 命令，失败返回 None（不抛）。"""
    try:
        r = subprocess.run(["git"] + args, cwd=L.REPO, capture_output=True,
                           text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def gate_revision(path=GATE_SRC):
    """给"读的是哪一版阈值"一个**能跨机器比对**的指纹。

    为什么不用 sha256（team-lead 2026-09-17 指出）：裸文件 sha256 与行尾约定绑定——
    同一份判据在 CRLF 工作区算出 `7072c362cffc`、在 LF 归一后算出 `37eb21d51cac`
    （本文件初版报的就是后者，因为 Python 文本模式读入会把 CRLF 折成 LF）。
    换台机器、换个 `core.autocrlf`，同一个"判据版本"就是另一个哈希，
    那它就没法用来比对版本——而这是它唯一的用途。

    改用 **git blob 哈希**（对行尾不敏感，与 `code_fingerprint.dart` 同一套口径），
    并同时给出 HEAD 的 blob：**两者不等 = 我读的是未落库的工作区状态**，
    这时指纹绑不到任何 commit，报告里不许把它当版本号用。
    git 不可用时退回 LF 归一后的 sha256，并**在输出里标明是归一后的**。
    """
    rel = os.path.relpath(path, L.REPO).replace("\\", "/")
    blob = _git(["hash-object", "--", rel])
    head_blob = _git(["rev-parse", "HEAD:" + rel])
    head_commit = _git(["rev-parse", "--short", "HEAD"])
    if blob is None:
        raw = open(path, "rb").read()
        return dict(kind="lf-sha256(归一后)", id=hashlib.sha256(
            raw.replace(b"\r\n", b"\n")).hexdigest()[:12],
            committed=None, head_blob=None, head_commit=head_commit)
    return dict(kind="git-blob", id=blob[:12], committed=(blob == head_blob),
                head_blob=(head_blob or "")[:12], head_commit=head_commit)


# `load()` 的元信息（成片规格、行数账）。放模块级而不是塞进样本表里当一个
# 保留键——保留键会污染每一次对样本表的迭代与计数，正是本文件反复在批的毛病。
LOAD_META = {}


_C = load_constants()
K_RESIDUAL_MAX = _C["K_RESIDUAL_MAX"]              # |residual| 上限
K_RESIDUAL_MEDIAN_MAX = _C["K_RESIDUAL_MEDIAN_MAX"]  # 中位残余上限
K_SLOPE_ABS_MAX = _C["K_SLOPE_ABS_MAX"]
K_INTERCEPT_ABS_MAX = _C["K_INTERCEPT_ABS_MAX"]
K_COVERAGE_MIN_TRUTH = _C["K_COVERAGE_MIN_TRUTH"]  # |truth| > 此值必须给出 pupil
K_MIN_DISTINCT = _C["K_MIN_DISTINCT"]
K_UPRIGHT_MIN = _C["K_UPRIGHT_MIN"]


# ---- 不同照片计数 ----------------------------------------------------------
#
# 背景（2026-09-17）：门禁 `gate_P0.dart:410` 写的是 `cohort.length >= kMinDistinctPhotos`
# ——数**行数**；而同项 expected（:416）写的是"样本 ≥ 8 张**不同照片**"。
# 当前 P0.1a 队列 11 行、但只有 10 张不同照片（c03≡c04），两者都 ≥ 8 故不改结论，
# 但判据比它的名字**松**。team-lead 已回派 gatekeeper 改成数不同照片。
#
# 本函数按**语义**（法典口径 6）实现，不等门禁——这样两边互为独立见证：
# 我这份不抄门禁的实现，所以不落"第 4 条"那个"共用同一个错误仍自洽"的陷阱。
KNOWN_SAME_PHOTO = (frozenset({"c03", "c04"}),)
# 证据：ECC 欧氏对齐后只统计结构像素（Sobel > 25），c03/c04 一致度 95.2%（中位差 1），
# 而 c10/c11 为 11.3%(33)、c10/c12 为 10.6%(36)，差一个数量级。详见 docs/PITFALLS.md。


def count_distinct_photos(ids):
    """数**不同照片**：已证同图的 id 折成一类，其余各自计数。"""
    seen, n = set(), 0
    for i in ids:
        if i in seen:
            continue
        grp = next((g for g in KNOWN_SAME_PHOTO if i in g), frozenset({i}))
        seen |= set(grp)
        n += 1
    return n


def selftest_distinct():
    """已知答案检验——**只依赖本文件的代码**，不抄门禁，故不落第 4 条的陷阱。

    返回 (bad, weak)：bad = 与手算答案不符的 case；weak = 朴素 `len()` 也能蒙对的
    case（不具鉴别力）。要求至少 2 个 case 具鉴别力，否则这套检验等于没牙。
    """
    anchors12 = ["c01", "c02", "c03", "c04", "c05", "c06", "c07", "c08",
                 "c10", "c11", "c12", "p1"]
    pupil11 = [i for i in anchors12 if i != "c11"]   # c11 unavailable，不进 P0.1a 队列
    cases = [
        (anchors12, 11, "锚点栏 12 条 − c03≡c04 → 11 张（法典口径 6）"),
        (pupil11, 10, "P0.1a 队列 11 行 − c03≡c04 → 10 张"),
        ([i for i in anchors12 if i != "c05"], 10, "去掉一张**真**照片 c05 → 11 条 → 10 张"),
        ([i for i in anchors12 if i != "c04"], 11, "去掉 c04 但 c03 仍在 → 该照片仍被代表 → 11 张"),
        (pupil11 + ["c03"], 10, "重复出现 c03 不得再加一（按 id 去重）"),
    ]
    bad = ["%s：期望 %d 实得 %d" % (why, want, count_distinct_photos(ids))
           for ids, want, why in cases if count_distinct_photos(ids) != want]
    weak = [why for ids, want, why in cases if len(ids) == want]
    return bad, weak, len(cases)

C08_RECORDED = -8.01
HYPOTHESES = [("H1 手写值", -8.01), ("H2 稳健估计", -6.56), ("H3 YuNet 眼线", -9.389)]


def _median(xs):
    if not xs:
        return float("nan")
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _slope(pts):
    if len(pts) < 2:
        return float("nan")
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    num = sum((p[0] - mx) * (p[1] - my) for p in pts)
    den = sum((p[0] - mx) ** 2 for p in pts)
    return float("nan") if den == 0 else num / den


def _intercept(pts):
    if not pts:
        return float("nan")
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    return my - _slope(pts) * mx


def _delta_of(sid):
    """夹具 id -> 该样本在假设 t 下的**真实倾角**与 t 的差（即 truth = t_c08 + 返回值）。

    订正（2026-09-17，自查）：初版的 `if tag == "upright": return None` 分支是**死代码**——
    `"c08_upright"` 里没有 `"_d"`，所以上面的 `if "_d" not in sid: return 0.0` 先返回了，
    永远走不到那个分支。后果：`apply_hypothesis` 把竖直夹具的 truth 写成了 `t_c08`
    （H2 下 −6.56°），而它的真实倾角应是 **t_c08 − t_recorded**（H2 下 +1.45°）。
    这个错值会漏进 P0.3a 的回归（该回归用 (truth, residual) 拟合），污染 H2/H3 的斜率与截距。

    竖直夹具的来历：它是把锚点按**记录的真值** `t_recorded` 反向旋转做出来的，
    所以其倾角 = t_true − t_recorded。H1 下恰好为 0（自洽），H2 下则是 +1.45°。
    换句话说，**"这条夹具是不是竖直的"完全取决于 c08 真值**——真值错多少，它就歪多少。
    """
    if sid.endswith("_upright"):
        return -C08_RECORDED          # truth = t_c08 + (-t_recorded) = t_c08 - t_recorded
    if "_d" not in sid:
        return 0.0
    return float(sid.split("_d")[1].replace("+", ""))


def load():
    """按 `gate_P0.dart::buildSamples` 的**取数优先级**重建样本表。

    这一步必须照抄，否则复算不出门禁的数（我第一版就是直接全用 SIFT 的残余，
    得到 max 0.660 / 中位 0.101，与门禁报告的 0.714 / 0.476 对不上）。

    优先级：门禁自己的眼线量具 → SIFT 配准 → qa-batch 量测 → 恒等式兜底。

    ⚠️ **两条路径对真值的依赖不同，这正是本分析的关键**：
      * `gate_eyeline` / `qa_eyeline` 量的是**成片本身的倾角**，**与 truth 无关**；
      * `gate_sift_align` 的残余 = `truth − 实测施加角`，**与 truth 线性相关**；
      * `derived_identity` 同理。
    所以只有走后两条路径的样本，才会随 c08 真值假设一起平移。
    """
    eyeline = {r["id"]: r for r in json.load(
        open(os.path.join(L.REPO, "out", "gate_P0_eyeline.json"),
             encoding="utf-8"))["rows"]}
    sift = {r["id"]: r for r in json.load(
        open(os.path.join(L.REPO, "out", "gate_P0_sift_align.json"),
             encoding="utf-8"))["rows"]}

    # 成片记录的行键是 **(id, specId)**，不是 id：110 行 / 100 个 id，
    # 有 5 个 id 各按 spec 展开成 3 行（p1 / p2 / p1_d-10 / p1_upright / c08_d-10，
    # specId 为 cn_1inch / cn_big_1inch / visa_us）。**按 id 单独去重会静默丢 10 行。**
    #
    # 门禁的口径（`gate_P0.dart:318`）是**按 spec 过滤**，不是按 id 合并：
    #     if (inputs['spec'] != null && c['specId'] != inputs['spec']) continue;
    # 所以这里照它的口径来——先定 spec，再选行，最后才按 id 建表。
    #
    # 我初版写成 `{i["id"]: i for i in items}`（最后一行胜出，即 visa_us），
    # 之所以没出事纯属侥幸：那 5 个 id 的三行在 truth/rollSource/straightenDeg
    # 上**完全一致**。值一旦按 spec 分化，它就会静默取错行。
    #
    # spec 不写死，从**量测文件自己带的 specId** 解出（数据来源，不是我的记忆）；
    # 不唯一就抛错，不猜。
    spec_ids = sorted({r["specId"] for r in eyeline.values() if r.get("specId")})
    if len(spec_ids) != 1:
        raise RuntimeError(
            "量测文件的 specId 不唯一（%s），无法确定成片规格，拒绝猜测" % spec_ids)
    spec = spec_ids[0]

    items_all = json.load(open(
        os.path.join(L.REPO, "out", "P0_output_residual.json"),
        encoding="utf-8"))["items"]
    comp_list = [c for c in items_all if c.get("specId") == spec]
    comp = {c["id"]: c for c in comp_list}
    if len(comp) != len(comp_list):
        raise RuntimeError(
            "按 specId=%s 过滤后仍有重复 id（%d 行 -> %d 个 id），"
            "行选取规则与门禁口径不一致" % (spec, len(comp_list), len(comp)))
    LOAD_META.update(spec=spec, rows_in_file=len(items_all),
                     rows_at_spec=len(comp_list), unique_ids=len(comp))

    out = {}
    for cid, c in comp.items():
        truth = float(c["truthTiltDeg"])
        applied = float(c["straightenDeg"])
        g = eyeline.get(cid)
        r = sift.get(cid)
        if g is not None and g.get("ok") is True:
            residual, by = float(g["tilt_deg"]), "gate_eyeline"
        elif r is not None and r.get("ok") is True:
            residual, by = float(r["residual_deg"]), "gate_sift_align"
        elif (c.get("primary_tilt_deg") is not None
              and c.get("end_to_end_status") not in ("reliability_mismatch", "unmeasured")):
            residual, by = float(c["primary_tilt_deg"]), "qa_eyeline"
        else:
            residual, by = truth - applied, "derived_identity"
        out[cid] = {
            "id": cid,
            "corpus": c["corpus"],
            "source": c["rollSource"],
            "truth": truth,
            "residual": residual,
            "residualBy": by,
            "applied": applied,
        }
    return out


def apply_hypothesis(samples, t_c08):
    """返回换了 c08 真值后的样本副本。非 c08 家族原样不动。

    残余只在**真值相关**的路径上平移（见 load() 的说明）；眼线直测的样本
    量的是成片倾角，换真值不影响它。
    """
    shift = t_c08 - C08_RECORDED
    out = {}
    for cid, s in samples.items():
        s2 = dict(s)
        if (cid == "c08" or cid.startswith("c08_")) and s["residualBy"] in (
                "gate_sift_align", "derived_identity"):
            s2["truth"] = t_c08 + _delta_of(cid)
            s2["residual"] = s["residual"] + shift
        out[cid] = s2
    return out


def verdicts(samples):
    anchors = [s for s in samples.values() if s["corpus"] == "anchor"]
    rotated = [s for s in samples.values() if s["corpus"] == "rotated"]
    upright = [s for s in samples.values() if s["corpus"] == "uprightSynthetic"]
    pupils = [s for s in samples.values() if s["source"] == "pupil"]

    # P0.1a
    co = [s for s in anchors if s["source"] == "pupil"]
    res = [abs(s["residual"]) for s in co]
    # 用**不同照片**数（不是行数）对齐 kMinDistinctPhotos 的语义，见 count_distinct_photos()。
    n_distinct = count_distinct_photos([s["id"] for s in co])
    p1a = (n_distinct >= K_MIN_DISTINCT and max(res) <= K_RESIDUAL_MAX
           and _median(res) <= K_RESIDUAL_MEDIAN_MAX) if res else False
    p1a_detail = dict(n=len(co), n_distinct=n_distinct,
                      max=max(res) if res else None,
                      median=_median(res) if res else None)

    # P0.1b
    need = [s for s in anchors if abs(s["truth"]) > K_COVERAGE_MIN_TRUTH]
    bad = [s for s in need if s["source"] == "unavailable"]
    p1b = not bad
    p1b_detail = dict(need=len(need), bad=[s["id"] for s in bad])

    # P0.3a
    cohort = pupils if pupils else list(samples.values())
    pts = [(s["truth"], s["residual"]) for s in cohort]
    sl, ic = _slope(pts), _intercept(pts)
    over = [s["id"] for s in cohort if abs(s["residual"]) > K_RESIDUAL_MAX]
    p3a = (math.isfinite(sl) and abs(sl) <= K_SLOPE_ABS_MAX
           and math.isfinite(ic) and abs(ic) <= K_INTERCEPT_ABS_MAX and not over)
    p3a_detail = dict(slope=sl, intercept=ic, n_over=len(over), over=over[:6])

    # P0.3b
    rneed = [s for s in rotated if abs(s["truth"]) > K_COVERAGE_MIN_TRUTH]
    rbad = [s for s in rneed if s["source"] == "unavailable"]
    p3b = not rbad
    p3b_detail = dict(need=len(rneed), bad=[s["id"] for s in rbad])

    # P0.2 —— **判据量是整队 max|残余|，不是只看 rollSource**。
    #
    # 订正（2026-09-17，team-lead 指出）：本函数初版写成
    #     p02 = len(upright) >= 9 and not notp
    # 理由是错的。`gate_P0.dart:471-481` 的实际判据是：
    #     cohort = [...straight, ...upright]
    #     maxAbs = max(|residual| for s in cohort)
    #     pass = instrumentsOk && cohort.isNotEmpty
    #            && upright.length >= kUprightSyntheticMin
    #            && maxAbs <= kResidualMaxDeg && notPupil.isEmpty
    # 即**残余与来源两半都检**，且残余那一半取的是含 p2 在内的整队最大值。
    # 初版漏掉了 maxAbs 这一半——这会让本脚本对 P0.2 报出一个比门禁更宽松的判据，
    # 而"c08 真值变了会怎样"恰恰要靠这一半才看得出来。
    #
    # `instrumentsOk` 本脚本不建模（它属于门禁的运行期门），故此处只复算
    # cohort/maxAbs/notPupil 三项；报告里必须注明这一条未复算。
    straight_l = [s for s in samples.values() if s["corpus"] == "straight"]
    cohort02 = straight_l + upright
    res02 = [abs(s["residual"]) for s in cohort02]
    max_abs = max(res02) if res02 else float("nan")
    argmax = (max(cohort02, key=lambda s: abs(s["residual"]))["id"]
              if cohort02 else None)
    notp = [s for s in upright if s["source"] != "pupil"]
    p02 = (cohort02 and len(upright) >= K_UPRIGHT_MIN
           and max_abs <= K_RESIDUAL_MAX and not notp)
    p02 = bool(p02)
    return dict(p1a=p1a, p1b=p1b, p3a=p3a, p3b=p3b, p02=p02), dict(
        p1a=p1a_detail, p1b=p1b_detail, p3a=p3a_detail, p3b=p3b_detail,
        p02=dict(n_cohort=len(cohort02), n_straight=len(straight_l),
                 n_upright=len(upright), max_abs=max_abs, argmax=argmax,
                 margin=K_RESIDUAL_MAX - max_abs, bad=[s["id"] for s in notp]))


def selfcheck(base):
    """空变换自检：用**现用真值**跑一遍 `apply_hypothesis`，必须逐字节还原输入。

    这是本模型唯一不依赖真值真伪的检验——若 H1 下都有漂移，那么后面所有
    "H2 变了多少"的数字都掺着建模误差，不能归因给真值假设。
    它同时钉住 `_delta_of`：竖直夹具在 H1 下必须算回 0.0（= −t_recorded + t_recorded）。
    比较用 1e-9 容差而非按位相等——真值是用 `t_c08 + delta` **重算**的，浮点上不保证
    与 JSON 里解析出来的字面量按位相同（如 −8.01+10 → 1.9900000000000002 vs 1.99）。

    ⚠️ 这个容差**不是**被放宽的断言（不是 ACCEPTANCE 防作弊条款 3 那种情形）：
    1e-9 只吸收"同一实数两种算法各差一个 ulp"，比本文件任何有意义的差别小 7 个数量级
    （本文件最小的判定刻度是 0.069°）。它抓不住的东西，本来就轮不到它抓。
    **不要为了让它变绿而放大它**——它第一次运行就是红的，红的原因正是上面那个 ulp。

    覆盖面（别高估它）：
      * 能抓：真值算错（如竖直夹具被写成 t_c08）——旧版 `_delta_of` 喂进来会返回
        `['c08_upright']`，实测如此。
      * **抓不到：平移集合错**。自检只在 δ=0 上跑，而"哪些样本该随真值平移"这个
        判断只在 δ≠0 时才起作用；把 `residualBy` 过滤整个删掉，自检照样 PASS。
    """
    same = apply_hypothesis(base, C08_RECORDED)
    bad = [cid for cid in base
           if abs(same[cid]["truth"] - base[cid]["truth"]) > 1e-9
           or abs(same[cid]["residual"] - base[cid]["residual"]) > 1e-9]
    return bad


def main():
    strict = "--strict" in sys.argv[1:]
    base = load()
    rev = gate_revision()
    print("阈值来源 %s" % _C["_src_path"])
    print("  指纹 %s:%s" % (rev["kind"], rev["id"]))
    if rev["committed"] is True:
        print("  已落库：与 HEAD blob %s 相同（HEAD %s）"
              % (rev["head_blob"], rev["head_commit"]))
    elif rev["committed"] is False:
        print("  ⚠ **未落库**：HEAD blob 是 %s，我读的是工作区 blob %s（HEAD %s）"
              % (rev["head_blob"], rev["id"], rev["head_commit"]))
        print("    此时这枚指纹**绑不到任何 commit**，报告里不得当版本号引用。")
    else:
        print("  ⚠ git 不可用，退回哈希；kind 已标明是否做过行尾归一。")
    print("  " + "  ".join("%s=%s" % (n, _C[n]) for n in sorted(_CONST_NAMES)))
    print()
    if strict and rev["committed"] is not True:
        print("--strict：阈值来源未绑定到 commit，拒绝出数（见上）。")
        sys.exit(2)

    dbad, dweak, dtotal = selftest_distinct()
    strong = dtotal - len(dweak)
    print("不同照片计数 已知答案检验：%s（具鉴别力的 case %d/%d）"
          % ("PASS" if not dbad else "FAIL %s" % dbad, strong, dtotal))
    if strong < 2:
        print("  ⚠ 鉴别力不足：太多个案连朴素 len() 都能蒙对，这套检验没有牙。")
    bad = selfcheck(base)
    print("空变换自检（H1 应逐条还原）：%s\n"
          % ("PASS" if not bad else "FAIL %s" % bad[:6]))
    print("样本 %d 条（成片台语料）\n" % len(base))

    # 与 gatekeeper 的握手：**先对①，再对②③**（team-lead 2026-09-17 定的顺序）。
    # ① 对不上 = 谓词/行选取规则没对齐，此时比 ②③ 等于比两个不同的东西。
    # 谓词钉的是 `corpus=anchor && rollSource=pupil`，id 从**当轮记录**解出，
    # 不跨轮沿用——r1 的 id 清单在 c11 由 unavailable 翻成 pupil 后就会过期。
    co0 = [s for s in base.values()
           if s["corpus"] == "anchor" and s["source"] == "pupil"]
    ids0 = sorted(s["id"] for s in co0)
    print("P0.1a 队列握手（对照用；先对①再对②③）：")
    print("  ① id 序列: %s" % " ".join(ids0))
    print("  ② 行数: %d    ③ 不同照片数: %d"
          % (len(ids0), count_distinct_photos(ids0)))
    print("  行选取规则: specId == %s（取自量测文件自带的 specId）；"
          "账：文件 %d 行 → 该规格 %d 行 → %d 个 id"
          % (LOAD_META["spec"], LOAD_META["rows_in_file"],
             LOAD_META["rows_at_spec"], LOAD_META["unique_ids"]))
    print()
    results = {}
    for name, t in HYPOTHESES:
        v, d = verdicts(apply_hypothesis(base, t))
        results[name] = (v, d)
        print("=== %s：c08 真值 = %.3f ===" % (name, t))
        print("  P0.1a %s  %d 行 / %d 张不同照片  max=%.3f 中位=%.3f" % (
            "PASS" if v["p1a"] else "FAIL", d["p1a"]["n"], d["p1a"]["n_distinct"],
            d["p1a"]["max"] or 0, d["p1a"]["median"] or 0))
        print("  P0.1b %s  需摆正 %d 条，其中 unavailable %d %s" % (
            "PASS" if v["p1b"] else "FAIL", d["p1b"]["need"],
            len(d["p1b"]["bad"]), d["p1b"]["bad"] or ""))
        print("  P0.3a %s  斜率=%.4f 截距=%.4f 超限 %d 条 %s" % (
            "PASS" if v["p3a"] else "FAIL", d["p3a"]["slope"],
            d["p3a"]["intercept"], d["p3a"]["n_over"], d["p3a"]["over"]))
        print("  P0.3b %s  需摆正 %d 条，其中 unavailable %d %s" % (
            "PASS" if v["p3b"] else "FAIL", d["p3b"]["need"],
            len(d["p3b"]["bad"]), d["p3b"]["bad"] or ""))
        d2 = d["p02"]
        print("  P0.2  %s  整队 %d 条（straight %d + upright %d）max|残余| = %.3f"
              "（%s），余量 %.3f；非 pupil %d %s" % (
                  "PASS" if v["p02"] else "FAIL", d2["n_cohort"],
                  d2["n_straight"], d2["n_upright"], d2["max_abs"],
                  d2["argmax"], d2["margin"], len(d2["bad"]),
                  d2["bad"] or ""))
        print()

    print("=== 翻转检查（相对 H1 现用值）===")
    base_v = results[HYPOTHESES[0][0]][0]
    flipped_any = False
    for name, _ in HYPOTHESES[1:]:
        v = results[name][0]
        flips = [k for k in base_v if v[k] != base_v[k]]
        print("  %-16s 翻转的判据：%s" % (name, flips or "无"))
        flipped_any = flipped_any or bool(flips)
    print("\n  结论：%s" % ("有判据随 c08 真值改变" if flipped_any
                          else "**五条判据的 PASS/FAIL 均不翻转**"
                               "（c08 真值取 −8.01/−6.56/−9.389 判定一致）"))
    print("  但注意：不翻转 ≠ 不受影响。逐条余量见上，最小余量出现在 P0.2。")
    print("  H3（YuNet 眼线 −9.389°）是**已知失效**的路径——它的 3.7~6.7° 误差正"
          "是 P0 事故的根因，\n  故 H3 下的任何变化只作**余量评估**读，"
          "不得当作'P0.1a 有问题'的证据。")
    print("  本脚本**未复算** `instrumentsOk`（门禁的运行期门），报告须注明。")

    # c08 家族明细
    print("\n=== c08 家族逐条（残余随真值整体平移）===")
    print("%-14s %10s %10s %10s %8s %10s" % ("id", "H1残余", "H2残余", "H3残余", "source", "H1真值"))
    for cid in sorted(base):
        if cid == "c08" or cid.startswith("c08_"):
            s = base[cid]
            sh = [t - C08_RECORDED for _, t in HYPOTHESES]
            print("%-14s %10.3f %10.3f %10.3f %8s %10.2f" % (
                cid, s["residual"] + sh[0], s["residual"] + sh[1],
                s["residual"] + sh[2], s["source"], s["truth"]))


if __name__ == "__main__":
    main()
