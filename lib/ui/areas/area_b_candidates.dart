/// 区域 B — 候选结果（DESIGN.md §5，占屏 38%）。
///
/// 绒布台面上一排小木相框，横向滚动。每个候选下方一块黄铜铭牌刻底色名。
/// 生成中显示"显影"占位；空态显示一排空相框（**不能是一片空白**，
/// RUBRIC 致命项 8）。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../state/providers.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/wood_painter.dart';
import '../widgets/candidate_card.dart';
import '../widgets/developing.dart';
import '../widgets/metal.dart';
import '../widgets/mouse_wheel_scroller.dart';

class AreaBCandidates extends ConsumerStatefulWidget {
  const AreaBCandidates({super.key});

  @override
  ConsumerState<AreaBCandidates> createState() => _AreaBCandidatesState();
}

class _AreaBCandidatesState extends ConsumerState<AreaBCandidates> {
  // 滚轮横滚（Windows 鼠标滚轮只报 dy，见 mouse_wheel_scroller.dart）。
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = ref.watch(appStateProvider);
    final WorkbenchState wb = ref.watch(workbenchProvider);
    final double aspect = app.spec.aspectRatio;

    final bool developing =
        app.stage == Stage.matting || app.stage == Stage.composing;
    final bool hasResult = app.candidates.isNotEmpty;
    final LivePreviewAdjust? adjust = _liveAdjust(app, wb);

    return SizedBox.expand(
      key: const Key('area_b'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const FeltSurface(seed: 5),
          const Align(alignment: Alignment.topCenter, child: SeamDivider()),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(stage: app.stage, count: app.candidates.length),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    // 相框高度由可用高度倒推：铭牌 24 + 间隙 5 + 木框内边距 14
                    // + 上浮 4 + 投影 6
                    final double photoH = (c.maxHeight - 24 - 5 - 14 - 4 - 8)
                        .clamp(56.0, 420.0);
                    final double cardW = math.max(56.0, photoH * aspect) + 14;
                    return MouseWheelScroller(
                      controller: _scroll,
                      child: ListView.separated(
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        itemCount: kBuiltInBackgrounds.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (BuildContext context, int i) {
                          final BackgroundStyle style = kBuiltInBackgrounds[i];
                          final Candidate? found = _find(
                            app.candidates,
                            style.id,
                          );
                          return CandidateCard(
                            key: Key('candidate_${style.id}'),
                            style: style,
                            thumb: found?.thumbBytes,
                            aspectRatio: aspect,
                            liveAdjust: found == null ? null : adjust,
                            selected:
                                hasResult && wb.selectedStyleId == style.id,
                            width: cardW,
                            seed: 11 + i * 13,
                            onTap: found == null
                                ? null
                                : () => ref
                                      .read(workbenchProvider.notifier)
                                      .select(style.id),
                            placeholder: developing
                                ? DevelopingPlate(aspectRatio: aspect)
                                : const _EmptySlot(),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const _ShelfLip(),
            ],
          ),
        ],
      ),
    );
  }

  static Candidate? _find(List<Candidate> list, String id) {
    for (final Candidate c in list) {
      if (c.style.id == id) return c;
    }
    return null;
  }

  /// 交互中的实时预览调整：把当前几何（角度 + 裁剪框）与候选合成时的
  /// 快照（[AppState.composedAngleDeg] / [AppState.composedCrop]）之差
  /// 折成缩略图上的仿射变换。几何未动或数据不齐时返回 null（原样显示）。
  ///
  /// 角度的符号换算与区域 A 的框选层同源：框选层在 manual 增大时顺时针
  /// 转 `+δ`，透过框看到的照片内容等于逆时针转 —— 缩略图内容同样按
  /// `−(manual − composed)` 旋转（见 crop_overlay 的 frameRotationRad）。
  static LivePreviewAdjust? _liveAdjust(AppState app, WorkbenchState wb) {
    if (app.candidates.isEmpty) return null;
    final Rect? live = wb.crop ?? app.suggestedCrop;
    final Rect? composed = app.composedCrop ?? app.suggestedCrop;
    if (live == null || composed == null) return null;
    if (live.width < 1 || live.height < 1 || composed.width < 1) return null;
    final double dDeg = app.manualAngleDeg - app.composedAngleDeg;
    final bool still = dDeg.abs() < 0.01 &&
        (live.center - composed.center).distance < 0.5 &&
        (live.width - composed.width).abs() < 0.5 &&
        (live.height - composed.height).abs() < 0.5;
    if (still) return null;
    return LivePreviewAdjust(
      dAngleRad: -dDeg * math.pi / 180,
      composedCrop: composed,
      liveCrop: live,
    );
  }
}

/// 台面前沿：绒布台下面那道木质挡边，相框就立在它上面。
/// 同时把区域 B 的可用高度收窄一点，让一屏能露出更多候选（R6 信息层级）。
class _ShelfLip extends StatelessWidget {
  const _ShelfLip();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const WoodSurface(
            spec: WoodSpec(tone: WoodTone.light, seed: 71, figure: false),
            origin: Offset(0, 700),
          ),
          CustomPaint(painter: const _LipPainter()),
        ],
      ),
    );
  }
}

class _LipPainter extends CustomPainter {
  const _LipPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    // 台面投在挡边上的影（光在左上，影往下）
    canvas.drawRect(
      Rect.fromLTWH(r.left, r.top, r.width, 7),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Shade.warmShadow, Color(0x00241609)],
        ).createShader(Rect.fromLTWH(r.left, r.top, r.width, 7)),
    );
    // 挡边正面的倒角亮线
    canvas.drawLine(
      Offset(r.left, r.top + 7.5),
      Offset(r.right, r.top + 7.5),
      Paint()
        ..strokeWidth = 1.4
        ..color = T.woodLight.withValues(alpha: 0.55),
    );
    canvas.drawLine(
      Offset(r.left, r.bottom - 0.5),
      Offset(r.right, r.bottom - 0.5),
      Paint()
        ..strokeWidth = 1
        ..color = T.woodDark,
    );
  }

  @override
  bool shouldRepaint(_LipPainter old) => false;
}

/// 区域 B 顶栏：一根黄铜条，左边刻区域名，右边刻状态。
class _Header extends StatelessWidget {
  final Stage stage;
  final int count;

  const _Header({required this.stage, required this.count});

  String get _status => switch (stage) {
    Stage.idle => '等待照片',
    Stage.matting => '正在抠图',
    Stage.composing => '正在冲洗 $count / 6',
    Stage.ready => '已完成 6 张',
    Stage.error => '未能完成',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SizedBox(
        height: 26,
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 86,
              child: Nameplate(text: '候选底色', highlighted: true),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _status,
                  style: Type.caption(T.creamText),
                  maxLines: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态相框里的一张空白相纸。
class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PaperSurface(seed: 29, edgeDarken: 0.85),
        Center(child: _EmptyMark()),
      ],
    );
  }
}

class _EmptyMark extends StatelessWidget {
  const _EmptyMark();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(28, 28),
      painter: const _CrossPainter(),
    );
  }
}

/// 空相纸上的定位十字，像未曝光的相纸上的对位标记。
class _CrossPainter extends CustomPainter {
  const _CrossPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final Paint p = Paint()
      ..strokeWidth = 1.2
      ..color = T.inkFaded.withValues(alpha: 0.55);
    canvas.drawLine(c - const Offset(9, 0), c + const Offset(9, 0), p);
    canvas.drawLine(c - const Offset(0, 9), c + const Offset(0, 9), p);
    canvas.drawCircle(
      c,
      6.5,
      p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_CrossPainter old) => false;
}
