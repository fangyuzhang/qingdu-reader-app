import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../models/ink_annotation.dart';
import '../reader_chapter_layout.dart';
import 'ink_controller.dart';
import 'ink_strokes_painter.dart';

/// 【青茄·Active Canvas】正文内嵌手写块的渲染层。
///
/// 三种形态（见 SCRIBE-NOTES-SPEC.md C1/C2/C4）：
/// - 草稿画布（[EmbeddedInkCanvas.isDraft]）：半透明虚线边框 + 右下角
///   「取消/确认」，书写越界自动向上级请求扩高（[onDraftGrow]）；
/// - 已确认画布：默认静默展示；轻点进入选中态（边框加亮 + 撤销/重做 +
///   底边高度手柄 + 右下角垃圾桶），拖手柄改高、点垃圾桶走二次确认；
/// - 折叠图标行（[InkBlockIconRow]）：便签/打字备注在正文里的折叠态，
///   一行小图标，点开由父级展开书写面板/编辑弹层。
///
/// 笔迹协议与整页墨迹一致：书写时块本地像素坐标，经 [onStrokesChanged]
/// 交给父级归一化落盘；undo/redo 由内部 [InkController 管，输出始终是
/// 当前盒子里的全量笔迹。
class EmbeddedInkCanvas extends StatefulWidget {
  const EmbeddedInkCanvas({
    super.key,
    required this.width,
    required this.height,
    required this.strokes,
    required this.isDraft,
    this.selected = false,
    this.onSelect,
    this.onStrokesChanged,
    this.onDraftGrow,
    this.onConfirmDraft,
    this.onCancelDraft,
    this.onResize,
    this.onResizeEnd,
    this.onRequestDelete,
  });

  /// 块盒子尺寸（逻辑像素）。宽度恒等于文本栏宽（D4）。
  final double width;
  final double height;
  final List<InkStroke> strokes;
  final bool isDraft;
  final bool selected;

  /// 已确认画布被轻点（进入/保持选中态）。
  final VoidCallback? onSelect;

  /// 每次笔迹全集变化（落笔提交/撤销/重做）回调，参数 = 当前盒子本地
  /// 坐标的全量笔迹；父级负责归一化与落盘。
  final ValueChanged<List<InkStroke>>? onStrokesChanged;

  /// 草稿书写越界：请求把画布扩高（父级按步进调整并重排）。
  final ValueChanged<double>? onDraftGrow;

  final VoidCallback? onConfirmDraft;
  final VoidCallback? onCancelDraft;

  /// 已确认画布拖动高度手柄（拖动中实时预览，父级跟随重排）。
  final ValueChanged<double>? onResize;

  /// 拖动结束（松手）——父级在此落盘定稿。
  final VoidCallback? onResizeEnd;

  /// 已确认画布点垃圾桶（父级弹二次确认后删除）。
  final VoidCallback? onRequestDelete;

  @override
  State<EmbeddedInkCanvas> createState() => _EmbeddedInkCanvasState();
}

