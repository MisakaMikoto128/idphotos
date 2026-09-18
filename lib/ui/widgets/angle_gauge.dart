/// 角度微调尺：一根凹槽黄铜刻度尺 + 游标滑块 + 左右微调钮 + 回正钮。
///
/// 放在**区域 A 之内**、紧贴照片框下沿 —— 它调的就是框里那张图的面内角度，
/// 不新增第四个主区域（CLAUDE.md §2）。
///
/// 为什么是"刻度尺"而不是一根滑条：本 App 的时间坐标是 1930 年代照相馆的
/// 木质工作台，现代 Material 滑条会立刻穿帮。这里复用顶部规格标尺已经建立的
/// 语汇（蚀刻刻度线、黄铜、游标），让它读起来像同一台机器上的另一件铜活。
///
/// 交互：整条尺身都是拖拽热区（不小于 44px 高），拖动为**相对**位移
/// （手指走多少，角度变多少），松手前不给引擎压力；轻触尺身则直接跳到该处。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../state/providers.dart';
import '../theme/brass.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'metal.dart';
import 'press_effect.dart';

/// 控件总高。拖拽热区 ≥ 44×44（DESIGN.md 无障碍要求），故整行就是热区。
const double kAngleGaugeHeight = 44;

/// 度数提交给 controller 的最小间隔。
///
/// 拖动会经过几十个角度，逐个提交会把状态流和整棵区域 A 冲垮。
/// 120ms 约合 8 次/秒，肉眼已经"跟手"；controller 侧另有 300ms 去抖才真正
/// 重跑合成，所以真正昂贵的重算只发生在用户停手之后。
const Duration kAngleCommitInterval = Duration(milliseconds: 120);

/// 微调钮每按一下走的角度。
const double kNudgeStepDeg = 0.5;

/// 角度微调尺。
class AngleGauge extends ConsumerStatefulWidget {
  /// 当前角度（度），来自 [AppState.manualAngleDeg]。
  final double angleDeg;

  /// false = 不可用（空态 / 冲洗中）：金属转哑光并整体压淡。
  final bool enabled;

  const AngleGauge({
    super.key,
    required this.angleDeg,
    required this.enabled,
  });

  @override
  ConsumerState<AngleGauge> createState() => _AngleGaugeState();
}

class _AngleGaugeState extends ConsumerState<AngleGauge> {
  /// 本控件自己持有的角度。拖动期间以它为准 —— controller 的状态要绕一圈
  /// 才回来，直接读会让读数滞后一帧、游标发飘。
  late double _deg = widget.angleDeg;

  bool _dragging = false;

  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailing;
  double? _pending;

  @override
  void initState() {
    super.initState();
    _deg = widget.angleDeg;
  }

  @override
  void didUpdateWidget(covariant AngleGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 没在拖的时候以外部状态为准：换图归零、规格切换、撤销都由它同步回来。
    if (!_dragging) _deg = widget.angleDeg;
  }

  @override
  void dispose() {
    _trailing?.cancel();
    super.dispose();
  }

  /// 吸附到 0.5° 台阶并钳制到 ±30°。步进 0.5° 让读数恒为一位小数。
  static double snapAngle(double v) {
    if (!v.isFinite) return 0;
    final double c = v.clamp(kManualAngleMinDeg, kManualAngleMaxDeg).toDouble();
    final double s = (c * 2).roundToDouble() / 2;
    return s == 0 ? 0 : s; // 顺带消掉 -0.0
  }

  void _onDragStart() => _dragging = true;

  void _onDragTo(double raw) {
    final double v = snapAngle(raw);
    if (v != _deg) setState(() => _deg = v);
    _push(v);
  }

  /// 松手：把最终值钉死提交，不留半路上的中间值。
  void _onDragEnd() {
    _dragging = false;
    _trailing?.cancel();
    _trailing = null;
    _pending = null;
    _send(_deg);
  }

  void _onJumpTo(double raw) {
    final double v = snapAngle(raw);
    if (v != _deg) setState(() => _deg = v);
    _onDragEnd();
  }

  /// 前沿立即提交 + 尾沿最多每 [kAngleCommitInterval] 补一次。
  void _push(double v) {
    final DateTime now = DateTime.now();
    final Duration since = now.difference(_lastSentAt);
    if (since >= kAngleCommitInterval) {
      _send(v);
      return;
    }
    _pending = v;
    _trailing ??= Timer(kAngleCommitInterval - since, () {
      _trailing = null;
      final double? p = _pending;
      _pending = null;
      if (p == null) return;
      _send(p);
    });
  }

