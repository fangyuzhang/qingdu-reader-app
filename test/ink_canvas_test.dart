import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/widgets/reader/annotation/ink_canvas.dart';
import 'package:fqapp/widgets/reader/annotation/ink_controller.dart';

/// 第 5 组：墨迹画布与控制器的手势/编辑语义（不依赖真机；压感真实值
/// 见 stylus_probe_page.dart 头注释实测结论）。
void main() {
  Future<void> pumpCanvas(
    WidgetTester tester,
    InkController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 600,
              child: InkCanvas(controller: controller),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('stylus 落笔画出一笔；touch 默认不画', (tester) async {
    final controller = InkController();
    await pumpCanvas(tester, controller);
    final center = tester.getCenter(find.byKey(const Key('ink-canvas')));

    final touch = await tester.startGesture(
      center,
      kind: PointerDeviceKind.touch,
    );
    await touch.moveBy(const Offset(50, 0));
    await touch.up();
    await tester.pump();
    expect(controller.strokes, isEmpty);

    final pen = await tester.startGesture(
      center,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(60, 0));
    await pen.moveBy(const Offset(0, 40));
    await pen.up();
    await tester.pump();

    expect(controller.strokes, hasLength(1));
    final stroke = controller.strokes.single;
    expect(stroke.points, hasLength(3));
    // 归一化坐标：400 宽的画布上 x 中心 200 → 0.5。
    expect(stroke.points.first.x, closeTo(0.5, 1e-6));
    expect(stroke.points.last.y, greaterThan(stroke.points.first.y));
  });

  testWidgets('调试开关放开后手指也可绘制', (tester) async {
    final controller = InkController()..acceptFinger = true;
    await pumpCanvas(tester, controller);
    final center = tester.getCenter(find.byKey(const Key('ink-canvas')));

    final touch = await tester.startGesture(
      center,
      kind: PointerDeviceKind.touch,
    );
    await touch.moveBy(const Offset(30, 30));
    await touch.up();
    await tester.pump();

    expect(controller.strokes, hasLength(1));
  });

  testWidgets('撤销/重做往返恢复原状；dirty 只在编辑后为真', (tester) async {
    final controller = InkController();
    controller.addStroke(
      const InkStroke(
        points: [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.2, y: 0.2)],
      ),
    );
    expect(controller.dirty, isTrue);
    expect(controller.strokes, hasLength(1));

    controller.undo();
    expect(controller.strokes, isEmpty);
    expect(controller.canRedo, isTrue);

    controller.redo();
    expect(controller.strokes, hasLength(1));
  });

  testWidgets('橡皮按命中距离擦除整笔', (tester) async {
    final controller = InkController()..acceptFinger = true;
    await pumpCanvas(tester, controller);
    final center = tester.getCenter(find.byKey(const Key('ink-canvas')));

    // 画一笔横线。
    final pen = await tester.startGesture(
      center,
      kind: PointerDeviceKind.touch,
    );
    await pen.moveBy(const Offset(120, 0));
    await pen.up();
    await tester.pump();
    expect(controller.strokes, hasLength(1));

    // 切橡皮，在线中段扫过。
    controller.tool = InkTool.eraser;
    final eraser = await tester.startGesture(
      center + const Offset(60, 0),
      kind: PointerDeviceKind.touch,
    );
    await eraser.moveBy(const Offset(0, 2));
    await eraser.up();
    await tester.pump();

    expect(controller.strokes, isEmpty);
    // 撤销能把这一笔找回来。
    controller.undo();
    expect(controller.strokes, hasLength(1));
  });

  test('seed 覆盖笔迹并清空撤销栈（同页重进批注模式）', () {
    final controller = InkController();
    controller.addStroke(
      const InkStroke(points: [InkPoint(x: 0.3, y: 0.3)]),
    );
    controller.seed(const []);
    expect(controller.strokes, isEmpty);
    expect(controller.canUndo, isFalse);
    expect(controller.dirty, isFalse);
  });
}
