import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// 分类浏览页的批次缓存（内存 + SharedPreferences）。
///
/// 【青茄性能·新增】分类页要凑齐一批书，得并发搜索 5 个相关关键词，
/// 上游单次搜索常在 0.5–2 秒，于是每次点进「古典名著 / 世界文学…」
/// 都先看两秒转圈。这里把每个（分类, 偏移）批次缓存下来：
///
/// * 缓存新鲜（[ttl] 内）时直接渲染，完全不再请求上游；
/// * 缓存过时仍先渲染，随后后台刷新（stale-while-revalidate）；
/// * 持久化到 SharedPreferences，冷启动后第二次进来同样秒开。
class CategoryBrowseCache {
  CategoryBrowseCache._();

  static final CategoryBrowseCache instance = CategoryBrowseCache._();

  static const prefsKey = 'category_browse_cache_v1';

  /// 超过这个时长视为过时：照旧先渲染，但会重新拉一次。
  static const ttl = Duration(hours: 6);

  /// 最多保留多少批（分类 × 偏移），避免 SharedPreferences 无限膨胀。
  static const maxEntries = 24;

  final Map<String, _CachedBatch> _entries = {};
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  Zone _writesZone = Zone.current;

  /// 缓存键：分类 + 页偏移。
  static String keyOf(String categoryKey, int offset) => '$categoryKey@$offset';

  /// 从磁盘读回缓存（幂等，多次调用共享同一次读取）。
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _read();
  }

  Future<void> _read() async {
    _dropStaleWriteChain();
    await _writes;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final batch = _CachedBatch.fromJson(Map<String, dynamic>.from(value));
        if (batch.items.isNotEmpty) _entries[key] = batch;
      });
      _prune();
    } catch (_) {
      // 缓存损坏/插件缺失都不影响使用：当作没有缓存，重新请求。
    } finally {
      _loaded = true;
      _loading = null;
    }
  }

  /// 同步取缓存；未命中返回 null。
  List<MediaItem>? read(String categoryKey, int offset) {
    final batch = _entries[keyOf(categoryKey, offset)];
    if (batch == null || batch.items.isEmpty) return null;
    return batch.items;
  }

  /// 缓存是否仍在 [ttl] 内（可以完全不请求上游）。
  bool isFresh(String categoryKey, int offset, {DateTime? now}) {
    final batch = _entries[keyOf(categoryKey, offset)];
    return batch != null && batch.isFresh(now ?? DateTime.now());
  }

  /// 写入一批新结果（同步更新内存，异步落盘）。
  void write(
    String categoryKey,
    int offset,
    List<MediaItem> items, {
    DateTime? at,
  }) {
    if (items.isEmpty) return;
    _entries[keyOf(categoryKey, offset)] = _CachedBatch(
      at: (at ?? DateTime.now()).millisecondsSinceEpoch,
      items: List<MediaItem>.unmodifiable(items),
    );
    _prune();
    unawaited(_persist());
  }

  /// 只保留最新的 [maxEntries] 批。
  void _prune() {
    if (_entries.length <= maxEntries) return;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => b.value.at.compareTo(a.value.at));
    for (final entry in ordered.skip(maxEntries)) {
      _entries.remove(entry.key);
    }
  }

  /// 与 [SearchHistoryStore] 同一套 zone 处理：widget test 的 fake async
  /// zone 之间共享写队列会永久挂起，这里跨 zone 时直接丢弃旧链。
  void _dropStaleWriteChain() {
    if (!identical(Zone.current, _writesZone)) {
      _writes = Future<void>.value();
      _writesZone = Zone.current;
    }
  }

  Future<void> _persist() {
    _dropStaleWriteChain();
    return _writes = _writes.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(
          prefsKey,
          jsonEncode({
            for (final entry in _entries.entries)
              entry.key: entry.value.toJson(),
          }),
        );
      } catch (_) {
        // 落盘失败只影响下次启动的首屏，不影响本次会话。
      }
    });
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _loaded = false;
    _loading = null;
    _writes = Future<void>.value();
    _writesZone = Zone.current;
  }
}

class _CachedBatch {
  const _CachedBatch({required this.at, required this.items});

  /// 写入时间（epoch 毫秒）。
  final int at;
  final List<MediaItem> items;

  bool isFresh(DateTime now) =>
      at > 0 &&
      now.millisecondsSinceEpoch - at <= CategoryBrowseCache.ttl.inMilliseconds;

  Map<String, dynamic> toJson() => {
    'at': at,
    'items': [for (final item in items) item.toJson()],
  };

  static _CachedBatch fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = <MediaItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final item = MediaItemJson.fromJson(Map<String, dynamic>.from(raw));
        if (item != null) items.add(item);
      }
    }
    return _CachedBatch(
      at: int.tryParse('${json['at']}') ?? 0,
      items: List<MediaItem>.unmodifiable(items),
    );
  }
}