  void _send(double v) {
    _lastSentAt = DateTime.now();
    ref.read(controllerProvider).setManualAngle(v);
  }

  /// 左右微调钮：走一步 [kNudgeStepDeg]，提交语义与松手相同。
  void _nudge(double delta) {
    final double v = snapAngle(_deg + delta);
    if (v != _deg) setState(() => _deg = v);
    _send(v);
  }

  @override
  Widget build(BuildContext context) {
    final bool on = widget.enabled;
    return AnimatedOpacity(
      opacity: on ? 1 : 0.55,
      duration: Motion.micro,
      curve: Motion.curve,
      child: SizedBox(
        height: kAngleGaugeHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text('角度', style: Type.caption(T.creamText)),
            const SizedBox(width: 8),
            _NudgeKnob(
              enabled: on,
              label: '−',
              semanticLabel: '逆时针微调',
              onTap: () => _nudge(-kNudgeStepDeg),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _VernierTrack(
                deg: _deg,
                enabled: on,
                onDragStart: _onDragStart,
                onDragTo: _onDragTo,
                onDragEnd: _onDragEnd,
                onJumpTo: _onJumpTo,
              ),
            ),
            const SizedBox(width: 6),
            _NudgeKnob(
              enabled: on,
              label: '+',
              semanticLabel: '顺时针微调',
              onTap: () => _nudge(kNudgeStepDeg),
            ),
            const SizedBox(width: 6),
            _ResetKnob(
              enabled: on,
              onTap: () => _onJumpTo(0),
            ),
          ],
        ),
      ),
    );
  }
}

/// 刻度尺与游标。
class _VernierTrack extends StatefulWidget {
  final double deg;
  final bool enabled;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragTo;
  final VoidCallback onDragEnd;
  final ValueChanged<double> onJumpTo;

  const _VernierTrack({
    required this.deg,
    required this.enabled,
    required this.onDragStart,
    required this.onDragTo,
    required this.onDragEnd,
    required this.onJumpTo,
  });

  @override
  State<_VernierTrack> createState() => _VernierTrackState();
}

class _VernierTrackState extends State<_VernierTrack> {
  double _startDeg = 0;
  double _startX = 0;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // 文案刻意不用"微调"：`微` 不在 Noto Serif SC 子集里（fonts.dart 的
      // coveredCharset），用它会让无障碍标签出豆腐块。要改回"角度微调"，
      // 必须先 `dart run tools/charset_scan.dart` 并重新子集化。
      label: '调整角度',
      value: formatAngle(widget.deg),
      enabled: widget.enabled,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final _ScaleMap map = _ScaleMap(c.maxWidth);
          return GestureDetector(
            key: const Key('angle_track'),
            behavior: HitTestBehavior.opaque,
            onPanStart: widget.enabled
                ? (DragStartDetails d) {
                    _startDeg = widget.deg;
                    _startX = d.globalPosition.dx;
                    widget.onDragStart();
                  }
                : null,
            onPanUpdate: widget.enabled
                ? (DragUpdateDetails d) => widget.onDragTo(
                      _startDeg + (d.globalPosition.dx - _startX) / map.pxPerDeg,
                    )
                : null,
            onPanEnd: widget.enabled ? (_) => widget.onDragEnd() : null,
            onPanCancel: widget.enabled ? widget.onDragEnd : null,
            // 轻触定位：拖动不会触发它（TapGestureRecognizer 会被 pan 挤掉），
            // 所以"拖"是相对的、"点"是绝对的，互不打扰。
            onTapUp: widget.enabled
                ? (TapUpDetails d) =>
                    widget.onJumpTo(map.degAt(d.localPosition.dx))
                : null,
            child: CustomPaint(
              painter: _VernierPainter(
                deg: widget.deg,
                enabled: widget.enabled,
              ),
              isComplex: true,
              willChange: true,
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }
}

/// ±30° 到尺身像素的映射。
///
/// 两端各留出半个游标滑块的宽度，滑块走到极限位置时不会探出尺身。
class _ScaleMap {
  /// 游标滑块宽度。
  static const double capW = 24;

  final double width;

  const _ScaleMap(this.width);

