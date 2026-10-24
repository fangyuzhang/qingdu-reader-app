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
import '../widgets/notes/note_tag_drag.dart';
import '../widgets/reader/reader_note_block.dart';
import 'reader_page.dart';

enum _NotesViewMode { timeline, books }

/// 划线视图里「只看向下划线 / 只看荧光笔」的二级切换。
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

  /// 「全部类型」一行的手动顺序（`type:` / `tag:` id）。空表示还没排过。
  List<String> _order = const [];

  /// 拖拽悬停中的笔记与标签，用来画磁力虚影。
  String? _hoverNoteKey;
  NoteTagDrag? _hoverTag;

  /// 正在移动/删除中的角标（noteKey → (类型, 文案) 集合）。
  ///
  /// 松手到写库、重载完成的空档里，先把源笔记上的角标藏住：否则角标会
  /// 先闪回原位、等异步重载后才消失，看起来像一个残影。某次重载数据
  /// 确认源上已没有这枚角标后自动解除；写库失败时回滚恢复。
  final Map<String, Set<(NoteTagKind, String)>> _leavingBadges = {};

  /// 顶部「全部类型」的拖动排序状态：正在拖的标签、起止插入位置，以及按下时各标签的中心（用固定坐标算插入点，
  /// 避免标签被挤动后坐标变化导致来回抖）。
  NoteTagDrag? _paletteDrag;
  int _paletteFrom = 0;
  int _paletteTo = 0;
  bool _paletteInRow = false;
  List<double> _paletteCenters = const [];

  /// 拿起瞬间各枚标签在行内的左边界与宽度（含右侧 6dp 间距），
  /// 用来算出「挤位后」的精确位置，避免不同宽度的标签互相压住。
  List<_PaletteSlot> _paletteSlots = const [];
  final GlobalKey _paletteRowKey = GlobalKey();
  final Map<String, GlobalKey> _paletteChipKeys = {};
  final Map<String, int> _rebornTokens = {};

  /// 划线 / 荧光笔记录，以及按书过滤当前划线视图的选择。
  List<_MarkEntry> _marks = const [];
  /// 划线线型筛选（null = 全部线型）；仅当类型筛选选中「划线」时生效。
  ReaderMarkStyle? _markStyleFilter;

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
      _order = ReaderMarkerTypeStore.instance.order;
      _covers = meta.covers;
      _bookTitles = meta.titles;
      _marks = _buildMarks(ranges, paragraphs, entries, meta.titles);
      _loading = false;
      _pruneLeavingBadges(entries);
    });
  }

  /// 重载数据落地后，解除已确认完成的「正在离开」隐藏：
  /// 源笔记已不存在、或已确实不含该角标时清掉对应条目。
  void _pruneLeavingBadges(List<ReaderAnnotation> entries) {
    _leavingBadges.removeWhere(
      (noteKey, _) => !entries.any((note) => note.key == noteKey),
    );
    for (final note in entries) {
      final leaving = _leavingBadges[note.key];
      if (leaving == null) continue;
      leaving.removeWhere(
        (badge) => switch (badge.$1) {
          NoteTagKind.marker =>
            !note.markerBadges.any((entry) => entry.label == badge.$2),
          NoteTagKind.tag => !note.tags.contains(badge.$2),
        },
      );
      if (leaving.isEmpty) _leavingBadges.remove(note.key);
    }
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
  /// 这里保持目录顺序；展示顺序由 [_sortByOrder] 按「全部类型」排。
  List<ReaderMarkerType> get _baseMarkerCatalog {
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

  /// 没手动排过时，先批注类型、后自由标签；排过一次就完全听用户的。
  List<String> get _effectiveOrder {
    if (_order.isNotEmpty) return _order;
    return [
      for (final type in _baseMarkerCatalog)
        ReaderMarkerTypeStore.typeOrderId(type.key),
      for (final tag in _tags) ReaderMarkerTypeStore.tagOrderId(tag),
    ];
  }

  Map<String, int> get _orderRank => {
    for (var index = 0; index < _effectiveOrder.length; index++)
      _effectiveOrder[index]: index,
  };

  String _orderIdOf(NoteTagDrag entry) => entry.kind == NoteTagKind.marker
      ? ReaderMarkerTypeStore.typeOrderId(entry.label)
      : ReaderMarkerTypeStore.tagOrderId(entry.label);

  /// 当前「全部类型」一行的 id 序列（按用户顺序排好）。
  List<String> get _sortedOrderIds => _sortByOrder([
    for (final type in _baseMarkerCatalog)
      ReaderMarkerTypeStore.typeOrderId(type.key),
    for (final tag in _tags) ReaderMarkerTypeStore.tagOrderId(tag),
  ], (id) => id);

  /// 角标 / 类型 / 标签都按「全部类型」里的手动顺序排列，
  /// 没排过的排后面并保持原序。
  List<T> _sortByOrder<T>(List<T> entries, String Function(T entry) idOf) {
    final rank = _orderRank;
    final indexed = entries.indexed.toList();
    indexed.sort((a, b) {
      final left = rank[idOf(a.$2)] ?? 1 << 20;
      final right = rank[idOf(b.$2)] ?? 1 << 20;
      final byRank = left.compareTo(right);
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
    return List.unmodifiable(indexed.map((entry) => entry.$2));
  }

  /// 「全部类型」里实际渲染的一行：批注类型 + 自由标签，统一排序。
  List<NoteTagDrag> _paletteEntries({required bool dark}) => _sortByOrder([
    for (final type in _baseMarkerCatalog)
      NoteTagDrag(
        label: type.label,
        colorValue: type.colorValue,
        kind: NoteTagKind.marker,
      ),
    for (final tag in _tags)
      NoteTagDrag(
        label: tag,
        colorValue: noteTagColorValue(tag, dark: dark),
        kind: NoteTagKind.tag,
      ),
  ], _orderIdOf);

  /// 一条笔记上挂的所有角标：类型与标签混排，顺序跟「全部类型」一致。
  /// 正在移动/删除中的角标（[_leavingBadges]）暂时不显示。
  ///
  /// [ghost] 是拖动悬停中的磁力虚影：插到它松手后应落的排序位置上，
  /// 让虚影直接预览落点（同一行的行内位置），行内其他角标顺次挤开。
  List<NoteTagDrag> _badgesOf(
    ReaderAnnotation note, {
    required bool dark,
    NoteTagDrag? ghost,
  }) {
    final markers = <NoteTagDrag>[
      for (final badge in note.markerBadges)
        if (!_isLeavingBadge(note.key, NoteTagKind.marker, badge.label))
          NoteTagDrag(
            label: badge.label,
            colorValue: badge.colorValue,
            kind: NoteTagKind.marker,
            sourceNoteKey: note.key,
          ),
    ];
    final tags = <NoteTagDrag>[
      for (final tag in note.tags)
        if (!_isLeavingBadge(note.key, NoteTagKind.tag, tag))
          NoteTagDrag(
            label: tag,
            colorValue: noteTagColorValue(tag, dark: dark),
            kind: NoteTagKind.tag,
            sourceNoteKey: note.key,
          ),
    ];
    if (ghost != null) {
      (ghost.kind == NoteTagKind.marker ? markers : tags).add(ghost);
    }
    return _sortByOrder([...markers, ...tags], _orderIdOf);
  }

  List<ReaderAnnotation> get _visible {
    // 「划线」类型下时间线渲染划线记录（_visibleMarks），注解列表清空。
    if (_type == NoteTypeFilter.marks) return const [];
    return filterNoteTimeline(_all, _filters, type: _type);
  }

  /// 按书浏览：时间、分类、标签与批注/书摘条件继续生效；
  /// 选中某本书后用它收窄到这一本。
  List<ReaderAnnotation> get _bookViewNotes {
    return filterNoteTimeline(
      _all,
      NoteTimelineFilters(
        bookId: _filters.bookId,
        category: _filters.category,
        tags: _filters.tags,
        timePreset: _filters.timePreset,
        customRange: _filters.customRange,
        markerKeys: _filters.markerKeys,
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
      // 视图切换一律回到全量：单书范围只属于「按书查看」里的那一层，
      // 否则时间线会莫名只剩一本书，而顶部又没有可见的筛选提示。
      _filters = _filters.without(bookId: true);
      // 「划线」是时间线里的类型筛选；按书查看只收批注/书摘，
      // 切走时退出划线模式，避免按书视图意外变成空列表。
      if (mode != _NotesViewMode.timeline && _type == NoteTypeFilter.marks) {
        _type = NoteTypeFilter.all;
      }
      _hoverNoteKey = null;
      _hoverTag = null;
    });
  }

  void _openBookNotes(_BookNotesGroup group) {
    setState(() {
      _filters = _filters.copyWith(bookId: group.id);
      // 留在「按书查看」里展开这本书，不再擅自跳到时间线。
      _hoverNoteKey = null;
      _hoverTag = null;
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

  /// 当前类型筛选选中「划线」时的数据：按线型筛选（null = 全部线型）。
  List<_MarkEntry> get _visibleMarks => [
    for (final mark in _marks)
      if (_markStyleFilter == null || mark.style == _markStyleFilter) mark,
  ];

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final visible = _visible;
    final groups = _viewMode == _NotesViewMode.books
        ? _bookGroups
        : const <_BookNotesGroup>[];
    final selectedBookId = _viewMode == _NotesViewMode.books
        ? _filters.bookId
        : null;
    final bookNotes = selectedBookId == null
        ? const <ReaderAnnotation>[]
        : _bookViewNotes;
    final showMarks = _type == NoteTypeFilter.marks;
    final exportNotes = showMarks ? const <ReaderAnnotation>[] : visible;
    final hasContent = showMarks ? _visibleMarks.isNotEmpty : visible.isNotEmpty;
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
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : !hasContent
                ? _buildEmpty(palette)
                : switch (_viewMode) {
                    _NotesViewMode.books =>
                      selectedBookId == null
                          ? _buildBookGrid(groups)
                          : _buildBookNotes(palette, selectedBookId, bookNotes),
                    _NotesViewMode.timeline => showMarks
                        ? _buildMarkTimeline(palette, _visibleMarks)
                        : _buildNoteList(palette, visible),
                  },
          ),
        ],
      ),
    );
  }

  Widget _buildNoteList(
    HomePalette palette,
    List<ReaderAnnotation> notes,
  ) => ListView.builder(
    key: const ValueKey('notes-timeline'),
    padding: const EdgeInsets.fromLTRB(12, 4, 16, 32),
    itemCount: notes.length,
    itemBuilder: (context, index) {
      final note = notes[index];
      final previous = index == 0 ? null : notes[index - 1];
      final next = index + 1 >= notes.length ? null : notes[index + 1];
      return _noteRow(
        note,
        palette: palette,
        firstOfDay:
            previous == null || !_sameDay(previous.createdAt, note.createdAt),
        lastOfDay: next == null || !_sameDay(next.createdAt, note.createdAt),
      );
    },
  );

  /// 按书查看里点开一本书：留在这个视图，只把范围收窄到这一本。
  Widget _buildBookNotes(
    HomePalette palette,
    String bookId,
    List<ReaderAnnotation> notes,
  ) => Column(
    children: [
      _BookScopeBar(
        title: _titleOf(bookId, notes.isEmpty ? '' : notes.first.bookTitle),
        count: notes.length,
        onBack: () => setState(() {
          _filters = _filters.without(bookId: true);
          _hoverNoteKey = null;
          _hoverTag = null;
        }),
      ),
      Expanded(
        child: notes.isEmpty
            ? _buildEmpty(palette)
            : _buildNoteList(palette, notes),
      ),
    ],
  );

  /// 一条时间线笔记，统一挂上「拖标签进来」的落点与磁力虚影。
  Widget _noteRow(
    ReaderAnnotation note, {
    required HomePalette palette,
    required bool firstOfDay,
    required bool lastOfDay,
  }) {
    final hovering = _hoverNoteKey == note.key;
    final badges = _badgesOf(note, dark: palette.dark);
    final hoverTag = hovering ? _hoverTag : null;
    // 目标笔记已有同款角标时不画虚影（靠角标自身的吸附环提示）。
    final ghostTag =
        hoverTag != null &&
            !badges.any(
              (badge) =>
                  badge.kind == hoverTag.kind && badge.label == hoverTag.label,
            )
        ? hoverTag
        : null;
    return DragTarget<NoteTagDrag>(
      // 拖回自己身上也要接受：接受后是无操作，否则会被当成「丢到空白处」
      // 把标签删掉。
      onWillAcceptWithDetails: (details) => true,
      onMove: (details) {
        if (_hoverNoteKey == note.key && _hoverTag?.id == details.data.id) {
          return;
        }
        setState(() {
          _hoverNoteKey = note.key;
          _hoverTag = details.data;
        });
      },
      onLeave: (_) {
        if (_hoverNoteKey != note.key) return;
        setState(() {
          _hoverNoteKey = null;
          _hoverTag = null;
        });
      },
      onAcceptWithDetails: (details) {
        final data = details.data;
        setState(() {
          _hoverNoteKey = null;
          _hoverTag = null;
        });
        unawaited(_applyTagDrop(note, data));
      },
      builder: (context, candidate, rejected) => _TimelineNoteRow(
        key: ValueKey('note-timeline-${note.key}'),
        note: note,
        bookTitle: _titleOf(note.bookId, note.bookTitle),
        firstOfDay: firstOfDay,
        lastOfDay: lastOfDay,
        badges: ghostTag == null
            ? badges
            : _badgesOf(note, dark: palette.dark, ghost: ghostTag),
        ghostId: ghostTag?.id,
        hoverTag: hoverTag,
        hovered: hovering,
        onOpen: _openNote,
        onEdit: _editNote,
        onDragFinished: _clearHover,
        onRemoveTag: (tag) => unawaited(_removeBadge(note, tag)),
      ),
    );
  }

  bool _isLeavingBadge(String noteKey, NoteTagKind kind, String label) =>
      _leavingBadges[noteKey]?.contains((kind, label)) ?? false;

  void _markLeavingBadge(String noteKey, NoteTagKind kind, String label) {
    if (_isLeavingBadge(noteKey, kind, label)) return;
    setState(() {
      _leavingBadges
          .putIfAbsent(noteKey, () => <(NoteTagKind, String)>{})
          .add((kind, label));
    });
  }

  /// 写库失败时回滚：解除隐藏并提示，角标回到原位，不留下残影误导。
  void _rollbackLeavingBadge(String noteKey, NoteTagDrag tag) {
    if (!mounted) return;
    setState(() {
      final leaving = _leavingBadges[noteKey];
      leaving?.remove((tag.kind, tag.label));
      if (leaving != null && leaving.isEmpty) _leavingBadges.remove(noteKey);
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
  }

  /// 把拖进来的标签落到 [note] 上；跨笔记拖动时从来源上摘掉。
  ///
  /// 摘除前先把源角标记为「正在离开」并立即隐藏：写库与重载之间有空档，
  /// 不藏的话源角标会先闪回原位再消失，看起来像松手后留了个虚影。
  Future<void> _applyTagDrop(ReaderAnnotation note, NoteTagDrag data) async {
    final fromKey = data.sourceNoteKey;
    final source = fromKey == null || fromKey == note.key
        ? null
        : _all.where((entry) => entry.key == fromKey).firstOrNull;
    bool sourceHas() => switch (data.kind) {
      NoteTagKind.marker =>
        source!.markerBadges.any((badge) => badge.key == data.label),
      NoteTagKind.tag => source!.tags.contains(data.label),
    };
    // 目标已经有这个角标：整次拖动视为无操作，不能把来源上的删掉。
    final targetHas = switch (data.kind) {
      NoteTagKind.marker =>
        note.markerBadges.any((badge) => badge.key == data.label),
      NoteTagKind.tag => note.tags.contains(data.label),
    };
    if (targetHas) return;
    final movesFromSource = source != null && sourceHas();
    if (movesFromSource) {
      _markLeavingBadge(source.key, data.kind, data.label);
    }
    try {
      if (data.kind == NoteTagKind.marker) {
        final type = ReaderMarkerType(
          label: data.label,
          colorValue: data.colorValue,
        );
        await _store.updateMarkerTags(note.key, [
          ...note.markerBadges,
          type,
        ]);
        if (movesFromSource) {
          await _store.updateMarkerTags(
            source.key,
            source.markerBadges.where((badge) => badge.key != type.key),
          );
        }
        return;
      }
      await _store.updateTags(note.key, [...note.tags, data.label]);
      if (movesFromSource) {
        await _store.updateTags(
          source.key,
          source.tags.where((tag) => tag != data.label),
        );
      }
    } catch (_) {
      if (movesFromSource) _rollbackLeavingBadge(fromKey!, data);
    }
  }

  /// 拖到空白处 = 从这条笔记上摘掉角标。同样先隐藏再异步写库，
  /// 避免松手后角标闪回原位、等重载才消失。
  Future<void> _removeBadge(ReaderAnnotation note, NoteTagDrag tag) async {
    _markLeavingBadge(note.key, tag.kind, tag.label);
    try {
      if (tag.kind == NoteTagKind.marker) {
        await _store.updateMarkerTags(
          note.key,
          note.markerBadges.where((entry) => entry.key != tag.label),
        );
      } else {
        await _store.updateTags(
          note.key,
          note.tags.where((entry) => entry != tag.label),
        );
      }
    } catch (_) {
      _rollbackLeavingBadge(note.key, tag);
    }
  }

  /// 拿起「全部类型」里的标签：记下原位与所有其他标签的中心。
  void _paletteDragStarted(NoteTagDrag dragged, Size size) {
    final entries = _paletteEntries(
      dark: Theme.of(context).brightness == Brightness.dark,
    );
    final from = entries.indexWhere((entry) => entry.id == dragged.id);
    final centers = <double>[];
    final slots = <_PaletteSlot>[];
    double? origin;
    for (var index = 0; index < entries.length; index++) {
      final box = _paletteChipKeys[entries[index].id]?.currentContext
          ?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final global = box.localToGlobal(Offset.zero);
        origin ??= global.dx;
        slots.add(_PaletteSlot(global.dx - origin, box.size.width));
        if (index != from) {
          centers.add(box.localToGlobal(box.size.center(Offset.zero)).dx);
        }
      } else {
        slots.add(const _PaletteSlot(0, 0));
        if (index != from) centers.add(0);
      }
    }
    setState(() {
      _paletteDrag = dragged;
      _paletteFrom = from < 0 ? 0 : from;
      _paletteTo = _paletteFrom;
      _paletteInRow = true;
      _paletteCenters = centers;
      _paletteSlots = slots;
      _hoverNoteKey = null;
      _hoverTag = null;
    });
  }

  /// 拖动中：只在指针回到这一行时计算插入位置；离开就回到原位空位。
  void _paletteDragUpdated(Offset globalPosition) {
    if (_paletteDrag == null) return;
    final box = _paletteRowKey.currentContext?.findRenderObject();
    final rect = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final inRow =
        rect != null &&
        globalPosition.dy >= rect.top - 32 &&
        globalPosition.dy <= rect.bottom + 32;
    var to = _paletteFrom;
    if (inRow) {
      to = 0;
      for (final center in _paletteCenters) {
        if (globalPosition.dx > center) to++;
      }
    }
    if (inRow == _paletteInRow && to == _paletteTo) return;
    setState(() {
      _paletteInRow = inRow;
      _paletteTo = to;
    });
  }

  /// 每一枚标签该横向让开多少：空位本身也一起挪到插入点，
  /// 中间被跨过的标签按各自宽度反向补齐，形成「挤进去」的效果。
  double _paletteShiftFor(int index) {
    if (_paletteDrag == null || !_paletteInRow) return 0;
    if (_paletteFrom == _paletteTo) return 0;
    final slots = _paletteSlots;
    if (index < 0 || index >= slots.length) return 0;
    if (slots.any((slot) => slot.width <= 0)) return 0;
    final target = _paletteTargetLefts(slots);
    return target[index] - slots[index].left;
  }

  /// 按「去掉被拖的那枚、再插到 [_paletteTo]」重算一遍行内左边界。
  List<double> _paletteTargetLefts(List<_PaletteSlot> slots) {
    final order = <int>[
      for (var index = 0; index < slots.length; index++)
        if (index != _paletteFrom) index,
    ];
    order.insert(_paletteTo.clamp(0, order.length), _paletteFrom);
    final lefts = List<double>.filled(slots.length, 0);
    var cursor = 0.0;
    for (final index in order) {
      lefts[index] = cursor;
      cursor += slots[index].width;
    }
    return lefts;
  }

  /// 松手：在行内就按插入点落位，并让这枚标签弹性重生。
  void _paletteDragFinished() {
    final dragged = _paletteDrag;
    if (dragged == null) {
      _clearHover();
      return;
    }
    if (_paletteInRow) _commitPaletteReorder(dragged, _paletteTo);
    setState(() {
      _rebornTokens[dragged.id] = (_rebornTokens[dragged.id] ?? 0) + 1;
      _paletteDrag = null;
      _paletteInRow = false;
      _paletteCenters = const [];
    });
    _clearHover();
  }

  /// 把 [dragged] 插到「去掉自己之后」的第 [to] 位并持久化。
  void _commitPaletteReorder(NoteTagDrag dragged, int to) {
    final ids = [..._sortedOrderIds];
    final id = _orderIdOf(dragged);
    final from = ids.indexOf(id);
    if (from < 0) return;
    ids.removeAt(from);
    final target = to.clamp(0, ids.length);
    if (target == from) return;
    ids.insert(target, id);
    setState(() => _order = List.unmodifiable(ids));
    unawaited(ReaderMarkerTypeStore.instance.setOrder(ids));
  }

  /// 拖拽结束（无论有没有落点）都清掉磁力虚影，避免悬停态残留。
  void _clearHover() {
    if (_hoverNoteKey == null && _hoverTag == null) return;
    setState(() {
      _hoverNoteKey = null;
      _hoverTag = null;
    });
  }

  /// 类型与自由标签都支持多选：同一维度内「任一命中」，再点一次取消。
  void _toggleType(NoteTagDrag entry) {
    setState(() {
      if (entry.kind == NoteTagKind.marker) {
        final next = {..._filters.markerKeys};
        if (!next.remove(entry.label)) next.add(entry.label);
        _filters = next.isEmpty
            ? _filters.without(marker: true)
            : _filters.copyWith(markerKeys: next);
        return;
      }
      final next = {..._filters.tags};
      if (!next.remove(entry.label)) next.add(entry.label);
      _filters = next.isEmpty
          ? _filters.without(tags: true)
          : _filters.copyWith(tags: next);
    });
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
          ],
        ),
      ),
    );
  }

  Widget _buildQuickFilters(HomePalette palette) {
    final marksMode = _type == NoteTypeFilter.marks;
    final markStyleAll = _markStyleFilter == null;
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
          // 再点一次当前类型 = 取消选择，不再额外弹「类型 / 清除」按钮。
          onSelected: (_) =>
              setState(() => _type = _type == type ? NoteTypeFilter.all : type),
        ),
      );
    }

    final entries = _paletteEntries(dark: palette.dark);
    final allTypes = _filters.markerKeys.isEmpty && _filters.tags.isEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                chip(NoteTypeFilter.all, '全部', _all.length),
                chip(NoteTypeFilter.annot, '批注', _annotCount),
                chip(NoteTypeFilter.excerpt, '书摘', _excerptCount),
                // 【产品调整】划线从独立视图改为与批注/书摘同类的类型筛选。
                chip(NoteTypeFilter.marks, '划线', _marks.length),
              ],
            ),
          ),
        ),
        // 「全部类型」= 批注类型 + 自由标签，共用一条可长按拖动的顺序。
        // 类型单选、标签多选；再点一次当前项即取消，不再弹「类型 / 清除」。
        SizedBox(
          // ChoiceChip 在 MaterialTapTargetSize.padded 下自带 48dp 命中区，
          // 原来的 40dp 行高既压扁了 chip，也让点击带不足 48dp。
          height: 48,
          child: KeyedSubtree(
            key: _paletteRowKey,
            child: ListView(
              key: const ValueKey('notes-marker-types'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: const ValueKey('notes-marker-all'),
                    showCheckmark: false,
                    // 划线类型下「全部类型」= 全部线型。
                    selected: marksMode ? markStyleAll : allTypes,
                    label: const Text('全部类型'),
                    labelStyle: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: (marksMode ? markStyleAll : allTypes)
                          ? palette.accentText
                          : palette.muted,
                    ),
                    selectedColor: palette.chipSelectedFill,
                    backgroundColor: palette.chipFill,
                    side: palette.chipBorder(
                      marksMode ? markStyleAll : allTypes,
                    ),
                    onSelected: (_) => setState(
                      () => marksMode
                          ? _markStyleFilter = null
                          : _filters =
                                _filters.without(marker: true, tags: true),
                    ),
                  ),
                ),
                // 【产品调整】类型选中「划线」时，这一行变为线型筛选：
                // 横线 / 波浪线 / 虚线 / 荧光笔，点选过滤划线记录。
                if (marksMode)
                  for (final style in ReaderMarkStyle.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        key: ValueKey('notes-mark-style-${style.name}'),
                        showCheckmark: false,
                        selected: _markStyleFilter == style,
                        label: Text(
                          '${style.label} ${_marks.where((mark) => mark.style == style).length}',
                        ),
                        labelStyle: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: _markStyleFilter == style
                              ? palette.accentText
                              : palette.muted,
                        ),
                        selectedColor: palette.chipSelectedFill,
                        backgroundColor: palette.chipFill,
                        side: palette.chipBorder(_markStyleFilter == style),
                        onSelected: (_) => setState(
                          () => _markStyleFilter =
                              _markStyleFilter == style ? null : style,
                        ),
                      ),
                    )
                else
                  for (var index = 0; index < entries.length; index++)
                  KeyedSubtree(
                    key: _paletteChipKeys.putIfAbsent(
                      entries[index].id,
                      () => GlobalKey(debugLabel: entries[index].id),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      transform: Matrix4.translationValues(
                        _paletteShiftFor(index),
                        0,
                        0,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: PaletteTagChip(
                          key: ValueKey(
                            entries[index].kind == NoteTagKind.marker
                                ? 'notes-marker-${entries[index].label}'
                                : 'notes-tag-${entries[index].label}',
                          ),
                          label: entries[index].label,
                          colorValue: entries[index].colorValue,
                          kind: entries[index].kind,
                          selected: entries[index].kind == NoteTagKind.marker
                              ? _filters.markerKeys.contains(
                                  entries[index].label,
                                )
                              : _filters.tags.contains(entries[index].label),
                          onTap: () => _toggleType(entries[index]),
                          onDragStarted: _paletteDragStarted,
                          onDragUpdate: _paletteDragUpdated,
                          onDragFinished: _paletteDragFinished,
                          rebornToken: _rebornTokens[entries[index].id] ?? 0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 划线视图的顶部：先分线型，再按书收窄。
  /// 「划线」类型下的时间线：划线记录沿用日期轴 + 记录卡片，与批注
  /// 时间线同一观感（不再作为独立视图）。
  Widget _buildMarkTimeline(HomePalette palette, List<_MarkEntry> marks) =>
      ListView.builder(
        key: const ValueKey('notes-mark-timeline'),
        padding: const EdgeInsets.fromLTRB(12, 4, 16, 32),
        itemCount: marks.length,
        itemBuilder: (context, index) {
          final mark = marks[index];
          final previous = index == 0 ? null : marks[index - 1];
          final next = index + 1 >= marks.length ? null : marks[index + 1];
          final firstOfDay = previous == null ||
              !_sameDay(previous.createdAt, mark.createdAt);
          final lastOfDay =
              next == null || !_sameDay(next.createdAt, mark.createdAt);
          final color = Color(
            mark.colorValue == 0
                ? readerDefaultUnderlineColor
                : mark.colorValue,
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            // 与批注时间线同款：时间线列以卡片实测高度撑满，需要
            // IntrinsicHeight 给 Row 一个有界高度（stretch 才能生效）。
            child: IntrinsicHeight(
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
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: palette.canvas,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      if (firstOfDay)
                        Positioned(
                          left: 0,
                          top: 1,
                          width: 38,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              _dayLabel(mark.createdAt),
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
                  child: _MarkRow(
                    key: ValueKey('mark-row-${mark.key}'),
                    entry: mark,
                    onTap: () => _openMark(mark),
                  ),
                ),
              ],
            ),
            ),
          ); // return Padding
        },
      );

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

  Widget _buildEmpty(HomePalette palette) {
    final showMarks = _type == NoteTypeFilter.marks;
    final filtered = _filters.isActive ||
        (_type != NoteTypeFilter.all && !showMarks);
    final (String title, String hint, IconData icon) = showMarks
        ? (
            _markStyleFilter == null
                ? '还没有划线'
                : '没有符合条件的划线',
            '阅读时选中一句 → 划线 / 荧光笔，这里就会收进来',
            LucideIcons.highlighter,
          )
        : switch (_viewMode) {
            _NotesViewMode.books => (
              '没有可查看的书籍',
              '写过的书会按最近笔记时间排列',
              LucideIcons.book_open,
            ),
            _NotesViewMode.timeline => (
              filtered ? '没有符合筛选条件的笔记' : '还没有笔记',
              filtered ? '可调整书籍、时间、类型、分类或标签' : '阅读时长按选中句子 → 批注 / 书摘',
              LucideIcons.pen_line,
            ),
          };
    final clearable = showMarks
        ? _markStyleFilter != null
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
                _markStyleFilter = null;
              }),
              child: const Text('清除全部筛选'),
            ),
          ],
        ],
      ),
    );
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
    required this.badges,
    required this.onRemoveTag,
    this.ghostId,
    this.hoverTag,
    this.hovered = false,
    required this.onDragFinished,
    required this.onOpen,
    required this.onEdit,
  });

  final ReaderAnnotation note;

  /// 书名已按阅读历史/书单缓存兜底，空字符串表示确实不知道是哪本书。
  final String bookTitle;
  final bool firstOfDay;
  final bool lastOfDay;

  /// 类型与自由标签混排，已按「全部类型」的顺序排好，全部展示。
  ///
  /// 拖动悬停时磁力虚影（[ghostId] 标记的那枚）已插进它松手后应落的
  /// 排序位置，渲染时用虚影角标代替普通角标即可。
  final List<NoteTagDrag> badges;
  final String? ghostId;
  final NoteTagDrag? hoverTag;
  final bool hovered;
  final void Function(NoteTagDrag badge) onRemoveTag;
  final VoidCallback onDragFinished;
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
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: hovered ? palette.accentText : palette.line,
                    width: hovered ? 1.2 : 0.5,
                  ),
                  boxShadow: hovered
                      ? [
                          BoxShadow(
                            color: HomePalette.accent.withValues(alpha: 0.18),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
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
                        // 书名固定在标题行，标签另起一行：标签增删、换序、
                        // 拖动都不会再推着书名或别的标签上下跑。
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 22,
                                child: Align(
                                  alignment: Alignment.centerLeft,
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
                        // 时间戳按产品要求不再展示，卡片内只保留章节名。
                        if (note.chapterTitle.isNotEmpty)
                          Text(
                            note.chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: palette.muted,
                            ),
                          ),
                        // 磁力虚影已插在角标列表里（见 [ghostId]），和其他
                        // 角标同一行渲染：拖动中就能预览松手后的落点，
                        // 不再另起一行、松手才归位。
                        if (badges.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final badge in badges)
                                if (badge.id == ghostId)
                                  NoteTagGhost(
                                    key: ValueKey(
                                      'note-ghost-${note.key}-${badge.label}',
                                    ),
                                    label: badge.label,
                                    colorValue: badge.colorValue,
                                    kind: badge.kind,
                                  )
                                else
                                  NoteBadgeChip(
                                    key: ValueKey(
                                      'note-badge-${note.key}-${badge.label}',
                                    ),
                                    label: badge.label,
                                    colorValue: badge.colorValue,
                                    noteKey: note.key,
                                    sourceKind: badge.kind,
                                    // 拖回本条笔记自己时，对应的角标亮一圈：
                                    // 这就是「已命中这里」的吸附提示。
                                    highlighted:
                                        hoverTag != null &&
                                        hoverTag!.kind == badge.kind &&
                                        hoverTag!.label == badge.label,
                                    onDragEnd: (accepted) {
                                      onDragFinished();
                                      if (accepted) return;
                                      onRemoveTag(badge);
                                    },
                                  ),
                            ],
                          ),
                        ],
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
                          // 用户想法与原文同款底色图层：同一 badge 色的
                          // 8% 透明底 + 同圆角/内边距，视觉与引用块成对。
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
                              note.thought,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.55,
                                color: palette.ink,
                              ),
                            ),
                          ),
                        ],
                        // 分类（文件夹）chip 按产品要求不再在卡片内展示；
                        // 分类仍保留在数据与编辑器中。
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

/// 「按书查看」点开一本后的范围条：返回全部书籍 + 当前书名 + 条数。
class _BookScopeBar extends StatelessWidget {
  const _BookScopeBar({
    required this.title,
    required this.count,
    required this.onBack,
  });

  final String title;
  final int count;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 16, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('notes-book-back'),
            tooltip: '返回全部书籍',
            visualDensity: VisualDensity.compact,
            icon: const Icon(LucideIcons.chevron_left, size: 20),
            color: palette.muted,
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count 条',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.muted,
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

/// 「全部类型」一行里一枚标签的静态几何：相对首枚的左边界 + 宽度。
class _PaletteSlot {
  const _PaletteSlot(this.left, this.width);

  final double left;
  final double width;
}

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
