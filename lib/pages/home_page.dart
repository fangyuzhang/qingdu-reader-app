import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/curated_book.dart';
import '../services/category_browse_warmup.dart';
import '../services/curated_resolver.dart';
import '../widgets/curated/curated_book_cover.dart';
import '../widgets/home/home_design.dart';
import 'category_browse_page.dart';
import 'curated_book_page.dart';
import 'search_page.dart';

/// 首页：编辑部精选书单（分类推荐）。
///
/// 【青茄重构·重写】原首页拉的是上游网文推荐流（homeProvider），
/// 与「面向青少年、不推荐网络文学」的定位冲突，这里整页换成策划书单：
///
/// * 数据来自打包的 `assets/config/curated_books.json`，不联网、不受上游影响；
/// * 按 7 个类型分组（古典名著/世界文学/历史人文/科普百科/科幻想象/成长青春/诗歌散文）；
/// * 顶部「今日荐读」按日期稳定轮换（同一天固定同一本）；
/// * 【青茄修复·新增】点书直接进阅读器（书单条目先解析成书城书籍）；
///   长按卡片才进荐读页，荐语入口仍然保留。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.catalog, this.categoryLoader});

  /// 测试可注入固定书单，避免依赖资源加载。
  final CuratedCatalog? catalog;

  /// 分类“全部”页的书城加载器；测试注入后可完全离线运行。
  final HomeCategoryBooksLoader? categoryLoader;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _allKey = 'all';

  /// 【青茄修复·听书分类】书单里标了 audio 的书集中在这里，点开优先听。
  static const _listenKey = 'listen';

  CuratedCatalog _catalog = CuratedCatalog.empty;
  bool _loading = true;
  String _category = _allKey;

  /// 首页推荐批次。基础顺序按日期稳定轮换，这个值只响应用户「换一批」。
  int _recommendationBatch = 0;

  /// 正在解析/打开某本书：给一层很轻的遮罩，避免重复点击和闪屏。
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    CuratedResolver.instance.changes.addListener(_onResolutionChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    CuratedResolver.instance.changes.removeListener(_onResolutionChanged);
    super.dispose();
  }

  void _onResolutionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool rotateRecommendations = false}) async {
    final catalog = widget.catalog ?? await CuratedLibrary.load();
    // 先读回上次解析的封面/书源，首帧就能显示真实封面。
    await CuratedResolver.instance.load();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
      if (rotateRecommendations) _recommendationBatch++;
    });
    _prefetchRecommendations();
    _warmCategories();
  }

  /// 首页稳定后悄悄把前 3 个分类的首批抓进缓存。
  ///
  /// 用户点「古典名著 → 全部」时就能同一帧铺满。只在真实运行时预热：
  /// 注入 [HomePage.catalog] 或 [HomePage.categoryLoader] 即测试/离线环境，
  /// 走本地书单，不该发任何请求，也不该留下悬挂的定时器。
  void _warmCategories() {
    if (widget.catalog != null || widget.categoryLoader != null) return;
    final categories = <String, String>{
      for (final category in _catalog.categories)
        if (category.key.isNotEmpty) category.key: category.label,
    };
    if (categories.isEmpty) return;
    unawaited(
      CategoryBrowseWarmup.warm(
        categories: categories,
        shouldContinue: () => mounted,
      ),
    );
  }

  /// 用户点「换一批」或下拉刷新时，只换推荐位，不改变书单数据。
  void _nextRecommendationBatch() {
    setState(() => _recommendationBatch++);
    _prefetchRecommendations();
  }

  void _prefetchRecommendations() {
    if (_catalog.books.isEmpty) return;
    // 当前今日荐读与各分类推荐位排在最前，先补齐首屏封面；其余书随后补。
    final priority = <CuratedBook>[
      ?_catalog.pickOfDay(batch: _recommendationBatch),
      for (final category in _catalog.categories)
        ..._recommendedBooksOf(category),
      ..._catalog.books,
    ];
    unawaited(CuratedResolver.instance.prefetch(priority));
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // 【青茄修复·固定标签栏】分类条固定在顶部，不再随内容滚走；
                // 滑到再深的位置也能随时换分类或听书。
                _topBar(palette),
                Expanded(
                  child: RefreshIndicator(
                    color: HomePalette.accent,
                    backgroundColor: palette.surface,
                    onRefresh: () => _load(rotateRecommendations: true),
                    child: CustomScrollView(
                      key: const Key('home_curated'),
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      slivers: [
                        if (_loading)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 80),
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: HomePalette.accent,
                                ),
                              ),
                            ),
                          )
                        else if (_catalog.books.isEmpty)
                          SliverToBoxAdapter(child: _empty(palette))
                        else ...[
                          ..._homeSlivers(palette),
                          SliverToBoxAdapter(child: _footer(palette)),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 96)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_opening) const _OpeningOverlay(),
        ],
      ),
    );
  }

  // ---------------- 固定顶栏 ----------------

  /// 固定顶栏：搜索按钮 + 分类标签条，全程钉在页面顶部。
  Widget _topBar(HomePalette palette) {
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        border: Border(bottom: BorderSide(color: palette.line, width: 0.6)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Row(
        children: [
          Expanded(child: _categoryBar(palette)),
          const SizedBox(width: 6),
          IconButton(
            key: const Key('home-search-button'),
            tooltip: '搜索你想读的书',
            onPressed: _openSearch,
            icon: const Icon(LucideIcons.search, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: palette.surface,
              foregroundColor: palette.ink,
              side: BorderSide(color: palette.line, width: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 今日荐读 ----------------

  Widget _recommendationHeading(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 14, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '今日精选',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '每天自动轮换，也可以手动换一批',
                  style: TextStyle(fontSize: 11.5, color: palette.muted),
                ),
              ],
            ),
          ),
          TextButton.icon(
            key: const Key('home-recommendation-refresh'),
            onPressed: _nextRecommendationBatch,
            icon: const Icon(LucideIcons.refresh_cw, size: 15),
            label: const Text('换一批'),
            style: TextButton.styleFrom(
              foregroundColor: HomePalette.accent,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayPick(HomePalette palette) {
    final book = _catalog.pickOfDay(batch: _recommendationBatch);
    if (book == null) return const SizedBox.shrink();
    final category = _catalog.categoryOf(book.category);
    final gradient =
        category?.gradient ?? const [Color(0xFF2FA98C), Color(0xFF1F7F69)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: HomeEntrance(
        child: GestureDetector(
          // 长按进荐读页；点一下先看书籍详情与目录，不直接跳正文。
          onLongPress: () => _openCuratedPage(book),
          child: HomePressable(
            key: const Key('home-today-pick'),
            onTap: () => _openBook(book),
            borderRadius: BorderRadius.circular(22),
            semanticLabel: '今日荐读：${book.title}',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradient,
                ),
                boxShadow: [
                  BoxShadow(
                    color: gradient.last.withValues(alpha: 0.28),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -50,
                    top: -60,
                    child: Container(
                      width: 190,
                      height: 190,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CuratedBookCover(
                          book: book,
                          category: category,
                          width: 88,
                          showAge: false,
                          coverUrl: _coverOf(book),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  _Label(icon: LucideIcons.sun, text: '今日荐读'),
                                  const SizedBox(width: 6),
                                  _Label(text: book.age),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                book.title,
                                key: const Key('home-today-pick-title'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  height: 1.2,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.84),
                                  fontSize: 11.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              // 大字号下允许撑开卡片，不再固定高度（会溢出）
                              Text(
                                book.blurb,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontSize: 12.5,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    '查看详情',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.95,
                                      ),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  const Icon(
                                    LucideIcons.arrow_right,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
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

  // ---------------- 分类条 ----------------

  Widget _categoryBar(HomePalette palette) {
    final entries = <(String, String)>[
      (_allKey, '推荐'),
      for (final category in _catalog.categories)
        (category.key, category.label),
      (_listenKey, '听书'),
    ];
    return SizedBox(
      height: 46,
      child: ListView.separated(
        key: const Key('home-category-bar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (key, label) = entries[index];
          final selected = _category == key;
          return GestureDetector(
            key: Key('home-category-$key'),
            onTap: () {
              final category = _catalog.categoryOf(key);
              if (category != null) {
                _openCategory(category);
              } else {
                setState(() => _category = key);
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? HomePalette.accent : palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? HomePalette.accent : palette.line,
                  width: 0.7,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Colors.white : palette.ink,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------- 书单内容 ----------------

  /// 按选中的标签分发内容：推荐（今日荐读 + 分类按钮 + 各分类横滑）、
  /// 单个分类、听书。
  List<Widget> _homeSlivers(HomePalette palette) {
    if (_category == _listenKey) return _listenSlivers(palette);
    if (_category == _allKey) {
      return [
        SliverToBoxAdapter(child: _recommendationHeading(palette)),
        SliverToBoxAdapter(child: _todayPick(palette)),
        SliverToBoxAdapter(child: _categoryButtons(palette)),
        ..._contentSlivers(palette),
      ];
    }
    return _contentSlivers(palette);
  }

  /// 【青茄修复·分类功能按钮】推荐页直接摆出全部分类入口，点一下切到
  /// 对应分类，不用先滚回顶部。
  Widget _categoryButtons(HomePalette palette) {
    final categories = _catalog.categories
        .where((category) => _catalog.booksOf(category.key).isNotEmpty)
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
      child: GridView.count(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.5,
        children: [
          for (final category in categories)
            Material(
              key: Key('home-cat-button-${category.key}'),
              color: palette.surface,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openCategory(category),
                child: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.line, width: 0.6),
                  ),
                  // 【青茄修复】1.8x 字号下按钮高度不够，整体等比缩放防溢出。
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          category.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                          ),
                        ),
                        const SizedBox(height: 1),
                        // 这里的数字只是首页轮换用的本地书单条数，点进「全部」
                        // 还会从书城追加更多，写「精选 N 本」会和目标页对不上。
                        // 不写死数量，避免用户拿它当分类总数。
                        Text(
                          '精选书单 · 查看全部',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 【青茄修复·听书分类】书单里标了 audio 的书：点开优先解析有声源，
  /// 没有音频的书源时退回文字阅读。
  List<Widget> _listenSlivers(HomePalette palette) {
    final audioBooks = _catalog.books
        .where((book) => book.audio)
        .toList(growable: false);
    if (audioBooks.isEmpty) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Text(
                '有声书正在补充中，先去「推荐」挑一本吧',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Text(
            '这些书都有有声版，点开直接听；个别书源缺失时会退回文字阅读。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: palette.muted,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList.separated(
          itemCount: audioBooks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final book = audioBooks[index];
            return CuratedBookRow(
              key: Key('home-listen-row-${book.id}'),
              book: book,
              category: _catalog.categoryOf(book.category),
              coverUrl: _coverOf(book),
              onTap: () => _openBook(book),
              onLongPress: () => _openCuratedPage(book),
            );
          },
        ),
      ),
    ];
  }

  List<CuratedBook> _recommendedBooksOf(CuratedCategory category) =>
      _catalog.recommendationBatchOf(category.key, batch: _recommendationBatch);

  List<Widget> _contentSlivers(HomePalette palette) {
    if (_category != _allKey) {
      final category = _catalog.categoryOf(_category);
      final books = _catalog.booksOf(_category);
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Text(
              category?.desc ?? '',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: palette.muted,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.separated(
            itemCount: books.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => CuratedBookRow(
              book: books[index],
              category: category,
              coverUrl: _coverOf(books[index]),
              onTap: () => _openBook(books[index]),
              onLongPress: () => _openCuratedPage(books[index]),
            ),
          ),
        ),
      ];
    }

    return [
      for (final category in _catalog.categories)
        if (_catalog.booksOf(category.key).isNotEmpty)
          SliverToBoxAdapter(child: _categorySection(palette, category)),
    ];
  }

  Widget _categorySection(HomePalette palette, CuratedCategory category) {
    final books = _recommendedBooksOf(category);
    final width = MediaQuery.sizeOf(context).width;
    final tileWidth = ((width - 20 * 2 - 12 * 2) / 2.6).clamp(96.0, 132.0);
    // 横滑列表高度必须跟随字号：固定 44px 的文字块在 1.8x 字号下会溢出。
    final scaler = MediaQuery.textScalerOf(context);
    final captionHeight =
        8 + scaler.scale(13.5) * 1.3 + 2 + scaler.scale(11) * 1.3 + 6;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: category.gradient,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  category.label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    category.desc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: palette.muted),
                  ),
                ),
                GestureDetector(
                  key: Key('home-category-all-${category.key}'),
                  onTap: () => _openCategory(category),
                  child: Row(
                    children: [
                      Text(
                        '全部',
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                      Icon(
                        LucideIcons.chevron_right,
                        size: 14,
                        color: palette.muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: tileWidth * 4 / 3 + captionHeight,
            child: _CategoryRail(
              key: Key('home-rail-${category.key}'),
              // 滑到末尾后继续右滑，直接进「全部」。阈值按拖动距离累计，
              // 松手即重置，避免轻扫误触。
              onOpenAll: () => _openCategory(category),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: books.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => CuratedBookTile(
                  key: Key('home-recommend-${category.key}-${books[index].id}'),
                  book: books[index],
                  category: category,
                  width: tileWidth,
                  coverUrl: _coverOf(books[index]),
                  onTap: () => _openBook(books[index]),
                  onLongPress: () => _openCuratedPage(books[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.shield_check, size: 14, color: palette.muted),
                const SizedBox(width: 6),
                Text(
                  '关于这份书单',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '共 ${_catalog.books.length} 本编辑精选。首页每天自动轮换推荐，也可点「换一批」；'
              '每个分类先展示 4 本，点「全部」进入书城分类页，可继续加载更多并换一批。'
              '点书先看详情与目录，长按可以看荐语。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
      child: Column(
        children: [
          Icon(LucideIcons.book_open, size: 36, color: palette.line),
          const SizedBox(height: 12),
          Text('书单准备中', style: TextStyle(fontSize: 14, color: palette.muted)),
          const SizedBox(height: 6),
          Text(
            '下拉刷新试试，也可以直接搜索想读的书',
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _openSearch, child: const Text('去搜索')),
        ],
      ),
    );
  }

  // ---------------- 跳转 ----------------

  void _openCategory(CuratedCategory category) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CategoryBrowsePage(
          category: category,
          loader: widget.categoryLoader,
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
  }

  /// 当前这本书解析出的真实封面（未解析/解析失败时为 null → 文字封面）。
  String? _coverOf(CuratedBook book) =>
      CuratedResolver.instance.cached(book.id)?.cover;

  /// 点书：先解析成书城书籍并打开详情与目录；失败回退到搜索页。
  ///
  /// 只有用户在详情页点章节或「开始阅读」后才进入正文。
  Future<void> _openBook(CuratedBook book) async {
    if (_opening) return;
    await openCuratedReading(
      context,
      book,
      onBusy: (busy) {
        if (mounted) setState(() => _opening = busy);
      },
    );
  }

  /// 长按：保留原来的荐读页（荐语 + 同类推荐 + 搜索入口）。
  void _openCuratedPage(CuratedBook book) {
    final category = _catalog.categoryOf(book.category);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CuratedBookPage(
          book: book,
          category: category,
          siblings: _catalog
              .booksOf(book.category)
              .where((b) => b.id != book.id)
              .toList(growable: false),
          categoryOf: _catalog.categoryOf,
        ),
      ),
    );
  }
}

/// 解析/打开书籍时的轻量遮罩：不弹页面、不闪白，只挡住重复点击。
class _OpeningOverlay extends StatelessWidget {
  const _OpeningOverlay();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.08),
          child: Center(
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 18,
                  ),
                ],
              ),
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: HomePalette.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 渐变卡上的小标签（图标 + 文字）。
class _Label extends StatelessWidget {
  const _Label({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 横向书架的「滑到底继续滑 = 查看全部」容器。
///
/// 安卓默认 ClampingScrollPhysics 到头后不再移动，只会持续发
/// [OverscrollNotification]。这里把一次拖动中越过右端的距离累加，达到阈值就
/// 打开分类页并给一次轻震动；松手 / 重新按下都会清零，所以正常滑动不会误触。
class _CategoryRail extends StatefulWidget {
  const _CategoryRail({
    super.key,
    required this.child,
    required this.onOpenAll,
  });

  final Widget child;
  final VoidCallback onOpenAll;

  @override
  State<_CategoryRail> createState() => _CategoryRailState();
}

class _CategoryRailState extends State<_CategoryRail> {
  /// 滑到末尾后再拖约 72dp 才触发：太短会被正常甩动误触，太长又像滑不动。
  static const double _triggerOverscroll = 72;

  double _pull = 0;
  bool _fired = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) return false;
    if (notification is ScrollStartNotification) {
      _pull = 0;
      _fired = false;
    } else if (notification is OverscrollNotification) {
      final atEnd =
          notification.metrics.extentAfter <= 0.5 &&
          notification.metrics.maxScrollExtent > 0;
      if (atEnd && notification.overscroll > 0 && !_fired) {
        _pull += notification.overscroll;
        if (_pull >= _triggerOverscroll) {
          _fired = true;
          HapticFeedback.selectionClick();
          widget.onOpenAll();
        }
      }
    } else if (notification is ScrollEndNotification) {
      _pull = 0;
      _fired = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.child,
    );
  }
}