  double get left => capW / 2 + 1;
  double get right => width - capW / 2 - 1;
  double get span => (right - left).clamp(1.0, double.infinity);
  double get pxPerDeg => span / (kManualAngleMaxDeg - kManualAngleMinDeg);

  double xOf(double deg) => left + (deg - kManualAngleMinDeg) * pxPerDeg;

  double degAt(double x) => kManualAngleMinDeg + (x - left) / pxPerDeg;

  bool get usable => width >= 90;
}

/// 度数的显示口径：`+3.5°` / `−3.5°` / `0.0°`。
///
/// 用 U+2212 减号而不是 ASCII 连字符 —— 衬线体里连字符又短又高，摆在数字前
/// 像撇号。正号显式写出，避免"没有号"与"减号"看混。
String formatAngle(double deg) {
  if (deg.abs() < 0.05) return '0.0°';
  final String sign = deg > 0 ? '+' : '−';
  return '$sign${deg.abs().toStringAsFixed(1)}°';
}

/// 手动角度（度）→ 画布要转的弧度。
///
/// 取负号是因为 `manualAngleDeg` 为正时画面是**逆**时针转：
/// controller 把它直接当 `rollDeg` 传进 `planRotation`，而 `RotationPlan`
/// 的换算式 `p_src = C_src + R(θ)·(p_rot − C_rot)` 把内容整体搬了 −θ
/// （见 `lib/core/imaging/crop_geometry.dart`）。Flutter 的 `Transform.rotate`
/// 正角却是顺时针（屏幕坐标 y 向下），所以两者差一个符号。
///
/// ⚠️ `lib/core/api.dart` 的注释把 `manualRollDeg` 写成"正值顺时针"，与
/// `RotationPlan` 的实际口径相反；`docs/CONTRACTS.md` 记过一次同源事故
/// （`rollDeg` 的"顺/逆"措辞与实现相反，曾把 qa-batch 真值文件带偏）。
/// 这里以**实现**为准。若主会话裁定改口径，只需改这一行的符号。
double canvasRotationRad(double deg) => -deg * math.pi / 180.0;

// ---------------------------------------------------------------------------
// 绘制
// ---------------------------------------------------------------------------

/// 凹槽黄铜刻度尺 + 游标滑块。
class _VernierPainter extends CustomPainter {
  final double deg;
  final bool enabled;

  const _VernierPainter({required this.deg, required this.enabled});

  /// 尺身（凹槽）上下各留的边距。留够之后整条尺子才落在行中线上，
  /// 左中右三件（标签 / 读数窗 / 回正钮）才不用各自错位对齐。
  static const double _channelInset = 5;

  /// 刻度线距离尺身下沿的高度。
  static const double _tickBase = 3;

  /// 游标铜帽的高度。它骑在凹槽里，不是悬在凹槽上方。
  static const double _capH = 13;

  @override
  void paint(Canvas canvas, Size size) {
    final _ScaleMap map = _ScaleMap(size.width);
    final Rect ch = Rect.fromLTRB(
        0, _channelInset, size.width, size.height - _channelInset);
    if (!map.usable || ch.height < 22) return;

    final RRect chRR = RRect.fromRectAndRadius(ch, const Radius.circular(3));

    canvas.save();
    canvas.clipRRect(chRR);
    _paintChannelFloor(canvas, ch);
    _paintTicks(canvas, map, ch);
    _paintEdgeBevel(canvas, ch);
    _paintNumerals(canvas, map, ch);
    canvas.restore();

    _paintCarriage(canvas, map, size);
  }

  /// 凹槽底：暗只留在最上面一条窄唇上，其余是平整的黄铜面。
  ///
  /// 早先把暗部铺满上半段，34px 高的槽里会读成"上下两条不同色的带子"
  /// 而不是一条挖出来的槽；暗唇压到 14% 才是"上内壁在阴影里"的观感。
  void _paintChannelFloor(Canvas canvas, Rect ch) {
    if (!enabled) {
      canvas.drawRect(
          ch, Paint()..shader = metalFaceShader(ch, MetalFinish.matte));
      return;
    }
    canvas.drawRect(
      ch,
      Paint()
        ..shader = ui.Gradient.linear(
          ch.topCenter,
          ch.bottomCenter,
          <Color>[
            Color.lerp(T.brassShadow, T.brass, 0.12)!,
            T.brass,
            T.brass,
            Color.lerp(T.brass, T.brassHi, 0.30)!,
          ],
          const <double>[0.0, 0.14, 0.70, 1.0],
        ),
    );
  }

