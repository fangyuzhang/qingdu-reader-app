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
/// 交互：
/// * 轻点 = 筛选 / 再点一次取消（由 [onTap] 处理）；
/// * 长按 = 拿起，反馈层弹性放大 12%；
/// * 拿起后原位置留一个虚线空位（[childWhenDragging]）；
/// * 松手后原位弹性重生（0.55 → 1，elasticOut）；
/// * 拖到另一枚标签上 = 调整顺序（[onReorder]）。
class PaletteTagChip extends StatefulWidget {
  const PaletteTagChip({
    super.key,
    required this.label,
    required this.colorValue,
    required this.kind,
    required this.selected,
    required this.onTap,
    required this.onReorder,
    this.onDragFinished,
  });

  final String label;
  final int colorValue;
  final NoteTagKind kind;
  final bool selected;
  final VoidCallback onTap;

  /// 把 [dragged] 放到当前标签后面（类型与自由标签共用一条顺序）。
  final void Function(NoteTagDrag dragged, NoteTagDrag target) onReorder;

  /// 松手后通知页面清掉磁力虚影，避免悬停态残留。
  final VoidCallback? onDragFinished;

  @override
  State<PaletteTagChip> createState() => _PaletteTagChipState();
}

class _PaletteTagChipState extends State<PaletteTagChip> {
  bool _dragging = false;
  int _reborn = 0;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return DragTarget<NoteTagDrag>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        // 类型与自由标签共用一条顺序，允许跨类型拖动（如把「1万」
        // 拖到「反驳」后面），只排除拖回自己。
        return data.fromPalette && data.label != widget.label;
      },
      onAcceptWithDetails: (details) => widget.onReorder(
        details.data,
        NoteTagDrag(
          label: widget.label,
          colorValue: widget.colorValue,
          kind: widget.kind,
        ),
      ),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return LongPressDraggable<NoteTagDrag>(
          data: NoteTagDrag(
            label: widget.label,
            colorValue: widget.colorValue,
            kind: widget.kind,
          ),
          feedback: _feedback(),
          childWhenDragging: _hole(palette),
          onDragStarted: () => setState(() => _dragging = true),
          onDragEnd: (_) {
            setState(() {
              _dragging = false;
              _reborn++;
            });
            widget.onDragFinished?.call();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox(
              height: 48,
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey('palette-tag-reborn-${widget.label}-$_reborn'),
                  tween: Tween(begin: _reborn == 0 ? 1 : 0.55, end: 1),
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
                        color: hovering
                            ? HomePalette.accent
                            : (widget.selected
                                  ? palette.accentText
                                  : palette.line),
                        width: hovering ? 1.4 : 1,
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
      },
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
  });

  final String label;
  final int colorValue;
  final String noteKey;
  final NoteTagKind sourceKind;

  /// 松手回调：`accepted == false` 表示没落在任何笔记上，调用方据此删标签。
  final void Function(bool accepted)? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
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
      childWhenDragging: _BadgeHole(palette: palette, isMarker: isMarker),
      onDragEnd: (details) => onDragEnd?.call(details.wasAccepted),
      child: chip,
    );
  }
}

class _BadgeHole extends StatelessWidget {
  const _BadgeHole({required this.palette, required this.isMarker});

  final HomePalette palette;
  final bool isMarker;

  @override
  Widget build(BuildContext context) => Container(
    height: isMarker ? 20 : 22,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: palette.soft.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(isMarker ? 5 : 11),
      border: Border.all(color: palette.line),
    ),
  );
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
