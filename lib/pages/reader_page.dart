import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_comment.dart';
import '../models/chapter_ideas.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_theme.dart';
import '../services/backend_transport.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/reader_device.dart';
import '../services/eink_refresh.dart';
import '../services/volume_key.dart';
import '../services/reader_history.dart';
import '../services/reader_preferences.dart';
import '../services/reader_tap_zones.dart';
import '../services/app_log.dart';
import '../services/reader_annotation_store.dart';
import '../services/reading_stats_store.dart';
import '../services/reader_underline_store.dart';
import '../services/system_tts.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/reader_bubble.dart';
import '../widgets/reader/reader_chapter_layout.dart';
import '../widgets/reader/reader_controls.dart';
import '../widgets/reader/reader_cutout_insets.dart';
import '../widgets/reader/reader_illustration.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../widgets/reader/reader_paged_view.dart';
import '../widgets/content_rating_chip.dart';
import '../widgets/reader/reader_note_block.dart';
import '../widgets/reader/reader_paragraph_menu.dart';
import '../widgets/reader/reader_status_bar.dart';
import '../widgets/reader/reader_text_selection.dart';
import '../widgets/reader/reader_theme.dart';
import 'audio_page.dart';

typedef ChapterTextLoader = Future<String> Function(Chapter chapter);
typedef _LoadedChapter = ({String text, bool fetched});

/// Loads a chapter's paragraph ideas (段评).
typedef ChapterIdeasLoader = Future<ChapterIdeas> Function(String itemId);

/// Resolves the comment bodies for one paragraph's idea bucket. [cursor] is
/// the previous page's offset while paging, null on the first request.
typedef ParagraphCommentResolver =
    Future<BookCommentPage> Function(
      String itemId,
      ParagraphIdeas paragraph,
      String? cursor,
    );

class ReaderPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;
  final bool localOnly;
  final ChapterTextLoader? chapterLoader;
  final ReaderStore? readerStore;
  final ChapterCache? chapterCache;
  final ReaderDevice? readerDevice;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Local 划线 storage. Defaults to the device-wide box.
  final ReaderUnderlineStore? underlineStore;

  /// 【青茄重构·新增】批注/书摘存储（默认单例；测试可注入）。
  final ReaderAnnotationStore? annotationStore;

  /// 【青茄重构·新增】打开后直接定位到的正文偏移（字符坐标）。
  /// 笔记页「定位原文」用它覆盖已保存进度。
  final int? startTextOffset;

  /// 【青茄重构·新增】内容分级（12+ / 15+），null 表示入口未提供，
  /// 不显示标签。见 `ContentRating`。
  final String? ageRating;

  /// Paragraph ideas for the current chapter. When both this and
  /// [commentResolver] are null the reader fetches them itself, unless a
  /// [chapterCache] was injected (an injected cache marks the caller as
  /// driving its own data).
  final ChapterIdeasLoader? ideasLoader;

  /// Resolves one paragraph's comment bodies. See [ParagraphCommentResolver].
  final ParagraphCommentResolver? commentResolver;

  const ReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    this.cover = '',
    required this.chapters,
    required this.startIndex,
    this.localOnly = false,
    this.chapterLoader,
    this.readerStore,
    this.chapterCache,
    this.readerDevice,
    this.imageProviderFactory,
    this.ideasLoader,
    this.commentResolver,
    this.underlineStore,
    this.annotationStore,
    this.startTextOffset,
    this.ageRating,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