  /// 蚀刻刻度：每 2.5° 一道，5° 加长，10° 最长，0° 再加长。
  ///
  /// 每道画两笔 —— 深色刻痕 + 其右一道极细的高光。这是"刻"进金属而不是
  /// "画"在上面的关键（RUBRIC R4）。
  void _paintTicks(Canvas canvas, _ScaleMap map, Rect ch) {
    final double base = ch.bottom - _tickBase;
    final Paint cut = Paint()..strokeWidth = 1;
    final Paint lit = Paint()..strokeWidth = 1;

    // q 的单位是 1/4 度：步进 10 即 2.5° 一档。
    for (int q = -120; q <= 120; q += 10) {
      final double d = q / 4.0;
      final double x = map.xOf(d).roundToDouble() + 0.5;
      final bool zero = q == 0;
      final bool major = q % 40 == 0; // 10°
      final bool mid = q % 20 == 0; // 5°
      final double len = zero ? 14 : (major ? 12 : (mid ? 9 : 6));

      cut.color = (enabled ? T.brassShadow : T.woodDark)
          .withValues(alpha: zero ? 0.95 : (major ? 0.8 : (mid ? 0.62 : 0.45)));
      lit.color = (enabled ? T.brassHi : T.inkFaded).withValues(
          alpha: zero ? 0.85 : (major ? 0.5 : (mid ? 0.36 : 0.24)));

      canvas.drawLine(Offset(x, base), Offset(x, base - len), cut);
      canvas.drawLine(Offset(x + 1, base), Offset(x + 1, base - len), lit);
    }
  }

