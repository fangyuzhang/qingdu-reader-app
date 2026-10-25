import 'package:flutter/gestures.dart';
import 'dart:math' as math;

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
/// 套索工具例外：手指和笔都可拖圈选（圈选优先于书写/滚动）。画布此时
/// 挂一个空回调的 pan GestureDetector 参与手势竞技场并赢得拖拽，套索
/// 拖动期间不触发下层滚动/翻页；几何仍由 Listener 原始指针事件驱动
/// （Listener 不经竞技场，事件恒达，onPan* 只负责占位抢手势）。
///
/// 画布与内容层严格解耦：不持有 PDF/排版组件，只输出归一化墨迹。
class InkCanvas extends StatefulWidget {
  const InkCanvas({super.key, required this.controller});

  final InkController controller;

  @override
  State<InkCanvas> createState() => _InkCanvasState();
}

/// 套索工具下的一次指针手势语义。
enum _LassoGesture {
  /// 非 lasso 工具（pen/eraser 原行为）。
  none,

  /// 拖圈选。
  lasso,

  /// 按在选中包围盒内拖动 → 移动选中笔迹。
  move,
}

class _InkCanvasState extends State<InkCanvas> {
  final ValueNotifier<List<(Offset, double, double)>?> _live =
      ValueNotifier<List<(Offset, double, double)>?>(null);
  int? _activePointer;
  _LassoGesture _gesture = _LassoGesture.none;
  Offset _lastMove = Offset.zero;

  /// stylus 恒收；touch/unknown 仅在调试手指通道放开时收。unknown 是
  /// adb `input` 注入事件的 kind（真机手指恒 touch、手写笔恒 stylus，
  /// 见 stylus_probe_page 实测），放开它只为自动化验证可驱动绘制。
  /// lasso 工具下手指也参与圈选（滚动优先让位于圈选）。
  bool _accepts(PointerEvent e) => switch (e.kind) {
    PointerDeviceKind.stylus => true,
    PointerDeviceKind.touch || PointerDeviceKind.unknown =>
      widget.controller.acceptFinger ||
          widget.controller.tool == InkTool.lasso,
    _ => false,
  };

