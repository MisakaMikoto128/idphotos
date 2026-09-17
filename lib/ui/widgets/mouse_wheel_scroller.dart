/// 鼠标滚轮 → 滚动翻译层（区域 B 横向列表用，也可复用到其它列表）。
///
/// 根因：Flutter 的 `Scrollable` 对横向列表只消费 `PointerScrollEvent` 的
/// `scrollDelta.dx`；Windows 桌面鼠标滚轮只报 `dy`，于是滚轮落在横向
/// `ListView` 上被整个忽略（只有触摸板双指、或按住 Shift 才有 dx/翻转）。
///
/// 修法：外层 `Listener` 抢先注册 `PointerSignalResolver`，把 `dy`
/// 交给 `ScrollPosition.pointerScroll` —— 与原生 `Scrollable` 同一条
/// 路径，自带物理钳制（滚到头继续滚只停不炸、不回弹）。
/// 横向列表自身因 dx==0 不会注册同一事件，无 resolver 冲突；
/// Shift+滚轮的原生翻转行为也不受影响（同为 dy，结果一致）。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

class MouseWheelScroller extends StatelessWidget {
  const MouseWheelScroller({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double dy = event.scrollDelta.dy;
    if (dy == 0 || !dy.isFinite) return;
    if (!controller.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      PointerSignalEvent resolved,
    ) {
      final double delta = (resolved as PointerScrollEvent).scrollDelta.dy;
      final ScrollPosition position = controller.position;
      if (position is ScrollPositionWithSingleContext) {
        position.pointerScroll(delta);
      } else {
        // 兜底：非标准 position（如 PageView）也能滚，只是没有物理。
        final double target = (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        position.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(onPointerSignal: _onPointerSignal, child: child);
  }
}