  /// 上下内壁的倒角线。画在裁剪之内，两端的圆角不会让线头露出去。
  void _paintEdgeBevel(Canvas canvas, Rect ch) {
    final Color dark = enabled ? T.brassShadow : T.woodDark;
    final Color light = enabled ? T.brassHi : T.inkFaded;
    canvas.drawLine(
      Offset(ch.left + 3, ch.top + 0.5),
      Offset(ch.right - 3, ch.top + 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = dark.withValues(alpha: 0.9),
    );
    canvas.drawLine(
      Offset(ch.left + 3, ch.bottom - 0.5),
      Offset(ch.right - 3, ch.bottom - 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = light.withValues(alpha: 0.55),
    );
  }

  /// 量程数字：`−30` / `0` / `+30`，压在刻线上方的空白里。
  ///
  /// 阴刻：把字往下压 1px 先描一道亮边，再压上暗字，读起来像冲头打进去的。
  void _paintNumerals(Canvas canvas, _ScaleMap map, Rect ch) {
    final Color ink = enabled ? T.brassShadow : T.woodDark;
    final Color relief =
        (enabled ? T.brassHi : T.inkFaded).withValues(alpha: 0.5);
    for (final double d in <double>[kManualAngleMinDeg, 0, kManualAngleMaxDeg]) {
      final String label =
          d == 0 ? '0' : '${d > 0 ? '+' : '−'}${d.abs().round()}';
      final TextPainter laid = _layoutNumeral(label, ink);
      final Offset at = Offset(map.xOf(d) - laid.width / 2, ch.top + 1);
      _layoutNumeral(label, relief).paint(canvas, at + const Offset(0, 1));
      laid.paint(canvas, at);
    }
  }

  TextPainter _layoutNumeral(String label, Color color) => TextPainter(
        text: TextSpan(text: label, style: Type.captionStrong(color)),
        textDirection: TextDirection.ltr,
      )..layout();

  /// 游标滑块：一枚滚花铜帽骑在凹槽里，帽下伸出一道亮刻线指读数。
  void _paintCarriage(Canvas canvas, _ScaleMap map, Size size) {
    final double cx = map.xOf(deg);
    const double hw = _ScaleMap.capW / 2;
    final double chTop = _channelInset;
    final double chBottom = size.height - _channelInset;

    final Rect cap =
        Rect.fromLTWH(cx - hw + 1.5, chTop + 0.5, _ScaleMap.capW - 3, _capH);

    // 刻线：右一笔亮、左一笔暗托，线才有"立"起来的感觉
    final Rect line =
        Rect.fromLTRB(cx - 1, cap.bottom, cx + 1, chBottom - 2);
    canvas.drawRect(
      line.shift(const Offset(-1.4, 0)),
      Paint()..color = Shade.warmShadow,
    );
    canvas.drawRect(line, Paint()..color = enabled ? T.brassHi : T.inkFaded);

    final RRect capRR = RRect.fromRectAndRadius(cap, const Radius.circular(2.5));
    canvas.drawRRect(
      capRR.shift(const Offset(1.0, 1.8)),
      Paint()..color = Shade.warmShadow,
    );
    canvas.drawRRect(
      capRR,
      Paint()
        ..shader = metalFaceShader(
            cap, enabled ? MetalFinish.brass : MetalFinish.matte),
    );

    // 帽下沿一枚小三角，明确"读的是这条线"
    final Path pointer = Path()
      ..moveTo(cx - 4, cap.bottom - 1)
      ..lineTo(cx + 4, cap.bottom - 1)
      ..lineTo(cx, cap.bottom + 4)
      ..close();
    canvas.drawPath(
      pointer,
      Paint()..color = enabled ? T.brassHi : T.inkFaded,
    );

    if (!enabled) return;

    // 滚花：横向三道，与滑块的运动方向垂直
    final Paint knurl = Paint()
      ..strokeWidth = 1
      ..color = T.brassShadow.withValues(alpha: 0.5);
    for (int i = 1; i <= 3; i++) {
      final double y = cap.top + i * cap.height / 4;
      canvas.drawLine(
          Offset(cap.left + 2, y), Offset(cap.right - 2, y), knurl);
    }
    // 顶面高光（光在左上）与底沿暗边
    canvas.drawLine(
      Offset(cap.left + 1.5, cap.top + 0.8),
      Offset(cap.right - 1.5, cap.top + 0.8),
      Paint()
        ..strokeWidth = 1
        ..color = T.brassHi.withValues(alpha: 0.9),
    );
    canvas.drawLine(
      Offset(cap.left + 1, cap.bottom - 0.7),
      Offset(cap.right - 1, cap.bottom - 0.7),
      Paint()
        ..strokeWidth = 1
        ..color = T.brassShadow.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_VernierPainter old) =>
      old.deg != deg || old.enabled != enabled;
}

/// 回正钮：把角度一步归零。面板高度与尺身凹槽一致，整行读起来是
/// 一台机器上的几件铜活。
class _ResetKnob extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _ResetKnob({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _GaugeButton(
      key: const Key('btn_angle_reset'),
      width: 48,
      enabled: enabled,
      semanticLabel: '角度回正',
      onTap: onTap,
      label: '回正',
    );
  }
}

/// 尺子左右两侧的微调钮：一按走 [kNudgeStepDeg]。
class _NudgeKnob extends StatelessWidget {
  final bool enabled;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

  const _NudgeKnob({
    required this.enabled,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _GaugeButton(
      width: 34,
      enabled: enabled,
      semanticLabel: semanticLabel,
      onTap: onTap,
      label: label,
    );
  }
}

/// 微调/回正共用的铜面按钮。高度与尺身凹槽对齐。
class _GaugeButton extends StatelessWidget {
  final double width;
  final bool enabled;
  final String semanticLabel;
  final VoidCallback onTap;
  final String label;

  const _GaugeButton({
    super.key,
    required this.width,
    required this.enabled,
    required this.semanticLabel,
    required this.onTap,
    required this.label,
  });

  /// 尺身凹槽高度：[kAngleGaugeHeight] 减上下内壁各 5px。
  static const double plateH = kAngleGaugeHeight - 10;

  @override
  Widget build(BuildContext context) {
    return PressSurface(
      key: key,
      enabled: enabled,
      sink: 1,
      semanticLabel: semanticLabel,
      onTap: onTap,
      builder: (BuildContext context, bool pressed) {
        return SizedBox(
          width: width,
          height: kAngleGaugeHeight,
          child: Center(
            child: SizedBox(
              width: width,
              height: plateH,
              child: MetalPlate(
                finish: enabled ? MetalFinish.brass : MetalFinish.matte,
                radius: const BorderRadius.all(Radius.circular(3)),
                pressed: pressed,
                seed: 17,
                child: Center(
                  child: EngravedText(
                    label,
                    // 哑光面偏暗，配奶油色（metal.dart 里实测 6.3:1）；
                    // 亮铜面配深褐（5.6:1）。两者都在无障碍红线之上。
                    style: Type.plate(enabled ? T.inkBrown : T.creamText),
                    relief: enabled ? T.brassHi : T.inkFaded,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
