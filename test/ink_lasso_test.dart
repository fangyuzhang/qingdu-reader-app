import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/widgets/reader/annotation/ink_canvas.dart';
import 'package:fqapp/widgets/reader/annotation/ink_controller.dart';
import 'package:fqapp/widgets/reader/annotation/ink_toolbar.dart';

/// 套索编辑（Kindle Scribe 式）：圈选命中、选中集变换、剪贴板、撤销，
/// 以及画布路由（手指圈选 / 选中态内拖动移动）与工具栏动作行。
/// 全部纯内存（seed 造笔迹），不联网、不碰 Hive。
void main() {
  // ── 控制器单测 ──────────────────────────────────────────────────────

  group('套索命中判定', () {
    test('完全圈中：两点都被包住 → 命中', () {
      final c = _controller([_line(0.1, 0.5, 0.9, 0.5)]);
      _lassoRect(c, const Rect.fromLTRB(0.05, 0.3, 0.95, 0.7));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {0});
      expect(c.hasSelection, isTrue);
      expect(c.isLassoing, isFalse);
    });

    test('部分相交：多边形切过笔段但不含任何端点 → 命中', () {
      final c = _controller([_line(0.1, 0.5, 0.9, 0.5)]);
      // 小方框 (0.45~0.55, 0.4~0.6)：不含 (0.1,0.5)/(0.9,0.5)，
      // 但左右两条边与笔段 y=0.5 相交。
      _lassoRect(c, const Rect.fromLTRB(0.45, 0.4, 0.55, 0.6));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {0});
    });

    test('圈不中：未命中清空路径与旧选中，返回 false', () {
      final c = _controller([_line(0.1, 0.5, 0.9, 0.5)]);
      _lassoRect(c, const Rect.fromLTRB(0.05, 0.05, 0.2, 0.2));
      expect(c.endLasso(), isFalse);
      expect(c.selectedIndices, isEmpty);
      expect(c.lassoPath, isEmpty);
    });

    test('新圈选替换旧选中；点按（退化路径）清空选中', () {
      final c = _controller([
        _line(0.1, 0.5, 0.9, 0.5),
        _line(0.1, 0.1, 0.2, 0.2),
      ]);
      _lassoRect(c, const Rect.fromLTRB(0.05, 0.3, 0.95, 0.7));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {0});

      _lassoRect(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {1}, reason: '新圈选替换旧选中');

      c.beginLasso(const Offset(0.8, 0.8));
      expect(c.endLasso(), isFalse);
      expect(c.hasSelection, isFalse, reason: '未圈中任何笔迹则清空选中');
    });

    test('单点笔迹按点命中；selectionBounds 为选中包围盒', () {
      final c = _controller([
        const InkStroke(points: [InkPoint(x: 0.5, y: 0.5)]),
      ]);
      _lassoRect(c, const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6));
      expect(c.endLasso(), isTrue);
      expect(c.selectionBounds, _rect(0.5, 0.5, 0.5, 0.5));
    });

    test('多选：一个大圈框住两笔', () {
      final c = _controller([
        _line(0.1, 0.1, 0.2, 0.2),
        _line(0.6, 0.6, 0.8, 0.8),
        _line(0.9, 0.9, 0.95, 0.95),
      ]);
      _lassoRect(c, const Rect.fromLTRB(0.05, 0.05, 0.85, 0.85));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {0, 1});
      expect(c.selectionBounds, _rect(0.1, 0.1, 0.8, 0.8));
    });
  });

  group('选中集变换（可撤销）', () {
    test('moveSelected 只动选中的那笔', () {
      final c = _controller([
        _line(0.1, 0.1, 0.2, 0.2),
        _line(0.5, 0.5, 0.6, 0.6),
      ]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      c.moveSelected(const Offset(0.1, -0.05));
      expect(c.strokes[0].points.first.x, closeTo(0.2, 1e-9));
      expect(c.strokes[0].points.first.y, closeTo(0.05, 1e-9));
      expect(c.strokes[1].points.first, _pt(0.5, 0.5));
      expect(c.selectionBounds, _rect(0.2, 0.05, 0.3, 0.15));

      c.undo();
      expect(c.strokes[0].points.first, _pt(0.1, 0.1));
      c.redo();
      expect(c.strokes[0].points.first.x, closeTo(0.2, 1e-9));
    });

    test('scaleSelected 围绕锚点缩放点与笔宽', () {
      final c = _controller([
        InkStroke(
          baseWidth: 3,
          points: const [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.2, y: 0.2)],
        ),
      ]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      c.scaleSelected(2, const Offset(0.1, 0.1));
      final s = c.strokes.single;
      expect(s.points.first.x, closeTo(0.1, 1e-9));
      expect(s.points.last.x, closeTo(0.3, 1e-9), reason: '0.1 + (0.2-0.1)×2');
      expect(s.points.last.y, closeTo(0.3, 1e-9));
      expect(s.baseWidth, closeTo(6, 1e-9), reason: '笔宽同步缩放');

      c.undo();
      expect(c.strokes.single.baseWidth, closeTo(3, 1e-9));
      expect(c.strokes.single.points.last, _pt(0.2, 0.2));
    });

    test('移动/缩放/粘贴 逐步撤销回退到最初状态', () {
      final c = _controller([
        InkStroke(
          baseWidth: 3,
          points: const [InkPoint(x: 0.1, y: 0.1), InkPoint(x: 0.2, y: 0.2)],
        ),
      ]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));

      c.moveSelected(const Offset(0.1, 0)); // → (0.2,0.1)(0.3,0.2)
      c.scaleSelected(2, const Offset(0.2, 0.1)); // → (0.2,0.1)(0.4,0.3) w6
      c.copySelected();
      expect(c.pasteAt(const Offset(0.6, 0.6)), isTrue); // 粘贴中心对齐 0.6,0.6
      expect(c.strokes, hasLength(2));
      expect(c.selectedIndices, {1}, reason: '粘贴后选中新笔迹');
      expect(
        c.selectionBounds,
        _rect(0.5, 0.5, 0.7, 0.7),
        reason: '粘贴整体中心对齐指定点',
      );

      c.undo(); // 撤销粘贴
      expect(c.strokes, hasLength(1));
      expect(c.strokes.single.points.last, _pt(0.4, 0.3));
      expect(c.strokes.single.baseWidth, closeTo(6, 1e-9));
      expect(c.hasSelection, isFalse, reason: '越界选中下标被裁剪');

      c.undo(); // 撤销缩放
      expect(c.strokes.single.points.last, _pt(0.3, 0.2));
      expect(c.strokes.single.baseWidth, closeTo(3, 1e-9));

      c.undo(); // 撤销移动
      expect(c.strokes.single.points.first, _pt(0.1, 0.1));
      expect(c.canUndo, isFalse);

      c.redo();
      c.redo();
      c.redo();
      expect(c.strokes, hasLength(2));
      expect(c.strokes.last.points.first, _pt(0.5, 0.5));
    });

    test('deleteSelected 一次删除多笔并整体撤销', () {
      final c = _controller([
        _line(0.1, 0.1, 0.2, 0.2),
        _line(0.3, 0.3, 0.4, 0.4),
        _line(0.6, 0.6, 0.7, 0.7),
      ]);
      _lassoRect(c, const Rect.fromLTRB(0.05, 0.05, 0.45, 0.45));
      expect(c.endLasso(), isTrue);
      expect(c.selectedIndices, {0, 1});
      c.deleteSelected();
      expect(c.strokes, hasLength(1));
      expect(c.hasSelection, isFalse);

      c.undo();
      expect(c.strokes, hasLength(3));
    });

    test('copy → cut → paste：剪切移除并保留副本，撤销逐步回退', () {
      final c = _controller([
        _line(0.1, 0.1, 0.2, 0.2),
        _line(0.6, 0.6, 0.7, 0.7),
      ]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      expect(c.cutSelected(), isTrue);
      expect(c.strokes, hasLength(1));
      expect(c.hasClipboard, isTrue);
      expect(c.hasSelection, isFalse);

      expect(c.pasteAt(const Offset(0.4, 0.4)), isTrue);
      expect(c.strokes, hasLength(2));
      expect(
        c.selectionBounds,
        _rect(0.35, 0.35, 0.45, 0.45),
      );

      c.undo(); // 撤销粘贴 → 只剩未剪切那笔
      expect(c.strokes, hasLength(1));
      c.undo(); // 撤销剪切 → 回到两笔原状
      expect(c.strokes, hasLength(2));
      expect(c.strokes.first.points.first, _pt(0.1, 0.1));
      expect(c.canUndo, isFalse);
    });

    test('空剪贴板/空选中是安全 no-op', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      expect(c.copySelected(), isFalse);
      expect(c.cutSelected(), isFalse);
      c.deleteSelected();
      expect(c.pasteAt(const Offset(0.5, 0.5)), isFalse);
      expect(() => c.moveSelected(const Offset(0.1, 0.1)), returnsNormally);
      expect(() => c.scaleSelected(2, Offset.zero), returnsNormally);
      expect(c.strokes.single.points.first, _pt(0.1, 0.1));
      expect(c.strokes, hasLength(1));
    });
  });

  group('变换事务（拖拽合并撤销）', () {
    test('begin/endTransform 之间多次 move 只记一条撤销', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      c.beginTransform();
      for (var i = 0; i < 3; i++) {
        c.moveSelected(const Offset(0.01, 0));
      }
      c.endTransform();
      expect(c.strokes.single.points.first.x, closeTo(0.13, 1e-9));
      expect(c.canRedo, isFalse);

      c.undo();
      expect(c.strokes.single.points.first.x, closeTo(0.1, 1e-9));
      expect(c.canUndo, isFalse, reason: '整段拖动只有一条撤销记录');
    });

    test('无实际变更的事务不产生撤销记录', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.beginTransform();
      c.endTransform();
      expect(c.canUndo, isFalse);
    });
  });

  group('工具切换与 seed 的圈选态清理', () {
    test('切到 pen/eraser 清空选中与套索路径', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      expect(c.hasSelection, isTrue);
      c.selectTool(InkTool.eraser);
      expect(c.hasSelection, isFalse);
      expect(c.isLassoing, isFalse);
    });

    test('seed 清空选中与套索路径（同页重进批注模式）', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      c.seed([_line(0.5, 0.5, 0.6, 0.6)]);
      expect(c.hasSelection, isFalse);
      expect(c.isLassoing, isFalse);
      expect(c.strokes, hasLength(1));
    });

    test('cancelLasso 丢弃路径不做命中判定', () {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.beginLasso(const Offset(0.05, 0.05));
      c.updateLasso(const Offset(0.2, 0.2));
      c.cancelLasso();
      expect(c.isLassoing, isFalse);
      expect(c.hasSelection, isFalse);
    });
  });

  // ── 画布路由（widget 测试）──────────────────────────────────────────

  group('画布套索路由', () {
    final stroke = _line(0.25, 0.25, 0.5, 0.25); // 400×600 画布上 (100,150)-(200,150)

    testWidgets('lasso 工具下手指圈选命中（无需调试手指开关）', (tester) async {
      final c = _controller([stroke]);
      c.selectTool(InkTool.lasso);
      await pumpCanvas(tester, c);

      // 画布全局偏移 x+200（800×600 测试面中央的 400×600 盒）。
      final g = await tester.startGesture(const Offset(260, 100));
      await g.moveBy(const Offset(200, 0));
      await g.moveBy(const Offset(0, 120));
      await g.moveBy(const Offset(-200, 0));
      await g.moveBy(const Offset(0, -120));
      await g.up();
      await tester.pump();

      expect(c.selectedIndices, {0});
      expect(c.strokes, hasLength(1), reason: '套索不产生新笔迹');
    });

    testWidgets('lasso 工具下手指圈空 → 无选中', (tester) async {
      final c = _controller([stroke]);
      c.selectTool(InkTool.lasso);
      await pumpCanvas(tester, c);

      final g = await tester.startGesture(const Offset(260, 420));
      await g.moveBy(const Offset(60, 0));
      await g.moveBy(const Offset(0, 60));
      await g.up();
      await tester.pump();
      expect(c.hasSelection, isFalse);
    });

    testWidgets('选中包围盒内按下拖动 → 移动选中笔迹，整段一条撤销', (tester) async {
      final c = _controller([stroke]);
      c.selectTool(InkTool.lasso);
      _select(c, const Rect.fromLTRB(0.2, 0.2, 0.55, 0.3));
      await pumpCanvas(tester, c);

      // 笔迹包围盒 (100~200,150) 外扩 12px：(88,138)-(212,162)，(350,150)
      // 全局 = 本地 (150,150) 在盒内 → 移动而非新圈选。
      final g = await tester.startGesture(const Offset(350, 150));
      await g.moveBy(const Offset(40, 0));
      await g.moveBy(const Offset(40, 0));
      await g.up();
      await tester.pump();

      expect(c.strokes.single.points.first.x, closeTo(0.25 + 80 / 400, 1e-6));
      expect(c.strokes.single.points.last.x, closeTo(0.5 + 80 / 400, 1e-6));

      c.undo();
      expect(c.strokes.single.points.first.x, closeTo(0.25, 1e-6));
      expect(c.canUndo, isFalse, reason: '一次拖动 = 一条撤销记录');
    });

    testWidgets('pen 工具行为不变：touch 默认不画（回归守护）', (tester) async {
      final c = _controller([stroke]);
      c.selectTool(InkTool.pen);
      await pumpCanvas(tester, c);

      final g = await tester.startGesture(
        const Offset(260, 150),
        kind: PointerDeviceKind.touch,
      );
      await g.moveBy(const Offset(50, 0));
      await g.up();
      await tester.pump();
      expect(c.strokes, hasLength(1));

      final pen = await tester.startGesture(
        const Offset(260, 150),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(60, 0));
      await pen.up();
      await tester.pump();
      expect(c.strokes, hasLength(2));
    });
  });

  // ── 工具栏（widget 测试）────────────────────────────────────────────

  group('工具栏套索动作行', () {
    testWidgets('lasso 激活且有选中：出现复制/剪切/删除/完成，剪贴板空无粘贴', (
      tester,
    ) async {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.selectTool(InkTool.lasso);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      await pumpToolbar(tester, c);

      expect(find.byKey(const Key('ink-copy')), findsOneWidget);
      expect(find.byKey(const Key('ink-cut')), findsOneWidget);
      expect(find.byKey(const Key('ink-delete')), findsOneWidget);
      expect(find.byKey(const Key('ink-lasso-done')), findsOneWidget);
      expect(find.byKey(const Key('ink-paste')), findsNothing);
    });

    testWidgets('无选中时不出现动作行', (tester) async {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.selectTool(InkTool.lasso);
      await pumpToolbar(tester, c);
      expect(find.byKey(const Key('ink-copy')), findsNothing);
      expect(find.byKey(const Key('ink-lasso-done')), findsNothing);
    });

    testWidgets('复制后出现粘贴，粘贴插入页面中心并选中', (tester) async {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.selectTool(InkTool.lasso);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      await pumpToolbar(tester, c);

      await tester.tap(find.byKey(const Key('ink-copy')));
      await tester.pump();
      expect(find.byKey(const Key('ink-paste')), findsOneWidget);
      expect(c.strokes, hasLength(1));

      await tester.tap(find.byKey(const Key('ink-paste')));
      await tester.pump();
      expect(c.strokes, hasLength(2));
      expect(c.selectedIndices, {1});
      expect(c.selectionBounds!.center.dx, closeTo(0.5, 1e-9));
      expect(c.selectionBounds!.center.dy, closeTo(0.5, 1e-9));
    });

    testWidgets('完成圈选：清空选中并退出套索回笔工具', (tester) async {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.selectTool(InkTool.lasso);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      await pumpToolbar(tester, c);

      await tester.tap(find.byKey(const Key('ink-lasso-done')));
      await tester.pump();

      expect(c.hasSelection, isFalse);
      expect(c.tool, InkTool.pen);
      expect(find.byKey(const Key('ink-copy')), findsNothing);
      expect(find.byKey(const Key('ink-lasso-done')), findsNothing);
    });

    testWidgets('删除按钮删除选中笔迹并可撤销', (tester) async {
      final c = _controller([_line(0.1, 0.1, 0.2, 0.2)]);
      c.selectTool(InkTool.lasso);
      _select(c, const Rect.fromLTRB(0.05, 0.05, 0.3, 0.3));
      await pumpToolbar(tester, c);

      await tester.tap(find.byKey(const Key('ink-delete')));
      await tester.pump();
      expect(c.strokes, isEmpty);
      expect(c.hasSelection, isFalse);

      await tester.tap(find.byKey(const Key('ink-undo')));
      await tester.pump();
      expect(c.strokes, hasLength(1));
    });
  });
}

