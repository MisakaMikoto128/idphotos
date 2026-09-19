# assets/models/ 里模型的来历

## `birefnet_lite_1024_int8.onnx` — 抠图（现役，2026-09-19 起），67.38 MB

- 来源：onnx-community/BiRefNet_lite-ONNX 的 `onnx/model.onnx`
  （MIT，base = ZhengPeng7/BiRefNet_lite；deform_conv2d 已被导出方改写为
  等价的 grid_sample 子图）。输入固定 1×3×1024×1024，opset 17。
  下载（直连不通，走镜像）：
  `curl -L -o native/quantize/src/birefnet_lite_1024_fp32.onnx
  https://hf-mirror.com/onnx-community/BiRefNet_lite-ONNX/resolve/main/onnx/model.onnx`
- 生成：`python native/quantize/build_birefnet_model.py`（脚本头部有完整策略）。
  逐通道 int8 weight-only（Conv/MatMul，149 个张量）+ deform-conv 采样网格
  常量（整数值、fp16 往返误差为 0）无损 fp16。每个消费方一个独立 DQ 节点——
  共享 DQ 会触发 ORT 1.15 的复制优化丢 axis 属性（运行期报错）。
- 前处理：`cv2.INTER_AREA` 缩到 1024×1024 → **RGB** 通道序（不是 BGR）→
  NCHW → `(x/255 − mean) / std`，mean=[0.485,0.456,0.406]，
  std=[0.229,0.224,0.225]（权重卡 preprocessor_config 口径）。
- 后处理：输出是 **logits**（实测 −20 ~ +140），`sigmoid(x) * 255` 向零截断
  成 uint8，再面积重采样放回原图尺寸。
- 体积 67MB 的构成：44MB int8 权重 + 21.5MB fp16 采样网格 + 2MB 其余。
  网格是 grid_sample 的坐标表，不是权重，吃不了 weight-only 量化。
- 换档理由：MODNet 的发丝边缘是分割式硬过渡，换红底白边/色边明显；
  BiRefNet 输出真抠图 alpha。代价：PC CPU 单张 ~12s（MODNet ~1.5s）。

## `modnet_portrait_1024_int8.onnx` — 抠图（旧，留作 A/B 对照），7.19 MB

- 来源：HivisionIDPhotos 的 `modnet_photographic_portrait_matting.onnx`
  （fp32，25,888,640 字节，在 `.ref_hivision/hivision/creator/weights/`）。
- 生成：`python native/quantize/build_matting_model.py`（脚本头部写了完整的
  量化策略与取舍理由）。输入固定 1×3×1024×1024，opset 13。
  （2026-09-19 前为 512²；发丝锯齿的根源是分辨率而非量化，质量优先换档，
  旧 512 变体可用 `--size 512 --out <路径>` 复现，仅供对照 bench。）
- 量化：逐输出通道 int8 **weight-only**，节点序号 < 105 的卷积保留 fp32。
- 前处理必须与生成黄金集参考 alpha 的脚本逐位对齐（512 口径的 G2A.3–2A.5
  已随换档作废，新口径由主会话重校准）：
  `cv2.INTER_AREA` 缩到 1024×1024 → 量化回 uint8 → **BGR** 通道序 → NCHW →
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
