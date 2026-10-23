import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/stats_page.dart';
import 'package:fqapp/services/library_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-stats-review-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('statistics fit a narrow phone at text scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: StatsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('阅读热力图'), findsOneWidget);
      for (final weekday in {0: '周一', 2: '周三', 4: '周五'}.entries) {
        final label = find.text(weekday.value);
        final cell = find.byKey(
          ValueKey('reading-heatmap-cell-${weekday.key}'),
        );
        expect(label, findsOneWidget);
        expect(cell, findsOneWidget);
        expect(
          tester.getCenter(label).dy,
          closeTo(tester.getCenter(cell).dy, 0.01),
          reason: '${weekday.value} must align with its calendar row',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('audio statistics reopen the original content ID', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          LibraryStore.instance.accumulateReadTime('audio:shared', 'audio', 60),
    );
    final observer = _StatsRouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: const Scaffold(body: StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(StatsPage));
    final showAll = find.widgetWithText(TextButton, '查看全部');
    await tester.scrollUntilVisible(
      showAll,
      400,
      scrollable: find
          .descendant(
            of: find.byType(StatsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(showAll);
    await tester.pumpAndSettle();
    await tester.tap(showAll.hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('听书 shared'),
      ),
    );
    final page =
        (observer.lastRoute! as MaterialPageRoute).builder(context)
            as DetailPage;
    expect(page.item.id, 'shared');
    expect(page.item.kind, 'audio');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy video statistics stay hidden from the product UI', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          LibraryStore.instance.accumulateReadTime('orphan-video', 'video', 60),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StatsPage())),
    );
    await tester.pumpAndSettle();
    final showAll = find.widgetWithText(TextButton, '查看全部');
    await tester.scrollUntilVisible(
      showAll,
      400,
      scrollable: find
          .descendant(
            of: find.byType(StatsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(showAll).onPressed, isNull);
    expect(find.text('orphan-video'), findsNothing);
  });

  testWidgets('概览卡把天数类指标并成一行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: StatsPage())),
    );
    await tester.pumpAndSettle();
    for (final label in ['今日', '本月', '总计', '累计字数']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 天数类指标不再各占一格，合并为宫格下方的一行。
    expect(find.text('活跃天数'), findsNothing);
    expect(find.textContaining('活跃 0 天'), findsOneWidget);
    expect(find.textContaining('连续打卡 0 天'), findsOneWidget);
  });

  testWidgets('我的页不再重复放笔记快捷入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: MinePage()));
    await tester.pumpAndSettle();
    // 快捷栏里不再有「笔记」，只留底部导航 + 统计页的「我的笔记」卡。
    expect(find.text('笔记'), findsNothing);
    expect(find.text('章节缓存'), findsOneWidget);
    expect(find.text('我的笔记'), findsOneWidget);
  });
}

class _StatsRouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      lastRoute = route;
}
