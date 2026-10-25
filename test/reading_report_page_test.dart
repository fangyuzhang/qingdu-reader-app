import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/reading_report_page.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/reading_report.dart';
import 'package:fqapp/services/reading_stats_store.dart';

/// 「我的阅读」详细报告页：五个档位的排版与数据接线。
void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-reading-report-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    ReadingStatsStore.instance.resetForTest();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  /// Hive 走真实文件 IO，在 testWidgets 的假时钟里必须用 runAsync 包起来，
  /// 否则写入永远等不到完成（统计页的老测试也是这么处理的）。
  ///
  /// 种子时间必须相对 DateTime.now() 取：页面按真实当前日历算「本周/
  /// 本月」窗口，硬编码日期（如 2026-10-19）会在日历翻页后全部落出
  /// 当前周——曾让该用例在 2026-10-26 00:00 后静默失败（时间炸弹）。
  Future<void> seed(WidgetTester tester, {double seconds = 600}) async {
    final now = DateTime.now();
    await tester.runAsync(() async {
      await LibraryStore.instance.addHistory({
        'id': 'book-a',
        'kind': 'book',
        'title': '稻草人',
        'author': '叶圣陶',
        'time': now.millisecondsSinceEpoch,
      });
      await LibraryStore.instance.accumulateReadTime(
        'book-a',
        'book',
        seconds,
        at: now,
      );
      await LibraryStore.instance.accumulateReadTime(
        'book-a',
        'book',
        seconds / 2,
        at: now,
      );
    });
  }

  Widget app({double textScale = 1.0, Key? key}) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: ReadingReportPage(key: key),
  );

  testWidgets('默认进入周视图：大数字、图表、最久书都在', (tester) async {
    await seed(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('我的阅读'), findsOneWidget);
    for (final scope in ['week', 'month', 'year', 'all', 'timeline']) {
      expect(
        find.byKey(ValueKey('reading-report-scope-$scope')),
        findsOneWidget,
      );
    }
    // 600s + 300s = 15 分钟。
    expect(find.text('15'), findsOneWidget);
    expect(find.text('分钟'), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-report-chart')), findsOneWidget);
    expect(find.text('阅读时长分布'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('阅读最久'), 200);
    expect(find.text('稻草人'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每日阅读：周档补齐到今天的每一天，阅历档不出现', (tester) async {
    await seed(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reading-report-daily')),
      200,
    );
    expect(find.text('每日阅读'), findsOneWidget);
    // 周档补齐 0 分钟的天，但只列到今天：周一起算共 weekday 行。
    final rows = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('reading-report-daily-row-');
    });
    expect(rows, findsNWidgets(reportDay(DateTime.now()).weekday));

    // 档位切换在列表顶部，先滚回去再点「阅历」。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reading-report-scope-timeline')),
      -200,
    );
    await tester.tap(
      find.byKey(const ValueKey('reading-report-scope-timeline')),
    );
    await tester.pumpAndSettle();
    expect(find.text('每日阅读'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月档切成读过/读完/阅读天数/笔记四宫格', (tester) async {
    await seed(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reading-report-scope-month')));
    await tester.pumpAndSettle();

    expect(find.text('读过'), findsOneWidget);
    expect(find.text('读完'), findsOneWidget);
    expect(find.text('阅读天数'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    // 月视图是 31 根柱子，横轴按 1/5/10… 抽稀。
    expect(find.byKey(const ValueKey('reading-report-chart')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('年档能往前翻到上一年（空数据回到 0）', (tester) async {
    await seed(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reading-report-scope-year')));
    await tester.pumpAndSettle();
    expect(find.textContaining('年'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('reading-report-prev')));
    await tester.pumpAndSettle();
    // 上一年没有记录，大数字回到 0。
    expect(find.text('0'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅历：数据太少时给空状态', (tester) async {
    await seed(tester, seconds: 60);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reading-report-scope-timeline')),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有值得纪念的节点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('阅历：累计满 1 小时出现时间线', (tester) async {
    // 3600 + 1800 秒 = 90 分钟，跨过「1 个小时」。
    await seed(tester, seconds: 3600);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reading-report-scope-timeline')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reading-report-timeline')),
      findsOneWidget,
    );
    expect(find.text('阅读时长达到 1 个小时。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 + 1.8 倍字号下五个档位都不溢出', (tester) async {
    await seed(tester, seconds: 3600);
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app(textScale: 1.8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final scope in ['month', 'year', 'all', 'timeline']) {
      await tester.tap(find.byKey(ValueKey('reading-report-scope-$scope')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
