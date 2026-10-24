import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/ink_annotation.dart';

/// 墨迹渲染器：二次贝塞尔平滑（中点法）+ 压感线宽。
///
/// 笔宽基准：InkStroke.baseWidth 以「页宽 1000」为基准的逻辑像素，
/// 渲染时 × 当前画布宽 / 1000，缩放页面时笔画粗细同步缩放。
/// 压感映射：width = base × (0.35 + 0.65 × pressure)——手指 pressure 恒
/// 1.0（见 stylus_probe_page.dart 实测），映射只对 stylus 有意义。
class InkStrokesPainter extends CustomPainter {
  InkStrokesPainter({
    required this.strokes,
    required this.canvasWidth,
    this.livePoints,
    this.liveColorValue = InkAnnotation.defaultColorValue,
    this.liveBaseWidth = 4,
    this.repaint,
  }) : super(repaint: repaint);

  /// 已提交的墨迹（归一化坐标）。
  final List<InkStroke> strokes;

  /// 当前画布宽（像素），笔宽缩放基准。
  final double canvasWidth;

  /// 进行中一笔的原始点（画布局部像素坐标 + 压感），可为 null。
  final List<(Offset, double)>? livePoints;
  final int liveColorValue;
  final double liveBaseWidth;
  final Listenable? repaint;

  /// 页宽基准：baseWidth 的标尺。
  static const widthBasis = 1000.0;

  static double widthPx(double baseWidth, double canvasWidth) =>
      baseWidth * canvasWidth / widthBasis;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(
        canvas,
        [
          for (final p in stroke.points)
            (Offset(p.x * size.width, p.y * size.height), p.pressure),
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
    }
  }

  void _paintStroke(
    Canvas canvas,
    List<(Offset, double)> points,
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
      final radius = _width(basePx, points.single.$2) / 2;
      final dot = Paint()..color = color;
      canvas.drawCircle(points.single.$1, radius, dot);
      return;
    }
    // 中点二次贝塞尔：p_{i-1}→p_i 的中点为端点、p_i 为控制点，逐段变线宽。
    for (var i = 1; i < points.length; i++) {
      final (a, ap) = points[i - 1];
      final (b, bp) = points[i];
      final start = i == 1 ? a : (a + b) / 2;
      final ctrl = a;
      final end = i == points.length - 1 ? b : (a + b) / 2;
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, end.dx, end.dy);
      paint.strokeWidth = _width(basePx, (ap + bp) / 2);
      canvas.drawPath(path, paint);
    }
  }

  double _width(double basePx, double pressure) =>
      math.max(0.6, basePx * (0.35 + 0.65 * pressure.clamp(0, 1)));

  @override
  bool shouldRepaint(InkStrokesPainter old) =>
      !identical(old.strokes, strokes) ||
      old.canvasWidth != canvasWidth ||
      !identical(old.livePoints, livePoints) ||
      old.liveColorValue != liveColorValue;
}
