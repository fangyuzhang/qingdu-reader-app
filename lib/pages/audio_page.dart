import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/audio_extra.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/app_log.dart';
import '../services/audio_history.dart';
import '../services/audio_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_text_formatter.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/shelf_store.dart';
import '../services/transient_retry.dart';
import '../services/system_tts.dart';
import '../widgets/audio/audio_sections.dart';
import '../widgets/audio/listening_capsule.dart';
import '../widgets/audio/voice_settings_sheet.dart';
import '../widgets/audio/system_tts_controls.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/comment_images.dart';
import '../widgets/home/home_design.dart';
import 'detail_page.dart';
import 'home_page.dart';
import 'reader_page.dart';
import 'system_tts_settings_page.dart';

part '../services/audio_playback_controller.dart';
part '../widgets/audio/audio_playback_scope.dart';

/// Foreground listening using the existing Android Media3 URL player.
class AudioPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;

  /// Where playback starts inside [startIndex]. 从本段听 sets this to the pressed
  /// paragraph's place on the chapter's spoken timeline. Null means resume from
  /// history, else the chapter opening.
  final Duration? startPosition;
  final String? initialToneId;
  final double? initialRate;
  final bool autoplay;

  /// Reopening the current work keeps its live session. A chapter/paragraph
  /// request can opt out to seek deliberately instead.
  final bool resumeSession;
  final ReaderStore? historyStore;
  final NativePlayer Function()? playerFactory;
  final Future<AudioSource> Function(String itemId, {String? toneId})?
  sourceLoader;
  final Future<List<AudioVoice>> Function()? voicesLoader;

  /// 智能朗读 voices, companion works and the summary shown around the player.
  final AudioExtrasLoader? extrasLoader;

  /// 边听边读 subtitles for one chapter. Resolved with the selected tone id,
  /// because the backend only answers for a real tone.
  final SubtitleLoader? subtitleLoader;

  /// Current-chapter opening excerpt shown under the cover, mirroring the
  /// official listening page. Defaults to `/chapters/summary`.
  final Future<String?> Function(String itemId)? excerptLoader;

  /// Directory of another recording or the associated TTS novel. A version
  /// switch uses that book's own chapter IDs. Defaults to the listening API.
  final Future<List<Chapter>> Function(String bookId)? directoryLoader;

  const AudioPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    this.startIndex = 0,
    this.startPosition,
    this.initialToneId,
    this.initialRate,
    this.autoplay = true,
    this.resumeSession = true,
    this.cover = '',
    this.historyStore,
    this.playerFactory,
    this.sourceLoader,
    this.voicesLoader,
    this.extrasLoader,
    this.subtitleLoader,
    this.excerptLoader,
    this.directoryLoader,
  });

  @override
  State<AudioPage> createState() => _AudioPageState();
}

/// Optional listening-page decorations. A caller that already injects its own
/// source, voice or player stubs is offline by construction, so the page does
/// not reach for the network behind its back.
///
/// Note: 听书页版式复刻、字幕与音色的实测契约 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
class AudioExtras {
  const AudioExtras({
    this.tones = const AudioToneSet(),
    this.related = const [],
    this.detail,
  });

  final AudioToneSet tones;
  final List<RelatedWork> related;
  final BookDetail? detail;
}

typedef AudioExtrasLoader = Future<AudioExtras> Function(String bookId);
typedef SubtitleLoader =
    Future<SubtitleTrack> Function(String itemId, String toneId);

typedef _ReadAlongSnapshot = ({
  String chapterTitle,
  SubtitleTrack track,
  Duration position,
});

typedef _MoreSnapshot = ({bool loading, bool autoAdvance, int? sleepMinutes});

typedef _RoutePlayback = ({
  int index,
  Duration position,
  bool completed,
  bool autoplay,
});

Future<AudioExtras> _defaultAudioExtras(String bookId) async {
  final tones = await ApiClient.instance
      .bookTones(bookId)
      .catchError((Object _) => const AudioToneSet());
  final related = await ApiClient.instance
      .relatedWorks(bookId)
      .catchError((Object _) => const <RelatedWork>[]);
  final detail = await ApiClient.instance
      .bookDetail(bookId)
      .catchError((Object _) => const BookDetail());
  return AudioExtras(tones: tones, related: related, detail: detail);
}

