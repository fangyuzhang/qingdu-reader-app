import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/ink_annotation.dart';
import '../services/ink_annotation_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import '../widgets/home/home_design.dart';
import '../widgets/reader/annotation/ink_canvas.dart';
import '../widgets/reader/annotation/ink_controller.dart';
import '../widgets/reader/annotation/ink_strokes_painter.dart';
import '../widgets/reader/annotation/ink_toolbar.dart';

/// PDF 固定版式阅读页（第 4 组）＋ 手写批注模式（第 5 组）。
///
/// 与 TXT/EPUB 的流式阅读器（ReaderPage + ReaderChapterLayout）并列的
/// 第三种内容视图：渲染原 PDF 版式，分页天然固定，进度按页码存
/// LibraryStore 历史盒（positionVersion:3）。批注模式下叠加透明
/// [InkCanvas]（只收 stylus，手指穿透翻页），墨迹经 [InkAnnotationStore]
/// 持久化，锚点用 PDFium 逐字符坐标表换算成文本区间。
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

  // ── 批注模式（第 5 组）───────────────────────────────────────────────
  InkController? _ink;
  int _inkPage = 0;
  Timer? _inkDebounce;
  Size _contentSize = Size.zero;

  /// 非批注态的整页墨迹（只读展示）。
  final ValueNotifier<List<InkStroke>> _pageStrokes =
      ValueNotifier<List<InkStroke>>(const []);

  /// 逐页文本缓存（锚点换算用，懒加载）。
  final Map<int, PdfPageRawText?> _textCache = {};

  static const _pdfLayoutVersion = 'pdf-fixed';

  static String _pageKey(int page) => 'pdf:page:$page';

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
      unawaited(_loadPageStrokes(_page));
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
    final newPage = index + 1;
    if (_ink != null) {
      // 批注模式下手指翻页：先落盘当前页墨迹，再载入新页墨迹。
      unawaited(
        _saveInk().then((_) {
          if (mounted) _ensureInk(newPage);
        }),
      );
    }
    setState(() => _page = newPage);
    unawaited(_persistProgress());
    if (_ink == null) unawaited(_loadPageStrokes(newPage));
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
    _inkDebounce?.cancel();
    // 从批注模式直接返回退出（手势/返回键）也要落盘：dispose 没有等待
    // 时机，尽力触发（控制器此刻仍存活，异步链自行完成）。
    if (_ink != null) unawaited(_saveInk());
    _ink?.dispose();
    _pageStrokes.dispose();
    _pageController.dispose();
    unawaited(_doc?.dispose());
    super.dispose();
  }

  /// 某一页的文本 + 逐字符坐标表（PDF 用户坐标系，原点左下、y 向上）。
  Future<PdfPageRawText?> pageText(int pageNumber) async {
    final doc = _doc;
    if (doc == null || pageNumber < 1 || pageNumber > doc.pages.length) {
      return null;
    }
    if (_textCache.containsKey(pageNumber)) return _textCache[pageNumber];
    PdfPageRawText? text;
    try {
      text = await doc.pages[pageNumber - 1].loadText();
    } catch (_) {
      text = null;
    }
    _textCache[pageNumber] = text;
    return text;
  }

  // ── 墨迹存取 ─────────────────────────────────────────────────────────

  Future<void> _loadPageStrokes(int page) async {
    final list = await InkAnnotationStore.instance.loadByChapter(
      widget.bookId,
      _pageKey(page),
    );
    if (!mounted) return;
    _pageStrokes.value = List.unmodifiable([
      for (final annotation in list) ...annotation.strokes,
    ]);
  }

  void _enterAnnotate() {
    _ensureInk(_page);
    setState(() => _barsVisible = false);
  }

  void _ensureInk(int page) {
    final existing = _ink;
    _inkPage = page;
    _ink = InkController(onChanged: _scheduleInkSave);
    _pageStrokes.value = const [];
    InkAnnotationStore.instance
        .loadByChapter(widget.bookId, _pageKey(page))
        .then((list) {
          if (!mounted || _ink == null || _inkPage != page) return;
          final strokes = [
            for (final annotation in list) ...annotation.strokes,
          ];
          _ink!.seed(strokes);
        });
    // 旧控制器同样延迟到摘除后销毁（渲染面冻结防线，见 reader 同名方法）。
    if (existing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => existing.dispose());
    }
    setState(() {});
  }

  Future<void> _exitAnnotate() async {
    _inkDebounce?.cancel();
    await _saveInk();
    if (!mounted) return;
    final controller = _ink;
    _ink = null;
    setState(() => _barsVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => controller?.dispose());
    await _loadPageStrokes(_page);
  }

  void _scheduleInkSave() {
    _inkDebounce?.cancel();
    _inkDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveInk());
    });
  }

  Future<void> _saveInk() async {
    final controller = _ink;
    if (controller == null || _inkPage == 0 || _contentSize == Size.zero) {
      return;
    }
    final key = InkAnnotation.keyFor(
      bookId: widget.bookId,
      chapterId: _pageKey(_inkPage),
      layoutVersion: _pdfLayoutVersion,
    );
    if (controller.strokes.isEmpty) {
      await InkAnnotationStore.instance.delete(key);
      return;
    }
    final existing = (await InkAnnotationStore.instance.loadByChapter(
      widget.bookId,
      _pageKey(_inkPage),
    ))
        .where((a) => a.key == key)
        .firstOrNull;
    final anchor = await _computeAnchor(controller.strokes, _inkPage);
    try {
      await InkAnnotationStore.instance.save(
        InkAnnotation(
          bookId: widget.bookId,
          chapterId: _pageKey(_inkPage),
          format: InkAnnotation.kFormatPdf,
          pageWidth: _contentSize.width,
          pageHeight: _contentSize.height,
          layoutVersion: _pdfLayoutVersion,
          strokes: controller.strokes,
          createdAt:
              existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          startOffset: anchor.$1,
          endOffset: anchor.$2,
          contextBefore: anchor.$3,
          contextAfter: anchor.$4,
          anchorBox: anchor.$5,
        ),
      );
    } catch (_) {
      // 存储不可用不阻断书写；下次编辑仍会整条覆写重试。
    }
  }

  /// 墨迹包围盒 → 命中字符区间与上下文指纹。
  ///
  /// 坐标链：画布（内容区，即页面 contain-fit 的外框）→ 页面渲染矩形
  /// （PdfPageView 按 min 缩放居中）→ PDF 用户坐标（y 翻转）。
  /// 无文本/无命中字符时退化为纯页锚点（offsets/指纹为空）。
  Future<(int?, int?, String, String, InkRect?)> _computeAnchor(
    List<InkStroke> strokes,
    int pageNumber,
  ) async {
    final doc = _doc;
    if (doc == null ||
        pageNumber < 1 ||
        pageNumber > doc.pages.length ||
        _contentSize == Size.zero) {
      return (null, null, '', '', null);
    }
    var left = 1.0, top = 1.0, right = 0.0, bottom = 0.0;
    for (final stroke in strokes) {
      for (final p in stroke.points) {
        left = p.x < left ? p.x : left;
        top = p.y < top ? p.y : top;
        right = p.x > right ? p.x : right;
        bottom = p.y > bottom ? p.y : bottom;
      }
    }
    if (right < left || bottom < top) return (null, null, '', '', null);

    final text = await pageText(pageNumber);
    if (text == null || text.fullText.isEmpty || text.charRects.isEmpty) {
      return (null, null, '', '', null);
    }
    final page = doc.pages[pageNumber - 1];
    final scale = _contentSize.width / page.width <
            _contentSize.height / page.height
        ? _contentSize.width / page.width
        : _contentSize.height / page.height;
    final pageW = page.width * scale;
    final pageH = page.height * scale;
    final originX = (_contentSize.width - pageW) / 2;
    final originY = (_contentSize.height - pageH) / 2;

    // 画布归一化墨迹盒 → PDF 用户坐标（含 6pt 容差），y 翻转。
    double toPdfX(double nx) =>
        ((_contentSize.width * nx - originX) / scale);
    double toPdfY(double ny) =>
        page.height - ((_contentSize.height * ny - originY) / scale);
    final inkLeft = toPdfX(left) - 6;
    final inkRight = toPdfX(right) + 6;
    final inkTop = toPdfY(top) + 6;
    final inkBottom = toPdfY(bottom) - 6;

    var start = -1;
    var end = -1;
    var boxLeft = double.infinity, boxTop = -double.infinity;
    var boxRight = -double.infinity, boxBottom = double.infinity;
    for (var i = 0; i < text.charRects.length; i++) {
      final r = text.charRects[i];
      if (r.right < inkLeft || r.left > inkRight) continue;
      if (r.top < inkBottom || r.bottom > inkTop) continue;
      if (start < 0) start = i;
      end = i + 1;
      boxLeft = r.left < boxLeft ? r.left : boxLeft;
      boxTop = r.top > boxTop ? r.top : boxTop;
      boxRight = r.right > boxRight ? r.right : boxRight;
      boxBottom = r.bottom < boxBottom ? r.bottom : boxBottom;
    }
    if (start < 0 || end <= start) return (null, null, '', '', null);

    final (before, after) = InkAnnotation.contextOf(
      text.fullText,
      start,
      end,
    );
    // 锚点盒：字符盒并集 → 画布归一化（存展示坐标系，y 向下）。
    double toCanvasX(double px) => ((px * scale + originX) / _contentSize.width)
        .clamp(0.0, 1.0);
    double toCanvasY(double py) =>
        1 - ((page.height - py) * scale + originY) / _contentSize.height;
    final anchorBox = InkRect(
      left: toCanvasX(boxLeft),
      top: toCanvasY(boxTop),
      right: toCanvasX(boxRight),
      bottom: toCanvasY(boxBottom),
    );
    return (start, end, before, after, anchorBox);
  }

  // ── 布局 ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final annotating = _ink != null;
    return Scaffold(
      backgroundColor: const Color(0xFF3B403C),
      body: _error != null
          ? _errorView(palette)
          : Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // 批注模式下点击不翻页/不切工具栏（防误触；翻页用手势划）。
                    onTapUp: annotating ? null : (d) => _handleTap(d, context),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _contentSize = constraints.biggest;
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: _doc == null
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                        ),
                                      )
                                    : ScrollConfiguration(
                                        // 翻页手势恒只认手指：笔永远留给墨迹
                                        // 画布（阅读态用笔翻页走点击区）。
                                        // 批注态与非批注态保持同一棵子树——
                                        // 随模式切换重包 dragDevices 会在 MIUI
                                        // 上把渲染面冻结成白屏（pdfrx 纹理随
                                        // PageView 子树重建失效，实测复现）。
                                        behavior: ScrollConfiguration.of(
                                          context,
                                        ).copyWith(
                                          dragDevices: const {
                                            PointerDeviceKind.touch,
                                          },
                                        ),
                                        child: PageView.builder(
                                          key: const Key('pdf-page-view'),
                                          controller: _pageController,
                                          itemCount: _pageCount,
                                          onPageChanged: _onPageChanged,
                                          itemBuilder: (context, index) =>
                                              PdfPageView(
                                            document: _doc,
                                            pageNumber: index + 1,
                                            backgroundColor: Colors.white,
                                          ),
                                        ),
                                      ),
                              ),
                              // 只读墨迹（非批注态）。
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: ValueListenableBuilder(
                                    valueListenable: _pageStrokes,
                                    builder: (context, strokes, _) =>
                                        CustomPaint(
                                      foregroundPainter: InkStrokesPainter(
                                        strokes: strokes,
                                        canvasWidth: _contentSize.width,
                                        repaint: _pageStrokes,
                                      ),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),
                              if (annotating)
                                Positioned.fill(
                                  child: InkCanvas(controller: _ink!),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (_barsVisible && _doc != null && !annotating) ...[
                  _topBar(palette),
                  _bottomBar(palette),
                ],
                if (annotating && _ink != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: InkToolbar(
                      controller: _ink!,
                      onDone: () => unawaited(_exitAnnotate()),
                    ),
                  ),
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
              key: const Key('pdf-annotate'),
              icon: const Icon(LucideIcons.pen_line, color: Colors.white),
              tooltip: '批注',
              onPressed: _enterAnnotate,
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
