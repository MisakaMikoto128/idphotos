# assets/models/ 里两个模型的来历

## `modnet_portrait_int8.onnx` — 抠图，7.19 MB

- 来源：HivisionIDPhotos 的 `modnet_photographic_portrait_matting.onnx`
  （fp32，25,888,640 字节，在 `.ref_hivision/hivision/creator/weights/`）。
- 生成：`python native/quantize/build_matting_model.py`（脚本头部写了完整的
  量化策略与取舍理由）。输入固定 1×3×512×512，opset 13。
- 量化：逐输出通道 int8 **weight-only**，节点序号 < 105 的卷积保留 fp32。
- 前处理必须与生成黄金集参考 alpha 的脚本逐位对齐，否则 G2A.3–2A.5 对不上：
  `cv2.INTER_AREA` 缩到 512×512 → 量化回 uint8 → **BGR** 通道序 → NCHW →
  `(x/255 − 0.5) / 0.5`。注意是 BGR 不是 RGB。
- 后处理：`(matte * 255)` 向零截断成 uint8（不是四舍五入），再用同一套面积
  重采样放回原图尺寸。

## `face_yunet_2023mar.onnx` — 人脸，227 KB

- 来源：OpenCV Zoo `models/face_detection_yunet/face_detection_yunet_2023mar.onnx`
  （原样使用，未做任何量化或改写）。输入固定 1×3×640×640，opset 11。
- 前处理：等比缩放 + 右下角补 0 的 letterbox，**不做归一化**（直接喂 0–255 的
  BGR 浮点），与 OpenCV `FaceDetectorYN` 的 blob 一致。
- 后处理（`lib/core/matting/yunet_decoder.dart`）：三路 stride 8/16/32，
  `score = sqrt(cls * obj)`，框中心 `(col + bbox.x) * stride`、
  宽高 `exp(bbox.wh) * stride`，关键点同理；再做 IoU 0.3 的 NMS。
- 选它不选 UltraFace：UltraFace 只有框、没有关键点，算不出契约要求的
  `rollDeg`，也没法从眼–嘴间距推 `chinY`/`headTopY`。
- **没有用 ML Kit**：那会引入 Google Play Services，违反 CLAUDE.md 的离线红线。
