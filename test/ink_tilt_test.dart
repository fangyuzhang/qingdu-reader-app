import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/widgets/reader/annotation/ink_strokes_painter.dart';

/// 【轻读·阶段三兼容方案】M-Pencil 3 侧锋与宽度映射：
/// - InkPoint.tilt 归一化 0~1，旧存档无字段 → 0（行为不变）；
/// - pointWidth：压感定基础宽，倾斜侧锋最多加粗 60%；手指两值恒定不受影响。
void main() {
  group('InkPoint.tilt 序列化', () {
    test('有侧锋时往返保留，tilt=0 不写字段（旧存档体积不变）', () {
      const point = InkPoint(x: 0.2, y: 0.3, pressure: 0.7, t: 9, tilt: 0.45);
      final map = point.toMap();
      expect(map['tl'], 0.45);
      final back = InkPoint.fromMap(map)!;
      expect(back.tilt, 0.45);
      expect(back, point);

      const flat = InkPoint(x: 0.1, y: 0.1, pressure: 0.5, t: 1);
      expect(flat.toMap().containsKey('tl'), isFalse);
      // 旧存档（无 tl）读取 → tilt 0。
      final legacy = InkPoint.fromMap(const {
        'x': 0.1,
        'y': 0.2,
        'p': 0.5,
        't': 3,
      })!;
      expect(legacy.tilt, 0);
      expect(legacy, const InkPoint(x: 0.1, y: 0.2, pressure: 0.5, t: 3));
    });
  });

  group('pointWidth 压感×倾斜矩阵', () {
    test('手指恒定路径不变：tilt 0 时与旧公式一致', () {
      for (final p in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(
          InkStrokesPainter.pointWidth(10, p, 0),
          10 * (0.35 + 0.65 * p),
        );
      }
    });

    test('侧锋放平最多加粗 60%，且同倾斜下压感越大越粗', () {
      final vertical = InkStrokesPainter.pointWidth(10, 0.5, 0);
      final flat = InkStrokesPainter.pointWidth(10, 0.5, 1);
      expect(flat, closeTo(vertical * 1.6, 1e-9));
      // 单调：倾斜增大 → 变粗；压感增大 → 变粗。
      var prev = 0.0;
      for (final tl in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final w = InkStrokesPainter.pointWidth(10, 0.6, tl);
        expect(w, greaterThan(prev));
        prev = w;
      }
      prev = 0;
      for (final p in [0.1, 0.4, 0.7, 1.0]) {
        final w = InkStrokesPainter.pointWidth(10, p, 0.3);
        expect(w, greaterThan(prev));
        prev = w;
      }
    });

    test('极小压感仍有最小线宽兜底', () {
      expect(InkStrokesPainter.pointWidth(1, 0, 0), greaterThanOrEqualTo(0.6));
    });
  });
}
