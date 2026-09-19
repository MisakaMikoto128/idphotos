/// 抠图档位拨杆：双模型切换开关（CONTRACTS §3 `setMattingQuality`）。
///
/// 造型与角度微调尺同源（"同一台机器上的另一件铜活"，见 angle_gauge.dart）：
/// 一条凹陷的黄铜槽，槽内左右两个档位的刻字阴刻在槽底；当前档位被一枚
/// 凸起的黄铜拨钮盖住（阳刻），点另一档拨钮滑过去。
///
/// 交互：整条槽都是热区（高 44，同角度尺），点左半=快速档、右半=精细档。
/// 抠图中**不禁用**：controller 有代数守卫，连点安全（CONTRACTS §3）。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/api.dart';
import '../theme/brass.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'metal.dart';

/// 档位刻字。两档都要让第一次用的人一眼分出快慢（精细档把"慢"直接刻上去）。
const String kQualityFastLabel = '快速';
const String kQualityFineLabel = '精细（慢）';

class QualitySwitch extends StatelessWidget {
  /// 当前档位，来自 [AppState.mattingQuality]。
  final MattingQuality value;

  /// 点了某一档。调用方接 `controller.setMattingQuality`。
  final ValueChanged<MattingQuality> onChanged;

  const QualitySwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// 控件总高：整条都是触摸热区（≥44，DESIGN.md 无障碍要求）。
  static const double height = 44;

  /// 凹槽槽体高度。
  static const double channelHeight = 30;

  @override
  Widget build(BuildContext context) {
    final bool fine = value == MattingQuality.fine;
    return Semantics(
      button: true,
      label: '抠图档位',
      value: fine ? '精细档，较慢' : '快速档',
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text('抠图', style: Type.caption(T.creamText)),
            const SizedBox(width: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  return GestureDetector(
                    key: const Key('quality_switch'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (TapUpDetails d) {
                      final MattingQuality q =
                          d.localPosition.dx < c.maxWidth / 2
                              ? MattingQuality.fast
                              : MattingQuality.fine;
                      if (q != value) onChanged(q);
                    },
                    child: Center(
                      child: SizedBox(
                        height: channelHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            const CustomPaint(painter: _ChannelPainter()),
                            const _FloorLabels(),
                            // 拨钮：盖住当前档的槽底刻字
                            AnimatedAlign(
                              duration: Motion.micro,
                              curve: Motion.curve,
                              alignment: fine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: 0.5,
                                heightFactor: 1.0,
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: _Thumb(
                                    label: fine
                                        ? kQualityFineLabel
                                        : kQualityFastLabel,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 槽底的两个档位刻字（阴刻，未选中的那档露出来）。
class _FloorLabels extends StatelessWidget {
  const _FloorLabels();

  @override
  Widget build(BuildContext context) {
    Widget label(String text) => Expanded(
          child: Center(
            child: Opacity(
              opacity: 0.72,
              child: EngravedText(
                text,
                style: Type.plate(T.inkBrown),
                relief: T.brassHi,
                raised: false,
                maxLines: 1,
              ),
            ),
          ),
        );
    return Row(
      children: <Widget>[
        label(kQualityFastLabel),
        label(kQualityFineLabel),
      ],
    );
  }
}

/// 拨钮：一枚凸起的黄铜帽，阳刻当前档位名。
class _Thumb extends StatelessWidget {
  final String label;

  const _Thumb({required this.label});

  @override
  Widget build(BuildContext context) {
    return MetalPlate(
      finish: MetalFinish.brass,
      radius: const BorderRadius.all(Radius.circular(3)),
      seed: 4,
      child: Center(
        child: EngravedText(
          label,
          style: Type.plate(T.inkBrown),
          relief: T.brassHi,
          maxLines: 1,
        ),
      ),
    );
  }
}

/// 凹槽槽体：凹陷的黄铜面 + 上沿暗唇/下沿亮唇 + 中缝定位刻口。
///
/// 渐变与暗唇比例直接沿用角度尺槽底的实测结论（angle_gauge.dart 的
/// `_paintChannelFloor`）：暗只留最上面一条窄唇，铺满上半段会被读成两条带子。
class _ChannelPainter extends CustomPainter {
  const _ChannelPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect r = Offset.zero & size;
    final RRect rr = RRect.fromRectAndRadius(r, const Radius.circular(4));

    canvas.save();
    canvas.clipRRect(rr);
    // 槽底：上内壁在阴影里，向下过渡到亮铜
    canvas.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.linear(
          r.topCenter,
          r.bottomCenter,
          <Color>[
            Color.lerp(T.brassShadow, T.brass, 0.12)!,
            T.brass,
            T.brass,
            Color.lerp(T.brass, T.brassHi, 0.30)!,
          ],
          const <double>[0.0, 0.14, 0.70, 1.0],
        ),
    );
    canvas.restore();

    // 上沿暗唇 / 下沿亮唇：把槽"挖"进台面（光源在左上）
    canvas.drawLine(
      Offset(r.left + 3, r.top + 0.5),
      Offset(r.right - 3, r.top + 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = T.brassShadow.withValues(alpha: 0.9),
    );
    canvas.drawLine(
      Offset(r.left + 3, r.bottom - 0.5),
      Offset(r.right - 3, r.bottom - 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = T.brassHi.withValues(alpha: 0.55),
    );

    // 中缝定位刻口：两档分界处一道短刻痕（先暗刻再补高光）
    final double mid = r.center.dx.roundToDouble() + 0.5;
    canvas.drawLine(
      Offset(mid, r.top + 3),
      Offset(mid, r.top + 9),
      Paint()
        ..strokeWidth = 1.2
        ..color = T.brassShadow.withValues(alpha: 0.85),
    );
    canvas.drawLine(
      Offset(mid + 1, r.top + 3),
      Offset(mid + 1, r.top + 9),
      Paint()
        ..strokeWidth = 0.8
        ..color = T.brassHi.withValues(alpha: 0.5),
    );

    // 外描边，把槽从木台面上切出来
    canvas.drawRRect(
      rr.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = T.woodDark.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(_ChannelPainter old) => false;
}
