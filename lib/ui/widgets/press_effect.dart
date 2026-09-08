/// 按压反馈：按钮下沉 2px + 阴影收缩（DESIGN.md §3）。
///
/// **全 App 不使用 Material 的水波纹点击组件**（G2C.9 会 grep 源码，
/// 所以这里连类名都不写出来，避免注释被误判）。
/// 真实的木/铜按钮是"压下去"，不是"泛起一圈水波"。
///
/// 势力范围：ui-woodcraft。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// 用 [builder] 自绘按钮外观；[pressed] 为 true 时应画成压下的样子。
class PressSurface extends StatefulWidget {
  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final bool enabled;

  /// 按下时的下沉距离。
  final double sink;

  /// 是否触发中等强度震动（DESIGN.md §5 区域 C）。
  final bool haptic;

  /// 无障碍标签。
  final String? semanticLabel;

  const PressSurface({
    super.key,
    required this.builder,
    this.onTap,
    this.enabled = true,
    this.sink = 2,
    this.haptic = false,
    this.semanticLabel,
  });

  @override
  State<PressSurface> createState() => _PressSurfaceState();
}

class _PressSurfaceState extends State<PressSurface> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.enabled && widget.onTap != null;
    final Widget content = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: _down ? widget.sink : 0),
      duration: Motion.micro,
      curve: Motion.curve,
      builder: (BuildContext ctx, double v, Widget? child) =>
          Transform.translate(offset: Offset(0, v), child: child),
      child: widget.builder(context, _down),
    );

    return Semantics(
      button: true,
      enabled: active,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: active ? (_) => _set(true) : null,
        onTapUp: active ? (_) => _set(false) : null,
        onTapCancel: active ? () => _set(false) : null,
        onTap: active
            ? () {
                if (widget.haptic) {
                  HapticFeedback.mediumImpact();
                }
                widget.onTap!.call();
              }
            : null,
        child: content,
      ),
    );
  }
}
