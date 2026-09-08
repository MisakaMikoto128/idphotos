/// 候选相框（区域 B 的一项，DESIGN.md §5）。
///
/// 一个小木相框 + 相纸衬底 + 照片 + 下方黄铜铭牌。
/// 选中态：整框上浮 4px、铜边加亮、铭牌变亮；未选中略降饱和度。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/api.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/wood_painter.dart';
import 'metal.dart';
import 'press_effect.dart';

/// 降饱和滤镜（未选中的候选"退到后面去"）。
const ColorFilter _desaturate = ColorFilter.matrix(<double>[
  0.55, 0.36, 0.09, 0, 0, //
  0.18, 0.73, 0.09, 0, 0, //
  0.18, 0.36, 0.46, 0, 0, //
  0, 0, 0, 1, 0, //
]);

class CandidateCard extends StatelessWidget {
  final BackgroundStyle style;

  /// null = 还在冲洗，画显影占位。
  final Uint8List? thumb;

  final double aspectRatio;
  final bool selected;
  final double width;
  final VoidCallback? onTap;

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
    this.placeholder,
    this.seed = 11,
  });

  @override
  Widget build(BuildContext context) {
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
                _frame(),
                const SizedBox(height: 5),
                Nameplate(text: style.nameZh, highlighted: selected),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _frame() {
    final Widget photo = AspectRatio(
      aspectRatio: aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const PaperSurface(seed: 17, edgeDarken: 0.5),
          if (thumb != null)
            Padding(
              padding: const EdgeInsets.all(3),
              child: ClipRect(
                child: selected
                    ? Image.memory(
                        thumb!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      )
                    : ColorFiltered(
                        colorFilter: _desaturate,
                        child: Image.memory(
                          thumb!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
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
