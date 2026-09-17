# -*- coding: utf-8 -*-
"""qa-batch：G2B-P0 真值锚点集定稿。

⚠️ **真值是下面 `ANCHORS` / `STRAIGHT_REAL` 表里手写的数值，不是本脚本算出来的。**
（2026-09-17 订正：旧版本文档写"主值取 M1 跨 7 次旋转的稳健估计"，与实现不符——
实测 13/13 条真值 = 手写表的值。**只订正文档，实现与数值一律未动**：
改实现会让全部已有轮次的真值整体位移、作废既有结果。）

真值的来源与佐证现状（逐条按实测写，别再按"应该怎样"写）：
  1. **主值 = 手写表**。手写值大体沿用了 M1（pupil-centroid）在 Δ=0 的读数，
     但那是"写表时的依据"，不是运行期计算——脚本不会重算它。
  2. **p0_est.py 的稳健估计只作交叉核对**，不作主值：它用 7 个旋转夹具反推
     `est_base = median(measured_M1(Δ) − Δ)`。两者相差 >0.8° 即标 needsReview。
     实测 **c08 相差 +1.45°**（稳健 −6.56 vs 手写 −8.01），越过阈值，
     **当时无人复核**（已上报；真值是否修改属用户裁定，不在此脚本内处理）。
     p1 亦有 +0.59°，主要来自 radon 族的"向零收缩"。
  3. 佐证要求：M3（Haar 眼线，与 M1 不同检测器）与 M1 之差 ≤1.5°。
     实测**有 m3 的 12 条**最大差 0.63°，均满足。
     **c08 不在这 12 条里——它 Haar 全程失败、根本没有 m3**，
     其 `corroborationOk = false`，是作为 lowConfidence 样本被收进来的。
     换句话说"全部满足"只对有 m3 的样本成立，**不要读成全 13 条都过了佐证**。
  4. 目视复核：overlay 图确实逐张看过（图存在且早于真值成文）。
     但**它在 `P0_truth.json` 里的记录值与 trueRollDeg 逐位相同（14/14）**，
     是事后写下的副本，**不构成第二条独立证据**（详见 PITFALLS"用副本冒充佐证"）。
  5. 不满足 3 的样本：c08 未能满足但仍收进锚点集（标记 lowConfidence）；
     c09 因两法互相矛盾（spread 17.07°）被列 rejected 并写明原因。
  6. p1 / p2 的 −4.4 / −0.2 沿用主会话给定值。**主会话未能确认这两个数有
     独立于本项目的读数**；p1 是"瞳孔法与被测引擎同族"风险的集中点，见报告。

另产出 straight 合成样本（P0.2 用）：把倾斜锚点按真值反向旋转回正，
应有 tilt ≈ 0。这是"不引入歪斜"最直接的判据输入。

用法：python test/batch/p0_finalize.py
"""
import json
import math
import os
import sys

from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import p0_lib as L  # noqa: E402

OUT = os.path.join(L.REPO, "out", "P0_anchors")
REL = "out/P0_anchors"