class _EmbeddedInkCanvasState extends State<EmbeddedInkCanvas> {
  late InkController _controller;
  late ValueNotifier<int> _repaint;
  List<(Offset, double)>? _live;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _controller = InkController()..seed(widget.strokes);
    _repaint = ValueNotifier(0);
  }

  @override
  void didUpdateWidget(covariant EmbeddedInkCanvas old) {
    super.didUpdateWidget(old);
    if (!identical(old.strokes, widget.strokes) &&
        widget.strokes.length != _controller.strokes.length) {
      // 外部重载（存储变化/重缩放）与内部编辑对齐：以外部为准。
      _controller.seed(widget.strokes);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _emitChanged() =>
      widget.onStrokesChanged?.call(List.of(_controller.strokes));

  void _commitLive() {
    final live = _live;
    _live = null;
    if (live == null || live.length < 2) {
      _repaint.value++;
      return;
    }
    _controller.addStroke(
      InkStroke(
        points: [
          for (final (offset, pressure) in live)
            InkPoint(
              x: offset.dx,
              y: offset.dy,
              pressure: pressure <= 0 || pressure > 1
                  ? 0.5
                  : pressure.toDouble(),
              t: DateTime.now().millisecondsSinceEpoch,
            ),
        ],
        colorValue: InkAnnotation.defaultColorValue,
      ),
    );
    _emitChanged();
    if (widget.isDraft) _maybeGrow();
    _repaint.value++;
  }

  /// 草稿书写越界 → 请求扩高（父级按步进调整）。留 12% 下笔余量，
  /// 避免笔迹贴边时才扩。
  void _maybeGrow() {
    final grow = widget.onDraftGrow;
    if (grow == null) return;
    var maxY = 0.0;
    for (final stroke in _controller.strokes) {
      for (final p in stroke.points) {
        if (p.y > maxY) maxY = p.y;
      }
    }
    if (maxY > widget.height * 0.88) grow(widget.height + 48);
  }

  void _onPointerDown(PointerEvent event) {
    // 手写笔直接书写（不参与手势竞技场，滚动不被触发）。
    if (event.kind != PointerDeviceKind.stylus) return;
    _capturing = true;
    _live = [(event.localPosition, event.pressure)];
    _repaint.value++;
  }

  void _onPointerMove(PointerEvent event) {
    if (!_capturing || event.kind != PointerDeviceKind.stylus) return;
    _appendLive(event.localPosition, event.pressure);
  }

  void _onPointerUp(PointerEvent event) {
    if (!_capturing || event.kind != PointerDeviceKind.stylus) return;
    _capturing = false;
    _commitLive();
  }

  void _appendLive(Offset position, double pressure) {
    final live = _live ??= <(Offset, double)>[];
    if (live.isNotEmpty) {
      final last = live.last.$1;
      if ((position - last).distance < 1.2) return;
    }
    live.add((position, pressure));
    _repaint.value++;
  }

  // 手指路径：GestureDetector 的 pan 拿到手势竞技场后，滚动/翻页不再
  // 争夺这一区域，画布内手指 = 书写（Scribe 手机端口径）。
  void _onFingerPanStart(DragStartDetails details) {
    _capturing = true;
    _live = [(details.localPosition, 0.5)];
    _repaint.value++;
  }

  void _onFingerPanUpdate(DragUpdateDetails details) {
    if (!_capturing) return;
    _appendLive(details.localPosition, 0.5);
  }

  void _onFingerPanEnd(DragEndDetails details) {
    if (!_capturing) return;
    _capturing = false;
    _commitLive();
  }

  void _onFingerPanCancel() {
    if (!_capturing) return;
    _capturing = false;
    _live = null;
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final width = math.max(1.0, widget.width);
    final height = math.max(1.0, widget.height);
    final borderColor = widget.isDraft
        ? const Color(0x99D8A24A)
        : widget.selected
        ? const Color(0xFFD8A24A)
        : const Color(0x33C9B183);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.isDraft ? null : widget.onSelect,
      onPanStart: _onFingerPanStart,
      onPanUpdate: _onFingerPanUpdate,
      onPanEnd: _onFingerPanEnd,
      onPanCancel: _onFingerPanCancel,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFFFFDF6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: widget.isDraft || widget.selected ? 1.3 : 1,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: CustomPaint(
                    painter: InkStrokesPainter(
                      strokes: _controller.strokes,
                      canvasWidth: width,
                      livePoints: _live,
                      repaint: _repaint,
                    ),
                  ),
                ),
              ),
              if (widget.isDraft) ..._draftChrome(),
              if (!widget.isDraft && widget.selected) ..._selectedChrome(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _draftChrome() => [
    Positioned(
      right: 8,
      bottom: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CanvasButton(
            key: const ValueKey('ink-block-cancel'),
            icon: LucideIcons.x,
            label: '取消',
            onTap: widget.onCancelDraft,
          ),
          const SizedBox(width: 6),
          _CanvasButton(
            key: const ValueKey('ink-block-confirm'),
            icon: LucideIcons.check,
            label: '确认',
            filled: true,
            onTap: widget.onConfirmDraft,
          ),
        ],
      ),
    ),
  ];

  List<Widget> _selectedChrome() => [
    Positioned(
      right: 8,
      top: 6,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CanvasButton(
            key: const ValueKey('ink-block-undo'),
            icon: LucideIcons.undo_2,
            enabled: _controller.canUndo,
            onTap: () {
              _controller.undo();
              _emitChanged();
              _repaint.value++;
            },
          ),
          const SizedBox(width: 4),
          _CanvasButton(
            key: const ValueKey('ink-block-redo'),
            icon: LucideIcons.redo_2,
            enabled: _controller.canRedo,
            onTap: () {
              _controller.redo();
              _emitChanged();
              _repaint.value++;
            },
          ),
          const SizedBox(width: 4),
          _CanvasButton(
            key: const ValueKey('ink-block-trash'),
            icon: LucideIcons.trash,
            danger: true,
            onTap: widget.onRequestDelete,
          ),
        ],
      ),
    ),
    // 底边中央高度手柄：拖动改高（父级实时重排预览）。
    Positioned(
      left: 0,
      right: 0,
      bottom: -10,
      child: Center(
        child: GestureDetector(
          key: const ValueKey('ink-block-resize-handle'),
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) =>
              widget.onResize?.call(widget.height + details.delta.dy),
          onVerticalDragEnd: (_) => widget.onResizeEnd?.call(),
          child: Container(
            width: 64,
            height: 18,
            alignment: Alignment.center,
            child: Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFD8A24A),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    ),
  ];
}

/// 折叠图标行：便签 / 打字备注在正文里的折叠态（34dp 定高，几乎不占位）。
class InkBlockIconRow extends StatelessWidget {
  const InkBlockIconRow({
    super.key,
    required this.note,
    required this.width,
    required this.onTap,
    this.onLongPress,
  });

  final ReaderInlineNote note;
  final double width;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isSticky = note.inkKind == ReaderInlineNote.inkKindSticky;
    final label = isSticky ? '便签' : '备注';
    return SizedBox(
      width: width,
      height: 34,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0x66FBF3E2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x55EADFC8)),
            ),
            child: Row(
              children: [
                Icon(
                  isSticky ? LucideIcons.file_pen : LucideIcons.message_square,
                  size: 13,
                  color: const Color(0xFFB08A3E),
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(
                    inherit: false,
                    fontSize: 11,
                    height: 1.0,
                    color: Color(0xFFB08A3E),
                  ),
                ),
                if (note.inkFilled) ...[
                  const SizedBox(width: 5),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: Color(0xFFB08A3E),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CanvasButton extends StatelessWidget {
  const _CanvasButton({
    super.key,
    required this.icon,
    this.label,
    this.filled = false,
    this.danger = false,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String? label;
  final bool filled;
  final bool danger;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    final foreground = !enabled
        ? const Color(0x613B362C)
        : filled
        ? Colors.white
        : danger
        ? const Color(0xFFC25B4E)
        : const Color(0xFF3B362C);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: filled ? const Color(0xFF2FA98C) : const Color(0xFFF4EBD9),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: foreground),
                if (label != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      inherit: false,
                      fontSize: 11.5,
                      height: 1.0,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
