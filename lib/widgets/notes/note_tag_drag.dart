import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 笔记页里可拖动的东西只有两种：批注类型角标、自由文本标签。
enum NoteTagKind { marker, tag }

/// 自由标签没有用户选色的步骤，用文案算一个稳定的颜色：
/// 同一标签在浅色/深色主题下都保持同一个色相，只是明度不同。
int noteTagColorValue(String label, {required bool dark}) {
  var seed = 0;
  for (final unit in label.codeUnits) {
    seed = (seed * 31 + unit) & 0x7fffffff;
  }
  const light = [
    0xFF2F7D68,
    0xFF3B6EA5,
    0xFF9A5B2C,
    0xFF8A4E8F,
    0xFFB3543F,
    0xFF4F7A3A,
  ];
  const darkTones = [
    0xFF6FC3A6,
    0xFF7FB2E3,
    0xFFD8A062,
    0xFFC58CC9,
    0xFFE08A72,
    0xFF9CC47F,
  ];
  final palette = dark ? darkTones : light;
  return palette[seed % palette.length];
}

/// 拖动中携带的负载。
///
/// [sourceNoteKey] 为空表示从顶部「全部类型」一行拖出来的（复制语义）；
/// 有值表示从某条笔记上拖下来的（移动/删除语义）。
@immutable
class NoteTagDrag {
  const NoteTagDrag({
    required this.label,
    required this.colorValue,
    required this.kind,
    this.sourceNoteKey,
  });

  final String label;
  final int colorValue;
  final NoteTagKind kind;
  final String? sourceNoteKey;

  bool get fromPalette => sourceNoteKey == null;

  String get id => '${kind.name}|$label|${sourceNoteKey ?? 'palette'}';
}

/// 顶部「全部类型」里的一枚可拖动标签。
///
/// 轻点 = 筛选 / 再点一次取消（由 [onTap] 处理）；长按 = 拿起，反馈层
/// 弹性放大 12%。拿起后原位留一个等大的空位，由页面负责「挤开」式排序；
/// 松手后按 [rebornToken] 弹性重生（0.55 → 1，elasticOut）。
class PaletteTagChip extends StatefulWidget {
  const PaletteTagChip({
    super.key,
    required this.label,
    required this.colorValue,
    required this.kind,
    required this.selected,
    required this.onTap,
    this.onDragStarted,
    this.onDragUpdate,
    this.onDragFinished,
    this.rebornToken = 0,
  });

  final String label;
  final int colorValue;
  final NoteTagKind kind;
  final bool selected;
  final VoidCallback onTap;

  /// 拿起时把标签尺寸交给页面，页面据此在排序时让出等宽的空位。
  final void Function(NoteTagDrag data, Size size)? onDragStarted;

  /// 拖动中的全局坐标，页面用它判断插入位置。
  final void Function(Offset globalPosition)? onDragUpdate;

  /// 松手后通知页面收尾（排序落位 / 清磁力虚影）。
  final VoidCallback? onDragFinished;

  /// 每次从拖动里回来 +1，触发一次弹性重生。
  final int rebornToken;

  @override
  State<PaletteTagChip> createState() => _PaletteTagChipState();
}

class _PaletteTagChipState extends State<PaletteTagChip> {
  bool _dragging = false;

  NoteTagDrag get _data => NoteTagDrag(
    label: widget.label,
    colorValue: widget.colorValue,
    kind: widget.kind,
  );

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return LongPressDraggable<NoteTagDrag>(
      data: _data,
      feedback: _feedback(),
      childWhenDragging: _hole(palette),
      onDragStarted: () {
        setState(() => _dragging = true);
        widget.onDragStarted?.call(_data, context.size ?? Size.zero);
      },
      onDragUpdate: (details) =>
          widget.onDragUpdate?.call(details.globalPosition),
      onDragEnd: (_) {
        setState(() => _dragging = false);
        widget.onDragFinished?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: TweenAnimationBuilder<double>(
              key: ValueKey(
                'palette-tag-reborn-${widget.label}-${widget.rebornToken}',
              ),
              tween: Tween(begin: widget.rebornToken == 0 ? 1 : 0.55, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: Curves.elasticOut,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? palette.chipSelectedFill
                      : palette.chipFill,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: widget.selected ? palette.accentText : palette.line,
                    width: 1,
                  ),
                ),
                child: _chipBody(
                  palette,
                  selected: widget.selected,
                  showHandle: _dragging,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chipBody(
    HomePalette palette, {
    required bool selected,
    required bool showHandle,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (widget.kind == NoteTagKind.tag)
        Icon(Icons.tag, size: 12, color: Color(widget.colorValue))
      else
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Color(widget.colorValue),
            shape: BoxShape.circle,
          ),
        ),
      SizedBox(width: widget.kind == NoteTagKind.tag ? 3 : 6),
      Text(
        widget.label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: selected
              ? palette.accentText
              : (widget.kind == NoteTagKind.tag
                    ? Color(widget.colorValue)
                    : palette.muted),
        ),
      ),
      if (showHandle) ...[
        const SizedBox(width: 4),
        Icon(Icons.drag_indicator, size: 12, color: palette.muted),
      ],
    ],
  );

