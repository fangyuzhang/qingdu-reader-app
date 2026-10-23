import 'media_history_store.dart';

/// 【青茄重构·新增】「我的阅读」详细报告的纯数据层。
///
/// 热力图只答「哪天读了多久」，详细页要答「这一周/月/年读了多久、读了几本、
/// 最多的一天是哪天、最久的是哪本书、什么时候跨过了里程碑」。
/// 这些都要在原始快照（`{bookId: {日: 秒}}`）上做多轮聚合，放在 Widget 里
/// 会既难测又容易拖慢首帧，所以统一在这里算完再交给 UI。
///
/// 所有日期键沿用 [LibraryStore] 的 `yyyy-M-d`（**不补零**），
/// 与阅读时长、字数统计共用同一套键，避免两处对不上。

/// 报告的时间粒度。
enum ReportScope { week, month, year, all, timeline }

extension ReportScopeLabel on ReportScope {
  String get label => switch (this) {
    ReportScope.week => '周',
    ReportScope.month => '月',
    ReportScope.year => '年',
    ReportScope.all => '总',
    ReportScope.timeline => '阅历',
  };

  /// 该粒度是否有「上一期 / 下一期」。
  bool get paged => this == ReportScope.week || this == ReportScope.month;
}

String reportDayKey(DateTime day) => '${day.year}-${day.month}-${day.day}';

DateTime reportDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 「今天 / 昨天 / 周一」这类相对标签；正常日期一律返回周几。
///
/// 「每日阅读」列表和原先「我的」页的每日记录共用这一份文案逻辑，
/// 避免两处各写一遍日期判断。
String reportDayLabel(DateTime day, {DateTime? now}) {
  final today = reportDay(now ?? DateTime.now());
  final target = reportDay(day);
  if (target == today) return '今天';
  if (target == today.subtract(const Duration(days: 1))) return '昨天';
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return weekdays[target.weekday - 1];
}

/// 闭区间的日期范围（按天）。
class ReportRange {
  const ReportRange(this.start, this.end);

  final DateTime start;
  final DateTime end;

  int get dayCount => end.difference(start).inDays + 1;

