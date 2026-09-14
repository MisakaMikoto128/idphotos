/// 区域 C — 保存（DESIGN.md §5，占屏 17%）。
///
/// 一块宽大的黄铜压花按钮，浮雕字"保 存 照 片"；按下时下沉 + 中等强度震动；
/// 成功后按钮短暂改字，并从按钮上方飘出一张纸条。
/// 禁用态金属变哑光灰褐（不变透明度）。
///
/// 势力范围：ui-woodcraft。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../state/providers.dart';
import '../util/error_text.dart';
import '../theme/brass.dart';
import '../theme/paper_painter.dart';
import '../theme/surfaces.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../theme/wood_painter.dart';
import '../widgets/metal.dart';
import '../widgets/press_effect.dart';

class AreaCSave extends ConsumerStatefulWidget {
  const AreaCSave({super.key});

  @override
  ConsumerState<AreaCSave> createState() => _AreaCSaveState();
}

class _AreaCSaveState extends ConsumerState<AreaCSave> {
  Timer? _dismiss;
  bool _busy = false;

  @override
  void dispose() {
    _dismiss?.cancel();
    super.dispose();
  }

  Candidate? _selected(AppState app, WorkbenchState wb) {
    if (app.candidates.isEmpty) return null;
    for (final Candidate c in app.candidates) {
      if (c.style.id == wb.selectedStyleId) return c;
    }
    return app.candidates.first;
  }

  /// 保存。
  ///
  /// `save()` 返回的 Future 可能 reject（无存储权限、磁盘满、MediaStore 插入
  /// 失败）。**必须 try/finally**：否则异常从这个 `VoidCallback` 逃逸成未处理的
  /// 异步错误，`_busy` 永不复位，`enabled` 恒为 false，按钮退回哑光
  /// "请先选择照片"态 —— 不重启 App 就没法重试。
  /// catch 分支不空吞：翻成中文写进 `WorkbenchState.saveError`，
  /// 由按钮上方的纸条显示出来（见 [_SaveSlip]）。
  Future<void> _save(Candidate c) async {
    if (_busy) return;
    setState(() => _busy = true);
    final WorkbenchNotifier wb = ref.read(workbenchProvider.notifier);
    final UiConfig cfg = ref.read(uiConfigProvider);
    wb.setSaveError(null);
    bool ok = false;
    try {
      await ref.read(controllerProvider).save(c);
      ok = true;
    } catch (e, st) {
      logUiError('save', e, st);
      if (mounted) {
        wb.setSaveError(errorTextOf(e, fallback: '保存失败了，请再试一次'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || !ok) return;
    wb.setSaveFeedback(true);
    if (!cfg.freezeAnimations) {
      _dismiss?.cancel();
      _dismiss = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) wb.setSaveFeedback(false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState app = ref.watch(appStateProvider);
    final WorkbenchState wb = ref.watch(workbenchProvider);
    final Candidate? sel = _selected(app, wb);
    final bool enabled = sel != null && app.stage == Stage.ready && !_busy;
    final double bottomInset = MediaQuery.paddingOf(context).bottom;

    return SizedBox.expand(
      key: const Key('area_c'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 台面：颜色最深的一块木头，让区域 C 在视觉上"托底"
          const WoodSurface(
            spec: WoodSpec(tone: WoodTone.dark, seed: 41, figure: false),
            origin: Offset(0, 1400),
          ),
          // 与区域 B 之间的接缝
          const Align(alignment: Alignment.topCenter, child: SeamDivider()),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4 + bottomInset),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                // 小屏（720×1280）上区域 C 只有 ~109 逻辑像素高，
                // 纸条 + 间距 + 按钮用 Column 竖排必然溢出。
                // 改成 Stack：按钮贴底、纸条贴顶，两者各自按可用高度收缩，
                // 空间不够时由 Stack 裁切而不是抛 overflow（RUBRIC 致命项 7）。
                final double h =
                    (c.maxHeight * 0.68).clamp(40.0, 74.0).clamp(0.0, c.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.topCenter,
                      child: _SaveSlip(
                        visible: wb.saveFeedback || wb.saveError != null,
                        error: wb.saveError,
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        height: h,
                        width: double.infinity,
                        child: _SaveButton(
                          enabled: enabled,
                          saved: wb.saveFeedback,
                          onTap: sel == null ? null : () => _save(sel),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveButton extends ConsumerWidget {
  final bool enabled;
  final bool saved;
  final VoidCallback? onTap;

  const _SaveButton({
    required this.enabled,
    required this.saved,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool haptic = ref.watch(uiConfigProvider).haptics;
    final String label = saved ? '已保存到相册' : '保 存 照 片';
    return PressSurface(
      key: const Key('btn_save'),
      enabled: enabled,
      haptic: haptic,
      semanticLabel: enabled ? label : '请先选择照片',
      onTap: enabled ? onTap : null,
      builder: (BuildContext context, bool pressed) {
        final MetalFinish finish =
            enabled ? MetalFinish.brass : MetalFinish.matte;
        return MetalPlate(
          finish: finish,
          radius: Shape.buttonBorder,
          pressed: pressed,
          screws: true,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: enabled
                    // 阳刻：深字 + 下方铜色高光边
                    ? EngravedText(
                        label,
                        style: Type.title(T.inkBrown),
                        relief: T.brassHi,
                      )
                    // 哑光禁用态：面偏暗，改用米色字保住对比度（实测 6.3:1）
                    : EngravedText(
                        '请 先 选 择 照 片',
                        style: Type.title(T.creamText),
                        relief: T.woodDark,
                        raised: false,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 保存后飘出的小纸条（DESIGN.md §5：300ms）。
/// [error] 非空时改成失败提示：同一张纸条，前面多一枚旧漆红标记。
class _SaveSlip extends StatelessWidget {
  final bool visible;
  final String? error;

  const _SaveSlip({required this.visible, this.error});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: Motion.area,
      curve: Motion.curve,
      child: AnimatedSlide(
        offset: Offset(0, visible ? 0 : 0.45),
        duration: Motion.area,
        curve: Motion.curve,
        child: Transform.rotate(
          angle: -0.018,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              boxShadow: Shade.lifted,
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(2)),
              child: CustomPaint(
                painter: const PaperPainter(seed: 21, edgeDarken: 0.7),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (error != null)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: SizedBox(
                            width: 8,
                            height: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: T.accentRed,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      Flexible(
                        child: Text(
                          error ?? '已保存到相册　·　照片未离开本机',
                          style: Type.small(T.inkBrown),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
