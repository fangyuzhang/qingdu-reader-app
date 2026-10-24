import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import 'app_log.dart';
import 'api_client.dart';
import 'audio_preferences.dart';
import 'backend_transport.dart';
import 'chapter_cache_store.dart';
import 'chapter_text_formatter.dart';
import 'readable_chapter_resolver.dart';
import 'listening_session.dart';
import 'native_player.dart';

class SystemTtsEngine {
  const SystemTtsEngine(this.package, this.label);
  final String package;
  final String label;
}

class SystemTts {
  static const _channel = MethodChannel('fqapp/system_tts');
  static const _events = EventChannel('fqapp/system_tts_events');
  static final events = _events.receiveBroadcastStream();

  static Future<T?> _call<T>(String method, [Object? arguments]) => _channel
      .invokeMethod<T>(method, arguments)
      .timeout(const Duration(seconds: 20));

  static Future<({List<SystemTtsEngine> engines, String? defaultEngine})>
  engines() async {
    final data = await _call<Map<Object?, Object?>>('engines');
    return (
      engines: [
        for (final item in (data?['engines'] as List? ?? const []))
          if (item is Map)
            SystemTtsEngine(item['package'] as String, item['label'] as String),
      ],
      defaultEngine: data?['defaultEngine'] as String?,
    );
  }

  static Future<int> initialize(SystemTtsPreferences prefs) async =>
      await _call<int>('initialize', {
        'engine': prefs.engine,
        'rate': prefs.rate,
      }) ??
      4000;
  static Future<void> speak(String text, String id) =>
      _call<void>('speak', {'text': text, 'id': id});
  static Future<void> stop() => _call<void>('stop');
  static Future<void> shutdown() => _call<void>('shutdown');
  static Future<void> openSettings() => _call<void>('settings');

  static String errorMessage(Object error) => switch (error) {
    PlatformException(:final message) => message ?? '系统朗读失败，请检查引擎配置',
    MissingPluginException() => '当前平台不支持系统朗读',
    TimeoutException() => '朗读响应超时，请重试或更换引擎',
    StateError(:final message) => message,
    _ => '无法加载正文或朗读引擎，请重试',
  };
}

class SystemTtsPreferences {
  const SystemTtsPreferences({this.engine, this.rate = 1});
  final String? engine;
  final double rate;

  static Future<SystemTtsPreferences> load() async {
    final sp = await SharedPreferences.getInstance();
    final rate = sp.getDouble('system_tts_rate') ?? 1;
    return SystemTtsPreferences(
      engine: sp.getString('system_tts_engine'),
      rate: rate.isFinite ? rate.clamp(0.5, 2) : 1,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    if (engine == null) {
      await sp.remove('system_tts_engine');
    } else {
      await sp.setString('system_tts_engine', engine!);
    }
    await sp.setDouble('system_tts_rate', rate);
  }
}

class SystemTtsLoadedChapter {
  const SystemTtsLoadedChapter({
    required this.index,
    required this.chapter,
    required this.content,
  });

  final int index;
  final Chapter chapter;
  final ChapterContent content;
}

/// All sources are data/store references. No reader State or BuildContext is
/// retained when loading the following chapter after the reader has closed.
class SystemTtsBook {
  SystemTtsBook({
    required this.bookId,
    required this.title,
    required List<Chapter> chapters,
    required this.startIndex,
    required this.initialContent,
    this.cover = '',
    this.startOffset = 0,
    this.localOnly = false,
    this.textLoader,
    this.cache,
  }) : chapters = List.unmodifiable(chapters);

  final String bookId;
  final String title;
  final List<Chapter> chapters;
  final int startIndex;
  final ChapterContent initialContent;
  final String cover;
  final int startOffset;
  final bool localOnly;
  final Future<String> Function(Chapter)? textLoader;
  final ChapterCache? cache;

  Future<SystemTtsLoadedChapter?> load(
    int index, {
    BackendRequest? request,
    int direction = 1,
  }) async {
    final resolver = ReadableChapterResolver(
      chapters: chapters,
      loadText: (chapter) => _loadText(chapter, request: request),
    );
    // An empty initial content is not a loaded chapter: the audiobook page
    // starts system TTS without having the reader's body in memory. Passing
    // its empty cache text as `initialText` makes the resolver treat the
    // chapter as a valid empty page and throw before it ever tries the cache
    // or the network. Only reuse content that actually has blocks.
    final initialText = index == startIndex && !initialContent.isEmpty
        ? initialContent.toCacheText()
        : null;
    final resolved = await resolver.resolve(
      index: index,
      direction: direction,
      initialText: initialText,
    );
    return resolved == null
        ? null
        : SystemTtsLoadedChapter(
            index: resolved.index,
            chapter: resolved.chapter,
            content: resolved.content,
          );
  }

