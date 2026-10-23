import 'dart:async';

import '../models/media_item.dart';
import 'api_client.dart';
import 'category_browse_cache.dart';

/// 分类「全部」页的首批预热。
///
/// 【青茄性能·新增】分类页首批要并发搜 5 个关键词，上游最快那条也要几百
/// 毫秒，用户点「古典名著 → 全部」时先看到的是骨架/旧书单。首页渲染完、
/// 用户还在挑书的时候把最常点的前几个分类的首批悄悄抓下来写进
/// [CategoryBrowseCache]，再点进去就是缓存命中：同一帧铺满，零等待。
///
/// 只在真实运行（首页没有注入 loader）时调用，测试与离线环境不会发请求。
class CategoryBrowseWarmup {
  CategoryBrowseWarmup._();

  /// 与分类页一致的每页条数，缓存键（分类 + 偏移）才会对得上。
  static const pageSize = 10;

  /// 每个分类并发搜索的关键词；首个是分类名本身。
  static const queries = <String, List<String>>{
    'classic': ['古典名著', '中国古典文学', '古典小说', '四大名著', '古代经典'],
    'world': ['世界文学', '世界名著', '外国文学', '经典文学', '外国小说'],
    'history': ['历史人文', '中国历史', '世界历史', '历史读物', '历史小说'],
    'science': ['科普百科', '科普读物', '自然科学', '科学启蒙', '科学知识'],
    'scifi': ['科幻想象', '科幻小说', '科学幻想', '未来世界', '太空冒险'],
    'growth': ['成长青春', '青春文学', '成长小说', '青少年文学', '校园小说'],
    'poetry': ['诗歌散文', '现代诗歌', '散文集', '古诗词', '诗意生活'],
  };

  static List<String> queriesFor(String categoryKey, String label) =>
      queries[categoryKey] ?? [label];

  /// 首页稳定下来再动手，别和首屏封面抢带宽。
  static const defaultDelay = Duration(milliseconds: 1500);

  /// 预热的分类数：前 3 个（古典名著 / 世界文学 / 历史人文）覆盖绝大多数点击。
  static const defaultLimit = 3;

  /// 顺序预热 [categories]（键 → 显示名）的前 [limit] 个，已在缓存且未过期
  /// 的直接跳过。[shouldContinue] 用来在页面销毁后停下。
  static Future<void> warm({
    required Map<String, String> categories,
    int limit = defaultLimit,
    Duration delay = defaultDelay,
    Future<List<MediaItem>> Function(String query, int offset)? loader,
    CategoryBrowseCache? cache,
    bool Function()? shouldContinue,
  }) async {
    if (categories.isEmpty || limit <= 0) return;
    bool alive() => shouldContinue?.call() ?? true;
    final store = cache ?? CategoryBrowseCache.instance;
    final fetch = loader ?? _search;
    await Future<void>.delayed(delay);
    if (!alive()) return;
    // 先读回磁盘缓存，否则写入会被随后的加载覆盖。
    await store.load();
    if (!alive()) return;
    var warmed = 0;
    for (final entry in categories.entries) {
      if (warmed >= limit || !alive()) return;
      if (store.read(entry.key, 0) != null && store.isFresh(entry.key, 0)) {
        warmed++;
        continue;
      }
      final batch = await _fetchFirstBatch(
        fetch,
        queriesFor(entry.key, entry.value),
      );
      if (!alive()) return;
      // 整个分类一条都没回来（通常是网络抖动）：跳过，不写空缓存。
      if (batch.isEmpty) continue;
      store.write(entry.key, 0, batch);
      warmed++;
    }
  }

  static Future<List<MediaItem>> _search(String query, int offset) async {
    final tabs = await ApiClient.instance.searchTabs(
      query,
      tabType: 3,
      offset: offset,
    );
    return [for (final tab in tabs) ...tab.items];
  }

  /// 并发搜索一个分类首批需要的所有关键词，按返回顺序合并去重。
  ///
  /// 去重规则与分类页完全一致：同 id 或同名（上游不同关键词会给出不同 id）
  /// 都算同一本书，否则预热出来的批次和页面自己拉的对不上。
  static Future<List<MediaItem>> _fetchFirstBatch(
    Future<List<MediaItem>> Function(String query, int offset) fetch,
    List<String> queries,
  ) async {
    final merged = <MediaItem>[];
    final ids = <String>{};
    final titles = <String>{};
    await Future.wait([
      for (final query in queries)
        () async {
          List<MediaItem> page;
          try {
            page = await fetch(query, 0);
          } catch (_) {
            return;
          }
          for (final item in page) {
            if (item.id.isEmpty) continue;
            if (item.kind != 'book' && item.kind != 'audio') continue;
            if (!ids.add(item.id)) continue;
            final title =
                item.title.replaceAll(RegExp(r'\s+'), '').toLowerCase();
            if (!titles.add(title)) continue;
            merged.add(item);
          }
        }(),
    ]);
    return merged;
  }
}
