part of '../../pages/audio_page.dart';

/// 跟踪 Navigator 的路由栈，用来判断「听书页是否真的被另一个页面盖住」。
///
/// `ModalRoute.isCurrentOf` 把弹窗、菜单、底部面板也算作「上面有东西」，
/// 于是听书页一开弹层，迷你胶囊就会冒出来盖住播放控件。这里只看页面路由
/// （[PageRoute]），弹层（[PopupRoute]）不算遮挡。
class AudioRouteWatcher extends NavigatorObserver with ChangeNotifier {
  AudioRouteWatcher._();

  static final AudioRouteWatcher instance = AudioRouteWatcher._();

  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  /// 没有接入 Navigator 时（例如 widget 测试里的裸 MaterialApp）返回 false，
  /// 调用方回退到 `ModalRoute.isCurrentOf`。
  bool get tracksRoutes => _routes.isNotEmpty;

  @visibleForTesting
  void resetForTest() => _routes.clear();

  /// 栈顶是弹层（弹窗 / 底部面板 / 菜单）时为 true。
  ///
  /// 胶囊挂在 Navigator 之外的最外层 Overlay，天然压在弹层之上：阅读页
  /// 打开「听书 / 系统朗读」选择面板时，胶囊会盖住面板里的「听书」一行。
  /// 这里用路由栈判断，弹层期间先让胶囊退场。
  bool get popupOpen =>
      _routes.isNotEmpty && _routes.last is PopupRoute<dynamic>;

  bool isTopPage(Route<dynamic> route) {
    for (final other in _routes.reversed) {
      if (other is PageRoute<dynamic>) return identical(other, route);
    }
    return false;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    notifyListeners();
  }
}

/// 阅读页与听书胶囊之间的轻量协调层。
///
/// 胶囊挂在 Navigator 之外的最外层 Overlay，读不到阅读页内部状态，所以
/// 阅读页把「工具栏是否展开」「是否有置顶弹窗」写进这里。
/// 工具栏收起时胶囊不再退化成底部小按钮，而是始终保持完整形态，保证
/// 播放/暂停、设置、关闭这些控制入口一直可用；只有弹出休息提醒等置顶
/// 弹窗时才暂时隐藏，让弹窗真正压在最上层。
class ReadingCapsuleHost extends ChangeNotifier {
  ReadingCapsuleHost._();

  static final ReadingCapsuleHost instance = ReadingCapsuleHost._();

  bool _toolbarVisible = false;
  bool _dialogOpen = false;

  bool get toolbarVisible => _toolbarVisible;
  bool get dialogOpen => _dialogOpen;

  void enterReader() => notifyListeners();

  void exitReader() {
    _toolbarVisible = false;
    notifyListeners();
  }

  void setToolbarVisible(bool value) {
    if (_toolbarVisible == value) return;
    _toolbarVisible = value;
    notifyListeners();
  }

  void setDialogOpen(bool value) {
    if (_dialogOpen == value) return;
    _dialogOpen = value;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _toolbarVisible = false;
    _dialogOpen = false;
    notifyListeners();
  }
}

/// Owns one listening session for the lifetime of the app's Navigator.
class AudioPlaybackScope extends StatefulWidget {
  const AudioPlaybackScope({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  static Future<void> startSystemTts(BuildContext context, SystemTtsBook book) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    if (owner == null) throw StateError('当前阅读入口不支持持续朗读');
    return owner.startSystemTts(book);
  }

  @override
  State<AudioPlaybackScope> createState() => _AudioPlaybackScopeState();
}

class _AudioPlaybackScopeState extends State<AudioPlaybackScope> {
  _AudioPlaybackController? _session;
  SystemTtsPlayback? _tts;
  SystemTtsPlayback? _ttsPage;
  Future<void> _queue = Future<void>.value();
  final _views = <_AudioPageState>{};
  bool _rebuildPending = false;
  late final Future<void> Function(NativePlayer) _playGate = _beforePlay;

  @override
  void initState() {
    super.initState();
    NativePlayer.beforePlay = _playGate;
    ReadingCapsuleHost.instance.addListener(_changed);
    AudioRouteWatcher.instance.addListener(_changed);
  }

  Future<void> _beforePlay(NativePlayer player) async {
    await _tts?.pause();
    final session = _session;
    if (session == null || session._closed) return;
    if (identical(player, session._player)) {
      await NativePlayer.pauseOthers(player);
    } else {
      await session._pauseForOtherMedia();
    }
  }

