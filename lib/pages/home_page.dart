import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/curated_book.dart';
import '../widgets/curated/curated_book_cover.dart';
import '../widgets/home/home_design.dart';
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
/// * 书目本身只做推荐，阅读入口是「在书城搜索」——搜索网文的能力完整保留。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.catalog});

  /// 测试可注入固定书单，避免依赖资源加载。
  final CuratedCatalog? catalog;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _allKey = 'all';

  CuratedCatalog _catalog = CuratedCatalog.empty;
  bool _loading = true;
  String _category = _allKey;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final catalog = widget.catalog ?? await CuratedLibrary.load();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: HomePalette.accent,
          backgroundColor: palette.surface,
          onRefresh: () => _load(),
          child: CustomScrollView(
            key: const Key('home_curated'),
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(child: _header(palette)),
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
                SliverToBoxAdapter(child: _todayPick(palette)),
                SliverToBoxAdapter(child: _categoryBar(palette)),
                ..._contentSlivers(palette),
                SliverToBoxAdapter(child: _footer(palette)),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 头部 ----------------

  Widget _header(HomePalette palette) {
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 11
        ? '早上好'
        : hour < 14
        ? '中午好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: HomePalette.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '青茄 · 青少年书房',
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: HomePalette.accentStrong,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  greeting,
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    color: palette.ink,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '今天想读点什么？书单由编辑部挑过一遍。',
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('home-search-button'),
            tooltip: '搜索你想读的书',
            onPressed: _openSearch,
            icon: const Icon(LucideIcons.search),
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

  Widget _todayPick(HomePalette palette) {
    final book = _catalog.pickOfDay();
    if (book == null) return const SizedBox.shrink();
    final category = _catalog.categoryOf(book.category);
    final gradient =
        category?.gradient ?? const [Color(0xFF2FA98C), Color(0xFF1F7F69)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: HomeEntrance(
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
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _Label(
                                  icon: LucideIcons.sun,
                                  text: '今日荐读',
                                ),
                                const SizedBox(width: 6),
                                _Label(text: book.age),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              book.title,
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
                                  '去看看',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.95),
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
    );
  }

  // ---------------- 分类条 ----------------

  Widget _categoryBar(HomePalette palette) {
    final entries = <(String, String)>[
      (_allKey, '全部'),
      for (final category in _catalog.categories)
        (category.key, category.label),
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
            onTap: () => setState(() => _category = key),
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
              onTap: () => _openBook(books[index]),
            ),
          ),
        ),
      ];
    }

    return [
      for (final category in _catalog.categories)
        if (_catalog.booksOf(category.key).isNotEmpty)
          SliverToBoxAdapter(
            child: _categorySection(palette, category),
          ),
    ];
  }

  Widget _categorySection(HomePalette palette, CuratedCategory category) {
    final books = _catalog.booksOf(category.key);
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
                  onTap: () => setState(() => _category = category.key),
                  child: Row(
                    children: [
                      Text(
                        '全部',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: palette.muted,
                        ),
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
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: books.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) => CuratedBookTile(
                book: books[index],
                category: category,
                width: tileWidth,
                onTap: () => _openBook(books[index]),
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
                Icon(
                  LucideIcons.shield_check,
                  size: 14,
                  color: palette.muted,
                ),
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
              '共 ${_catalog.books.length} 本，按类型整理，标注 12+/15+ 适龄提示。'
              '青茄只做推荐与阅读工具，不内置正文；想读哪本，点开后在书城搜索即可。',
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
          Text(
            '书单准备中',
            style: TextStyle(fontSize: 14, color: palette.muted),
          ),
          const SizedBox(height: 6),
          Text(
            '下拉刷新试试，也可以直接搜索想读的书',
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _openSearch,
            child: const Text('去搜索'),
          ),
        ],
      ),
    );
  }

  // ---------------- 跳转 ----------------

  void _openSearch() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
  }

  void _openBook(CuratedBook book) {
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
