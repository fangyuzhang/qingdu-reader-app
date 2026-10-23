import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/reader_annotation_store.dart';
import '../services/reading_report.dart';
import '../services/reading_stats_store.dart';
import '../services/shelf_store.dart';
import '../widgets/book_thumb.dart';
import '../widgets/home/home_design.dart';
import 'notes_page.dart';
import '../services/reading_report_exporter.dart';

/// 【青茄重构·新增】「我的阅读」详细报告。
///
/// 从「我的」页的阅读热力图点进来（热力图答「哪天读了多久」，这一页答
/// 「这一周一月一年读了多少、读了几本、最久的是哪天哪本书」）。
///
/// 排版对齐蜗牛读书的统计页：
/// * 顶部五档切换（周 / 月 / 年 / 总 / 阅历）；
/// * 大数字时长 + 日均，月档再带一个环比；
/// * 周档是「读了几天 + 连续打卡」，其余档是读过/读完/天数/笔记四宫格；
/// * 阅读时长分布柱状图（可点柱子切换下方的那句总结）；
/// * 阅读最久（封面 + 时长 + 可展开的前三）；
/// * 阅历 = 时长 / 笔记 / 连续天数三类里程碑的时间线。
class ReadingReportPage extends StatefulWidget {
  const ReadingReportPage({super.key, this.initialScope = ReportScope.week});

  final ReportScope initialScope;

  @override
  State<ReadingReportPage> createState() => _ReadingReportPageState();
}

class _ReadingReportPageState extends State<ReadingReportPage> {
  ReportScope _scope = ReportScope.week;
  DateTime _anchor = reportDay(DateTime.now());
  ReadingReport? _report;
  bool _loading = true;

  /// 原始聚合结果留着，批注异步读到后再拼一次报告，避免重算。
  Map<String, Map<String, double>> _bookDayMinutes = const {};
  List<ReadingBookMeta> _bookMeta = const [];
  bool _exporting = false;

  /// -1 表示「自动选中最长的那根柱子」。
  int _selectedBar = -1;
  bool _bookExpanded = false;
  bool _dailyExpanded = false;

  late final Listenable _historyChanges;
  late final Listenable _readTimeChanges;
  late final Listenable _statsChanges;
  Timer? _reloadTimer;

  @override
  void initState() {
    super.initState();
    _scope = widget.initialScope;
    _historyChanges = LibraryStore.instance.historyListenable
      ..addListener(_scheduleReload);
    _readTimeChanges = LibraryStore.instance.readTimeListenable
      ..addListener(_scheduleReload);
    _statsChanges = ReadingStatsStore.instance.changes
      ..addListener(_scheduleReload);
    unawaited(_load());
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    _historyChanges.removeListener(_scheduleReload);
    _readTimeChanges.removeListener(_scheduleReload);
    _statsChanges.removeListener(_scheduleReload);
    super.dispose();
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final store = LibraryStore.instance;
    final history = store.historySnapshot();
    final readTime = store.readTimeSnapshot();
    List<ShelfRecord> shelf = const [];
    try {
      shelf = ShelfStore.instance.records();
    } catch (_) {
      shelf = const [];
    }

    // 书名/封面的来源优先级：书架 > 历史（书架是用户主动收藏的，信息更全）。
    final metas = <String, ReadingBookMeta>{};
    for (final entry in history) {
      final id = historyStatisticsId(entry);
      if (id.isEmpty) continue;
      metas[id] = ReadingBookMeta(
        id: id,
        title: entry['title']?.toString() ?? id,
        cover: entry['cover']?.toString() ?? '',
        author: entry['author']?.toString() ?? '',
      );
    }
    for (final record in shelf) {
      metas[record.item.id] = ReadingBookMeta(
        id: record.item.id,
        title: record.item.title,
        cover: record.item.cover,
        author: record.item.author,
        finished: record.status == ShelfStatus.done,
      );
    }

    _bookDayMinutes = buildBookDayMinutes(
      history: history,
      readTimeSeconds: readTime,
    );
    _bookMeta = metas.values.toList();
    // 【青茄重构·修复】先出报告，批注（Hive 读盘）异步补齐。
    // 之前先 await loadAll 再 setState：盒子没开/读盘慢时整页一直转圈，
    // 真机冷启动和 widget 测试里都会卡在这一步。
    _applyNotes(const <ReaderAnnotation>[]);
    if (!mounted) return;
    setState(() => _loading = false);

    List<ReaderAnnotation> notes;
    try {
      notes = await ReaderAnnotationStore.instance.loadAll();
    } catch (_) {
      notes = const [];
    }
    if (!mounted || notes.isEmpty) return;
    _applyNotes(notes);
    setState(() {});
  }

