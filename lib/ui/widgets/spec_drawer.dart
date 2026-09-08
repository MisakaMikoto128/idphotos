/// 规格选择抽屉（DESIGN.md §5：木质抽屉样式，从下方滑出）。
///
/// 刻意不使用 `showModalBottomSheet` —— 那会带进 Material 的圆角卡片与
/// 拖拽手柄外观（RUBRIC 致命项 1）。这里是一只真正的木抽屉：面板上有铜拉手、
/// 燕尾榫接缝，每个规格是一枚铜牌。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/widgets.dart';

import '../../core/api.dart';
import '../theme/brass.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/wood_painter.dart';
import 'metal.dart';
import 'press_effect.dart';

class SpecDrawer extends StatelessWidget {
  final bool open;
  final PhotoSpec current;
  final ValueChanged<PhotoSpec> onPick;
  final VoidCallback onClose;

  const SpecDrawer({
    super.key,
    required this.open,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !open,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: Motion.area,
            curve: Motion.curve,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: const ColoredBox(color: Shade.scrim),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedSlide(
              offset: Offset(0, open ? 0 : 1),
              duration: Motion.area,
              curve: Motion.curve,
              child: _Drawer(
                current: current,
                onPick: onPick,
                onClose: onClose,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Drawer extends StatelessWidget {
  final PhotoSpec current;
  final ValueChanged<PhotoSpec> onPick;
  final VoidCallback onClose;

  const _Drawer({
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom;
    return WoodPanel(
      spec: const WoodSpec(tone: WoodTone.light, seed: 61),
      grainOrigin: const Offset(0, 900),
      radius: const BorderRadius.vertical(top: Shape.panel),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + (bottom > 0 ? 0 : 4)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Center(child: _DrawerPull()),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text('选择规格', style: Type.subtitle(T.creamText)),
                  const Spacer(),
                  PressSurface(
                    onTap: onClose,
                    sink: 1,
                    semanticLabel: '关闭',
                    builder: (BuildContext c, bool pressed) => SizedBox(
                      height: 30,
                      width: 62,
                      child: MetalPlate(
                        finish: MetalFinish.brass,
                        pressed: pressed,
                        seed: 3,
                        child: Center(
                          child: EngravedText(
                            '取消',
                            style: Type.plate(T.inkBrown),
                            relief: T.brassHi,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final PhotoSpec s in kBuiltInSpecs) ...<Widget>[
                _SpecRow(
                  spec: s,
                  selected: s.id == current.id,
                  onTap: () => onPick(s),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉面板上的铜拉手。
class _DrawerPull extends StatelessWidget {
  const _DrawerPull();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 12,
      child: CustomPaint(painter: const _PullPainter()),
    );
  }
}

class _PullPainter extends CustomPainter {
  const _PullPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final RRect r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 3, size.width, 6),
      const Radius.circular(3),
    );
    canvas.drawRRect(r.shift(const Offset(0.6, 1.4)),
        Paint()..color = Shade.warmShadow);
    canvas.drawRRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const <Color>[T.brassHi, T.brass, T.brassShadow],
        ).createShader(r.outerRect),
    );
    paintScrew(canvas, Offset(5, size.height / 2), 2.6, MetalFinish.brass);
    paintScrew(
        canvas, Offset(size.width - 5, size.height / 2), 2.6, MetalFinish.brass,
        phase: 2);
  }

  @override
  bool shouldRepaint(_PullPainter old) => false;
}

class _SpecRow extends StatelessWidget {
  final PhotoSpec spec;
  final bool selected;
  final VoidCallback onTap;

  const _SpecRow({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressSurface(
      onTap: onTap,
      sink: 1,
      semanticLabel: '${spec.nameZh} ${spec.widthMm}乘${spec.heightMm}毫米',
      builder: (BuildContext context, bool pressed) {
        return SizedBox(
          height: 46,
          child: MetalPlate(
            finish: selected ? MetalFinish.brass : MetalFinish.matte,
            pressed: pressed,
            seed: spec.id.hashCode & 0x3F,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: selected
                      ? CustomPaint(
                          size: const Size(14, 14),
                          painter: const _MarkPainter(),
                        )
                      : const SizedBox(),
                ),
                Expanded(
                  child: EngravedText(
                    spec.nameZh,
                    style: Type.bodyStrong(
                        selected ? T.inkBrown : T.creamText),
                    relief: selected ? T.brassHi : T.woodDark,
                    raised: selected,
                    align: TextAlign.left,
                    maxLines: 1,
                  ),
                ),
                EngravedText(
                  '${spec.widthMm}×${spec.heightMm}mm  ·  '
                  '${spec.widthPx}×${spec.heightPx}',
                  style:
                      Type.caption(selected ? T.inkBrown : T.creamText),
                  relief: selected ? T.brassHi : T.woodDark,
                  raised: selected,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 选中标记：一枚小铜钉。
class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    paintScrew(
      canvas,
      Offset(size.width / 2, size.height / 2),
      5.5,
      MetalFinish.brass,
      phase: 1,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
