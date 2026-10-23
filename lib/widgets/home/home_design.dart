import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../services/app_theme.dart';

/// The home surface keeps its warm paper / tomato identity in both themes.
class HomePalette {
  // 【青茄重构】青少年版视觉：青茄绿为主，珊瑚橙做点缀（highlight）。
  static const accent = Color(0xFF2FA98C);
  static const accentStrong = Color(0xFF1F8A72);
  static const highlight = Color(0xFFE2603F);
  final bool dark;

  /// #15/#9：墨水屏时所有纸面 / 文字 / 线条退化为纯黑白。accent 静态常量
  /// 仍为品牌橙（93 处直接引用），本轮不全量替换，见收尾未验项。
  final bool eink;

  const HomePalette(this.dark, {this.eink = false});

  factory HomePalette.of(BuildContext context) => HomePalette(
    Theme.of(context).brightness == Brightness.dark,
    eink: einkModeNotifier.value,
  );

  Color get canvas => eink
      ? Colors.white
      : (dark ? const Color(0xFF0F1413) : const Color(0xFFFAFBF6));
  Color get surface =>
      eink ? Colors.white : (dark ? const Color(0xFF171E1C) : Colors.white);
  Color get ink => eink
      ? Colors.black
      : (dark ? const Color(0xFFF1F5F2) : const Color(0xFF212824));
  // 浅色 muted(#6C7A73) 在 canvas(#FAFBF6) 上只有 4.33:1，副标题/计数这类
  // 11–12sp 小字不达 4.5:1；#5E6B64 提到 5.37:1，仍比正文轻一档。
  Color get muted => eink
      ? Colors.black
      : (dark ? const Color(0xFF98A5A0) : const Color(0xFF5E6B64));
  // accentStrong(#1F8A72) 作小字前景只有 4.25:1；#176B58 在 canvas 上 6.16:1、
  // 在 soft 上 5.69:1。填充仍用 accent，不改变品牌色的视觉重量。
  Color get accentText =>
      eink ? Colors.black : (dark ? accent : const Color(0xFF176B58));
  Color get soft => eink
      ? Colors.white
      : (dark ? const Color(0xFF1B2421) : const Color(0xFFEEF3EC));
  Color get line => eink
      ? Colors.black
      : (dark ? const Color(0xFF2A3330) : const Color(0xFFE3E9E1));

  // 筛选 chip 的统一配色，取自听书页的音色卡：未选是比底色更暗的一层，
  // 选中抬成 surface 并加一圈主色描边，视线自然落在当前选择上。
  Color get chipFill =>
      eink ? Colors.white : line.withValues(alpha: dark ? 0.45 : 0.55);
  Color get chipSelectedFill => eink ? Colors.white : surface;
  BorderSide chipBorder(bool selected) => BorderSide(
    color: selected
        ? (eink ? Colors.black : accentText.withValues(alpha: 0.55))
        : Colors.transparent,
    width: selected ? (eink ? 1.4 : 1.2) : 0,
  );
}

/// Pointer, keyboard and accessibility activation share the same action.
/// The spring settles after interaction; no idle animation is scheduled.
class HomePressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final String? semanticLabel;

  const HomePressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.semanticLabel,
  });

  @override
  State<HomePressable> createState() => _HomePressableState();
}

class _HomePressableState extends State<HomePressable>
    with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);

  void _press(bool pressed) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _scale.stop();
      _scale.value = 1;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 30),
        _scale.value,
        pressed ? 0.972 : 1,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _scale,
    builder: (context, child) =>
        Transform.scale(scale: _scale.value, child: child),
    child: Semantics(
      label: widget.semanticLabel,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          borderRadius: widget.borderRadius,
          splashColor: HomePalette.accent.withValues(alpha: 0.08),
          highlightColor: Colors.transparent,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Fades and lifts a newly arrived child into place.
///
/// The fade costs an [Opacity] layer for as long as it runs, and a sliver
/// disposes the children that leave its cache extent, so a child that is
/// re-mounted by scrolling back up the feed must opt out ([animate] false) or
/// every scroll past the first screenful replays a layer per card.
class HomeEntrance extends StatelessWidget {
  final int index;
  final bool animate;
  final Widget child;

  const HomeEntrance({
    super.key,
    this.index = 0,
    this.animate = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 380 + index.clamp(0, 5) * 45),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: 0.5 + value * 0.5,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}