  /// 拿起后的悬浮副本：先放大 1.12 再轻微回弹，提示「可以拖」。
  Widget _feedback() {
    final palette = HomePalette.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 1.12),
      duration: const Duration(milliseconds: 200),
      curve: Curves.elasticOut,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: HomePalette.accent, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: _chipBody(palette, selected: true, showHandle: true),
        ),
      ),
    );
  }

  /// 原位置的空位：保留同样尺寸，避免周围的标签跳动。
  Widget _hole(HomePalette palette) => SizedBox(
    height: 48,
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: palette.soft.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.line, width: 1),
        ),
        child: Opacity(
          opacity: 0,
          child: _chipBody(palette, selected: false, showHandle: false),
        ),
      ),
    ),
  );
}

/// 笔记卡片上的一枚角标：长按可拖走（换另一条笔记或直接取消）。
class NoteBadgeChip extends StatelessWidget {
  const NoteBadgeChip({
    super.key,
    required this.label,
    required this.colorValue,
    required this.noteKey,
    this.sourceKind = NoteTagKind.marker,
    this.onDragEnd,
    this.highlighted = false,
  });

  final String label;
  final int colorValue;
  final String noteKey;
  final NoteTagKind sourceKind;

  /// 拖动中的标签正落在这枚角标上（含拖回自己这张卡片）：
  /// 用一圈描边 + 轻微放大给出吸附反馈，且不改变布局尺寸。
  final bool highlighted;

  /// 松手回调：`accepted == false` 表示没落在任何笔记上，调用方据此删标签。
  final void Function(bool accepted)? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final isMarker = sourceKind == NoteTagKind.marker;
    final chip = Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: isMarker ? 20 : 22,
      padding: EdgeInsets.symmetric(horizontal: isMarker ? 5 : 7),
      // 不设 alignment：否则 Container 会撑满 Wrap 给的可用宽度，
      // 小角标变成整行长条。
      decoration: BoxDecoration(
        color: isMarker
            ? Color(colorValue)
            : Color(colorValue).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(isMarker ? 5 : 11),
        border: isMarker
            ? null
            : Border.all(color: Color(colorValue).withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMarker) ...[
            Icon(Icons.tag, size: 10, color: Color(colorValue)),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(
              color: isMarker ? Colors.white : Color(colorValue),
              fontSize: isMarker ? 10 : 10.5,
              height: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    // 吸附环画在 Stack 的定位层里，不参与布局：角标尺寸不变，
    // 所以拖动时 Wrap 不会重新折行、其他标签也不会上下跳。
    Widget withHalo(Widget child) => Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          left: -3,
          top: -3,
          right: -3,
          bottom: -3,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: HomePalette.accent, width: 1.4),
                boxShadow: [
                  BoxShadow(
                    color: HomePalette.accent.withValues(alpha: 0.25),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final body = AnimatedScale(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      scale: highlighted ? 1.08 : 1,
      child: highlighted ? withHalo(chip) : chip,
    );
    // 拖动中本体被隐藏；拖回自己这张卡片时，原位留半透明角标提示松手
    // 落点，但不再画绿色吸附环（用户反馈残影感）。空位保持等大，
    // Wrap 不重折行。
    final placeholder = highlighted
        ? Opacity(opacity: 0.5, child: chip)
        : Opacity(opacity: 0, child: chip);
    return LongPressDraggable<NoteTagDrag>(
      data: NoteTagDrag(
        label: label,
        colorValue: colorValue,
        kind: sourceKind,
        sourceNoteKey: noteKey,
      ),
      feedback: Transform.scale(
        scale: 1.18,
        child: Material(color: Colors.transparent, child: chip),
      ),
      // 空位必须和原角标一样大：换成别的占位符会让 Wrap 重新折行，
      // 周围的标签就会上下跳。
      childWhenDragging: placeholder,
      onDragEnd: (details) => onDragEnd?.call(details.wasAccepted),
      child: body,
    );
  }
}

/// 磁力落点提示：拖到卡片上方时出现的虚影角标。
class NoteTagGhost extends StatelessWidget {
  const NoteTagGhost({
    super.key,
    required this.label,
    required this.colorValue,
    required this.kind,
  });

  final String label;
  final int colorValue;
  final NoteTagKind kind;

  @override
  Widget build(BuildContext context) {
    final isMarker = kind == NoteTagKind.marker;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.8, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        height: isMarker ? 20 : 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: Color(colorValue).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(isMarker ? 5 : 11),
          border: Border.all(
            color: Color(colorValue).withValues(alpha: 0.75),
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 10, color: Color(colorValue)),
            const SizedBox(width: 2),
            Text(
              label,
              style: TextStyle(
                color: Color(colorValue),
                fontSize: isMarker ? 10 : 10.5,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
