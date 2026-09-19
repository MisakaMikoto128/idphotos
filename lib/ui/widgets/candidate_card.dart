/// 候选相框（区域 B 的一项，DESIGN.md §5）。
///
/// 一个小木相框 + 相纸衬底 + 照片 + 下方黄铜铭牌。
/// 选中态：整框上浮 4px、铜边加亮、铭牌变亮；未选中略降饱和度。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../state/providers.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/wood_painter.dart';
import 'metal.dart';
import 'press_effect.dart';

/// 未选中候选的降饱和滤镜。
///
/// DESIGN.md §5 要求只"**略微**降低饱和度"——旧实现把饱和度压到 ~35%，
/// 人像被压成近灰度，用户无法据此比对肤色与底色（visual-critic R8 扣分）。
/// 现在保留 70% 饱和度，配合上浮/铜边/铭牌的选中反馈仍一眼可辨。
const ColorFilter _desaturate = ColorFilter.matrix(<double>[
  0.764, 0.215, 0.022, 0, 0, //
  0.064, 0.915, 0.022, 0, 0, //
  0.064, 0.215, 0.722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// 实时预览调整：把"当前交互几何"相对"候选合成时几何"的差量表达成
/// 一个作用在缩略图上的仿射变换（旋转 + 等比缩放 + 平移）。
///
/// 推导：候选缩略图展示的是源图区域 [composedCrop]；用户把框改成
/// [liveCrop] 后，新图（近似）就是旧图把 [liveCrop] 中心的内容挪到
/// 画面中心、再按 `composedCrop.width / liveCrop.width` 缩放；角度差
/// [dAngleRad] 直接旋转（口径同 `Transform.rotate`：正值顺时针）。
/// 裁剪框比例被锁定，缩放恒为等比。
class LivePreviewAdjust {
  /// 内容旋转角（弧度）。调用方负责按引擎口径换算符号：
  /// `-(manualAngleDeg - composedAngleDeg) * π / 180`。
  final double dAngleRad;

  /// 候选合成时使用的裁剪框（原图像素坐标）。
  final Rect composedCrop;

  /// 当前交互中的裁剪框（原图像素坐标）。
  final Rect liveCrop;

  const LivePreviewAdjust({
    required this.dAngleRad,
    required this.composedCrop,
    required this.liveCrop,
  });

  /// 在 [frame]（缩略图照片区的实际像素尺寸）上求变换矩阵。
  Matrix4 matrixFor(Size frame) {
    final Offset cf = frame.center(Offset.zero);
    final double k = composedCrop.width / liveCrop.width;
    // 旧图（child）上对应"新框中心"的像素位置：这个点要被挪到画面中心。
    final Offset t = Offset(
      (liveCrop.center.dx - composedCrop.left) /
          composedCrop.width *
          frame.width,
      (liveCrop.center.dy - composedCrop.top) /
          composedCrop.height *
          frame.height,
    );
    // M = T(cf) · R · S(k) · T(−t)：t 点 → 中心，绕中心等比缩放 k，再旋转。
    return Matrix4.identity()
      ..translateByDouble(cf.dx, cf.dy, 0, 1)
      ..rotateZ(dAngleRad)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-t.dx, -t.dy, 0, 1);
  }
}

class CandidateCard extends ConsumerWidget {
  final BackgroundStyle style;

  /// null = 还在冲洗，画显影占位。
  final Uint8List? thumb;

  final double aspectRatio;
  final bool selected;
  final double width;
  final VoidCallback? onTap;

  /// 交互中的实时预览调整。非 null 时缩略图按「当前几何 − 合成时几何」
  /// 做旋转/缩放/平移跟手显示，替代等待重新合成；全精度候选抵达后
  /// 快照更新，调整自然归零（见 [AppState.composedAngleDeg]）。
  final LivePreviewAdjust? liveAdjust;

  /// 冲洗中时用的占位内容。
  final Widget? placeholder;

  final int seed;

  const CandidateCard({
    super.key,
    required this.style,
    required this.thumb,
    required this.aspectRatio,
    required this.selected,
    required this.width,
    required this.onTap,
    this.liveAdjust,
    this.placeholder,
    this.seed = 11,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 照片渲染器由单一注入点决定（审查 A4）：真机 Image.memory，
    // 截图/测试场景 SyncRaster。
    final PhotoRasterBuilder raster = ref.watch(photoRasterProvider);
    return PressSurface(
      onTap: onTap,
      sink: 1,
      semanticLabel: style.nameZh,
      builder: (BuildContext context, bool pressed) {
        return TweenAnimationBuilder<double>(
          // DESIGN.md §5：选中态上浮 4px
          tween: Tween<double>(begin: 0, end: selected ? -4 : 0),
          duration: Motion.micro,
          curve: Motion.curve,
          builder: (BuildContext ctx, double dy, Widget? child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _frame(raster),
                const SizedBox(height: 5),
                Nameplate(text: style.nameZh, highlighted: selected),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 未选中态套"略微降饱和"；选中态原样。
  Widget _tinted(Widget photo) {
    if (selected) return photo;
    return ColorFiltered(colorFilter: _desaturate, child: photo);
  }

  Widget _frame(PhotoRasterBuilder raster) {
    final Widget photo = AspectRatio(
      aspectRatio: aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 相纸衬底只在空态/显影占位时露出；有照片时照片顶满相框内沿——
          // 白色衬边会让人以为成片带白框（用户 2026-09-19），成片并没有。
          if (thumb == null) const PaperSurface(seed: 17, edgeDarken: 0.5),
          if (thumb != null)
            ClipRect(
              child: liveAdjust == null
                  ? _tinted(raster(thumb!, BoxFit.cover))
                  : LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        return ColoredBox(
                          // 旋转/缩放露出的边角用本色底的纯色端补齐
                          //（实时预览是过渡态，停手后全精度候选替换）。
                          color: Color(style.colorTop),
                          child: Transform(
                            transform: liveAdjust!.matrixFor(
                              Size(c.maxWidth, c.maxHeight),
                            ),
                            child: _tinted(raster(thumb!, BoxFit.cover)),
                          ),
                        );
                      },
                    ),
            )
          else if (placeholder != null)
            Padding(padding: const EdgeInsets.all(3), child: placeholder!),
          // 相纸压在相框里的内投影
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Shade.warmShadowSoft, Color(0x00241609)],
                  stops: <double>[0.0, 0.22],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return WoodPanel(
      spec: WoodSpec(
        tone: selected ? WoodTone.light : WoodTone.base,
        seed: seed,
        figure: false,
      ),
      grainOrigin: Offset(seed * 37.0, 260),
      radius: Shape.panelBorder,
      padding: const EdgeInsets.all(7),
      child: Stack(
        children: <Widget>[
          photo,
          if (selected)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: T.brassHi, width: 1.6),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
