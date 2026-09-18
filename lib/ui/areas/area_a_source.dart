/// 区域 A — 上传与框选（DESIGN.md §5，占屏 45%）。
///
/// 顶部一条黄铜标尺（当前规格 + 像素尺寸，点击拉出规格抽屉）；
/// 下方一个带铜包角的木相框：空态框内是绒布 + 铜质"+"；有图后图片居中 contain，
/// 覆盖可拖拽的裁剪框。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../state/photo_source.dart';
import '../state/providers.dart';
import '../theme/brass.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/wood_painter.dart';
import '../util/crop_geometry.dart';
import '../util/error_text.dart';
import '../util/image_size.dart';
import '../widgets/angle_gauge.dart';
import '../widgets/crop_overlay.dart';
import '../widgets/metal.dart';
import '../widgets/press_effect.dart';
import '../widgets/spec_ruler.dart';

class AreaASource extends ConsumerWidget {
  const AreaASource({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppState app = ref.watch(appStateProvider);
    final WorkbenchState wb = ref.watch(workbenchProvider);
    final double topInset = MediaQuery.paddingOf(context).top;
    final bool hasImage = app.sourceImage != null;

    // 换了新照片：上一张留下的取图/保存错误立即作废（审查 L3）——
    // 保存失败的红条不该跟着新照片走进第二轮。以 sourceImage 的**实例身份**
    // 判断"换图"：裁剪/换规格等无关更新传的是同一份字节，不会误清。
    // 载入失败（sourceImage 回到 null）时不清，错误提示要保持可见。
    ref.listen<AppState>(appStateProvider, (AppState? prev, AppState next) {
      final Uint8List? prevImg = prev?.sourceImage;
      final Uint8List? nextImg = next.sourceImage;
      if (nextImg == null || identical(prevImg, nextImg)) return;
      final WorkbenchNotifier notifier = ref.read(workbenchProvider.notifier);
      notifier.setPickError(null);
      notifier.setSaveError(null);
    });

    return SizedBox.expand(
      key: const Key('area_a'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const WoodSurface(spec: WoodSpec(seed: 7)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(height: topInset + 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                child: Row(
                  children: <Widget>[
                    const _BrandPlate(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SpecRuler(
                        spec: app.spec,
                        onTap: () => ref
                            .read(workbenchProvider.notifier)
                            .setSpecSheet(true),
                        // PHASE6 W1：长按标尺打开"关于"浮层。
                        onLongPress: () => ref
                            .read(workbenchProvider.notifier)
                            .setAboutOpen(true),
                      ),
                    ),
                  ],
                ),
              ),
              _CaptionRow(
                hasImage: hasImage,
                spec: app.spec,
                // 取图失败是 UI 层自己的错（不经过 controller），优先显示；
                // 其余错误仍来自 AppState.errorMessage（CONTRACTS §6）。
                error: wb.pickError ?? app.errorMessage,
                onRepick: () => _pick(ref),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: _PhotoFrame(
                          app: app,
                          wb: wb,
                          onPick: () => _pick(ref),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 角度微调尺。紧贴画布下沿，因为它调的就是框里这张图；
                      // 仍在区域 A 之内，不新增第四个主区域（CLAUDE.md §2）。
                      // 冲洗中禁拖，与裁剪框同一条规矩。
                      AngleGauge(
                        key: const Key('angle_gauge'),
                        angleDeg: app.manualAngleDeg,
                        enabled: app.stage == Stage.ready,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 取图 + 载入。
  ///
  /// 全程包在 try/catch 里：`ImagePicker` 在用户拒绝 `READ_MEDIA_IMAGES`
  /// 或 picker activity 被系统杀掉时会抛 `PlatformException`（Android 13+
  /// 首次运行的常见路径）。没人接的话异常会变成未处理的异步错误，用户只看到
  /// 空态、没有任何提示 —— 违反 CONTRACTS §6"所有异常必须转成中文提示"。
  /// 这里**不是空吞**：翻成中文写进 `WorkbenchState.pickError`，
  /// 由区域 A 的提示行显示出来，同时把原始异常打进日志。
  static Future<void> _pick(WidgetRef ref) async {
    final WorkbenchNotifier wb = ref.read(workbenchProvider.notifier);
    wb.setPickError(null);
    try {
      final Uint8List? bytes = await ref.read(photoSourceProvider).pick();
      if (bytes == null) return; // 用户主动取消，不是错误
      await ref.read(controllerProvider).loadImage(bytes);
    } catch (e, st) {
      logUiError('pick', e, st);
      wb.setPickError(errorTextOf(e, fallback: '打不开相册，请稍后再试'));
    }
  }
}

/// 左上角的品牌铭牌：整台"工作台"的铭板。
class _BrandPlate extends StatelessWidget {
  const _BrandPlate();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 62,
      height: 40,
      child: MetalPlate(
        finish: MetalFinish.brass,
        seed: 2,
        screws: false,
        child: Center(
          child: EngravedText(
            '木照',
            style: Type.subtitle(T.inkBrown),
            relief: T.brassHi,
          ),
        ),
      ),
    );
  }
}

/// 标尺下方的一行小字：告诉用户此刻该做什么（RUBRIC R6 信息层级）。
class _CaptionRow extends StatelessWidget {
  final bool hasImage;
  final PhotoSpec spec;
  final String? error;
  final VoidCallback onRepick;

  const _CaptionRow({
    required this.hasImage,
    required this.spec,
    required this.error,
    required this.onRepick,
  });

  @override
  Widget build(BuildContext context) {
    final String text = error ??
        (hasImage
            ? '拖动四角调整裁剪范围　·　已锁定${spec.nameZh}比例'
            : '支持 JPG / PNG　·　全程离线处理，照片不离开本机');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 14, 1),
      child: Row(
        children: <Widget>[
          if (error != null)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: _ErrorMark(),
            ),
          Expanded(
            child: Text(
              text,
              style: Type.caption(error != null ? T.paper : T.creamText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasImage)
            PressSurface(
              onTap: onRepick,
              sink: 1,
              semanticLabel: '更换照片',
              builder: (BuildContext c, bool pressed) => SizedBox(
                width: 60,
                height: 24,
                child: MetalPlate(
                  finish: MetalFinish.brass,
                  pressed: pressed,
                  seed: 7,
                  child: Center(
                    child: EngravedText(
                      '更换',
                      style: Type.caption(T.inkBrown),
                      relief: T.brassHi,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 错误提示前的一枚旧漆红标记。
class _ErrorMark extends StatelessWidget {
  const _ErrorMark();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 10,
      height: 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: T.accentRed,
          shape: BoxShape.circle,
          boxShadow: Shade.pressed,
        ),
      ),
    );
  }
}

/// 木相框：外框木料 + 内衬绒布 + 四角铜包角。
class _PhotoFrame extends ConsumerWidget {
  final AppState app;
  final WorkbenchState wb;
  final VoidCallback onPick;

  const _PhotoFrame({
    required this.app,
    required this.wb,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Uint8List? bytes = app.sourceImage;
    final PixelSize? px = bytes == null ? null : readImageSize(bytes);

    Widget inner;
    if (bytes == null || px == null) {
      inner = _EmptyPlate(onPick: onPick);
    } else {
      final Size src = Size(px.width.toDouble(), px.height.toDouble());
      final Rect crop = _effectiveCrop(app, wb, src);
      inner = CropOverlay(
        sourceSize: src,
        crop: crop,
        aspectRatio: app.spec.aspectRatio,
        imageBytes: bytes,
        // 冲洗中（matting/composing）禁拖（审查 X6）：这时拖出的框会带着
        // 新图 token 进 workbench，suggestedCrop 到达时被静默覆盖，
        // 引擎的自动取景永远不出现。
        interactive: app.stage == Stage.ready,
        activeHandle: wb.activeHandle,
        onChanged: (Rect r) {
          ref
              .read(workbenchProvider.notifier)
              .updateCrop(r, cropTokenOf(app));
          ref.read(controllerProvider).setCrop(r);
        },
        onDragStart: (String h) =>
            ref.read(workbenchProvider.notifier).beginDrag(h),
        onDragEnd: () => ref.read(workbenchProvider.notifier).endDrag(),
      );
    }

    // 手动微调角度：预览必须跟着转，否则用户在调一个看不见的东西。
    //
    // 整体旋转（照片 + 裁剪框 + 把手）与引擎的做法一致：`_mapCropToRotated`
    // 把用户的框**刚体**搬到旋转空间（中心映射、宽高原样带走），所以框在
    // 成片里就是跟着图一起转的。`Transform` 默认 transformHitTests，
    // CropOverlay 的 `globalToLocal` 会反解旋转，把手在斜着的框上照样拖得准。
    //
    // angle == 0 时**不套 Transform**：默认态（含全部截图场景与门禁）的
    // widget 树与加本功能之前逐节点一致，不给既有裁决引入任何变量。
    final double angle = app.manualAngleDeg;
    if (angle != 0) {
      inner = Transform.rotate(
        angle: canvasRotationRad(angle),
        child: inner,
      );
    }

    return WoodPanel(
      spec: const WoodSpec(tone: WoodTone.dark, seed: 23, figure: false),
      grainOrigin: const Offset(0, 120),
      padding: const EdgeInsets.all(11),
      child: BrassCorners(
        arm: 28,
        highlight: wb.activeHandle != null,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(2)),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const FeltSurface(seed: 13),
              inner,
              // 框口内投影：让照片显得真的嵌在框里
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Shade.warmShadow,
                        Color(0x00241609),
                        Color(0x00241609),
                      ],
                      stops: <double>[0.0, 0.10, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 有效裁剪框：用户拖过就用用户的；否则用引擎给的建议框；再否则居中推算。
  static Rect _effectiveCrop(AppState app, WorkbenchState wb, Size src) {
    final Rect bounds = Offset.zero & src;
    final double aspect = app.spec.aspectRatio;
    if (wb.crop != null && wb.cropToken == cropTokenOf(app)) {
      return CropMath.fitIntoBounds(wb.crop!, bounds, aspect);
    }
    final Rect? suggested = app.suggestedCrop;
    if (suggested != null && !suggested.isEmpty) {
      return CropMath.fitIntoBounds(suggested, bounds, aspect);
    }
    return CropMath.defaultCrop(src, aspect);
  }
}

/// 空态：绒布上一枚铜质"+"托盘。
class _EmptyPlate extends StatelessWidget {
  final VoidCallback onPick;

  const _EmptyPlate({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: PressSurface(
        key: const Key('btn_pick'),
        onTap: onPick,
        semanticLabel: '轻触选择照片',
        builder: (BuildContext context, bool pressed) {
          // FittedBox：真机上有的是空间，原尺寸呈现；极矮的测试表面
          // （800x600 的 host test）里整体等比缩小，而不是竖向溢出。
          return FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 74,
                    height: 74,
                    child: CustomPaint(painter: _PlusPainter(pressed: pressed)),
                  ),
                  const SizedBox(height: 14),
                  _PaperLabel(pressed: pressed),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PaperLabel extends StatelessWidget {
  final bool pressed;

  const _PaperLabel({required this.pressed});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: pressed ? Shade.pressed : Shade.lifted,
        borderRadius: Shape.buttonBorder,
      ),
      child: ClipRRect(
        borderRadius: Shape.buttonBorder,
        child: CustomPaint(
          painter: const PaperPainter(seed: 41, edgeDarken: 0.8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('轻触选择照片', style: Type.bodyStrong(T.inkBrown)),
                const SizedBox(height: 2),
                Text('从相册里挑一张正面照', style: Type.caption(T.inkBrown)),
                const SizedBox(height: 6),
                // 关于页入口的可见提示（visual-critic PHASE6：零提示发现率为零）
                Text('长按顶部标尺，了解木照',
                    style: Type.caption(T.brass)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 铜质"+"：一枚圆铜牌，中间是凹刻的十字。
class _PlusPainter extends CustomPainter {
  final bool pressed;

  const _PlusPainter({required this.pressed});

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = size.width / 2 - 3;
    canvas.drawCircle(
      c + Offset(1.2, pressed ? 1.0 : 2.4),
      r,
      Paint()..color = Shade.warmShadow,
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const <Color>[T.brassHi, T.brass, T.brassShadow],
          stops: const <double>[0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // 环形凹槽
    canvas.drawCircle(
      c,
      r - 6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = T.brassShadow.withValues(alpha: 0.8),
    );
    canvas.drawCircle(
      c,
      r - 7.4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = T.brassHi.withValues(alpha: 0.55),
    );
    // 十字：先暗刻，再在下缘补一道高光，做出凹陷
    const double arm = 16;
    final Paint carve = Paint()
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.square
      ..color = T.brassShadow;
    canvas.drawLine(c - const Offset(arm, 0), c + const Offset(arm, 0), carve);
    canvas.drawLine(c - const Offset(0, arm), c + const Offset(0, arm), carve);
    final Paint gleam = Paint()
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square
      ..color = T.brassHi.withValues(alpha: 0.75);
    canvas.drawLine(c - const Offset(arm, -3), c + const Offset(arm, 3), gleam);
    canvas.drawLine(c - const Offset(-3, arm), c + const Offset(3, arm), gleam);
  }

  @override
  bool shouldRepaint(_PlusPainter old) => old.pressed != pressed;
}
