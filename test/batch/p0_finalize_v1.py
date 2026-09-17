# -*- coding: utf-8 -*-
"""qa-batch：把 out/P0_truth.json 升级为 gatekeeper 约定的 v1 schema。

只做**结构与字段的增补**，不改任何测量值：
  * 顶层 `version: 1`
  * 顶层 `convention` 改为**字符串**（gatekeeper 按字符串消费）；
    原 dict 移到 `conventionDetail` 并更新（api.dart 的注释已改正，旧的
    signTrap 措辞已失效）。
  * `anchors` / `straight` / `uprightSynthetic` 每条补：
      kind、truth_apply_deg、methods[{name,value_deg,evidence}]、visual_review、
      derivedAnnotations（`visual` 降级后的落点，见 methods_block 的注释）、
      end_to_end（成片端到端残余，来自 out/P0_output_residual.json）
  * `rotated` 每条补 truth_apply_deg
  * 全部 path 改为**绝对路径 + 正斜杠**，调用方不用猜工作目录。

用法（项目根）：`python test/batch/p0_finalize_v1.py`
幂等：重复运行结果一致（每次都从 out/P0_truth.json 的 v0 字段重建，
已存在的 v1 字段会被覆盖重写）。
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO = r"C:\Users\liuyu\Desktop\WorkPlace\idPhotos"
TRUTH = os.path.join(REPO, "out", "P0_truth.json")
RESID = os.path.join(REPO, "out", "P0_output_residual.json")

CONVENTION = (
    "角度一律用 tilt 表述，不要用'顺/逆时针'口头描述。"
    "tilt = degrees(atan2(y_imgRightEye - y_imgLeftEye, x_imgRightEye - x_imgLeftEye))，"
    "图像坐标 y 向下，正值 = 图像右侧的眼更低。"
    "生产契约 FaceInfo.rollDeg **等于 tilt 本身，不取负**；"
    "实现侧恒等式 输出倾角 = tilt - rollDeg，故摆平当且仅当 rollDeg == tilt。"
    "本文件所有 *_deg 字段（truth_apply_deg / trueRollDeg / expectedEngineRollDeg）"
    "同号同值，都表示'应该施加的摆正角'，量纲与 ComposeDiagnostics.straightenDeg 一致。"
)

METHOD_DOC = {
    "m1_pupil": "YuNet 眼位开窗 → 多阈值暗色圆盘 blob（圆度≥0.60、尺寸窗 0.03–0.32×眼距）→ 左右配对",
    "m2_radon_yunet": "YuNet 眼带（对称带 hw=1.05 hf=0.34）→ Radon 行投影方差脊线取向",
    "m3_haar_eyeline": "Haar frontalface + eye_tree_eyeglasses/eye 级联（与 YuNet 完全不同的检测器）→ 双眼连线",
    "m4_radon_haar": "Haar 眼带 → Radon 脊线取向",
    "visual": "人（多模态）直接看 overlay 目视判读",
}

# 目视复核结论（据 out/P0_anchors/_sheet_anchors_review.png 与各 <id>.png overlay）
VISUAL = {
    "p1": "正视、无遮挡，瞳孔边界清晰；四条方法线肉眼重合，无异议。",
    "p2": "竖直蓝底证件照，正视；瞳孔清晰。M2/M4（Radon 带）比 M1/M3 略偏正，"
          "是已知的方法族偏置，不影响 M1 读数。",
    "c01": "正视证件照，细金属镜框；瞳孔可见，M1/M3 一致。",
    "c02": "蓝底证件照，镜框较粗；瞳孔可辨，四法基本重合。",
    "c03": "正视，眼镜反光轻微；瞳孔清晰。",
    "c04": "**与 c03 是同一张照片的不同分辨率副本**（c03 1159×1920 / c04 483×800，"
           "缩放后逐像素 mean|diff|=2.74）。保留以记录不同分辨率下的行为，"
           "但统计时不得当作两张独立样本。",
    "c05": "近景正视，眼镜；瞳孔清晰但画幅小。",
    "c06": "蓝底证件照，正视；瞳孔清晰。",
    "c07": "蓝底证件照（报名照），正视；瞳孔清晰。M3 与 M1 差 1.2°，M1 为准。",
    "c08": "宿舍广角实拍，人脸在画面中很小（眼距 ~86px@工作分辨率），有床帘/梯子等"
           "杂物；瞳孔可辨但抠图在成片上把下半脸挖空（见 end_to_end）。",
    "c10": "**五人合影**，主体为画面中央最近者；多张脸，选中的是最大且最居中的一张。"
           "与 c11/c12 为同一场景的不同裁切（结构相关 0.68–0.84），非独立场景。",
    "c11": "与 c10 同场景（合影），主体同一个人；本项引擎返回 unavailable（picth 近零，"
           "按 P0.1b 可接受）。",
    "c12": "与 c10/c11 同场景（合影）；瞳孔在合影里偏小，M1/M3 一致。",
    "p2_full": "",
}
VISUAL["p2"] = VISUAL["p2"]
_STRAIGHT_VISUAL = ("二方确认的竖直样本（用户原图 2.jpg）。蓝底证件照，"
                    "双眼水平，瞳孔清晰；四法一致。")
_UPRIGHT_VISUAL = ("由 <src> 按真值反向旋转合成的竖直样本，几何为纯旋转；"
                   "瞳孔清晰，M1 可测。")


def absfix(p):
    p = p.replace("\\", "/")
    if not p.startswith("/") and ":" not in p[:3]:
        p = REPO.replace("\\", "/") + "/" + p
    return p


def methods_block(rec, idv):
    """把 robustPerMethodDeg + measure_raw 的 Delta0 值组装成 methods[]。

    返回 `(methods, derivedAnnotations)`。

    ⚠️ `visual` **不进 `methods[]`**。它的值就是 `trueRollDeg` 的逐位副本
    （见 `docs/PITFALLS.md` 的"用副本冒充佐证"条），把它并列进方法列表会让
    一份实际只有 1~4 条独立测量的真值在纸面上看起来有"4 法 + 目视"五个证据。
    它降级为**派生标注**：单独一栏、显式 `independent: false`，不参与任何计数。
    人眼复查的原始结论保留在同级的 `visual_review` 文本字段里。
    """
    robust = rec.get("robustPerMethodDeg") or {}
    d0 = rec.get("measuredMethodsDelta0") or {}
    out = []
    for k in ("m1_pupil", "m2_radon_yunet", "m3_haar_eyeline", "m4_radon_haar"):
        v = robust.get(k, d0.get(k))
        if v is None:
            continue
        out.append({
            "name": k,
            "value_deg": round(float(v), 3),
            "evidence": f"out/P0_anchors/{idv}.png",
            "doc": METHOD_DOC[k],
            "delta0Deg": round(float(d0[k]), 3) if k in d0 else None,
            "nObservations": (rec.get("robustObsCount") or {}).get(k),
            "note": "7 次旋转（0/±3/±5/±10）稳健估计 median(measured-Δ)，"
                    "压制单次 ±0.4° 噪声",
        })
    derived = []
    if out:
        # 只有真做过人眼复查的锚点/竖直样本才有这一栏；
        # 合成夹具（uprightSynthetic / rotated）不产出，避免凭空多出一条"方法"。
        derived.append({
            "name": "visual",
            "value_deg": rec.get("trueRollDeg"),
            "derived": "trueRollDeg",
            "independent": False,
            "evidence": "out/P0_anchors/_sheet_anchors_review.png",
            "doc": METHOD_DOC["visual"],
            "note": "**非独立读数**：与 trueRollDeg 逐位相同，是它的副本。"
                    "不得计入方法数，也不得当作真值的佐证。",
        })
    return out, derived


def _load_jsonl(p):
    out = []
    with open(p, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def _count_by_source(ids):
    """把夹具 id（如 `c11_d+10`）按源图前缀（`c11`）归并计数。"""
    out = {}
    for i in ids:
        src = i.split("_")[0]
        out[src] = out.get(src, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: (-kv[1], kv[0])))


def _tally(values):
    """通用计数（用于 rollSource 等枚举值的分布）。"""
    out = {}
    for v in values:
        out[v] = out.get(v, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: (-kv[1], kv[0])))


def _alpha_frac_by_basename():
    """{`c08_d+10.png`: eyeBandZeroFrac}，取自 out/P0_alpha_holes.json。"""
    p = os.path.join(REPO, "out", "P0_alpha_holes.json")
    if not os.path.exists(p):
        return {}
    h = json.load(open(p, encoding="utf-8"))
    out = {}
    for r in h.get("items", []):
        if r.get("assessable") and r.get("eyeBandZeroFrac") is not None:
            out[os.path.basename(r["path"])] = r["eyeBandZeroFrac"]
    for k, v in (h.get("controlComparison", {}).get("rotatedFixtures", {})
                 .get("perFixture") or {}).items():
        out.setdefault(k, v)
    return out


def _classify_not_scorable(ids, frac):
    """ACCEPTANCE 计分口径第 7 条：不可计分的样本必须逐条列出并归类，
    且在总数与通过数里同时显式扣除。阈值与 out/P0_alpha_holes.json 一致
    （eyeBandZeroFrac > 0.35 = 抠图把双眼区域挖空）。"""
    items = []
    for i in ids:
        f = frac.get(i + ".png")
        if f is not None and f > 0.35:
            cls = "抠图失效"
            why = (f"双眼区 alpha=0 占比 {f:.3f} > 0.35，瞳孔被挖掉，"
                   f"成片眼线不可测")
        else:
            cls = "量测失效"
            why = ((f"双眼区 alpha 干净（eyeBandZeroFrac={f:.4f}），"
                    f"残余却自证不可信——**不能用'量不出来'兜过去**，"
                    f"须由 gatekeeper 用独立路径（刚体残留配准）复核，"
                    f"其归类会改变违规计数")
                   if f is not None else
                   "无 alpha 记录，须由 gatekeeper 用独立路径复核")
        items.append({"id": i, "class": cls, "eyeBandZeroFrac": f, "reason": why})
    return items


def gate_inputs(truth, resid):
    """按 ACCEPTANCE G2B-P0 的分项，把 qa-batch 侧算好的数字集中放一处，
    免得 gatekeeper 再各算一遍、算法不一致。**这里只有数据，没有 PASS/FAIL。**"""
    prim = [r for r in resid["items"] if r["specId"] == "cn_big_1inch"]
    frac = _alpha_frac_by_basename()
    import numpy as np

    def stats(corpus):
        """P0.1a / P0.2 / P0.3a 的成片端到端残余。
        计分口径第 1 条：`unavailable` **不计为通过**（从判据剔除，不作 0 观测）。
        第 7 条：量测失效的单条列出、在总数与通过数里显式扣除，
        分母用扣除后的可见样本数，并同时给出原始总数。"""
        sel = [r for r in prim if r.get("corpus") == corpus]
        measured = [r for r in sel
                    if r["end_to_end_status"] in ("ok", "low_confidence")]
        notsc = sorted(r["id"] for r in sel
                       if r["end_to_end_status"] not in ("ok", "low_confidence"))
        pupil = [r for r in measured if r["rollSource"] == "pupil"]
        v = [abs(r["primary_tilt_deg"]) for r in pupil]
        return {
            "spec": "cn_big_1inch (390x567)",
            "rawTotal": len(sel),
            "measured": len(measured),
            "notScorableDeducted": len(notsc),
            "notScorable": notsc,
            "visibleDenominator": len(pupil),
            "excluded_unavailable": sorted(
                r["id"] for r in measured if r["rollSource"] != "pupil"),
            "n": len(pupil),
            "absMax": round(max(v), 3) if v else None,
            "absMedian": round(float(np.median(v)), 3) if v else None,
        }

    cov_path = os.path.join(REPO, "out", "P0_compose_items.jsonl")
    comp = {}
    for r in _load_jsonl(cov_path):
        if r.get("specId") != "cn_big_1inch":
            continue
        comp[r["id"]] = r

    def coverage(corpus):
        sel = [r for r in comp.values()
               if r.get("corpus") == corpus
               and r.get("truthTiltDeg") is not None
               and abs(r["truthTiltDeg"]) > 1.5]
        un = sorted(r["id"] for r in sel if r.get("rollSource") != "pupil")
        return {"n": len(sel), "unavailable": len(un), "culprits": un,
                "nearZeroExempt": sorted(
                    r["id"] for r in comp.values()
                    if r.get("corpus") == corpus
                    and r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) <= 1.5
                    and r.get("rollSource") != "pupil")}

    pu = [r for r in prim if r.get("corpus") == "rotated"
          and r["rollSource"] == "pupil"
          and r["end_to_end_status"] in ("ok", "low_confidence")]
    xs = np.array([r["truthTiltDeg"] for r in pu])
    ys = np.array([r["primary_tilt_deg"] for r in pu])
    slope = intercept = None
    if len(xs) >= 3:
        slope, intercept = (float(v) for v in np.linalg.lstsq(
            np.vstack([xs, np.ones_like(xs)]).T, ys, rcond=None)[0])
    # 诊断口径 ①：引擎施加角 vs 真值
    xa = np.array([r["straightenDeg"] for r in pu])
    slope_est = int_est = None
    if len(xa) >= 3:
        slope_est, int_est = (float(v) for v in np.linalg.lstsq(
            np.vstack([xs, np.ones_like(xs)]).T, xa, rcond=None)[0])
    worst = sorted(pu, key=lambda r: -abs(r["primary_tilt_deg"]))[:5]

    cov = _load_jsonl(os.path.join(REPO, "out", "P0_coverage_items.jsonl"))
    un_all = [r for r in cov if r.get("rollSource") == "unavailable"]
    in_hashes, in_hash_src = _input_hashes(prim, list(comp.values()))

    return {
        "note": "qa-batch 提供的实测数字，供 gatekeeper 判定；本块不含 PASS/FAIL。"
                "硬判据按 ACCEPTANCE 计分口径第 5 条用 output_tilt（成片端到端残余）。",
        "spec": "cn_big_1inch (390x567)",
        "inputHashes": {
            "algorithm": "sha256",
            "note": "喂给引擎的**输入字节**摘要，按 id 索引。**对齐夹具时以此为准，"
                    "不以文件名或尺寸为准**——本轮 c04/c05 的尺寸恰好与 gatekeeper "
                    "的源图相同，只看尺寸会误判同源。sidecar: out/P0_input_hashes.json",
            "provenanceById": in_hash_src,
            "byId": in_hashes,
        },
        "c05SlopeRecheck": _c05_slope_recheck(prim, in_hashes, in_hash_src),
        "deadZone": {
            "const": "kRollDeadZoneDeg = 1.0（lib/core/imaging/crop_geometry.dart:125）",
            "note": "**`rollSource == 'pupil'` 不蕴含「施加角非零」。** "
                    "`|rollDeg| ≤ 1.0` 时 compose 把角钳到 0、不旋转；"
                    "`pupil` 只说明估计成功，不说明转了多少。判据里不得写 "
                    "「pupil ⟹ applied ≠ 0」——那是错的。",
            "samplesWithAbsTruthAtMost1Deg": sorted(
                r["id"] for r in prim
                if r.get("truthTiltDeg") is not None
                and abs(r["truthTiltDeg"]) <= 1.0),
            "forwardCheck": {
                "what": "|truth| ≤ 1.0 的样本：全部 `straightenDeg == 0.0`，"
                        "但其 `rollSource` 并不都是 `unavailable`。",
                "caveat": "**这是本轮的观察，不是死区的推论。** 死区判的是**估计值**，"
                          "所以「真值小 ⇒ 施加角 0」并不成立——真值 0.9° 而估角器给 5° 的样本"
                          "会被**真的旋转 5°**。本轮恰好全部为 0，是因为这些样本的估计也小。"
                          "读这个分布时不要把「真值小」当成「估计小」的代理。",
                "n": sum(1 for r in prim
                         if r.get("truthTiltDeg") is not None
                         and abs(r["truthTiltDeg"]) <= 1.0),
                "byRollSource": dict(_tally(
                    r.get("rollSource") or "?" for r in prim
                    if r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) <= 1.0)),
                "clampedButNotUnavailable": sorted(
                    r["id"] for r in prim
                    if r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) <= 1.0
                    and r.get("rollSource") == "pupil"),
                "whyItMatters": "「pupil 不蕴含施加角非零」**不是边角情形**："
                                "它在 100 条里覆盖 18 条（18%）。这条若被写反，"
                                "受影响的样本量是两位数。",
            },
            "reverseCheck": {
                "what": "反向：|truth| > 1.0 却 `straightenDeg == 0.0` 的样本，"
                        "其 `rollSource` 是什么？",
                "n": sum(1 for r in prim
                         if r.get("truthTiltDeg") is not None
                         and abs(r["truthTiltDeg"]) > 1.0
                         and r.get("straightenDeg") in (0.0, 0, None)),
                "byRollSource": dict(_tally(
                    r.get("rollSource") or "?" for r in prim
                    if r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) > 1.0
                    and r.get("straightenDeg") in (0.0, 0, None))),
                "ids": sorted(
                    r["id"] for r in prim
                    if r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) > 1.0
                    and r.get("straightenDeg") in (0.0, 0, None)),
                "pupilClampedOutsideDeadZone": sorted(
                    r["id"] for r in prim
                    if r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) > 1.0
                    and r.get("straightenDeg") in (0.0, 0, None)
                    and r.get("rollSource") == "pupil"),
                "conclusion": "**空集**：100 条里没有一条 `pupil` 在 |truth| > 1.0 时"
                              "`straightenDeg == 0.0`（该集合 10 条**全部是 `unavailable`**）。"
                              "**订正措辞（2026-09-17）**：原文写成「在死区之外被静默钳零」，"
                              "把真值当成了估计值的代理——死区判的是**估计值**。"
                              "严格的含义是：对 `pupil` 样本，`applied == 0` ⟺ "
                              "`|估计| ≤ 1.0`，所以本集合为空 ⟺ **本轮不存在"
                              "「真值大、而估计小」的样本**。这正是本次事故的形态"
                              "（真值 −4.4° 被读成 +0.84°），它在本轮缺席——"
                              "**这是关于估角器的经验结论，不是关于死区安全的结论**。",
            },
            "whyHarmless": "**本条订正（2026-09-17）。原文写「死区 1.0 ≤ P0.1a 容差 1.5，"
                           "被钳到 0 的样本其残余天然过线，因此死区本身不制造 P0.1a 违规」"
                           "——该推导**不成立**。死区判的是**估计值**（`crop_geometry.dart:143` "
                           "`roll.abs() <= deadZoneDeg`，入参来自 `compose_engine.dart:235` 的 "
                           "`face?.rollDeg`），**不是真值**。被钳到 0 的样本其残余 = **它自己的真值**，"
                           "≤1.5° 当且仅当真值本来就小，「被钳下」不保证这一点。"
                           "反例：真值 3.0°、估角器错给 0.5° → 钳零 → 残余 3.0° → P0.1a 违规，"
                           "且它返回 `pupil` 而非 `unavailable`，**P0.1b 不拦**。"
                           "**死区不衰减误差，它把小的估计误差透传成满量级残余。**",
            "whyThisRunIsStillClean": "本轮不出违规，靠的是**数据事实**而非死区性质："
                                      "`reverseCheck` 实测，100 条里凡 |truth| > 1.0 且 "
                                      "`straightenDeg == 0.0` 的样本，其 `rollSource` "
                                      "**全部是 `unavailable`**（10/10），没有一条 `pupil` 出现"
                                      "「真值大而估计小」。**这是本轮的经验观察，不是不变量**——"
                                      "换个数据集或估角器失准，死区照样能制造 P0.1a 违规。",
            "example": "c05_d+3：truth = -0.91，实际 applied = 0.0，"
                       "成片残余 -0.938 —— 行为正确。",
        },
        "scoringDenominators": {
            "note": "ACCEPTANCE 计分口径第 1/6/7 条。分母一律用**扣除后可见样本数**，"
                    "并同时给原始总数；`unavailable` 不计通过（剔除，非作 0 观测）；"
                    "不可计分样本逐条列出归类、在总数与通过数里显式扣除。",
            "rawAnchorList": len(truth["anchors"]),
            "distinctAnchorPhotos": 11,
            "distinctAnchorNote": "第 6 条：锚点栏 12 条 − `c03`/`c04` 这一对真重复 "
                                  "= **11 张不同照片**。**订正（2026-09-17）**：原文另称 "
                                  "`c10`/`c11`/`c12` 是「同合影三裁切」——**该理由不成立，已删除**。"
                                  "三者是同一场景的**三张不同照片**，不去重、各自计数"
                                  "（ECC 欧氏对齐后只统计结构像素：`c10`/`c11` 一致度 11.3%、"
                                  "`c10`/`c12` 10.6%，而已知同图对 `c03`/`c04` 为 95.2%，"
                                  "差一个数量级）。数字 11 不变，只订正理由。"
                                  "报告与判据一律按 11 张表述。",
            "P0.1a": {
                "rawTotal": stats("anchor")["rawTotal"],
                "excluded_unavailable": stats("anchor")["excluded_unavailable"],
                "notScorableDeducted": stats("anchor")["notScorableDeducted"],
                "visibleDenominator": stats("anchor")["visibleDenominator"],
            },
            "P0.2_uprightSynthetic": {
                "rawTotal": stats("uprightSynthetic")["rawTotal"],
                "notScorableDeducted": stats("uprightSynthetic")["notScorableDeducted"],
                "visibleDenominator": stats("uprightSynthetic")["visibleDenominator"],
            },
            "P0.3a_rotated": {
                "rawFixtures": len(truth["rotated"]),
                "notScorableDeducted": stats("rotated")["notScorableDeducted"],
                "visibleDenominator": stats("rotated")["visibleDenominator"],
                "note": "`c08_upright` 的语料标签是 uprightSynthetic 而非 rotated，"
                        "其不可计分计入 P0.2 一项；两条合计 6 条。",
            },
        },
        "notScorableClassification": {
            "note": "第 7 条：逐条列出并归类，**总数 6**（rotated 5 + "
                    "uprightSynthetic 1）。**归类为'量测失效'的每一条必须由 "
                    "gatekeeper 用与 qa-batch 不同的独立路径复核并写明结论**——"
                    "把真实缺陷归成'量不出来'是这套判据里最容易藏东西的地方。",
            "thresholds": {"eyeBandZeroFrac": 0.35},
            "items": _classify_not_scorable(
                stats("rotated")["notScorable"]
                + stats("uprightSynthetic")["notScorable"], frac),
            "affectsWhichCriterion": "只影响残差类（P0.1a/P0.2/P0.3a②）的分母；"
                                     "覆盖率类（P0.1b/P0.3b）读的是 rollSource，"
                                     "这几条仍全部计分、不扣除（c08_d-5 同时是 "
                                     "P0.3b 违规之一）。",
        },
        "P0.1a_anchorOutputResidual": stats("anchor"),
        "P0.1b_anchorConditionalCoverage": coverage("anchor"),
        "P0.2_straightOutputResidual": stats("straight"),
        "P0.2_uprightSyntheticOutputResidual": stats("uprightSynthetic"),
        "P0.2_uprightSyntheticCoverage": coverage("uprightSynthetic"),
        "P0.2_allSamplesReturnedPupil": {
            "note": "P0.2 要求竖直样本（p2 + 9 张 uprightSynthetic）必须返回 pupil，"
                    "不接受 unavailable。",
            "straight": {"n": sum(1 for r in comp.values()
                                  if r.get("corpus") == "straight"),
                         "pupil": sum(1 for r in comp.values()
                                      if r.get("corpus") == "straight"
                                      and r.get("rollSource") == "pupil")},
            "uprightSynthetic": {
                "n": sum(1 for r in comp.values()
                         if r.get("corpus") == "uprightSynthetic"),
                "pupil": sum(1 for r in comp.values()
                             if r.get("corpus") == "uprightSynthetic"
                             and r.get("rollSource") == "pupil")},
        },
        "P0.3a_pupilFixtureRegression": {
            "n": len(pu),
            "criterionA_estimate_vs_truth": {
                "note": "ACCEPTANCE P0.3a ①：估计值 rollDeg vs 真值，斜率 ∈[0.85,1.15]。"
                        "**只作诊断**。",
                "slope": None if slope_est is None else round(slope_est, 3),
                "intercept": None if int_est is None else round(int_est, 3),
            },
            "criterionB_outputResidual": {
                "note": "ACCEPTANCE P0.3a ②（口径无关硬判据）：成片残余 vs 真值，"
                        "|斜率| ≤ 0.15 且 |截距| ≤ 0.5° 且 max|残余| ≤ 1.5°。",
                "slope": None if slope is None else round(slope, 3),
                "intercept": None if intercept is None else round(intercept, 3),
                "max_abs_residual_deg": round(
                    max(abs(r["primary_tilt_deg"]) for r in pu), 3) if pu else None,
                "absMaxExcludingGrossOutlier": round(
                    max(abs(r["primary_tilt_deg"]) for r in pu
                        if r["id"] != "c06_d-3"), 3) if len(pu) > 1 else None,
            },
            "grossOutliers": [
                {"id": r["id"], "truth": r["truthTiltDeg"],
                 "applied": round(r["straightenDeg"], 3),
                 "output_tilt": round(r["primary_tilt_deg"], 3),
                 "evidence": r["path"]}
                for r in worst if abs(r["primary_tilt_deg"]) > 1.5],
        },
        "P0.3b_fixtureConditionalCoverage": coverage("rotated"),
        "P0.3b_culpritBreakdown": {
            "note": "9 条违规按源图归并。**不得用'真难样本'标签把 c11 的 5 条兜过去**"
                    "——只有 `c11`(Δ=0, 真值 −0.11) 那一条是死区豁免。",
            "bySource": _count_by_source(
                coverage("rotated")["culprits"]),
            "c11AllSix": {
                "total": 6,
                "violations": 5,
                "harmless": ["c11_d0(Δ=0,truth=-0.11) 死区豁免"],
                "nonMonotonic": "c11_d+3(真值 2.89) 反而是 pupil，与 d-3/-5 不同向",
            },
            "c09Note": "暗光图 Camera Roll/WIN_20230522_00_19_21_Pro.jpg（我 rejected 的 "
                       "c09，两法矛盾 17.07° 未定真值）**不在 P0 语料内、无夹具**，"
                       "在 P0.1b/P0.3b 上既不算通过也不算违规，不占分母。",
        },
        "P0.4_rollSourceDistribution": {
            "byCorpus": (json.load(open(
                os.path.join(REPO, "out", "P0_coverage_post.json"),
                encoding="utf-8")).get("byCorpus")
                if os.path.exists(os.path.join(REPO, "out", "P0_coverage_post.json"))
                else None),
            "unavailableCount": len(un_all),
            "unavailableWithNonZeroRollDeg": [
                r["id"] for r in un_all if r.get("rollDeg") not in (0.0, 0)],
            "coverageRun": "out/P0_coverage_post.json "
                           "(test/batch/p0_coverage_test.dart, 修后)",
        },
        "notScorable_measurementUnreliable": sorted(
            r["id"] for r in prim
            if r["end_to_end_status"] in ("reliability_mismatch", "unmeasured")),
        "alphaHoleIndependentOfRotation": {
            "file": "out/P0_alpha_holes.json",
            "answer": "未旋转真实照片无洞（14/14 人像 eyeBandZeroFrac=0.0）；"
                      "洞只在被旋转过的 c08 夹具上（4/7）。",
            "consequence": "不是独立于摆正的既有缺陷；但会让 c08 夹具的 P0.3 无法计分。",
            "userImpact": "**无用户影响**（生产绝不会把面内旋转过的图喂给抠图引擎）。",
            "codeEvidence": [
                "lib/core/controller.dart:137 —— `_engine.removeBackground(bytes)`，"
                "用户**原始字节**直传，无预处理。",
                "lib/core/matting/ 无任何对像素的面内旋转算子"
                "（无 copyRotate / `.rotate(`）。",
                "lib/core/imaging/compose_engine.dart:232 的 `planRotation` 跑在"
                "抠图**之后**（文件头注第 13 行亦说明），只对已有 alpha 做采样旋转。",
                "lib/core/matting/image_ops.dart:203 `img.bakeOrientation` —— "
                "EXIF 方向烘焙，是 90° 整数倍的**无损转置**，不是面内旋转。",
            ],
            "correctionsToUpstreamClaim": [
                "**路径更正**：EXIF 那处在 `lib/core/matting/image_ops.dart`"
                "（不是 `lib/core/imaging/image_ops.dart` —— 该文件不存在）。",
                "**论据措辞更正（范围问题，不是关键词问题）**：原论据的关键词 grep "
                "是**只对 `matting_engine.dart` 单文件**跑的，**该文件内 0 命中准确**；"
                "但结论被表述为「matting 没有旋转/摆正代码」，读成整个目录完全合理。"
                "按 `lib/core/matting/` 目录复核为 **19 处命中**。"
                "那 19 处全是 `rollDeg` 这个**估计结果字段/标识符**与 "
                "`kPupilMaxRollDeg` 常量，**没有一处是对像素做旋转的算子**。"
                "结论不变，但论据不能写成「关键词 0 命中」——**证据必须连范围一起说**，"
                "范围一放大，真的 0 命中也会变成假证明。"
                "真正的证据是「没有旋转**算子**」+「EXIF 烘焙只是 90° 转置」。",
            ],
        },
        "rotationFailureBoundary": {
            "what": "**不得把「旋转夹具上的失败」一概推广成「夹具伪影」。** "
                    "c08 的空洞是伪影（生产碰不到面内旋转输入），"
                    "但 P0.3 那 1 条硬违规 + 9 条覆盖率违规是**估角器真不稳**，必须修。",
            "evidenceNonMonotonic": {
                "note": "c06 家族在**同一张图**上：|Δ| 最小的一档炸，更大的一档反而干净"
                        "——均匀的伪影不会这样跳。",
                "rows": [
                    {"id": r["id"],
                     "deltaDeg": _fixture_delta(r["id"]),
                     "truthTiltDeg": r.get("truthTiltDeg"),
                     "appliedStraightenDeg": (None if r.get("straightenDeg") is None
                                              else round(r["straightenDeg"], 3)),
                     "outputTiltDeg": (None if r.get("primary_tilt_deg") is None
                                       else round(r["primary_tilt_deg"], 3)),
                     "absResidualDeg": (None if r.get("primary_tilt_deg") is None
                                        else round(abs(r["primary_tilt_deg"]), 3)),
                     }
                    for r in sorted(
                        (x for x in prim if x["id"].startswith("c06")),
                        key=lambda x: str(x["id"]))],
            },
            "evidenceRealTiltHandled": {
                "note": "真实照片锚点本身带真倾角，P0.1a 全过 —— **真倾角能处理，"
                        "合成旋转才炸**。",
                "rows": [
                    {"id": r["id"], "truthTiltDeg": r.get("truthTiltDeg"),
                     "outputTiltDeg": (None if r.get("primary_tilt_deg") is None
                                       else round(r["primary_tilt_deg"], 3)),
                     "rollSource": r.get("rollSource")}
                    for r in prim
                    if r.get("corpus") == "anchor"
                    and r.get("truthTiltDeg") is not None
                    and abs(r["truthTiltDeg"]) > 1.5],
            },
        },
    }


def _sha256_file(p):
    import hashlib
    try:
        with open(p, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except Exception:  # noqa: BLE001
        return None


def _input_hashes(prim, comp_raw):
    """喂给引擎的输入字节 SHA256，逐 id。

    优先取 `p0_compose_test.dart` 在测量当时写下的 `inputSha256`（对
    `readAsBytes()` 的返回值直接取摘要，是权威值）；本轮那份 jsonl 还没有这个
    字段，则退回对 `path` 文件取摘要，并**标注来源**——因为该测试是
    `removeBackground(File(path).readAsBytes())`，两者在无中间变换时相等，
    但"相等"是推断而非实测，必须让消费方看得见。
    """
    by_id = {}
    src = {}
    for r in comp_raw:
        if r.get("specId") != "cn_big_1inch":
            continue
        i = r["id"]
        if r.get("inputSha256"):
            by_id[i] = r["inputSha256"]
            src[i] = "jsonl(测量时)"
        elif i not in by_id:
            h = _sha256_file(r["path"]) if r.get("path") else None
            if h:
                by_id[i] = h
                src[i] = "file(后补：本轮 jsonl 无该字段，按 path 文件取摘要)"
    return by_id, src


def _c05_slope_recheck(prim, hashes, srcs):
    """按 team-lead 要求：c05 的斜率用**全部** Δ 重算并逐条报状态。

    背景：gatekeeper 的 `c05 Δ=-10` 与 qa 的 `c05_d-10` **不是同一份字节**
    （gatekeeper 在内存里旋转原图 483×604；qa 的夹具取自 `out/P0_anchors/c05.png`
    719×900，是原图的 ~1.49× 放大件）。该点卡在瞳孔 blob 门限上，翻一下
    就从 pupil 翻成 unavailable —— 用一个判决不稳定的样本去撑一条斜率，
    结论本身就是脆的。这里把每条 Δ 的状态摊开，让脆弱性可见。
    """
    import numpy as np
    rows = []
    for r in sorted(prim, key=lambda x: x["id"]):
        if not r["id"].startswith("c05"):
            continue
        rows.append({
            "id": r["id"],
            "fixtureDeltaDeg": _fixture_delta(r["id"]),
            "truthTiltDeg": r.get("truthTiltDeg"),
            "rollSource": r.get("rollSource"),
            "appliedStraightenDeg": (None if r.get("straightenDeg") is None
                                     else round(r["straightenDeg"], 3)),
            "outputTiltDeg": (None if r.get("primary_tilt_deg") is None
                              else round(r["primary_tilt_deg"], 3)),
            "methodSpreadDeg": (None if r.get("methodSpreadDeg") is None
                                else round(r["methodSpreadDeg"], 3)),
            "status": r.get("end_to_end_status"),
            "inputSha256": hashes.get(r["id"]),
            "hashSource": srcs.get(r["id"]),
        })
    # Δ=0 锚点本身也要在表里（gatekeeper 的 slope 含 Δ=0）。
    out = {}
    usable = [x for x in rows if x["rollSource"] == "pupil"
              and x["outputTiltDeg"] is not None]
    if len(usable) >= 3:
        xs = np.array([x["truthTiltDeg"] for x in usable])
        ys = np.array([x["outputTiltDeg"] for x in usable])
        out["criterionB_outputResidual_vs_truth"] = {
            "n": len(usable),
            "slope": round(float(np.linalg.lstsq(
                np.vstack([xs, np.ones_like(xs)]).T, ys, rcond=None)[0][0]), 4),
        }
        xa = np.array([x["appliedStraightenDeg"] for x in usable])
        out["criterionA_estimate_vs_truth"] = {
            "n": len(usable),
            "slope": round(float(np.linalg.lstsq(
                np.vstack([xs, np.ones_like(xs)]).T, xa, rcond=None)[0][0]), 4),
        }
    out["note"] = ("**斜率脆弱性是本项要暴露的东西**：c05_d-10 在本路径上是 "
                   "pupil，在 gatekeeper 的字节上是 unavailable，两种判决都离门限很近。"
                   "它一旦翻，c05 的斜率就随之翻——所以 c05 的 slope 不能作为"
                   "独立证据使用。")
    out["rows"] = rows
    return out


def _fixture_delta(idv):
    """从夹具 id 尾部解析 Δ（`c05_d-10` → -10.0；`c05` → 0.0；
    `c05_upright` → 'upright'，不返回 None —— 下游看到 null 会误读成"未知"）。"""
    import re
    if idv.endswith("_upright"):
        return "upright"
    m = re.search(r"_d([+-]\d+)$", idv)
    if m:
        return float(m.group(1))
    return 0.0


def _git(args):
    try:
        r = subprocess.run(["git"] + args.split(), cwd=REPO, capture_output=True,
                           text=True)
        return r.stdout.strip().replace("\n", " | ")
    except Exception:  # noqa: BLE001
        return "unknown"


def _git_ok(argv):
    """取 git 输出；git 正常跑完但非 0 退出时返回 None。

    与 `_git()` 的区别：后者把"命令非 0"和"起不了进程"都压成 `'unknown'`，
    而 `rev-parse HEAD:<path>` 在"该文件不在这个提交里"时**预期内**地非 0 ——
    这正是 commit 绑定要识别的情形，压成 `'unknown'` 就分不出来了。
    argv 走**列表**不做 split：路径可能含空格。

    **刻意不包 try/except。** 这里曾经有 `except Exception: return None`，而本文件
    当时只在函数内部 `import subprocess`，于是 `_git_ok` 抛 NameError 被自己吃掉，
    返回 None —— 上层据此报"取不到 HEAD（非 git 仓库？）"，**把所有指纹的提交绑定
    静默置空，还附了一句错误的解释**。真正的异常（比如本地没有 git）必须炸出来，
    不能降级成"这个对象不存在"。这正是本项目反复记的那个形态。
    """
    r = subprocess.run(["git"] + argv, cwd=REPO, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def _commit_binding(hashes):
    """把被测集绑定到一个 commit（与 `code_fingerprint.dart:commitBinding` 同一口径）。

    按内容记的指纹能回答"变了没有"，回答不了"这是哪个版本的代码"。工作区有未提交
    改动时指纹描述的是一个**历史里不存在的状态** —— 实测 ml-porting 未提交的估角改动
    把 fnv 从 `5ba549780700fba9` 变成 `00a9fa55f822f55e`，后者在任何 commit 里都找不到。
    """
    head = _git_ok(["rev-parse", "HEAD"])
    if not head:
        # 只有在 git 正常跑完（exit 0）却给不出 HEAD 时才走到这里（空仓库等）。
        # 起不了 git 走 `_git_ok` 抛异常，不会降级成本分支。
        return {"headCommit": None, "allCommitted": None,
                "uncommittedMeasuredFiles": [],
                "commitBindingNote": "git 正常退出但给不出 HEAD，无法绑定提交。"}
    uncommitted = sorted(rel for rel, blob in hashes.items()
                         if _git_ok(["rev-parse", f"HEAD:{rel}"]) != blob)
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


def _code_fingerprint():
    """被测代码的**内容**指纹（不是 HEAD）。

    存在的理由：本轮成片/覆盖率/残余三份数字产出于 HEAD b3518ba + ml-porting
    未提交的估角改动；此后主会话又提交了若干 docs-only commit。若按 HEAD 记账，
    会把数字错标到一个与测量无关的 commit 上（实测已发生：evaluatedState 从
    b3518ba 漂到 5d4e89e）。按内容记账则与提交时序无关。

    除内容指纹外另带 **commit 绑定**（`headCommit`/`allCommitted`/未提交文件表）：
    只有内容指纹时，下游能判"不一致"却说不出"测量时跑的是哪份代码"，也就无法判
    `undecidable`。绑定字段是**兄弟字段**，不参与 FNV，故不影响既有 `fnv1a64` 的可比性。
    """
    files = []
    for d in ("lib/core/matting", "lib/core/imaging"):
        p = os.path.join(REPO, *d.split("/"))
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                files += [os.path.join(root, n) for n in names if n.endswith(".dart")]
    api = os.path.join(REPO, "lib", "core", "api.dart")
    if os.path.exists(api):
        files.append(api)
    files.sort()
    hashes = {}
    for f in files:
        rel = os.path.relpath(f, REPO).replace("\\", "/")
        try:
            r = subprocess.run(["git", "hash-object", f], cwd=REPO,
                               capture_output=True, text=True)
            hashes[rel] = r.stdout.strip()
        except Exception:  # noqa: BLE001
            hashes[rel] = "unknown"
    joined = "\n".join(f"{k}:{v}" for k, v in hashes.items())
    h = 0xCBF29CE484222325
    for ch in joined.encode("utf-8"):
        h ^= ch
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return {"files": len(hashes), "fnv1a64": format(h, "016x"),
            "blobHashes": hashes, **_commit_binding(hashes)}



def _measured_state(truth):
    """测量当时的工作区状态，取自各工件自带的记录（不是当前 HEAD）。"""
    cov = os.path.join(REPO, "out", "P0_coverage_post.json")
    head = dirty = None
    if os.path.exists(cov):
        d = json.load(open(cov, encoding="utf-8"))
        head, dirty = d.get("gitCommit"), d.get("workingTreeDirty")
    comp = os.path.join(REPO, "out", "P0_compose_summary.json")
    fp_measured = None
    round_valid = None
    changed_files = []
    if os.path.exists(comp):
        d = json.load(open(comp, encoding="utf-8"))
        pv = d.get("provenance") or {}
        fp_measured = pv.get("codeFingerprint")
        # 本轮**自己**是否有效：开跑/收尾两次指纹若不一致，说明跑的过程中代码被改过，
        # 这份数字不属于任何一个稳定版本。它是比"测量后漂移"更硬的一种失效——
        # 那种是数字过期，这种是数字从来就没对过任何版本。
        round_valid = pv.get("roundValid")
        if round_valid is None and "codeStableDuringRun" in pv:
            round_valid = pv.get("codeStableDuringRun")
        changed_files = pv.get("changedFiles") or []
    fp_now = _code_fingerprint()
    fp_meas_fnv = None if fp_measured is None else fp_measured.get("fnv1a64")
    if round_valid is False:
        verdict_code = "round_self_invalid"
        verdict = ("**本轮自身即失效**：成片台开跑/收尾两次指纹不一致，"
                   f"跑的过程中被测代码被改过（变更文件：{changed_files}）。"
                   "这份数字绑不到任何代码版本，**不得用作门禁判据**，必须重跑。")
    elif fp_measured is None:
        verdict_code = "unprovable"
        verdict = ("**无法自证**：产出成片的 `p0_compose_summary.json` 里没有"
                   " `provenance.codeFingerprint`（本轮跑的时候还没加这个字段），"
                   "因此不能证明这些数字对应的代码内容 = 现在的代码内容。"
                   "ml-porting 提交后重跑一遍即可补上，届时此字段会给出比对结论。")
    elif fp_meas_fnv != fp_now.get("fnv1a64"):
        # 门禁口径：不一致即 `undecidable` —— **不许拿旧代码的数当本轮的数**。
        verdict_code = "undecidable"
        verdict = ("**不可判定（undecidable）**：测量当时的被测代码内容与现在**不一致**，"
                   f"因此无法判定本文件的数字是否属于这份代码。测量时 "
                   f"{fp_measured.get('fnv1a64')}（{fp_measured.get('commitBindingNote')}）、"
                   f"现在 {fp_now.get('fnv1a64')}。必须重跑全链。")
    else:
        verdict_code = "attributable"
        bind = fp_measured.get("headCommit") or "(未知提交)"
        verdict = ("**可归属**：测量当时的被测代码内容与现在逐文件相同，数字未被后续改动"
                   f"污染，可归到 {bind}。"
                   + ("" if fp_measured.get("allCommitted") else
                      " 注意测量时工作区**有未提交改动**，故该指纹不对应任何提交，"
                      "只能按内容比对。"))
    return {
        "note": "**这不是 HEAD。** 成片/覆盖率/残余三份数字产出于下表记录的"
                "工作区状态；此后主会话提交了若干 docs-only commit，按 HEAD 记账"
                "会把数字错标到与测量无关的 commit 上。",
        "gitHeadAtCoverageRun": head,
        "workingTreeDirtyAtCoverageRun": dirty,
        "roundSelfValid": round_valid,
        "roundChangedFiles": changed_files,
        "codeFingerprintAtFinalize": {"fnv1a64": fp_now["fnv1a64"],
                                      "files": fp_now["files"],
                                      "headCommit": fp_now.get("headCommit"),
                                      "allCommitted": fp_now.get("allCommitted")},
        "codeFingerprintAtMeasure": (None if fp_measured is None
                                     else {"fnv1a64": fp_measured.get("fnv1a64"),
                                           "files": fp_measured.get("files"),
                                           "headCommit": fp_measured.get("headCommit"),
                                           "allCommitted": fp_measured.get("allCommitted"),
                                           "uncommittedMeasuredFiles":
                                               fp_measured.get("uncommittedMeasuredFiles"),
                                           "commitBindingNote":
                                               fp_measured.get("commitBindingNote")}),
        "fingerprintVerdictCode": verdict_code,
        "fingerprintVerdict": verdict,
        "headAtFinalize": _git("rev-parse --short HEAD"),
    }



def main():
    # 幂等：v0 原始文件留一份底，之后每次从它重建，重复运行不会把 methods
    # 套娃成两层。
    v0 = os.path.join(REPO, "out", "P0_truth_v0.json")
    if not os.path.exists(v0):
        with open(TRUTH, encoding="utf-8") as fh:
            src = json.load(fh)
        if src.get("version") != 1:
            with open(v0, "w", encoding="utf-8") as fh:
                json.dump(src, fh, ensure_ascii=False, indent=1)
    truth = json.load(open(v0, encoding="utf-8"))
    resid = json.load(open(RESID, encoding="utf-8"))
    e2e = {}
    for r in resid["items"]:
        cur = e2e.get(r["id"])
        # 主规格优先
        if cur is None or r["specId"] == "cn_big_1inch":
            e2e[r["id"]] = r

    old_conv = truth.get("conventionDetail") or truth.get("convention") or {}
    conv_detail = dict(old_conv)
    conv_detail["trueRollDeg"] = (
        "本文件的历史字段名，等价于 truth_apply_deg：实测倾角 tilt（见 convention）")
    conv_detail["expectedEngineRollDeg"] = (
        "FaceInfo.rollDeg 应输出的值。**实测等于 tilt，不取负**。"
        "（旧版此处的 signTrap 注记已失效：api.dart / CONTRACTS.md §6 已改正，"
        "三处口径现已一致。）")
    conv_detail["outputResidual"] = (
        "硬判据：成片端到端残余 = 成片眼线的实测倾角，理想 0。"
        "与符号约定无关——摆正了就是 0；符号写反会得到 2×真值，一眼可见。"
        "见 out/P0_output_residual.json，产出脚本 test/batch/p0_output_residual.py，"
        "成片由 test/batch/p0_compose_test.dart 走生产引擎生成。")
    conv_detail["fixtureDelta"] = (
        "夹具应有 tilt = 锚点真值 + deltaDeg；生成用 PIL.rotate(-deltaDeg, BICUBIC)")
    conv_detail.pop("signTrap", None)
    conv_detail["measurementProvenance"] = (
        "全部数值由纯 Python（PIL/OpenCV/scipy）测量，**不调用任何被测 Dart 代码**；"
        "Dart 侧只负责产出成片（被测量对象）。")

    def wrap(a, kind, corpus):
        o = dict(a)
        o["path"] = absfix(o["path"])
        o["kind"] = kind
        o["corpus"] = corpus
        o["truth_apply_deg"] = o.get("trueRollDeg")
        o["methods"], o["derivedAnnotations"] = methods_block(o, a["id"])
        if corpus == "anchor":
            o["visual_review"] = VISUAL.get(a["id"], "")
        elif corpus == "straight":
            o["visual_review"] = _STRAIGHT_VISUAL
        else:
            o["visual_review"] = _UPRIGHT_VISUAL.replace("<src>", str(a.get("src")))
        e = e2e.get(a["id"])
        if e:
            o["end_to_end"] = {
                "spec": e.get("specId"),
                "output_tilt_deg": e.get("primary_tilt_deg"),
                "output_tilt_by_method": {
                    k: (v.get("deg") if isinstance(v, dict) else None)
                    for k, v in e.items()
                    if k in ("m1_pupil", "m1h_pupil_haarseed", "m2_radon_yunet",
                             "m3_haar_eyeline", "m4_radon_haar")},
                "tilt_abs_max_deg": e.get("tiltAbsMaxDeg"),
                "method_spread_deg": e.get("methodSpreadDeg"),
                "roll_source": e.get("rollSource"),
                "applied_straighten_deg": e.get("straightenDeg"),
                "truth_consistency_deg": e.get("truthConsistencyDeg"),
                "status": e.get("end_to_end_status"),
                "note": e.get("end_to_end_note"),
                "evidence": e.get("path"),
            }
        return o

    anchors = [wrap(a, "portrait", "anchor") for a in truth["anchors"]]
    # gatekeeper 要求 anchors 内至少 1 条 kind:"upright"。p2 是唯一"真实照片 +
    # 已知竖直"，同时保留在 straight 段（两处同源，id 相同，消费方按 id 去重）。
    p2 = dict(truth["straight"][0])
    p2["id"] = "p2"
    anchors.append(wrap(p2, "upright", "straight"))

    straight = [wrap(a, "upright", "straight") for a in truth["straight"]]
    uprights = [wrap(a, "upright", "uprightSynthetic")
                for a in truth["uprightSynthetic"]]
    rotated = []
    for a in truth["rotated"]:
        o = dict(a)
        o["path"] = absfix(o["path"])
        o["truth_apply_deg"] = o.get("expectedTiltDeg")
        e = e2e.get(o["id"])
        if e:
            o["end_to_end"] = {
                "spec": e.get("specId"),
                "output_tilt_deg": e.get("primary_tilt_deg"),
                "tilt_abs_max_deg": e.get("tiltAbsMaxDeg"),
                "method_spread_deg": e.get("methodSpreadDeg"),
                "roll_source": e.get("rollSource"),
                "applied_straighten_deg": e.get("straightenDeg"),
                "truth_consistency_deg": e.get("truthConsistencyDeg"),
                "status": e.get("end_to_end_status"),
                "note": e.get("end_to_end_note"),
                "evidence": e.get("path"),
            }
        rotated.append(o)

    truth["version"] = 1
    truth["convention"] = CONVENTION
    truth["conventionDetail"] = conv_detail
    truth["anchors"] = anchors
    truth["straight"] = straight
    truth["uprightSynthetic"] = uprights
    truth["rotated"] = rotated
    truth["anchorCount"] = len(anchors)
    truth["endToEndResidual"] = {
        "summary": resid["summary"],
        "perItemFile": "out/P0_output_residual.json",
        "composedDir": "out/P0_anchors/composed/",
        "composedBy": "test/batch/p0_compose_test.dart（生产引擎，white 底）",
        "measuredBy": "test/batch/p0_output_residual.py（纯 Python）",
        "smallImageReliability": resid.get("smallImageReliability"),
    }
    truth["knownLimitations"] = [
        "c03 与 c04 是同一张照片的不同分辨率副本（缩放后逐像素 mean|diff|≈2，"
        "缩放比 0.4165 恰为分辨率比、相对旋转 −0.024°），统计独立样本时应视为 1 张："
        "anchor 栏 12 条实际覆盖 11 张不同照片。",
        "c10 / c11 / c12 是**同一场景、同一群人的三张不同照片**，"
        "**不是**同一张照片的不同裁切。复核方法：ECC 对齐后只统计结构像素"
        "（Sobel 梯度 >25）的逐像素差，三对的一致度 10–11%（≤5 灰阶）；"
        "而确为同一张不同分辨率副本的 c03/c04 达到 95%——两端差一个数量级。"
        "三张均为 4032×3024 全画幅原图，可见取景与站位不同。"
        "证据图 out/P0_anchors/c10_c11_c12_sheet.png。",
        "锚点集以东亚男性青年为主，无儿童/老人/深肤色/强逆光样本，"
        "不能据此声称普适覆盖率。",
        "c08 的**被旋转过的**夹具（d-10/d-5/d+3/upright）抠图会在双眼区域产生"
        "大面积 alpha=0，其成片残余不可测（end_to_end.status=reliability_mismatch / "
        "unmeasured）。**未旋转的原图本身没有洞**：Pictures 全量可评估人像 14 张的 "
        "eyeBandZeroFrac 全部 = 0.0（含两张 Camera Roll 原图）。即这是"
        "**旋转诱导**的抠图失效，不是独立于摆正的既有缺陷。证据 "
        "out/P0_alpha_holes.json。",
    ]

    truth["evaluatedState"] = _measured_state(truth)
    truth["gateInputs"] = gate_inputs(truth, resid)

    with open(TRUTH, "w", encoding="utf-8") as fh:
        json.dump(truth, fh, ensure_ascii=False, indent=1)
    # sidecar：喂给引擎的输入字节摘要，供 gatekeeper 对齐夹具。
    hi = truth["gateInputs"]["inputHashes"]
    side = {
        "generatedBy": "qa-batch test/batch/p0_finalize_v1.py",
        "algorithm": hi["algorithm"],
        "note": hi["note"],
        "provenanceById": hi["provenanceById"],
        "byId": hi["byId"],
        "c05ConflictNote": {
            "what": "gatekeeper 的 `c05 Δ=-10` 与 qa 的 `c05_d-10` 不是同一份字节。"
                    "**谁都没测错，是输入不同源。**",
            "qaFixtureReproduced": "qa 的 out/P0_anchors/c05_d-10.png 与 "
                                   "PIL.rotate(exif_transpose(a.jpg), +10, BICUBIC, "
                                   "expand=False, fillcolor=白) **逐像素相同（MAE 0.00）**。",
            "whereTheyDiffer": "与 fillcolor=黑 的同参数重放相比，MAE = 19.29 —— 即 "
                               "gatekeeper 侧那个「最接近的重放」值。差异像素 22068 / "
                               "291732 = **7.56%**，**全部落在画面中央 60% 框之外**"
                               "（中央框内差异像素 = 0）。",
            "diagnosis": "两条路径的**图像内容完全一致**，只差旋转出画后四角三角区的"
                         "填充色（qa 填白，gatekeeper 侧表现为填黑）。该样本卡在瞳孔 blob "
                         "门限上，四角填充色竟足以把 rollSource 从 pupil 翻成 unavailable —— "
                         "这本身说明该点的判决不稳定，不能用来撑一条斜率。",
            "caveat": "「gatekeeper 侧填黑」是据其给出的 MAE 19.29 反推的最优解释，"
                      "未直接读其源码确认；请 gatekeeper 用本文件 byId 的哈希自证。",
            "howToAlign": "**以 byId[id] 的 SHA256 为准对齐**，不以文件名/尺寸为准"
                          "（c04/c05 尺寸恰好相同，看尺寸会误判同源）。"
                          "更根本的做法：gatekeeper 直接消费 qa 落盘的夹具字节"
                          "（按哈希校验），不要各自重新推导——重新推导时任何实现细节"
                          "（填充色、重采样库）都会改变输入，进而改变判决。",
        },
    }
    with open(os.path.join(REPO, "out", "P0_input_hashes.json"), "w",
              encoding="utf-8") as fh:
        json.dump(side, fh, ensure_ascii=False, indent=1)
    print(f"wrote {TRUTH}")
    print("wrote out/P0_input_hashes.json")
    print(f"anchors={len(anchors)} (portrait={sum(1 for a in anchors if a['kind']=='portrait')}, "
          f"upright={sum(1 for a in anchors if a['kind']=='upright')}) "
          f"straight={len(straight)} uprightSynthetic={len(uprights)} "
          f"rotated={len(rotated)}")
    with_e2e = sum(1 for a in anchors + straight + uprights if a.get("end_to_end"))
    print(f"anchors+straight+upright 带 end_to_end 的：{with_e2e}")


if __name__ == "__main__":
    main()
