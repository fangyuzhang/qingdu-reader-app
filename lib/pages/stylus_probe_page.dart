// ─────────────────────────────────────────────────────────────────────────
// 手写笔输入能力探测页（调试工具，发布前整体删除）
//
// 用途：在真机上实测手写笔的 PointerEvent 能力，为「手写墨迹批注」
// （AnnotationCanvas）确定压感映射参数。全部调试代码集中在本文件，
// 入口挂在设置页「服务」分类（kDebugMode 守卫，release 不可见）。
//
// 【实测结论】（2026-10-25，验证包 --dart-define=fqapp.debugTools=true）
// - Redmi K20 Pro（MIUI Android 11，无手写笔，手指触摸）：kind 恒为 touch；
//   pressure 恒为 1.000（min=max=avg=1.000，62 采样点）；tilt / orientation
//   恒为 0.000；localPosition 正常跟随。→ 手指划线会恒为最粗线宽，
//   批注画布的压感映射只在 kind==stylus 时有意义。
// - 华为 MatePad 11 (2021) + M-Pencil 3：【待设备到位后实测】预期
//   kind == stylus、pressure ∈ (0,1] 随笔压变化、tilt 随倾斜角变化。
// ─────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/home/home_design.dart';

/// 一个采样点：位置 + 原始压感/倾斜/方位角。
class _Sample {
  const _Sample(this.position, this.pressure, this.tilt, this.orientation);

  final Offset position;
  final double pressure;
  final double tilt;
  final double orientation;
}

class StylusProbePage extends StatefulWidget {
  const StylusProbePage({super.key});

  @override
  State<StylusProbePage> createState() => _StylusProbePageState();
}

class _StylusProbePageState extends State<StylusProbePage> {
  /// 进行中的笔迹（pointer → 采样序列）与已完成笔迹。
  final Map<int, List<_Sample>> _active = {};
  final List<List<_Sample>> _finished = [];

  PointerEvent? _last;
  int _count = 0;
  double _minPressure = double.infinity;
  double _maxPressure = 0;
  double _pressureSum = 0;
  final Map<String, int> _kindCounts = {};

  void _on(PointerEvent e) {
    setState(() {
      _last = e;
      _count++;
      _pressureSum += e.pressure;
      _minPressure = math.min(_minPressure, e.pressure);
      _maxPressure = math.max(_maxPressure, e.pressure);
      _kindCounts[e.kind.name] = (_kindCounts[e.kind.name] ?? 0) + 1;
      if (e is PointerDownEvent) {
        _active[e.pointer] = [_sampleOf(e)];
      } else if (e is PointerMoveEvent) {
        _active[e.pointer]?.add(_sampleOf(e));
      } else if (e is PointerUpEvent || e is PointerCancelEvent) {
        final stroke = _active.remove(e.pointer);
        if (stroke != null && stroke.length > 1) _finished.add(stroke);
      }
    });
  }

  _Sample _sampleOf(PointerEvent e) =>
      _Sample(e.localPosition, e.pressure, e.tilt, e.orientation);

  void _reset() {
    setState(() {
      _active.clear();
      _finished.clear();
      _last = null;
      _count = 0;
      _minPressure = double.infinity;
      _maxPressure = 0;
      _pressureSum = 0;
      _kindCounts.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('手写笔探测（调试）')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _readoutCard(palette),
          const SizedBox(height: 8),
          Expanded(
            child: Listener(
              key: const Key('probe-canvas'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: _on,
              onPointerMove: _on,
              onPointerUp: _on,
              onPointerCancel: _on,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _ProbePainter(
                    active: _active.values.toList(),
                    finished: _finished,
                    color: HomePalette.accent,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '在上方区域书写；手指与笔的事件都会被记录，用于对比 kind 字段。',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ),
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清空'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _readoutCard(HomePalette palette) {
    final e = _last;
    final avg = _count == 0 ? 0.0 : _pressureSum / _count;
    String fmt(double v) => v.toStringAsFixed(3);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          fontSize: 12.5,
          height: 1.55,
          color: palette.ink,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv(palette, 'kind', e?.kind.name ?? '—'),
            _kv(palette, 'pressure', e == null ? '—' : fmt(e.pressure)),
            _kv(palette, 'tilt / orientation', e == null
                ? '—'
                : '${fmt(e.tilt)} / ${fmt(e.orientation)}'),
            _kv(
              palette,
              'localPosition',
              e == null ? '—' : '(${e.localPosition.dx.round()}, '
                  '${e.localPosition.dy.round()})',
            ),
            const Divider(height: 14),
            _kv(palette, '采样点', '$_count', valueKey: const Key('probe-count')),
            _kv(
              palette,
              'pressure min / max / avg',
              _count == 0
                  ? '—'
                  : '${fmt(_minPressure)} / ${fmt(_maxPressure)} / ${fmt(avg)}',
            ),
            _kv(
              palette,
              '设备类型分布',
              _kindCounts.isEmpty
                  ? '—'
                  : _kindCounts.entries
                        .map((k) => '${k.key}×${k.value}')
                        .join('  '),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(HomePalette palette, String label, String value, {Key? valueKey}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(label, style: TextStyle(color: palette.muted)),
            ),
            Expanded(
              child: Text(
                value,
                key: valueKey,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}

/// 笔迹绘制：线宽 = 基准宽 × pressure（线性映射，不做平滑——基线测试目的）。
class _ProbePainter extends CustomPainter {
  const _ProbePainter({
    required this.active,
    required this.finished,
    required this.color,
  });

  static const _baseStrokeWidth = 9.0;

  final List<List<_Sample>> active;
  final List<List<_Sample>> finished;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in finished) {
      _drawStroke(canvas, stroke, paint);
    }
    for (final stroke in active) {
      _drawStroke(canvas, stroke, paint);
    }
  }

  void _drawStroke(Canvas canvas, List<_Sample> stroke, Paint paint) {
    for (var i = 1; i < stroke.length; i++) {
      final a = stroke[i - 1];
      final b = stroke[i];
      paint.strokeWidth =
          math.max(0.5, _baseStrokeWidth * ((a.pressure + b.pressure) / 2));
      canvas.drawLine(a.position, b.position, paint);
    }
  }

  @override
  bool shouldRepaint(_ProbePainter old) => true;
}
