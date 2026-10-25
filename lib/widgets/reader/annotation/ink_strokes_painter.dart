import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../models/ink_annotation.dart';

/// 墨迹渲染器：二次贝塞尔平滑（中点法）+ 压感线宽。
///
/// 笔宽基准：InkStroke.baseWidth 以「页宽 1000」为基准的逻辑像素，
/// 渲染时 × 当前画布宽 / 1000，缩放页面时笔画粗细同步缩放。
/// 压感映射：width = base × (0.35 + 0.65 × pressure)——手指 pressure 恒
/// 1.0（见 stylus_probe_page.dart 实测），映射只对 stylus 有意义。
///
/// 套索编辑态：选中笔迹画虚线外框（selectionBounds），拖圈过程中画
/// 半透明套索路径（lassoPath，均为归一化坐标）。
class InkStrokesPainter extends CustomPainter {
  InkStrokesPainter({
    required this.strokes,
    required this.canvasWidth,
    this.livePoints,
    this.liveColorValue = InkAnnotation.defaultColorValue,
    this.liveBaseWidth = 4,
    this.selectedIndices = const <int>{},
    this.selectionBounds,
    this.lassoPath = const <Offset>[],
    this.selectionColor = const Color(InkAnnotation.defaultColorValue),
    this.repaint,
  }) : super(repaint: repaint);

  /// 已提交的墨迹（归一化坐标）。
  final List<InkStroke> strokes;

  /// 当前画布宽（像素），笔宽缩放基准。
  final double canvasWidth;

  /// 进行中一笔的原始点（画布局部像素坐标 + 压感 + 归一化倾斜），可空。
  final List<(Offset, double, double)>? livePoints;
  final int liveColorValue;
  final double liveBaseWidth;

  /// 套索选中的笔迹下标 + 整体包围盒（归一化）。
  final Set<int> selectedIndices;
  final Rect? selectionBounds;

  /// 拖圈中的套索路径（归一化；空列表 = 未在拖圈）。
  final List<Offset> lassoPath;

  /// 选中高亮色（虚线框 / 套索路径）。
  final Color selectionColor;

  final Listenable? repaint;

  /// 页宽基准：baseWidth 的标尺。
  static const widthBasis = 1000.0;

  static double widthPx(double baseWidth, double canvasWidth) =>
      baseWidth * canvasWidth / widthBasis;

