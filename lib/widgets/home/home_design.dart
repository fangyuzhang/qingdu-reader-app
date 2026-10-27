import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../services/app_theme.dart';

/// The home surface keeps its warm paper / tomato identity in both themes.
class HomePalette {
  // 【轻读重构】青少年版视觉：轻读绿为主，珊瑚橙做点缀（highlight）。
  static const accent = Color(0xFF2FA98C);
  static const accentStrong = Color(0xFF1F8A72);
  static const highlight = Color(0xFFE2603F);
  final bool dark;

  /// #15/#9：墨水屏时所有纸面 / 文字 / 线条退化为纯黑白。accent 静态常量
  /// 仍为品牌橙（93 处直接引用），本轮不全量替换，见收尾未验项。
  final bool eink;

  final Color canvas;
  final Color surface;
  final Color ink;
  final Color muted;
  final Color soft;
  final Color line;

  const HomePalette._({
    required this.dark,
    required this.eink,
    required this.canvas,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.soft,
    required this.line,
  });

  /// Reads the *current* theme colours instead of switching between two
  /// hand-written palettes on `brightness`. MaterialApp interpolates ThemeData
  /// for 220ms; taking the interpolated values here makes custom surfaces fade
  /// along with it instead of flashing white/black at the midpoint.
  factory HomePalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return HomePalette._(
      dark: theme.brightness == Brightness.dark,
      eink: einkModeNotifier.value,
      canvas: theme.scaffoldBackgroundColor,
      surface: scheme.surface,
      ink: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      soft: scheme.surfaceContainer,
      line: scheme.outlineVariant,
    );
  }

  // 浅色 muted(#6C7A73) 在 canvas(#FAFBF6) 上只有 4.33:1，副标题/计数这类
  // 11–12sp 小字不达 4.5:1；#5E6B64 提到 5.37:1，仍比正文轻一档。
  // accentStrong(#1F8A72) 作小字前景只有 4.25:1；#176B58 在 canvas 上 6.16:1、
  // 在 soft 上 5.69:1。填充仍用 accent，不改变品牌色的视觉重量。
  Color get accentText =>
      eink ? Colors.black : (dark ? accent : const Color(0xFF176B58));

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
/// [FadeTransition] and [SlideTransition] animate compositor-friendly layers;
/// the child is passed through unchanged and wrapped in a [RepaintBoundary], so
/// the card itself is not rebuilt on every animation tick. A sliver disposes
/// children outside its cache extent, so a card remounted by scrolling back up
/// must opt out ([animate] false) to avoid replaying the entrance.
class HomeEntrance extends StatefulWidget {
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
  State<HomeEntrance> createState() => _HomeEntranceState();
}

class _HomeEntranceState extends State<HomeEntrance>
    with SingleTickerProviderStateMixin {
  static const _staggerMs = 40;
  static const _riseMs = 260;

  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;
  late bool _playing;

  @override
  void initState() {
    super.initState();
    final delayMs = widget.index.clamp(0, 5) * _staggerMs;
    final totalMs = delayMs + _riseMs;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    final eased = CurvedAnimation(
      parent: _controller,
      curve: Interval(delayMs / totalMs, 1, curve: Curves.easeOutCubic),
    );
    _opacity = Tween<double>(begin: 0.5, end: 1).animate(eased);
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(eased);
    _playing = widget.animate;
    if (_playing) _controller.forward();
  }

  @override
  void didUpdateWidget(HomeEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_playing && widget.animate) {
      _playing = true;
      _controller.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_playing) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating && !_controller.isCompleted) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_playing || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _offset,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