  void _onDown(PointerDownEvent e) {
    if (!_accepts(e)) return;
    if (_activePointer != null) return; // 已有指针处理中（拖拽时忽略第二触点）
    _activePointer = e.pointer;
    final controller = widget.controller;
    if (controller.tool == InkTool.lasso) {
      final p = _normalize(e.localPosition);
      final bounds = controller.selectionBounds;
      if (bounds != null && _withinSelection(bounds, p)) {
        _gesture = _LassoGesture.move;
        _lastMove = p;
        controller.beginTransform();
      } else {
        _gesture = _LassoGesture.lasso;
        controller.beginLasso(p);
      }
      return;
    }
    if (widget.controller.tool == InkTool.pen) {
      _live.value = [(e.localPosition, e.pressure, _tiltOf(e))];
    } else {
      _eraseAt(e.localPosition);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final controller = widget.controller;
    switch (_gesture) {
      case _LassoGesture.lasso:
        controller.updateLasso(_normalize(e.localPosition));
        return;
      case _LassoGesture.move:
        final p = _normalize(e.localPosition);
        final delta = p - _lastMove;
        _lastMove = p;
        controller.moveSelected(delta);
        return;
      case _LassoGesture.none:
        break;
    }
    if (widget.controller.tool == InkTool.pen) {
      final points = _live.value;
      if (points == null) return;
      // 采样降频：< 1.5px 的抖动点丢弃（三点内保留，保证起笔形状）。
      if (points.length >= 3 &&
          (e.localPosition - points.last.$1).distance < 1.5) {
        return;
      }
      _live.value = [...points, (e.localPosition, e.pressure, _tiltOf(e))];
    } else {
      _eraseAt(e.localPosition);
    }
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    final controller = widget.controller;
    switch (_gesture) {
      case _LassoGesture.lasso:
        _gesture = _LassoGesture.none;
        controller.endLasso();
        return;
      case _LassoGesture.move:
        _gesture = _LassoGesture.none;
        controller.endTransform();
        return;
      case _LassoGesture.none:
        break;
    }
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
        for (final (offset, pressure, tilt) in points)
          InkPoint(
            x: (offset.dx / size.width).clamp(0, 1),
            y: (offset.dy / size.height).clamp(0, 1),
            pressure: pressure,
            t: 0,
            tilt: tilt,
          ),
      ]),
    );
    widget.controller.addStroke(stroke);
  }

  /// 手势被打断（系统抢走指针）：pen/eraser 维持既有语义（打断按抬手
  /// 结算）；套索丢弃路径不做命中判定；移动提交已发生的位移。
  void _onCancel(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    switch (_gesture) {
      case _LassoGesture.none:
        _onUp(e);
      case _LassoGesture.lasso:
        _activePointer = null;
        _gesture = _LassoGesture.none;
        widget.controller.cancelLasso();
      case _LassoGesture.move:
        _activePointer = null;
        _gesture = _LassoGesture.none;
        widget.controller.endTransform();
    }
  }

  /// 画布局部像素坐标 → 归一化页面坐标。
  /// 归一化倾斜 0~1（0=垂直，1=放平）。PointerEvent.tilt 为弧度 0..π/2，
  /// 手指恒 0；M-Pencil 3（鸿蒙 Android 兼容层）stylus 事件携带。
  static double _tiltOf(PointerEvent e) {
    final radians = e.tilt;
    if (!radians.isFinite || radians <= 0) return 0;
    return (radians / (math.pi / 2)).clamp(0.0, 1.0);
  }

  Offset _normalize(Offset local) {
    final size = context.size;
    if (size == null || size.width <= 0 || size.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  /// 起点落在选中包围盒（外扩 12px 命中容差）内 → 拖动移动选中笔迹。
  bool _withinSelection(Rect bounds, Offset p) {
    final size = context.size;
    if (size == null || size.width <= 0 || size.height <= 0) return false;
    final inflated = Rect.fromLTRB(
      bounds.left - 12 / size.width,
      bounds.top - 12 / size.height,
      bounds.right + 12 / size.width,
      bounds.bottom + 12 / size.height,
    );
    return inflated.contains(p);
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
        final lassoMode = widget.controller.tool == InkTool.lasso;
        return Listener(
          key: const Key('ink-canvas'),
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: RepaintBoundary(
            // 控制器变化（选中集/套索路径）经 AnimatedBuilder 重建 painter，
            // 否则 repaint 只重画旧字段值（painter 字段在 build 时定死）。
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => ValueListenableBuilder(
                valueListenable: _live,
                builder: (context, live, _) => CustomPaint(
                  foregroundPainter: InkStrokesPainter(
                    strokes: widget.controller.strokes,
                    canvasWidth: width,
                    livePoints: live,
                    liveColorValue: widget.controller.colorValue,
                    liveBaseWidth: widget.controller.baseWidth,
                    selectedIndices: widget.controller.selectedIndices,
                    selectionBounds: widget.controller.selectionBounds,
                    lassoPath: widget.controller.lassoPath,
                    // repaint 只挂稳定引用：live 的变化经上面的
                    // ValueListenableBuilder 重建 painter 生效。
                    repaint: widget.controller,
                  ),
                  // 套索模式下用空回调 pan 识别器参与竞技场并抢先赢得拖拽，
                  // 圈选/移动期间不触发下层滚动翻页；几何仍由 Listener 驱动。
                  child: lassoMode
                      ? GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanDown: (_) {},
                          onPanStart: (_) {},
                          onPanUpdate: (_) {},
                          onPanEnd: (_) {},
                          onPanCancel: () {},
                          child: const SizedBox.expand(),
                        )
                      : const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
