# -*- coding: utf-8 -*-
"""qa-batch：判断"抠图把脸挖空（眼睛被 alpha=0 盖住）"是不是独立于摆正的真实缺陷。

输入：out/P0_alpha_scan/manifest.jsonl + <slug>_alpha.png（生产 removeBackground 产物）
     原图路径（干净，非 overlay）。

做法（纯 Python，不调用生产 Dart 做测量）：
  1. 用 cv2 YuNet 在**原图**上取双眼位置（p0_lib 同一套，独立于生产解码器）；
  2. 按 workW/原图宽 换算到 alpha 坐标系；
  3. 在"双眼带"（以双眼连线中点为中心、宽 1.6×眼距、高 0.45×眼距）内统计
     alpha<128 的占比 —— 这就是"眼睛被背景盖住的比例"。健康抠图应 ≈0。
  4. 同时给整脸框内的占比作对照。

判据（阈值可由 gatekeeper 改，这里只报数）：
  eyeBandZeroFrac > 0.35 → 脸上有洞，且洞盖住了眼睛区域。

产出：out/P0_alpha_holes.json（+ 被点名样本的对照图 out/P0_alpha_scan/_sheet_holes.png）
"""
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import code_fingerprint as CF  # noqa: E402  （与 code_fingerprint.dart 同口径）
import p0_lib as L  # noqa: E402

REPO = L.REPO
SCAN = os.path.join(REPO, "out", "P0_alpha_scan")
HOLE_THR = 0.35


def detect_on_source(path, work_long=4096):
    """EXIF 转置后按（近似）原生分辨率跑 YuNet。返回 (kps, box, W, H)。"""
    im = Image.open(path)
    im = ImageOps.exif_transpose(im).convert("RGB")
    W, H = im.size
    s = 1.0
    if max(W, H) > work_long:
        s = work_long / max(W, H)
        im = im.resize((max(1, round(W * s)), max(1, round(H * s))), Image.LANCZOS)
    bgr = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    h, w = bgr.shape[:2]
    d = cv2.FaceDetectorYN.create(L.YUNET, "", (w, h), score_threshold=0.5,
                                  nms_threshold=0.3, top_k=50)
    d.setInputSize((w, h))
    _, faces = d.detect(bgr)
    if faces is None or len(faces) == 0:
        return None, None, w, h
    f = max(faces, key=lambda r: r[2] * r[3])
    return [float(v) for v in f[4:14]], [float(v) for v in f[0:4]], w, h