/// 迷你胶囊的「听书设置」入口：定时关闭 / 语速 / 音色。
///
/// 三个面板由听书页与悬浮胶囊共用同一份实现，两处看到的选项永远一致。
Future<void> _showListeningSettings(
  BuildContext context,
  _AudioPlaybackController session,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: HomePalette.of(context).canvas,
    builder: (context) {
      final palette = HomePalette.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '听书设置',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                LucideIcons.alarm_clock,
                size: 20,
                color: palette.muted,
              ),
              title: const Text('定时关闭'),
              trailing: Text(
                session._sleepMinutes == null
                    ? '未开启'
                    : '${session._sleepMinutes} 分钟',
                style: TextStyle(color: palette.muted, fontSize: 13),
              ),
              onTap: () => Navigator.pop(context, 'sleep'),
            ),
            ListTile(
              leading: Icon(LucideIcons.gauge, size: 20, color: palette.muted),
              title: const Text('语速'),
              trailing: Text(
                '${formatPlaybackRate(session._rate)}×',
                style: TextStyle(color: palette.muted, fontSize: 13),
              ),
              onTap: () => Navigator.pop(context, 'rate'),
            ),
            ListTile(
              leading: Icon(LucideIcons.mic, size: 20, color: palette.muted),
              title: const Text('音色'),
              trailing: Text(
                _currentToneLabel(session),
                style: TextStyle(color: palette.muted, fontSize: 13),
              ),
              onTap: () => Navigator.pop(context, 'voice'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      );
    },
  );
  if (!context.mounted) return;
  switch (action) {
    case 'sleep':
      await _showSleepTimerSheet(context, session);
    case 'rate':
      await _showRateSheet(context, session);
    case 'voice':
      await _showVoiceSheet(context, session);
  }
}

List<AudioTone> _selectableTones(_AudioPlaybackController c) =>
    c._mode == 'narrator' ? c._narratorTones : c._ttsTones;

String _currentToneLabel(_AudioPlaybackController c) {
  for (final tone in [...c._narratorTones, ...c._ttsTones]) {
    if (tone.id == c._toneId && tone.title.trim().isNotEmpty) {
      return tone.title;
    }
  }
  if (c._mode == 'narrator' && c._narratorTones.length == 1) {
    return c._narratorTones.single.title;
  }
  if (c._mode == 'tts' && c._ttsTones.length == 1) {
    return c._ttsTones.single.title;
  }
  return c._mode == 'narrator' ? '真人讲书' : '智能朗读';
}

Future<void> _showRateSheet(
  BuildContext context,
  _AudioPlaybackController session,
) async {
  final palette = HomePalette.of(context);
  final rate = await showModalBottomSheet<double>(
    context: context,
    showDragHandle: true,
    backgroundColor: palette.canvas,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('播放速度')),
          for (final rate in _AudioPlaybackController._rates)
            ListTile(
              title: Text('${formatPlaybackRate(rate)}×'),
              trailing: rate == session._rate
                  ? Icon(LucideIcons.check, color: palette.accentText, size: 20)
                  : null,
              onTap: () => Navigator.pop(context, rate),
            ),
        ],
      ),
    ),
  );
  if (rate != null) await session._setRate(rate);
}

/// 定时关闭：暂停播放，倒计时到点自动停。
Future<void> _showSleepTimerSheet(
  BuildContext context,
  _AudioPlaybackController session,
) async {
  const options = <int>[-1, 15, 30, 60];
  final selected = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    backgroundColor: HomePalette.of(context).canvas,
    builder: (context) {
      final palette = HomePalette.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('定时关闭')),
            for (final minutes in options)
              ListTile(
                title: Text(minutes == -1 ? '关闭定时' : '$minutes 分钟后'),
                trailing: (session._sleepMinutes ?? -1) == minutes
                    ? Icon(
                        LucideIcons.check,
                        color: palette.accentText,
                        size: 20,
                      )
                    : null,
                onTap: () => Navigator.pop(context, minutes),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (selected == null || !context.mounted) return;
  session._applySleepTimer(selected == -1 ? null : selected);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(selected == -1 ? '已关闭定时' : '将在 $selected 分钟后停止播放'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 换音色可能要把整本书换成另一条录音/原著，失败时不能静默：面板已经关掉
/// 了，用户至少要有一次明确的「没换成」的反馈。
Future<void> _chooseToneGuarded(
  BuildContext context,
  _AudioPlaybackController session,
  String toneId,
) async {
  try {
    await session._chooseTone(toneId);
  } catch (_) {
    if (session._closed || !context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('暂时无法切换声音，请稍后重试')));
  }
}

Future<void> _showVoiceSheet(
  BuildContext context,
  _AudioPlaybackController session,
) async {
  if (session._switchingVersion) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * 0.72,
      child: VoiceSettingsSheet(
        selectedId: session._extras.tones.hasFixedTone
            ? session._bookId
            : session._toneId,
        narrators: session._narratorVoiceOptions(),
        online: session._onlineVoiceOptions(),
        onSelect: (option) {
          Navigator.pop(sheetContext);
          unawaited(_chooseToneGuarded(context, session, option.id));
        },
      ),
    ),
  );
}

class _AudioPageState extends State<AudioPage> {
  _AudioPlaybackController? _session;
  _AudioPlaybackScopeState? _owner;
  bool _attaching = false;
  bool _attachFailed = false;
  bool _routeCurrent = true;
  Route<dynamic>? _route;