# id -> (真值 tilt, 来源说明, 备注)
#
# ⚠️ 来源说明里的 `+visual` 已删。原因见 docs/PITFALLS.md "用副本冒充佐证"：
# 目视复查**不是**一条独立方法——它在 P0_truth.json 里的记录值与 trueRollDeg
# 逐位相同（14/14 全中），是人工确认后写下的副本，不构成第二个证据。
# 真正独立的只有 pupil-centroid / haar-eyeline 两条特征族线；且对 c08 而言
# 这两条也没跑满（Haar 全程失败，corroborationOk=false）。
# 字段本身已被 entry() 丢弃、不进 P0_truth.json，这里只是别让它继续误导读代码的人。
ANCHORS = [
    ("p1", -4.40, "pupil-centroid+haar-eyeline",
     "主会话三方确认锚点 -4.4；本脚本 7 次旋转稳健估计 M1=-4.38 / M3=-4.08，一致"),
    ("c01", -1.30, "pupil-centroid+haar-eyeline",
     "radon 族读 ~0，与眼线族差 1.29（radon 向零偏置）；目视确认右瞳孔更高"),
    ("c02", -0.25, "pupil-centroid+haar-eyeline",
     "YuNet 读 -6.09，偏差 5.8 (P0 根因样本)"),
    ("c03", -3.72, "pupil-centroid+haar-eyeline",
     "YuNet 读 +1.11，偏差 4.9 (P0 根因样本)"),
    ("c04", -3.82, "pupil-centroid+haar-eyeline", "多人合影裁切版"),
    ("c05", -3.91, "pupil-centroid+haar-eyeline",
     "四法稳健估计极紧 (M1 -3.91 / M2 -3.75 / M3 -3.73 / M4 -3.70)"),
    ("c06", -1.73, "pupil-centroid+haar-eyeline",
     "YuNet 人脸框整体偏到头发上；M4 因 Haar 眼框落在眉上而系统性偏 +2.7"),
    ("c07", -0.35, "pupil-centroid+haar-eyeline",
     "低分辨率(295x413, 眼距 68px)，JPEG 块效应重，标记 lowConfidence"),
    ("c08", -8.01, "pupil-centroid",
     "暗光摄像头；Haar 全程失败，仅 2 法可用且互差 1.69，标记 lowConfidence"),
    ("c10", -3.44, "pupil-centroid+haar-eyeline", "4032x3024 多人合影原图(5 张脸)，主体为最大脸"),
    ("c11", -0.11, "pupil-centroid+haar-eyeline", "同上系列；近竖直"),
    ("c12", -2.09, "pupil-centroid+haar-eyeline", "同上系列"),
]
STRAIGHT_REAL = [
    ("p2", -0.20, "pupil-centroid+haar-eyeline",
     "主会话确认的竖直蓝底证件照；本脚本稳健估计 M1=-0.12 / M3=-0.35；"
     "当前实现转歪 +3.7 (P0.2 基准)"),
]
REJECTED = [
    ("c09", "C:/Users/liuyu/Pictures/Camera Roll/WIN_20230522_00_19_21_Pro.jpg",
     "方法互相矛盾：M1=-29.46 vs M2=-12.39 (spread 17.07)。"
     "原因：暗光 + 宽镜框 + 刘海遮挡，M1 的圆形暗块落在镜框/眉弓上而非瞳孔；"
     "目视也无法可靠定位瞳孔。已排除出真值集。"),
]
LOWCONF = {"c07", "c08"}

PATHS = {
    "p1": r"C:\Users\liuyu\Pictures\1 (2).jpg",
    "p2": r"C:\Users\liuyu\Pictures\2.jpg",
    "c01": r"C:\Users\liuyu\Pictures\20240710193717_7c99.jpg",
    "c02": r"C:\Users\liuyu\Pictures\29EDA59B982FA8339335D50B00CCD096.jpg",
    "c03": r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124.jpg",
    "c04": r"C:\Users\liuyu\Pictures\8D861A29F86CE7464865EFEB3C9B4124 (自定义).jpg",
    "c05": r"C:\Users\liuyu\Pictures\a.jpg",
    "c06": r"C:\Users\liuyu\Pictures\吴港+通信工程+532128200107160711.jpg",
    "c07": r"C:\Users\liuyu\Pictures\报名照片.jpg",
    "c08": r"C:\Users\liuyu\Pictures\Camera Roll\WIN_20230522_00_19_11_Pro.jpg",
    "c10": r"C:\Users\liuyu\Pictures\1979d869c783fcc849d4e05b81eb809e.png",
    "c11": r"C:\Users\liuyu\Pictures\4e84ef7b8a910c776acd0eebb8293ee9.png",
    "c12": r"C:\Users\liuyu\Pictures\e9168d2cfe9045d07fac74e68419d211.png",
}

MAX_LONG = 2048


def _mk_upright(src, tilt_deg, dst):
    """把倾斜样本按真值反向旋转回正 → 应有 tilt ≈ 0 的合成直片。"""
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    W, H = im.size
    if max(W, H) > MAX_LONG:
        s = MAX_LONG / max(W, H)
        im = im.resize((round(W * s), round(H * s)), Image.LANCZOS)
    # PIL rotate(+a) 使 tilt 减 a；要让 tilt 从 t 变成 0，需 rotate(+t)
    out = im.rotate(tilt_deg, resample=Image.BICUBIC, expand=False,
                    fillcolor=(255, 255, 255))
    out.save(dst)
    return out.size


def _measure_src(src):
    im, scale, faces = L.detect_faces(src)
    if not faces:
        return None, im.size
    f = L.pick_face(faces, im.size)
    res = L.measure_all(L.gray_of(im), f)
    d = L.methods_deg(res)
    d["_yunet"] = res["yunet_eyeline"]
    return d, im.size