  Future<_AudioPlaybackController?> acquire(AudioPage request) {
    final next = _queue.then((_) async {
      if (!mounted) return null;
      await _closeTts();
      if (!mounted) return null;
      final current = _session;
      if (current != null &&
          !current._closed &&
          current._bookId == request.bookId) {
        if ((!request.resumeSession || request.startPosition != null) &&
            request.chapters.isNotEmpty) {
          final chapter =
              request.chapters[request.startIndex.clamp(
                0,
                request.chapters.length - 1,
              )];
          final index = current._chapters.indexWhere(
            (c) => c.itemId == chapter.itemId,
          );
          if (index >= 0) {
            unawaited(
              current._openChapter(
                index,
                position: request.startPosition,
                toneId: request.initialToneId,
                restoreHistory: true,
                autoplay: request.autoplay,
              ),
            );
            return current;
          }
          // A refreshed directory can remove an old chapter. Start the exact
          // requested directory instead of silently retaining another chapter.
        } else {
          return current;
        }
      }
      await _closeCurrent();
      if (!mounted) return null;
      final session = _AudioPlaybackController(request);
      _session = session;
      session.onStop = () => unawaited(stop(session));
      session.addListener(_changed);
      session.start();
      _changed();
      return session;
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> stop(_AudioPlaybackController session) {
    final next = _queue.then((_) async {
      if (identical(_session, session)) await _closeCurrent();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _closeCurrent() async {
    final session = _session;
    _session = null;
    session?.removeListener(_changed);
    _changed();
    await session?.close();
  }

  Future<void> startSystemTts(SystemTtsBook book) {
    final next = _queue.then((_) async {
      if (!mounted || book.chapters.isEmpty) return;
      await _closeCurrent();
      await _closeTts();
      if (!mounted) return;
      late final SystemTtsPlayback session;
      session = SystemTtsPlayback(
        book,
        beforePlay: () async {
          if (mounted && identical(_tts, session)) {
            await NativePlayer.pauseOthers();
          }
        },
        onStop: () => unawaited(stopTts(session)),
      );
      _tts = session;
      session.addListener(_changed);
      session.start();
      _changed();
      try {
        // Do not close the listening page until the first body is loaded and
        // the engine accepted the first utterance. A locked chapter with no
        // readable text must fail in place, not flash back to the reader.
        await session.started.timeout(const Duration(seconds: 40));
      } catch (_) {
        if (identical(_tts, session)) await _closeTts();
        rethrow;
      }
      if (session.closed || session.error != null) {
        final message = session.error ?? '系统朗读未能启动';
        if (identical(_tts, session)) await _closeTts();
        throw StateError(message);
      }
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> stopTts(SystemTtsPlayback session) {
    final next = _queue.then((_) async {
      if (identical(_tts, session)) await _closeTts();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _closeTts() async {
    final session = _tts;
    _tts = null;
    session?.removeListener(_changed);
    _changed();
    await session?.close();
  }

  void _openTts(SystemTtsPlayback session) {
    if (session.closed ||
        !identical(_tts, session) ||
        identical(_ttsPage, session)) {
      return;
    }
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    _ttsPage = session;
    _changed();
    unawaited(
      navigator
          .push<void>(
            MaterialPageRoute<void>(
              builder: (_) => SystemTtsPlaybackPage(
                session: session,
                onClose: () => unawaited(stopTts(session)),
              ),
            ),
          )
          .whenComplete(() {
            if (identical(_ttsPage, session)) {
              _ttsPage = null;
              _changed();
            }
          }),
    );
  }

  void viewChanged(_AudioPageState view) {
    _views.add(view);
    _changed();
  }

  void removeView(_AudioPageState view) {
    _views.remove(view);
    _changed();
  }

  void _changed() {
    if (!mounted || _rebuildPending) return;
    _rebuildPending = true;
    // Views attach/detach while Navigator builds. Defer the ancestor rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _open(_AudioPlaybackController session) {
    if (session._closed || !identical(_session, session)) return;
    final request = session.request;
    unawaited(
      widget.navigatorKey.currentState?.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AudioPage(
            bookId: session._bookId,
            title: session._title,
            cover: session._cover,
            chapters: session._chapters,
            startIndex: session._index,
            historyStore: request.historyStore,
            playerFactory: request.playerFactory,
            sourceLoader: request.sourceLoader,
            voicesLoader: request.voicesLoader,
            extrasLoader: request.extrasLoader,
            subtitleLoader: request.subtitleLoader,
            excerptLoader: request.excerptLoader,
            directoryLoader: request.directoryLoader,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    ReadingCapsuleHost.instance.removeListener(_changed);
    AudioRouteWatcher.instance.removeListener(_changed);
    if (identical(NativePlayer.beforePlay, _playGate)) {
      NativePlayer.beforePlay = null;
    }
    final session = _session;
    _session = null;
    session?.removeListener(_changed);
    // Descendant audio/reader views finish detaching before close broadcasts.
    if (session != null) unawaited(Future<void>.microtask(session.close));
    final tts = _tts;
    _tts = null;
    tts?.removeListener(_changed);
    if (tts != null) unawaited(Future<void>.microtask(tts.close));
    super.dispose();
  }

  // The mini bars below are siblings of the Navigator, not descendants,
  // so they have no Overlay ancestor for their IconButton tooltips
  // (the Navigator owns its own Overlay internally). Wrap the column
  // in an Overlay so the tooltips resolve to this outer Overlay, while
  // route content still resolves to the Navigator's inner Overlay.
  //
  // The entry is created once: Overlay only reads initialEntries in
  // initState, so an entry rebuilt in build() would never be inserted
  // and its builder would stay frozen on the first build's values
  // (mini bars never appearing). The builder below reads live state,
  // so each scope rebuild re-renders the bars with current values.
  late final OverlayEntry _entry = OverlayEntry(builder: _buildEntry);

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry]);
  }

  // 胶囊的落点：拖过之后记住，换会话时回到默认位置。
  Offset? _capsuleAt;
  Object? _capsuleOwner;

  Offset _defaultCapsule(BoxConstraints box, EdgeInsets padding) => Offset(
    16,
    math.max(
      padding.top + 8,
      box.maxHeight - padding.bottom - ListeningCapsule.height - 96,
    ),
  );

  Offset _clampCapsule(Offset wanted, BoxConstraints box, EdgeInsets padding) {
    final maxX = math.max(8.0, box.maxWidth - ListeningCapsule.width - 8);
    final maxY = math.max(
      padding.top + 8,
      box.maxHeight - padding.bottom - ListeningCapsule.height - 8,
    );
    return Offset(
      wanted.dx.clamp(8.0, maxX),
      wanted.dy.clamp(padding.top + 8, maxY),
    );
  }

  Widget _buildEntry(BuildContext context) {
    final session = _session;
    final tts = _tts;
    final showAudio =
        session != null &&
        !session._closed &&
        !_views.any((v) => v._routeCurrent && identical(v._session, session));
    // 听书详情页自己就是完整的播放器，再浮一颗胶囊只会压在传输控件上。
    final showTts = tts != null && !tts.closed && !identical(_ttsPage, tts);
    final showCapsule = showAudio || showTts;
    final host = ReadingCapsuleHost.instance;
    // 阅读页收起工具栏时胶囊保持完整形态，用播放/暂停、设置、关闭继续
    // 提供听书控制；任何置顶弹窗（如 45 分钟护眼提醒）打开期间胶囊整体
    // 隐藏，弹窗才能真正压在最上层。
    final suppressed = host.dialogOpen || AudioRouteWatcher.instance.popupOpen;
    final owner = showAudio ? session : tts;
    if (!identical(_capsuleOwner, owner)) {
      _capsuleOwner = owner;
      _capsuleAt = null;
    }
    return LayoutBuilder(
      builder: (context, box) {
        final padding = MediaQuery.paddingOf(context);
        final at = _clampCapsule(
          _capsuleAt ?? _defaultCapsule(box, padding),
          box,
          padding,
        );
        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (showCapsule && !suppressed)
              Positioned(
                left: at.dx,
                top: at.dy,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    // 快速滑动时一帧内会有多次 pointer move；必须以最新的
                    // 落点为基准累加，否则每次都用同一帧的旧坐标，手指走完
                    // 胶囊却只挪了一小步。
                    final next = _clampCapsule(
                      (_capsuleAt ?? at) + details.delta,
                      box,
                      padding,
                    );
                    if (next == _capsuleAt) return;
                    setState(() => _capsuleAt = next);
                  },
                  child: showAudio ? _audioCapsule(session) : _ttsCapsule(tts!),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _audioCapsule(_AudioPlaybackController session) {
    final chapterTitle = session._chapters.isEmpty
        ? '暂无章节'
        : session._chapters[session._index].title;
    return ListeningCapsule(
      title: session._title,
      status: session._error != null
          ? '播放失败'
          : session._loading
          ? '正在加载…'
          : chapterTitle,
      playing: session._wantPlay && !session._completed,
      onOpen: () => _open(session),
      onToggle: session._ready ? session._togglePlayback : null,
      // 胶囊挂在 Navigator 之外，弹层要用 Navigator 自己的 context，
      // 否则 showModalBottomSheet 找不到可用的 Navigator。
      onSettings: () => unawaited(_openListeningSettings(session)),
      onClose: () => unawaited(stop(session)),
    );
  }

  Widget _ttsCapsule(SystemTtsPlayback session) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => ListeningCapsule(
      title: session.book.title,
      status: session.error != null
          ? '朗读失败'
          : session.loading
          ? '正在准备…'
          : '系统朗读 · ${session.chapter.title}',
      playing: session.wantPlay,
      onOpen: () => _openTts(session),
      onToggle: () => unawaited(session.toggle()),
      onSettings: () => unawaited(_openTtsSettings()),
      onClose: () => unawaited(stopTts(session)),
    ),
  );

  Future<void> _openListeningSettings(_AudioPlaybackController session) async {
    final context = widget.navigatorKey.currentState?.overlay?.context;
    if (context == null) return;
    await _showListeningSettings(context, session);
  }

  Future<void> _openTtsSettings() async {
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const SystemTtsSettingsPage()),
    );
  }
}