  Future<String> _loadText(Chapter chapter, {BackendRequest? request}) async {
    final loader = textLoader;
    if (localOnly) {
      if (loader == null) throw StateError('本地书籍正文不可用');
      return loader(chapter);
    }
    try {
      final cached = await (cache ?? ChapterCacheStore.instance).read(
        bookId: bookId,
        chapterId: chapter.itemId,
      );
      if (cached != null) {
        final content = ChapterContent.fromCacheText(cached);
        if (!content.isEmpty) return cached;
      }
    } catch (_) {
      // Online novels retain their normal network fallback on a cache miss.
    }
    if (loader != null) {
      return loader(chapter);
    }
    if (request?.isCancelled ?? false) throw BackendRequestAborted('已停止朗读');
    final content = await ApiClient.instance.withCancellation(
      request ?? BackendRequest(),
      () => ApiClient.instance.chapterContent(chapter.itemId, allowEmpty: true),
    );
    return content.toCacheText();
  }

  /// 把正文切成句子区间（保留句末标点，段落换行也算边界）。
  static List<({int start, int end})> splitSentences(String text) {
    const terminators = '。！？!?；;\n';
    final out = <({int start, int end})>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (!terminators.contains(text[i])) continue;
      final end = i + 1;
      if (text.substring(start, end).trim().isNotEmpty) {
        out.add((start: start, end: end));
      }
      start = end;
    }
    if (start < text.length && text.substring(start).trim().isNotEmpty) {
      out.add((start: start, end: text.length));
    }
    return out;
  }

  static String plainText(ChapterContent content, String title) => content
      .withoutLeadingTitle(title)
      .blocks
      .whereType<ChapterParagraph>()
      .map((p) => p.text)
      .join('\n');
}

// Note: .agents/notes/implemented/feature/2026-10-15-system-tts.md
// The scope serializes ownership. Generations cancel deferred loads/play, and
// utterance IDs reject late callbacks after pause, chapter changes or shutdown.
class SystemTtsPlayback extends ChangeNotifier with WidgetsBindingObserver {
  SystemTtsPlayback(this.book, {required this.beforePlay, required this.onStop})
    : index = book.startIndex;

  final SystemTtsBook book;
  final Future<void> Function() beforePlay;
  final VoidCallback onStop;
  int index;
  bool loading = false;
  bool wantPlay = false;
  bool closed = false;
  bool completed = false;
  String? error;
  String _text = '';
  List<({int start, int end})> _sentences = const [];
  int _offset = 0;
  int _pieceStart = 0;
  int _pieceEnd = 0;
  int _generation = 0;
  int _serial = 0;
  int _maxLength = 300;
  String? _id;
  bool _ready = false;
  bool _started = false;
  bool _appActive = true;
  StreamSubscription<dynamic>? _subscription;
  Future<void> _notificationQueue = Future<void>.value();
  Future<void>? _closeFuture;
  BackendRequest? _loadRequest;
  final Completer<void> _startedSignal = Completer<void>();

  /// Completes after the first chapter body is loaded and the first utterance
  /// has been handed to the engine (or the session stopped/failed). Callers
  /// use it to avoid closing the listening page before TTS actually started.
  Future<void> get started => _startedSignal.future;

  Chapter get chapter => book.chapters[index];

  /// 本章正文（段落之间用 '\n' 连接），听书面板按句逐行渲染。
  String get text => _text;

  /// 段落里的分句边界：逗号、顿号、冒号也断开，让高亮跟着读到的地方走，
  /// 而不是一整段亮到这句话念完。
  static const _clauseBreaks = '，,、：:';

  /// 正在朗读的那一句在 [text] 里的区间（按分句收窄）；尚未开始朗读时为
  /// null。阅读页用这个区间染色，所以长句也是一小节一小节地亮。
  ({int start, int end})? get sentenceRange {
    if (_text.isEmpty || _pieceEnd <= _pieceStart) return null;
    if (_pieceEnd > _text.length) return null;
    var start = _offset.clamp(_pieceStart, _pieceEnd);
    if (start >= _pieceEnd) {
      // 已经念到这一句的末尾（引擎的 range 会走到句尾、done 还没回来）：
      // 停在最后一个分句上，而不是把整句重新点亮。
      start = _pieceStart;
      for (var i = _pieceEnd - 1; i >= _pieceStart; i--) {
        if (_clauseBreaks.contains(_text[i])) {
          start = i + 1;
          break;
        }
      }
    }
    var end = _pieceEnd;
    for (var i = start; i < _pieceEnd; i++) {
      if (_clauseBreaks.contains(_text[i])) {
        end = i + 1;
        break;
      }
    }
    if (end <= start) return (start: _pieceStart, end: _pieceEnd);
    return (start: start, end: end);
  }

  String? _clauseText() {
    final range = sentenceRange;
    if (range == null) return null;
    return _text.substring(range.start, range.end).trim();
  }

