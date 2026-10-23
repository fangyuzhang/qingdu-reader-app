import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import '../widgets/home/home_design.dart';
import 'reader_page.dart';

/// 本地导入书/离线缓存书的详情与目录页。
///
/// 点书永远先落在这里；用户点章节或底部按钮后才进入正文。
class LocalBookDetailPage extends StatefulWidget {
  const LocalBookDetailPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    this.subtitle = '本地书籍',
    this.author = '',
    this.cover = '',
    this.readerStore,
    this.chapterCache,
    this.chapterLoader,
  });

  final String bookId;
  final String title;
  final String subtitle;
  final String author;
  final String cover;
  final List<Chapter> chapters;
  final ReaderStore? readerStore;
  final ChapterCache? chapterCache;
  final Future<String> Function(Chapter chapter)? chapterLoader;

  @override
  State<LocalBookDetailPage> createState() => _LocalBookDetailPageState();
}

class _LocalBookDetailPageState extends State<LocalBookDetailPage> {
  int? _resumeIndex;
  bool _loadingHistory = true;

  ReaderStore get _readerStore => widget.readerStore ?? LibraryStore.instance;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    Map<String, dynamic>? saved;
    try {
      saved = await ReaderHistory(_readerStore).load(widget.bookId);
    } catch (_) {
      // 历史存储不可用不阻止从第一章开始读。
    }
    if (!mounted) return;
    var index = widget.chapters.indexWhere(
      (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
    );
    if (index < 0) {
      final episode = num.tryParse(saved?['episode']?.toString() ?? '');
      if (episode != null && episode.isFinite && widget.chapters.isNotEmpty) {
        index = episode.toInt().clamp(0, widget.chapters.length - 1);
      }
    }
    setState(() {
      _resumeIndex = index < 0 ? null : index;
      _loadingHistory = false;
    });
  }

  Future<void> _open(int index) async {
    if (widget.chapters.isEmpty) return;
    final safeIndex = index.clamp(0, widget.chapters.length - 1);
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: widget.bookId,
          title: widget.title,
          cover: widget.cover,
          chapters: widget.chapters,
          startIndex: safeIndex,
          localOnly: widget.chapterLoader != null,
          readerStore: _readerStore,
          chapterCache: widget.chapterCache,
          chapterLoader: widget.chapterLoader,
        ),
      ),
    );
    if (mounted) await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final hasChapters = widget.chapters.isNotEmpty;
    return Scaffold(
      key: const ValueKey('local-book-detail-page'),
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('书籍详情'),
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(palette)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
              child: Row(
                children: [
                  Text(
                    '目录',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${widget.chapters.length} 章',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ),
          ),
          if (!hasChapters)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '这本书没有可用章节',
                  style: TextStyle(color: palette.muted),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: widget.chapters.length,
              itemBuilder: (context, index) {
                final chapter = widget.chapters[index];
                return ListTile(
                  key: ValueKey('local-book-chapter-${chapter.itemId}'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 22),
                  leading: SizedBox(
                    width: 34,
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ),
                  title: Text(
                    chapter.title.isEmpty ? '第 ${index + 1} 章' : chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(
                    LucideIcons.chevron_right,
                    size: 17,
                    color: palette.muted,
                  ),
                  onTap: () => _open(index),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
      bottomNavigationBar: !hasChapters
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                child: FilledButton.icon(
                  key: const ValueKey('local-book-read-button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: HomePalette.accent,
                  ),
                  onPressed: _loadingHistory
                      ? null
                      : () => _open(_resumeIndex ?? 0),
                  icon: Icon(
                    _resumeIndex == null
                        ? LucideIcons.book_open
                        : LucideIcons.play,
                    size: 18,
                  ),
                  label: Text(
                    _resumeIndex == null ? '开始阅读' : '继续阅读',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _header(HomePalette palette) {
    final cover = widget.cover.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.line, width: 0.6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 92,
                height: 126,
                child: _cover(cover, palette),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 21,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.author.trim().isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      widget.author,
                      style: TextStyle(color: palette.muted, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      widget.subtitle,
                      style: TextStyle(
                        color: palette.accentText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '本地保存，无需联网。点选目录章节后再进入正文。',
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(String path, HomePalette palette) {
    if (path.isNotEmpty) {
      final file = File(path);
      if (file.existsSync()) return Image.file(file, fit: BoxFit.cover);
      if (path.startsWith('http://') || path.startsWith('https://')) {
        return Image.network(
          path,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackCover(palette),
        );
      }
    }
    return _fallbackCover(palette);
  }

  Widget _fallbackCover(HomePalette palette) => Container(
    color: palette.soft,
    alignment: Alignment.center,
    child: Icon(LucideIcons.book, size: 40, color: palette.accentText),
  );
}
