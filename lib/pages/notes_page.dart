import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/curated_book.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/curated_resolver.dart';
import '../services/detail_snapshot_cache.dart';
import '../services/imported_book_store.dart';
import '../services/library_store.dart';
import '../services/note_card_exporter.dart';
import '../services/note_timeline.dart';
import '../services/reader_annotation_store.dart';
import '../services/reader_mark_style.dart';
import '../services/reader_marker_type_store.dart';
import '../services/reader_underline_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/reader/reader_note_block.dart';
import 'reader_page.dart';

@immutable
class _BookOption {
  const _BookOption(this.id, this.title);
  final String id;
  final String title;
}

enum _NotesViewMode { timeline, books, marks }

/// 划线视图里「只看向下划线 / 只看荧光笔」的二级切换。
enum _MarkStyleFilter { all, underline, highlighter }

/// 一条划线记录在笔记页里的展示形态。
///
/// 两种历史形态统一成一个视图模型：范围划线带文字偏移（可以直接跳到那句），
/// 早期的整段划线只有段落序号，跳转时落到章首。
@immutable
class _MarkEntry {
  const _MarkEntry({
    required this.bookId,
    required this.bookTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.text,
    required this.style,
    required this.colorValue,
    required this.createdAt,
    this.startOffset,
    this.blockIndex,
  });

  final String bookId;
  final String bookTitle;
  final String chapterId;
  final String chapterTitle;
  final String text;
  final ReaderMarkStyle style;
  final int colorValue;
  final int createdAt;
  final int? startOffset;
  final int? blockIndex;

  bool get isHighlighter => style == ReaderMarkStyle.highlighter;

  String get key =>
      '$bookId|$chapterId|${startOffset ?? 'b$blockIndex'}|${style.storageValue}';
}

@immutable
class _BookNotesGroup {
  const _BookNotesGroup({
    required this.id,
    required this.title,
    required this.notes,
  });

  final String id;
  final String title;

  /// Newest first, matching the timeline ordering.
  final List<ReaderAnnotation> notes;

  int get annotCount => notes.where((note) => note.isAnnot).length;
  int get excerptCount => notes.length - annotCount;
  int get chapterCount => notes.map((note) => note.chapterId).toSet().length;
  int get latestAt => notes.isEmpty ? 0 : notes.first.createdAt;
}

/// 笔记页：按时间轴回顾批注与书摘，也可以按书分组查看，并支持
/// 书籍/时间/分类/标签组合筛选。
class NotesPage extends StatefulWidget {
  const NotesPage({super.key, this.store, this.underlineStore});

  final ReaderAnnotationStore? store;

  /// 测试注入用；默认走全局划线存储。
  final ReaderUnderlineStore? underlineStore;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  ReaderAnnotationStore get _store =>
      widget.store ?? ReaderAnnotationStore.instance;

  List<ReaderAnnotation> _all = const [];
  NoteTimelineFilters _filters = const NoteTimelineFilters();
  NoteTypeFilter _type = NoteTypeFilter.all;
  _NotesViewMode _viewMode = _NotesViewMode.timeline;
  bool _loading = true;
  bool _exporting = false;

  /// 用户自定义过的批注类型（内置四个预设不在这里）。
  List<ReaderMarkerType> _customMarkerTypes = const [];

  /// 划线 / 荧光笔记录，以及按书过滤当前划线视图的选择。
  List<_MarkEntry> _marks = const [];
  String? _markBookId;
  _MarkStyleFilter _markFilter = _MarkStyleFilter.all;

  /// bookId → 封面地址：封面来自阅读历史，缺失时用同目录的几何封面兜底。
  Map<String, String> _covers = const {};