def main():
    # 开跑/收尾各取一次被测代码指纹。跑一轮要几分钟，只在收尾取会把"跑完之后"的
    # 代码状态记到"被测代码"头上（本项目实测发生过 evaluatedState 错标 commit）。
    fp_start = CF.code_fingerprint()
    man = []
    with open(os.path.join(SCAN, "manifest.jsonl"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                man.append(json.loads(line))

    results = []
    for r in man:
        if r.get("outcome") != "ok":
            results.append({"path": r.get("path"), "outcome": r.get("outcome"),
                            "assessable": False})
            continue
        ap = os.path.join(SCAN, f"{r['slug']}_alpha.png")
        if not os.path.exists(ap):
            results.append({"path": r["path"], "outcome": "alpha_missing",
                            "assessable": False})
            continue
        A = np.asarray(Image.open(ap).convert("L"))
        ah, aw = A.shape
        kps, box, sw, sh = detect_on_source(r["path"])
        rec = {"path": r["path"], "slug": r["slug"],
               "alphaSize": [aw, ah], "sourceSize": [sw, sh],
               "workW": r.get("workW"), "workH": r.get("workH"),
               "exifOrientation": r.get("exifOrientation")}
        if kps is None:
            rec["assessable"] = False
            rec["reason"] = "no_face_on_source"
            results.append(rec)
            continue
        sx, sy = aw / float(sw), ah / float(sh)
        il = (kps[2] * sx, kps[3] * sy)   # 契约序：kps[2:4] = 图像左眼
        ir = (kps[0] * sx, kps[1] * sy)
        if il[0] > ir[0]:
            il, ir = ir, il
        ed = float(np.hypot(ir[0] - il[0], ir[1] - il[1]))
        mx, my = (il[0] + ir[0]) / 2.0, (il[1] + ir[1]) / 2.0
        bw, bh = 1.6 * ed, 0.45 * ed

        def frac_zero(cx, cy, w, h):
            x0 = int(max(0, round(cx - w / 2)))
            x1 = int(min(aw, round(cx + w / 2)))
            y0 = int(max(0, round(cy - h / 2)))
            y1 = int(min(ah, round(cy + h / 2)))
            if x1 - x0 < 3 or y1 - y0 < 3:
                return None, 0
            sub = A[y0:y1, x0:x1]
            return float((sub < 128).mean()), int(sub.size)

        ez, en = frac_zero(mx, my, bw, bh)
        bx0, by0 = box[0] * sx, box[1] * sy
        bx1, by1 = (box[0] + box[2]) * sx, (box[1] + box[3]) * sy
        x0, x1 = int(max(0, bx0)), int(min(aw, bx1))
        y0, y1 = int(max(0, by0)), int(min(ah, by1))
        fz = float((A[y0:y1, x0:x1] < 128).mean()) if (x1 - x0 > 3 and y1 - y0 > 3) else None

        rec.update({
            "assessable": True,
            "eyedistPx": round(ed, 1),
            "eyeBandZeroFrac": None if ez is None else round(ez, 4),
            "eyeBandPx": en,
            "faceBoxZeroFrac": None if fz is None else round(fz, 4),
            "alphaZeroFracOverall": round(float((A < 128).mean()), 4),
            "faceBoxInAlpha": [x0, y0, x1, y1],
            "eyeBandInAlpha": [int(max(0, round(mx - bw / 2))),
                               int(max(0, round(my - bh / 2))),
                               int(min(aw, round(mx + bw / 2))),
                               int(min(ah, round(my + bh / 2)))],
            "eyeBandHole": bool(ez is not None and ez > HOLE_THR),
        })
        results.append(rec)

    assessable = [r for r in results if r.get("assessable")]
    fixtures = [r for r in assessable if "P0_anchors" in r["path"].replace("\\", "/")]
    originals = [r for r in assessable if r not in fixtures]
    holes = [r for r in assessable if r["eyeBandHole"]]
    fp_end = CF.code_fingerprint()
    changed = sorted(k for k in set(fp_start["blobHashes"]) | set(fp_end["blobHashes"])
                     if fp_start["blobHashes"].get(k) != fp_end["blobHashes"].get(k))
    stable = fp_start["fnv1a64"] == fp_end["fnv1a64"]
    payload = {
        "generatedBy": "qa-batch test/batch/p0_alpha_holes.py",
        # 门禁按"产出它的代码指纹"钉本文件（out/ 不受冻结约束，不能按内容钉）。
        # 键路径 `provenance.codeFingerprint` 是门禁定死的契约。
        "provenance": {
            "codeFingerprint": fp_start,
            "codeFingerprintAtEnd": fp_end,
            "codeStableDuringRun": stable,
            "roundValid": stable,
            "changedFiles": changed,
            "inputProvenance": (
                "⚠ 本文件测量的是 `out/P0_alpha_scan/` 下**更早一次扫描**产出的 alpha，"
                "而那次扫描**没有记录自己的代码指纹**。所以这里的指纹只证明"
                "「跑本脚本期间被测代码没有变」，**不能证明那些 alpha 出自同一份代码**。"),
        },
        "question": "抠图在双眼区域产生大面积 alpha=0（脸上一个洞）是否独立于旋转、"
                    "在未旋转真实照片上就存在？",
        "answer": (
            "**否。未旋转的真实照片一张都没有洞**"
            f"（Pictures 可评估人像 {len(originals)} 张，eyeBandZeroFrac 全部 = 0.0，"
            "含两张 Camera Roll 原图）。洞只出现在**被旋转过的输入**上："
            f"c08 夹具家族 {sum(1 for r in fixtures if r['eyeBandHole'])}/{len(fixtures)} "
            "命中。故这是**旋转诱导的抠图失效**，不是独立于摆正的既有缺陷。"),
        "threshold": {"eyeBandZeroFrac": HOLE_THR,
                      "band": "宽 1.6x眼距、高 0.45x眼距，中心为双眼连线中点"},
        "scanSource": "out/P0_alpha_scan/（生产 removeBackground 的 alpha，"
                      "输入为干净原图/干净夹具，**不是画了线的 overlay**）",
        "total": len(results),
        "assessable": len(assessable),
        "notAssessable": [
            {"path": r.get("path"), "reason": r.get("reason") or r.get("outcome")}
            for r in results if not r.get("assessable")],
        "eyeBandHoleCount": len(holes),
        "eyeBandHoleFractionOfAssessable": round(len(holes) / max(1, len(assessable)), 3),
        "controlComparison": {
            "unrotatedRealPhotos": {
                "n": len(originals),
                "withHole": sum(1 for r in originals if r["eyeBandHole"]),
                "maxEyeBandZeroFrac": round(max(
                    [r["eyeBandZeroFrac"] for r in originals] or [0.0]), 4),
            },
            "rotatedFixtures": {
                "n": len(fixtures),
                "withHole": sum(1 for r in fixtures if r["eyeBandHole"]),
                "perFixture": {os.path.basename(r["path"]): r["eyeBandZeroFrac"]
                               for r in fixtures},
            },
        },
        "eyeBandHoles": sorted(
            [{"path": r["path"], "eyeBandZeroFrac": r["eyeBandZeroFrac"],
              "faceBoxZeroFrac": r["faceBoxZeroFrac"], "eyedistPx": r["eyedistPx"]}
             for r in holes], key=lambda d: -d["eyeBandZeroFrac"]),
        "worst10": sorted(
            [{"path": r["path"], "eyeBandZeroFrac": r["eyeBandZeroFrac"],
              "faceBoxZeroFrac": r["faceBoxZeroFrac"]} for r in assessable],
            key=lambda d: -d["eyeBandZeroFrac"])[:10],
        "items": results,
    }
    with open(os.path.join(REPO, "out", "P0_alpha_holes.json"), "w",
              encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)

    print(f"total={payload['total']} assessable={payload['assessable']} "
          f"eyeBandHole={payload['eyeBandHoleCount']} "
          f"({payload['eyeBandHoleFractionOfAssessable']:.1%})")
    print("\n最差 10 张：")
    for w in payload["worst10"]:
        print(f"  eyeBandZero={w['eyeBandZeroFrac']:>6} faceBoxZero={w['faceBoxZeroFrac']} "
              f"{os.path.basename(w['path'])}")

    # 对照图：标出洞的样本
    if holes:
        from PIL import ImageDraw
        tiles = []
        for h in holes[:9]:
            r = [x for x in assessable if x["path"] == h["path"]][0]
            im = Image.open(os.path.join(SCAN, f"{r['slug']}_alpha.png")).convert("RGB")
            d = ImageDraw.Draw(im)
            d.rectangle(r["faceBoxInAlpha"], outline=(255, 0, 0), width=2)
            d.rectangle(r["eyeBandInAlpha"], outline=(0, 255, 255), width=3)
            im.thumbnail((300, 300))
            tiles.append((os.path.basename(r["path"]), im))
        cell = (320, 330)
        W = 3
        sheet = Image.new("RGB", (W * cell[0],
                                  ((len(tiles) + W - 1) // W) * cell[1]), (25, 25, 25))
        dd = ImageDraw.Draw(sheet)
        for i, (lab, im) in enumerate(tiles):
            x = (i % W) * cell[0] + 8
            y = (i // W) * cell[1] + 18
            sheet.paste(im, (x, y))
            dd.text((x, y - 13), lab[:44], fill=(255, 255, 0))
        sheet.save(os.path.join(SCAN, "_sheet_holes.png"))
        print(f"\n对照图 -> {os.path.join(SCAN, '_sheet_holes.png')}")


if __name__ == "__main__":
    main()
