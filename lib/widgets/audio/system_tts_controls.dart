import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../pages/reader_page.dart';
import '../../pages/system_tts_settings_page.dart';
import '../../services/system_tts.dart';
import '../home/home_design.dart';
import 'audio_sections.dart';

/// 系统朗读的「听书」详情页。
///
/// 和作品自带音频的听书页共用同一套骨架（封面 + 章节、可滚动逐句正文、
/// 页码/全书进度、传输控件、音色条），用户从胶囊进来看到的界面一致，
/// 不再是一个纯文字的系统朗读列表页。
class SystemTtsPlaybackPage extends StatelessWidget {
  const SystemTtsPlaybackPage({
    super.key,
    required this.session,
    required this.onClose,
  });

  final SystemTtsPlayback session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            final chapters = session.book.chapters;
            if (chapters.isEmpty) {
              return Column(
                children: [
                  AudioTopBar(
                    onCollapse: () => Navigator.of(context).maybePop(),
                    onMore: () {},
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '暂无可朗读章节',
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                  ),
                ],
              );
            }
            final chapter = session.chapter;
            final text = session.text;
            final ranges = session.sentences;
            final lines = [
              for (final range in ranges) text.substring(range.start, range.end),
            ];
            return Column(
              children: [
                AudioTopBar(
                  onCollapse: () => Navigator.of(context).maybePop(),
                  onMore: () => _showMore(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
                  child: AudioNowPlayingHeader(
                    cover: session.book.cover,
                    bookTitle: session.book.title,
                    chapterTitle: chapter.title,
                    subtitle: '第 ${session.index + 1} / ${chapters.length} 章',
                    onOpenCatalog: () => _showCatalog(context),
                    onOpenReader: () => _openReader(context),
                  ),
                ),
                Expanded(
                  child: TtsNarrationBody(
                    lines: lines,
                    currentIndex: session.sentenceIndex,
                    placeholder: session.loading ? '正在准备朗读…' : '本章暂无正文',
                    onListenFrom: (index) =>
                        unawaited(session.speakFrom(ranges[index].start)),
                    onOpenReader: () => _openReader(context),
                  ),
                ),
                AudioListenFooter(
                  pageLabel: _pageLabel(session, text.length),
                  bookProgress: _bookProgress(session),
                ),
                SizedBox(
                  height: 46,
                  child: Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _statusLine(context, palette),
                      ),
                    ),
                  ),
                ),
                _transport(context, palette),
                const SizedBox(height: 6),
                AudioToneBar(
                  title: '系统朗读',
                  toneLabel: session.loading ? '正在准备…' : '手机语音引擎',
                  onTones: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const SystemTtsSettingsPage(),
                    ),
                  ),
                  onReadAlong: () => _openReader(context),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _statusLine(BuildContext context, HomePalette palette) {
    final style = TextStyle(color: palette.muted, fontSize: 12.5);
    if (session.closed) return Text('朗读已关闭', style: style);
    if (session.error case final message?) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              style: style,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => unawaited(session.toggle()),
            child: const Text('重试'),
          ),
        ],
      );
    }
    if (session.loading) return Text('正在准备朗读…', style: style);
    if (session.completed) {
      return Text(
        session.index + 1 >= session.book.chapters.length
            ? '全书朗读完毕'
            : '本章已朗读完毕',
        style: style,
      );
    }
    final index = session.sentenceIndex;
    if (index >= 0) {
      return Text(
        '正在朗读 · 第 ${index + 1} / ${session.sentences.length} 句',
        style: style,
      );
    }
    return Text(session.wantPlay ? '正在朗读' : '已暂停', style: style);
  }

  Widget _transport(BuildContext context, HomePalette palette) {
    final chapters = session.book.chapters;
    final playing = session.wantPlay;
    Widget button(IconData icon, String tooltip, VoidCallback? onTap) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          iconSize: 22,
          style: IconButton.styleFrom(
            foregroundColor: palette.muted,
            disabledForegroundColor: palette.muted.withValues(alpha: 0.35),
          ),
          icon: Icon(icon),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        button(LucideIcons.list, '目录', () => _showCatalog(context)),
        button(
          LucideIcons.skip_back,
          '上一章',
          session.closed || session.index == 0
              ? null
              : () => unawaited(session.openChapter(session.index - 1)),
        ),
        IconButton(
          tooltip: playing ? '暂停' : '播放',
          onPressed: session.closed
              ? null
              : () => unawaited(session.toggle()),
          padding: const EdgeInsets.all(11),
          iconSize: 38,
          style: IconButton.styleFrom(
            foregroundColor: palette.ink,
            disabledForegroundColor: palette.muted.withValues(alpha: 0.5),
          ),
          icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
        ),
        button(
          LucideIcons.skip_forward,
          '下一章',
          session.closed || session.index + 1 >= chapters.length
              ? null
              : () => unawaited(session.openChapter(session.index + 1)),
        ),
        button(
          LucideIcons.settings_2,
          '朗读设置',
          () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
          ),
        ),
      ],
    );
  }

  Future<void> _showMore(BuildContext context) async {
    final palette = HomePalette.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: palette.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(LucideIcons.settings_2, color: palette.ink),
              title: Text('朗读设置', style: TextStyle(color: palette.ink)),
              onTap: () => Navigator.of(context).pop('settings'),
            ),
            ListTile(
              leading: Icon(LucideIcons.x, color: palette.ink),
              title: Text('关闭朗读', style: TextStyle(color: palette.ink)),
              onTap: () => Navigator.of(context).pop('close'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (selected) {
      case 'settings':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
        );
      case 'close':
        onClose();
        Navigator.of(context).maybePop();
    }
  }

  Future<void> _showCatalog(BuildContext context) async {
    final palette = HomePalette.of(context);
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: palette.surface,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: session.book.chapters.length,
            itemBuilder: (context, index) {
              final current = index == session.index;
              return ListTile(
                dense: true,
                title: Text(
                  session.book.chapters[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: current ? palette.accentText : palette.ink,
                    fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                onTap: () => Navigator.of(context).pop(index),
              );
            },
          ),
        ),
      ),
    );
    if (selected == null || selected == session.index) return;
    await session.openChapter(selected);
  }

  Future<void> _openReader(BuildContext context) {
    final chapters = session.book.chapters;
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          bookId: session.book.bookId,
          title: session.book.title,
          cover: session.book.cover,
          chapters: chapters,
          startIndex: session.index.clamp(0, math.max(0, chapters.length - 1)),
        ),
      ),
    );
  }

  String _pageLabel(SystemTtsPlayback session, int length) {
    final pages = math.max(1, (length / 650).ceil());
    final page = (session.progress * pages).floor().clamp(0, pages - 1) + 1;
    return '第 $page / $pages 页';
  }

  double _bookProgress(SystemTtsPlayback session) {
    final total = session.book.chapters.length;
    if (total == 0) return 0;
    return ((session.index + session.progress) / total).clamp(0.0, 1.0);
  }
}
