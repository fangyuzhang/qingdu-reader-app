part of '../pages/audio_page.dart';

// Note: 会话持有播放器，页面只订阅；见
// .agents/notes/implemented/architecture/2026-10-15-persistent-audio-session.md.
class _AudioPlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  _AudioPlaybackController(this.request);
  final AudioPage request;
  bool _closed = false;
  Future<void>? _closing;
  VoidCallback? onStop;

  void _update(VoidCallback action) {
    if (_closed) return;
    action();
    notifyListeners();
  }

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _defaultVoice = AudioVoice(id: '0', label: '默认音色');

  late String _bookId;
  late String _title;
  late String _cover;
  late List<Chapter> _chapters;
  late int _index;
  late final AudioHistory _history;
  int _settingsGeneration = 0;
  Future<void> _settingsReady = Future<void>.value();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _listenTime = Stopwatch();
  Future<void> _releases = Future<void>.value();
  NativePlayer? _player;
  int? _activeIndex;
  bool _hasPlayed = false;
  int _generation = 0;
  int _seekGeneration = 0;
  Timer? _saveTimer;
  bool _appActive = true;
  bool _loading = true;
  bool _wantPlay = true;
  bool _completed = false;
  bool _autoAdvance = true;
  String? _error;
  String _toneId = '0';
  String _excerpt = '';
  int _excerptGeneration = 0;
  double _rate = 1;
  // The narration position ticks ~5×/s and feeds only the progress row, so
  // both are ValueNotifiers: the 5Hz stream rebuilds that row instead of the
  // whole page (cover image, tone cards, related-works list and all).
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<double?> _seekPreview = ValueNotifier(null);
  Duration _duration = Duration.zero;
  List<AudioVoice> _voices = const [_defaultVoice];
  AudioExtras _extras = const AudioExtras();
  SubtitleTrack _subtitles = SubtitleTrack.empty;
  // Modal routes rebuild independently of the player page. See
  // .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
  final _readAlong = ValueNotifier<_ReadAlongSnapshot>((
    chapterTitle: '',
    track: SubtitleTrack.empty,
    position: Duration.zero,
  ));
  final _moreState = ValueNotifier<_MoreSnapshot>((
    loading: true,
    autoAdvance: true,
    sleepMinutes: null,
  ));
  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  bool _inShelf = false;
  bool _switchingVersion = false;
  final Map<String, AudioSource> _audioSourceCache = {};
  Timer? _sleepTimerTick;

  void _prefetchNextAudioChapter() {
    if (request.sourceLoader != null ||
        !_autoAdvance ||
        _index + 1 >= _chapters.length) {
      return;
    }
    final nextId = _chapters[_index + 1].itemId;
    final cacheKey = '$nextId|$_toneId';
    if (_audioSourceCache.containsKey(cacheKey)) return;
    unawaited(
      _loadSourceWithRetry(
        nextId,
      ).catchError((Object _) => AudioSource(itemId: nextId, url: '')),
    );
  }

  /// Resolves the listening-page decorations. See [AudioExtras].
  Future<AudioExtras> _loadExtras() {
    final loader = request.extrasLoader;
    if (loader != null) return loader(_bookId);
    if (request.sourceLoader != null ||
        request.voicesLoader != null ||
        request.playerFactory != null) {
      return Future.value(const AudioExtras());
    }
    return _defaultAudioExtras(_bookId);
  }

  /// Resolves 边听边读 subtitles. Books without generated speech text answer
  /// with an empty track, so this is never treated as an error.
  Future<SubtitleTrack> _loadSubtitles(String itemId, String toneId) {
    final loader = request.subtitleLoader;
    if (loader != null) return loader(itemId, toneId);
    if (request.sourceLoader != null || request.playerFactory != null) {
      return Future.value(SubtitleTrack.empty);
    }
    return ApiClient.instance.chapterTimeline(itemId, toneId: toneId);
  }

  bool _current(int generation, [NativePlayer? player]) =>
      !_closed &&
      generation == _generation &&
      (player == null || identical(player, _player));

  bool get _ready =>
      !_closed && !_loading && _error == null && (_player?.isCreated ?? false);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    NativePlayer.setRemoteCommandHandler(
      onAction: _handleRemoteAction,
      onBecomingNoisy: _handleBecomingNoisy,
    );
    unawaited(AudioPreferences.instance.load());
    AudioPreferences.instance.backgroundPlayback.addListener(
      _preferencesChanged,
    );
    _history = AudioHistory(request.historyStore ?? LibraryStore.instance);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _bookId = request.bookId;
    _title = request.title;
    _cover = request.cover;
    _chapters = request.chapters;
    _index = _chapters.isEmpty
        ? 0
        : request.startIndex.clamp(0, _chapters.length - 1);
    _settingsReady = _prepareSettings();
    if (_chapters.isEmpty) {
      _loading = false;
    } else {
      unawaited(
        _openChapter(
          _index,
          restoreHistory: true,
          autoplay: request.autoplay,
          position: request.startPosition,
        ),
      );
    }
  }

  Future<void> _prepareSettings({String? forceToneId}) async {
    final generation = ++_settingsGeneration;
    final history = _history.load(_bookId).catchError((Object _) => null);
    final voices = () async {
      try {
        return await (request.voicesLoader?.call() ??
                ApiClient.instance.audioVoices(_bookId))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        return <AudioVoice>[_defaultVoice];
      }
    }();
    final extras = _loadExtrasSafely();
    final saved = await history;
    final available = await voices;
    if (_closed || generation != _settingsGeneration) return;
    final byId = <String, AudioVoice>{'0': _defaultVoice};
    for (final voice in available) {
      if (voice.id.trim().isNotEmpty && voice.label.trim().isNotEmpty) {
        byId[voice.id] = voice;
      }
    }
    final savedTone = saved?['toneId'];
    final savedRate = saved?['rate'];
    final initialTone = request.initialToneId?.trim();
    // Only a saved voice that the decorations endpoint knows is worth waiting
    // for before the first source request. Letting /tones, /related or /detail
    // gate playback for everyone else is the p09 defect; the wait is bounded
    // so a slow or hung decorations call can never block playback forever.
    AudioExtras? resolved;
    if ((initialTone == null || initialTone.isEmpty) &&
        savedTone is String &&
        savedTone.trim().isNotEmpty &&
        !byId.containsKey(savedTone)) {
      try {
        resolved = await extras.timeout(const Duration(seconds: 3));
      } catch (_) {
        resolved = null;
      }
      if (_closed || generation != _settingsGeneration) return;
      if (resolved != null) _mergeToneVoices(resolved, byId);
    }
    _update(() {
      if (resolved != null) _extras = resolved;
      _voices = List.unmodifiable(byId.values);
      if (generation == 1) {
        if (savedTone is String && byId.containsKey(savedTone)) {
          _toneId = savedTone;
        }
        if (initialTone != null && initialTone.isNotEmpty) {
          _toneId = initialTone;
        }
        if (savedRate is num &&
            savedRate.isFinite &&
            _rates.contains(savedRate.toDouble())) {
          _rate = savedRate.toDouble();
        }
        final initialRate = request.initialRate;
        if (initialRate != null && _rates.contains(initialRate)) {
          _rate = initialRate;
        }
      }
      if (forceToneId != null && forceToneId.isNotEmpty) {
        _toneId = forceToneId;
      }
      if (saved?['autoAdvance'] case final bool enabled) {
        _autoAdvance = enabled;
      }
      // 是否已在书架以本地收藏库为准；收藏库不可用时退回历史里的旧字段，
      // 以免没有 Hive 的环境丢掉标记。
      _inShelf = _resolveShelf(saved);
    });
    _publishMoreState();
    unawaited(_publishExtras(extras, generation));
  }

  Future<AudioExtras> _loadExtrasSafely() async {
    try {
      return await _loadExtras().timeout(const Duration(seconds: 10));
    } catch (_) {
      return const AudioExtras();
    }
  }

  /// Mirrors the upstream tone list as-is: same names, same order. Two
  /// different tones may share a display name (the official panel shows them
  /// as two cards distinguished by their description); the ids stay distinct.
  List<AudioTone> _uniqueTones(List<AudioTone> tones) {
    final seen = <String>{};
    final out = <AudioTone>[];
    for (final tone in tones) {
      if (!seen.add('${tone.id}\u0000${tone.title}')) continue;
      out.add(tone);
    }
    return out;
  }

  void _mergeToneVoices(AudioExtras loaded, Map<String, AudioVoice> byId) {
    // Real tone names beat the CSV fallback's placeholder labels. 真人讲书
    // narrators only arrive here; their ids were resolved exactly by
    // AudioToneSet.fromPayload, which drops any unresolved narrator.
    final tones = _uniqueTones([
      ...loaded.tones.ttsTones,
      ...loaded.tones.narratorTones,
    ]);
    final labels = <String, String>{
      for (final voice in byId.values) voice.label: voice.id,
    };
    for (final tone in tones) {
      final id = tone.id.trim();
      final title = tone.title.trim();
      if (id.isEmpty || title.isEmpty) continue;
      var label = title;
      if (labels.containsKey(label) && labels[label] != id) {
        label = '$title（$id）';
        var bump = 2;
        while (labels.containsKey(label) && labels[label] != id) {
          label = '$title（$id·${bump++})';
        }
      }
      labels[label] = id;
      byId[id] = AudioVoice(id: id, label: label);
    }
  }

  Future<void> _publishExtras(
    Future<AudioExtras> extras, [
    int? generation,
  ]) async {
    AudioExtras loaded;
    try {
      loaded = await extras;
    } catch (_) {
      loaded = const AudioExtras();
    }
    if (_closed) return;
    if (generation != null && generation != _settingsGeneration) return;
    final byId = <String, AudioVoice>{
      for (final voice in _voices) voice.id: voice,
    };
    _mergeToneVoices(loaded, byId);
    _update(() {
      _extras = loaded;
      _voices = List.unmodifiable(byId.values);
    });
  }

  void _syncForeground() {
    if (_closed || _index < 0 || _index >= _chapters.length) return;
    if (!AudioPreferences.instance.backgroundPlayback.value) {
      unawaited(NativePlayer.stopListenForeground());
      return;
    }
    final player = _player;
    final isPlaying =
        (player?.playing ?? false) && _wantPlay && !_completed && !_loading;
    unawaited(
      NativePlayer.startListenForeground(
        title: _title,
        episode: _chapters[_index].title,
        playing: isPlaying,
        hasPrev: _index > 0,
        hasNext: _index < _chapters.length - 1,
        // 位置 + 倍速交给系统外推，媒体卡片的进度条才会动；总时长是两侧时间的来源。
        positionMs: player?.position.inMilliseconds ?? 0,
        durationMs: _duration.inMilliseconds,
        speed: _rate,
      ),
    );
  }

  void _handleRemoteAction(String action) {
    if (_closed) return;
    switch (action) {
      case 'playPause':
        unawaited(_togglePlayback());
      case 'prev':
        unawaited(_switchChapter(-1));
      case 'next':
        unawaited(_switchChapter(1));
      case 'stop':
        if (onStop case final stop?) {
          stop();
        } else {
          unawaited(close());
        }
    }
  }

  void _handleBecomingNoisy() {
    unawaited(_pauseForOtherMedia());
  }

  Future<void> _pauseForOtherMedia() async {
    if (_closed || !_wantPlay) return;
    _update(() => _wantPlay = false);
    _listenTime.stop();
    final player = _player;
    if (player != null && player.isCreated) {
      await _pause(player, _generation);
    }
    _syncForeground();
  }

  void _preferencesChanged() {
    if (_closed) return;
    if (!_appActive && !AudioPreferences.instance.backgroundPlayback.value) {
      unawaited(_pauseForOtherMedia());
    }
    _syncForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      // 切换到后台或锁屏时立即持久化当前进度，防止后续被系统杀后台导致进度丢失。
      unawaited(_persistProgress());
      // 若后台听书开关关闭，切后台自动暂停播放并移除前台通知。
      if (!AudioPreferences.instance.backgroundPlayback.value) {
        unawaited(_pauseForOtherMedia());
        unawaited(NativePlayer.stopListenForeground());
      }
    }
    _syncListenClock();
    if (!_closed) _update(() {});
  }

  Future<void> _openChapter(
    int index, {
    bool restoreHistory = false,
    Duration? position,
    String? toneId,
    bool autoplay = true,
    bool? completed,
    bool persistCurrent = true,
    int skipEmptyDirection = 0,
    int skipEmptyRemaining = 12,
  }) async {
    if (_closed || index < 0 || index >= _chapters.length) return;
    final generation = ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _listenTime.stop();
    if (persistCurrent) unawaited(_persistProgress());
    final released = _releasePlayer();
    _update(() {
      _index = index;
      _loading = true;
      _error = null;
      _completed = false;
      _position.value = position ?? Duration.zero;
      _duration = Duration.zero;
      _seekPreview.value = null;
      _subtitles = SubtitleTrack.empty;
      _wantPlay =
          autoplay &&
          (_appActive || AudioPreferences.instance.backgroundPlayback.value);
    });
    _publishReadAlong();
    _publishMoreState();
    unawaited(_loadExcerpt(_chapters[index].itemId));
    NativePlayer? candidate;
    try {
      await _settingsReady;
      if (!_current(generation)) return;
      if (toneId != null) _toneId = toneId;
      Map<String, dynamic>? saved;
      if (restoreHistory) {
        try {
          saved = await _history.load(_bookId);
        } catch (_) {
          // Listening can still start when local storage is unavailable.
        }
      }
      if (!_current(generation)) return;
      final sameChapter = resumeAudioChapterIndex(saved, _chapters) == index;
      final resume =
          position ??
          (sameChapter ? _savedDuration(saved?['position']) : Duration.zero);
      final savedDuration = sameChapter
          ? _savedDuration(saved?['duration'])
          : Duration.zero;
      // A position handed in from outside is a deliberate start point, not a
      // resume: the chapter's saved "played to the end" state must not turn it
      // into a replay-from-zero or a skip to the next chapter.
      // A start position handed in from outside is a deliberate new start, not
      // a resume: a chapter saved as "played to the end" must not turn it into
      // a replay-from-zero on the next play tap, nor skip to the next chapter.
      final wasCompleted =
          completed ??
          (position == null && sameChapter && saved?['completed'] == true);
      final itemId = _chapters[index].itemId;
      final source = await _loadSourceWithRetry(itemId);
      if (!_current(generation)) return;
      final uri = Uri.tryParse(source.url);
      if (source.itemId != itemId ||
          uri == null ||
          !const ['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException('Invalid audio source');
      }
      await released;
      if (!_current(generation)) return;
      final player = candidate =
          request.playerFactory?.call() ?? NativePlayer();
      _player = player;
      await player.create(source.url, source.keyHex);
      if (!_current(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      _subscribe(player, generation);
      await player.setRate(_rate);
      if (!_current(generation, player)) return;
      final duration = player.duration > Duration.zero
          ? player.duration
          : (source.duration ?? Duration.zero) > Duration.zero
          ? source.duration!
          : savedDuration;
      final restoredPosition = _boundedPosition(resume, duration);
      if (restoredPosition > Duration.zero) {
        await player.seek(restoredPosition);
        if (!_current(generation, player)) return;
      }
      _update(() {
        _activeIndex = index;
        _toneId = source.toneId;
        _duration = duration;
        _position.value = _boundedPosition(player.position, duration);
        _completed = wasCompleted;
        if (wasCompleted) _wantPlay = false;
        _loading = false;
      });
      _publishReadAlong();
      _publishMoreState();
      // Subtitles are decoration: they arrive whenever the book has generated
      // speech text and are ignored otherwise.
      unawaited(_refreshSubtitles(generation, itemId, source.toneId));
      if (_wantPlay) await _play(player, generation);
      if (!_current(generation, player)) return;
      _syncForeground();
      _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!player.playing) return;
        unawaited(_persistProgress());
        // 每 5 秒回一次真实位置：系统进度条靠外推前进，缓冲/卡顿时会跑偏。
        _syncForeground();
      });
      _syncListenClock();
    } catch (error) {
      // 诊断用：只记异常类型与上游文案（不含 URL / 密钥 / 响应体），
      // 设置 → 服务 → 日志即可看到具体是哪一步失败。
      AppLog.e(
        'audio',
        '第 ${index + 1} 章音源失败 ${error.runtimeType}: $error',
        error: error,
      );
      // 版权页、前折页、书名页这类只有图片的前置章节在上游没有音频，翻章
      // 撞上它们时不该停在“本章暂无音频内容”的死页上：沿同一个方向继续找
      // 下一章真的有音源的正文。付费锁章不跳过——那是有意拦截，必须让用户
      // 看到明确文案。
      final nextSkip = index + skipEmptyDirection;
      if (_current(generation) &&
          skipEmptyDirection != 0 &&
          skipEmptyRemaining > 0 &&
          _isNoAudioError(error) &&
          nextSkip >= 0 &&
          nextSkip < _chapters.length) {
        await candidate?.dispose();
        if (!_current(generation)) return;
        return _openChapter(
          nextSkip,
          autoplay: autoplay,
          skipEmptyDirection: skipEmptyDirection,
          skipEmptyRemaining: skipEmptyRemaining - 1,
          persistCurrent: false,
        );
      }
      if (_current(generation)) {
        _fail(error, generation);
      } else {
        await candidate?.dispose();
      }
    }
  }

  /// 用户点「上一章 / 下一章」时按方向翻章，自动跨过没有音源的前置章节。
  Future<void> _switchChapter(int direction) async {
    if (_closed || direction == 0) return;
    final target = _index + direction;
    if (target < 0 || target >= _chapters.length) return;
    await _openChapter(target, skipEmptyDirection: direction);
  }

  /// 上游“这一章根本没有音源”的确定结果（不是付费锁，也不是网络抖动）。
  static bool _isNoAudioError(Object error) {
    final text = error.toString();
    if (text.contains('LOCK')) return false;
    return text.contains('未获取到音频地址') ||
        text.contains('该章节暂时无法播放');
  }

  /// Fetches one chapter's audio source.
  ///
  /// The backend picks a pooled device per upstream request and the audio
  /// player host sometimes answers a body-level 403 for it, so the network
  /// path retries a few draws before the page reports a failure. An injected
  /// loader is exact and is never multiplied.
  ///
  /// A pure-TTS book has no default voice: the playinfo endpoint answers
  /// NO_THIS_TONE for tone 0, so the first selectable voice is retried once.
  Future<AudioSource> _loadSourceWithRetry(String itemId) async {
    final loader = request.sourceLoader;
    if (loader != null) {
      return loader(
        itemId,
        toneId: _toneId,
      ).timeout(const Duration(seconds: 30));
    }
    final cacheKey = '$itemId|$_toneId';
    final cached = _audioSourceCache[cacheKey];
    if (cached != null) return cached;
    final toneId = _toneId;
    AudioSource result;
    try {
      result = await retryTransient(
        () => ApiClient.instance
            .audioSource(itemId, bookId: _bookId, toneId: toneId)
            .timeout(const Duration(seconds: 30)),
        // A deterministic "this tone does not exist" answer will not change on
        // retry: let it reach the fallback below immediately.
        shouldRetry: (error) =>
            error is! ApiException || !error.message.contains('NO_THIS_TONE'),
      );
    } on ApiException catch (error) {
      if (toneId != '0' ||
          !error.message.contains('NO_THIS_TONE') ||
          !_current(_generation)) {
        final fallback = await _loadLegacySource(itemId, toneId);
        if (fallback == null) rethrow;
        result = fallback;
      } else {
        final selectable = _firstSelectableTone();
        if (selectable == null) rethrow;
        final tone = selectable;
        result = await retryTransient(
          () => ApiClient.instance
              .audioSource(itemId, bookId: _bookId, toneId: tone)
              .timeout(const Duration(seconds: 30)),
        );
      }
    } on FormatException catch (error) {
      // "未获取到音频地址" means playinfo simply had no stream for this item,
      // which the audiobook player may still hold.
      if (!error.message.contains('未获取到音频地址')) rethrow;
      final fallback = await _loadLegacySource(itemId, toneId);
      if (fallback == null) rethrow;
      result = fallback;
    }
    _audioSourceCache[cacheKey] = result;
    while (_audioSourceCache.length > 5) {
      _audioSourceCache.remove(_audioSourceCache.keys.first);
    }
    return result;
  }

  /// Asks the audiobook player (legacy mget bridge) for a stream.
  ///
  /// Only called when the reading-edition playinfo endpoint refuses a chapter
  /// (locked chapters answer `QUERY_CHAPTER_LOCK_ERROR`, front-matter items
  /// have no playinfo stream at all). Failures return null so the original
  /// playinfo error still reaches the UI.
  Future<AudioSource?> _loadLegacySource(String itemId, String toneId) async {
    try {
      return await ApiClient.instance
          .audioPlaySource(itemId, bookId: _bookId, toneId: toneId)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    }
  }

  /// First non-default voice the page knows, for books without a default one.
  String? _firstSelectableTone() {
    for (final tone in _extras.tones.ttsTones) {
      if (tone.id.trim().isNotEmpty) return tone.id;
    }
    for (final tone in _extras.tones.narratorTones) {
      if (tone.id.trim().isNotEmpty) return tone.id;
    }
    for (final voice in _voices) {
      if (voice.id != '0' && voice.id.trim().isNotEmpty) return voice.id;
    }
    return null;
  }

  /// Loads the 边听边读 track for a chapter and publishes it if the chapter is
  /// still the active one.
  Future<void> _refreshSubtitles(
    int generation,
    String itemId,
    String toneId,
  ) async {
    try {
      final track = await _loadSubtitles(itemId, toneId);
      if (!_current(generation)) return;
      _subtitles = track;
      _publishReadAlong();
    } catch (_) {
      // Optional timeline failures must not escape the unawaited request or
      // interrupt playback. The chapter was already reset to an empty track.
    }
  }

  void _publishReadAlong() {
    if (_closed || _index < 0 || _index >= _chapters.length) return;
    final preview = _seekPreview.value;
    _readAlong.value = (
      chapterTitle: _chapters[_index].title,
      track: _subtitles,
      position: preview == null
          ? _position.value
          : Duration(milliseconds: preview.round()),
    );
  }

  void _publishMoreState() {
    if (_closed) return;
    _moreState.value = (
      loading: _loading,
      autoAdvance: _autoAdvance,
      sleepMinutes: _sleepRemaining?.inMinutes,
    );
  }

  static Duration _savedDuration(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) return Duration.zero;
    final milliseconds = value * 1000;
    if (!milliseconds.isFinite || milliseconds >= 0x7fffffffffffffff) {
      return Duration.zero;
    }
    return Duration(milliseconds: milliseconds.round());
  }

  /// Publishes the current narration state so an open reader can follow the
  /// playback (听书跟随翻页).
  void _publishListeningSession({bool playing = true}) {
    if (_index < 0 || _index >= _chapters.length) return;
    final chapter = _chapters[_index];
    final position = _boundedPosition(
      _player?.position ?? _position.value,
      _duration,
    );
    ListeningSession.instance.update(
      bookId: _bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      position: position,
      duration: _duration,
      playing: playing && !_completed,
      // 有声书没有字符坐标，用字幕轨里正在念的那一句让阅读页定位高亮。
      narrationText: _subtitles.cueAt(position)?.text,
    );
  }

  static Duration _boundedPosition(Duration position, Duration duration) {
    if (position < Duration.zero) return Duration.zero;
    return duration > Duration.zero && position > duration
        ? duration
        : position;
  }

  void _subscribe(NativePlayer player, int generation) {
    _subscriptions.addAll([
      player.positionStream.listen((position) {
        if (!_current(generation, player)) return;
        // Notifier-only: the 5Hz tick rebuilds the progress row, not the page.
        _position.value = _boundedPosition(position, _duration);
        _publishReadAlong();
        // Publish the REAL playing state: a paused seek also fires this
        // stream, and publishing playing=true would yank the reader back to
        // the narrated page while paused.
        _publishListeningSession(playing: player.playing);
      }),
      player.durationStream.listen((duration) {
        if (!_current(generation, player) || duration <= Duration.zero) return;
        _update(() {
          _duration = duration;
          _position.value = _boundedPosition(_position.value, duration);
        });
        _publishReadAlong();
        // 总时长是系统媒体卡片两侧时间的来源，一拿到就得同步一次。
        _syncForeground();
      }),
      player.playingStream.listen((playing) {
        if (!_current(generation, player)) return;
        // Creation acknowledges prepare(), and API duration can be known
        // before the CDN is readable. Keep the last successful chapter until
        // this candidate actually starts foreground playback.
        if (playing && !_hasPlayed && _activeIndex == _index && _wantPlay) {
          _hasPlayed = true;
          unawaited(_persistProgress());
        }
        _syncListenClock();
        _syncForeground();
        _publishListeningSession(playing: playing && _wantPlay);
        _update(() {});
      }),
      player.bufferingStream.listen((_) {
        if (!_current(generation, player)) return;
        _syncListenClock();
        _update(() {});
      }),
      player.completedStream.listen((completed) {
        if (!_current(generation, player) ||
            _activeIndex != _index ||
            !completed ||
            _completed) {
          return;
        }
        final shouldAdvance = _wantPlay && _autoAdvance;
        _update(() {
          _completed = true;
          _wantPlay = false;
          _position.value = _boundedPosition(player.position, _duration);
        });
        _publishReadAlong();
        _listenTime.stop();
        _syncForeground();
        unawaited(_persistProgress());
        if (shouldAdvance && _index + 1 < _chapters.length) {
          unawaited(_switchChapter(1));
        } else {
          unawaited(_pause(player, generation));
        }
        // _openChapter resets completion before its source is ready.
        // The next player's playing event will publish the actual start.
        _publishListeningSession(playing: false);
      }),
      player.errorStream.listen((error) => _fail(error, generation)),
    ]);
  }

  void _syncListenClock() {
    final player = _player;
    if (_wantPlay &&
        !_completed &&
        !_loading &&
        _error == null &&
        player != null &&
        player.playing &&
        !player.buffering) {
      _listenTime.start();
      _prefetchNextAudioChapter();
    } else {
      _listenTime.stop();
    }
  }

  Future<void> _persistProgress() {
    final player = _player;
    final index = _activeIndex;
    if (player == null || index == null || !_hasPlayed) {
      return Future<void>.value();
    }
    final duration = player.duration > Duration.zero
        ? player.duration
        : _duration;
    final position = _boundedPosition(player.position, duration);
    final seconds =
        _listenTime.elapsedMicroseconds / Duration.microsecondsPerSecond;
    _listenTime.reset();
    return _history.save({
      'id': _bookId,
      'bookId': _bookId,
      'kind': 'audio',
      'title': _title,
      'cover': _cover,
      'chapterId': _chapters[index].itemId,
      'episodeId': _chapters[index].itemId,
      'episode': index,
      'position': position.inMilliseconds / 1000,
      'duration': duration.inMilliseconds / 1000,
      'maxScroll': duration.inMilliseconds / 1000,
      'progress': duration > Duration.zero
          ? position.inMilliseconds / duration.inMilliseconds
          : 0.0,
      'toneId': _toneId,
      'rate': _rate,
      'autoAdvance': _autoAdvance,
      'inShelf': _inShelf,
      'completed': _completed,
      'time': DateTime.now().millisecondsSinceEpoch,
    }, listenedSeconds: seconds);
  }

  Future<void> _releasePlayer() {
    final player = _player;
    _player = null;
    _activeIndex = null;
    _hasPlayed = false;
    final cancellations = [
      for (final sub in _subscriptions) sub.cancel().catchError((Object _) {}),
    ];
    _subscriptions.clear();
    _releases = _releases.then((_) async {
      await Future.wait(cancellations);
      if (player == null) return;
      try {
        if (player.isCreated) await player.pause();
      } catch (_) {
        // Release still has to run if the platform cannot acknowledge pause.
      }
      try {
        await player.dispose();
      } catch (_) {
        // The Flutter engine may already be shutting down.
      }
    });
    return _releases;
  }

  void _fail(Object error, int generation) {
    if (!_current(generation)) return;
    ListeningSession.instance.clear();
    unawaited(NativePlayer.stopListenForeground());
    ++_generation;
    _saveTimer?.cancel();
    _listenTime.stop();
    unawaited(_persistProgress());
    unawaited(_releasePlayer());
    _update(() {
      _loading = false;
      _wantPlay = false;
      // Signed URLs and backend response bodies must not appear in the UI.
      _error = _audioFailureText(error);
    });
    _publishMoreState();
  }

  /// Turns a source failure into a message that tells the user what actually
  /// happened: a locked chapter and a chapter that ships no audio at all are
  /// both permanent, and "请重试" is misleading for either.
  static String _audioFailureText(Object error) {
    if (error is TimeoutException) return '加载超时，请检查网络后重试。';
    final text = error.toString();
    if (text.contains('LOCK')) return '本章为付费内容，暂不可听。';
    if (text.contains('未获取到音频地址') || text.contains('该章节暂时无法播放')) {
      return '本章暂无音频内容。';
    }
    return '音频暂时无法播放，请重试或切换其他章节。';
  }

  Future<void> _play(NativePlayer player, int generation) async {
    if (!_current(generation, player) || !_wantPlay) return;
    if (!_appActive && !AudioPreferences.instance.backgroundPlayback.value) {
      await _pauseForOtherMedia();
      return;
    }
    await player.play();
    if (!_current(generation, player)) return;
    if (!_wantPlay) await player.pause();
    if (!_current(generation, player)) return;
    _syncListenClock();
    _syncForeground();
    _update(() {});
  }

  Future<void> _pause(NativePlayer player, int generation) async {
    _publishListeningSession(playing: false);
    try {
      await player.pause();
      if (_current(generation, player)) {
        await _persistProgress();
        _syncForeground();
      }
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    if (_wantPlay) {
      _update(() => _wantPlay = false);
      _listenTime.stop();
      await _pause(player, generation);
      _syncForeground();
      return;
    }
    // A replay seek must remain cancellable by backgrounding or pausing.
    _update(() => _wantPlay = true);
    try {
      if (_completed) {
        await player.seek(Duration.zero);
        if (!_current(generation, player)) return;
        _update(() {
          _position.value = Duration.zero;
          _completed = false;
        });
        _publishReadAlong();
      }
      await _play(player, generation);
      if (_current(generation, player)) {
        await _persistProgress();
        _syncForeground();
      }
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _seekTo(Duration position) async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    final seekGeneration = ++_seekGeneration;
    final target = _boundedPosition(position, _duration);
    _seekPreview.value = target.inMilliseconds.toDouble();
    _publishReadAlong();
    try {
      await player.seek(target);
      if (!_current(generation, player) || seekGeneration != _seekGeneration) {
        return;
      }
      _update(() {
        _completed = false;
      });
      _seekPreview.value = null;
      _position.value = target;
      _publishReadAlong();
      await _persistProgress();
      _syncForeground();
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _setRate(double rate) async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    // Carry the selected speed into a chapter opened before this reply.
    _update(() => _rate = rate);
    try {
      await player.setRate(rate);
      if (!_current(generation, player)) return;
      await _persistProgress();
      _syncForeground();
    } catch (error) {
      _fail(error, generation);
    }
  }

  /// Whether a voice can be selected for playback at all.
  ///
  /// A fixed recording needs an exact associated novel before its TTS voices
  /// can be offered. `0` is synthetic; narrator and offline IDs use other paths.
  bool _selectableTone(String toneId) {
    if (_ttsBookId == null) return false;
    final id = toneId.trim();
    if (id.isEmpty || id == '0') return false;
    if (_narratorTones.any((tone) => tone.id == id)) return false;
    if (_extras.tones.offlineTones.any((tone) => tone.id == id)) return false;
    return true;
  }

  /// 真人讲书一栏：每个 narrators 条目其实是另一本书的录音版本。
  List<VoiceOption> _narratorVoiceOptions() => [
    for (final tone in _uniqueTones(_extras.tones.narratorTones))
      VoiceOption(
        id: tone.id,
        title: tone.title,
        description: tone.description,
        badge: tone.badge,
      ),
  ];

  /// 智能朗读一栏：只列 playinfo 真的能播的音色。
  ///
  /// `tts_tones` 列表本身就是可选集合：每个 id 都能单独出流（对 playinfo
  /// 实测过）。另外三类来源绝不能进面板：合成出来的 `0/默认音色`、
  /// 只能走离线下载的 `offline_tts_tones`、以及是 abook_id 的真人讲书。
  List<VoiceOption> _onlineVoiceOptions() {
    final ids = <String>{};
    final options = <VoiceOption>[
      for (final tone in _uniqueTones(_ttsTones))
        if (_selectableTone(tone.id) && ids.add(tone.id))
          VoiceOption(
            id: tone.id,
            title: tone.title,
            description: tone.description,
            badge: tone.badge,
            isMultiTone: tone.isMultiTone,
          ),
    ];
    if (options.isNotEmpty) return options;
    for (final voice in _voices) {
      if (!_selectableTone(voice.id) || !ids.add(voice.id)) continue;
      options.add(VoiceOption(id: voice.id, title: voice.label));
    }
    return options;
  }

  /// 选中一个音色：同书就地换音轨；智能朗读属于原著目录时换到原著版本。
  /// 换版本本身由 [_switchBookVersion] 负责释放旧播放器并重建。
  Future<void> _chooseTone(String toneId) async {
    if (_closed || _switchingVersion) return;
    for (final narrator in _narratorTones) {
      if (narrator.id != toneId) continue;
      if (narrator.id == _bookId) return;
      await _switchBookVersion(
        narrator.id,
        title: narrator.title,
        cover: _cover,
        toneId: '0',
      );
      return;
    }
    if (!_selectableTone(toneId)) return;
    final novel = _extras.tones.relatedNovel;
    if (_ttsBookId != _bookId && novel != null) {
      await _switchBookVersion(
        novel.id,
        title: novel.title.isEmpty ? _title : novel.title,
        cover: novel.cover.isEmpty ? _cover : novel.cover,
        toneId: toneId,
      );
      return;
    }
    if (toneId == _toneId) return;
    await _openChapter(
      _index,
      position: _player?.position ?? _position.value,
      toneId: toneId,
      autoplay: _wantPlay,
      completed: _completed,
    );
  }

  /// TTS plays on the ebook's chapter IDs, even when the panel was opened
  /// from a fixed recording. Never send its tone to the recording's chapters.
  String? get _ttsBookId {
    if (!_extras.tones.hasFixedTone) return _bookId;
    final id = _extras.tones.relatedNovel?.id;
    return id != null && id.isNotEmpty && id != _bookId ? id : null;
  }

  List<AudioTone> get _ttsTones =>
      _ttsBookId == null ? const [] : _extras.tones.ttsTones;

  List<AudioTone> get _narratorTones => _extras.tones.narratorTones;

  /// Current family, derived from the selected tone so the voice card always
  /// describe what is actually playing: `tts` (智能朗读) or `narrator` (真人讲书).
  ///
  /// A fixed recording starts on its narrator. Selecting intelligent reading
  /// opens the associated novel instead of relabeling the current recording.
  String get _mode =>
      _extras.tones.hasFixedTone ||
          _narratorTones.any((tone) => tone.id == _toneId)
      ? 'narrator'
      : 'tts';

  Future<void> _loadExcerpt(String itemId) async {
    final generation = ++_excerptGeneration;
    String? text;
    if (request.excerptLoader != null) {
      try {
        text = await request.excerptLoader!(itemId);
      } catch (_) {
        text = null;
      }
    } else if (!_offline) {
      try {
        final summary = await ApiClient.instance.chapterSummaries(_bookId, [
          itemId,
        ]);
        text = summary.forItem(itemId);
      } catch (_) {
        text = null;
      }
    }
    if (_closed || generation != _excerptGeneration) return;
    _update(() => _excerpt = text?.trim() ?? '');
  }

  bool get _offline =>
      request.sourceLoader != null ||
      request.voicesLoader != null ||
      request.playerFactory != null ||
      request.extrasLoader != null;

  /// 听书条目的归一化模型：本地收藏库同时服务书架页与这一页。
  MediaItem get _shelfItem => MediaItem(
    id: _bookId,
    title: _title,
    cover: _cover,
    author: '',
    badge: '',
    ep: _chapters.isEmpty ? '' : '${_chapters.length}',
    kind: 'audio',
  );

  /// 以 [ShelfStore] 为准；收藏库没起来时（例如纯离线测试环境）退回历史里的
  /// 旧 `inShelf` 字段。
  bool _resolveShelf(Map<String, dynamic>? saved) {
    final store = ShelfStore.instance;
    if (store.isReady) return store.containsItem(_shelfItem);
    return saved?['inShelf'] == true;
  }

  void _applySleepTimer(int? minutes) {
    if (_closed) return;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes == null) {
      _sleepTimerTick?.cancel();
      _update(() => _sleepRemaining = null);
      _publishMoreState();
      return;
    }
    _update(() => _sleepRemaining = Duration(minutes: minutes));
    _publishMoreState();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _sleepTimer = null;
      _sleepTimerTick?.cancel();
      if (_closed) return;
      _update(() {
        _sleepRemaining = null;
        _wantPlay = false;
      });
      _publishMoreState();
      final player = _player;
      if (player != null && player.isCreated) {
        unawaited(_pause(player, _generation));
      }
    });
    _startSleepTicker();
  }

  void _startSleepTicker() {
    _sleepTimerTick?.cancel();
    _sleepTimerTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = _sleepRemaining;
      if (remaining == null || _closed) return;
      final next = remaining - const Duration(seconds: 1);
      _update(() => _sleepRemaining = next > Duration.zero ? next : null);
      _publishMoreState();
      if (next <= Duration.zero) _sleepTimerTick?.cancel();
    });
  }

  /// Stop playback before a route can open another native player. The restored
  /// route stays paused at its own position until the user explicitly plays.
  /// Note: .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md
  Future<_RoutePlayback?> _suspendForRoute(int generation) async {
    await _persistProgress();
    if (!_current(generation)) return null;
    final snapshot = (
      index: _index,
      position: _player?.position ?? _position.value,
      completed: _completed,
      autoplay: _wantPlay,
    );
    _update(() => _wantPlay = false);
    _publishListeningSession(playing: false);
    final suspendedGeneration = ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _listenTime.stop();
    await _releasePlayer();
    return _current(suspendedGeneration) ? snapshot : null;
  }

  Future<void> _restoreAfterRoute(_RoutePlayback? snapshot) async {
    if (_closed || snapshot == null) return;
    await _openChapter(
      snapshot.index,
      position: snapshot.position,
      autoplay: false,
      completed: snapshot.completed,
    );
  }

  Future<void> _switchBookVersion(
    String targetId, {
    required String title,
    required String cover,
    required String toneId,
  }) async {
    if (_closed ||
        _switchingVersion ||
        targetId.isEmpty ||
        targetId == _bookId) {
      return;
    }
    var generation = _generation;
    _update(() => _switchingVersion = true);
    try {
      final chapters = await (request.directoryLoader ?? _defaultDirectory)(
        targetId,
      ).timeout(const Duration(seconds: 20));
      if (!_current(generation)) return;
      if (chapters.isEmpty) throw const FormatException('所选声音版本暂无目录');
      final start = _chapters.isEmpty ? 0 : _narratorChapterIndex(chapters);
      await _persistProgress();
      if (!_current(generation)) return;
      generation = ++_generation;
      ++_seekGeneration;
      _saveTimer?.cancel();
      _listenTime.stop();
      await _releasePlayer();
      if (!_current(generation)) return;
      _update(() {
        _bookId = targetId;
        _title = title;
        _cover = cover;
        _chapters = List<Chapter>.unmodifiable(chapters);
        _index = start;
        _toneId = toneId;
        _extras = const AudioExtras();
        _excerpt = '';
        _error = null;
        _position.value = Duration.zero;
        _duration = Duration.zero;
        _subtitles = SubtitleTrack.empty;
      });
      _settingsReady = _prepareSettings(forceToneId: toneId);
      await _openChapter(
        start,
        restoreHistory: true,
        toneId: toneId,
        autoplay: _wantPlay,
        persistCurrent: false,
      );
    } finally {
      _update(() => _switchingVersion = false);
    }
  }

  /// `/api/directory` answers per volume, and the listening page wants one
  /// flat chapter list.
  Future<List<Chapter>> _defaultDirectory(String bookId) async {
    final volumes = await ApiClient.instance.directoryChapters(
      bookId,
      tab: '听书',
    );
    return [for (final volume in volumes) ...volume];
  }

  /// Index in [chapters] holding the same content as the chapter playing here.
  ///
  /// The two versions number the same text their own way (`第一章合着…` vs
  /// `001 合着…`), so the ordinal prefix is stripped before comparing; a
  /// version whose titles do not line up falls back to the same position.
  int _narratorChapterIndex(List<Chapter> chapters) {
    final want = _chapterCore(_chapters[_index].title);
    if (want.isNotEmpty) {
      for (var i = 0; i < chapters.length; i++) {
        if (_chapterCore(chapters[i].title) == want) return i;
      }
    }
    // Some versions drop the chapter title and only number the installments
    // (`麻衣风水师01` for `第1章 八鬼抬轿`), often with an extra teaser in
    // front (`麻衣风水师00片花`). A positional fallback would land on the
    // teaser there, so match the ordinal number first.
    final ordinal = _chapterOrdinal(_chapters[_index].title);
    if (ordinal != null) {
      for (var i = 0; i < chapters.length; i++) {
        if (_chapterOrdinal(chapters[i].title) == ordinal) return i;
      }
    }
    return _index < chapters.length ? _index : 0;
  }

  /// First number a chapter title carries: `第1章 …`, `001 …` and
  /// `麻衣风水师01` all yield `1`; a title without any number yields `null`.
  static int? _chapterOrdinal(String title) {
    final match = RegExp(r'\d+').firstMatch(title);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// `第一章合着，我是出生头子！？` / `001 合着，我是出生头子！？`
  /// both reduce to `合着，我是出生头子！？`.
  static String _chapterCore(String title) => title
      .trim()
      .replaceFirst(
        RegExp(
          r'^(?:第\s*[0-9零一二三四五六七八九十百千]+\s*[章节集回话]?|\d+)'
          r'\s*[、.，,：:·\-]?\s*',
        ),
        '',
      )
      .trim();

  int? get _sleepMinutes {
    final remaining = _sleepRemaining;
    if (remaining == null) return null;
    final minutes = (remaining.inSeconds / 60).ceil();
    return minutes >= 60 ? 60 : (minutes >= 30 ? 30 : 15);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    ++_seekGeneration;
    ++_settingsGeneration;
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTimerTick?.cancel();
    _listenTime.stop();
    WidgetsBinding.instance.removeObserver(this);
    AudioPreferences.instance.backgroundPlayback.removeListener(
      _preferencesChanged,
    );
    NativePlayer.clearRemoteCommandHandler();
    ListeningSession.instance.clear();
    final saved = _persistProgress().catchError((Object _) {});
    final released = _releasePlayer();
    notifyListeners();
    // The foreground-service stop is best-effort: every other call site
    // fire-and-forgets it, and awaiting the platform reply here would block
    // session teardown forever if the platform never answers (engine
    // shutdown, or a widget test with no channel mock), which in turn
    // stalls the acquire queue waiting on close().
    unawaited(NativePlayer.stopListenForeground());
    await Future.wait([saved, released]);
    // Views/sheets may still be detaching during close; their listenables
    // remain readable until they release this controller for collection.
  }
}