  /// 单点线宽：压感决定基础宽度（0.35 + 0.65×p），倾斜在侧锋放平时
  /// 最多加粗 60%（M-Pencil 3 铅笔侧锋感；手指 tilt 恒 0 不受影响）。
  static double pointWidth(double basePx, double pressure, double tilt) {
    final p = pressure.clamp(0.0, 1.0);
    final tl = tilt.clamp(0.0, 1.0);
    return math.max(0.6, basePx * (0.35 + 0.65 * p) * (1 + 0.6 * tl));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(
        canvas,
        [
          for (final p in stroke.points)
            (
              Offset(p.x * size.width, p.y * size.height),
              p.pressure,
              p.tilt,
            ),
        ],
        Color(stroke.colorValue),
        widthPx(stroke.baseWidth, canvasWidth),
      );
    }
    final live = livePoints;
    if (live != null && live.isNotEmpty) {
      _paintStroke(
        canvas,
        live,
        Color(liveColorValue),
        widthPx(liveBaseWidth, canvasWidth),
      );
      // 【青茄·阶段三兼容方案】预测笔尖：鸿蒙 Android 兼容层不提供系统级
      // 报点预测（Pencil Engine 仅对华为系 HAP 开放），用最近两点速度外
      // 推一小段（≤10dp）缓解感知延迟。只影响书写中的视觉反馈，抬手提交
      // 的数据不含预测点，笔迹最终形状不变。
      _paintPredictedTip(canvas, live, Color(liveColorValue), widthPx(liveBaseWidth, canvasWidth));
    }
    _paintSelection(canvas, size);
    _paintLasso(canvas, size);
  }

  /// 选中笔迹整体虚线外框（Kindle Scribe 式选中态）。
  void _paintSelection(Canvas canvas, Size size) {
    final bounds = selectionBounds;
    if (bounds == null || selectedIndices.isEmpty) return;
    final rect = Rect.fromLTRB(
      bounds.left * size.width,
      bounds.top * size.height,
      bounds.right * size.width,
      bounds.bottom * size.height,
    ).inflate(6);
    final path = Path()..addRect(rect);
    canvas.drawPath(
      _dashed(path, dash: 6, gap: 4),
      Paint()
        ..color = selectionColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// 拖圈中的半透明套索路径（填充 + 虚线描边）。
  void _paintLasso(Canvas canvas, Size size) {
    if (lassoPath.length < 2) return;
    final path = Path()
      ..moveTo(lassoPath.first.dx * size.width, lassoPath.first.dy * size.height);
    for (var i = 1; i < lassoPath.length; i++) {
      path.lineTo(lassoPath[i].dx * size.width, lassoPath[i].dy * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = selectionColor.withValues(alpha: 0.08),
    );
    canvas.drawPath(
      _dashed(path, dash: 5, gap: 3),
      Paint()
        ..color = selectionColor.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// 沿 [source] 的路径度量截出虚线段。
  static Path _dashed(Path source, {required double dash, required double gap}) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = math.min(dist + dash, metric.length);
        out.addPath(metric.extractPath(dist, next), Offset.zero);
        dist = next + gap;
      }
    }
    return out;
  }

  void _paintStroke(
    Canvas canvas,
    List<(Offset, double, double)> points,
    Color color,
    double basePx,
  ) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (points.length == 1) {
      final (pos, p, tl) = points.single;
      final radius = pointWidth(basePx, p, tl) / 2;
      final dot = Paint()..color = color;
      canvas.drawCircle(pos, radius, dot);
      return;
    }
    // 中点二次贝塞尔：p_{i-1}→p_i 的中点为端点、p_i 为控制点，逐段变线宽。
    for (var i = 1; i < points.length; i++) {
      final (a, ap, atl) = points[i - 1];
      final (b, bp, btl) = points[i];
      final start = i == 1 ? a : (a + b) / 2;
      final ctrl = a;
      final end = i == points.length - 1 ? b : (a + b) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, end.dx, end.dy);
      paint.strokeWidth = pointWidth(basePx, (ap + bp) / 2, (atl + btl) / 2);
      canvas.drawPath(path, paint);
    }
  }

  /// 预测笔尖：最近两点的位移按 1 个采样间隔外推（限幅 10dp），以末端
  /// 线宽画一段直线。慢速书写时位移小、几乎不可见；快速书写时补上
  /// 输入事件间隔里的「追手」空隙。
  void _paintPredictedTip(
    Canvas canvas,
    List<(Offset, double, double)> live,
    Color color,
    double basePx,
  ) {
    if (live.length < 3) return;
    final (a, _, _) = live[live.length - 2];
    final (b, bp, btl) = live.last;
    final delta = b - a;
    final distance = delta.distance;
    if (distance < 0.5) return;
    final lead = math.min(distance, 10.0);
    final tip = b + Offset.fromDirection(delta.direction, lead);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = pointWidth(basePx, bp, btl);
    canvas.drawLine(b, tip, paint);
  }

  @override
  bool shouldRepaint(InkStrokesPainter old) =>
      !identical(old.strokes, strokes) ||
      old.canvasWidth != canvasWidth ||
      !identical(old.livePoints, livePoints) ||
      old.liveColorValue != liveColorValue ||
      !setEquals(old.selectedIndices, selectedIndices) ||
      old.selectionBounds != selectionBounds ||
      !listEquals(old.lassoPath, lassoPath) ||
      old.selectionColor != selectionColor;
}
