/// 木照 MuZhao — 规格表（imaging 势力范围）。
///
/// **唯一真值源是 `lib/core/api.dart`**：mm / px / dpi 由 `docs/CONTRACTS.md`
/// 第 4 节锁定，本文件一律用 [PhotoSpec.copyWith] 从 api.dart 的 7 个常量派生，
/// 绝不重新硬编码尺寸——否则会出现第二个真值源，早晚漂移。
///
/// 本文件只负责调校两个几何比例：
///
/// - [PhotoSpec.headTopRatio]    头顶留白 / 画面总高
/// - [PhotoSpec.headHeightRatio] （头顶 → 下巴）/ 画面总高
///
/// ## 取值依据
///
/// 证件照通行规范（GB/T 35271、公安部人像采集规范、各类办事窗口通用要求）对
/// 人像在画面中的位置约定为：
///
/// - 头顶到画面上边缘的留白约占总高 **7% – 12%**（太小压顶，太大显得人小）
/// - 头顶到下巴的头部高度约占总高 **60% – 65%**
/// - 二者之和即下巴位置，落在 **0.68 – 0.72**，余下约 28% – 32% 留给颈肩
///
/// 美国签证照（51×51mm）另有硬性要求：头高 25–35mm（即 0.49–0.69），
/// 双眼位于画面下缘往上 56%–69% 处。本文件取 headTop 0.08 / headHeight 0.64：
/// 头高 = 0.64 × 51 ≈ 32.6mm（落在 25–35mm 内），
/// 按“双眼约在头顶到下巴的中点”估算，眼位 = 1 − (0.08 + 0.64/2) = 0.60，
/// 落在 56%–69% 内。
///
/// 各规格的差异来自画幅本身的长宽比：越接近正方形（社保卡 26×32、美签 51×51）
/// 头部占比可以大一些；越修长（二寸 35×49、大一寸 33×48）则需要给颈肩多留余量，
/// 否则成片会显得头重脚轻。
library;

import '../api.dart';

// ---------------------------------------------------------------------------
// 派生后的 7 个规格（尺寸继承自 api.dart，仅覆写两个几何比例）
// ---------------------------------------------------------------------------

/// 一寸 25×35mm / 295×413px。
final PhotoSpec specCn1inch =
    kSpecCn1inch.copyWith(headTopRatio: 0.09, headHeightRatio: 0.62);

/// 小一寸 22×32mm / 260×378px。与一寸同比例观感。
final PhotoSpec specCnSmall1inch =
    kSpecCnSmall1inch.copyWith(headTopRatio: 0.09, headHeightRatio: 0.62);

/// 大一寸 33×48mm / 390×567px。画幅偏长，颈肩多留余量。
final PhotoSpec specCnBig1inch =
    kSpecCnBig1inch.copyWith(headTopRatio: 0.10, headHeightRatio: 0.62);

/// 二寸 35×49mm / 413×579px。最修长的画幅，头部占比取下限。
final PhotoSpec specCn2inch =
    kSpecCn2inch.copyWith(headTopRatio: 0.10, headHeightRatio: 0.60);

/// 小二寸 35×45mm / 413×531px。
final PhotoSpec specCnSmall2inch =
    kSpecCnSmall2inch.copyWith(headTopRatio: 0.09, headHeightRatio: 0.62);

/// 社保卡 26×32mm / 358×441px。近方形画幅，头部占比取上限。
final PhotoSpec specCnSocialSecurity =
    kSpecCnSocialSecurity.copyWith(headTopRatio: 0.08, headHeightRatio: 0.64);

/// 美签 51×51mm / 600×600px。见上文眼位推导。
final PhotoSpec specVisaUs =
    kSpecVisaUs.copyWith(headTopRatio: 0.08, headHeightRatio: 0.64);

/// 调校后的 7 个规格，顺序与 [kBuiltInSpecs] 完全一致（UI 展示顺序）。
///
/// 主会话阶段 3 接线时用本表替代 [kBuiltInSpecs]，
/// 这样 UI 与合成引擎看到的是同一组几何比例。
final List<PhotoSpec> photoSpecs = List<PhotoSpec>.unmodifiable(<PhotoSpec>[
  specCn1inch,
  specCnSmall1inch,
  specCnBig1inch,
  specCn2inch,
  specCnSmall2inch,
  specCnSocialSecurity,
  specVisaUs,
]);

/// 默认规格：一寸（与 [kDefaultSpec] 同 id）。
final PhotoSpec defaultPhotoSpec = specCn1inch;

/// 按 id 把 api.dart 里未调校的常量换成本文件调校后的同名规格。
///
/// **只给接线层（controller / UI）用**。`ComposeEngineMixin.compose` 刻意
/// **不**调用它：几何比例是 [PhotoSpec] 的字段，compose 必须按调用方传进来的
/// 那一份执行，否则「传 0.08 却按 0.09 裁」，任何对着入参做断言的调用方
/// （包括验收脚本）都会判它错。想用调校值，就在这里换好再传进 compose。
PhotoSpec tunedSpecFor(PhotoSpec spec) {
  for (final PhotoSpec s in photoSpecs) {
    if (s.id == spec.id) {
      return s;
    }
  }
  // 外部自定义规格：尺寸照用，几何比例落到通用值。
  return spec.copyWith(headTopRatio: 0.09, headHeightRatio: 0.62);
}