  /// 书单解析缓存里的书名，用于补「未知书籍」的划线记录。
  Map<String, String> _bookTitles = const {};

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final entries = await _store.loadAll();
    final underlineStore =
        widget.underlineStore ?? ReaderUnderlineStore.instance;
    final ranges = await underlineStore.loadAllRanges();
    final paragraphs = await underlineStore.loadAllParagraphs();
    await ReaderMarkerTypeStore.instance.load();
    final meta = _loadBookMeta();
    if (!mounted) return;
    setState(() {
      _all = entries;
      _customMarkerTypes = ReaderMarkerTypeStore.instance.types;
      _covers = meta.covers;
      _bookTitles = meta.titles;
      _marks = _buildMarks(ranges, paragraphs, entries, meta.titles);
      _loading = false;
    });
  }

  /// 书名和封面只在本地查，不发网络请求：查不到的书用几何封面兜底。
  ///
  /// 用同步快照而不是 `history()`：笔记页可能在 Hive 还没就绪时构建（widget
  /// 测试、冷启动首帧），等一个永远不完成的 open 会把整页卡在加载态。
  ({Map<String, String> covers, Map<String, String> titles}) _loadBookMeta() {
    final covers = <String, String>{};
    final titles = <String, String>{};
    try {
      for (final entry in LibraryStore.instance.historySnapshot()) {
        final id = entry['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final cover = entry['cover']?.toString() ?? '';
        final title = entry['title']?.toString() ?? '';
        if (cover.isNotEmpty) covers.putIfAbsent(id, () => cover);
        if (title.isNotEmpty) titles.putIfAbsent(id, () => title);
      }
    } catch (_) {
      // 历史读不出来时只是少了真实封面，不影响笔记本身。
    }
    // 首页书单解析过的书（如《小王子》）带着上游 id，正好能补上封面和书名。
    try {
      for (final book in CuratedLibrary.current.books) {
        final resolved = CuratedResolver.instance.cached(book.id);
        if (resolved == null || resolved.id.isEmpty) continue;
        if (resolved.cover.isNotEmpty) {
          covers.putIfAbsent(resolved.id, () => resolved.cover);
        }
        if (resolved.title.isNotEmpty) {
          titles.putIfAbsent(resolved.id, () => resolved.title);
        }
      }
    } catch (_) {
      // 书单未加载时跳过即可。
    }
    return (covers: covers, titles: titles);
  }

  /// 把两种划线记录合并成一条按时间倒序的列表，并尽量补上章节名。
  List<_MarkEntry> _buildMarks(
    List<ReaderRangeUnderline> ranges,
    List<ReaderUnderline> paragraphs,
    List<ReaderAnnotation> notes,
    Map<String, String> knownTitles,
  ) {
    final bookTitles = <String, String>{...knownTitles};
    for (final note in notes) {
      final title = note.bookTitle.trim();
      if (title.isNotEmpty) bookTitles.putIfAbsent(note.bookId, () => title);
    }
    final chapterTitles = <String, Map<String, String>>{};
    String bookTitleOf(String bookId) => bookTitles[bookId] ?? '未知书籍';
    String chapterTitleOf(String bookId, String chapterId) {
      final cached = chapterTitles[bookId] ??= {
        for (final chapter
            in DetailSnapshotCache.instance.read(bookId)?.chapters ??
                const <Chapter>[])
          chapter.itemId: chapter.title,
      };
      return cached[chapterId] ?? '';
    }

    final entries = <_MarkEntry>[
      for (final mark in ranges)
        _MarkEntry(
          bookId: mark.bookId,
          bookTitle: bookTitleOf(mark.bookId),
          chapterId: mark.chapterId,
          chapterTitle: chapterTitleOf(mark.bookId, mark.chapterId),
          text: mark.text,
          style: mark.style,
          colorValue: mark.colorValue,
          createdAt: mark.createdAt,
          startOffset: mark.start,
        ),
      for (final mark in paragraphs)
        _MarkEntry(
          bookId: mark.bookId,
          bookTitle: bookTitleOf(mark.bookId),
          chapterId: mark.chapterId,
          chapterTitle: chapterTitleOf(mark.bookId, mark.chapterId),
          text: mark.text,
          style: mark.style,
          colorValue: mark.colorValue,
          createdAt: mark.createdAt,
          blockIndex: mark.blockIndex,
        ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(entries);
  }

  /// 笔记里出现过的所有批注类型：内置预设 + 用户自定义 + 已落在笔记上的。
  List<ReaderMarkerType> get _markerCatalog {
    final observed = <ReaderMarkerType>[];
    for (final note in _all) {
      if (!note.isAnnot) continue;
      final label = note.displayMarkerLabel.trim();
      if (label.isEmpty || observed.any((type) => type.key == label)) {
        continue;
      }
      observed.add(
        ReaderMarkerType(
          label: label,
          colorValue: note.effectiveMarkerColorValue,
        ),
      );
    }
    return ReaderMarkerTypeStore.catalog([..._customMarkerTypes, ...observed]);
  }

  List<ReaderAnnotation> get _visible {
    return filterNoteTimeline(_all, _filters, type: _type);
  }

  /// 按书浏览时忽略单书筛选，但保留时间、分类、标签和批注/书摘条件。
  List<ReaderAnnotation> get _bookViewNotes {
    return filterNoteTimeline(
      _all,
      NoteTimelineFilters(
        category: _filters.category,
        tags: _filters.tags,
        timePreset: _filters.timePreset,
        customRange: _filters.customRange,
      ),
      type: _type,
    );
  }

  List<_BookNotesGroup> get _bookGroups {
    final grouped = <String, List<ReaderAnnotation>>{};
    for (final note in _bookViewNotes) {
      (grouped[note.bookId] ??= <ReaderAnnotation>[]).add(note);
    }
    final groups = [
      for (final entry in grouped.entries)
        _BookNotesGroup(
          id: entry.key,
          title: _titleOf(entry.key, entry.value.first.bookTitle),
          notes: List.unmodifiable(entry.value),
        ),
    ];
    groups.sort((a, b) {
      if (a.latestAt <= 0 && b.latestAt > 0) return 1;
      if (b.latestAt <= 0 && a.latestAt > 0) return -1;
      final byTime = b.latestAt.compareTo(a.latestAt);
      return byTime != 0 ? byTime : a.title.compareTo(b.title);
    });
    return groups;
  }

  void _setViewMode(_NotesViewMode mode) {
    if (_viewMode == mode) return;
    setState(() {
      _viewMode = mode;
      // 「按书」本身就是书籍维度；清掉单书筛选，才能看到所有书。
      if (mode == _NotesViewMode.books && _filters.bookId != null) {
        _filters = _filters.without(bookId: true);
      }
    });
  }

  void _openBookNotes(_BookNotesGroup group) {
    setState(() {
      _filters = _filters.copyWith(bookId: group.id);
      _viewMode = _NotesViewMode.timeline;
    });
  }

  int get _annotCount => _all.where((e) => e.isAnnot).length;
  int get _excerptCount => _all.length - _annotCount;

  /// 书名优先用笔记里记下的，其次是阅读历史/书单缓存里的。
  String _titleOf(String bookId, String fallback) {
    final own = fallback.trim();
    if (own.isNotEmpty) return own;
    final known = _bookTitles[bookId]?.trim() ?? '';
    return known.isEmpty ? '未知书籍' : known;
  }

  List<_BookOption> get _books {
    final seen = <String>{};
    final result = <_BookOption>[];
    for (final note in _all) {
      if (seen.add(note.bookId)) {
        result.add(
          _BookOption(note.bookId, _titleOf(note.bookId, note.bookTitle)),
        );
      }
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return result;
  }

  List<String> get _categories {
    final values = <String>{};
    for (final note in _all) {
      final value = note.category.trim();
      if (value.isNotEmpty) values.add(value);
    }
    final sorted = values.toList()..sort();
    return sorted;
  }

  List<String> get _tags {
    final values = <String>{};
    for (final note in _all) {
      values.addAll(note.tags);
    }
    final sorted = values.toList()..sort();
    return sorted;
  }

  /// 当前划线视图的数据：先按书、再按「划线 / 荧光笔」过滤。
  List<_MarkEntry> get _visibleMarks => [
    for (final mark in _marks)
      if ((_markBookId == null || mark.bookId == _markBookId) &&
          switch (_markFilter) {
            _MarkStyleFilter.all => true,
            _MarkStyleFilter.underline => !mark.isHighlighter,
            _MarkStyleFilter.highlighter => mark.isHighlighter,
          })
        mark,
  ];

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final visible = _visible;
    final groups = _viewMode == _NotesViewMode.books
        ? _bookGroups
        : const <_BookNotesGroup>[];
    final marks = _viewMode == _NotesViewMode.marks
        ? _visibleMarks
        : const <_MarkEntry>[];
    final exportNotes = switch (_viewMode) {
      _NotesViewMode.timeline => visible,
      _NotesViewMode.books => _bookViewNotes,
      _NotesViewMode.marks => const <ReaderAnnotation>[],
    };
    final hasContent = switch (_viewMode) {
      _NotesViewMode.books => groups.isNotEmpty,
      _NotesViewMode.marks => marks.isNotEmpty,
      _NotesViewMode.timeline => visible.isNotEmpty,
    };
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('笔记'),
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            key: const Key('notes-export-button'),
            tooltip: '导出当前筛选为长图',
            icon: const Icon(LucideIcons.image_down),
            onPressed: exportNotes.isEmpty || _exporting ? null : _exportImage,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildViewSwitch(palette),
          _buildQuickFilters(palette),
          if (_filters.isActive && _viewMode != _NotesViewMode.marks)
            _buildActiveSummary(palette),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : !hasContent
                ? _buildEmpty(palette)
                : switch (_viewMode) {
                    _NotesViewMode.books => _buildBookGrid(groups),
                    _NotesViewMode.marks => _buildMarkList(palette, marks),
                    _NotesViewMode.timeline => ListView.builder(
                      key: const ValueKey('notes-timeline'),
                      padding: const EdgeInsets.fromLTRB(12, 4, 16, 32),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final note = visible[index];
                        final previous = index == 0 ? null : visible[index - 1];
                        final next = index + 1 >= visible.length
                            ? null
                            : visible[index + 1];
                        return _TimelineNoteRow(
                          key: ValueKey('note-timeline-${note.key}'),
                          note: note,
                          bookTitle: _titleOf(note.bookId, note.bookTitle),
                          firstOfDay:
                              previous == null ||
                              !_sameDay(previous.createdAt, note.createdAt),
                          lastOfDay:
                              next == null ||
                              !_sameDay(next.createdAt, note.createdAt),
                          onOpen: _openNote,
                          onEdit: _editNote,
                        );
                      },
                    ),
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildViewSwitch(HomePalette palette) {
    Widget tab(_NotesViewMode mode, String label, IconData icon) {
      final selected = _viewMode == mode;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('notes-view-${mode.name}'),
          onTap: () => _setViewMode(mode),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: selected ? palette.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 5,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: selected ? palette.accentText : palette.muted,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? palette.accentText : palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            tab(_NotesViewMode.timeline, '时间线', LucideIcons.list),
            tab(_NotesViewMode.books, '按书查看', LucideIcons.book_open),
            tab(_NotesViewMode.marks, '划线', LucideIcons.highlighter),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickFilters(HomePalette palette) {
    if (_viewMode == _NotesViewMode.marks) return _buildMarkFilters(palette);
    Widget chip(NoteTypeFilter type, String label, int count) {
      final active = _type == type;
      return Padding(
        padding: const EdgeInsets.only(right: 7),
        child: ChoiceChip(
          key: ValueKey('notes-type-${type.name}'),
          selected: active,
          showCheckmark: false,
          label: Text('$label $count'),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: active ? palette.accentText : palette.muted,
          ),
          selectedColor: palette.chipSelectedFill,
          backgroundColor: palette.chipFill,
          side: palette.chipBorder(active),
          onSelected: (_) => setState(() => _type = type),
        ),
      );
    }

    final markers = _markerCatalog;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      chip(NoteTypeFilter.all, '全部', _all.length),
                      chip(NoteTypeFilter.annot, '批注', _annotCount),
                      chip(NoteTypeFilter.excerpt, '书摘', _excerptCount),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('notes-filter-button'),
                    onPressed: _openFilters,
                    icon: const Icon(LucideIcons.sliders_horizontal, size: 16),
                    label: const Text('筛选'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: _filters.isActive
                          ? palette.accentText
                          : palette.muted,
                      side: BorderSide(
                        color: _filters.isActive
                            ? palette.accentText
                            : palette.line,
                      ),
                    ),
                  ),
                  if (_filters.activeDimensions > 0)
                    Positioned(
                      right: -6,
                      top: -7,
                      child: Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: HomePalette.accent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${_filters.activeDimensions}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        // 批注类型：内置四种 + 用户自定义的，直接按类型挑，不必进筛选面板。
        SizedBox(
          // ChoiceChip 在 MaterialTapTargetSize.padded 下自带 48dp 命中区，
          // 原来的 40dp 行高既压扁了 chip，也让点击带不足 48dp。
          height: markers.isEmpty ? 6 : 48,
          child: markers.isEmpty
              ? null
              : ListView(
                  key: const ValueKey('notes-marker-types'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                  children: [
                    _markerTypeChip(palette, null, '全部类型'),
                    for (final type in markers)
                      _markerTypeChip(palette, type, type.label),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _markerTypeChip(
    HomePalette palette,
    ReaderMarkerType? type,
    String label,
  ) {
    final active = _filters.markerKey == type?.key;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('notes-marker-${type?.key ?? 'all'}'),
        showCheckmark: false,
        selected: active,
        avatar: type == null
            ? null
            : CircleAvatar(radius: 5, backgroundColor: Color(type.colorValue)),
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: active ? palette.accentText : palette.muted,
        ),
        selectedColor: palette.chipSelectedFill,
        backgroundColor: palette.chipFill,
        side: palette.chipBorder(active),
        onSelected: (_) => setState(() {
          _filters = type == null
              ? _filters.without(marker: true)
              : _filters.copyWith(markerKey: type.key);
        }),
      ),
    );
  }

  /// 划线视图的顶部：先分线型，再按书收窄。
  Widget _buildMarkFilters(HomePalette palette) {
    int countOf(_MarkStyleFilter filter) => switch (filter) {
      _MarkStyleFilter.all => _marks.length,
      _MarkStyleFilter.underline =>
        _marks.where((mark) => !mark.isHighlighter).length,
      _MarkStyleFilter.highlighter =>
        _marks.where((mark) => mark.isHighlighter).length,
    };
    Widget styleChip(_MarkStyleFilter filter, String label) {
      final active = _markFilter == filter;
      return Padding(
        padding: const EdgeInsets.only(right: 7),
        child: ChoiceChip(
          key: ValueKey('notes-marks-${filter.name}'),
          showCheckmark: false,
          selected: active,
          label: Text('$label ${countOf(filter)}'),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: active ? palette.accentText : palette.muted,
          ),
          selectedColor: palette.chipSelectedFill,
          backgroundColor: palette.chipFill,
          side: palette.chipBorder(active),
          onSelected: (_) => setState(() => _markFilter = filter),
        ),
      );
    }

    final bookIds = <String>[];
    final bookTitles = <String, String>{};
    for (final mark in _marks) {
      if (bookTitles.containsKey(mark.bookId)) continue;
      bookTitles[mark.bookId] = mark.bookTitle;
      bookIds.add(mark.bookId);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                styleChip(_MarkStyleFilter.all, '全部'),
                styleChip(_MarkStyleFilter.underline, '划线'),
                styleChip(_MarkStyleFilter.highlighter, '荧光笔'),
              ],
            ),
          ),
        ),
        SizedBox(
          height: bookIds.length <= 1 ? 8 : 38,
          child: bookIds.length <= 1
              ? null
              : ListView(
                  key: const ValueKey('notes-marks-books'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 5, 12, 2),
                  children: [
                    _markBookChip(palette, null, '全部书籍'),
                    for (final id in bookIds)
                      _markBookChip(palette, id, bookTitles[id] ?? '未知书籍'),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _markBookChip(HomePalette palette, String? bookId, String label) {
    final active = _markBookId == bookId;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('notes-marks-book-${bookId ?? 'all'}'),
        showCheckmark: false,
        selected: active,
        label: Text(label, overflow: TextOverflow.ellipsis),
        labelStyle: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: active ? palette.accentText : palette.muted,
        ),
        selectedColor: palette.chipSelectedFill,
        backgroundColor: palette.chipFill,
        side: palette.chipBorder(active),
        onSelected: (_) => setState(() => _markBookId = bookId),
      ),
    );
  }

  Widget _buildBookGrid(List<_BookNotesGroup> groups) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final cellWidth = homeCardWidth(context, width);
      return GridView.builder(
        key: const ValueKey('notes-books'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        gridDelegate: homeGridDelegate(context, width),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return _BookNotesCard(
            key: ValueKey('notes-book-${group.id}'),
            group: group,
            cover: _covers[group.id] ?? '',
            coverWidth: cellWidth,
            onTap: () => _openBookNotes(group),
          );
        },
      );
    },
  );

  Widget _buildMarkList(HomePalette palette, List<_MarkEntry> marks) =>
      ListView.separated(
        key: const ValueKey('notes-marks'),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        itemCount: marks.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _MarkRow(
          key: ValueKey('mark-row-${marks[index].key}'),
          entry: marks[index],
          onTap: () => _openMark(marks[index]),
        ),
      );

  Widget _buildActiveSummary(HomePalette palette) {
    final labels = <(String, VoidCallback)>[];
    if (_filters.bookId != null) {
      final title = _books
          .where((book) => book.id == _filters.bookId)
          .map((book) => book.title)
          .firstOrNull;
      labels.add((
        '书：${title ?? '未知书籍'}',
        () => setState(() => _filters = _filters.without(bookId: true)),
      ));
    }
    if (_filters.timePreset != NoteTimePreset.all) {
      final range = _filters.resolveRange(DateTime.now());
      labels.add((
        '时间：${range == null ? '不限' : _rangeLabel(range)}',
        () => setState(() => _filters = _filters.without(time: true)),
      ));
    }
    if (_filters.category != null) {
      labels.add((
        '分类：${_filters.category == noteUncategorizedFilter ? '未分类' : _filters.category}',
        () => setState(() => _filters = _filters.without(category: true)),
      ));
    }
    if (_filters.tags.isNotEmpty) {
      labels.add((
        '标签：${_filters.tags.join(' / ')}',
        () => setState(() => _filters = _filters.without(tags: true)),
      ));
    }
    if (_filters.markerKey != null) {
      labels.add((
        '类型：${_filters.markerKey}',
        () => setState(() => _filters = _filters.without(marker: true)),
      ));
    }
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 12, 4),
        children: [
          for (final entry in labels)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                label: Text(entry.$1),
                onDeleted: entry.$2,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ActionChip(
            key: const ValueKey('notes-filter-clear'),
            label: const Text('清除'),
            onPressed: () =>
                setState(() => _filters = const NoteTimelineFilters()),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(HomePalette palette) {
    final filtered = _filters.isActive || _type != NoteTypeFilter.all;
    final (String title, String hint, IconData icon) = switch (_viewMode) {
      _NotesViewMode.books => (
        '没有可查看的书籍',
        '写过的书会按最近笔记时间排列',
        LucideIcons.book_open,
      ),
      _NotesViewMode.marks => (
        _markFilter == _MarkStyleFilter.all && _markBookId == null
            ? '还没有划线'
            : '没有符合条件的划线',
        '阅读时选中一句 → 划线 / 荧光笔，这里就会收进来',
        LucideIcons.highlighter,
      ),
      _NotesViewMode.timeline => (
        filtered ? '没有符合筛选条件的笔记' : '还没有笔记',
        filtered ? '可调整书籍、时间、类型、分类或标签' : '阅读时长按选中句子 → 批注 / 书摘',
        LucideIcons.pen_line,
      ),
    };
    final clearable = _viewMode == _NotesViewMode.marks
        ? _markFilter != _MarkStyleFilter.all || _markBookId != null
        : filtered;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: palette.line),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontSize: 14, color: palette.muted)),
          const SizedBox(height: 6),
          Text(hint, style: TextStyle(fontSize: 12, color: palette.muted)),
          if (clearable) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() {
                _filters = const NoteTimelineFilters();
                _type = NoteTypeFilter.all;
                _markFilter = _MarkStyleFilter.all;
                _markBookId = null;
              }),
              child: const Text('清除全部筛选'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<NoteTimelineFilters>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HomePalette.of(context).canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _NoteFilterSheet(
        initial: _filters,
        books: _books,
        categories: _categories,
        tags: _tags,
        markerTypes: _markerCatalog,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _filters = result);
  }

  Future<void> _editNote(ReaderAnnotation note) async {
    final draft = await showAnnotationEditor(
      context,
      quote: note.text,
      title: note.isAnnot ? '编辑批注' : '编辑书摘信息',
      isExcerpt: !note.isAnnot,
      initial: note.thought,
      initialCategory: note.category,
      initialTags: note.tags,
      initialMarkerType: note.markerType,
      initialMarkerLabel: note.displayMarkerLabel,
      initialMarkerColorValue: note.effectiveMarkerColorValue,
      initialMarkStyle: note.markStyle,
      initialMarkColorValue: note.effectiveMarkColorValue,
      knownCategories: _categories,
      knownTags: _tags,
    );
    if (draft == null) return;
    try {
      await _store.updateNote(note.key, draft);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    }
  }

  Future<void> _exportImage() async {
    final notes = _viewMode == _NotesViewMode.timeline
        ? _visible
        : _bookViewNotes;
    if (notes.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final path = await NoteCardExporter.export(notes: notes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('长图已保存：$path'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openNote(ReaderAnnotation note) async {
    await _openChapter(
      bookId: note.bookId,
      bookTitle: note.bookTitle,
      chapterId: note.chapterId,
      textOffset: note.start,
    );
  }

  /// 从划线记录跳回正文：范围划线直接落到那句，整段划线落到章首。
  Future<void> _openMark(_MarkEntry mark) async {
    await _openChapter(
      bookId: mark.bookId,
      bookTitle: mark.bookTitle,
      chapterId: mark.chapterId,
      textOffset: mark.startOffset,
    );
  }

  Future<void> _openChapter({
    required String bookId,
    required String bookTitle,
    required String chapterId,
    int? textOffset,
  }) async {
    final local = await _localChapter(bookId);
    if (local != null) {
      await _pushReaderAt(
        bookId: bookId,
        bookTitle: bookTitle,
        chapterId: chapterId,
        chapters: local,
        localOnly: true,
        textOffset: textOffset,
      );
      return;
    }
    List<List<Chapter>> volumes;
    try {
      volumes = await ApiClient.instance.directoryChapters(bookId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('取目录失败，请检查网络后重试')));
      return;
    }
    final chapters = volumes.expand((volume) => volume).toList(growable: false);
    if (chapters.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这本书没有可用章节')));
      return;
    }
    await _pushReaderAt(
      bookId: bookId,
      bookTitle: bookTitle,
      chapterId: chapterId,
      chapters: chapters,
      localOnly: false,
      textOffset: textOffset,
    );
  }

  Future<List<Chapter>?> _localChapter(String bookId) async {
    try {
      final book = await ImportedBookStore.instance.book(bookId);
      if (book == null || book.chapters.isEmpty) return null;
      return book.chapters;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pushReaderAt({
    required String bookId,
    required String bookTitle,
    required String chapterId,
    required List<Chapter> chapters,
    required bool localOnly,
    int? textOffset,
  }) async {
    var index = chapters.indexWhere((c) => c.itemId == chapterId);
    if (index < 0) index = 0;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: bookId,
          title: bookTitle.isEmpty ? '阅读' : bookTitle,
          chapters: chapters,
          startIndex: index,
          localOnly: localOnly,
          chapterLoader: !localOnly
              ? null
              : (chapter) => ImportedBookStore.instance.chapterText(
                  bookId,
                  chapter.itemId,
                ),
          startTextOffset: textOffset,
        ),
      ),
    );
  }
}

class _TimelineNoteRow extends StatelessWidget {
  const _TimelineNoteRow({
    super.key,
    required this.note,
    required this.bookTitle,
    required this.firstOfDay,
    required this.lastOfDay,
    required this.onOpen,
    required this.onEdit,
  });

  final ReaderAnnotation note;

  /// 书名已按阅读历史/书单缓存兜底，空字符串表示确实不知道是哪本书。
  final String bookTitle;
  final bool firstOfDay;
  final bool lastOfDay;
  final Future<void> Function(ReaderAnnotation note) onOpen;
  final Future<void> Function(ReaderAnnotation note) onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final badgeColor = Color(note.effectiveMarkerColorValue);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 56,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 44,
                  top: firstOfDay ? 18 : 0,
                  bottom: lastOfDay ? 20 : 0,
                  child: Container(width: 1.5, color: palette.line),
                ),
                Positioned(
                  left: 39.5,
                  top: 8,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.canvas, width: 2),
                    ),
                  ),
                ),
                if (firstOfDay)
                  Positioned(
                    left: 0,
                    top: 1,
                    width: 38,
                    // 日期是 10sp 的固定 5 字符，系统字号放大后会从
                    // 「10/21」折成「10/2 + 1」。这里保单行并允许整体
                    // 等比缩小，宁可小一点也不让日期断成两行。
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        _dayLabel(note.createdAt),
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 10,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: palette.line, width: 0.5),
                ),
                child: InkWell(
                  key: ValueKey('note-card-${note.key}'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onOpen(note),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              constraints: const BoxConstraints(minWidth: 22),
                              height: 20,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: badgeColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  note.displayMarkerLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    height: 1,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                bookTitle.isEmpty ? '未知书籍' : bookTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              key: ValueKey('note-menu-${note.key}'),
                              tooltip: '更多',
                              iconSize: 18,
                              padding: EdgeInsets.zero,
                              onSelected: (value) {
                                if (value == 'edit') onEdit(note);
                                if (value == 'open') onOpen(note);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('编辑分类、标签与标记'),
                                ),
                                PopupMenuItem(
                                  value: 'open',
                                  child: Text('回到原文'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Text(
                              _timestampLabel(note.createdAt),
                              key: ValueKey('note-time-${note.key}'),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: palette.muted,
                              ),
                            ),
                            if (note.chapterTitle.isNotEmpty) ...[
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  note.chapterTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: palette.muted,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            note.text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: palette.muted,
                            ),
                          ),
                        ),
                        if (note.thought.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            note.thought,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.55,
                              color: palette.ink,
                            ),
                          ),
                        ],
                        if (note.category.trim().isNotEmpty ||
                            note.tags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (note.category.trim().isNotEmpty)
                                _MetaChip(
                                  label: note.category,
                                  icon: LucideIcons.folder,
                                ),
                              for (final tag in note.tags)
                                _MetaChip(
                                  label: '#$tag',
                                  icon: LucideIcons.tag,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
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

class _BookNotesCard extends StatelessWidget {
  const _BookNotesCard({
    super.key,
    required this.group,
    required this.cover,
    required this.coverWidth,
    required this.onTap,
  });

  final _BookNotesGroup group;
  final String cover;
  final double coverWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    // 与首页共用同一个封面组件：有真实封面就显示封面，没有就用同款几何封面，
    // 于是「按书查看」和首页看起来是同一套卡片。
    final item = MediaItem(
      id: group.id,
      title: group.title,
      cover: cover,
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 5 / 7,
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: palette.line.withValues(alpha: 0.55),
                          width: 0.6,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: palette.dark ? 0.28 : 0.05,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: StoryCover(
                          item: item,
                          cacheWidth: (coverWidth * pixelRatio).round(),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${group.notes.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Text(
              group.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
          ),
          Text(
            '${group.notes.length} 条笔记 · ${group.annotCount} 批注'
            ' · ${group.excerptCount} 书摘 · ${group.chapterCount} 个章节',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: palette.muted),
          ),
        ],
      ),
    );
  }
}

