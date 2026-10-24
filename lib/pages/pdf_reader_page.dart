import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/library_store.dart';
import '../services/reader_history.dart';
import '../widgets/home/home_design.dart';

/// PDF 固定版式阅读页（第 4 组）。
///
/// 与 TXT/EPUB 的流式阅读器（ReaderPage + ReaderChapterLayout）并列的
/// 第三种内容视图：渲染原 PDF 版式，分页天然固定，进度按页码存
/// LibraryStore 历史盒（positionVersion:3）。字符位置表通过
/// [pageText] 暴露，供墨迹批注锚定（第 5 组）。
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.pdfPath,
    this.cover = '',
    this.initialPage = 1,
  });

  final String bookId;
  final String title;
  final String pdfPath;
  final String cover;
  final int initialPage;

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  PdfDocument? _doc;
  String? _error;
  late final PageController _pageController;
  int _page = 1;
  int _pageCount = 0;
  bool _barsVisible = true;
  final DateTime _openedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(1, 1 << 30);
    _pageController = PageController(initialPage: _page - 1);
    _open();
  }

  Future<void> _open() async {
    try {
      // pdfrx 的运行时初始化（缓存目录/资源加载回调），幂等，首次打开前
      // 必须完成，否则 PdfDocument.openFile 报 getCacheDirectory is not set。
      await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
      final doc = await PdfDocument.openFile(widget.pdfPath);
      if (!mounted) {
        await doc.dispose();
        return;
      }
      // 续读页码来自历史（positionVersion:3）；超界回落第一页。
      final saved = await _resumePage();
      final count = doc.pages.length;
      setState(() {
        _doc = doc;
        _pageCount = count;
        _page = saved.clamp(1, count);
      });
      if (_page - 1 != _pageController.initialPage) {
        _pageController.jumpToPage(_page - 1);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'PDF 打开失败：$e');
    }
  }

  Future<int> _resumePage() async {
    try {
      final entry = await ReaderHistory(LibraryStore.instance).load(
        widget.bookId,
      );
      if (entry?['positionVersion'] == 3) {
        final page = num.tryParse(entry?['page']?.toString() ?? '');
        if (page != null && page >= 1) return page.toInt();
      }
    } catch (_) {
      // 历史不可用就从第一页开始。
    }
    return widget.initialPage;
  }

  Future<void> _persistProgress() async {
    if (_pageCount == 0) return;
    try {
      await ReaderHistory(LibraryStore.instance).save({
        'id': widget.bookId,
        'kind': 'book',
        'title': widget.title,
        'bookId': widget.bookId,
        'chapterId': 'pdf',
        'episode': _page,
        'positionVersion': 3,
        'page': _page,
        'pageCount': _pageCount,
        'progress': _page / _pageCount,
        'cover': widget.cover,
        'time': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // 进度失败不阻断阅读。
    }
  }

  void _onPageChanged(int index) {
    setState(() => _page = index + 1);
    unawaited(_persistProgress());
  }

  void _goTo(int page) {
    final target = page.clamp(1, _pageCount <= 0 ? 1 : _pageCount);
    _pageController.jumpToPage(target - 1);
  }

  @override
  void dispose() {
    final seconds = DateTime.now().difference(_openedAt).inMilliseconds / 1000.0;
    if (seconds > 1) {
      unawaited(
        LibraryStore.instance
            .accumulateReadTime(widget.bookId, 'book', seconds)
            .catchError((_) {}),
      );
    }
    _pageController.dispose();
    unawaited(_doc?.dispose());
    super.dispose();
  }

  /// 某一页的文本 + 逐字符坐标表（PDF 用户坐标系，原点左下、y 向上；
  /// 归一化到页面视口时需翻转 y，见第 5 组锚点换算）。
  Future<PdfPageRawText?> pageText(int pageNumber) async {
    final doc = _doc;
    if (doc == null || pageNumber < 1 || pageNumber > doc.pages.length) {
      return null;
    }
    try {
      return await doc.pages[pageNumber - 1].loadText();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF3B403C),
      body: _error != null
          ? _errorView(palette)
          : Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => _handleTap(details, context),
                    child: _doc == null
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          )
                        : PageView.builder(
                            key: const Key('pdf-page-view'),
                            controller: _pageController,
                            itemCount: _pageCount,
                            onPageChanged: _onPageChanged,
                            itemBuilder: (context, index) => Padding(
                              padding: const EdgeInsets.all(12),
                              child: PdfPageView(
                                document: _doc,
                                pageNumber: index + 1,
                                backgroundColor: Colors.white,
                              ),
                            ),
                          ),
                  ),
                ),
                if (_barsVisible && _doc != null) ...[
                  _topBar(palette),
                  _bottomBar(palette),
                ],
              ],
            ),
    );
  }

  /// 点击分区：左右 28% 翻页，中间切换工具栏显隐（对齐阅读器点击区习惯）。
  void _handleTap(TapUpDetails details, BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (x < width * 0.28) {
      _goTo(_page - 1);
    } else if (x > width * 0.72) {
      _goTo(_page + 1);
    } else {
      setState(() => _barsVisible = !_barsVisible);
      SystemChrome.setEnabledSystemUIMode(
        _barsVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersive,
      );
    }
  }

  Widget _topBar(HomePalette palette) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 6,
          left: 8,
          right: 16,
          bottom: 8,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.maybePop(context),
            ),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$_page / $_pageCount',
              key: const Key('pdf-page-indicator'),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(HomePalette palette) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: MediaQuery.paddingOf(context).bottom + 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              key: const Key('pdf-prev-page'),
              icon: const Icon(Icons.chevron_left, color: Colors.white),
              onPressed: _page <= 1 ? null : () => _goTo(_page - 1),
            ),
            Expanded(
              child: Slider(
                key: const Key('pdf-page-slider'),
                value: _pageCount <= 1
                    ? 0
                    : (_page - 1) / (_pageCount - 1),
                onChanged: _pageCount <= 1
                    ? null
                    : (v) => _goTo((v * (_pageCount - 1)).round() + 1),
              ),
            ),
            IconButton(
              key: const Key('pdf-next-page'),
              icon: const Icon(Icons.chevron_right, color: Colors.white),
              onPressed: _page >= _pageCount ? null : () => _goTo(_page + 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(HomePalette palette) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.file_x,
              size: 40,
              color: Color(0xB3FFFFFF),
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
            ),
            const SizedBox(height: 18),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