  bool contains(DateTime day) {
    final d = reportDay(day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  @override
  bool operator ==(Object other) =>
      other is ReportRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '${reportDayKey(start)}..${reportDayKey(end)}';
}

/// 所在自然周（周一到周日）。
ReportRange reportWeekRange(DateTime anchor) {
  final day = reportDay(anchor);
  final monday = day.subtract(Duration(days: day.weekday - DateTime.monday));
  return ReportRange(monday, monday.add(const Duration(days: 6)));
}

/// 所在自然月。
ReportRange reportMonthRange(DateTime anchor) {
  final day = reportDay(anchor);
  final first = DateTime(day.year, day.month);
  return ReportRange(first, DateTime(day.year, day.month + 1, 0));
}

/// 所在自然年。
ReportRange reportYearRange(DateTime anchor) {
  final day = reportDay(anchor);
  return ReportRange(DateTime(day.year), DateTime(day.year, 12, 31));
}

/// 按自然月平移，并把日期夹到目标月的最后一天（1 月 31 日往前一月是 12 月 31 日）。
DateTime _shiftMonths(DateTime day, int months) {
  final anchor = DateTime(day.year, day.month + months);
  final lastDay = DateTime(anchor.year, anchor.month + 1, 0).day;
  return DateTime(
    anchor.year,
    anchor.month,
    day.day > lastDay ? lastDay : day.day,
  );
}

/// 粒度对应的范围；[ReportScope.all] / [ReportScope.timeline] 返回 null
/// （由数据自身的首尾日期决定）。
ReportRange? reportRangeFor(ReportScope scope, DateTime anchor) =>
    switch (scope) {
      ReportScope.week => reportWeekRange(anchor),
      ReportScope.month => reportMonthRange(anchor),
      ReportScope.year => reportYearRange(anchor),
      _ => null,
    };

/// 把 anchor 往前/后挪一期（周按 7 天，月/年按自然月/年）。
DateTime shiftReportAnchor(ReportScope scope, DateTime anchor, int delta) {
  final day = reportDay(anchor);
  return switch (scope) {
    ReportScope.week => day.add(Duration(days: 7 * delta)),
    ReportScope.month => _shiftMonths(day, delta),
    ReportScope.year => _shiftMonths(day, delta * 12),
    _ => day,
  };
}

/// 一本书在报告里的静态信息（标题/封面/作者/是否读完）。
class ReadingBookMeta {
  const ReadingBookMeta({
    required this.id,
    required this.title,
    this.cover = '',
    this.author = '',
    this.finished = false,
  });

  final String id;
  final String title;
  final String cover;
  final String author;
  final bool finished;
}

/// 把「阅读时长快照」折算成 `{bookId: {日: 分钟}}`。
///
/// 老历史（开统计之前就读过的书）没有真实秒数，按每本 10 分钟估算，
/// 与热力图的口径保持一致；一旦这本书有了真实数据，估算值自动让位。
Map<String, Map<String, double>> buildBookDayMinutes({
  required List<Map<String, dynamic>> history,
  required Map<String, Map<String, double>> readTimeSeconds,
  double flatBookMinutes = 10,
}) {
  final out = <String, Map<String, double>>{};
  void add(String bookId, String day, double minutes) {
    if (bookId.isEmpty || minutes <= 0) return;
    final days = out.putIfAbsent(bookId, () => <String, double>{});
    days[day] = (days[day] ?? 0) + minutes;
  }

  readTimeSeconds.forEach((bookId, days) {
    days.forEach((day, seconds) => add(bookId, day, seconds / 60));
  });
  final withRealData = readTimeSeconds.keys.toSet();
  for (final entry in history) {
    final id = historyStatisticsId(entry);
    if (withRealData.contains(id)) continue;
    final time = DateTime.fromMillisecondsSinceEpoch(
      (entry['time'] as num?)?.toInt() ?? 0,
    );
    add(id, reportDayKey(time), flatBookMinutes);
  }
  return out;
}

/// 把按书聚合的表压平成按天。
Map<String, double> sumDayMinutes(Map<String, Map<String, double>> bookDays) {
  final out = <String, double>{};
  bookDays.forEach((_, days) {
    days.forEach((day, minutes) {
      out[day] = (out[day] ?? 0) + minutes;
    });
  });
  return out;
}

/// 柱状图上的一根柱子。
class ReportBar {
  const ReportBar({required this.label, required this.minutes, this.day});

  /// X 轴刻度文字（周一为「一」、月视图为「19」、年视图为「3」…）。
  final String label;
  final double minutes;

  /// 该柱对应的具体日期（年/月视图的聚合柱为 null）。
  final DateTime? day;
}

/// 「阅历」时间线上的一条里程碑。
class ReportMilestone {
  const ReportMilestone({
    required this.day,
    required this.headline,
    required this.detail,
  });

  final DateTime day;

  /// 主句，例如「阅读时长达到 10 个小时。」
  final String headline;

  /// 副句，例如「那时，你正在读《稻草人》。」
  final String detail;
}

/// 报告页一次渲染所需的全部聚合结果。
class ReadingReport {
  ReadingReport({
    required this.bookDayMinutes,
    required this.books,
    required this.notes,
  }) : dayMinutes = sumDayMinutes(bookDayMinutes),
       _bookIndex = {for (final book in books) book.id: book};

  final Map<String, Map<String, double>> bookDayMinutes;
  final Map<String, double> dayMinutes;
  final List<ReadingBookMeta> books;
  final List<ReaderAnnotationSummary> notes;
  final Map<String, ReadingBookMeta> _bookIndex;

  static final ReadingReport empty = ReadingReport(
    bookDayMinutes: const {},
    books: const [],
    notes: const [],
  );

  bool get hasData => dayMinutes.values.any((minutes) => minutes > 0);

  /// 有数据的最早/最晚一天；没有数据时退化为今天。
  ReportRange get extent {
    if (dayMinutes.isEmpty) {
      return ReportRange(reportDay(DateTime.now()), reportDay(DateTime.now()));
    }
    var first = DateTime(9999);
    var last = DateTime(1970);
    for (final key in dayMinutes.keys) {
      final day = _parseDayKey(key);
      if (day == null) continue;
      if (day.isBefore(first)) first = day;
      if (day.isAfter(last)) last = day;
    }
    if (last.isBefore(first)) {
      final today = reportDay(DateTime.now());
      return ReportRange(today, today);
    }
    return ReportRange(first, last);
  }

  /// 指定范围的合计分钟数。
  double minutesIn(ReportRange range) {
    var total = 0.0;
    for (
      var day = range.start;
      !day.isAfter(range.end);
      day = day.add(const Duration(days: 1))
    ) {
      total += dayMinutes[reportDayKey(day)] ?? 0;
    }
    return total;
  }

  /// 范围内有阅读记录的天数。
  int activeDaysIn(ReportRange range) {
    var days = 0;
    for (
      var day = range.start;
      !day.isAfter(range.end);
      day = day.add(const Duration(days: 1))
    ) {
      if ((dayMinutes[reportDayKey(day)] ?? 0) > 0) days++;
    }
    return days;
  }

  /// 范围内逐日的阅读时长，按日期正序。
  ///
  /// [includeEmpty] 为 false 时只返回有记录的天，适合年/总这类跨度很大的
  /// 档位（一年 365 行没人看）；周档传 true，让用户看到完整 7 天。
  List<({DateTime day, double minutes})> dailyIn(
    ReportRange range, {
    bool includeEmpty = false,
  }) {
    final out = <({DateTime day, double minutes})>[];
    for (
      var day = range.start;
      !day.isAfter(range.end);
      day = day.add(const Duration(days: 1))
    ) {
      final minutes = dayMinutes[reportDayKey(day)] ?? 0;
      if (!includeEmpty && minutes <= 0) continue;
      out.add((day: day, minutes: minutes));
    }
    return out;
  }

  /// 范围内读过的书（按时长从多到少）。
  List<({ReadingBookMeta book, double minutes})> booksIn(ReportRange range) {
    final out = <({ReadingBookMeta book, double minutes})>[];
    bookDayMinutes.forEach((bookId, days) {
      var total = 0.0;
      days.forEach((day, minutes) {
        final parsed = _parseDayKey(day);
        if (parsed != null && range.contains(parsed)) total += minutes;
      });
      if (total <= 0) return;
      out.add((book: _metaOf(bookId), minutes: total));
    });
    out.sort((a, b) => b.minutes.compareTo(a.minutes));
    return out;
  }

  /// 范围内读得最久的那一天。
  ({DateTime day, double minutes})? topDayIn(ReportRange range) {
    DateTime? bestDay;
    var best = 0.0;
    for (
      var day = range.start;
      !day.isAfter(range.end);
      day = day.add(const Duration(days: 1))
    ) {
      final minutes = dayMinutes[reportDayKey(day)] ?? 0;
      if (minutes > best) {
        best = minutes;
        bestDay = day;
      }
    }
    if (bestDay == null) return null;
    return (day: bestDay, minutes: best);
  }

  /// 某一天里读得最久的那本书（里程碑文案用）。
  ReadingBookMeta? bookOn(DateTime day) {
    final key = reportDayKey(day);
    String? bestId;
    var best = 0.0;
    bookDayMinutes.forEach((bookId, days) {
      final minutes = days[key] ?? 0;
      if (minutes > best) {
        best = minutes;
        bestId = bookId;
      }
    });
    return bestId == null ? null : _metaOf(bestId!);
  }

  /// 单日 / 单月的柱状图序列。
  List<ReportBar> barsFor(ReportScope scope, ReportRange range) {
    switch (scope) {
      case ReportScope.week:
        const labels = ['一', '二', '三', '四', '五', '六', '日'];
        return [
          for (var i = 0; i < 7; i++)
            ReportBar(
              label: labels[i],
              minutes:
                  dayMinutes[reportDayKey(
                    range.start.add(Duration(days: i)),
                  )] ??
                  0,
              day: range.start.add(Duration(days: i)),
            ),
        ];
      case ReportScope.month:
        final days = range.dayCount;
        return [
          for (var i = 0; i < days; i++)
            ReportBar(
              label: '${i + 1}',
              minutes:
                  dayMinutes[reportDayKey(
                    range.start.add(Duration(days: i)),
                  )] ??
                  0,
              day: range.start.add(Duration(days: i)),
            ),
        ];
      case ReportScope.year:
        final year = range.start.year;
        return [
          for (var month = 1; month <= 12; month++)
            ReportBar(
              label: '$month',
              minutes: minutesIn(
                ReportRange(
                  DateTime(year, month),
                  DateTime(year, month + 1, 0),
                ),
              ),
            ),
        ];
      case ReportScope.all:
        return barsByYear();
      case ReportScope.timeline:
        return const [];
    }
  }

  /// 总览视图：按自然年聚合（只有一年数据时退化为按月，图才不至于只有一根柱）。
  List<ReportBar> barsByYear() {
    final span = extent;
    final years = <int>{};
    for (
      var day = span.start;
      !day.isAfter(span.end);
      day = day.add(const Duration(days: 1))
    ) {
      if ((dayMinutes[reportDayKey(day)] ?? 0) > 0) years.add(day.year);
    }
    if (years.isEmpty) return const [];
    if (years.length == 1) {
      // 只有一年数据时按月份出柱，标签直接带「月」，免得读成「3 年」。
      return [
        for (final bar in barsFor(
          ReportScope.year,
          reportYearRange(DateTime(years.first)),
        ))
          ReportBar(label: '${bar.label}月', minutes: bar.minutes),
      ];
    }
    final sorted = years.toList()..sort();
    return [
      for (final year in sorted)
        ReportBar(
          label: '$year年',
          minutes: minutesIn(reportYearRange(DateTime(year))),
        ),
    ];
  }

  /// 「阅历」：时长 / 笔记 / 连续天数三类里程碑，按时间倒序。
  List<ReportMilestone> milestones() {
    final out = <ReportMilestone>[];
    final dayKeys = dayMinutes.keys.toList()
      ..sort((a, b) {
        final da = _parseDayKey(a);
        final db = _parseDayKey(b);
        if (da == null || db == null) return 0;
        return da.compareTo(db);
      });

    // 1. 累计时长里程碑。
    final minuteThresholds = <(double, String)>[
      (60, '1 个小时'),
      (300, '5 个小时'),
      (600, '10 个小时'),
      (1800, '30 个小时'),
      (3600, '60 个小时'),
      (7200, '120 个小时'),
    ];
    for (final (threshold, text) in minuteThresholds) {
      DateTime? reached;
      var total = 0.0;
      for (final key in dayKeys) {
        final day = _parseDayKey(key);
        if (day == null) continue;
        total += dayMinutes[key] ?? 0;
        if (total >= threshold) {
          reached = day;
          break;
        }
      }
      if (reached == null) continue;
      final book = bookOn(reached);
      out.add(
        ReportMilestone(
          day: reached,
          headline: '阅读时长达到 $text。',
          detail: book == null ? '那天你读得很投入。' : '那时，你正在读《${book.title}》。',
        ),
      );
    }

    // 2. 笔记里程碑。
    final sortedNotes = [...notes]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final threshold in const [10, 50, 100, 500]) {
      if (sortedNotes.length < threshold) continue;
      final note = sortedNotes[threshold - 1];
      final day = DateTime.fromMillisecondsSinceEpoch(note.createdAt);
      out.add(
        ReportMilestone(
          day: reportDay(day),
          headline: '发表的笔记达到 $threshold 条。',
          detail: note.bookTitle.isEmpty
              ? '你为读到的段落留下了想法。'
              : '在《${note.bookTitle}》里，你留下划线，文字成为你存在的证明。',
        ),
      );
    }

    // 3. 连续阅读里程碑。
    var run = 0;
    DateTime? cursor;
    for (final key in dayKeys) {
      final day = _parseDayKey(key);
      if (day == null) continue;
      if ((dayMinutes[key] ?? 0) <= 0) continue;
      if (cursor != null && day.difference(cursor).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      cursor = day;
      for (final threshold in const [3, 7, 30, 100]) {
        if (run == threshold) {
          out.add(
            ReportMilestone(
              day: day,
              headline: '连续阅读达到 $threshold 天。',
              detail: '把阅读变成习惯，你已经在路上了。',
            ),
          );
        }
      }
    }

    out.sort((a, b) => b.day.compareTo(a.day));
    return out;
  }

  ReadingBookMeta _metaOf(String bookId) =>
      _bookIndex[bookId] ??
      ReadingBookMeta(id: bookId, title: bookId.isEmpty ? '未知书籍' : bookId);

  static DateTime? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }
}

/// 报告里只用得到批注的「时间 + 出处」，不必把整条原文带进 UI 层。
class ReaderAnnotationSummary {
  const ReaderAnnotationSummary({
    required this.createdAt,
    this.bookTitle = '',
    this.type = '',
  });

  final int createdAt;
  final String bookTitle;
  final String type;

  bool get isExcerpt => type == 'excerpt';
}

/// 把分钟格式化成「1小时20分钟」这类中文时长。
String formatReadingDuration(double minutes) {
  final total = minutes.round();
  if (total <= 0) return '0分钟';
  final hours = total ~/ 60;
  final mins = total % 60;
  if (hours == 0) return '$mins分钟';
  if (mins == 0) return '$hours小时';
  return '$hours小时$mins分钟';
}

/// 大数字 + 小单位：数值较大时换成小时，避免出现「1240 分钟」。
({String value, String unit}) readingDurationParts(double minutes) {
  final total = minutes.round();
  if (total < 60) return (value: '$total', unit: '分钟');
  final hours = total / 60;
  if (hours < 10) {
    final text = hours.toStringAsFixed(1);
    return (
      value: text.endsWith('.0') ? text.substring(0, text.length - 2) : text,
      unit: '小时',
    );
  }
  return (value: '${hours.round()}', unit: '小时');
}