  /// [text] 按句切分后的区间，用来渲染「上一句 / 当前句 / 下一句」。
  List<({int start, int end})> get sentences => _sentences;

  /// 当前正在朗读的句子下标，没有在朗读时返回 -1。
  int get sentenceIndex {
    if (_pieceEnd <= _pieceStart) return -1;
    for (var i = 0; i < _sentences.length; i++) {
      final s = _sentences[i];
      if (s.start <= _pieceStart && _pieceStart < s.end) return i;
    }
    return -1;
  }
  double get progress =>
      _text.isEmpty ? 0 : (_offset / _text.length).clamp(0, 1);
  bool get _allowed =>
      _appActive || AudioPreferences.instance.backgroundPlayback.value;

  void start() {
    if (_started || closed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    AudioPreferences.instance.backgroundPlayback.addListener(
      _preferencesChanged,
    );
    _subscription = SystemTts.events.listen(
      _event,
      onError: (Object e) {
        if (!closed) unawaited(_fail(e));
      },
    );
    NativePlayer.setRemoteCommandHandler(
      onAction: (action) {
        if (closed) return;
        switch (action) {
          case 'playPause':
            unawaited(toggle());
          case 'prev':
            unawaited(openChapter(index - 1));
          case 'next':
            unawaited(openChapter(index + 1));
          case 'stop':
            onStop();
        }
      },
    );
    unawaited(
      openChapter(index, offset: book.startOffset).whenComplete(() {
        if (!_startedSignal.isCompleted) _startedSignal.complete();
      }),
    );
  }

  Future<void> openChapter(int next, {int offset = 0}) async {
    if (closed || next < 0 || next >= book.chapters.length) return;
    final direction = next >= index ? 1 : -1;
    final token = ++_generation;
    _loadRequest?.cancel();
    final request = _loadRequest = BackendRequest();
    _id = null;
    wantPlay = _allowed;
    loading = true;
    completed = false;
    error = null;
    index = next;
    _text = '';
    _sentences = const [];
    _pieceStart = 0;
    _pieceEnd = 0;
    _offset = offset;
    _publish();
    try {
      await SystemTts.stop();
      if (closed || token != _generation) return;
      final loaded = await book
          .load(next, request: request, direction: direction)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              request.cancel();
              throw TimeoutException('正文加载超时');
            },
          );
      if (closed || token != _generation) return;
      if (loaded == null) {
        completed = true;
        await pause();
        return;
      }
      index = loaded.index;
      _text = SystemTtsBook.plainText(loaded.content, loaded.chapter.title);
      _sentences = SystemTtsBook.splitSentences(_text);
      if (_text.trim().isEmpty) throw StateError('本章没有可朗读的文字');
      _offset = _safeOffset(_offset.clamp(0, _text.length));
      loading = false;
      if (wantPlay) {
        await _begin(token);
      } else {
        _publish();
      }
    } catch (e) {
      if (!closed && token == _generation) await _fail(e);
    } finally {
      if (identical(_loadRequest, request)) _loadRequest = null;
    }
  }

  Future<void> _begin(int token) async {
    await beforePlay();
    if (!_current(token)) return;
    if (!_ready) {
      loading = true;
      _publish();
      final prefs = await SystemTtsPreferences.load();
      if (!_current(token)) return;
      _maxLength = (await SystemTts.initialize(prefs)).clamp(2, 300);
      if (!_current(token)) return;
      _ready = true;
    }
    loading = false;
    await _speak(token);
  }

  bool _current(int token) =>
      !closed && token == _generation && wantPlay && _allowed;

  int _safeOffset(int offset) {
    if (offset > 0 && offset < _text.length) {
      final unit = _text.codeUnitAt(offset);
      if (unit >= 0xdc00 && unit <= 0xdfff) return offset - 1;
    }
    return offset;
  }

  Future<void> _speak(int token) async {
    if (!_current(token)) return;
    if (_offset >= _text.length) {
      if (index + 1 < book.chapters.length) {
        await openChapter(index + 1);
      } else {
        completed = true;
        await pause();
      }
      return;
    }
    _pieceStart = _offset;
    // 每次只把「当前这一句」交给引擎：句子边界取 [_offset] 之后最近的句末
    // 标点。以前是从 offset+300 往回找标点，结果一段话里好几句被当成一次
    // 朗读，阅读页也就一口气高亮一整段。
    var end = _text.length;
    for (final sentence in _sentences) {
      if (sentence.end > _offset) {
        end = sentence.end;
        break;
      }
    }
    end = _safeOffset(end.clamp(_offset, _offset + _maxLength));
    _pieceEnd = end;
    final id = '${identityHashCode(this)}-${++_serial}';
    _id = id;
    _publish();
    // Android 15+ requires foreground eligibility before requesting audio focus.
    await _notificationQueue;
    if (!_current(token) || _id != id) return;
    await SystemTts.speak(_text.substring(_pieceStart, end), id);
  }

  void _event(dynamic value) {
    if (closed || value is! Map) return;
    if (value['type'] == 'interrupted' && value['id'] == null) {
      unawaited(pause());
      return;
    }
    if (_id == null || value['id'] != _id) return;
    switch (value['type']) {
      case 'range':
        final start = value['start'];
        if (start is int && start >= 0 && start < _pieceEnd - _pieceStart) {
          _offset = _safeOffset(_pieceStart + start);
          _publish(notification: false);
        }
      case 'done':
        _id = null;
        _offset = _pieceEnd;
        final token = _generation;
        unawaited(
          _speak(token).catchError((Object e) async {
            if (!closed && token == _generation) await _fail(e);
          }),
        );
      case 'error':
        unawaited(_fail(StateError('引擎朗读失败，请检查音色或网络后重试')));
      case 'interrupted':
        unawaited(pause());
    }
  }

  /// 从 [text] 的某个字符位置接着念（听书面板「从本句听」）。
  Future<void> speakFrom(int offset) async {
    if (closed || _text.isEmpty) return;
    _offset = _safeOffset(offset.clamp(0, _text.length));
    completed = false;
    error = null;
    final token = ++_generation;
    wantPlay = true;
    _publish();
    try {
      await _begin(token);
    } catch (e) {
      if (!closed && token == _generation) await _fail(e);
    }
  }

  Future<void> toggle() => wantPlay ? pause() : resume();

  Future<void> resume() async {
    if (closed || wantPlay || !_allowed) return;
    if (_text.isEmpty) {
      await openChapter(index, offset: _offset);
      return;
    }
    final token = ++_generation;
    wantPlay = true;
    error = null;
    if (completed) {
      _offset = 0;
      completed = false;
    }
    try {
      await _begin(token);
    } catch (e) {
      if (!closed && token == _generation) await _fail(e);
    }
  }

  Future<void> pause() async {
    if (closed) return;
    ++_generation;
    _loadRequest?.cancel();
    _id = null;
    wantPlay = false;
    loading = false;
    _publish();
    try {
      await SystemTts.stop();
    } catch (error) {
      AppLog.w('听书', '停止系统朗读失败', error: error);
    }
  }

  Future<void> _fail(Object e) async {
    if (closed) return;
    error = SystemTts.errorMessage(e);
    _ready = false;
    await pause();
  }

  void _publish({bool notification = true}) {
    if (closed) return;
    ListeningSession.instance.update(
      bookId: book.bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      position: Duration.zero,
      duration: Duration.zero,
      playing: wantPlay && !loading && error == null,
      textProgress: progress,
      // 高亮跟着读到的那一小节走（见 sentenceRange 的分句收窄）。
      sentenceRange: sentenceRange,
      // 同时带上这一小节的原文：阅读页拿它在排版里就近定位，字符偏移
      // 与排版块一旦对不齐也不会把整段都染色。
      narrationText: _clauseText(),
    );
    notifyListeners();
    if (notification) {
      _notificationQueue = _notificationQueue.then((_) async {
        if (closed) return;
        if (!AudioPreferences.instance.backgroundPlayback.value) {
          await NativePlayer.stopListenForeground();
        } else {
          await NativePlayer.startListenForeground(
            title: book.title,
            episode: '系统朗读 · ${chapter.title}',
            playing: wantPlay && !loading && error == null,
            hasPrev: index > 0,
            hasNext: index + 1 < book.chapters.length,
          );
        }
      });
    }
  }

  void _preferencesChanged() {
    if (closed) return;
    if (!_allowed) {
      unawaited(pause());
    } else {
      _publish();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_allowed) unawaited(pause());
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closed = true;
    if (!_startedSignal.isCompleted) _startedSignal.complete();
    ++_generation;
    _loadRequest?.cancel();
    _id = null;
    wantPlay = false;
    WidgetsBinding.instance.removeObserver(this);
    AudioPreferences.instance.backgroundPlayback.removeListener(
      _preferencesChanged,
    );
    NativePlayer.clearRemoteCommandHandler();
    ListeningSession.instance.clear();
    notifyListeners();
    // Do not await the EventChannel cancel: awaiting a platform-stream
    // subscription cancel stalls every later await in this zone (widget
    // tests hang in shutdown below), so fire it and forget it. Late events
    // are already ignored because `closed` is set above.
    unawaited(_subscription?.cancel());
    _subscription = null;
    try {
      await SystemTts.shutdown();
    } catch (error) {
      AppLog.w('听书', '关闭系统朗读引擎失败', error: error);
    }
    await _notificationQueue;
    await NativePlayer.stopListenForeground();
    dispose();
  }
}
