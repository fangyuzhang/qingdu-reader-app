import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/curated_book.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/category_browse_cache.dart';
import '../services/category_browse_warmup.dart';
import '../services/curated_resolver.dart';
import '../widgets/home/home_design.dart';
import '../widgets/media_card.dart';
import 'detail_page.dart';

/// Loads one upstream search page for the category browser.
///
/// The production implementation searches several related phrases so a
/// category is not limited to its six hand-picked entries. Tests inject a
/// deterministic implementation and never touch the network.
typedef HomeCategoryBooksLoader = Future<List<MediaItem>> Function(
    String query, int offset);

/// 分类「全部」浏览视图：不再作为独立页面跳转，而是内嵌在首页的
/// PageView 里（首页顶部分类条常驻并随页面切换同步高亮）。
/// 混入 AutomaticKeepAliveClientMixin：滑走的分类页保留加载结果，
/// 滑回来不重新拉取。
class CategoryBrowseView extends StatefulWidget {
  const CategoryBrowseView({super.key, required this.category, this.loader});

  final CuratedCategory category;
  final HomeCategoryBooksLoader? loader;

  @override
  State<CategoryBrowseView> createState() => _CategoryBrowseViewState();
}

class _CategoryBrowseViewState extends State<CategoryBrowseView>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 10;
  final List<MediaItem> _items = [];
  final Set<String> _seenIds = {};
  final Set<String> _titleKeys = {};
  bool _loading = true;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _pageIndex = 0;
  int _generation = 0;

  CategoryBrowseCache get _cache => CategoryBrowseCache.instance;

  /// 冷启动第一次进分类时先用书单里已解析好的书铺首屏。
  ///
  /// 这些条目来自本地 assets 与解析缓存，同步可取，不需要等任何网络；
  /// 上游结果回来后整批覆盖，所以只影响「第一眼」的等待感。
  List<MediaItem> _seedItems() {
    final books = CuratedLibrary.current.booksOf(widget.category.key);
    final seeded = <MediaItem>[];
    for (final book in books) {
      final resolved = CuratedResolver.instance.cached(book.id);
      if (resolved != null) seeded.add(resolved.toMediaItem());
    }
    return seeded;
  }

  /// 关键词表与首页预热共用一份，避免两处漂移导致预热白做。
  List<String> get _searchQueries => CategoryBrowseWarmup.queriesFor(
        widget.category.key,
        widget.category.label,
      );

  @override
  void initState() {
    super.initState();
    unawaited(_loadBatch());
  }

  Future<List<MediaItem>> _loadPage(String query, int offset) async {
    final loader = widget.loader;
    if (loader != null) return loader(query, offset);
    final tabs = await ApiClient.instance.searchTabs(
      query,
      tabType: 3,
      offset: offset,
    );
    return [for (final tab in tabs) ...tab.items];
  }

  Future<List<MediaItem>> _safeLoadPage(String query, int offset) async {
    try {
      return await _loadPage(query, offset);
    } catch (_) {
      return const [];
    }
  }

  /// 并发搜索这一页需要的所有关键词，并按「谁先返回谁先上屏」合并。
  ///
  /// 5 个关键词是并行的，但上游最快的那条通常只需几百毫秒。以前要等
  /// 全部返回才渲染，表现为固定两秒白屏；现在每回来一条就通过
  /// [onPartial] 交给页面先画出来。
  Future<List<MediaItem>> _fetchBatch(
    int pageIndex, {
    void Function(List<MediaItem> partial)? onPartial,
  }) async {
    final offset = pageIndex * _pageSize;
    final result = <MediaItem>[];
    final batchIds = <String>{};
    await Future.wait([
      for (final query in _searchQueries)
        _safeLoadPage(query, offset).then((page) {
          final fresh = <MediaItem>[];
          for (final item in page) {
            if (item.id.isEmpty || !_supported(item.kind)) continue;
            if (!batchIds.add(item.id)) continue;
            fresh.add(item);
          }
          if (fresh.isEmpty) return;
          result.addAll(fresh);
          onPartial?.call(fresh);
        }),
    ]);
    return result;
  }

  static bool _supported(String kind) => kind == 'book' || kind == 'audio';

  void _append(List<MediaItem> batch) {
    for (final item in batch) {
      if (_addsNew(item)) _items.add(item);
    }
  }

  /// 是否确实是一本新书：同 id 或同名（上游不同关键词会给出不同 id）都算重复。
  bool _addsNew(MediaItem item) {
    if (item.id.isEmpty) return false;
    final title = _titleKey(item);
    if (_titleKeys.contains(title)) return false;
    _seenIds.add(item.id);
    _titleKeys.add(title);
    return true;
  }

  static String _titleKey(MediaItem item) =>
      item.title.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// 首屏结果追加式合入：缓存/本地兜底条目留在原位，新结果补在后面。
  ///
  /// 以前这里整体替换，整片格子会在同一帧换一遍（封面重新解码、滚动位置
  /// 跳动），看起来就是「什么都没点它自己刷新了一下」。追加则只增不改。
  void _adopt(List<MediaItem> batch) {
    for (final item in batch) {
      if (_addsNew(item)) _items.add(item);
    }
  }

  /// 用一批结果整体替换当前网格（缓存先渲染，随后被新结果覆盖）。
  void _showBatch(List<MediaItem> batch) {
    _items
      ..clear()
      ..addAll(batch);
    _seenIds
      ..clear()
      ..addAll(batch.map((item) => item.id));
    _titleKeys
      ..clear()
      ..addAll(batch.map(_titleKey));
  }

  Future<void> _loadBatch({bool advance = false, bool force = false}) async {
    if (_loadingMore) return;
    final generation = ++_generation;
    var targetPage = advance ? _pageIndex + 1 : 0;
    // 缓存是先同步读内存的：命中就能在同一帧把书铺出来。
    await _cache.load();
    if (!mounted || generation != _generation) return;
    // 【修复·下拉刷新两次跳动】换一批（advance）时不再先展示缓存批次：
    // 旧逻辑缓存批次先上屏、网络批次回来再整体替换一次，用户看到内容
    // 连跳两次，像「刷新了两遍」。现在保持当前内容不动，网络批次回来
    // 一次性替换（RefreshIndicator 的指示器已提供加载反馈）。
    final cached = advance
        ? null
        : _cache.read(widget.category.key, targetPage);
    final fresh = cached != null &&
        !force &&
        _cache.isFresh(widget.category.key, targetPage);
    setState(() {
      _error = null;
      if (cached != null) {
        _showBatch(cached);
        _pageIndex = targetPage;
        _hasMore = true;
        _loading = false;
        _refreshing = !fresh;
      } else {
        if (advance) {
          // 换一批：不清空、不转圈，静默等网络批次一次性替换。
          _loading = false;
          _refreshing = true;
        } else {
          final seeded = _seedItems();
          if (seeded.isNotEmpty) {
            _showBatch(seeded);
            _loading = false;
            _refreshing = true;
          } else {
            _loading = true;
            _refreshing = false;
          }
        }
      }
    });
    // 缓存还新鲜就不打扰上游：这一批直接秒开。
    if (fresh) return;
    var batch = await _fetchBatch(
      targetPage,
      onPartial: (partial) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _loading = false;
          _append(partial);
        });
      },
    );
    // After the last page, a refresh wraps back to the first batch instead of
    // leaving the user on an empty screen forever.
    if (advance && targetPage > 0 && batch.isEmpty) {
      targetPage = 0;
      batch = await _fetchBatch(targetPage);
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      _refreshing = false;
      _pageIndex = targetPage;
      if (batch.isNotEmpty) {
        // 「换一批」是用户主动要的替换；首次铺屏则是追加，屏幕不闪。
        if (advance) {
          _showBatch(batch);
        } else {
          _adopt(batch);
        }
        _cache.write(widget.category.key, targetPage, batch);
        _hasMore = true;
        _error = null;
      } else {
        _hasMore = false;
        _error = '书城暂时没有返回更多书籍，请稍后重试';
      }
    });
  }

  Future<void> _changeBatch() => _loadBatch(advance: true, force: true);

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = ++_generation;
    final next = _pageIndex + 1;
    await _cache.load();
    if (!mounted || generation != _generation) return;
    final cached = _cache.read(widget.category.key, next);
    if (cached != null) {
      // 下一批以前拉过：先追加，用户立刻看到更多书。
      setState(() {
        _append(cached);
        _pageIndex = next;
        _error = null;
      });
      if (_cache.isFresh(widget.category.key, next)) return;
    }
    setState(() => _loadingMore = true);
    final batch = await _fetchBatch(next);
    if (!mounted || generation != _generation) return;
    var added = 0;
    setState(() {
      for (final item in batch) {
        if (_addsNew(item)) {
          _items.add(item);
          added++;
        }
      }
      if (batch.isNotEmpty) {
        _cache.write(widget.category.key, next, batch);
      }
      _pageIndex = next;
      _loadingMore = false;
      _hasMore = added > 0 || (batch.isEmpty && cached != null);
    });
  }

  void _open(MediaItem item) => openBookDetail(context, item);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final palette = HomePalette.of(context);
    return RefreshIndicator(
      color: HomePalette.accent,
      backgroundColor: palette.surface,
      onRefresh: _changeBatch,
      child: CustomScrollView(
        key: const Key('category-books-scroll'),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.category.desc,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.55,
                            color: palette.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _loading
                              ? '正在从书城加载更多书籍…'
                              : _refreshing
                                  ? '已载入 ${_items.length} 本 · 正在更新'
                                  : '已载入 ${_items.length} 本',
                          key: const Key('category-loaded-count'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: const Key('category-change-batch'),
                    onPressed: _loading ? null : _changeBatch,
                    icon: const Icon(LucideIcons.shuffle, size: 15),
                    label: const Text('换一批'),
                    style: TextButton.styleFrom(
                      foregroundColor: HomePalette.accent,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null && _items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.cloud_off,
                        size: 38,
                        color: palette.line,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: palette.muted),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const Key('category-retry'),
                        onPressed: _changeBatch,
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              sliver: SliverGrid.builder(
                itemCount: _items.length,
                gridDelegate: mediaGridDelegateFor(context),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return MediaCard(
                    key: Key('category-book-${item.id}'),
                    item: item,
                    showScore: true,
                    onTap: () => _open(item),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                child: Center(
                  child: _loadingMore
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _hasMore
                          ? OutlinedButton.icon(
                              key: const Key('category-load-more'),
                              onPressed: _loadMore,
                              icon: const Icon(LucideIcons.plus, size: 15),
                              label: const Text('加载更多'),
                            )
                          : Text(
                              '这一批已经到底，点「换一批」继续发现',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
