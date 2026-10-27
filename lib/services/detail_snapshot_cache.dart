import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

/// 详情页首屏快照：上游 detail 载荷 + 整本目录。
///
/// 【轻读性能·新增】详情页原先必须等 detail 与 directory 两个请求都回来
/// 才把正文区铺出来，实机上要等 1 秒左右；第二次进同一本书也一样，因为
/// 什么也没存。这里把上一次的结果落到加密 Hive 盒里：
///
/// * 命中且新鲜（[ttl] 内）：同帧渲染，后台不再请求；
/// * 命中但过时：先渲染旧快照，随后静默刷新（stale-while-revalidate）；
/// * 未命中：照旧走网络，完成后写入，下次进来即秒开。
///
/// 只缓存详情页自己的数据，章节正文仍由 [ChapterCacheStore] 负责。
class DetailSnapshot {
  final Map<String, dynamic>? detail;
  final List<Chapter> chapters;

  /// 写入时间（epoch 毫秒）。
  final int at;

  const DetailSnapshot({
    required this.detail,
    required this.chapters,
    required this.at,
  });

  bool isFresh(DateTime now) =>
      at > 0 &&
      now.millisecondsSinceEpoch - at <= DetailSnapshotCache.ttl.inMilliseconds;
}

class DetailSnapshotCache {
  DetailSnapshotCache({HiveInterface? hive, this.keyProvider})
    : _hive = hive ?? Hive;

  static final DetailSnapshotCache instance = DetailSnapshotCache();

  static const boxName = 'detail_snapshot_v1';

  /// 超过这个时长视为过时：照旧先渲染，但会重新拉一次。
  static const ttl = Duration(hours: 12);

  /// 最多保留多少本书的快照，避免盒子无限增长。
  static const maxEntries = 16;

  final HiveInterface _hive;
  final SecureKeyProvider? keyProvider;
  final Map<String, DetailSnapshot> _entries = {};
  bool _loaded = false;
  Future<void>? _loading;
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();
  Zone _writesZone = Zone.current;

  /// 从磁盘读回快照（幂等）。盒子打不开时退化为纯内存缓存。
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _read();
  }

  Future<void> _read() async {
    try {
      final box = await _box();
      for (final key in box.keys) {
        if (key is! String) continue;
        final snapshot = _decode(box.get(key));
        if (snapshot == null) continue;
        // 盒子打开前已经写进内存的那条更新，别被盘上的旧记录盖回去。
        final existing = _entries[key];
        if (existing != null && existing.at >= snapshot.at) continue;
        _entries[key] = snapshot;
      }
      _prune();
    } catch (_) {
      // 加密密钥缺失或存储损坏都不影响使用：当作没有快照，走网络。
    } finally {
      _loaded = true;
      _loading = null;
    }
  }

  /// 同步取快照；未命中返回 null。
  DetailSnapshot? read(String bookId) {
    if (bookId.isEmpty) return null;
    return _entries[bookId];
  }

  /// 快照是否仍在 [ttl] 内。
  bool isFresh(String bookId, {DateTime? now}) {
    final snapshot = read(bookId);
    return snapshot != null && snapshot.isFresh(now ?? DateTime.now());
  }

  /// 写入一本书的快照（同步更新内存，异步落盘）。
  void write(
    String bookId, {
    required Map<String, dynamic>? detail,
    required List<Chapter> chapters,
  }) {
    if (bookId.isEmpty) return;
    if (detail == null && chapters.isEmpty) return;
    _entries[bookId] = DetailSnapshot(
      detail: detail,
      chapters: List<Chapter>.unmodifiable(chapters),
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _prune();
    unawaited(_persist(bookId));
  }

  void _prune() {
    if (_entries.length <= maxEntries) return;
    // 同一毫秒写入的多条 at 相同，用插入顺序兜底，否则淘汰谁是不确定的。
    final ordered =
        [
          for (final (index, entry) in _entries.entries.indexed)
            (index: index, key: entry.key, at: entry.value.at),
        ]..sort((a, b) {
          final byTime = a.at.compareTo(b.at);
          return byTime != 0 ? byTime : a.index.compareTo(b.index);
        });
    for (final entry in ordered.take(ordered.length - maxEntries)) {
      _entries.remove(entry.key);
    }
  }

  /// 与 [CategoryBrowseCache] 同一套 zone 处理：widget test 的 fake async
  /// zone 之间共享写队列会永久挂起，这里跨 zone 时直接丢弃旧链。
  void _dropStaleWriteChain() {
    if (!identical(Zone.current, _writesZone)) {
      _writes = Future<void>.value();
      _writesZone = Zone.current;
    }
  }

  Future<void> _persist(String bookId) {
    _dropStaleWriteChain();
    return _writes = _writes.then((_) async {
      // 盒子只在启动预热时打开；没打开过就只留内存，不在首帧路径上碰存储。
      if (_opening == null) return;
      final snapshot = _entries[bookId];
      if (snapshot == null) return;
      try {
        final box = await _box();
        await box.put(bookId, _encode(snapshot));
      } catch (_) {
        // 落盘失败只影响下次启动的首屏，不影响本次会话。
      }
    });
  }

  Future<Box<dynamic>> _box() => _opening ??= EncryptedHive.openBox<dynamic>(
    _hive,
    boxName,
    keys: keyProvider,
  );

  /// 等待挂起的落盘完成（测试用：写完立刻重开盒子读出结果）。
  @visibleForTesting
  Future<void> flush() => _writes;

  static Map<String, dynamic> _encode(DetailSnapshot snapshot) => {
    'at': snapshot.at,
    if (snapshot.detail != null) 'detail': snapshot.detail,
    'chapters': [
      for (final chapter in snapshot.chapters)
        {
          'itemId': chapter.itemId,
          'title': chapter.title,
          'volumeName': chapter.volumeName,
          'version': chapter.version,
          'wordCount': ?chapter.wordCount,
          'chapterType': ?chapter.chapterType,
          'trailer': ?(chapter.trailer ? true : null),
          'highlight': ?(chapter.highlight ? true : null),
          'disabled': ?(chapter.disabled ? true : null),
          'newlyUpdate': ?(chapter.newlyUpdate ? true : null),
        },
    ],
  };

  static DetailSnapshot? _decode(dynamic raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! int || at <= 0) return null;
    final rawChapters = raw['chapters'];
    final chapters = <Chapter>[];
    if (rawChapters is List) {
      for (final value in rawChapters) {
        if (value is! Map || value['itemId'] is! String) continue;
        final id = value['itemId'] as String;
        if (id.isEmpty) continue;
        chapters.add(
          Chapter(
            itemId: id,
            title: value['title']?.toString() ?? '',
            volumeName: value['volumeName']?.toString() ?? '',
            version: value['version']?.toString() ?? '',
            wordCount: value['wordCount'] is int
                ? value['wordCount'] as int
                : null,
            chapterType: value['chapterType'] is int
                ? value['chapterType'] as int
                : null,
            trailer: value['trailer'] == true,
            highlight: value['highlight'] == true,
            disabled: value['disabled'] == true,
            newlyUpdate: value['newlyUpdate'] == true,
          ),
        );
      }
    }
    final detail = raw['detail'];
    final detailMap = detail is Map ? Map<String, dynamic>.from(detail) : null;
    if (detailMap == null && chapters.isEmpty) return null;
    return DetailSnapshot(
      detail: detailMap,
      chapters: List<Chapter>.unmodifiable(chapters),
      at: at,
    );
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _loaded = false;
    _loading = null;
    _opening = null;
    _writes = Future<void>.value();
    _writesZone = Zone.current;
  }
}