// Note: 菜单覆盖层与正文布局分离；见
// .agents/notes/implemented/feature/2026-09-10-reader-interface.md
class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late int _index;
  final ScrollController _scrollController = ScrollController();
  Timer? _saveTimer;

  /// 滚动模式下拖过边界的累计量：超过阈值才触发连续阅读跨章，避免轻微
  /// 回弹误触（与分页视图的 32px 边界阈值一致）。带符号：拖过底部为正，
  /// 拖过顶部为负；同一拖拽内反向会抵消累计量。
  double _scrollOverscroll = 0;

  /// In-flight chapter fetch. Switching chapters or leaving the reader cancels
  /// it, so a slow chapter cannot keep the upstream request alive.
  BackendRequest? _chapterRequest;

  String _content = '';
  ChapterContent _chapterContent = ChapterContent(blocks: const []);
  ChapterIdeas _ideas = ChapterIdeas.empty;
  bool _loading = true;
  bool _progressReady = false;
  double _lastPosition = 0;
  double _lastMaxScroll = 0;
  String? _error;
  ReaderPreferences _preferences = const ReaderPreferences();
  ReaderThemePreset _dayTheme = ReaderThemePreset.light;
  bool _controlsVisible = false;

  /// 自动翻页: a repeating timer flips forward every [ReaderPreferences.autoTurnSeconds]
  /// seconds; any tap or drag stops it. See
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Timer? _autoTurnTimer;

  bool get _paged => _preferences.pageMode == ReaderPageMode.paged;

  /// 全局墨水屏模式覆盖阅读器显示预设（#15/#9）：开启时阅读器强制纯黑白，
  /// 不改用户保存的预设，关闭后恢复原预设。夜间切换等仍写保存的预设。
  ReaderThemePreset get _effectivePreset => einkModeNotifier.value
      ? ReaderThemePreset.eink
      : _preferences.themePreset;

  /// 排版用的偏好：墨水屏模式下把预设换成 eink，正文/标题才是 #000000。
  ///
  /// 页面背景早就走 [_effectivePreset]，但 [ReaderLayoutSpec] 的正文、标题
  /// 颜色和 [ReaderControls] 自己的读色都取自这里传入的 preferences。之前
  /// 两处直接传 [_preferences]，于是全局墨水屏开启后正文仍用用户保存预设的
  /// textColor（默认米白 #292724）——实测设备上正文主色 RGB(41,39,36)，
  /// 墨水屏把它量化成明显发灰的一档。保存的预设不动，关闭墨水屏即恢复。
  ReaderPreferences get _displayPreferences => einkModeNotifier.value
      ? _preferences.copyWith(themePreset: ReaderThemePreset.eink)
      : _preferences;

  /// 原生层（MainActivity.dispatchKeyEvent）拦截到音量键后回调：仅在阅读页
  /// 当前路由、未显示控制栏、已开启音量键翻页、且为分页模式时翻页。
  void _onVolumeKey(int direction) {
    if (!mounted ||
        !_routeCurrent ||
        _controlsVisible ||
        !_preferences.volumeKeyTurn ||
        !_paged) {
      return;
    }
    _pauseListenFollow();
    _stopAutoTurn();
    unawaited(_turnPage(direction));
  }

  /// 根据当前状态同步原生是否拦截音量键：仅当阅读页是当前路由、未显示控制栏、
  /// 已开启音量键翻页、且为分页模式时启用。其余情况放行系统音量。
  void _syncVolumeKeyEnabled() {
    unawaited(
      VolumeKeyService.instance.setEnabled(
        _routeCurrent &&
            _preferences.volumeKeyTurn &&
            !_controlsVisible &&
            _paged,
      ),
    );
  }

  void _toggleAutoTurn() {
    if (_autoTurnTimer != null) {
      _stopAutoTurn();
      return;
    }
    _controlsVisible = false;
    _autoTurnTimer = Timer.periodic(
      Duration(seconds: _preferences.autoTurnSeconds),
      (_) => _autoTurnStep(),
    );
    if (mounted) setState(() {});
  }

  void _stopAutoTurn() {
    _autoTurnTimer?.cancel();
    _autoTurnTimer = null;
    if (mounted) setState(() {});
  }

  /// 听书跟随翻页: the audio page is narrating this chapter, so land on the
  /// page holding the estimated playback position. Instant jumps — the
  /// narration keeps moving and an animated chase would always lag.
  ///
  /// 用户接管闩锁: a manual page turn pauses following briefly, so the reader
  /// does not yank the page back within a second.
  DateTime _listenFollowPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _pauseListenFollow() {
    _listenFollowPausedUntil = DateTime.now().add(const Duration(seconds: 15));
  }

  /// 朗读句高亮：与跟随翻页独立同步，跟随关闭时高亮仍可显示；暂停、
  /// 切章或未在读本章时清空。
  (int, int)? _narrationRange;

  void _syncNarrationHighlight() {
    if (!mounted) return;
    final layout = _chapterLayout;
    (int, int)? next;
    final session = ListeningSession.instance;
    if (_preferences.narrationHighlight &&
        layout != null &&
        session.matches(widget.bookId, _chapter.itemId)) {
      final ttsRange = session.sentenceRange;
      if (ttsRange != null) {
        final translated = narrationLayoutRange(layout, ttsRange);
        if (translated != null) {
          next = (translated.start, translated.end);
        }
      }
    }
    if (next != _narrationRange) {
      setState(() => _narrationRange = next);
    }
  }

  void _onListeningTick() {
    _syncNarrationHighlight();
    if (!mounted ||
        !_routeCurrent ||
        !_appActive ||
        !_preferences.listeningFollow ||
        _autoTurnTimer != null ||
        _controlsVisible ||
        _loading ||
        _changingChapter ||
        _error != null) {
      return;
    }
    if (DateTime.now().isBefore(_listenFollowPausedUntil)) return;
    final session = ListeningSession.instance;
    if (!session.playing || session.bookId != widget.bookId) return;
    if (session.chapterId != _chapter.itemId) {
      final next = widget.chapters.indexWhere(
        (c) => c.itemId == session.chapterId,
      );
      if (next >= 0) unawaited(_jumpToChapter(next, followListening: true));
      return;
    }
    if (!session.matches(widget.bookId, _chapter.itemId)) return;
    final progress = session.progress;
    if (_paged) {
      _pagedKey.currentState?.followProgress(progress);
    } else if (_scrollController.hasClients) {
      final position = _scrollController.position;
      // 【青茄修复·滚动无缝】跟着读的是「活动段」，不是整条窗口：
      // progress 是章内比例，必须换算成段内偏移再加段起点。
      final segment = _activeScrollSegment;
      final top = segment?.top ?? 0.0;
      final span = segment?.extent ?? position.maxScrollExtent;
      if (span > 0) {
        _scrollController.jumpTo(top + progress.clamp(0.0, 1.0) * span);
      }
    }
  }

  void _autoTurnStep() {
    if (!mounted) return _stopAutoTurn();
    if (_loading || !_progressReady || _changingChapter) return;
    if (_index == widget.chapters.length - 1) {
      final atEnd = _paged
          ? _pagedKey.currentState?.isAtEndPage == true
          : _scrollController.hasClients &&
                _scrollController.position.pixels >=
                    _scrollController.position.maxScrollExtent - 2;
      if (atEnd) return _stopAutoTurn();
    }
    // Share the manual page-turn path so scrolling also crosses chapters.
    unawaited(_turnPage(1));
  }

  double? _chapterSeekValue;
  int _loadGeneration = 0;
  // Legado-style reading time: deltas are settled at scroll stops, chapter
  // switches and dispose, so no background timer is needed.
  DateTime _readStart = DateTime.now();
  bool _sessionActive = false;
  bool _appActive = true;
  bool _routeCurrent = false;
  bool _changingChapter = false;

  /// 墨水屏整屏刷新计数器：每翻一页 +1，达到 [_ReaderState._einkRefreshInterval]
  /// 阈值（来自 [_preferences.einkRefreshInterval]）就调用一次海信 EPD 全刷压残影，
  /// 然后归零。仅在全局墨水屏模式开启时累加。
  int _einkPageCounter = 0;

  /// Chapter-boundary transition handed to [ReaderPagedView]; see
  /// [ReaderChapterTurn]. Set by [_next] / [_prev] and cleared once the slide
  /// finishes, or when the chapter fails to load.
  // Note: .agents/notes/implemented/bug-fix/2026-10-15-reader-chapter-turn-animation.md
  ReaderChapterTurn? _chapterTurnRequest;

  /// Height of the reader's own bottom toolbar (目录/夜间/听书/设置) as measured
  /// on device, including its safe-area inset. The paragraph action bar keeps
  /// clear of it so a long press near the page foot flips above the line
  /// instead of landing on top of the controls.
  static const _bottomBarHeight = 74.0;

  /// Set while 从本段听 is waiting on a timeline fetch, so a repeated long-press
  /// cannot stack a second listening page (and a second player) on top.
  bool _openingListening = false;
  final LinkedHashMap<String, String> _chapterCache = LinkedHashMap();
  final Map<String, Future<_LoadedChapter>> _chapterRequests = {};
  final Map<String, int> _chapterCacheRevisions = {};
  final Map<String, Future<void>> _chapterRefreshes = {};
  Future<void>? _catalogFuture;
  late final ReaderHistory _history = ReaderHistory(_readerStore);
  late final ReaderDevice _device = widget.readerDevice ?? ReaderDevice();
  late final Future<void> _preferencesFuture;
  StreamSubscription<ReaderDeviceStatus>? _deviceSubscription;
  ReaderDeviceStatus _deviceStatus = ReaderDeviceStatus(time: DateTime.now());
  bool _deviceAvailable = false;
  bool _preferencesReady = false;
  bool _preferencesDirty = false;
  int _deviceGeneration = 0;
  int _brightnessGeneration = 0;
  int _fontGeneration = 0;
  String? _fontFamily;
  final _viewportKey = GlobalKey();
  final _pagedKey = GlobalKey<ReaderPagedViewState>();
  ReaderChapterLayout? _chapterLayout;
  ReaderPageMode? _layoutMode;
  int _layoutRevision = 0;

  // ===== 【青茄修复·滚动无缝】章节段窗口 =====
  //
  // 滚动模式不再「一章一个 ListView」：当前章之后预取的一章作为「段」接在
  // 同一棵 ListView 的尾部，段与段之间不留间隔、不插任何按钮。视口中心滚到
  // 哪一段，就把该段静默切换成「当前章」（不改列表内容、不 jumpTo）。
  // 分页模式完全不走这套，仍用 _chapterLayout。
  final List<_ScrollSegment> _scrollSegments = [];

  /// 当前视口中心所在的段（同时决定 `_index/_chapterLayout/...` 指向哪一章）。
  int _scrollActive = 0;

  /// 窗口对应的「书 + 章」与排版规格：任一变化都要把窗口从当前章重建。
  String? _scrollWindowBookChapter;
  ReaderLayoutSpec? _scrollWindowSpec;

  /// 正在预取的相邻章（防止滚动时重复发起）。
  bool _scrollBusy = false;

  /// 拍平后的列表项（段下标, 块下标）。只在段变化时重建。
  List<({int segment, int block})>? _scrollItems;

  /// 上一帧 _prepareLayout 是否已经把滚动位置重新定位过（恢复/换字号/换模式）。
  /// 重新定位过就不再做段窗口的偏移补偿，避免两个 jumpTo 互相打架。
  bool _layoutRepositioned = false;

  /// Bumped whenever [_ideas] changes. Cached layouts remember the revision they
  /// were measured with, so a chapter is re-measured once its paragraph bubbles
  /// arrive even though the text, font and viewport are unchanged.
  int _ideasRevision = 0;
  int _layoutIdeasRevision = -1;

  /// Whether the cached layout was measured with bubbles visible. Toggling
  /// the 段评气泡 switch must re-measure: the bubble placeholders change
  /// the text layout, so the cached layout is not reusable across a toggle.
  bool _layoutBubblesVisible = true;

  /// Paragraph ids of this chapter carrying a locally saved 划线.
  Set<int> _underlines = const {};

  /// Locally saved character-range 划线 of this chapter (the selection-model
  /// records; paragraph ones live in [_underlines]).
  List<ReaderRangeUnderline> _rangeUnderlines = const [];

  /// 【青茄重构·新增】本章批注/书摘（行内批注块 + 红线）。
  List<ReaderAnnotation> _annotations = const [];
  int _annotationRevision = 0;
  int _layoutAnnotationRevision = -1;
  late final VoidCallback _annotationListener;

  // ===== 【青茄重构·新增】护眼提醒 =====
  /// 连续阅读提醒间隔（青少年护眼边界，不做家长监护）。
  static const _eyeCareInterval = Duration(minutes: 45);

  Timer? _eyeCareTimer;

  /// 本次阅读会话选择「今天不再提醒」后置位。
  bool _eyeCareMuted = false;

  // ===== 【青茄重构·新增】阅读字数统计 =====
  /// 本次会话已计入字数的章节，来回翻页不重复累加。
  final Set<String> _countedChapters = <String>{};

  /// The live text selection — a whole paragraph right after a long press,
  /// then reshaped character-by-character by dragging a handle. Cleared on an
  /// outside tap, a scroll or a page turn, like the official selection.
  // Note: 选区模型（坐标空间、几何注册表、非模态操作条）—
  // 见 .agents/notes/implemented/feature/2026-09-19-reader-selection-model.md
  ReaderTextSelection? _selection;

  /// Palette plus hit-test registry, rebuilt per layout so stale blocks can
  /// never answer a drag from the previous chapter.
  ReaderSelectionScope? _marksScope;
  ReaderChapterLayout? _marksScopeLayout;
  final _selectionOverlayKey = GlobalKey();

  /// True while the action bar is up in the page overlay. It is non-modal —
  /// the official PopupWindow is too — so the drag handles stay touchable
  /// while it shows, and a tap outside it cancels the selection.
  bool _selectionBarOpen = false;

  /// The anchor (window coordinates) the bar was opened with: the long-press
  /// point or the handle position at drag end, with y re-based onto the
  /// selection's bottom so the bar can never cover the selected lines.
  Offset _selectionBarAnchor = Offset.zero;

  /// The selection's top edge (window coordinates) — the flip reference when
  /// the bar has to move above the selection instead of below it.
  Offset? _selectionBarTopAnchor;

  /// Gap between the selection's last line bottom and the bar's arrow tip:
  /// the end caret's dot protrudes 6dp, plus 4dp of air.
  static const _barSelectionClearance = 10.0;

  /// True while a long-press drag is reshaping the selection without the
  /// finger ever having grabbed a handle (官方不抬手拖动).
  bool _longPressDragging = false;

  int _underlineRevision = 0;
  int _layoutUnderlineRevision = -1;
  int _textOffset = 0;
  int _pageIndex = 0;
  Map<String, dynamic>? _savedPosition;
  bool _needsRestore = true;
  bool _requestedStartAtEnd = false;

  Chapter get _chapter => widget.chapters[_index];
  ReaderStore get _readerStore => widget.readerStore ?? LibraryStore.instance;
  ChapterCache get _diskCache =>
      widget.chapterCache ?? ChapterCacheStore.instance;
  CachedBook get _cachedBook => CachedBook(
    id: widget.bookId,
    title: widget.title,
    cover: widget.cover,
    chapters: widget.chapters,
  );

  @override
  void initState() {
    super.initState();
    VolumeKeyService.instance.setOnVolumeKey(_onVolumeKey);
    _syncVolumeKeyEnabled();
    ListeningSession.instance.addListener(_onListeningTick);
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _scrollController.addListener(_onScroll);
    // 【青茄重构·新增】批注块内的删除/编辑直接写存储，这里跟随后刷新。
    _annotationListener = () {
      if (mounted) unawaited(_loadAnnotations());
    };
    _annotationStore.changes.addListener(_annotationListener);
    _preferencesFuture = _loadPreferences();
    _startEyeCareTimer();
    if (widget.chapters.isEmpty) {
      _loading = false;
      _error = '暂无可阅读章节';
    } else {
      if (!widget.localOnly) {
        unawaited(_ensureCatalog().catchError((_) {}));
      }
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == current) return;
    _routeCurrent = current;
    _syncSystemBars();
    _syncVolumeKeyEnabled();
  }

  // Note: Route/lifecycle ownership and SDK 36 compatibility; see
  // .agents/notes/implemented/bug-fix/2026-10-12-reader-system-bars.md.
  // 【青茄修复·状态栏常显】曾经的「段评弹层保持沉浸」(#57) 逻辑已随
  // 沉浸模式整体下线：状态栏常显后没有任何显隐切换，也就没有闪烁。

  // 【青茄修复·进章顺滑】正文排版是重活（整章逐段 TextPainter 量高），
  // 若在路由转场动画进行中排版，动画必掉帧。等转场完成再放正文：
  // 代价是内容晚约 200ms 出现，换来整段动画全程流畅。
  bool _routeIntroReady = false;
  Animation<double>? _introAnimation;

  void _watchRouteIntro() {
    if (_routeIntroReady) return;
    final animation = _introAnimation ??= ModalRoute.of(context)?.animation;
    if (animation == null) {
      _routeIntroReady = true;
      return;
    }
    if (animation.status == AnimationStatus.completed) {
      _routeIntroReady = true;
      return;
    }
    if (animation.status != AnimationStatus.forward) return;
    animation.addStatusListener(_onIntroStatus);
  }

  void _onIntroStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    setState(() => _routeIntroReady = true);
  }

  void _syncSystemBars() {
    // 【青茄修复·状态栏常显】不再进入沉浸模式：系统状态栏（电量/WiFi/
    // 信号/时间）在阅读器全程可见。之前进正文隐藏、退出再显示，系统栏
    // 一隐一显会让正文整体上移/下移各跳一次，是进入/退出卡顿的来源之一；
    // 常显之后布局恒定，状态栏底色由 AnnotatedRegion 跟随阅读主题。
    // 段评弹层（#57）的沉浸保持逻辑随之失效，保留标记不再生效。
    unawaited(_device.setImmersive(false));
  }

  Future<void> _loadPreferences() async {
    ReaderPreferences preferences;
    try {
      preferences = await ReaderPreferences.load();
    } catch (_) {
      preferences = const ReaderPreferences();
    }
    if (!mounted) return;
    setState(() {
      _preferences = preferences;
      _preferencesReady = true;
      if (preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = preferences.themePreset;
      }
    });
    _syncVolumeKeyEnabled();
    await _loadFont(preferences.fontPath);
    if (mounted && _appActive) unawaited(_refreshDevice());
  }

  Future<void> _refreshDevice() async {
    if (!_preferencesReady || !_appActive || widget.chapters.isEmpty) return;
    final generation = ++_deviceGeneration;
    final status = await _device.start(
      followSystem: _preferences.followSystemBrightness,
      brightness: _preferences.brightness,
    );
    if (!mounted || generation != _deviceGeneration || !_appActive) return;
    setState(() {
      _deviceAvailable = status != null;
      if (status != null) _deviceStatus = status;
    });
    if (status != null) {
      _deviceSubscription ??= _device.changes.listen((status) {
        if (mounted && _appActive) setState(() => _deviceStatus = status);
      }, onError: (Object _) {});
    }
    // 进入阅读器即按偏好应用常亮(否则只有动过设置才生效)。
    unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
  }

  Future<void> _loadFont(String path) async {
    final generation = ++_fontGeneration;
    try {
      final family = await ReaderFonts.load(path);
      if (!mounted || generation != _fontGeneration) return;
      setState(() => _fontFamily = family);
    } on ReaderFontLimitException {
      if (!mounted || generation != _fontGeneration) return;
      setState(() => _fontFamily = null);
      _showMessage('已导入字体过多，重启应用后可继续更换字体');
    } catch (_) {
      if (!mounted || generation != _fontGeneration) return;
      setState(() {
        _fontFamily = null;
        _preferences = _preferences.copyWith(fontPath: '', fontName: '');
        _preferencesDirty = true;
      });
      _showMessage('字体无法读取，已使用系统字体');
    }
  }

  Future<ReaderFont?> _pickFont() async {
    final font = await _device.pickFont();
    if (font == null) return null;
    try {
      await ReaderFonts.load(font.path);
    } on ReaderFontLimitException {
      if (mounted) _showMessage('已导入字体过多，重启应用后可继续更换字体');
      return null;
    }
    return font;
  }

  Future<void> _savePreferences({bool applyKeepScreenOn = true}) async {
    if (applyKeepScreenOn) {
      unawaited(_device.keepScreenOn(_preferences.keepScreenOn));
    }
    if (!_preferencesReady || !_preferencesDirty) return;
    final snapshot = _preferences;
    _preferencesDirty = false;
    try {
      await snapshot.save();
    } catch (_) {
      _preferencesDirty = true;
      if (mounted) _showMessage('设置保存失败，请重试');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Long press on a paragraph: select it whole and open the action bar.
  ///
  /// Identity comes from [ReaderContentBlock.textId], which falls back to the
  /// paragraph's ordinal when the markup carried no `idx` (the plain-text
  /// `/api/content` path). Requiring `idx` here is what used to make a long
  /// press do literally nothing on those chapters.
  ///
  /// Note: .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
  Future<void> _onParagraphLongPress(
    ReaderContentBlock block,
    Offset position,
  ) async {
    if (block.isTitle || block.isImage || block.textId == null) return;
    _longPressDragging = false;
    // 选中文字,暂停自动翻页 — the official selection helper does the same
    // (selection/h.java#a).
    _stopAutoTurn();
    // A second long press replaces the selection; the old bar pops without
    // cancelling — the new selection takes over.
    _closeSelectionBar(clearSelection: false);
    if (!mounted) return;
    // 官方 ke5.a.a 的 SelectTextByRange 分支: long-pressing text that already
    // carries a range underline restores that exact range instead of the
    // whole paragraph.
    ReaderRangeUnderline? hit;
    final pressed = _marksScope?.geometry.chapterOffsetAt(position);
    if (pressed != null) {
      for (final underline in _rangeUnderlines) {
        if (underline.start <= pressed && pressed < underline.end) {
          hit = underline;
          break;
        }
      }
    }
    // 【青茄修复·长按选句】默认粒度从「整段」改成「手指下的那句话」：
    // 点在已有划线上仍恢复划线范围；位置取不到（落在插图/边缘）时兜底整段。
    var selectionStart = hit?.start ?? block.start;
    var selectionEnd = hit?.end ?? block.end;
    if (hit == null &&
        pressed != null &&
        pressed >= block.start &&
        pressed < block.end) {
      final (sentenceStart, sentenceEnd) = sentenceRangeInText(
        block.text,
        pressed - block.start,
      );
      if (sentenceEnd > sentenceStart) {
        selectionStart = block.start + sentenceStart;
        selectionEnd = block.start + sentenceEnd;
      }
    }
    final selection = ReaderTextSelection(
      start: selectionStart,
      end: selectionEnd,
    );
    setState(() {
      _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      );
    });
    _updateHandlePositions();
    _openSelectionBar(anchor: position);
  }

  /// 官方的不抬手拖动 (TTMarkingHelper 的 MOVE 分支): 长按选中后手指继续
  /// 移动,选区跟着手指逐字符重算,第一帧起收条;拖哪个点按手指落在选区的
  /// 上半还是下半推断 (D() 的中点规则),不必精确抓到控点。
  void _onParagraphLongPressMoveUpdate(Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    if (!_longPressDragging) {
      _longPressDragging = true;
      _closeSelectionBar(clearSelection: false);
    }
    _onHandleDrag(_dragIsStartBound(global), global);
  }

  void _onParagraphLongPressEnd(Offset global) {
    if (!_longPressDragging) return;
    _longPressDragging = false;
    _onHandleDragEnd(false, global);
  }

  /// 官方 D(): finger above the selection's vertical midpoint drags the start
  /// bound, below it the end bound.
  bool _dragIsStartBound(Offset global) {
    final startTop = _selectionBoundGlobal(isStart: true)?.dy;
    final endBottom = _selectionBoundGlobal(isStart: false)?.dy;
    if (startTop == null || endBottom == null) return true;
    return global.dy < (startTop + endBottom) / 2;
  }

  /// Global position of one bound's anchor — the start bound's line top or
  /// the end bound's line bottom — or null when its block is not mounted.
  Offset? _selectionBoundGlobal({required bool isStart}) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final anchor = selectionAnchor(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    return entry.box.localToGlobal(anchor);
  }

  /// Opens the action bar for the current selection. The bar lives in the
  /// page's own overlay Stack — non-modal, like the official PopupWindow — so
  /// the drag handles stay touchable while it is up, and a tap outside it
  /// reaches the page surface, which cancels the selection.
  ///
  /// 官方条子锚在整个选区上,绝不遮选区([yd5.j] 的条子几何): y 取选区
  /// 末端行的行底再让开末端圆点,x 跟手指;选区顶端作为翻转参考传下去。
  void _openSelectionBar({required Offset anchor}) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return;
    final bottom = _selectionBoundGlobal(isStart: false);
    final top = _selectionBoundGlobal(isStart: true);
    setState(() {
      _selectionBarAnchor = Offset(
        anchor.dx,
        bottom == null ? anchor.dy : bottom.dy + _barSelectionClearance,
      );
      _selectionBarTopAnchor = top;
      _selectionBarOpen = true;
    });
  }

  /// Hides the action bar; [clearSelection] also cancels the selection
  /// (outside tap, scroll, page turn — anything but a handle drag).
  void _closeSelectionBar({required bool clearSelection}) {
    if (clearSelection) _clearSelection();
    if (!_selectionBarOpen) return;
    setState(() => _selectionBarOpen = false);
  }

  /// The action bar overlay, or null while no selection is active. Geometry
  /// re-resolves per build so the bar always clears the system bars and the
  /// reader's own bottom toolbar.
  ///
  // Note: 选区条坐标系、段落时间轴映射与批量审查回退的来龙去脉 —
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-cross-review-batch-fixes.md
  /// [windowPadding] is the *window's* safe area, captured above the reader's
  /// own SafeArea: the anchor is a window coordinate while the bar is
  /// positioned inside the overlay Stack below that SafeArea (and below the
  /// reading-info row), so the anchor is converted into overlay-local space
  /// and the flip/clamp maths run against the overlay's own size. Using the
  /// window geometry directly shifted the bar one status-bar height down on
  /// every device whose top inset is non-zero.
  Widget? _selectionBar(ReaderThemePreset preset, EdgeInsets windowPadding) {
    final selection = _selection;
    if (!_selectionBarOpen || selection == null || !selection.isValid) {
      return null;
    }
    final media = MediaQuery.of(context);
    final underlined = _selectionUnderlined;
    var anchor = _selectionBarAnchor;
    var topAnchor = _selectionBarTopAnchor;
    var view = media.size;
    var safeArea = media.padding;
    var avoidBottom = _controlsVisible ? _bottomBarHeight : 0.0;
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox != null && overlayBox.attached) {
      anchor = overlayBox.globalToLocal(_selectionBarAnchor);
      topAnchor = _selectionBarTopAnchor == null
          ? null
          : overlayBox.globalToLocal(_selectionBarTopAnchor!);
      view = overlayBox.size;
      // The system insets are already consumed by the outer SafeArea, so the
      // overlay only needs a margin of its own; the reader's bottom toolbar
      // height includes the bottom inset, so subtract what SafeArea padded.
      safeArea = EdgeInsets.zero;
      avoidBottom = (avoidBottom - windowPadding.bottom).clamp(
        0.0,
        double.infinity,
      );
    } else {
      // No overlay box (loading/error fallback): the top anchor would be in a
      // different coordinate space than the bar maths — drop the flip
      // reference rather than flip to a wrong place.
      topAnchor = null;
    }
    final (position, below) = ReaderParagraphMenu.resolvePosition(
      anchor: anchor,
      topAnchor: topAnchor,
      paragraphScoped: selection.isWholeParagraph,
      view: view,
      safeArea: safeArea,
      underlined: underlined,
      showListening: true,
      avoidBottom: avoidBottom,
    );
    return Positioned(
      key: const ValueKey('reader-selection-bar'),
      left: position.dx,
      top: position.dy,
      child: ReaderParagraphMenu(
        underlined: underlined,
        paragraphScoped: selection.isWholeParagraph,
        showListening: true,
        isDark: preset.isDark,
        belowAnchor: below,
        onAction: (action) {
          unawaited(() async {
            await _applySelectionAction(action);
            // Every action consumes the selection, like the official bar.
            if (mounted) _closeSelectionBar(clearSelection: true);
          }());
        },
      ),
    );
  }

  void _clearSelection() {
    _longPressDragging = false;
    if (_selection == null) return;
    setState(() => _selection = null);
  }

  bool get _selectionUnderlined {
    final selection = _selection;
    if (selection == null) return false;
    if (selection.isWholeParagraph) {
      final textId = _chapterLayout?.blockAtOffset(selection.start)?.textId;
      if (textId != null && _underlines.contains(textId)) return true;
    }
    // A range record spanning exactly this selection outranks the paragraph
    // identity: a whole-paragraph drag can produce one, and only the range
    // store can ever remove it again.
    return _rangeUnderlines.any(
      (underline) => underline.coversExactly(selection.start, selection.end),
    );
  }

  Future<void> _applySelectionAction(ReaderParagraphAction action) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    switch (action) {
      case ReaderParagraphAction.copy:
        await Clipboard.setData(
          ClipboardData(
            text: layout.textInRange(selection.start, selection.end),
          ),
        );
        if (mounted) _showMessage('已复制');
      case ReaderParagraphAction.listen:
        final block = layout.blockAtOffset(selection.start);
        final textId = block?.textId;
        if (block == null || textId == null) return;
        await _openListening(fromMs: block.startMs, textId: textId);
      case ReaderParagraphAction.underline:
      case ReaderParagraphAction.removeUnderline:
        await _toggleSelectionUnderline(
          add: action == ReaderParagraphAction.underline,
        );
      // 【青茄重构·新增】批注 / 书摘：选中范围落库后由排版层插入行内批注块。
      case ReaderParagraphAction.annot:
        await _createAnnotation(excerpt: false);
      case ReaderParagraphAction.excerpt:
        await _createAnnotation(excerpt: true);
    }
  }

  /// 划线 on the current selection. A whole-paragraph selection keeps the
  /// paragraph-identity store (the pre-selection model, still how saved
  /// marks render); a dragged character range saves a range record.
  Future<void> _toggleSelectionUnderline({required bool add}) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    if (selection.isWholeParagraph) {
      final block = layout.blockAtOffset(selection.start);
      // A range record exactly spanning the paragraph (a whole-paragraph
      // drag) must be toggled in the range store — routing to the
      // paragraph-identity store here would strand it, unreachable for
      // 删除划线 forever.
      final hasExactRange = _rangeUnderlines.any(
        (underline) => underline.coversExactly(selection.start, selection.end),
      );
      if (block != null && !hasExactRange) {
        await _toggleUnderline(block, add: add);
        return;
      }
    }
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    final existing = _rangeUnderlines
        .where(
          (underline) =>
              underline.coversExactly(selection.start, selection.end),
        )
        .toList();
    if (!add && existing.isEmpty) return;
    final record = ReaderRangeUnderline(
      bookId: widget.bookId,
      chapterId: chapterId,
      start: selection.start,
      end: selection.end,
      text: layout.textInRange(selection.start, selection.end),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      if (add) {
        await store.addRange(record);
      } else {
        await store.remove(existing.first.key);
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '删除划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; appending a record that belongs to
    // the previous chapter would paint it onto the new one (the same guard
    // _loadUnderlines applies to its reads).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    setState(() {
      if (add) {
        _rangeUnderlines = [..._rangeUnderlines, record]
          ..sort((a, b) => a.start.compareTo(b.start));
      } else {
        _rangeUnderlines = _rangeUnderlines
            .where((underline) => underline.key != existing.first.key)
            .toList();
      }
    });
    _showMessage(add ? '已划线' : '已删除划线');
  }

  Future<void> _toggleUnderline(
    ReaderContentBlock block, {
    required bool add,
  }) async {
    final textId = block.textId;
    if (textId == null) return;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    final blockIndex = block.index - 1;
    final chapterId = _chapter.itemId;
    final loadGeneration = _loadGeneration;
    try {
      if (add) {
        await store.add(
          ReaderUnderline(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
            text: block.text,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      } else {
        await store.remove(
          ReaderUnderlineStore.keyFor(
            bookId: widget.bookId,
            chapterId: chapterId,
            paraIndex: block.paraIndex,
            blockIndex: blockIndex,
          ),
        );
      }
    } catch (_) {
      if (mounted) _showMessage(add ? '划线保存失败，请重试' : '取消划线失败，请重试');
      return;
    }
    // The await can span a chapter switch; the ids belong to the chapter the
    // underline was toggled in (same guard as _loadUnderlines).
    if (!mounted ||
        loadGeneration != _loadGeneration ||
        chapterId != _chapter.itemId) {
      return;
    }
    setState(() {
      final next = Set<int>.of(_underlines);
      if (add) {
        next.add(textId);
      } else {
        next.remove(textId);
      }
      _underlines = next;
      ++_underlineRevision;
    });
    _showMessage(add ? '已划线' : '已取消划线');
  }

  /// Loads the saved 划线 of this chapter: paragraph ids for the layout and
  /// range records for the mark painter.
  Future<void> _loadUnderlines() async {
    final generation = _loadGeneration;
    final chapterId = _chapter.itemId;
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    Set<int> ids;
    List<ReaderRangeUnderline> ranges;
    try {
      final saved = await store.load(widget.bookId, chapterId);
      ids = {for (final entry in saved.values) entry.id};
      ranges = await store.loadRanges(widget.bookId, chapterId);
    } catch (_) {
      ids = const {};
      ranges = const [];
    }
    if (!mounted || generation != _loadGeneration) return;
    if (chapterId != _chapter.itemId) return;
    setState(() {
      _underlines = ids;
      _rangeUnderlines = ranges;
      ++_underlineRevision;
    });
  }

  // ==================== 【青茄重构·新增】护眼提醒 ====================

  /// 每 [eyeCareInterval] 提醒一次休息。只在本页仍是当前路由时弹出，
  /// 避免用户已经退出阅读却突然收到弹窗。
  void _startEyeCareTimer() {
    _eyeCareTimer?.cancel();
    if (_eyeCareMuted) return;
    _eyeCareTimer = Timer(_eyeCareInterval, () {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) {
        // 不在前台就顺延，回来后再提醒。
        _startEyeCareTimer();
        return;
      }
      unawaited(_showEyeCareReminder());
    });
  }

  Future<void> _showEyeCareReminder() async {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('reader-eye-care-dialog'),
        title: const Text('休息一下眼睛'),
        content: const Text(
          '你已经连续阅读 45 分钟。抬头看看远处，让眼睛放松一会儿再继续吧。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            key: const ValueKey('reader-eye-care-mute'),
            onPressed: () => Navigator.of(dialogContext).pop('mute'),
            child: const Text('今天不再提醒'),
          ),
          TextButton(
            key: const ValueKey('reader-eye-care-later'),
            onPressed: () => Navigator.of(dialogContext).pop('later'),
            child: const Text('再看 15 分钟'),
          ),
          FilledButton(
            key: const ValueKey('reader-eye-care-rest'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE85D26),
            ),
            onPressed: () => Navigator.of(dialogContext).pop('rest'),
            child: const Text('休息一下'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'mute':
        _eyeCareMuted = true;
        _eyeCareTimer?.cancel();
        _showMessage('本次阅读不再提醒');
      case 'rest':
        await _persistProgress();
        if (mounted) Navigator.of(context).maybePop();
      default:
        // 再看 15 分钟：把提醒顺延到一个较短周期。
        _eyeCareTimer?.cancel();
        _eyeCareTimer = Timer(const Duration(minutes: 15), () {
          if (mounted && ModalRoute.of(context)?.isCurrent == true) {
            unawaited(_showEyeCareReminder());
          }
        });
    }
  }

  // ==================== 【青茄重构·新增】批注 / 书摘 ====================

  ReaderAnnotationStore get _annotationStore =>
      widget.annotationStore ?? ReaderAnnotationStore.instance;

  /// 批注红线（蜗牛读书式 2px 下划线），与划线共用章节坐标空间。
  List<ReaderRangeUnderline> get _annotationRanges => [
    for (final note in _annotations)
      ReaderRangeUnderline(
        bookId: note.bookId,
        chapterId: note.chapterId,
        start: note.start,
        end: note.end,
        text: note.text,
        createdAt: note.createdAt,
      ),
  ];

  /// 交给排版层的行内批注块数据。
  List<ReaderInlineNote> get _inlineNotes => [
    for (final note in _annotations)
      ReaderInlineNote(
        id: note.key,
        start: note.start,
        end: note.end,
        quote: note.text,
        thought: note.thought,
        isExcerpt: !note.isAnnot,
      ),
  ];

  /// 加载本章批注/书摘（切章、切书、存储变化时都会重新走一遍）。
  Future<void> _loadAnnotations() async {
    final generation = _loadGeneration;
    final chapterId = _chapter.itemId;
    List<ReaderAnnotation> loaded;
    try {
      loaded = await _annotationStore.load(widget.bookId, chapterId);
    } catch (_) {
      loaded = const [];
    }
    if (!mounted || generation != _loadGeneration) return;
    if (chapterId != _chapter.itemId) return;
    setState(() {
      _annotations = loaded;
      ++_annotationRevision;
    });
  }

  /// 把当前选区写成批注（带想法）或书摘（仅收藏原文）。
  Future<void> _createAnnotation({required bool excerpt}) async {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null || !selection.isValid) return;
    // 先把区间与原文抓出来：下面要立刻清掉选区。
    final start = selection.start;
    final end = selection.end;
    final quote = layout.textInRange(start, end).trim();
    if (quote.isEmpty) return;
    // 【青茄重构·修复】弹层之前先收掉选区与工具条：否则弹层动画期间
    // 选区高亮 + 两端手柄仍在逐帧重绘，真机上表现为「弹出特别卡」。
    _closeSelectionBar(clearSelection: true);
    // 等当前帧结束，让选区先真正从画面消失，再开始弹层动画。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    var thought = '';
    if (!excerpt) {
      final input = await showAnnotationEditor(
        context,
        quote: quote,
        title: '写想法',
      );
      // 取消或留空视为放弃，不产生半成品批注。
      if (input == null || input.trim().isEmpty) return;
      thought = input.trim();
    }
    if (!mounted) return;
    final note = ReaderAnnotation(
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      start: start,
      end: end,
      text: quote,
      thought: thought,
      type: excerpt
          ? ReaderAnnotation.kTypeExcerpt
          : ReaderAnnotation.kTypeAnnot,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      bookTitle: widget.title,
      chapterTitle: _chapter.title,
    );
    try {
      await _annotationStore.add(note);
    } catch (error, stack) {
      // 落盘失败要能在「日志」页里看到具体原因，而不是只有一句提示。
      AppLog.e('annot', '批注保存失败', error: error, stack: stack);
      if (mounted) _showMessage('保存失败，请重试');
      return;
    }
    if (!mounted) return;
    await _loadAnnotations();
    if (mounted) _showMessage(excerpt ? '已加入书摘' : '已添加批注');
  }

  void _changeBrightness(double value, {bool followSystem = false}) {
    _preferencesDirty = true;
    final generation = ++_brightnessGeneration;
    setState(
      () => _preferences = _preferences.copyWith(
        brightness: value,
        followSystemBrightness: followSystem,
      ),
    );
    unawaited(
      _device.setBrightness(followSystem: followSystem, brightness: value).then(
        (applied) {
          if (!applied && mounted && generation == _brightnessGeneration) {
            _showMessage('暂时无法调整亮度，请重新进入阅读界面');
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    _chapterRequest?.cancel();
    VolumeKeyService.instance.setOnVolumeKey(null);
    unawaited(VolumeKeyService.instance.setEnabled(false));
    ListeningSession.instance.removeListener(_onListeningTick);
    _introAnimation?.removeStatusListener(_onIntroStatus);
    _autoTurnTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ++_deviceGeneration;
    unawaited(_deviceSubscription?.cancel());
    // The save must not re-apply keepScreenOn after the explicit clear below,
    // or the screen would stay awake after leaving the reader.
    unawaited(_savePreferences(applyKeepScreenOn: false));
    unawaited(_device.keepScreenOn(false));
    unawaited(_device.close());
    _saveTimer?.cancel();
    _settleReadTime();
    _sessionActive = false;
    unawaited(_persistProgress());
    _eyeCareTimer?.cancel();
    unawaited(ReadingStatsStore.instance.flush());
    _annotationStore.changes.removeListener(_annotationListener);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed && _appActive) {
      _stopAutoTurn();
      ++_deviceGeneration;
      unawaited(_device.suspend());
      _settleReadTime();
      _sessionActive = false;
      _appActive = false;
      unawaited(_persistProgress());
    } else if (resumed && !_appActive) {
      _appActive = true;
      _syncSystemBars();
      unawaited(_refreshDevice());
      if (!_loading && _content.isNotEmpty) {
        _readStart = DateTime.now();
        _sessionActive = true;
        if (_chapterContent.needsRefresh()) {
          unawaited(_refreshCachedChapter(_chapter));
        }
      }
    }
    // 前台/后台切换不影响原生层音量键拦截（在 Activity 层，与 Flutter 生命周期
    // 无关），故此处无需重挂监听；仅同步一次状态即可。
    _syncVolumeKeyEnabled();
  }

  Future<void> _load({
    bool startAtEnd = false,
    ReaderChapterTurn? chapterTurn,
  }) async {
    if (widget.chapters.isEmpty) return;
    final generation = ++_loadGeneration;
    final chapter = _chapter;
    _saveTimer?.cancel();
    setState(() {
      _loading = true;
      _progressReady = false;
      _error = null;
      _content = '';
      _chapterContent = ChapterContent(blocks: const []);
      _chapterLayout = null;
      _layoutMode = null;
      _textOffset = 0;
      _pageIndex = 0;
      _needsRestore = true;
      _requestedStartAtEnd = startAtEnd;
      _sessionActive = false;
      _chapterTurnRequest = chapterTurn;
      // 【青茄修复·滚动无缝】整章加载（目录跳转 / 首尾跨章兜底）后窗口
      // 从当前章重建：旧段全部作废，等新排版出来后重新长出第 0 段。
      _clearScrollWindow();
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    try {
      final loaded = await _chapterText(chapter);
      await _preferencesFuture;
      if (!mounted || generation != _loadGeneration) return;
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(widget.bookId);
        if (saved?['kind'] != null && saved?['kind'] != 'book') saved = null;
      } catch (_) {
        // History storage must not prevent an available chapter from opening.
      }
      if (!mounted || generation != _loadGeneration) return;
      // Cache updates may arrive while preferences/history are being read.
      final text = _chapterCache[chapter.itemId] ?? loaded.text;
      final content = ChapterContent.fromCacheText(text);
      if (content.withoutLeadingTitle(chapter.title).isEmpty) {
        throw ApiException('正文为空');
      }
      setState(() {
        _content = text;
        _chapterContent = content;
        // 【青茄重构·新增】笔记页定位：首次加载的目标章直接跳到批注位置，
        // 用与自动存档一致的 positionVersion=2 结构复用恢复逻辑。
        final jump = widget.startTextOffset;
        _savedPosition =
            jump != null && _index == widget.startIndex && jump >= 0
            ? {
                'chapterId': chapter.itemId,
                'positionVersion': 2,
                'textOffset': jump,
                'kind': 'book',
              }
            : saved;
        _loading = false;
        // Ideas and 划线 belong to the chapter, so they are dropped on every
        // load and fetched again; a stale entry would point at another chapter.
        _ideas = ChapterIdeas.empty;
        _underlines = const {};
        _rangeUnderlines = const [];
        _annotations = const [];
        _selection = null;
        _selectionBarOpen = false;
      });
      unawaited(_prefetchAround(_index));
      unawaited(_loadIdeas(chapter, generation));
      unawaited(_loadUnderlines());
      unawaited(_loadAnnotations());
      // 【青茄重构·新增】按章记一次阅读字数（同一章本次会话只计一次）。
      if (_countedChapters.add(chapter.itemId)) {
        ReadingStatsStore.instance.addCharacters(
          content.withoutLeadingTitle(chapter.title).legacyText.length,
        );
      }
      if (!loaded.fetched && content.needsRefresh()) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _chapterTurnRequest = null;
      });
    }
  }

  /// Loads the chapter's paragraph ideas. Decoration only: a failure leaves the
  /// reader fully usable with the段评 action hidden.
  Future<void> _loadIdeas(Chapter chapter, int generation) async {
    if (widget.localOnly) return;
    final loader = widget.ideasLoader;
    if (loader == null && widget.chapterCache != null) {
      // An injected cache means the caller drives its own data; do not reach
      // for the network behind its back.
      return;
    }
    try {
      final ideas = await (loader ?? _defaultIdeas)(chapter.itemId);
      if (!mounted || generation != _loadGeneration) return;
      if (chapter.itemId != widget.chapters[_index].itemId) return;
      setState(() {
        _ideas = ideas;
        ++_ideasRevision;
      });
      // Note: Old image-aware caches can still lack paragraph ids. Refresh
      // only when ideas need them; never fabricate ids from display order.
      // .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
      if (!_chapterContent.paragraphIdsChecked &&
          ideas.paragraphs.any((paragraph) => paragraph.showsBubble)) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (_) {
      // Keep the section hidden rather than surfacing a failure. Catches Error
      // as well as Exception: ideas are decoration, not a page-level failure.
    }
  }

  /// The in-text paragraph-comment bubble, built during layout so it can be
  /// measured as a placeholder at the end of the paragraph.
  ///
  /// Note: 气泡的门槛与几何规格取自官方客户端 — 见
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Widget _buildParagraphBubble(
    int paraIndex,
    int count,
    ParagraphBubbleVariant variant,
  ) => ReaderParagraphBubble(
    count: count,
    metrics: ReaderBubbleMetrics.forFontSize(
      MediaQuery.textScalerOf(context).scale(_preferences.fontSize),
      variant: variant,
    ),
    preset: _effectivePreset,
    onTap: () => unawaited(_showIdeas(focusParaIndex: paraIndex)),
  );

  Future<void> _showIdeas({int? focusParaIndex}) async {
    if (_ideas.isEmpty) return;
    setState(() => _controlsVisible = false);
    final ideaSnapshot = _ideas;
    final chapter = widget.chapters[_index];
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: _effectivePreset.isDark
            ? _effectivePreset.panelColor
            : Colors.white,
        // E-ink (#57): a dimmed scrim forces a full-screen gray wash and
        // ghosts on e-ink. Transparent keeps the page readable behind the
        // sheet; tapping outside still dismisses it.
        barrierColor: einkModeNotifier.value
            ? Colors.transparent
            : Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (context) => FractionallySizedBox(
          // Match the supplied official screenshot, keeping the paragraph visible
          // above the comments. Note: 2026-09-11-reader-paragraph-bubble.md.
          heightFactor: 0.69,
          child: ReaderIdeasSheet(
            ideas: ideaSnapshot,
            preset: _effectivePreset,
            // Each bubble opens only that paragraph's comments.
            initialParaIndex: focusParaIndex,
            loadComments: (paragraph, cursor) async {
              final resolver = widget.commentResolver;
              if (resolver != null) {
                return resolver(chapter.itemId, paragraph, cursor);
              }
              return _defaultComments(
                chapter,
                paragraph,
                ideaSnapshot.itemVersion,
                cursor,
              );
            },
          ),
        ),
      );
    } finally {
      // 【青茄修复·状态栏常显】沉浸模式已下线：状态栏全程可见，弹层
      // 关闭不需要任何系统栏同步（曾有的 #57 闪烁问题随沉浸一起消失）。
    }
  }

  /// Default idea fetch and comment resolution; see [ReaderPage.ideasLoader].
  Future<ChapterIdeas> _defaultIdeas(String itemId) =>
      ApiClient.instance.chapterIdeas(itemId);

  /// Loads one paragraph's comments.
  ///
  /// Note: the upstream wants `server_channel=38` here, not the 43 the official
  /// presenter assigns, and it needs the chapter version — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Future<BookCommentPage> _defaultComments(
    Chapter chapter,
    ParagraphIdeas paragraph,
    String ideaVersion,
    String? cursor,
  ) {
    return ApiClient.instance.paragraphComments(
      widget.bookId,
      chapter.itemId,
      itemVersion: chapter.version.isNotEmpty ? chapter.version : ideaVersion,
      paraIndex: paragraph.paraIndex,
      cursor: cursor,
    );
  }

  Future<_LoadedChapter> _chapterText(Chapter chapter) async {
    final id = chapter.itemId;
    final cached = _chapterCache.remove(id);
    if (cached != null) {
      _chapterCache[id] = cached;
      return (text: cached, fetched: false);
    }
    final pending = _chapterRequests[id];
    if (pending != null) return pending;

    final request = _loadChapterText(chapter);
    _chapterRequests[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterRequests[id], request)) {
        _chapterRequests.remove(id);
      }
    }
  }

  Future<String> _fetchChapter(Chapter chapter) async {
    final loader = widget.chapterLoader;
    final ChapterContent content;
    if (loader == null) {
      _chapterRequest?.cancel();
      final request = _chapterRequest = BackendRequest();
      content = await ApiClient.instance.withCancellation(
        request,
        () => ApiClient.instance.chapterContent(chapter.itemId),
      );
    } else {
      final text = await loader(chapter);
      content = ChapterContent.isStructuredCache(text)
          ? ChapterContent.fromCacheText(text)
          : ChapterContent.fromPlainText(text, illustrationsChecked: true);
    }
    if (content.withoutLeadingTitle(chapter.title).isEmpty) {
      throw const ApiException('正文为空');
    }
    return content.toCacheText();
  }

  Future<void> _refreshCachedChapter(Chapter chapter) async {
    if (widget.localOnly) return;
    final pending = _chapterRefreshes[chapter.itemId];
    if (pending != null) return pending;
    final request = _upgradeChapter(chapter);
    _chapterRefreshes[chapter.itemId] = request;
    try {
      await request;
    } finally {
      if (identical(_chapterRefreshes[chapter.itemId], request)) {
        _chapterRefreshes.remove(chapter.itemId);
      }
    }
  }

  Future<void> _upgradeChapter(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    try {
      final text = await _fetchChapter(chapter);
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      final content = ChapterContent.fromCacheText(text);
      // This request only refreshes an existing cache, even if its memory
      // entry was evicted while fetching. Partial content cannot improve it.
      if (!content.illustrationsChecked) return;
      var catalogReady = true;
      try {
        await _ensureCatalog();
      } catch (_) {
        catalogReady = false;
      }
      if (!mounted ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0)) {
        return;
      }
      _onChapterContentAvailable(chapter, text);
      if (!catalogReady) return;
      try {
        await _diskCache.write(
          bookId: widget.bookId,
          chapterId: chapter.itemId,
          title: chapter.title,
          text: text,
        );
      } catch (_) {
        // A disk failure does not hide newly fetched illustrations.
      }
    } catch (_) {
      // Legacy text remains immediately readable, including while offline.
    }
  }

  void _rememberChapter(String id, String text) {
    _chapterCache.remove(id);
    _chapterCache[id] = text;
    while (_chapterCache.length > 5) {
      _chapterCache.remove(
        _chapterCache.keys.firstWhere((id) => id != _chapter.itemId),
      );
    }
  }

  // Note: 批量补图与预取共享缓存版本，迟到旧结果不能覆盖新图文；见
  // .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
  void _onChapterContentAvailable(Chapter chapter, String text) {
    // A cache hit must not invalidate an in-flight signature refresh.
    if (!mounted || _chapterCache[chapter.itemId] == text) return;
    final fetched = ChapterContent.fromCacheText(text);
    final cached = _chapterCache[chapter.itemId];
    final previous = cached == null
        ? null
        : ChapterContent.fromCacheText(cached);
    final content = fetched.preferCompleteCache(previous);
    if (!identical(content, fetched)) return;
    _chapterCacheRevisions.update(
      chapter.itemId,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    _rememberChapter(chapter.itemId, text);
    // The same chapter may have been left and reopened while this one
    // deduplicated refresh was pending. Its identity still makes it current.
    if (_loading || chapter.itemId != _chapter.itemId || text == _content) {
      return;
    }
    final hasImages = _chapterContent.hasImages;
    final restoring = _needsRestore;
    final offset = hasImages
        ? _textOffset
        : _chapterLayout?.legacyOffsetForText(_textOffset) ?? _textOffset;
    setState(() {
      if (restoring) {
        // A fast refresh may finish before the old cache's first layout.
        // Preserve the history/start-at-end request until it is restored.
        if (!hasImages && _savedPosition?['positionVersion'] == 2) {
          _savedPosition = {...?_savedPosition, 'positionVersion': 1};
        }
      } else {
        _savedPosition = {
          'chapterId': chapter.itemId,
          'positionVersion': hasImages ? 2 : 1,
          'textOffset': offset,
        };
        _requestedStartAtEnd = false;
      }
      _content = text;
      _chapterContent = content;
      _chapterLayout = null;
      _layoutMode = null;
      _needsRestore = true;
      _progressReady = false;
    });
  }

  Future<void> _ensureCatalog() => _catalogFuture ??= _diskCache
      .saveBook(_cachedBook)
      .catchError((Object error) {
        _catalogFuture = null;
        throw error;
      });

  Future<_LoadedChapter> _loadChapterText(Chapter chapter) async {
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    bool superseded() =>
        revision != (_chapterCacheRevisions[chapter.itemId] ?? 0);
    String? text;
    if (!widget.localOnly) {
      try {
        final cached = await _diskCache.read(
          bookId: widget.bookId,
          chapterId: chapter.itemId,
        );
        if (cached != null &&
            cached.trim().isNotEmpty &&
            !ChapterContent.fromCacheText(
              cached,
            ).withoutLeadingTitle(chapter.title).isEmpty) {
          text = cached;
        }
      } catch (_) {
        // A storage failure must not prevent online reading.
      }
    }
    if (superseded()) return _latestChapterText(chapter);
    final fetched = text == null;
    if (fetched) {
      try {
        text = await _fetchChapter(chapter);
      } catch (_) {
        if (superseded()) return _latestChapterText(chapter);
        rethrow;
      }
      if (superseded()) return _latestChapterText(chapter);
      if (mounted && !widget.localOnly) {
        try {
          await _ensureCatalog();
          if (superseded()) return await _latestChapterText(chapter);
          if (mounted) {
            await _diskCache.write(
              bookId: widget.bookId,
              chapterId: chapter.itemId,
              title: chapter.title,
              text: text,
            );
          }
        } catch (_) {
          // Cache management reports storage errors; keep the fetched text usable.
        }
      }
    }
    if (superseded()) return _latestChapterText(chapter);
    if (mounted) _rememberChapter(chapter.itemId, text);
    return (text: text, fetched: fetched);
  }

  Future<_LoadedChapter> _latestChapterText(Chapter chapter) async {
    final cached = _chapterCache[chapter.itemId];
    return cached == null
        ? _loadChapterText(chapter)
        : (text: cached, fetched: false);
  }

  Future<void> _prefetchAround(int index) async {
    final nearby = <Chapter>[
      if (index > 0) widget.chapters[index - 1],
      if (index + 1 < widget.chapters.length) widget.chapters[index + 1],
    ];
    await Future.wait(
      nearby.map((chapter) async {
        try {
          await _chapterText(chapter);
        } catch (_) {
          // Prefetch is opportunistic; the foreground load still reports a
          // useful error and offers retry if this chapter is opened later.
        }
      }),
    );
  }

  // ==================== 【青茄修复·滚动无缝】段窗口 ====================

  /// 作废整个段窗口。下一次 build 会用当前章重新长出第 0 段。
  void _clearScrollWindow() {
    _scrollSegments.clear();
    _scrollActive = 0;
    _scrollItems = null;
    _scrollWindowBookChapter = null;
    _scrollWindowSpec = null;
  }

  String get _scrollWindowKey => '${widget.bookId}\u0000${_chapter.itemId}';

  /// 当前段；窗口为空时返回 null。
  _ScrollSegment? get _activeScrollSegment =>
      _scrollSegments.isEmpty || _scrollActive >= _scrollSegments.length
      ? null
      : _scrollSegments[_scrollActive];

  /// 两套排版是否几何完全一致（只差装饰：划线、选区、批注红线的「有没有」）。
  ///
  /// 划线/批注加载完会触发一次重排，但块的位置与高度都不变；这种重排只
  /// 需要把新布局换进所在段，绝不能重建窗口（重建会把读者甩到别处）。
  bool _sameScrollGeometry(ReaderChapterLayout a, ReaderChapterLayout b) {
    if (identical(a, b)) return true;
    if (a.blocks.length != b.blocks.length) return false;
    for (var i = 0; i < a.blocks.length; i++) {
      final x = a.blocks[i];
      final y = b.blocks[i];
      if ((x.top - y.top).abs() > .01 || (x.height - y.height).abs() > .01) {
        return false;
      }
    }
    return true;
  }

  /// 重算段在整条列表里的起始偏移（只在增删段/重建后调用）。
  void _layoutScrollTops() {
    var top = 0.0;
    for (final segment in _scrollSegments) {
      segment.top = top;
      top += segment.extent;
    }
    _scrollItems = null;
  }

  /// 按当前章重建窗口。首次进入 / 换章 / 换排版 / 几何变化都走这里。
  ///
  /// [compensate] 为 true 时把旧窗口里「活动段起点」占掉的高度补回去，
  /// 观众看到的内容不跳动；恢复/换排版的路径已经由 [_prepareLayout] 定位，
  /// 不能重复补偿。
  void _resetScrollWindow(
    ReaderChapterLayout layout, {
    required bool compensate,
  }) {
    final previous = _activeScrollSegment;
    final previousTop = previous?.top ?? 0;
    final previousChapter = previous?.chapter.itemId;
    _scrollSegments
      ..clear()
      ..add(
        _ScrollSegment(
          chapter: _chapter,
          text: _content,
          content: _chapterContent,
          layout: layout,
          annotations: _annotations,
        ),
      );
    _scrollActive = 0;
    _scrollWindowBookChapter = _scrollWindowKey;
    _scrollWindowSpec = layout.spec;
    _layoutScrollTops();
    if (!compensate || previousTop <= 0 || previousChapter == null) return;
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final target = (offset - previousTop).clamp(0.0, double.infinity);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _paged || !_scrollController.hasClients) return;
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  /// 每帧排版后校准窗口：确保第 0 段就是当前章，且下标与几何都对得上。
  ///
  /// 幂等，只在一处（[_buildScrollContent]）调用。
  void _syncScrollWindow(ReaderChapterLayout layout) {
    if (_scrollSegments.isEmpty ||
        _scrollWindowBookChapter != _scrollWindowKey ||
        _scrollWindowSpec != layout.spec) {
      // 首次进入 / 换章 / 换字号：窗口从当前章重新长出来。
      _resetScrollWindow(layout, compensate: false);
      _prefetchScrollAfterFrame();
      return;
    }
    final active = _scrollSegments[_scrollActive];
    if (identical(active.layout, layout)) return;
    if (_sameScrollGeometry(active.layout, layout)) {
      // 只是划线/批注装饰变了：就地替换，位置与段结构都不动。
      active.layout = layout;
      return;
    }
    // 几何变了（行内批注插入、段评气泡到达）：只能重建，但要补偿偏移。
    _resetScrollWindow(layout, compensate: !_layoutRepositioned);
    _prefetchScrollAfterFrame();
  }

  /// 段尾距离视口不足 1.5 屏时预取下一章（帧后执行，避免 build 里起异步）。
  void _prefetchScrollAfterFrame() {
    if (_paged) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeScrollPrefetch();
    });
  }

  void _maybeScrollPrefetch() {
    if (_paged || _scrollSegments.isEmpty || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final last = _scrollSegments.last;
    final remaining =
        last.top + last.extent - (position.pixels + position.viewportDimension);
    if (remaining > position.viewportDimension * 1.5) return;
    unawaited(_prefetchScrollSegment());
  }

  /// 把下一章正文 + 批注排成新段，追加到窗口末尾（绝不改当前章状态）。
  ///
  /// 注意：这里不能走 [_prepareLayout]，它会把 `_chapterLayout/_textOffset`
  /// 等当前章状态一起改掉。布局只用同一个 [ReaderLayoutSpec] 量一遍。
  Future<void> _prefetchScrollSegment() async {
    if (_paged || _scrollBusy || _scrollSegments.isEmpty) return;
    final spec = _scrollWindowSpec;
    if (spec == null) return;
    final lastChapter = _scrollSegments.last.chapter;
    final lastIndex = widget.chapters.indexWhere(
      (chapter) => chapter.itemId == lastChapter.itemId,
    );
    if (lastIndex < 0 || lastIndex + 1 >= widget.chapters.length) return;
    final next = widget.chapters[lastIndex + 1];
    if (_scrollSegments.any(
      (segment) => segment.chapter.itemId == next.itemId,
    )) {
      return;
    }
    _scrollBusy = true;
    final generation = _loadGeneration;
    try {
      final loaded = await _chapterText(next);
      if (!mounted || generation != _loadGeneration) return;
      List<ReaderAnnotation> annotations;
      try {
        annotations = await _annotationStore.load(widget.bookId, next.itemId);
      } catch (_) {
        annotations = const [];
      }
      if (!mounted || generation != _loadGeneration) return;
      final content = ChapterContent.fromCacheText(loaded.text);
      if (content.withoutLeadingTitle(next.title).isEmpty) return;
      final layout = ReaderChapterLayout(
        title: next.title,
        content: content,
        spec: spec,
        // 相邻章不画段评气泡：气泡要额外拉 ideas，且会改变高度；
        // 真正进入该章（或整章加载）时会按完整数据重排。
        paragraphBubbles: const {},
        underlinedParagraphs: const {},
        inlineNotes: [
          for (final note in annotations)
            ReaderInlineNote(
              id: note.key,
              start: note.start,
              end: note.end,
              quote: note.text,
              thought: note.thought,
              isExcerpt: !note.isAnnot,
            ),
        ],
      );
      if (!mounted || generation != _loadGeneration) return;
      // 期间可能换过章或重建过窗口：只有仍以同一章结尾才追加。
      if (_scrollSegments.isEmpty ||
          _scrollSegments.last.chapter.itemId != lastChapter.itemId) {
        return;
      }
      setState(() {
        _scrollSegments.add(
          _ScrollSegment(
            chapter: next,
            text: loaded.text,
            content: content,
            layout: layout,
            annotations: annotations,
          ),
        );
        // 追加只往后长：已有段的 top 不变，滚动位置天然稳定（不 jumpTo）。
        _layoutScrollTops();
      });
    } catch (_) {
      // 预取失败保持静默：滚到底时 _next() 还会走一次正常加载并给出提示。
    } finally {
      _scrollBusy = false;
    }
  }

  /// 视口中心落在哪一段，就把该段静默变成「当前章」。
  void _syncActiveScrollSegment() {
    if (_paged || _scrollSegments.isEmpty || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final center = position.pixels + position.viewportDimension / 2;
    var index = 0;
    for (var i = 0; i < _scrollSegments.length; i++) {
      if (center >= _scrollSegments[i].top) {
        index = i;
      } else {
        break;
      }
    }
    if (index == _scrollActive) return;
    _switchScrollSegment(index);
  }

  /// 【青茄修复·滚动无缝】跨段静默换章：列表内容与滚动位置都不动，
  /// 只把「当前章」指向新段，并把它需要的装饰数据补上。
  void _switchScrollSegment(int index) {
    if (index < 0 || index >= _scrollSegments.length) return;
    final segment = _scrollSegments[index];
    final chapterIndex = widget.chapters.indexWhere(
      (chapter) => chapter.itemId == segment.chapter.itemId,
    );
    if (chapterIndex < 0) return;
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final textOffset = segment.layout.textOffsetAtScroll(offset - segment.top);
    setState(() {
      _scrollActive = index;
      _index = chapterIndex;
      _content = segment.text;
      _chapterContent = segment.content;
      _chapterLayout = segment.layout;
      _layoutMode = _preferences.pageMode;
      _textOffset = textOffset;
      _pageIndex = segment.layout.pageForOffset(textOffset);
      _progressReady = true;
      // 该章的批注与划线都跟着换；先按「空划线」把版本号对齐，避免
      // 下面 _loadUnderlines 回来之前按上一章的下划线重排一次。
      _annotations = segment.annotations;
      _annotationRevision++;
      _layoutAnnotationRevision = _annotationRevision;
      _underlines = const {};
      _rangeUnderlines = const [];
      _underlineRevision++;
      _layoutUnderlineRevision = _underlineRevision;
      // 段内的排版不含段评气泡：清掉上一章的 ideas，否则下一次重排会
      // 拿上一章的气泡数去量这一章。进入段评的入口仍在工具栏/目录。
      _ideas = ChapterIdeas.empty;
      _ideasRevision++;
      _layoutIdeasRevision = _ideasRevision;
      _layoutBubblesVisible = _preferences.showParagraphBubbles;
      _selection = null;
      _selectionBarOpen = false;
      _narrationRange = null;
      _needsRestore = false;
    });
    unawaited(_loadUnderlines());
    // 【青茄修复·滚动无缝】静默换章把 _ideas 清空了，工具栏「本章评论」
    // 入口（要求 total > 0）会随之消失；按整章加载同样的路径把新章的
    // 段评拉回来。气泡开着时 IdeasRevision 会让该段按完整数据重排，
    // 几何变化走 _resetScrollWindow 的补偿路径，不会跳屏。
    unawaited(_loadIdeas(segment.chapter, _loadGeneration));
    _settleReadTime();
    unawaited(_persistProgress());
  }

  /// 滚停后裁掉窗口头部过远的段（保留活动段之前两段，还能往回滚）。
  ///
  /// 只减头、不加头：删除高度 h 后把 offset 平移到 `offset - h`，
  /// 放在 post-frame 里做，拖拽过程中不会跳。
  void _pruneScrollSegments() {
    if (_paged || _scrollSegments.length <= 6) return;
    if (_scrollActive - 2 <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _paged || _scrollSegments.length <= 6) return;
      if (!_scrollController.hasClients || _scrollActive - 2 <= 0) return;
      final offset = _scrollController.offset;
      var removed = 0.0;
      while (_scrollSegments.length > 6 && _scrollActive - 2 > 0) {
        removed += _scrollSegments.removeAt(0).extent;
        _scrollActive--;
      }
      if (removed <= 0) return;
      _layoutScrollTops();
      // 先在旧列表上跳到补偿后的位置（仍然合法），再重建 —— 新列表的
      // offset 已经是对的，下一帧不会出现「先贴底再弹回」。
      _scrollController.jumpTo(
        (offset - removed).clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ),
      );
      setState(() {});
    });
  }

  /// 拍平「段 × 块」。段变了才重建（[items] 缓存由调用方持有）。
  List<({int segment, int block})> _flattenScrollSegments() {
    final items = <({int segment, int block})>[];
    for (var s = 0; s < _scrollSegments.length; s++) {
      final blocks = _scrollSegments[s].layout.blocks;
      for (var b = 0; b < blocks.length; b++) {
        items.add((segment: s, block: b));
      }
    }
    return items;
  }

  ReaderChapterLayout _prepareLayout(BoxConstraints constraints) {
    final spec = ReaderLayoutSpec(
      viewport: constraints.biggest,
      textScaler: MediaQuery.textScalerOf(context),
      preferences: _displayPreferences,
      fontFamily:
          _fontFamily ?? Theme.of(context).textTheme.bodyLarge?.fontFamily,
    );
    final previousSpec = _chapterLayout?.spec;
    final previousMode = _layoutMode;
    _layoutRepositioned = false;
    if (_chapterLayout?.spec == spec &&
        _layoutMode == _preferences.pageMode &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutAnnotationRevision == _annotationRevision &&
        _layoutBubblesVisible == _preferences.showParagraphBubbles) {
      return _chapterLayout!;
    }
    // Reuse the measured text layout only when nothing that feeds it changed.
    // Switching page mode keeps the same spec and page-insensitive measurements,
    // so it must not re-measure — but bubbles or 划线 must.
    // The bubble switch gates the data itself (not just the builder):
    // the layout reserves placeholder space from bubbleCount, so a null
    // builder alone would leave an empty gap at the paragraph end.
    final bubblesVisible = _preferences.showParagraphBubbles;
    final reusable =
        _chapterLayout?.spec == spec &&
        _layoutIdeasRevision == _ideasRevision &&
        _layoutUnderlineRevision == _underlineRevision &&
        _layoutAnnotationRevision == _annotationRevision &&
        _layoutBubblesVisible == bubblesVisible;
    final layout = reusable
        ? _chapterLayout!
        : ReaderChapterLayout(
            title: _chapter.title,
            content: _chapterContent,
            spec: spec,
            paragraphBubbles: bubblesVisible ? _ideas.bubbleCounts : const {},
            paragraphBubbleVariants: bubblesVisible
                ? _ideas.bubbleVariants
                : const {},
            underlinedParagraphs: _underlines,
            bubbleBuilder: bubblesVisible ? _buildParagraphBubble : null,
            // 【青茄重构·新增】批注块参与排版：分页/滚动两种模式共用。
            inlineNotes: _inlineNotes,
          );
    _layoutIdeasRevision = _ideasRevision;
    _layoutUnderlineRevision = _underlineRevision;
    _layoutAnnotationRevision = _annotationRevision;
    _layoutBubblesVisible = bubblesVisible;
    final initialRestore = _needsRestore;
    final restored = initialRestore
        ? layout.restore(
            _savedPosition,
            chapterId: _chapter.itemId,
            startAtEnd: _requestedStartAtEnd,
            paged: _paged,
          )
        : (
            textOffset: _textOffset,
            scroll: layout.scrollForTextOffset(_textOffset),
          );
    _chapterLayout = layout;
    _layoutMode = _preferences.pageMode;
    _textOffset = restored.textOffset;
    _pageIndex = layout.pageForOffset(_textOffset);
    _needsRestore = false;
    _progressReady = false;
    // 【青茄修复·滚动无缝】只有「恢复进度 / 切页模式 / 换排版规格」才需要
    // 把滚动位置重新定位到章内目标偏移。段评、划线、批注到达时的重排不改
    // 几何，此时列表里的 offset 是「段窗口」坐标，按章内坐标跳会甩飞。
    _layoutRepositioned =
        initialRestore ||
        previousMode != _preferences.pageMode ||
        previousSpec != spec;
    final reposition = _layoutRepositioned;
    final revision = ++_layoutRevision;
    final generation = _loadGeneration;
    // Layout and restoration must both finish before a new snapshot may save.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _loadGeneration ||
          revision != _layoutRevision ||
          !identical(layout, _chapterLayout)) {
        return;
      }
      if (!_paged && reposition) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(
          restored.scroll.clamp(0, _scrollController.position.maxScrollExtent),
        );
      }
      setState(() => _progressReady = true);
      if (_appActive && !_sessionActive) {
        _sessionActive = true;
        _readStart = DateTime.now();
      }
      unawaited(_persistProgress(createHistory: initialRestore));
    });
    return layout;
  }

  void _onScroll() {
    _saveTimer?.cancel();
    if (!_progressReady || _paged) return;
    // 【青茄修复·滚动无缝】先按视口中心判断跨段，再记进度：
    // 顺序反过来会把「上一章的偏移」记到刚切过去的章上。
    _syncActiveScrollSegment();
    _captureScrollProgress(updateTextOffset: true);
    _maybeScrollPrefetch();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _settleReadTime();
      unawaited(_persistProgress());
      _pruneScrollSegments();
    });
  }

  /// Settles the reading-time delta since the last event, legado-style:
  /// the time between this event and the previous one counts as reading.
  void _settleReadTime() {
    if (!_sessionActive || _content.isEmpty) return;
    final now = DateTime.now();
    final delta = now.difference(_readStart).inMilliseconds / 1000;
    if (delta >= 1) {
      unawaited(
        _readerStore
            .accumulateReadTime(widget.bookId, 'book', delta)
            .catchError((_) {}),
      );
    }
    _readStart = now;
  }

  void _captureScrollProgress({bool updateTextOffset = false}) {
    final layout = _chapterLayout;
    if (_paged) {
      if (layout != null) {
        _lastPosition = layout.scrollForTextOffset(_textOffset);
        _lastMaxScroll = layout.maxScroll;
      }
      return;
    }
    if (!_scrollController.hasClients) return;
    // 【青茄修复·滚动无缝】滚动模式下 position 要按「活动段」换算：
    // 列表 offset 是整条窗口的，减去段起点才是本章内的位置。
    final segment = _activeScrollSegment;
    if (segment != null) {
      final local = (_scrollController.offset - segment.top).clamp(
        0.0,
        segment.extent,
      );
      _lastPosition = local;
      _lastMaxScroll = segment.extent;
      if (updateTextOffset) {
        _textOffset = segment.layout.textOffsetAtScroll(local);
      }
      return;
    }
    _lastPosition = _scrollController.offset;
    _lastMaxScroll = _scrollController.position.maxScrollExtent;
    if (updateTextOffset && layout != null) {
      _textOffset = layout.textOffsetAtScroll(_lastPosition);
    }
  }

  void _onPageChanged(int page) {
    // Turning the page cancels the selection: the handles belong to the text,
    // the action bar's anchor would be stale. Reselecting is one long press.
    _closeSelectionBar(clearSelection: true);
    if (!_progressReady || _changingChapter || page == _pageIndex) return;
    setState(() {
      _pageIndex = page;
      _textOffset = _chapterLayout!.pages[page].start;
    });
    _settleReadTime();
    unawaited(_persistProgress());
    // 分页模式的实际翻页：累加墨水屏刷新计数（覆盖音量键/自动翻页/点按翻页）。
    _recordEinkPageTurn();
  }

  /// 墨水屏整屏刷新：翻够 [_preferences.einkRefreshInterval] 页触发一次海信 EPD
  /// 全刷压残影。全局墨水屏未开或间隔为 0 时直接跳过，计数不累加。
  void _recordEinkPageTurn() {
    if (!einkModeNotifier.value) return;
    final interval = _preferences.einkRefreshInterval;
    if (interval <= 0) return;
    _einkPageCounter++;
    if (_einkPageCounter >= interval) {
      _einkPageCounter = 0;
      unawaited(EinkRefreshService.instance.refreshIfSupported());
    }
  }

  Future<void> _pageBoundary(int direction) async {
    if (!_progressReady || _changingChapter || _loading) return;
    if (direction < 0) {
      if (_index == 0) {
        _showMessage('已是第一页');
      } else {
        await _prev(startAtEnd: true);
      }
    } else {
      await _next();
    }
  }

  /// Captures the page on screen so a chapter boundary can animate. Returns
  /// null when paging is off or the reader is set to turn without animation.
  ReaderChapterTurn? _captureChapterTurn(int direction) {
    if (!_paged || _preferences.pageTurnStyle == ReaderPageTurnStyle.none) {
      return null;
    }
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) return null;
    return ReaderChapterTurn(
      direction: direction,
      page: layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)],
      spec: layout.spec,
    );
  }

  /// The boundary slide finished: drop the overlay so the rebuilt pagination
  /// shows through. The chapter switch itself was already committed.
  void _onChapterTurnCompleted() {
    if (!mounted || _chapterTurnRequest == null) return;
    setState(() => _chapterTurnRequest = null);
  }

  Future<void> _persistProgress({bool createHistory = false}) async {
    if (!_progressReady) return;
    // The scrollable may already be detached when the reader is disposed.
    _captureScrollProgress();
    final index = _index;
    final chapterId = _chapter.itemId;
    final position = _lastPosition;
    final max = _lastMaxScroll;
    final progress = _chapterProgress(
      position: position,
      maxScroll: max,
      index: index,
    );
    final entry = {
      'id': widget.bookId,
      'kind': 'book',
      'title': widget.title,
      'bookId': widget.bookId,
      'chapterId': chapterId,
      'episode': index,
      'position': position,
      'maxScroll': max,
      'positionVersion': 2,
      'textOffset': _textOffset,
      'progress': progress,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    await _history.save(entry, createHistory: createHistory);
  }

  double _chapterProgress({double? position, double? maxScroll, int? index}) {
    if (widget.chapters.isEmpty) return 0;
    if (_paged) {
      final pageCount = _chapterLayout?.pages.length ?? 1;
      final fraction = pageCount > 1 ? _pageIndex / (pageCount - 1) : 0.0;
      return ((index ?? _index) + fraction) / widget.chapters.length;
    }
    final fraction =
        (maxScroll ??
                (_scrollController.hasClients
                    ? _scrollController.position.maxScrollExtent
                    : 0)) >
            0
        ? (position ??
                  (_scrollController.hasClients
                      ? _scrollController.offset
                      : 0)) /
              (maxScroll ?? _scrollController.position.maxScrollExtent)
        : 0.0;
    return ((index ?? _index) + fraction.clamp(0.0, 1.0)) /
        widget.chapters.length;
  }

  /// 目标章已经在段窗口里时，直接滚过去 —— 不重新加载、不重建列表。
  ///
  /// 返回 true 表示已接管。[toEnd] 用于 `_prev(startAtEnd: true)`：
  /// 落在上一章的末尾而不是开头。
  Future<bool> _scrollToWindowChapter(int index, {bool toEnd = false}) async {
    if (_paged || _scrollSegments.isEmpty) return false;
    if (!_scrollController.hasClients) return false;
    final target = _scrollSegments.indexWhere(
      (segment) => segment.chapter.itemId == widget.chapters[index].itemId,
    );
    if (target < 0) return false;
    final segment = _scrollSegments[target];
    final position = _scrollController.position;
    final offset = toEnd
        ? segment.top + segment.extent - position.viewportDimension
        : segment.top;
    final clamped = offset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  Future<void> _prev({bool startAtEnd = false}) async {
    if (_index <= 0 || _changingChapter) return;
    if (await _scrollToWindowChapter(_index - 1, toEnd: startAtEnd)) return;
    if (!mounted) return;
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(-1);
      setState(() => _index--);
      await _load(startAtEnd: startAtEnd, chapterTurn: turn);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _next() async {
    if (_changingChapter) return;
    if (_index >= widget.chapters.length - 1) {
      _showMessage('已是最后一章');
      return;
    }
    if (await _scrollToWindowChapter(_index + 1)) return;
    if (!mounted) return;
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      final turn = _captureChapterTurn(1);
      setState(() => _index++);
      await _load(chapterTurn: turn);
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _jumpToChapter(int index, {bool followListening = false}) async {
    if (!followListening) _pauseListenFollow();
    if (_changingChapter ||
        index == _index ||
        index < 0 ||
        index >= widget.chapters.length) {
      return;
    }
    _changingChapter = true;
    try {
      _settleReadTime();
      await _persistProgress();
      if (!mounted) return;
      if (followListening &&
          (!_routeCurrent ||
              !_appActive ||
              _controlsVisible ||
              !_preferences.listeningFollow ||
              _autoTurnTimer != null ||
              DateTime.now().isBefore(_listenFollowPausedUntil) ||
              !ListeningSession.instance.matches(
                widget.bookId,
                widget.chapters[index].itemId,
              ))) {
        return;
      }
      setState(() {
        _index = index;
        _chapterSeekValue = null;
      });
      await _load();
    } finally {
      _changingChapter = false;
    }
  }

  Future<void> _turnPage(int direction) async {
    if (_loading || !_progressReady || _changingChapter) return;
    if (_paged) {
      await _pagedKey.currentState?.turnPage(direction);
      return;
    }
    // 滚动模式的离散翻页（音量键/点按边缘/自动翻页）记一次，连续拖拽不计入。
    _recordEinkPageTurn();
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    const boundaryTolerance = 2.0;
    if (direction < 0 &&
        position.pixels <= position.minScrollExtent + boundaryTolerance) {
      await _prev(startAtEnd: true);
      return;
    }
    if (direction > 0 &&
        position.pixels >= position.maxScrollExtent - boundaryTolerance) {
      await _next();
      return;
    }

    final delta = position.viewportDimension * 0.86 * direction;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleControls() {
    _stopAutoTurn();
    if (!_controlsVisible) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    setState(() => _controlsVisible = !_controlsVisible);
    _syncVolumeKeyEnabled();
  }

  /// 点击区域九宫格分发：按点按位置取九宫格动作执行。
  void _handleTapZone(Offset position, BoxConstraints constraints) {
    final action = readerTapZoneActionAt(
      zones: _preferences.tapZones,
      dx: position.dx,
      dy: position.dy,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
    );
    switch (action) {
      case ReaderTapZoneAction.none:
        break;
      case ReaderTapZoneAction.menu:
        _toggleControls();
      case ReaderTapZoneAction.prevPage:
        _pauseListenFollow();
        unawaited(_turnPage(-1));
      case ReaderTapZoneAction.nextPage:
        _pauseListenFollow();
        unawaited(_turnPage(1));
      case ReaderTapZoneAction.prevChapter:
        unawaited(_prev(startAtEnd: true));
      case ReaderTapZoneAction.nextChapter:
        unawaited(_next());
      case ReaderTapZoneAction.toc:
        unawaited(_showDirectory());
    }
  }

  void _previewPreferences(ReaderPreferences preferences) {
    _preferencesDirty = true;
    final fontChanged = preferences.fontPath != _preferences.fontPath;
    final intervalChanged =
        preferences.einkRefreshInterval != _preferences.einkRefreshInterval;
    setState(() {
      _preferences = preferences.normalized();
      if (_preferences.themePreset != ReaderThemePreset.dark) {
        _dayTheme = _preferences.themePreset;
      }
      // 刷新间隔改变时清零计数，避免沿用旧阈值导致久不刷新或立刻刷新。
      if (intervalChanged) _einkPageCounter = 0;
    });
    if (fontChanged) unawaited(_loadFont(preferences.fontPath));
  }

  Future<void> _showAppearanceSettings() async {
    setState(() => _controlsVisible = false);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ReaderAppearanceSheet(
        initialValue: _preferences,
        einkOverride: einkModeNotifier.value,
        onChanged: _previewPreferences,
        onPickFont: _pickFont,
      ),
    );
    await _savePreferences();
  }

  void _toggleNightTheme() {
    // 全局墨水屏覆盖显示，点夜间不会有任何可见变化，先提示而非静默无响应。
    if (einkModeNotifier.value) {
      _showMessage('全局墨水屏模式已开启，先在设置里关闭它再切换夜间');
      return;
    }
    final nextPreset = _preferences.themePreset == ReaderThemePreset.dark
        ? _dayTheme
        : ReaderThemePreset.dark;
    _previewPreferences(_preferences.copyWith(themePreset: nextPreset));
    unawaited(_savePreferences());
  }

  Future<void> _showDirectory() async {
    setState(() => _controlsVisible = false);
    Set<String> cachedIds = {};
    try {
      cachedIds = await _diskCache.cachedChapterIds(widget.bookId);
    } catch (_) {}
    if (!mounted) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _effectivePreset.panelColor,
      builder: (context) => Theme(
        data: _effectivePreset.theme(Theme.of(context)),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height:
                (MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom) *
                0.78,
            child: _ChapterDirectorySheet(
              chapters: widget.chapters,
              currentIndex: _index,
              cachedIds: cachedIds,
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _jumpToChapter(selected);
  }

  /// Local books use system TTS; online books offer both available sources.
  Future<void> _openListening({int? fromMs, int? textId}) async {
    if (_openingListening || _loading || _error != null) return;
    final chapterId = _chapter.itemId;
    var system = widget.localOnly;
    if (!system) {
      _openingListening = true;
      try {
        final choice = await showModalBottomSheet<bool>(
          context: context,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: _effectivePreset.panelColor,
          builder: (context) => Theme(
            data: _effectivePreset.theme(Theme.of(context)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.headphones),
                  title: const Text('听书'),
                  subtitle: const Text('使用作品自带音频与音色'),
                  onTap: () => Navigator.pop(context, false),
                ),
                ListTile(
                  leading: const Icon(Icons.record_voice_over),
                  title: const Text('系统朗读'),
                  subtitle: const Text('使用手机已安装的 TTS 引擎'),
                  onTap: () => Navigator.pop(context, true),
                ),
              ],
            ),
          ),
        );
        if (!mounted || choice == null || chapterId != _chapter.itemId) return;
        system = choice;
      } finally {
        _openingListening = false;
      }
    }
    if (!system) {
      await _openUpstreamListening(fromMs: fromMs, textId: textId);
      return;
    }
    _openingListening = true;
    try {
      _stopAutoTurn();
      final content = _chapterContent;
      final chapter = _chapter;
      var offset = 0;
      if (textId != null) {
        final body = content.withoutLeadingTitle(chapter.title);
        var found = false;
        for (var i = 0; i < body.blocks.length; i++) {
          final block = body.blocks[i];
          if (block is! ChapterParagraph) continue;
          if (paragraphUnderlineId(paraIndex: block.paraIndex, blockIndex: i) ==
              textId) {
            found = true;
            break;
          }
          offset += block.text.length + 1;
        }
        if (!found) offset = 0;
      }
      // Capture data and source references before awaiting; the app session
      // never calls this State's cache/prefetch methods after the page leaves.
      final book = SystemTtsBook(
        bookId: widget.bookId,
        title: widget.title,
        chapters: widget.chapters,
        startIndex: _index,
        initialContent: content,
        startOffset: offset,
        localOnly: widget.localOnly,
        textLoader: widget.chapterLoader,
        cache: widget.chapterCache,
      );
      await _persistProgress();
      if (!mounted || chapterId != _chapter.itemId) return;
      setState(() => _controlsVisible = false);
      await AudioPlaybackScope.startSystemTts(context, book);
    } catch (e) {
      if (mounted) _showMessage(SystemTts.errorMessage(e));
    } finally {
      _openingListening = false;
    }
  }

  /// [fromMs] is the pressed paragraph's place on the spoken timeline the
  /// chapter shipped with (`<span start_time>`), so 从本段听 starts there
  /// instead of at the chapter's opening. [textId] non-null marks the request
  /// as paragraph-anchored: if that paragraph has no timeline the page still
  /// starts at the chapter's beginning rather than resuming old history.
  ///
  /// A cache written before the reader read that timeline carries no start
  /// times. Reading never waits on that; the timeline is fetched here, once,
  /// because the user asked to listen from a paragraph. The fetch is bounded,
  /// and a failure still opens the page at the chapter start.
  Future<void> _openUpstreamListening({int? fromMs, int? textId}) async {
    final paragraphAnchored = textId != null;
    if (_openingListening) return;
    _openingListening = true;
    final chapter = _chapter;
    final chapterIndex = _index;
    try {
      _stopAutoTurn();
      await _persistProgress();
      if (!mounted) return;
      var startMs = fromMs;
      if (startMs == null &&
          paragraphAnchored &&
          !_chapterContent.timelineChecked) {
        _showMessage('正在获取本段音频…');
        await _refreshCachedChapter(
          chapter,
        ).timeout(const Duration(seconds: 12), onTimeout: () {});
        // The user may have turned the page while the timeline was in flight.
        // Serving another chapter's paragraph position would start playback at
        // a place nobody asked for.
        if (!mounted || _chapter.itemId != chapter.itemId) return;
        startMs = _paragraphStartMs(textId);
      }
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AudioPage(
            bookId: widget.bookId,
            title: widget.title,
            cover: widget.cover,
            chapters: widget.chapters,
            startIndex: chapterIndex,
            resumeSession: false,
            // A paragraph-anchored request always carries an explicit start:
            // Duration.zero means "this paragraph has no audio, begin at the
            // chapter opening" and must not fall back to saved history.
            startPosition: paragraphAnchored
                ? Duration(milliseconds: startMs ?? 0)
                : null,
            historyStore: widget.readerStore,
          ),
        ),
      );
    } finally {
      _openingListening = false;
    }
  }

  /// The spoken start of the paragraph identified by [textId], when the chapter
  /// carries a timeline.
  ///
  /// [textId] is [ReaderContentBlock.textId]: the upstream `idx` when present,
  /// otherwise the paragraph's ordinal. The ordinal fallback is resolved
  /// against the exact block order the reader laid out — the leading title
  /// stripped, the synthetic title block occupying index 0, image blocks
  /// counted — so a chapter without ids still maps. Walking the raw block
  /// list instead desynced from the layout by one (title) plus however many
  /// images precede a paragraph, and 从本段听 landed on the previous paragraph.
  int? _paragraphStartMs(int textId) {
    final body = _chapterContent.withoutLeadingTitle(_chapter.title);
    // Block 0 is the layout's synthetic title, so the first body element sits
    // at layout index 1 and its fallback id is -(1 + 0) — the same maths
    // ReaderChapterLayout uses for textId.
    var layoutIndex = 1;
    for (final element in body.blocks) {
      if (element is ChapterParagraph) {
        if (paragraphUnderlineId(
              paraIndex: element.paraIndex,
              blockIndex: layoutIndex - 1,
            ) ==
            textId) {
          return element.startMs;
        }
      }
      layoutIndex++;
    }
    return null;
  }

  Future<void> _showCache() {
    setState(() => _controlsVisible = false);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _effectivePreset.panelColor,
      builder: (context) => Theme(
        data: _effectivePreset.theme(Theme.of(context)),
        child: ChapterCacheSheet(
          book: _cachedBook,
          currentIndex: _index,
          cache: _diskCache,
          loader: _fetchChapter,
          onContentAvailable: _onChapterContentAvailable,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: _errorView(),
      );
    }
    // 【青茄重构·修复】把输入法 inset 从整个阅读页里冻结掉。
    // 阅读页自己没有任何输入框（写想法、目录搜索都是独立路由），键盘只该
    // 影响弹层。这里做两件事：
    //   1. viewInsets 清零 —— 否则 Scaffold 默认会缩小 body；
    //   2. padding 固定成 viewPadding —— 框架给到的 padding 是「安全区减去
    //      键盘」的差值，键盘一弹 padding.bottom 会从手势条高度变成 0，
    //      进而让 SafeArea 内的正文视口高度变化，同样触发全章重新分页。
    //      固定成 viewPadding 后，这两个值在键盘升降过程中都不再变化。
    final base = readerMediaQueryWithCutoutInsets(MediaQuery.of(context));
    return MediaQuery(
      data: base.copyWith(
        viewInsets: EdgeInsets.zero,
        padding: base.viewPadding,
      ),
      child: Builder(builder: _buildReader),
    );
  }

  Widget _buildReader(BuildContext context) {
    final preset = _effectivePreset;
    final windowPadding = MediaQuery.paddingOf(context);
    final overlayStyle = preset.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return PopScope<Object?>(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _controlsVisible) _toggleControls();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle.copyWith(
          statusBarColor: preset.backgroundColor,
          systemNavigationBarColor: preset.backgroundColor,
        ),
        child: Theme(
          data: preset.theme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: preset.backgroundColor,
            // 【青茄重构·修复】阅读页不随输入法缩放。
            // 默认 true 时键盘一弹，body 高度被压掉约 300px，LayoutBuilder 的
            // constraints 随之变化 → ReaderLayoutSpec 变化 → 整章重新测量分页，
            // 真机上就表现为「正文带着插图上下跳一下，然后卡几百毫秒」。
            // 关掉之后 constraints 恒定，缓存的分页结果原样复用，正文不动。
            resizeToAvoidBottomInset: false,
            body: Stack(
              fit: StackFit.expand,
              children: [
                SafeArea(
                  child: Column(
                    children: [
                      if (_preferences.readingInfoMode ==
                          ReaderInfoMode.detailed)
                        GestureDetector(
                          onTap: _toggleControls,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Flexible(
                                  child: Text(
                                    _chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: preset.mutedTextColor,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: SizedBox.expand(
                          key: _viewportKey,
                          child: _buildContent(preset, windowPadding),
                        ),
                      ),
                      if (_preferences.showReadingInfo)
                        ListenableBuilder(
                          listenable: _scrollController,
                          builder: (context, _) => ReaderStatusBar(
                            key: const ValueKey('reader-status-bar'),
                            preset: preset,
                            compact:
                                _preferences.readingInfoMode ==
                                ReaderInfoMode.compact,
                            status: _deviceStatus,
                            progress: _chapterProgress(),
                            chapterIndex: _index,
                            chapterCount: widget.chapters.length,
                            paged: _paged,
                            pageIndex: _chapterLayout == null
                                ? null
                                : _pageIndex,
                            pageCount: _chapterLayout?.pages.length,
                          ),
                        ),
                    ],
                  ),
                ),
                _menuEdge(top: true, child: _buildToolbar(preset)),
                _menuEdge(top: false, child: _buildReaderControls(preset)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuEdge({required bool top, required Widget child}) => Positioned(
    top: top ? 0 : null,
    bottom: top ? null : 0,
    left: 0,
    right: 0,
    child: IgnorePointer(
      ignoring: !_controlsVisible,
      child: ExcludeSemantics(
        excluding: !_controlsVisible,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, top ? -1 : 1),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: _controlsVisible ? child : const SizedBox.shrink(),
        ),
      ),
    ),
  );

  Widget _buildToolbar(ReaderThemePreset preset) => Material(
    key: const ValueKey('reader-toolbar'),
    color: preset.panelColor,
    elevation: 2,
    shadowColor: Colors.black12,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回书籍',
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(LucideIcons.arrow_left, color: preset.textColor),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.ageRating != null) ...[
                        const SizedBox(width: 6),
                        ContentRatingChip(
                          rating: widget.ageRating!,
                          compact: true,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '正在阅读 · 第 ${_index + 1} 章',
                    style: TextStyle(
                      color: preset.mutedTextColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (!_loading &&
                _error == null &&
                _ideas.total > 0 &&
                _chapterEndParagraph() != null)
              IconButton(
                key: const ValueKey('reader-toolbar-chapter-comments'),
                tooltip: '本章评论',
                onPressed: () => unawaited(
                  _showIdeas(focusParaIndex: _chapterEndParagraph()),
                ),
                icon: Icon(LucideIcons.message_circle, color: preset.textColor),
              ),
            IconButton(
              tooltip: '收起阅读菜单',
              onPressed: _toggleControls,
              icon: Icon(LucideIcons.chevron_up, color: preset.textColor),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildContent(ReaderThemePreset preset, EdgeInsets windowPadding) {
    final chapterTurn = _chapterTurnRequest;
    if (_loading && chapterTurn != null) {
      // Keep the outgoing page on screen while the neighbouring chapter loads,
      // so the boundary slides instead of flashing the loading spinner.
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleControls,
        child: ReaderPageContent(
          page: chapterTurn.page,
          spec: chapterTurn.spec,
          imageProviderFactory: widget.imageProviderFactory,
        ),
      );
    }
    // 【青茄修复·进章顺滑】转场动画没走完就先保持加载态，正文排版
    // 留到动画结束后再做（见 _watchRouteIntro 的注释）。
    _watchRouteIntro();
    if (_loading || _error != null || !_routeIntroReady) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleControls,
        child: _loading || !_routeIntroReady
            ? Center(
                child: CircularProgressIndicator(color: preset.accentColor),
              )
            : _errorView(textColor: preset.textColor),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _prepareLayout(constraints);
        final scope = _marksScopeFor(preset, layout);
        return GestureDetector(
          key: const ValueKey('reader-page-surface'),
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            if (_selection != null) {
              // A tap outside the selection cancels it without turning the
              // page — the official reader behaves the same.
              _closeSelectionBar(clearSelection: true);
              return;
            }
            if (_autoTurnTimer != null) {
              _stopAutoTurn();
            } else if (_controlsVisible) {
              _toggleControls();
            } else {
              _handleTapZone(details.localPosition, constraints);
            }
          },
          child: Stack(
            key: _selectionOverlayKey,
            children: [
              // 【青茄重构·修复】内容区独立成层：弹层/键盘动画期间正文
              // 不必跟着重绘，真机上的弹出卡顿主要来自这里。
              Positioned.fill(
                // 键盘弹出只影响弹层自身：把 viewInsets 从正文子树移除，
                // 输入法动画就不会推动整章重排（真机卡顿的另一半原因）。
                child: MediaQuery.removeViewInsets(
                  context: context,
                  removeBottom: true,
                  child: RepaintBoundary(
                    child: _paged
                        ? ReaderPagedView(
                            key: _pagedKey,
                            layout: layout,
                            pageIndex: _pageIndex,
                            hasPreviousChapter: _index > 0,
                            hasNextChapter: _index < widget.chapters.length - 1,
                            onPageChanged: _onPageChanged,
                            onBoundary: _pageBoundary,
                            onDragStart: _hideControlsOnDrag,
                            instantSwipe: _preferences.instantSwipeTurn,
                            turnStyle: _preferences.instantSwipeTurn
                                ? ReaderPageTurnStyle.none
                                : _preferences.pageTurnStyle,
                            backgroundColor: preset.backgroundColor,
                            endPage: _index == widget.chapters.length - 1
                                ? _buildChapterEndPage(preset)
                                : null,
                            onBookEnd: _stopAutoTurn,
                            chapterTurn: _chapterTurnRequest,
                            onChapterTurnCompleted: _onChapterTurnCompleted,
                            imageProviderFactory: widget.imageProviderFactory,
                            onParagraphLongPress: (block, position) =>
                                unawaited(
                                  _onParagraphLongPress(block, position),
                                ),
                            onParagraphLongPressMoveUpdate:
                                _onParagraphLongPressMoveUpdate,
                            onParagraphLongPressEnd: _onParagraphLongPressEnd,
                            selectionScope: scope,
                            selection: _selection,
                            rangeUnderlines: _rangeUnderlines,
                            annotationRanges: _annotationRanges,
                            narrationRange: _narrationRange,
                          )
                        : _buildScrollContent(layout, scope),
                  ),
                ),
              ),
              ..._selectionHandles(scope),
              ?_selectionBar(preset, windowPadding),
            ],
          ),
        );
      },
    );
  }

  /// The selection scope for the current layout: palette from the active
  /// theme, a fresh hit-test registry per layout so a block from the previous
  /// chapter can never answer a drag.
  ReaderSelectionScope _marksScopeFor(
    ReaderThemePreset preset,
    ReaderChapterLayout layout,
  ) {
    if (_marksScope == null || !identical(_marksScopeLayout, layout)) {
      _marksScope = ReaderSelectionScope(
        geometry: ReaderSelectionGeometry(),
        washColor: preset.selectionWashColor,
        handleColor: preset.selectionHandleColor,
        underlineColor: preset.selectionUnderlineColor,
        narrationColor: preset.narrationHighlightColor,
      );
      _marksScopeLayout = layout;
    }
    return _marksScope!;
  }

  /// The drag handles, floated above the content: handles living inside a
  /// block would fall outside every ancestor's hit-test box whenever a bound
  /// sat at the block edge (first line's top, last line's bottom, page foot).
  /// Positions resolve through the geometry registry after layout.
  List<Widget> _selectionHandles(ReaderSelectionScope scope) {
    final selection = _selection;
    if (selection == null || !selection.isValid) return const [];
    final start = _handleCaretOverlay(isStart: true);
    final end = _handleCaretOverlay(isStart: false);
    if (start == null && end == null) return const [];

    // Ink layout (官方 yd5.j.I()): the 1dp bar runs the selected line's full
    // height; the dot protrudes 6dp beyond the line edge. Start ink hugs the
    // widget top, end ink hugs the bottom — the touch margin sits on the far
    // side of the line.
    Widget handle(bool isStart, ({double x, double top, double bottom}) caret) {
      final lineHeight = caret.bottom - caret.top;
      final widget = ReaderSelectionHandle(
        isStart: isStart,
        color: scope.handleColor,
        lineHeight: lineHeight,
        onDragStart: _onHandleDragStart,
        onDragUpdate: (global) => _onHandleDrag(isStart, global),
        onDragEnd: (global) => _onHandleDragEnd(isStart, global),
      );
      return Positioned(
        key: ValueKey('reader-selection-handle-${isStart ? 'start' : 'end'}'),
        left: caret.x - ReaderSelectionHandle.touchWidth / 2,
        top: isStart
            ? caret.top - ReaderSelectionHandle.dotOverhang
            : caret.top - ReaderSelectionHandle.touchMargin,
        child: widget,
      );
    }

    return [
      if (start != null) handle(true, start),
      if (end != null) handle(false, end),
    ];
  }

  /// Overlay-local caret of one selection bound — the glyph edge x plus the
  /// selected line's vertical extent — or null when the bound's block is not
  /// mounted (an off-screen page).
  ({double x, double top, double bottom})? _handleCaretOverlay({
    required bool isStart,
  }) {
    final selection = _selection;
    final layout = _chapterLayout;
    final scope = _marksScope;
    if (selection == null || layout == null || scope == null) return null;
    final textOffset = isStart ? selection.start : selection.end - 1;
    final block = layout.blockForAnchor(textOffset, isStart: isStart);
    if (block == null) return null;
    final entry = scope.geometry.entryFor(block.index);
    if (entry == null) return null;
    final caret = selectionCaret(
      block: block,
      painter: entry.painter,
      textOffset: _boundOffsetInBlock(textOffset, block, isStart: isStart),
      isStart: isStart,
      columnWidth: layout.spec.width,
    );
    final overlayBox =
        _selectionOverlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.attached) return null;
    final origin = overlayBox.globalToLocal(
      entry.box.localToGlobal(Offset(caret.x, caret.top)),
    );
    return (
      x: origin.dx,
      top: origin.dy,
      bottom: origin.dy + caret.bottom - caret.top,
    );
  }

  /// [offset] (chapter space) resolved into [block]'s text space, snapping a
  /// separator offset onto the block's first or last real character.
  int _boundOffsetInBlock(
    int offset,
    ReaderContentBlock block, {
    required bool isStart,
  }) {
    return isStart
        ? offset.clamp(block.start, block.end - 1) - block.start
        : (offset + 1 > block.end ? block.end : offset + 1) - 1 - block.start;
  }

  /// Recomputes the handle overlay after the frame that (re)mounted the mark
  /// layers — their registry entries land in a post-frame callback of the
  /// same build, scheduled ahead of this one.
  void _updateHandlePositions() {
    if (_selection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selection == null) return;
      setState(() {});
    });
  }

  void _onHandleDragStart() {
    // The bar would sit under the finger; pop it, keep the selection.
    _closeSelectionBar(clearSelection: false);
  }

  /// Reshapes the selection to the character under the finger. The drag
  /// starts on a handle but crosses paragraphs, so the point resolves
  /// through the geometry registry, not the handle's own block.
  // Note: 拖动边界对齐官方（非空不变量、分隔符守卫）—
  // 见 .agents/notes/implemented/bug-fix/2026-09-19-selection-drag-boundary.md
  void _onHandleDrag(bool isStart, Offset global) {
    final selection = _selection;
    final layout = _chapterLayout;
    if (selection == null || layout == null) return;
    final offset = _marksScope?.geometry.chapterOffsetAt(global);
    if (offset == null) return;
    final range = layout.selectableTextRange;
    if (range == null) return;
    var next = selection.withBound(
      isStart: isStart,
      offset: offset.clamp(range.$1, range.$2),
      textLength: range.$2,
    );
    // A drag can land a bound on the '\n' separator between two blocks; such
    // a range paints nothing, so grow it onto the next real character — the
    // finger must never hold an invisible selection.
    if (next.isValid && next.end < range.$2 && _selectionPaintsNothing(next)) {
      next = next.copyWith(end: next.end + 1);
    }
    if (next == selection) return;
    setState(() => _selection = next);
  }

  /// True when no text block overlaps [selection] — a range covering only
  /// the separators between blocks.
  bool _selectionPaintsNothing(ReaderTextSelection selection) {
    final layout = _chapterLayout;
    if (layout == null) return true;
    for (final block in layout.blocks) {
      if (block.isTitle || block.isImage) continue;
      if (blockSelectionRange(block, selection.start, selection.end) != null) {
        return false;
      }
    }
    return true;
  }

  void _onHandleDragEnd(bool isStart, Offset global) {
    final selection = _selection;
    if (selection == null || !selection.isValid) {
      _clearSelection();
      return;
    }
    // Whatever the drag did, the range is no longer necessarily the
    // long-pressed paragraph: recompute the flag from the geometry so
    // 从本段听 tracks the real range instead of inheriting the long press.
    setState(
      () => _selection = selection.copyWith(
        isWholeParagraph: _isWholeParagraphSelection(selection),
      ),
    );
    _openSelectionBar(anchor: global);
  }

  /// True when [selection] covers exactly one non-title text block — the
  /// shape a long press creates. Computed, not inherited: a drag that happens
  /// to land on another whole paragraph deserves the same bar.
  bool _isWholeParagraphSelection(ReaderTextSelection selection) {
    final block = _chapterLayout?.blockAtOffset(selection.start);
    return block != null &&
        !block.isTitle &&
        !block.isImage &&
        selection.start == block.start &&
        selection.end == block.end;
  }

  /// The final chapter keeps a stable completion page. Other chapters go
  /// directly to the next text page; their comments are in the reader toolbar.
  ///
  /// 【青茄修复·滚动无缝】章末只留「本章完」一行文字：章末的
  /// 「查看本章评论」按钮已经删掉（评论入口在顶部工具栏）。
  Widget _buildChapterEndPage(ReaderThemePreset preset) {
    return ColoredBox(
      color: preset.backgroundColor,
      child: Center(
        child: Text(
          '本章完',
          style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
        ),
      ),
    );
  }

  /// The chapter-end aggregate bucket: the ideas response's greatest paragraph
  /// key (e.g. para 10000), which the official client opens for 章末章评.
  int? _chapterEndParagraph() =>
      _ideas.paragraphs.isEmpty ? null : _ideas.paragraphs.last.paraIndex;

  void _hideControlsOnDrag() {
    _stopAutoTurn();
    _pauseListenFollow();
    if (_controlsVisible) setState(() => _controlsVisible = false);
  }

  Widget _buildScrollContent(
    ReaderChapterLayout layout,
    ReaderSelectionScope scope,
  ) {
    // 【青茄修复·滚动无缝】先校准段窗口，再拍平列表项。
    // 所有段共用这一棵 ListView：段与段之间没有 footer、没有按钮、
    // 没有额外间隔，滚过章界就是下一章的开头。
    _syncScrollWindow(layout);
    final spec = layout.spec;
    final segments = _scrollSegments;
    final items = _scrollItems ??= _flattenScrollSegments();
    // The scroll list re-renders the measured span, so the bubble is already in
    // it. Its size still depends on this list's own constraints, and the
    // painter's placeholder was measured at spec.width — the same width, so the
    // two agree without a second measurement pass.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification) {
          // A new drag resets the bottom-overscroll accumulator, so only
          // one continuous-reading advance fires per drag past the end.
          _scrollOverscroll = 0;
          if (notification.dragDetails != null) {
            // Scrolling away cancels the selection (the official client keeps
            // it and repositions its toolbar after the scroll settles; here one
            // long press reselects instead).
            _closeSelectionBar(clearSelection: true);
            _hideControlsOnDrag();
          }
          return false;
        }
        if (notification is OverscrollNotification &&
            notification.dragDetails != null &&
            _preferences.continuousReading &&
            !_changingChapter &&
            !_loading) {
          // 连续阅读：窗口末尾再往下拉，走一次整章加载接上后一章；
          // 滚到顶后继续下拉，回到上一章末尾。窗口内的章界不会再产生
          // overscroll —— 那里已经是下一章的正文了。
          final overscroll = notification.overscroll;
          final canAdvance = _index < widget.chapters.length - 1;
          final canRetreat = _index > 0;
          if ((overscroll > 0 && canAdvance) ||
              (overscroll < 0 && canRetreat)) {
            _scrollOverscroll += overscroll;
            if (_scrollOverscroll > 32) {
              _scrollOverscroll = 0;
              unawaited(_next());
            } else if (_scrollOverscroll < -32) {
              _scrollOverscroll = 0;
              unawaited(_prev(startAtEnd: true));
            }
          }
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('reader-paragraph-list'),
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          spec.horizontalPadding,
          spec.verticalPadding,
          spec.horizontalPadding,
          spec.verticalPadding + 32,
        ),
        itemCount: items.length,
        // Exact extents let a distant saved text position restore in one frame;
        // a lazy variable-height list otherwise only estimates its scroll range.
        itemExtentBuilder: (index, _) {
          final item = items[index];
          final block = segments[item.segment].layout.blocks[item.block];
          return block.lines.isEmpty ? 0 : block.height + spec.paragraphSpacing;
        },
        itemBuilder: (context, index) {
          final item = items[index];
          final segment = segments[item.segment];
          final block = segment.layout.blocks[item.block];
          if (block.lines.isEmpty) return const SizedBox.shrink();
          // 只有活动段参与选区/长按/几何注册；其它段只负责画出来，
          // 跨章选区本来就不支持，但滚动必须顺畅。
          final active = item.segment == _scrollActive;
          return Padding(
            padding: EdgeInsets.only(bottom: spec.paragraphSpacing),
            child: active
                ? ReaderBlockContent(
                    block: block,
                    spec: spec,
                    imageProviderFactory: widget.imageProviderFactory,
                    selectionScope: scope,
                    selection: _selection,
                    rangeUnderlines: _rangeUnderlines,
                    annotationRanges: _annotationRanges,
                    narrationRange: _narrationRange,
                    onParagraphLongPress: (block, position) =>
                        unawaited(_onParagraphLongPress(block, position)),
                    onParagraphLongPressMoveUpdate:
                        _onParagraphLongPressMoveUpdate,
                    onParagraphLongPressEnd: _onParagraphLongPressEnd,
                  )
                : _buildQuietScrollBlock(block, segment.layout.spec),
          );
        },
      ),
    );
  }

  /// 非活动段的块：只画，不注册选区几何、不挂长按。
  ///
  /// 不走 [ReaderBlockContent] 是因为选区几何表按「块下标」建键，
  /// 两章的同号块会互相覆盖，手柄和高亮会跳到别的段上去。
  Widget _buildQuietScrollBlock(
    ReaderContentBlock block,
    ReaderLayoutSpec spec,
  ) {
    final note = block.inlineNote;
    if (note != null) {
      return ReaderNoteBlock(
        note: note,
        height: block.height,
        maxLines: block.noteLines,
      );
    }
    final image = block.illustration;
    if (image != null) {
      return ReaderIllustration(
        image: image,
        providerFactory: widget.imageProviderFactory,
      );
    }
    return Text.rich(
      block.span,
      style: block.span.style,
      textAlign: block.align,
      textScaler: spec.textScaler,
      textDirection: TextDirection.ltr,
      locale: const Locale('zh', 'CN'),
      semanticsLabel: block.text,
    );
  }

  Widget _buildReaderControls(ReaderThemePreset preset) {
    final seekValue = _chapterSeekValue ?? _index.toDouble();
    final previewIndex = seekValue.round().clamp(0, widget.chapters.length - 1);
    return ReaderControls(
      key: const ValueKey('reader-controls'),
      preferences: _displayPreferences,
      chapterIndex: previewIndex,
      chapterCount: widget.chapters.length,
      chapterTitle: widget.chapters[previewIndex].title,
      seekValue: seekValue,
      deviceAvailable: _deviceAvailable,
      systemBrightness: _deviceStatus.systemBrightness,
      onPrevious: _index > 0 ? () => _prev(startAtEnd: true) : null,
      onNext: _index < widget.chapters.length - 1 ? _next : null,
      onSeek: (value) => setState(() => _chapterSeekValue = value),
      onSeekEnd: (value) {
        setState(() => _chapterSeekValue = null);
        _jumpToChapter(value.round());
      },
      onBrightness: _changeBrightness,
      onBrightnessEnd: () => unawaited(_savePreferences()),
      onFollowSystem: () {
        _changeBrightness(
          _preferences.followSystemBrightness
              ? _deviceStatus.systemBrightness ?? _preferences.brightness
              : _preferences.brightness,
          followSystem: !_preferences.followSystemBrightness,
        );
        unawaited(_savePreferences());
      },
      onDirectory: _showDirectory,
      onNight: _toggleNightTheme,
      onAppearance: _showAppearanceSettings,
      onCache: _showCache,
      onListen: () => unawaited(_openListening()),
      showListening: true,
      showCache: !widget.localOnly,
      autoTurnActive: _autoTurnTimer != null,
      onAutoTurn: _toggleAutoTurn,
    );
  }

  Widget _errorView({Color? textColor}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? '加载失败',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor ?? Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _load(startAtEnd: _requestedStartAtEnd),
            child: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

class _ChapterDirectorySheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  final Set<String> cachedIds;

  const _ChapterDirectorySheet({
    required this.chapters,
    required this.currentIndex,
    required this.cachedIds,
  });

  @override
  State<_ChapterDirectorySheet> createState() => _ChapterDirectorySheetState();
}