  /// 用户点上一章/下一章（或目录跳章）后，若目标章节因付费锁或没有音源
  /// 无法播放，自动转接到系统朗读，避免停在“重试 / 切换其他章节”的死页。
  /// 只在用户主动切章时启用；首次打开听书页仍让用户看到原始状态与按钮。
  bool _autoTtsPending = false;
  int? _autoTtsChapter;
  _AudioPlaybackController get c => _session!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route = route;
      AudioRouteWatcher.instance
        ..removeListener(_onRouteStackChanged)
        ..addListener(_onRouteStackChanged);
    }
    _routeCurrent = _computeRouteCurrent();
    if (!_attaching) {
      _attaching = true;
      _owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
      unawaited(_attach());
    }
    _owner?.viewChanged(this);
  }

  /// 只把「被另一个页面路由盖住」当成离开，弹窗/菜单/底部面板不算，
  /// 否则听书页一开弹层，迷你胶囊就会冒出来盖住播放控件。
  bool _computeRouteCurrent() {
    final route = _route;
    if (route == null) return true;
    final watcher = AudioRouteWatcher.instance;
    if (watcher.tracksRoutes) return watcher.isTopPage(route);
    return ModalRoute.isCurrentOf(context) ?? true;
  }

  void _onRouteStackChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = _computeRouteCurrent();
      _owner?.viewChanged(this);
      if (next != _routeCurrent) setState(() => _routeCurrent = next);
    });
  }

  Future<void> _attach() async {
    await Future<void>.value();
    if (!mounted) return;
    final owner = _owner;
    _AudioPlaybackController? session;
    try {
      session = owner == null
          ? _AudioPlaybackController(widget)
          : await owner.acquire(widget);
    } catch (_) {
      if (mounted) setState(() => _attachFailed = true);
      return;
    }
    if (session == null) return;
    if (!mounted) {
      if (owner == null) await session.close();
      return;
    }
    _session = session;
    session.addListener(_changed);
    if (owner == null) session.start();
    owner?.viewChanged(this);
    setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final session = _session;
    if (session == null) return;
    if (session._error == null && !session._loading) {
      _autoTtsChapter = null;
      _autoTtsPending = false;
    }
    if (!_autoTtsPending || session._loading) return;
    final message = session._error;
    if (message == null) return;
    final permanent = message.contains('付费') || message.contains('暂无音频');
    if (!permanent) {
      _autoTtsPending = false;
      return;
    }
    if (_autoTtsChapter == session._index) return;
    _autoTtsPending = false;
    _autoTtsChapter = session._index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final latest = _session;
      if (latest == null || latest._error == null) return;
      unawaited(_listenWithSystemTts());
    });
  }

  /// 用户主动切章：撞上无法播放的章节时自动交给系统朗读，而不是让用户
  /// 自己从错误提示里再点一次。
  void _switchChapter(int direction) {
    final session = _session;
    if (session == null) return;
    _autoTtsPending = true;
    unawaited(session._switchChapter(direction));
  }

  void _openChapterFromCatalog(int index) {
    final session = _session;
    if (session == null) return;
    _autoTtsPending = true;
    unawaited(session._openChapter(index));
  }

  /// 会话被关闭（例如系统通知栏里点了「停止」）后，听书页已经没有内容可
  /// 展示。直接回到上一层（详情页 / 阅读页）；若听书页就是栈底，则用首页
  /// 替换它。永远不再渲染「本次播放已关闭」的整页黑屏。
  bool _leavingClosed = false;

  void _leaveClosedSession() {
    if (_leavingClosed || !mounted) return;
    _leavingClosed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final route = ModalRoute.of(context);
      // 被其它页面（例如「边听边读」打开的阅读页）盖住时，不能 pop 栈顶，
      // 否则会关掉上面那一页；只把自己从栈里移除。
      if (route != null && !route.isCurrent) {
        navigator.removeRoute(route);
        return;
      }
      if (navigator.canPop()) {
        navigator.maybePop();
        return;
      }
      navigator.pushReplacement<void, void>(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    });
  }

  @override
  void dispose() {
    final session = _session;
    session?.removeListener(_changed);
    if (session != null && !session._closed) {
      unawaited(session._persistProgress());
    }
    AudioRouteWatcher.instance.removeListener(_onRouteStackChanged);
    _owner?.removeView(this);
    if (_owner == null && session != null) unawaited(session.close());
    super.dispose();
  }

  Future<void> _showRates() => _showRateSheet(context, c);

  Future<void> _showVoices() => _showVoiceSheet(context, c);

  Future<void> _showCatalog() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _AudioCatalog(chapters: c._chapters, currentIndex: c._index),
    );
    if (!mounted || selected == null || selected == c._index) return;
    _openChapterFromCatalog(selected);
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('听书')),
        body: Center(
          child: _attachFailed
              ? TextButton(
                  onPressed: () {
                    setState(() => _attachFailed = false);
                    unawaited(_attach());
                  },
                  child: const Text('打开失败，点击重试'),
                )
              : const Text('正在打开听书…'),
        ),
      );
    }
    final palette = HomePalette.of(context);
    if (c._closed) {
      // 先退场再让页面消失：build 里不能直接 pop，用 post-frame 调度一次。
      _leaveClosedSession();
      return Scaffold(
        backgroundColor: palette.canvas,
        body: const SizedBox.shrink(),
      );
    }
    if (c._chapters.isEmpty) {
      return Scaffold(
        key: ValueKey('audio_session_${c._bookId}'),
        backgroundColor: palette.canvas,
        appBar: AppBar(
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
          title: const Text('听书'),
        ),
        body: Center(
          child: Text('暂无可播放章节', style: TextStyle(color: palette.muted)),
        ),
      );
    }
    final chapter = c._chapters[c._index];
    return Scaffold(
      key: ValueKey('audio_session_${c._bookId}'),
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
              child: AudioNowPlayingHeader(
                cover: c._cover,
                bookTitle: c._title,
                chapterTitle: chapter.title,
                subtitle: '第 ${c._index + 1} / ${c._chapters.length} 章',
                onOpenCatalog: () => unawaited(_showCatalog()),
                onOpenReader: () => unawaited(_openReaderFromAudio()),
              ),
            ),
            // 正文区吃掉剩余高度：字号、句子长短、章节标题都不会再让下方的
            // 播放控件上下挪动。
            Expanded(
              child: AudioNarrationBody(
                track: c._subtitles,
                excerpt: c._excerpt,
                position: c._position,
                onListenFrom: (at) => unawaited(_listenFromCue(at)),
                onOpenReader: () => unawaited(_openReaderFromAudio()),
              ),
            ),
            ValueListenableBuilder<Duration>(
              valueListenable: c._position,
              builder: (context, position, _) {
                final pages = _pageEstimate(position);
                return AudioListenFooter(
                  pageLabel: '第 ${pages.$1} / ${pages.$2} 页',
                  bookProgress: _bookProgress(position),
                );
              },
            ),
            SizedBox(
              height: 50,
              child: Center(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _statusLine(palette),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AudioActionRow(actions: _actions),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ValueListenableBuilder<Duration>(
                valueListenable: c._position,
                builder: (context, position, _) =>
                    ValueListenableBuilder<double?>(
                      valueListenable: c._seekPreview,
                      builder: (context, seekPreview, _) => AudioProgressRow(
                        position: position,
                        duration: c._duration,
                        preview: seekPreview,
                        enabled: c._ready,
                        onChanged: (value) => c._seekPreview.value = value,
                        onChangeEnd: (value) =>
                            c._seekTo(Duration(milliseconds: value.round())),
                        onBack15: c._ready
                            ? () => c._seekTo(
                                c._position.value - const Duration(seconds: 15),
                              )
                            : null,
                        onForward15: c._ready
                            ? () => c._seekTo(
                                c._position.value + const Duration(seconds: 15),
                              )
                            : null,
                      ),
                    ),
              ),
            ),
            _transport(),
            const SizedBox(height: 6),
            AudioToneBar(
              title: c._mode == 'narrator' ? '真人讲书' : '智能朗读',
              toneLabel: _selectableTones(c).isEmpty
                  ? '暂无可选音色'
                  : _currentToneLabel(c),
              onTones: c._switchingVersion ? null : _showVoices,
              onReadAlong: _showReadAlong,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 双击正文区或点「进入正文」：直接打开阅读页，停在本章当前位置。
  ///
  /// 智能朗读读的就是这本书的正文，直接进本作阅读页；真人讲书读的是另一条
  /// 音轨，正文在同名原著的目录里，按章节名对上再进；两者都不成立时退回
  /// 原来的边听边读字幕面板，双击至少不会是一次没有反馈的空操作。
  Future<void> _openReaderFromAudio() async {
    if (c._closed || c._chapters.isEmpty) return;
    if (c._mode == 'tts' && c._ttsBookId == c._bookId && !c._offline) {
      await _pushReader(c._bookId, c._title, c._cover, c._chapters, c._index);
      return;
    }
    final novel = c._extras.tones.relatedNovel;
    if (novel != null && novel.id.isNotEmpty) {
      try {
        final loader = widget.directoryLoader ?? c._defaultDirectory;
        final chapters = await loader(
          novel.id,
        ).timeout(const Duration(seconds: 20));
        if (!mounted) return;
        if (chapters.isNotEmpty) {
          await _pushReader(
            novel.id,
            novel.title.isEmpty ? c._title : novel.title,
            novel.cover.isEmpty ? c._cover : novel.cover,
            chapters,
            c._narratorChapterIndex(chapters),
          );
          return;
        }
      } catch (_) {
        // 目录取不到就退回字幕面板。
      }
      if (!mounted) return;
    }
    await _showReadAlong();
  }

  /// 「从本句听」：跳到该句的时间点并开始播放。
  Future<void> _listenFromCue(Duration at) async {
    if (c._closed) return;
    await c._seekTo(at);
    if (!c._closed && !c._wantPlay) await c._togglePlayback();
  }

  /// 上游没有给出本章音频（付费锁定或本来就无音频）时，用手机自带的 TTS
  /// 接着读同一章正文，听书不中断；播报由「系统朗读」会话接管，胶囊保留。
  Future<void> _listenWithSystemTts() async {
    if (c._closed || c._chapters.isEmpty) return;
    final book = SystemTtsBook(
      bookId: c._bookId,
      title: c._title,
      chapters: c._chapters,
      startIndex: c._index,
      initialContent: ChapterContent(blocks: const []),
      cover: c._cover,
    );
    try {
      await AudioPlaybackScope.startSystemTts(context, book);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(SystemTts.errorMessage(error))));
      }
      return;
    }
    if (!mounted) return;
    final chapters = c._chapters;
    if (chapters.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    // 系统朗读接管后，原来的听书页已经没有可播放的音频，留在那里只剩报错
    // 文案。直接把用户带到正文页：朗读句高亮、胶囊控件都在正文里，听书中途
    // 不会掉回详情页。
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: c._bookId,
          title: c._title,
          cover: c._cover,
          chapters: chapters,
          startIndex: c._index.clamp(0, chapters.length - 1),
        ),
      ),
    );
  }

  /// 全书进度：章序号 + 本章播放进度，按章数加权。
  double _bookProgress(Duration position) {
    final chapters = c._chapters.length;
    if (chapters == 0) return 0;
    final ms = c._duration.inMilliseconds;
    final within = ms > 0
        ? (position.inMilliseconds / ms).clamp(0.0, 1.0)
        : 0.0;
    return ((c._index + within) / chapters).clamp(0.0, 1.0);
  }

  /// 阅读页数估算：按本章字幕字数折算每章页数，再按章数铺成全书页数。
  ///
  /// 听书页没有正文排版，拿不到真实分页，这里只求「同一进度永远是同一页」
  /// 并且随朗读单调前进。
  (int, int) _pageEstimate(Duration position) {
    var chars = 0;
    for (final cue in c._subtitles.cues) {
      chars += cue.text.length;
    }
    final perChapter = math.max(1, (chars / 560).round());
    final total = math.max(1, perChapter * math.max(1, c._chapters.length));
    final page = (_bookProgress(position) * total).round().clamp(1, total);
    return (page.toInt(), total.toInt());
  }

  Future<void> _pushReader(
    String bookId,
    String title,
    String cover,
    List<Chapter> chapters,
    int startIndex,
  ) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: bookId,
          title: title,
          cover: cover,
          chapters: chapters,
          startIndex: startIndex.clamp(0, chapters.length - 1),
        ),
      ),
    );
  }

  /// TTS shares stable chapter IDs with the novel. Fixed recordings retain
  /// their subtitle view; their chapter numbers cannot map a different book.
  Future<void> _showReadAlong() async {
    if (c._closed || c._chapters.isEmpty) return;
    if (c._mode == 'tts' && c._ttsBookId == c._bookId && !c._offline) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            bookId: c._bookId,
            title: c._title,
            cover: c._cover,
            chapters: c._chapters,
            startIndex: c._index,
          ),
        ),
      );
      return;
    }
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ValueListenableBuilder<_ReadAlongSnapshot>(
        valueListenable: c._readAlong,
        builder: (context, snapshot, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.chapterTitle,
                    key: const ValueKey('audio-read-along-chapter'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.ink, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: snapshot.track.isEmpty
                        ? Center(
                            child: Text(
                              '本章暂无同步字幕',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            child: AudioSubtitleView(
                              track: snapshot.track,
                              position: snapshot.position,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Icon row: 语速 / 加入书架 / 下载 / 章评 / 更多.
  List<AudioAction> get _actions => [
    AudioAction(
      key: 'audio-speed',
      icon: LucideIcons.gauge,
      label: '语速',
      onTap: c._ready ? _showRates : null,
    ),
    AudioAction(
      key: 'audio_shelf',
      icon: LucideIcons.book_plus,
      label: c._inShelf ? '已在书架' : '加入书架',
      active: c._inShelf,
      onTap: _toggleShelf,
    ),
    AudioAction(
      key: 'audio_download',
      icon: LucideIcons.download,
      label: '下载',
      onTap: _showDownload,
    ),
    AudioAction(
      key: 'audio_chapter_comment',
      icon: LucideIcons.message_circle,
      // The official listening page labels this 章评 (chapter-end discussion).
      // The closest sheet we have today shows the work's book reviews; the
      // reader keeps the real chapter/paragraph ideas.
      label: '章评',
      onTap: _showBookReviews,
    ),
    AudioAction(
      key: 'audio_more',
      icon: LucideIcons.ellipsis,
      label: '更多',
      onTap: _showMore,
    ),
  ];

  /// 目录 / 上一章 / 播放暂停 / 下一章 / 定时.
  Widget _transport() {
    final palette = HomePalette.of(context);
    final playing = c._wantPlay && !c._completed;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _TransportButton(
          icon: LucideIcons.list,
          tooltip: '目录',
          onTap: _showCatalog,
        ),
        _TransportButton(
          icon: LucideIcons.skip_back,
          tooltip: '上一章',
          onTap: c._index > 0 ? () => _switchChapter(-1) : null,
        ),
        Semantics(
          button: true,
          child: IconButton(
            tooltip: playing ? '暂停' : '播放',
            onPressed: c._ready ? c._togglePlayback : null,
            padding: const EdgeInsets.all(11),
            iconSize: 38,
            style: IconButton.styleFrom(
              foregroundColor: palette.ink,
              disabledForegroundColor: palette.muted.withValues(alpha: 0.5),
            ),
            icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
          ),
        ),
        _TransportButton(
          icon: LucideIcons.skip_forward,
          tooltip: '下一章',
          onTap: c._index + 1 < c._chapters.length
              ? () => _switchChapter(1)
              : null,
        ),
        _TransportButton(
          icon: LucideIcons.alarm_clock,
          tooltip: '定时',
          active: c._sleepRemaining != null,
          onTap: _showSleepTimer,
        ),
      ],
    );
  }

  Widget _statusLine(HomePalette palette) {
    if (c._error case final message?) {
      // 付费锁定 / 本来无音频是确定结果，重试没有意义；给出「系统朗读」
      // 让用户能接着听本章，而不是困在错误提示里。
      final permanent = message.contains('付费') || message.contains('暂无音频');
      // 状态区是固定高度：错误文案与重试按钮并排，避免撑出边界压到
      // 下方的操作行。
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.muted, fontSize: 12.5),
            ),
          ),
          if (permanent) ...[
            const SizedBox(width: 4),
            TextButton.icon(
              key: const ValueKey('audio-use-system-tts'),
              onPressed: () => unawaited(_listenWithSystemTts()),
              style: TextButton.styleFrom(
                foregroundColor: HomePalette.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(LucideIcons.audio_lines, size: 15),
              label: const Text('系统朗读', style: TextStyle(fontSize: 12.5)),
            ),
          ],
          const SizedBox(width: 4),
          TextButton.icon(
            key: const ValueKey('audio-retry'),
            onPressed: () => c._openChapter(c._index, restoreHistory: true),
            style: TextButton.styleFrom(
              foregroundColor: HomePalette.accent,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: const Icon(LucideIcons.refresh_cw, size: 15),
            label: const Text('重试', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      );
    }
    if (c._loading || (c._player?.buffering ?? false)) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            c._loading ? '正在加载音频…' : '缓冲中…',
            style: TextStyle(color: palette.muted, fontSize: 12.5),
          ),
        ],
      );
    }
    return Text(
      c._completed ? '本章已播完' : (c._wantPlay ? '正在播放' : '已暂停'),
      textAlign: TextAlign.center,
      style: TextStyle(color: palette.muted, fontSize: 12.5),
    );
  }

  Future<void> _toggleShelf() async {
    if (c._closed) return;
    final store = ShelfStore.instance;
    final next = store.isReady ? await store.toggle(c._shelfItem) : !c._inShelf;
    if (!mounted || c._closed) return;
    c._update(() => c._inShelf = next);
    // The shelf flag is independent of playback, so it is written even when
    // nothing has been played yet in this session. The history copy stays as
    // the legacy mirror of the flag.
    try {
      final existing =
          await c._history.load(c._bookId) ?? const <String, dynamic>{};
      await c._history.save({
        ...existing,
        'id': c._bookId,
        'bookId': c._bookId,
        'kind': 'audio',
        'title': c._title,
        'cover': c._cover,
        'inShelf': next,
      });
    } on Exception {
      // A storage failure must not desync the visible toggle.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next ? '已加入书架' : '已移出书架'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Caches the book's chapters for offline listening/reading.
  Future<void> _showDownload() async {
    final cache = ChapterCacheStore.instance;
    final book = CachedBook(
      id: c._bookId,
      title: c._title,
      cover: c._cover,
      chapters: c._chapters,
    );
    try {
      await cache.saveBook(book);
    } on Exception {
      // A cache index failure must not block the sheet.
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => ChapterCacheSheet(
        book: book,
        currentIndex: c._index,
        cache: cache,
        loader: (chapter) => ApiClient.instance.contentText(chapter.itemId),
      ),
    );
  }

  /// Book reviews for the work being listened to.
  ///
  /// Named for what it shows rather than the official page's 章评 label: the
  /// backend has no chapter-comment endpoint (see the 书评 action above).
  Future<void> _showBookReviews() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _AudioCommentsSheet(
        bookId: c._bookId,
        loader: widget.sourceLoader != null || widget.playerFactory != null
            ? null
            : ApiClient.instance.bookComments,
      ),
    );
  }

  /// Sleep timer: pauses playback when the countdown elapses.
  Future<void> _showSleepTimer() => _showSleepTimerSheet(context, c);

  Future<void> _showMore() async {
    c._publishMoreState();
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      showDragHandle: false,
      builder: (context) {
        final palette = HomePalette.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      '播放设置',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      icon: Icon(LucideIcons.x, size: 20, color: palette.muted),
                      onPressed: () => Navigator.pop(context),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Material(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: palette.line.withValues(alpha: 0.6),
                        width: 0.8,
                      ),
                    ),
                    child: ValueListenableBuilder<_MoreSnapshot>(
                      valueListenable: c._moreState,
                      builder: (context, snapshot, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF3B82F6,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.alarm_clock,
                                size: 20,
                                color: Color(0xFF3B82F6),
                              ),
                            ),
                            title: Text(
                              '定时关闭',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              snapshot.sleepMinutes == null
                                  ? '未开启'
                                  : '剩余 ${snapshot.sleepMinutes} 分钟',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: snapshot.sleepMinutes == null
                                    ? palette.muted
                                    : const Color(0xFF3B82F6),
                              ),
                            ),
                            trailing: Icon(
                              LucideIcons.chevron_right,
                              size: 18,
                              color: palette.muted,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_showSleepTimer());
                            },
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF10B981,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.list,
                                size: 20,
                                color: Color(0xFF10B981),
                              ),
                            ),
                            title: Text(
                              '书籍目录',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              '共 ${c._chapters.length} 章',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                            trailing: Icon(
                              LucideIcons.chevron_right,
                              size: 18,
                              color: palette.muted,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_showCatalog());
                            },
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 2,
                            ),
                            leading: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFF59E0B,
                                ).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                LucideIcons.skip_forward,
                                size: 20,
                                color: Color(0xFFF59E0B),
                              ),
                            ),
                            title: Text(
                              '自动下一章',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: palette.ink,
                              ),
                            ),
                            subtitle: Text(
                              '当前章节播完后自动连播',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                            trailing: Switch(
                              key: const ValueKey('audio-auto-next'),
                              value: snapshot.autoAdvance,
                              onChanged: snapshot.loading
                                  ? null
                                  : (enabled) {
                                      if (!mounted || c._loading) return;
                                      c._update(() => c._autoAdvance = enabled);
                                      c._publishMoreState();
                                      unawaited(c._persistProgress());
                                    },
                            ),
                            onTap: snapshot.loading
                                ? null
                                : () {
                                    if (!mounted || c._loading) return;
                                    c._update(
                                      () => c._autoAdvance =
                                          !snapshot.autoAdvance,
                                    );
                                    c._publishMoreState();
                                    unawaited(c._persistProgress());
                                  },
                          ),
                          Divider(
                            height: 1,
                            indent: 68,
                            color: palette.line.withValues(alpha: 0.5),
                          ),
                          ValueListenableBuilder<bool>(
                            valueListenable:
                                AudioPreferences.instance.backgroundPlayback,
                            builder: (context, bgEnabled, _) => ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 2,
                              ),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF8B5CF6,
                                  ).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  LucideIcons.headphones,
                                  size: 20,
                                  color: Color(0xFF8B5CF6),
                                ),
                              ),
                              title: Text(
                                '后台听书与保活',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                  color: palette.ink,
                                ),
                              ),
                              subtitle: Text(
                                '切到后台或锁屏时继续播放并常驻控制卡片',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: palette.muted,
                                ),
                              ),
                              trailing: Switch(
                                key: const ValueKey(
                                  'audio-background-playback',
                                ),
                                value: bgEnabled,
                                onChanged: (enabled) {
                                  unawaited(
                                    AudioPreferences.instance
                                        .setBackgroundPlayback(enabled),
                                  );
                                },
                              ),
                              onTap: () {
                                final next = !bgEnabled;
                                unawaited(
                                  AudioPreferences.instance
                                      .setBackgroundPlayback(next),
                                );
                              },
                            ),
                          ),
                          if (c._extras.related.isNotEmpty) ...[
                            Divider(
                              height: 1,
                              indent: 68,
                              color: palette.line.withValues(alpha: 0.5),
                            ),
                            for (final work in c._extras.related)
                              ListTile(
                                key: ValueKey('audio-related-${work.id}'),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 2,
                                ),
                                leading: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFFEC4899,
                                    ).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    LucideIcons.library,
                                    size: 20,
                                    color: Color(0xFFEC4899),
                                  ),
                                ),
                                title: Text(
                                  work.title.isEmpty ? '相关作品' : work.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                    color: palette.ink,
                                  ),
                                ),
                                subtitle: Text(
                                  work.label.isEmpty ? '同一部书的其他版本' : work.label,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: palette.muted,
                                  ),
                                ),
                                trailing: Icon(
                                  LucideIcons.chevron_right,
                                  size: 18,
                                  color: palette.muted,
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  unawaited(_openRelated(work));
                                },
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openRelated(RelatedWork work) async {
    if (c._closed || work.id.isEmpty || c._switchingVersion) return;
    final generation = c._generation;
    _RoutePlayback? suspended;
    c._update(() => c._switchingVersion = true);
    try {
      // The app owns playback across routes; a standalone page keeps its old
      // release/restore contract when no application session owner exists.
      if (_owner == null) {
        suspended = await c._suspendForRoute(generation);
        if (suspended == null) return;
      }
      if (!mounted || c._closed) return;
      await openBookDetail(
        context,
        MediaItem(
          id: work.id,
          title: work.title,
          cover: work.cover,
          author: '',
          badge: work.label,
          ep: '',
          kind: 'book',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开作品，请稍后重试')));
    } finally {
      await c._restoreAfterRoute(suspended);
      c._update(() => c._switchingVersion = false);
    }
  }
}

/// Reviews sheet opened from the 书评 action.
class _AudioCommentsSheet extends StatefulWidget {
  final String bookId;
  final Future<BookCommentPage> Function(String bookId, {int offset})? loader;

  const _AudioCommentsSheet({required this.bookId, this.loader});

  @override
  State<_AudioCommentsSheet> createState() => _AudioCommentsSheetState();
}

class _AudioCommentsSheetState extends State<_AudioCommentsSheet> {
  BookCommentPage? _page;
  List<BookComment> _comments = const [];
  bool _failed = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextOffset = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final loader = widget.loader;
    if (loader == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final page = await loader(widget.bookId);
      if (mounted) {
        setState(() {
          _page = page;
          _comments = page.comments;
          _hasMore = page.hasMore;
          _nextOffset = page.nextOffset;
        });
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.loader;
    if (loader == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await loader(widget.bookId, offset: _nextOffset);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...page.comments];
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset;
        _loadingMore = false;
      });
    } on Exception {
      // The appended list stays; the footer flips back so it can be retried.
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final page = _page;
    final hasMore = _hasMore && widget.loader != null;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                Text(
                  page?.headerLabel ?? '书评',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (page != null && page.scoreLabel.isNotEmpty)
                  Text(
                    page.scoreLabel,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _failed
                ? Center(
                    child: Text(
                      '暂时无法加载书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : page == null
                ? const Center(
                    child: CircularProgressIndicator(color: HomePalette.accent),
                  )
                : _comments.isEmpty
                ? Center(
                    child: Text(
                      '还没有书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _comments.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _comments.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: HomePalette.accent,
                                    ),
                                  )
                                : TextButton(
                                    key: const Key('audio_comments_more'),
                                    onPressed: _loadMore,
                                    child: Text(
                                      '加载更多书评',
                                      style: TextStyle(
                                        color: palette.accentText,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }
                      final comment = _comments[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    comment.userName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  comment.relativeTime(),
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (comment.text.isNotEmpty)
                              Text(
                                comment.text,
                                style: TextStyle(
                                  color: palette.ink,
                                  fontSize: 13,
                                  height: 1.65,
                                ),
                              ),
                            if (comment.imageUrls.isNotEmpty) ...[
                              if (comment.text.isNotEmpty)
                                const SizedBox(height: 8),
                              CommentImages(imageUrls: comment.imageUrls),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Compact icon + tooltip button used in the transport row.
class _TransportButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        foregroundColor: active ? palette.accentText : palette.ink,
        disabledForegroundColor: palette.line,
        minimumSize: const Size(48, 48),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

class _AudioCatalog extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;

  const _AudioCatalog({required this.chapters, required this.currentIndex});

  @override
  State<_AudioCatalog> createState() => _AudioCatalogState();
}

class _AudioCatalogState extends State<_AudioCatalog> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * 72.0,
  );
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexes = [
      for (var index = 0; index < widget.chapters.length; index++)
        if (_query.isEmpty ||
            widget.chapters[index].title.toLowerCase().contains(_query) ||
            '${index + 1}' == _query)
          index,
    ];
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height - keyboard) * 0.72,
          child: Column(
            children: [
              Text(
                '目录 · ${widget.chapters.length} 章',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索章节名称或序号',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) {
                    setState(() => _query = value.trim().toLowerCase());
                    if (_controller.hasClients) _controller.jumpTo(0);
                  },
                ),
              ),
              Expanded(
                child: indexes.isEmpty
                    ? const Center(child: Text('没有匹配的章节'))
                    : ListView.builder(
                        controller: _controller,
                        itemCount: indexes.length,
                        itemExtent: 72,
                        itemBuilder: (context, offset) {
                          final index = indexes[offset];
                          final chapter = widget.chapters[index];
                          return ListTile(
                            key: ValueKey('audio-chapter-$index'),
                            selected: index == widget.currentIndex,
                            leading: Text('${index + 1}'),
                            title: Text(
                              chapter.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: chapter.volumeName.isEmpty
                                ? null
                                : Text(
                                    chapter.volumeName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: index == widget.currentIndex
                                ? const Icon(Icons.graphic_eq)
                                : null,
                            onTap: () => Navigator.pop(context, index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
