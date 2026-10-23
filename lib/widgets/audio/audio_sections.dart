import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../../services/playback_format.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';

/// Listening page title with collapse and additional actions.
class AudioTopBar extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onMore;

  const AudioTopBar({
    super.key,
    required this.onCollapse,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 52,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.center,
            child: Semantics(
              header: true,
              child: Text(
                '听书',
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: '收起',
              onPressed: onCollapse,
              style: IconButton.styleFrom(foregroundColor: palette.ink),
              icon: const Icon(LucideIcons.chevron_down, size: 22),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: '更多',
                onPressed: onMore,
                style: IconButton.styleFrom(foregroundColor: palette.ink),
                icon: const Icon(LucideIcons.ellipsis_vertical, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Large cover card mirroring the official listening page: the chapter title
/// and the book title sit on the cover, the whole card opens the catalog, and
/// the top-right button switches the voice.
class AudioBookCard extends StatelessWidget {
  final String cover;
  final String bookTitle;
  final String chapterTitle;
  final VoidCallback? onSwitch;
  final VoidCallback? onOpenBook;

  const AudioBookCard({
    super.key,
    this.cover = '',
    required this.bookTitle,
    required this.chapterTitle,
    this.onSwitch,
    this.onOpenBook,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 293),
        child: AspectRatio(
          aspectRatio: 293 / 313,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CoverImage(url: cover, palette: palette),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 150,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 58,
                  child: Text(
                    chapterTitle,
                    key: const Key('audio_chapter_title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
                // Keep the full-cover catalog target below the two buttons.
                // See .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onOpenBook,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 15,
                  height: 35,
                  child: HomePressable(
                    key: const Key('audio_book_bar'),
                    semanticLabel: '查看目录',
                    onTap: onOpenBook ?? () {},
                    borderRadius: BorderRadius.zero,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              bookTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            LucideIcons.chevron_right,
                            size: 13,
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: HomePressable(
                    key: const Key('audio_cover_switch'),
                    semanticLabel: '切换音色',
                    onTap: onSwitch ?? () {},
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.28),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.repeat,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverImage extends StatelessWidget {
  final String url;
  final HomePalette palette;

  const _CoverImage({required this.url, required this.palette});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        color: palette.soft,
        alignment: Alignment.center,
        child: Icon(LucideIcons.book_open, color: palette.muted, size: 36),
      );
    }
    return CachedNetworkImage(
      cacheManager: PosterCache.instance,
      imageUrl: url,
      fit: BoxFit.cover,
      // The big cover renders at ~293 logical px; decode at 2× instead of the
      // original resolution (typically 600-1000px wide).
      memCacheWidth: 640,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, _) => Container(color: palette.soft),
      errorWidget: (context, _, _) => Container(
        color: palette.soft,
        alignment: Alignment.center,
        child: Icon(LucideIcons.book_open, color: palette.muted, size: 36),
      ),
    );
  }
}

/// 听书页顶部：缩小的封面 + 右侧当前章节。
///
/// 封面固定在左上，章节标题最多两行，所以标题长短不会推挤下方的播放控件。
class AudioNowPlayingHeader extends StatelessWidget {
  final String cover;
  final String bookTitle;
  final String chapterTitle;
  final String subtitle;
  final VoidCallback? onOpenCatalog;
  final VoidCallback? onOpenReader;

  const AudioNowPlayingHeader({
    super.key,
    this.cover = '',
    required this.bookTitle,
    required this.chapterTitle,
    this.subtitle = '',
    this.onOpenCatalog,
    this.onOpenReader,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 84,
      child: Row(
        children: [
          GestureDetector(
            onTap: onOpenCatalog,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 60,
                height: 80,
                child: _CoverImage(url: cover, palette: palette),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenCatalog,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapterTitle,
                    key: const Key('audio_chapter_title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle.isEmpty ? bookTitle : '$bookTitle · $subtitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '打开目录',
            onPressed: onOpenCatalog,
            visualDensity: VisualDensity.compact,
            icon: Icon(LucideIcons.list, size: 20, color: palette.muted),
          ),
          IconButton(
            tooltip: '进入正文',
            key: const Key('audio-open-reader'),
            onPressed: onOpenReader,
            visualDensity: VisualDensity.compact,
            icon: Icon(LucideIcons.book_open, size: 20, color: palette.muted),
          ),
        ],
      ),
    );
  }
}

/// 正文滚动区上下的渐隐遮罩：文字进出列表边缘时淡出，而不是被硬切掉半行。
class NarrationFade extends StatelessWidget {
  /// 44 像素盖住一行半文字，正文进出时是淡出而不是被刀切掉半行。
  const NarrationFade({super.key, required this.child, this.height = 44});

  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final edge = palette.canvas;
    Widget mask(bool top) => Positioned(
      top: top ? 0 : null,
      bottom: top ? null : 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [edge, edge, edge.withValues(alpha: 0)],
              stops: const [0, 0.28, 1],
            ),
          ),
        ),
      ),
    );
    return Stack(
      children: [Positioned.fill(child: child), mask(true), mask(false)],
    );
  }
}

/// 听书页正文区：整章文字可上下滚动，像读正文一样。
///
/// 有字幕轨时逐句铺开、当前句高亮并自动跟随；长按任意一句弹出「从本句听」。
/// 没有字幕轨（部分真人讲书）时退回章节摘要段落，只读不跟随。不加载任何图片。
class AudioNarrationBody extends StatefulWidget {
  final SubtitleTrack track;
  final String excerpt;
  final ValueListenable<Duration> position;
  final void Function(Duration at)? onListenFrom;
  final VoidCallback? onOpenReader;

  const AudioNarrationBody({
    super.key,
    required this.track,
    required this.excerpt,
    required this.position,
    this.onListenFrom,
    this.onOpenReader,
  });

  @override
  State<AudioNarrationBody> createState() => _AudioNarrationBodyState();
}

class _AudioNarrationBodyState extends State<AudioNarrationBody> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _currentKey = GlobalKey();
  int _index = -1;

  /// 用户自己滚动时暂停自动跟随，过一会儿再恢复，免得刚滑上去就被拽回。
  DateTime _followPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _index = widget.track.indexAt(widget.position.value);
    widget.position.addListener(_onPosition);
    _scheduleFollow();
  }

  @override
  void didUpdateWidget(covariant AudioNarrationBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    final next = widget.track.indexAt(widget.position.value);
    if (next != _index) {
      _index = next;
      _scheduleFollow();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _controller.dispose();
    super.dispose();
  }

  void _onPosition() {
    final next = widget.track.indexAt(widget.position.value);
    if (next == _index || !mounted) return;
    setState(() => _index = next);
    _scheduleFollow();
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (DateTime.now().isBefore(_followPausedUntil)) return;
      final context = _currentKey.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.32,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _showListenMenu(
    BuildContext context,
    Offset globalPosition,
    SubtitleCue cue,
  ) async {
    final confirmed = await _confirmListenFromHere(context, globalPosition);
    if (confirmed && mounted) {
      widget.onListenFrom?.call(Duration(milliseconds: cue.startMs));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final cues = widget.track.cues;
    final paragraphs = <String>[
      if (cues.isEmpty)
        for (final line in widget.excerpt.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
    ];
    if (cues.isEmpty && paragraphs.isEmpty) {
      return Center(
        child: Text(
          '本章暂无同步字幕',
          key: const Key('audio_narration_empty'),
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      );
    }
    return NarrationFade(
      child: NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) {
          _followPausedUntil = DateTime.now().add(const Duration(seconds: 8));
        }
        return false;
      },
      child: SingleChildScrollView(
        key: const Key('audio-narration-scroll'),
        controller: _controller,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cues.isEmpty)
              for (final paragraph in paragraphs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    paragraph,
                    key: const Key('audio_narration_excerpt'),
                    style: TextStyle(
                      color: palette.ink.withValues(alpha: 0.88),
                      fontSize: 16,
                      height: 1.8,
                    ),
                  ),
                )
            else
              for (var i = 0; i < cues.length; i++)
                _cueLine(context, cues[i], i, palette),
          ],
        ),
        ),
      ),
    );
  }

  Widget _cueLine(
    BuildContext context,
    SubtitleCue cue,
    int index,
    HomePalette palette,
  ) {
    final current = index == _index;
    final past = _index >= 0 && index < _index;
    final hasAction = widget.onListenFrom != null;
    return GestureDetector(
      key: current ? _currentKey : null,
      behavior: HitTestBehavior.opaque,
      onLongPressStart: hasAction
          ? (details) =>
                unawaited(_showListenMenu(context, details.globalPosition, cue))
          : null,
      onDoubleTap: widget.onOpenReader,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
        decoration: BoxDecoration(
          color: current
              ? HomePalette.accent.withValues(alpha: palette.dark ? 0.16 : 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: current ? palette.accentText : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          cue.text,
          key: current ? const Key('audio_narration_current') : null,
          style: TextStyle(
            color: current
                ? palette.ink
                : past
                ? palette.muted.withValues(alpha: 0.5)
                : palette.muted.withValues(alpha: 0.85),
            fontSize: current ? 17 : 16,
            height: 1.75,
            fontWeight: current ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 系统朗读的正文区：与有声书正文同一套观感（逐句铺开、当前句高亮、
/// 自动跟随、上下渐隐），区别只是句子来自 TTS 的正文切分而不是字幕轨。
class TtsNarrationBody extends StatefulWidget {
  const TtsNarrationBody({
    super.key,
    required this.lines,
    required this.currentIndex,
    this.placeholder = '正在准备朗读…',
    this.onListenFrom,
    this.onOpenReader,
  });

  final List<String> lines;
  final int currentIndex;
  final String placeholder;
  final void Function(int index)? onListenFrom;
  final VoidCallback? onOpenReader;

  @override
  State<TtsNarrationBody> createState() => _TtsNarrationBodyState();
}

class _TtsNarrationBodyState extends State<TtsNarrationBody> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _currentKey = GlobalKey();
  DateTime _followPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _scheduleFollow();
  }

  @override
  void didUpdateWidget(covariant TtsNarrationBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) _scheduleFollow();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (DateTime.now().isBefore(_followPausedUntil)) return;
      final context = _currentKey.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.32,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _showMenu(BuildContext context, Offset at, int index) async {
    if (await _confirmListenFromHere(context, at)) {
      widget.onListenFrom?.call(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          widget.placeholder,
          key: const Key('tts_narration_empty'),
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      );
    }
    return NarrationFade(
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.dragDetails != null) {
            _followPausedUntil = DateTime.now().add(const Duration(seconds: 8));
          }
          return false;
        },
        child: SingleChildScrollView(
          key: const Key('tts-narration-scroll'),
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < widget.lines.length; i++)
                _line(context, widget.lines[i], i, palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    String text,
    int index,
    HomePalette palette,
  ) {
    final current = index == widget.currentIndex;
    final past = widget.currentIndex >= 0 && index < widget.currentIndex;
    final hasAction = widget.onListenFrom != null;
    return GestureDetector(
      key: current ? _currentKey : null,
      behavior: HitTestBehavior.opaque,
      onLongPressStart: hasAction
          ? (details) =>
                unawaited(_showMenu(context, details.globalPosition, index))
          : null,
      onDoubleTap: widget.onOpenReader,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
        decoration: BoxDecoration(
          color: current
              ? HomePalette.accent.withValues(alpha: palette.dark ? 0.16 : 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: current ? palette.accentText : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          text,
          key: current ? const Key('tts_narration_current') : null,
          style: TextStyle(
            color: current
                ? palette.ink
                : past
                ? palette.muted.withValues(alpha: 0.5)
                : palette.muted.withValues(alpha: 0.85),
            fontSize: current ? 17 : 16,
            height: 1.75,
            fontWeight: current ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 正文下方的进度脚注：左边阅读页数，右边全书进度。
class AudioListenFooter extends StatelessWidget {
  final String pageLabel;
  final double bookProgress;

  const AudioListenFooter({
    super.key,
    required this.pageLabel,
    required this.bookProgress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final percent = (bookProgress.clamp(0.0, 1.0) * 100).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      child: Row(
        children: [
          Text(
            pageLabel,
            key: const Key('audio-page-label'),
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          ),
          const Spacer(),
          Text(
            '全书 $percent%',
            key: const Key('audio-book-progress'),
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// 音色与边听边读的紧凑入口，替代原来占很大一块的音色卡片。
class AudioToneBar extends StatelessWidget {
  final String title;
  final String toneLabel;
  final VoidCallback? onTones;
  final VoidCallback onReadAlong;

  const AudioToneBar({
    super.key,
    required this.title,
    required this.toneLabel,
    required this.onTones,
    required this.onReadAlong,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: const Key('audio-voice'),
              onTap: onTones,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.audio_lines,
                      size: 16,
                      color: palette.muted,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        toneLabel.isEmpty ? title : toneLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.ink, fontSize: 12.5),
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 14,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            key: const Key('audio-read-along-bar'),
            onTap: onReadAlong,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.line, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.headphones, size: 15, color: palette.muted),
                  const SizedBox(width: 6),
                  Text(
                    '边听边读',
                    style: TextStyle(color: palette.muted, fontSize: 12.5),
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

/// 边听边读: the line being spoken plus the next one.
class AudioSubtitleView extends StatelessWidget {
  final SubtitleTrack track;
  final Duration position;

  const AudioSubtitleView({
    super.key,
    required this.track,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (track.isEmpty) return const SizedBox.shrink();
    final (current, next) = track.windowAt(position);
    if (current == null && next == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('audio_subtitles'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (current != null)
            Text(
              current.text,
              key: const Key('audio_subtitle_current'),
              style: TextStyle(
                color: palette.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.6,
              ),
            ),
          if (next != null) ...[
            const SizedBox(height: 6),
            Text(
              next.text,
              key: const Key('audio_subtitle_next'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted.withValues(alpha: 0.75),
                fontSize: 14,
                height: 1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One entry in the icon action row.
class AudioAction {
  const AudioAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
}

/// Icon + caption row (语速 / 加入书架 / 下载 / 章评 / 更多).
class AudioActionRow extends StatelessWidget {
  final List<AudioAction> actions;

  const AudioActionRow({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      children: [
        for (final action in actions)
          Expanded(
            child: HomePressable(
              key: ValueKey(action.key),
              semanticLabel: action.label,
              onTap: action.onTap ?? () {},
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      action.icon,
                      size: 21,
                      color: action.active ? palette.accentText : palette.ink,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: action.active
                            ? palette.accentText
                            : palette.muted,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// `-15s  ──●──  08:40/09:01  +15s` row.
class AudioProgressRow extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final double? preview;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onBack15;
  final VoidCallback? onForward15;

  const AudioProgressRow({
    super.key,
    required this.position,
    required this.duration,
    this.preview,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
    this.onBack15,
    this.onForward15,
  });

  static String time(Duration value) => formatPlaybackTime(value);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final maximum = duration.inMilliseconds.toDouble();
    final value = (preview ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      maximum > 0 ? maximum : 1.0,
    );
    final active = enabled && maximum > 0;
    return Column(
      children: [
        Row(
          children: [
            _SkipLabel(label: '-15s', tooltip: '后退15秒', onTap: onBack15),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: palette.accentText,
                  inactiveTrackColor: palette.line,
                  thumbColor: palette.accentText,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: MergeSemantics(
                  child: Slider(
                  key: const ValueKey('audio-seek'),
                  value: value,
                  max: maximum > 0 ? maximum : 1,
                  label: time(Duration(milliseconds: value.round())),
                    onChanged: active ? onChanged : null,
                    onChangeEnd: active ? onChangeEnd : null,
                  ),
                ),
              ),
            ),
            _SkipLabel(label: '+15s', tooltip: '前进15秒', onTap: onForward15),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '${time(Duration(milliseconds: value.round()))}/${time(duration)}',
            key: const ValueKey('audio-position-label'),
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _SkipLabel extends StatelessWidget {
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  const _SkipLabel({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: onTap == null ? palette.line : palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「从本句听」菜单：有声书字幕与系统朗读两个视图的菜单项逐行相同，
/// 这里只负责弹出菜单，回答用户是否确认从这句开始听。
Future<bool> _confirmListenFromHere(BuildContext context, Offset at) async {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return false;
  final palette = HomePalette.of(context);
  final selected = await showMenu<bool>(
    context: context,
    color: palette.surface,
    position: RelativeRect.fromRect(
      Rect.fromPoints(at, at + const Offset(1, 1)),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem<bool>(
        value: true,
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.play, size: 17, color: palette.accentText),
            const SizedBox(width: 10),
            Text(
              '从本句听',
              style: TextStyle(
                color: palette.ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ],
  );
  return selected == true;
}
