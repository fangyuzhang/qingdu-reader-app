import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../models/ink_annotation.dart';
import 'ink_controller.dart';
import 'ink_strokes_painter.dart';

/// 透明墨迹画布（第 5 组 AnnotationCanvas）。
///
/// 事件策略：只消费 stylus（笔）；手指事件**不拦截**——Listener 只观察
/// 不参与手势竞技场，手指继续驱动下层的翻页/滚动（spec：手指穿透）。
/// 调试构建可经 [InkController.acceptFinger] 放开手指绘制（K20 Pro 验证
/// 用，正式版恒 false）。
///
/// 画布与内容层严格解耦：不持有 PDF/排版组件，只输出归一化墨迹。
class InkCanvas extends StatefulWidget {
  const InkCanvas({super.key, required this.controller});

  final InkController controller;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

class _InkCanvasState extends State<InkCanvas> {
  final ValueNotifier<List<(Offset, double)>?> _live =
      ValueNotifier<List<(Offset, double)>?>(null);
  int? _activePointer;

  bool _accepts(PointerEvent e) => switch (e.kind) {
    PointerDeviceKind.stylus => true,
    PointerDeviceKind.touch => widget.controller.acceptFinger,
    _ => false,
  };

  void _onDown(PointerDownEvent e) {
    if (!_accepts(e)) return;
    _activePointer = e.pointer;
    if (widget.controller.tool == InkTool.pen) {
      _live.value = [(e.localPosition, e.pressure)];
    } else {
      _eraseAt(e.localPosition);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    if (widget.controller.tool == InkTool.pen) {
      final points = _live.value;
      if (points == null) return;
      // 采样降频：< 1.5px 的抖动点丢弃（三点内保留，保证起笔形状）。
      if (points.length >= 3 &&
          (e.localPosition - points.last.$1).distance < 1.5) {
        return;
      }
      _live.value = [...points, (e.localPosition, e.pressure)];
    } else {
      _eraseAt(e.localPosition);
    }
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    final points = _live.value;
    _live.value = null;
    if (widget.controller.tool != InkTool.pen) return;
    if (points == null || points.isEmpty) return;
    final size = context.size;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    final stroke = InkStroke(
      baseWidth: widget.controller.baseWidth,
      colorValue: widget.controller.colorValue,
      points: List.unmodifiable([
        for (final (offset, pressure) in points)
          InkPoint(
            x: (offset.dx / size.width).clamp(0, 1),
            y: (offset.dy / size.height).clamp(0, 1),
            pressure: pressure,
            t: 0,
          ),
      ]),
    );
    widget.controller.addStroke(stroke);
  }

  /// 橡皮命中：点到任一笔段的距离 < 笔半径 + 10px 即擦除该笔。
  void _eraseAt(Offset local) {
    final size = context.size;
    if (size == null) return;
    final controller = widget.controller;
    for (var i = controller.strokes.length - 1; i >= 0; i--) {
      final stroke = controller.strokes[i];
      final radius =
          InkStrokesPainter.widthPx(stroke.baseWidth, size.width) / 2 + 10;
      for (var j = 1; j < stroke.points.length; j++) {
        final a = Offset(
          stroke.points[j - 1].x * size.width,
          stroke.points[j - 1].y * size.height,
        );
        final b = Offset(
          stroke.points[j].x * size.width,
          stroke.points[j].y * size.height,
        );
        if (_distanceToSegment(local, a, b) <= radius) {
          controller.removeStroke(i);
          return;
        }
      }
      // 单点笔迹（点一下）无段落可测，用点距。
      if (stroke.points.length == 1) {
        final a = Offset(
          stroke.points[0].x * size.width,
          stroke.points[0].y * size.height,
        );
        if ((local - a).distance <= radius) {
          controller.removeStroke(i);
        }
      }
    }
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSq == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSq)
        .clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Listener(
          key: const Key('ink-canvas'),
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onUp,
          child: RepaintBoundary(
            child: ValueListenableBuilder(
              valueListenable: _live,
              builder: (context, live, _) => CustomPaint(
                foregroundPainter: InkStrokesPainter(
                  strokes: widget.controller.strokes,
                  canvasWidth: width,
                  livePoints: live,
                  liveColorValue: widget.controller.colorValue,
                  liveBaseWidth: widget.controller.baseWidth,
                  repaint: Listenable.merge([widget.controller, _live]),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }
}