// ── 测试工具 ──────────────────────────────────────────────────────────

InkController _controller(List<InkStroke> strokes) {
  final c = InkController();
  c.seed(strokes);
  c.selectTool(InkTool.lasso);
  return c;
}

InkStroke _line(double x1, double y1, double x2, double y2, {double w = 3}) =>
    InkStroke(
      baseWidth: w,
      points: [InkPoint(x: x1, y: y1), InkPoint(x: x2, y: y2)],
    );

/// InkPoint 不与 Offset 比较相等（模型只与同类型比），用谓词断言坐标。
Matcher _pt(double x, double y) => predicate<InkPoint>(
  (p) => (p.x - x).abs() < 1e-9 && (p.y - y).abs() < 1e-9,
  'InkPoint($x, $y)',
);

/// Rect 的 == 是精确 double 比较（0.2-0.05 ≠ 字面量 0.15，差 1 ULP），
/// 包围盒断言一律用近似比较。
Matcher _rect(double l, double t, double r, double b) => predicate<Rect>(
  (x) =>
      (x.left - l).abs() < 1e-9 &&
      (x.top - t).abs() < 1e-9 &&
      (x.right - r).abs() < 1e-9 &&
      (x.bottom - b).abs() < 1e-9,
  'Rect~($l, $t, $r, $b)',
);

/// 用套索路径框住 [rect]（不 endLasso，交给用例决定抬手时机）。
void _lassoRect(InkController c, Rect rect) {
  c.beginLasso(rect.topLeft);
  c.updateLasso(rect.topRight);
  c.updateLasso(rect.bottomRight);
  c.updateLasso(rect.bottomLeft);
}

void _select(InkController c, Rect rect) {
  _lassoRect(c, rect);
  expect(c.endLasso(), isTrue);
}

Future<void> pumpCanvas(WidgetTester tester, InkController controller) async {
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
  await tester.pump();
}

Future<void> pumpToolbar(WidgetTester tester, InkController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: InkToolbar(controller: controller, onDone: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
}