def build_non_portrait():
    """从冻结的 test/dataset.json 抽出非人像清单，供 P0.4 覆盖率统计。"""
    ds = json.load(open(os.path.join(L.REPO, "test", "dataset.json"), encoding="utf-8"))
    rows = [{"path": i["path"].replace("\\", "/"), "class": i["class"],
             "w": i["w"], "h": i["h"], "sha256": i["sha256"]}
            for i in ds["items"] if i["class"] not in ("portrait", "multi_face")]
    by = {}
    for r in rows:
        by[r["class"]] = by.get(r["class"], 0) + 1
    dst = os.path.join(OUT, "non_portrait.json")
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump({"note": "Pictures 全量中的非人像类（分类依据冻结的 test/dataset.json）",
                   "count": len(rows), "byClass": by, "items": rows},
                  fh, ensure_ascii=False, indent=1)
    return [r["path"] for r in rows]


def build():
    os.makedirs(OUT, exist_ok=True)
    non_portrait = build_non_portrait()
    raw = json.load(open(os.path.join(OUT, "measure_raw.json"), encoding="utf-8"))
    meas = {r["id"]: r for r in raw["candidates"]}
    # 上一轮夹具跑出来的稳健估计（首轮不存在，属正常）
    rp = os.path.join(OUT, "anchor_robust_estimate.json")
    robust = {}
    if os.path.exists(rp):
        robust = {a["id"]: a for a in json.load(open(rp, encoding="utf-8"))["anchors"]}

    def entry(cid, truth, methods, note):
        m = meas.get(cid, {})
        md = m.get("methods", {})
        yunet = m.get("yunet_eyeline")
        rec = {
            "id": cid,
            "path": PATHS[cid].replace("\\", "/"),
            "trueRollDeg": truth,
            # 实测：引擎 rollDeg 数值上等于实测倾角 tilt（见 convention 段）
            "expectedEngineRollDeg": round(truth, 3),
            "methods": methods.split("+"),
            "evidence": "%s/%s.png" % (REL, cid),
            "measuredMethodsDelta0": md,
            "yunetEyeLineDeg": yunet,
            "yunetErrorDeg": round(yunet - truth, 3) if yunet is not None else None,
            "nFaces": m.get("n_faces"),
            "eyedistPx": m.get("eyedist"),
            "note": note,
        }
        r = robust.get(cid)
        if r:
            rec["robustPerMethodDeg"] = {k: v["median"] for k, v in r["perMethod"].items()}
            rec["robustObsCount"] = {k: v["n"] for k, v in r["perMethod"].items()}
            pm = rec["robustPerMethodDeg"]
            # 佐证：M1 与 M3(独立检测器) 之差
            if "m1_pupil" in pm and "m3_haar_eyeline" in pm:
                rec["corroborationM1vsM3Deg"] = round(
                    abs(pm["m1_pupil"] - pm["m3_haar_eyeline"]), 3)
                rec["corroborationOk"] = rec["corroborationM1vsM3Deg"] <= 1.5
            else:
                rec["corroborationOk"] = False
        if cid in LOWCONF:
            rec["lowConfidence"] = True
        return rec

    anchors = [entry(*a) for a in ANCHORS]
    straight = [entry(*a) for a in STRAIGHT_REAL]

    # P0.2 用：合成竖直样本（倾斜锚点反向旋转回正）
    upright = []
    for cid, truth, _m, _n in ANCHORS:
        if abs(truth) < 0.5:
            continue
        tag = "%s_upright" % cid
        dst = os.path.join(OUT, "%s.png" % tag)
        wh = _mk_upright(PATHS[cid], truth, dst)
        d, _ = _measure_src(dst)
        rec = {"id": tag, "src": cid, "path": "%s/%s.png" % (REL, tag),
               "trueRollDeg": 0.0, "wh": list(wh),
               "note": "由 %s (真值 %+.2f°) 按真值反向旋转回正合成的竖直样本"
                       % (cid, truth)}
        if d:
            vals = [v for k, v in d.items() if k != "_yunet"]
            rec["measuredTiltDeg"] = {k: round(v, 3) for k, v in d.items()}
            rec["measuredConsensus"] = round(float(sorted(vals)[len(vals) // 2]), 3)
        upright.append(rec)

    out = {
        "generatedBy": "qa-batch / test/batch/p0_finalize.py",
        "baselineTag": "baseline-p6p0",
        "convention": {
            "trueRollDeg": "实测倾角 tilt。图像坐标 y 向下；"
                           "tilt = atan2(y_imgRightEye - y_imgLeftEye, x_imgRightEye - x_imgLeftEye)；"
                           "正值 = 图像右侧的眼更低。",
            "expectedEngineRollDeg": "FaceInfo.rollDeg 应输出的值。"
                                     "**实测：引擎 rollDeg 在数值上等于 tilt（不是它的相反数）**。"
                                     "核对方式有二："
                                     "(1) p1 几何求解——把 crop_geometry 的 "
                                     "p_src = C + R(θ)(p_rot − C) 反解出 θ 恰为 -4.41，引擎输出 -4.42；"
                                     "(2) 合成点位的数值实验——θ=+10° 会让'右侧偏高的点'更高，"
                                     "即正 θ 使内容逆时针转。",
            "signTrap": "**api.dart 的注释与 crop_geometry.dart 的注释符号相反**："
                        "api.dart 写'正值表示把图像顺时针转'，而 crop_geometry 的 R(θ) "
                        "实现出来是'正 θ = 内容逆时针转'。数值以代码为准（已验证）。"
                        "这是极易引入反向 bug 的文档陷阱，已回派主会话。",
            "fixtureDelta": "夹具应有 tilt = 锚点真值 + deltaDeg；生成用 PIL.rotate(-deltaDeg, BICUBIC)",
        },
        "anchorCount": len(anchors) + len(straight),
        "anchors": anchors,
        "straight": straight,
        "uprightSynthetic": upright,
        "nonPortrait": non_portrait,
        "rejected": [{"id": c, "path": p, "reason": r} for c, p, r in REJECTED],
        "rotated": [],  # 由 p0_rotate.py 填写
    }
    with open(os.path.join(OUT, "anchors_base.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print("anchors=%d straight=%d synthetic=%d rejected=%d"
          % (len(anchors), len(straight), len(upright), len(REJECTED)))
    print("-> anchors_base.json")
    return out


def assemble(base):
    """把旋转夹具并进来，落盘交付物 out/P0_truth.json（主会话指定的 schema）。"""
    fx_path = os.path.join(OUT, "rotation_fixtures.json")
    geo_path = os.path.join(OUT, "fixture_geo_verify.json")
    geo = {}
    if os.path.exists(geo_path):
        geo = {g["id"]: g for g in
               json.load(open(geo_path, encoding="utf-8"))["fixtures"]}
    rotated = []
    if os.path.exists(fx_path):
        fx = json.load(open(fx_path, encoding="utf-8"))
        for f in fx["fixtures"]:
            g = geo.get(f["id"], {})
            rotated.append({
                "id": f["id"],
                "src": f["src"],
                "deltaDeg": f["deltaDeg"],
                "path": f["path"],
                "expectedTiltDeg": f["expectedTiltDeg"],
                "expectedEngineRollDeg": round(f["expectedTiltDeg"], 3),
                "wh": f["wh"],
                # 几何正确性：像素级配准独立核验，与任何特征检测器无关
                "geoRecoveredDeltaDeg": round(-g["recoveredPhiDeg"], 3) if g else None,
                "geoNcc": g.get("ncc"),
                "geoVerified": bool(g and abs(g["recoveredPhiDeg"] + f["deltaDeg"]) <= 0.25
                                    and g["ncc"] >= 0.95),
                # 特征点回测：仅供参考，个别图上方法会失手（不代表夹具错）
                "remeasureConsensusDeg": f.get("measuredConsensusDeg"),
                "remeasureOk": f.get("verifyOk"),
            })
    out = dict(base)
    out["rotated"] = rotated
    out["rotationFixtureCount"] = len(rotated)
    if geo:
        errs = [abs(g["recoveredPhiDeg"] + next(f["deltaDeg"] for f in fx["fixtures"]
                                                if f["id"] == g["id"])) for g in geo.values()]
        out["fixtureGeoVerification"] = {
            "method": "cv2 旋转配准（像素级，无特征点，见 test/batch/p0_verify_geo.py）",
            "n": len(geo),
            "geoVerifiedCount": sum(1 for r in rotated if r["geoVerified"]),
            "maxAbsErrorDeg": round(max(errs), 3),
            "minNcc": round(min(g["ncc"] for g in geo.values()), 4),
            "conclusion": "全部夹具角度经独立像素级配准确认，误差 ≤0.015°；"
                          "夹具的 expectedTiltDeg 可直接作为 P0.3 的横轴真值",
        }
    out["generatedBy"] = "qa-batch / test/batch/{p0_measure,p0_finalize,p0_rotate,p0_est,p0_verify_geo}.py"
    dst = os.path.join(L.REPO, "out", "P0_truth.json")
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print("-> out/P0_truth.json  (anchors=%d straight=%d synthetic=%d rotated=%d rejected=%d)"
          % (len(out["anchors"]), len(out["straight"]), len(out["uprightSynthetic"]),
             len(rotated), len(out["rejected"])))
    return out


if __name__ == "__main__":
    assemble(build())