  void _applyNotes(List<ReaderAnnotation> notes) {
    _report = ReadingReport(
      bookDayMinutes: _bookDayMinutes,
      books: _bookMeta,
      notes: [
        for (final note in notes)
          ReaderAnnotationSummary(
            createdAt: note.createdAt,
            bookTitle: note.bookTitle,
            type: note.type,
          ),
      ],
    );
  }

  // ---------- 期间 ----------

  ReportRange get _range =>
      reportRangeFor(_scope, _anchor) ??
      (_report ?? ReadingReport.empty).extent;

  bool get _canGoNext {
    if (!_scope.paged) return false;
    final next = reportRangeFor(_scope, shiftReportAnchor(_scope, _anchor, 1));
    if (next == null) return false;
    return next.start.isBefore(
      reportDay(DateTime.now()).add(const Duration(days: 1)),
    );
  }

  void _shift(int delta) {
    setState(() {
      _anchor = reportDay(shiftReportAnchor(_scope, _anchor, delta));
      _selectedBar = -1;
      _bookExpanded = false;
    });
  }

  void _switchScope(ReportScope scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      _anchor = reportDay(DateTime.now());
      _selectedBar = -1;
      _bookExpanded = false;
      _dailyExpanded = false;
    });
  }

  String get _periodLabel {
    final today = reportDay(DateTime.now());
    switch (_scope) {
      case ReportScope.week:
        final range = _range;
        final isCurrent = range.contains(today);
        final text =
            '${range.start.month}月${range.start.day}日 至 '
            '${range.end.month}月${range.end.day}日';
        return isCurrent ? '本周 $text' : text;
      case ReportScope.month:
        final range = _range;
        final isCurrent =
            today.year == range.start.year && today.month == range.start.month;
        final text = '${range.start.year}年${range.start.month}月';
        return isCurrent ? text : text;
      case ReportScope.year:
        return '${_range.start.year}年';
      case ReportScope.all:
        final extent = (_report ?? ReadingReport.empty).extent;
        return '${extent.start.year}年${extent.start.month}月 至 '
            '${extent.end.year}年${extent.end.month}月';
      case ReportScope.timeline:
        return '阅读阅历';
    }
  }

  /// 每日阅读只统计到今天：周 / 月档的期末若在未来，不把未来几天列成「--」。
  ReportRange get _dailyRange {
    final today = reportDay(DateTime.now());
    final end = _range.end.isAfter(today) ? today : _range.end;
    final start = _range.start.isAfter(end) ? end : _range.start;
    return ReportRange(start, end);
  }

  /// 已过去的天数（当期为「到今天为止」，往期为整期）。
  int _elapsedDays(ReportRange range) {
    final today = reportDay(DateTime.now());
    if (today.isBefore(range.start)) return range.dayCount;
    if (today.isAfter(range.end)) return range.dayCount;
    return today.difference(range.start).inDays + 1;
  }

  // ---------- 指标 ----------

  double _minutes(ReadingReport report) => report.minutesIn(_range);

  int _activeDays(ReadingReport report) => report.activeDaysIn(_range);

  List<({ReadingBookMeta book, double minutes})> _books(ReadingReport report) =>
      report.booksIn(_range);

  int _finishedCount(ReadingReport report) =>
      _books(report).where((entry) => entry.book.finished).length;

  int _noteCount(ReadingReport report) {
    if (_scope == ReportScope.all) return report.notes.length;
    final range = _range;
    var count = 0;
    for (final note in report.notes) {
      final day = DateTime.fromMillisecondsSinceEpoch(note.createdAt);
      if (range.contains(day)) count++;
    }
    return count;
  }

  /// 环比：只有周/月/年三档有意义，上一期为 0 时不给百分比（除零且没意义）。
  String? _comparisonText(ReadingReport report) {
    if (!_scope.paged && _scope != ReportScope.year) return null;
    final previousRange = reportRangeFor(
      _scope,
      shiftReportAnchor(_scope, _anchor, -1),
    );
    if (previousRange == null) return null;
    final previous = report.minutesIn(previousRange);
    if (previous <= 0) return null;
    final current = _minutes(report);
    final delta = (current - previous) / previous * 100;
    final direction = delta >= 0 ? '↑' : '↓';
    final label = switch (_scope) {
      ReportScope.week => '比上周',
      ReportScope.month => '比上月',
      _ => '比去年',
    };
    return '$label$direction${delta.abs().round()}%';
  }

  // ---------- 图表 ----------

  List<ReportBar> _bars(ReadingReport report) => report.barsFor(_scope, _range);

  /// X 轴刻度：31 根柱子时全label 会糊成一片，按 1/5/10… 抽稀。
  List<String?> _axisLabels(List<ReportBar> bars) {
    if (_scope == ReportScope.month) {
      return [
        for (var i = 0; i < bars.length; i++)
          (i == 0 || (i + 1) % 5 == 0) ? bars[i].label : null,
      ];
    }
    return [for (final bar in bars) bar.label];
  }

  int _topBarIndex(List<ReportBar> bars) {
    var best = 0;
    for (var i = 1; i < bars.length; i++) {
      if (bars[i].minutes > bars[best].minutes) best = i;
    }
    return best;
  }

  String _barLabel(ReportBar bar) => switch (_scope) {
    ReportScope.week => '周${bar.label}',
    ReportScope.month => '${bar.label}日',
    ReportScope.year => '${bar.label}月',
    ReportScope.all => bar.label,
    ReportScope.timeline => '',
  };

  String _pillText(List<ReportBar> bars) {
    if (bars.isEmpty) return '还没有阅读记录';
    final top = _topBarIndex(bars);
    final index = _selectedBar >= 0 && _selectedBar < bars.length
        ? _selectedBar
        : top;
    final bar = bars[index];
    final label = _barLabel(bar);
    if (bar.minutes <= 0) return '$label · 没有阅读记录';
    final suffix = index == top ? '阅读最久' : '';
    return '$label$suffix · ${formatReadingDuration(bar.minutes)}';
  }

  // ---------- 交互 ----------

  Future<void> _pickDate() async {
    final today = reportDay(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor.isAfter(today) ? today : _anchor,
      firstDate: DateTime(2000),
      lastDate: today,
      helpText: '选择要查看的日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _anchor = reportDay(picked);
      _selectedBar = -1;
      _bookExpanded = false;
    });
  }

  Future<void> _export(ReadingReport report) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final path = await ReadingReportExporter.export(
        periodLabel: _periodLabel,
        minutes: _minutes(report),
        averageMinutes: _minutes(report) / math.max(1, _elapsedDays(_range)),
        activeDays: _activeDays(report),
        noteCount: _noteCount(report),
        finishedCount: _finishedCount(report),
        bars: _bars(report),
        barLabels: _axisLabels(_bars(report)),
        topBooks: [
          for (final entry in _books(report).take(2))
            (title: entry.book.title, minutes: entry.minutes),
        ],
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('阅读报告已保存：$path'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final report = _report;
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text('我的阅读', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            key: const ValueKey('reading-report-share'),
            tooltip: '保存阅读报告',
            onPressed: report == null || !report.hasData || _exporting
                ? null
                : () => unawaited(_export(report)),
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.share_2, size: 20),
          ),
        ],
      ),
      body: _loading || report == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 36),
              children: [
                _ScopeTabs(scope: _scope, onChanged: _switchScope),
                const SizedBox(height: 14),
                if (_scope == ReportScope.timeline)
                  _buildTimeline(report, palette)
                else ...[
                  _PeriodBar(
                    label: _periodLabel,
                    canGoNext: _canGoNext,
                    onPrevious: () => _shift(-1),
                    onNext: () => _shift(1),
                  ),
                  const SizedBox(height: 14),
                  _SummaryBlock(
                    minutes: _minutes(report),
                    averageMinutes:
                        _minutes(report) / math.max(1, _elapsedDays(_range)),
                    comparison: _comparisonText(report),
                  ),
                  const SizedBox(height: 16),
                  if (_scope == ReportScope.week)
                    _WeekStats(
                      activeDays: _activeDays(report),
                      streakDays: ReadingStatsStore.instance.currentStreakDays,
                    )
                  else
                    _MetricGrid(
                      readBooks: _books(report).length,
                      finishedBooks: _finishedCount(report),
                      activeDays: _activeDays(report),
                      notes: _noteCount(report),
                      onNotesTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const NotesPage(),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (_scope == ReportScope.week) ...[
                    _ChallengeCard(
                      activeDays: _activeDays(report),
                      onTap: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _ChartCard(
                    bars: _bars(report),
                    axisLabels: _axisLabels(_bars(report)),
                    selectedIndex: _selectedBar,
                    pillText: _pillText(_bars(report)),
                    onSelect: (index) => setState(() => _selectedBar = index),
                    onPickDate: _pickDate,
                  ),
                  const SizedBox(height: 12),
                  _DailyReadingCard(
                    days: report.dailyIn(
                      _dailyRange,
                      includeEmpty: _scope == ReportScope.week,
                    ),
                    totalMinutes: _minutes(report),
                    expanded: _dailyExpanded,
                    onToggle: () =>
                        setState(() => _dailyExpanded = !_dailyExpanded),
                  ),
                  const SizedBox(height: 12),
                  _TopBookCard(
                    entries: _books(report),
                    tag: switch (_scope) {
                      ReportScope.week => '本周阅读最久',
                      ReportScope.month => '本月阅读最久',
                      ReportScope.year => '今年阅读最久',
                      _ => '总阅读最久',
                    },
                    expanded: _bookExpanded,
                    onToggle: () =>
                        setState(() => _bookExpanded = !_bookExpanded),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '统计口径：进入阅读页后的停留时长，按天累计；'
                    '旧记录按每本 10 分钟估算。',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.6,
                      color: palette.muted,
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildTimeline(ReadingReport report, HomePalette palette) {
    final milestones = report.milestones();
    if (milestones.isEmpty) {
      return _EmptyState(
        title: '还没有值得纪念的节点',
        hint: '读满 1 小时、写下 10 条笔记、连续阅读 3 天…都会出现在这里',
        palette: palette,
      );
    }
    return Column(
      key: const ValueKey('reading-report-timeline'),
      children: [
        for (var i = 0; i < milestones.length; i++)
          _TimelineRow(
            milestone: milestones[i],
            first: i == 0,
            last: i == milestones.length - 1,
            palette: palette,
          ),
      ],
    );
  }
}

// ---------------- 顶部五档切换 ----------------

class _ScopeTabs extends StatelessWidget {
  const _ScopeTabs({required this.scope, required this.onChanged});

  final ReportScope scope;
  final ValueChanged<ReportScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    const scopes = [
      ReportScope.week,
      ReportScope.month,
      ReportScope.year,
      ReportScope.all,
      ReportScope.timeline,
    ];
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final item in scopes)
            Expanded(
              child: GestureDetector(
                key: ValueKey('reading-report-scope-${item.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(item),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: item == scope ? palette.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: item == scope
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: item == scope
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: item == scope ? palette.ink : palette.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- 期间切换 ----------------

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({
    required this.label,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
  });

  final String label;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
        ),
        _CircleArrow(
          key: const ValueKey('reading-report-prev'),
          icon: LucideIcons.chevron_left,
          onTap: onPrevious,
          palette: palette,
        ),
        const SizedBox(width: 6),
        _CircleArrow(
          key: const ValueKey('reading-report-next'),
          icon: LucideIcons.chevron_right,
          onTap: canGoNext ? onNext : null,
          palette: palette,
        ),
      ],
    );
  }
}

class _CircleArrow extends StatelessWidget {
  const _CircleArrow({
    super.key,
    required this.icon,
    required this.onTap,
    required this.palette,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? palette.line : palette.line.withValues(alpha: 0.4),
          ),
        ),
        child: Icon(
          icon,
          size: 14,
          color: enabled ? palette.ink : palette.muted.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

// ---------------- 大数字 ----------------

class _SummaryBlock extends StatelessWidget {
  const _SummaryBlock({
    required this.minutes,
    required this.averageMinutes,
    required this.comparison,
  });

  final double minutes;
  final double averageMinutes;
  final String? comparison;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final parts = readingDurationParts(minutes);
    final average = averageMinutes < 1
        ? '日均阅读小于 1 分钟'
        : '日均阅读 ${formatReadingDuration(averageMinutes)}';
    return Column(
      key: const ValueKey('reading-report-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 大数字在 320 宽 + 1.8 倍字号下会顶破一行（44×1.8 ≈ 79px 的字号），
        // 用 FittedBox 整体等比缩放：视觉层级不变，又不会溢出。
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                parts.value,
                style: TextStyle(
                  fontSize: 44,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  parts.unit,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              average,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
            if (comparison != null)
              Text(
                comparison!,
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------- 周档：天数 / 连续打卡 ----------------

class _WeekStats extends StatelessWidget {
  const _WeekStats({required this.activeDays, required this.streakDays});

  final int activeDays;
  final int streakDays;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      children: [
        Expanded(
          child: _StatCell(
            value: '$activeDays',
            unit: '天',
            label: '本周阅读',
            palette: palette,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCell(
            value: '$streakDays',
            unit: '天',
            label: '连续打卡',
            palette: palette,
            trailing: const Icon(
              LucideIcons.flame,
              size: 15,
              color: Color(0xFFE2603F),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.value,
    required this.unit,
    required this.label,
    required this.palette,
    this.trailing,
  });

  final String value;
  final String unit;
  final String label;
  final HomePalette palette;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 24,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Text(unit, style: TextStyle(fontSize: 12, color: palette.ink)),
              if (trailing != null) ...[const SizedBox(width: 4), trailing!],
            ],
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11.5, color: palette.muted)),
        ],
      ),
    );
  }
}

// ---------------- 月/年/总：四宫格 ----------------

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({
    required this.readBooks,
    required this.finishedBooks,
    required this.activeDays,
    required this.notes,
    required this.onNotesTap,
  });

  final int readBooks;
  final int finishedBooks;
  final int activeDays;
  final int notes;
  final VoidCallback onNotesTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final items =
        <({String value, String unit, String label, VoidCallback? onTap})>[
          (value: '$readBooks', unit: '本', label: '读过', onTap: null),
          (value: '$finishedBooks', unit: '本', label: '读完', onTap: null),
          (value: '$activeDays', unit: '天', label: '阅读天数', onTap: null),
          (
            value: '$notes',
            unit: '条',
            label: '笔记',
            onTap: notes > 0 ? onNotesTap : null,
          ),
        ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Wrap(
        children: [
          for (final item in items)
            FractionallySizedBox(
              widthFactor: 0.5,
              child: InkWell(
                onTap: item.onTap,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: item.value,
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: palette.ink,
                                ),
                              ),
                              TextSpan(
                                text: ' ${item.unit}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: palette.ink,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        item.label,
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                      if (item.onTap != null)
                        Icon(
                          LucideIcons.chevron_right,
                          size: 13,
                          color: palette.muted,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- 阅读挑战 ----------------

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({required this.activeDays, required this.onTap});

  final int activeDays;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final goal = 7;
    final progress = (activeDays / goal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: HomePalette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  LucideIcons.trophy,
                  size: 16,
                  color: Color(0xFFE2603F),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '阅读挑战',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      activeDays >= goal
                          ? '本周目标已完成，继续保持'
                          : '每周读满 $goal 天，养成阅读习惯',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accentText,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  activeDays >= goal ? '已完成' : '去阅读',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: palette.soft,
              valueColor: AlwaysStoppedAnimation<Color>(palette.accentText),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本周已读 $activeDays / $goal 天',
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
        ],
      ),
    );
  }
}

// ---------------- 柱状图 ----------------

// ---------------- 每日阅读 ----------------

/// 按天列出阅读时长，是「我的」页原「每日记录」卡片的唯一实现。
///
/// 口径与热力图、柱状图完全一致（都来自 `ReadingReport.dayMinutes`），
/// 只是把「哪天读了多久」摊开成可读的列表：周档补齐 0 分钟的天，让一周
/// 七天的节奏看得出来；年 / 总档只列出真正读过的日子，免得刷出三百行空白。
class _DailyReadingCard extends StatelessWidget {
  const _DailyReadingCard({
    required this.days,
    required this.totalMinutes,
    required this.expanded,
    required this.onToggle,
  });

  final List<({DateTime day, double minutes})> days;
  final double totalMinutes;
  final bool expanded;
  final VoidCallback onToggle;

  /// 折叠时最多显示的条数，再长就交给「展开全部」。
  static const _collapsedRows = 14;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 最近的一天放最上面：折叠时看到的一定是最近的记录。
    final sorted = [...days]..sort((a, b) => b.day.compareTo(a.day));
    final visible = expanded || sorted.length <= _collapsedRows
        ? sorted
        : sorted.take(_collapsedRows).toList();
    final peak = sorted.fold<double>(
      0,
      (best, row) => math.max(best, row.minutes),
    );

    return Container(
      key: const ValueKey('reading-report-daily'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '每日阅读',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
              ),
              if (totalMinutes > 0)
                Text(
                  '共 ${formatReadingDuration(totalMinutes)}',
                  style: TextStyle(fontSize: 11.5, color: palette.muted),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '这段时间还没有阅读记录',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            )
          else ...[
            for (final row in visible)
              _DailyReadingRow(
                key: ValueKey(
                  'reading-report-daily-row-${reportDayKey(row.day)}',
                ),
                row: row,
                peak: peak,
                palette: palette,
              ),
            if (sorted.length > _collapsedRows)
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  key: const ValueKey('reading-report-daily-toggle'),
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: palette.accentText,
                  ),
                  child: Text(
                    expanded ? '收起' : '展开全部（共 ${sorted.length} 天）',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 每日阅读的一行：日期 + 相对条 + 时长。时长条以区间内最高的一天为满格。
class _DailyReadingRow extends StatelessWidget {
  const _DailyReadingRow({
    super.key,
    required this.row,
    required this.peak,
    required this.palette,
  });

  final ({DateTime day, double minutes}) row;
  final double peak;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    final minutes = row.minutes;
    final active = minutes > 0;
    final ratio = peak <= 0 ? 0.0 : (minutes / peak).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              '${row.day.month}月${row.day.day}日 ${reportDayLabel(row.day)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: active ? palette.ink : palette.muted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SizedBox(
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: palette.line)),
                      if (active)
                        SizedBox(
                          width: constraints.maxWidth * ratio,
                          height: 6,
                          child: ColoredBox(color: palette.accentText),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            // 系统字号被调大时「5小时16分钟」会超出 92pt：等比缩小，
            // 不加省略号——时长被截成「5小时16…」等于没显示。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                active ? formatReadingDuration(minutes) : '--',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? palette.ink : palette.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.bars,
    required this.axisLabels,
    required this.selectedIndex,
    required this.pillText,
    required this.onSelect,
    required this.onPickDate,
  });

  final List<ReportBar> bars;
  final List<String?> axisLabels;
  final int selectedIndex;
  final String pillText;
  final ValueChanged<int> onSelect;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '阅读时长分布',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('reading-report-calendar'),
                tooltip: '按日期查看',
                visualDensity: VisualDensity.compact,
                onPressed: onPickDate,
                icon: Icon(
                  LucideIcons.calendar_days,
                  size: 17,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (bars.isEmpty)
            SizedBox(
              height: 120,
              child: Center(
                child: Text(
                  '还没有阅读记录',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ),
            )
          else
            _BarChart(
              bars: bars,
              axisLabels: axisLabels,
              selectedIndex: selectedIndex,
              onSelect: onSelect,
            ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.accentText.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              pillText,
              style: TextStyle(
                fontSize: 11.5,
                color: palette.accentText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.bars,
    required this.axisLabels,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<ReportBar> bars;
  final List<String?> axisLabels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  static double _niceMax(double max) {
    if (max <= 0) return 10;
    const candidates = [
      10,
      15,
      20,
      30,
      45,
      60,
      90,
      120,
      180,
      240,
      300,
      450,
      600,
      900,
      1200,
      1800,
      2400,
      3600,
    ];
    for (final candidate in candidates) {
      if (max <= candidate) return candidate.toDouble();
    }
    return (max / 3600).ceil() * 3600.0;
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    var maxMinutes = 0.0;
    for (final bar in bars) {
      maxMinutes = math.max(maxMinutes, bar.minutes);
    }
    final axisMax = _niceMax(maxMinutes);
    var top = 0;
    for (var i = 1; i < bars.length; i++) {
      if (bars[i].minutes > bars[top].minutes) top = i;
    }
    final active = selectedIndex >= 0 && selectedIndex < bars.length
        ? selectedIndex
        : top;
    final barWidthFactor = bars.length <= 8 ? 0.46 : 0.72;
    final axisText = axisMax >= 60
        ? '${(axisMax / 60).round()}h'
        : '${axisMax.round()}m';

    return SizedBox(
      key: const ValueKey('reading-report-chart'),
      height: 158,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  right: 26,
                  child: CustomPaint(
                    painter: _GridPainter(color: palette.line),
                  ),
                ),
                // Y 轴只给首尾两个刻度，和参考图一致。
                Positioned(
                  top: -2,
                  right: 0,
                  child: Text(
                    axisText,
                    style: TextStyle(fontSize: 9.5, color: palette.muted),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Text(
                    '0',
                    style: TextStyle(fontSize: 9.5, color: palette.muted),
                  ),
                ),
                Positioned.fill(
                  right: 22,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < bars.length; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onSelect(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 1.2,
                              ),
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  widthFactor: barWidthFactor,
                                  heightFactor: bars[i].minutes <= 0
                                      ? 0
                                      : (bars[i].minutes / axisMax).clamp(
                                          0.02,
                                          1.0,
                                        ),
                                  alignment: Alignment.bottomCenter,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: i == active
                                          ? palette.accentText
                                          : palette.accentText.withValues(
                                              alpha: 0.28,
                                            ),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4),
                                        bottom: Radius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 22),
            child: Row(
              children: [
                for (var i = 0; i < bars.length; i++)
                  Expanded(
                    child: Text(
                      axisLabels.length > i ? (axisLabels[i] ?? '') : '',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.1,
                        color: palette.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.8;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), paint);
        x += 6;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ---------------- 阅读最久 ----------------

class _TopBookCard extends StatelessWidget {
  const _TopBookCard({
    required this.entries,
    required this.tag,
    required this.expanded,
    required this.onToggle,
  });

  final List<({ReadingBookMeta book, double minutes})> entries;
  final String tag;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final top = entries.isEmpty ? null : entries.first;
    return Container(
      key: const ValueKey('reading-report-top-book'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '阅读最久',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
              ),
              if (entries.length > 1)
                GestureDetector(
                  onTap: onToggle,
                  behavior: HitTestBehavior.opaque,
                  child: Icon(
                    expanded
                        ? LucideIcons.chevron_up
                        : LucideIcons.chevron_down,
                    size: 16,
                    color: palette.muted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (top == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '这一段时间还没有阅读记录',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BookThumb(
                  url: top.book.cover,
                  width: 46,
                  height: 62,
                  iconSize: 18,
                  backgroundColor: palette.soft,
                  iconColor: palette.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        top.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                      if (top.book.author.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          top.book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: palette.accentText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatReadingDuration(top.minutes),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '单本累计',
                      style: TextStyle(fontSize: 10, color: palette.muted),
                    ),
                  ],
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
              Divider(height: 1, color: palette.line),
              for (final entry in entries.skip(1).take(3))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: palette.ink),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatReadingDuration(entry.minutes),
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

// ---------------- 阅历时间线 ----------------

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.milestone,
    required this.first,
    required this.last,
    required this.palette,
  });

  final ReportMilestone milestone;
  final bool first;
  final bool last;
  final HomePalette palette;

  static const _months = [
    'JANUARY',
    'FEBRUARY',
    'MARCH',
    'APRIL',
    'MAY',
    'JUNE',
    'JULY',
    'AUGUST',
    'SEPTEMBER',
    'OCTOBER',
    'NOVEMBER',
    'DECEMBER',
  ];

  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    final day = milestone.day;
    // IntrinsicHeight：左侧时间线要和卡片等高。直接 stretch 在 ListView 里
    // 会拿到无限高度约束（BoxConstraints forces an infinite height）。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: CustomPaint(
              painter: _RailPainter(
                color: palette.line,
                dotColor: palette.accentText,
                first: first,
                last: last,
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.line, width: 0.6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 40,
                      height: 0.95,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _months[day.month - 1],
                    style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w500,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${day.month}月${day.day}日 · ${_weekdays[day.weekday - 1]}',
                    style: TextStyle(fontSize: 10.5, color: palette.muted),
                  ),
                  const SizedBox(height: 14),
                  Container(width: 28, height: 1, color: palette.line),
                  const SizedBox(height: 12),
                  Text(
                    milestone.headline,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    milestone.detail,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      color: palette.ink.withValues(alpha: 0.78),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  const _RailPainter({
    required this.color,
    required this.dotColor,
    required this.first,
    required this.last,
  });

  final Color color;
  final Color dotColor;
  final bool first;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    // 竖线：第一张从圆点往下画，最后一张画到圆点为止。
    final top = first ? 26.0 : 0.0;
    final bottom = last ? 26.0 : size.height;
    var y = top;
    while (y < bottom) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3, bottom)), paint);
      y += 7;
    }
    canvas.drawCircle(Offset(x, 26), 3.4, Paint()..color = dotColor);
    canvas.drawCircle(
      Offset(x, 26),
      6.4,
      Paint()..color = dotColor.withValues(alpha: 0.18),
    );
  }

  @override
  bool shouldRepaint(covariant _RailPainter oldDelegate) =>
      oldDelegate.first != first ||
      oldDelegate.last != last ||
      oldDelegate.color != color ||
      oldDelegate.dotColor != dotColor;
}

// ---------------- 空状态 ----------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.hint,
    required this.palette,
  });

  final String title;
  final String hint;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        children: [
          Icon(LucideIcons.sparkles, size: 28, color: palette.muted),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: palette.muted),
          ),
        ],
      ),
    );
  }
}
