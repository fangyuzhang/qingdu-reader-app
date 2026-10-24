import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/stylus_probe_page.dart';

/// 手写笔探测页（第 2 组调试工具）：验证事件统计与 kind 区分在普通
/// widget 测试环境即可跑通（不依赖真机；真机压感结论回填页面头注释）。
void main() {
  testWidgets('手指事件被统计：kind 显示 touch、采样点增加、可清空', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: StylusProbePage()),
    );

    expect(find.byKey(const Key('probe-canvas')), findsOneWidget);
    expect(find.textContaining('采样点'), findsOneWidget);

    final canvas = tester.getCenter(find.byKey(const Key('probe-canvas')));
    final gesture = await tester.startGesture(
      canvas,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    // 最后一次事件是 up：kind 仍为 touch，采样点 = down+2 move+up 共 4。
    expect(find.text('touch'), findsWidgets);
    expect(
      tester.widget<Text>(find.byKey(const Key('probe-count'))).data,
      '4',
    );

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('probe-count'))).data,
      '0',
    );
  });

  testWidgets('压感统计显示 min/max/avg', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: StylusProbePage()),
    );

    final canvas = tester.getCenter(find.byKey(const Key('probe-canvas')));
    final gesture = await tester.startGesture(
      canvas,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    // 测试环境压感恒 0，三值都应为 0.000（真实压感需真机）。
    expect(find.textContaining('0.000'), findsWidgets);
    expect(find.text('stylus'), findsWidgets);
  });
}
