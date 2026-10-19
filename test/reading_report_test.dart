import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reading_report.dart';

/// 「我的阅读」详细报告的数据层：范围、聚合、柱状图、里程碑。
void main() {
  ReadingReport buildReport({
    Map<String, Map<String, double>>? bookDays,
    List<ReaderAnnotationSummary> notes = const [],
  }) {
    return ReadingReport(
      bookDayMinutes:
          bookDays ??
          {
            'book-1': {'2026-10-19': 30, '2026-10-20': 60},
            'book-2': {'2026-10-19': 15},
          },
      books: const [
        ReadingBookMeta(id: 'book-1', title: '稻草人'),
        ReadingBookMeta(id: 'book-2', title: '疯狂动物城'),
      ],
      notes: notes,
    );
  }

  group('时间范围', () {
    test('周从周一开始，到周日结束', () {
      final range = reportWeekRange(DateTime(2026, 10, 21)); // 周三
      expect(range.start, DateTime(2026, 10, 19));
      expect(range.end, DateTime(2026, 10, 25));
      expect(range.dayCount, 7);
      expect(range.contains(DateTime(2026, 10, 25)), isTrue);
      expect(range.contains(DateTime(2026, 10, 26)), isFalse);
    });

    test('月按自然月，闰年二月 29 天', () {
      expect(
        reportMonthRange(DateTime(2026, 2, 10)).end,
        DateTime(2026, 2, 28),
      );
      expect(
        reportMonthRange(DateTime(2024, 2, 10)).end,
        DateTime(2024, 2, 29),
      );
      expect(
        reportMonthRange(DateTime(2026, 12, 5)).end,
        DateTime(2026, 12, 31),
      );
    });

    test('年从 1 月 1 日到 12 月 31 日', () {
      final range = reportYearRange(DateTime(2026, 7, 4));
      expect(range.start, DateTime(2026));
      expect(range.end, DateTime(2026, 12, 31));
    });

    test('前后翻页跨月跨年都正确', () {
      expect(
        shiftReportAnchor(ReportScope.week, DateTime(2026, 10, 19), -1),
        DateTime(2026, 10, 12),
      );
      expect(
        shiftReportAnchor(ReportScope.month, DateTime(2026, 1, 15), -1),
        DateTime(2025, 12, 15),
      );
      expect(
        shiftReportAnchor(ReportScope.year, DateTime(2026, 6, 1), 1),
        DateTime(2027, 6, 1),
      );
    });
  });

  group('聚合', () {
    test('合计时长与活跃天数按范围裁剪', () {
      final report = buildReport();
      final week = reportWeekRange(DateTime(2026, 10, 21));
      expect(report.minutesIn(week), 105);
      expect(report.activeDaysIn(week), 2);
      // 下一周没有任何记录。
      final nextWeek = reportWeekRange(DateTime(2026, 10, 28));
      expect(report.minutesIn(nextWeek), 0);
      expect(report.activeDaysIn(nextWeek), 0);
    });

    test('读得最久的那天', () {
      final report = buildReport();
      final top = report.topDayIn(reportWeekRange(DateTime(2026, 10, 21)));
      expect(top, isNotNull);
      expect(top!.day, DateTime(2026, 10, 20));
      expect(top.minutes, 60);
    });

    test('读过的书按分钟数从多到少', () {
      final report = buildReport();
      final books = report.booksIn(reportWeekRange(DateTime(2026, 10, 21)));
      expect(books.map((entry) => entry.book.title), ['稻草人', '疯狂动物城']);
      expect(books.first.minutes, 90);
      expect(books.last.minutes, 15);
    });

    test('周视图 7 根柱子，标签为周一到周日', () {
      final report = buildReport();
      final bars = report.barsFor(
        ReportScope.week,
        reportWeekRange(DateTime(2026, 10, 21)),
      );
      expect(bars.length, 7);
      expect(bars.map((bar) => bar.label), ['一', '二', '三', '四', '五', '六', '日']);
      expect(bars[0].minutes, 45); // 10-19：30 + 15
      expect(bars[1].minutes, 60);
      expect(bars[6].minutes, 0);
    });

    test('月视图按天数出柱，日期对得上', () {
      final report = buildReport();
      final bars = report.barsFor(
        ReportScope.month,
        reportMonthRange(DateTime(2026, 10, 21)),
      );
      expect(bars.length, 31);
      expect(bars[18].label, '19');
      expect(bars[18].minutes, 45);
      expect(bars[19].minutes, 60);
    });

    test('总览只有一年数据时按月份出柱，标签带月', () {
      final report = buildReport();
      final bars = report.barsByYear();
      expect(bars.length, 12);
      expect(bars[9].label, '10月');
      expect(bars[9].minutes, 105);
    });

    test('年视图 12 根柱，按自然月聚合', () {
      final report = buildReport();
      final bars = report.barsFor(
        ReportScope.year,
        reportYearRange(DateTime(2026, 10, 21)),
      );
      expect(bars.length, 12);
      expect(bars[9].minutes, 105);
      expect(bars[0].minutes, 0);
    });
  });

  group('里程碑', () {
    test('累计满 1 小时那天生成一条', () {
      final report = buildReport();
      final milestones = report.milestones();
      final hour = milestones.where((item) => item.headline == '阅读时长达到 1 个小时。');
      expect(hour.length, 1);
      expect(hour.first.day, DateTime(2026, 10, 20));
      expect(hour.first.detail, contains('稻草人'));
    });

    test('连续阅读 3 天生成一条', () {
      final report = ReadingReport(
        bookDayMinutes: {
          'book-1': {'2026-10-19': 5, '2026-10-20': 5, '2026-10-21': 5},
        },
        books: const [ReadingBookMeta(id: 'book-1', title: '稻草人')],
        notes: const [],
      );
      final streak = report.milestones().where(
        (item) => item.headline == '连续阅读达到 3 天。',
      );
      expect(streak.length, 1);
      expect(streak.first.day, DateTime(2026, 10, 21));
    });

    test('笔记满 10 条才生成，按时间正序取第 10 条', () {
      final notes = [
        for (var i = 0; i < 12; i++)
          ReaderAnnotationSummary(
            createdAt: DateTime(2026, 9, 1 + i).millisecondsSinceEpoch,
            bookTitle: '稻草人',
            type: 'annot',
          ),
      ];
      final report = buildReport(notes: notes);
      final milestone = report.milestones().where(
        (item) => item.headline == '发表的笔记达到 10 条。',
      );
      expect(milestone.length, 1);
      expect(milestone.first.day, DateTime(2026, 9, 10));
    });

    test('超出累计阈值的条目不会重复出现', () {
      final report = buildReport();
      final headlines = report
          .milestones()
          .map((item) => item.headline)
          .toList();
      expect(headlines.toSet().length, headlines.length);
    });
  });

  group('格式化', () {
    test('时长文案', () {
      expect(formatReadingDuration(0), '0分钟');
      expect(formatReadingDuration(5), '5分钟');
      expect(formatReadingDuration(60), '1小时');
      expect(formatReadingDuration(75), '1小时15分钟');
    });

    test('大数字 + 单位：超过 60 分钟换小时', () {
      expect(readingDurationParts(5), (value: '5', unit: '分钟'));
      expect(readingDurationParts(90), (value: '1.5', unit: '小时'));
      expect(readingDurationParts(120), (value: '2', unit: '小时'));
      expect(readingDurationParts(600), (value: '10', unit: '小时'));
      expect(readingDurationParts(6000), (value: '100', unit: '小时'));
    });

    test('空数据不崩，范围退化为今天', () {
      final report = ReadingReport.empty;
      expect(report.hasData, isFalse);
      expect(report.extent.start, report.extent.end);
      expect(report.minutesIn(report.extent), 0);
      expect(report.milestones(), isEmpty);
    });
  });

  group('旧记录估算', () {
    test('没有真实时长的历史按每本 10 分钟记在打开当天', () {
      final bookDays = buildBookDayMinutes(
        history: [
          {
            'id': 'legacy',
            'kind': 'book',
            'time': DateTime(2026, 10, 1, 12).millisecondsSinceEpoch,
          },
        ],
        readTimeSeconds: const {},
      );
      expect(bookDays['legacy']?['2026-10-1'], 10);
    });

    test('有真实时长时不再叠加估算值', () {
      final bookDays = buildBookDayMinutes(
        history: [
          {
            'id': 'book-1',
            'kind': 'book',
            'time': DateTime(2026, 10, 1, 12).millisecondsSinceEpoch,
          },
        ],
        readTimeSeconds: const {
          'book-1': {'2026-10-1': 600},
        },
      );
      expect(bookDays['book-1'], {'2026-10-1': 10});
    });
  });
}