class _ChapterDirectorySheetState extends State<_ChapterDirectorySheet> {
  static const _itemExtent = 58.0;

  final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController;
  bool _reversed = false;
  String _query = '';
  // The directory can hold thousands of chapters; filtering on every keystroke
  // re-scans them all and rebuilds the sheet. Coalesce the input instead.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final initialOffset = (widget.currentIndex * _itemExtent - 120).clamp(
      0.0,
      double.infinity,
    );
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
  }

  List<int> get _visibleIndexes {
    Iterable<int> indexes = Iterable<int>.generate(widget.chapters.length);
    if (_reversed) indexes = indexes.toList(growable: false).reversed;
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      indexes = indexes.where((index) {
        final chapter = widget.chapters[index];
        return chapter.title.toLowerCase().contains(query) ||
            '${index + 1}'.contains(query);
      });
    }
    return indexes.toList(growable: false);
  }

  void _toggleOrder() {
    setState(() => _reversed = !_reversed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || _query.isNotEmpty) return;
      final displayIndex = _reversed
          ? widget.chapters.length - 1 - widget.currentIndex
          : widget.currentIndex;
      final target = (displayIndex * _itemExtent - 120).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final indexes = _visibleIndexes;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '目录 · ${widget.chapters.length} 章',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: _reversed ? '切换为正序' : '切换为倒序',
                onPressed: _toggleOrder,
                icon: Icon(
                  _reversed ? LucideIcons.arrow_up : LucideIcons.arrow_down,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: '搜索章节名或序号',
              prefixIcon: const Icon(LucideIcons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      onPressed: () {
                        _searchDebounce?.cancel();
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(LucideIcons.x),
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: indexes.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配的章节',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemExtent: _itemExtent,
                  itemCount: indexes.length,
                  itemBuilder: (context, position) {
                    final index = indexes[position];
                    final chapter = widget.chapters[index];
                    final current = index == widget.currentIndex;
                    return Material(
                      color: current
                          ? scheme.primaryContainer.withValues(alpha: 0.72)
                          : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        selected: current,
                        onTap: () => Navigator.pop(context, index),
                        leading: SizedBox(
                          width: 42,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              color: current
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                              fontWeight: current
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        title: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.cachedIds.contains(chapter.itemId))
                              const Tooltip(
                                message: '已缓存',
                                child: Icon(LucideIcons.circle_check, size: 18),
                              ),
                            if (current)
                              Icon(
                                LucideIcons.locate_fixed,
                                color: scheme.primary,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 【青茄修复·滚动无缝】滚动模式的一个「章节段」：一章的排版 + 批注数据，
/// 拼进同一棵 ListView。段与段之间不插任何组件，跨章就是下一段的第一块。
class _ScrollSegment {
  _ScrollSegment({
    required this.chapter,
    required this.text,
    required this.content,
    required this.layout,
    required this.annotations,
  });

  final Chapter chapter;

  /// 该章的缓存正文（切换成当前章时回填 `_content`）。
  final String text;

  final ChapterContent content;

  /// 用当前 [ReaderLayoutSpec] 量出来的排版；装饰变化（划线/批注）时
  /// 会在原地替换成新测量结果，几何不变。
  ReaderChapterLayout layout;

  /// 该章批注（参与 inlineNotes 排版，保证高度正确）。
  final List<ReaderAnnotation> annotations;

  /// 在整条列表里的起始偏移（不含 ListView 顶部内边距）。
  double top = 0;

  /// 段内容高度（不含段尾的段间距）。
  double get height => layout.blocks.isEmpty
      ? 0
      : layout.blocks.last.top + layout.blocks.last.height;

  /// 这一段在列表里实际占据的高度：每个块都带一段段间距，
  /// 与 `itemExtentBuilder` 的逐项高度之和一致，段起点据此累加。
  double get extent => layout.contentHeight;
}