/// 划线视图的一行：线型标记 + 书/章 + 原文。
class _MarkRow extends StatelessWidget {
  const _MarkRow({super.key, required this.entry, required this.onTap});

  final _MarkEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final accent = Color(
      entry.colorValue == 0 ? readerDefaultUnderlineColor : entry.colorValue,
    );
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.45),
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      entry.isHighlighter ? '荧光笔' : entry.style.label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      entry.bookTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.muted,
                      ),
                    ),
                  ),
                  Text(
                    _timestampLabel(entry.createdAt),
                    style: TextStyle(fontSize: 10, color: palette.muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                entry.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: palette.ink.withValues(alpha: 0.86),
                ),
              ),
              if (entry.chapterTitle.trim().isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  entry.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: palette.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: palette.muted),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10.5, color: palette.muted)),
        ],
      ),
    );
  }
}

class _NoteFilterSheet extends StatefulWidget {
  const _NoteFilterSheet({
    required this.initial,
    required this.books,
    required this.categories,
    required this.tags,
    this.markerTypes = const [],
  });

  final NoteTimelineFilters initial;
  final List<_BookOption> books;
  final List<String> categories;
  final List<String> tags;
  final List<ReaderMarkerType> markerTypes;

  @override
  State<_NoteFilterSheet> createState() => _NoteFilterSheetState();
}

