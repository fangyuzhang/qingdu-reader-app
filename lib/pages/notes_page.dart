import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/imported_book_store.dart';
import '../services/note_card_exporter.dart';
import '../services/reader_annotation_store.dart';
import '../widgets/home/home_design.dart';
import 'reader_page.dart';

/// 笔记页：汇总全书架的批注与书摘。
///
/// 【青茄重构·新增】蜗牛读书式批注的「另一半」——阅读时写下的想法和收藏的
/// 句子在这里集中查看，点任意一条直接回到原文对应位置（[ReaderPage.startTextOffset]）。
class NotesPage extends StatefulWidget {
  const NotesPage({super.key, this.store});

  /// 默认单例；测试可注入。
  final ReaderAnnotationStore? store;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  ReaderAnnotationStore get _store =>
      widget.store ?? ReaderAnnotationStore.instance;

  List<ReaderAnnotation> _all = const [];
  String _tab = 'all';
  bool _loading = true;

  /// 导出进行中（按钮置灰，避免重复点）。
  bool _exporting = false;

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

  void _reload() {
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await _store.loadAll();
    if (!mounted) return;
    setState(() {
      _all = entries;
      _loading = false;
    });
  }

  List<ReaderAnnotation> get _visible => switch (_tab) {
    'annot' => _all.where((e) => e.isAnnot).toList(),
    'excerpt' => _all.where((e) => !e.isAnnot).toList(),
    _ => _all,
  };

  int get _annotCount => _all.where((e) => e.isAnnot).length;
  int get _excerptCount => _all.length - _annotCount;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
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
            tooltip: '导出长图',
            icon: const Icon(LucideIcons.image_down),
            onPressed: _visible.isEmpty || _exporting ? null : _exportImage,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTabs(palette),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _visible.isEmpty
                ? _buildEmpty(palette)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: _visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _NoteCard(note: _visible[index], onOpen: _openNote),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(HomePalette palette) {
    Widget chip(String key, String label, int count) {
      final active = _tab == key;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          selected: active,
          showCheckmark: false,
          label: Text('$label $count'),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: active ? palette.accentText : palette.muted,
          ),
          selectedColor: palette.soft,
          backgroundColor: palette.surface,
          side: BorderSide(color: palette.line, width: 0.5),
          onSelected: (_) => setState(() => _tab = key),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          chip('all', '全部', _all.length),
          chip('annot', '批注', _annotCount),
          chip('excerpt', '书摘', _excerptCount),
        ],
      ),
    );
  }

  Widget _buildEmpty(HomePalette palette) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.pen_line, size: 40, color: palette.line),
          const SizedBox(height: 12),
          Text(
            '还没有${_tab == 'excerpt' ? '书摘' : _tab == 'annot' ? '批注' : '笔记'}',
            style: TextStyle(fontSize: 14, color: palette.muted),
          ),
          const SizedBox(height: 6),
          Text(
            '阅读时长按选中句子 → 批注 / 书摘',
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
        ],
      ),
    );
  }

  /// 【青茄重构·新增】把当前筛选下的笔记导出为长图（PNG）。
  ///
  /// 只在主 isolate 里绘制：笔记数量级很小（最多几百条），
  /// 不值得为它起一个 isolate 增加出错面。
  Future<void> _exportImage() async {
    final notes = _visible;
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

  /// 回到原文：优先本地书（直接有章节），网络书现场取目录。
  Future<void> _openNote(ReaderAnnotation note) async {
    final local = await _localChapter(note);
    if (local != null) {
      await _pushReader(note, local, localOnly: true);
      return;
    }
    // 网络书：取一次目录再定位；失败时给明确提示而不是静默无反应。
    List<List<Chapter>> volumes;
    try {
      volumes = await ApiClient.instance.directoryChapters(note.bookId);
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
    await _pushReader(note, chapters, localOnly: false);
  }

  /// 本地书的章节来自 [ImportedBookStore]；没有则返回 null（按网络书处理）。
  Future<List<Chapter>?> _localChapter(ReaderAnnotation note) async {
    try {
      final book = await ImportedBookStore.instance.book(note.bookId);
      if (book == null || book.chapters.isEmpty) return null;
      return book.chapters;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pushReader(
    ReaderAnnotation note,
    List<Chapter> chapters, {
    required bool localOnly,
  }) async {
    var index = chapters.indexWhere((c) => c.itemId == note.chapterId);
    if (index < 0) index = 0;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: note.bookId,
          title: note.bookTitle.isEmpty ? '阅读' : note.bookTitle,
          chapters: chapters,
          startIndex: index,
          // 本地书走文件读取，网络书走在线接口。
          localOnly: localOnly,
          chapterLoader: !localOnly
              ? null
              : (chapter) => ImportedBookStore.instance.chapterText(
                  note.bookId,
                  chapter.itemId,
                ),
          startTextOffset: note.start,
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.onOpen});

  final ReaderAnnotation note;
  final Future<void> Function(ReaderAnnotation note) onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final isAnnot = note.isAnnot;
    final badgeColor = isAnnot
        ? const Color(0xFFD64545)
        : const Color(0xFF3DA88A);
    return Container(
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
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isAnnot ? '批' : '摘',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1.0,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [
                        if (note.bookTitle.isNotEmpty) note.bookTitle,
                        if (note.chapterTitle.isNotEmpty) note.chapterTitle,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                  ),
                  Icon(LucideIcons.corner_down_right,
                      size: 14, color: palette.accentText),
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
                  color: isAnnot
                      ? const Color(0x14D64545)
                      : const Color(0x143DA88A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  note.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: Color(0xFF8A7B62),
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
            ],
          ),
        ),
      ),
    );
  }
}