class _NoteFilterSheetState extends State<_NoteFilterSheet> {
  String? _bookId;
  String? _category;
  late Set<String> _tags;
  late NoteTimePreset _timePreset;
  DateTimeRange? _customRange;
  String? _markerKey;

  @override
  void initState() {
    super.initState();
    _bookId = widget.initial.bookId;
    _category = widget.initial.category;
    _tags = Set.of(widget.initial.tags);
    _timePreset = widget.initial.timePreset;
    _customRange = widget.initial.customRange;
    _markerKey = widget.initial.markerKey;
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customRange = picked;
      _timePreset = NoteTimePreset.custom;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      NoteTimelineFilters(
        bookId: _bookId,
        category: _category,
        tags: Set.unmodifiable(_tags),
        timePreset: _timePreset,
        customRange: _customRange,
        markerKey: _markerKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final palette = HomePalette.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.88),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: palette.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '筛选笔记',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('notes-filter-reset'),
                    style: TextButton.styleFrom(foregroundColor: palette.muted),
                    onPressed: () => setState(() {
                      _bookId = null;
                      _category = null;
                      _tags.clear();
                      _timePreset = NoteTimePreset.all;
                      _customRange = null;
                      _markerKey = null;
                    }),
                    child: const Text('重置'),
                  ),
                  FilledButton(
                    key: const ValueKey('notes-filter-apply'),
                    style: FilledButton.styleFrom(
                      backgroundColor: HomePalette.accent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _apply,
                    child: const Text('应用'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const _FilterLabel('书籍'),
              const SizedBox(height: 6),
              KeyedSubtree(
                key: const ValueKey('notes-filter-book'),
                child: DropdownButtonFormField<String?>(
                  // Recreate the field when reset changes the value. The form
                  // field caches its internal selection otherwise, leaving
                  // 全部书籍 visually stuck on the previous value after 重置.
                  key: ValueKey('notes-filter-book-${_bookId ?? 'all'}'),
                  initialValue: _bookId,
                  isExpanded: true,
                  decoration: _filterDecoration(palette, '全部书籍'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('全部书籍'),
                    ),
                    for (final book in widget.books)
                      DropdownMenuItem<String?>(
                        value: book.id,
                        child: Text(
                          book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  dropdownColor: palette.surface,
                  style: TextStyle(fontSize: 14, color: palette.ink),
                  onChanged: (value) => setState(() => _bookId = value),
                ),
              ),
              const SizedBox(height: 16),
              const _FilterLabel('时间'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  _timeChip('全部时间', NoteTimePreset.all),
                  _timeChip('今天', NoteTimePreset.today),
                  _timeChip('近 7 天', NoteTimePreset.sevenDays),
                  _timeChip('近 30 天', NoteTimePreset.thirtyDays),
                  ChoiceChip(
                    key: const ValueKey('notes-filter-time-custom'),
                    showCheckmark: false,
                    selected: _timePreset == NoteTimePreset.custom,
                    selectedColor: palette.chipSelectedFill,
                    backgroundColor: palette.chipFill,
                    side: palette.chipBorder(
                      _timePreset == NoteTimePreset.custom,
                    ),
                    label: Text(
                      _customRange == null
                          ? '自定义日期'
                          : _rangeLabel(_customRange!),
                    ),
                    onSelected: (_) => _pickCustomRange(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _FilterLabel('分类'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('notes-filter-category-all'),
                    showCheckmark: false,
                    selected: _category == null,
                    selectedColor: palette.chipSelectedFill,
                    backgroundColor: palette.chipFill,
                    side: palette.chipBorder(_category == null),
                    label: const Text('全部分类'),
                    onSelected: (_) => setState(() => _category = null),
                  ),
                  for (final category in widget.categories)
                    ChoiceChip(
                      key: ValueKey('notes-filter-category-$category'),
                      showCheckmark: false,
                      selected: _category == category,
                      selectedColor: palette.chipSelectedFill,
                      backgroundColor: palette.chipFill,
                      side: palette.chipBorder(_category == category),
                      label: Text(category),
                      onSelected: (_) => setState(() => _category = category),
                    ),
                  ChoiceChip(
                    key: const ValueKey('notes-filter-category-none'),
                    showCheckmark: false,
                    selected: _category == noteUncategorizedFilter,
                    selectedColor: palette.chipSelectedFill,
                    backgroundColor: palette.chipFill,
                    side: palette.chipBorder(
                      _category == noteUncategorizedFilter,
                    ),
                    label: const Text('未分类'),
                    onSelected: (_) =>
                        setState(() => _category = noteUncategorizedFilter),
                  ),
                ],
              ),
              if (widget.markerTypes.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _FilterLabel('批注类型'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('notes-filter-marker-all'),
                      showCheckmark: false,
                      selected: _markerKey == null,
                      selectedColor: palette.chipSelectedFill,
                      backgroundColor: palette.chipFill,
                      side: palette.chipBorder(_markerKey == null),
                      label: const Text('全部类型'),
                      onSelected: (_) => setState(() => _markerKey = null),
                    ),
                    for (final type in widget.markerTypes)
                      ChoiceChip(
                        key: ValueKey('notes-filter-marker-${type.key}'),
                        showCheckmark: false,
                        selected: _markerKey == type.key,
                        selectedColor: palette.chipSelectedFill,
                        backgroundColor: palette.chipFill,
                        side: palette.chipBorder(_markerKey == type.key),
                        avatar: CircleAvatar(
                          radius: 5,
                          backgroundColor: Color(type.colorValue),
                        ),
                        label: Text(type.label),
                        onSelected: (_) =>
                            setState(() => _markerKey = type.key),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              const _FilterLabel('标签（可多选，匹配任一标签）'),
              const SizedBox(height: 6),
              if (widget.tags.isEmpty)
                Text(
                  '还没有标签，编辑笔记时即可添加。',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                )
              else
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.tags)
                      FilterChip(
                        key: ValueKey('notes-filter-tag-$tag'),
                        label: Text('#$tag'),
                        selected: _tags.contains(tag),
                        selectedColor: palette.chipSelectedFill,
                        backgroundColor: palette.chipFill,
                        side: palette.chipBorder(_tags.contains(tag)),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _tags.add(tag);
                          } else {
                            _tags.remove(tag);
                          }
                        }),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeChip(String label, NoteTimePreset preset) {
    final palette = HomePalette.of(context);
    final active = _timePreset == preset;
    return ChoiceChip(
      key: ValueKey('notes-filter-time-${preset.name}'),
      showCheckmark: false,
      selected: active,
      selectedColor: palette.chipSelectedFill,
      backgroundColor: palette.chipFill,
      side: palette.chipBorder(active),
      label: Text(label),
      onSelected: (_) => setState(() => _timePreset = preset),
    );
  }
}

class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: HomePalette.of(context).muted,
    ),
  );
}

InputDecoration _filterDecoration(HomePalette palette, String hint) =>
    InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: palette.muted, fontSize: 13.5),
      filled: true,
      fillColor: palette.soft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: palette.line, width: 0.6),
      ),
    );

bool _sameDay(int leftMs, int rightMs) {
  if (leftMs <= 0 || rightMs <= 0) return leftMs == rightMs;
  final left = DateTime.fromMillisecondsSinceEpoch(leftMs);
  final right = DateTime.fromMillisecondsSinceEpoch(rightMs);
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String _two(int value) => value.toString().padLeft(2, '0');

String _dayLabel(int milliseconds) {
  if (milliseconds <= 0) return '日期未知';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${_two(date.month)}/${_two(date.day)}';
}

String _timestampLabel(int milliseconds) {
  if (milliseconds <= 0) return '时间未知';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${date.year}-${_two(date.month)}-${_two(date.day)} '
      '${_two(date.hour)}:${_two(date.minute)}';
}

String _rangeLabel(DateTimeRange range) {
  String date(DateTime value) =>
      '${value.year}.${_two(value.month)}.${_two(value.day)}';
  if (range.start.year == range.end.year &&
      range.start.month == range.end.month &&
      range.start.day == range.end.day) {
    return date(range.start);
  }
  return '${date(range.start)} - ${date(range.end)}';
}
