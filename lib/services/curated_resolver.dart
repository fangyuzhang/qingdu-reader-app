import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/curated_book.dart';
import '../models/media_item.dart';
import 'api_client.dart';

/// 书单条目解析出来的「上游可读书籍」。
///
/// 【青茄修复·新增】首页点书要能直接进阅读器，就必须先把《小王子》这类
/// 书单条目对到书城里真实存在的 [MediaItem]。这里把结果落成一个小对象，
/// 既方便 JSON 持久化，也避免每次进首页都重新搜索。
@immutable
class CuratedResolution {
  const CuratedResolution({
    required this.id,
    required this.title,
    required this.author,
    required this.cover,
    required this.kind,
    required this.at,
  });

  /// 上游书籍 ID（DetailPage / 阅读器认这个）。
  final String id;
  final String title;
  final String author;
  final String cover;

  /// 'book'（书单只会解析出小说/图书）。
  final String kind;

  /// 解析时间（epoch 毫秒），用于 7 天过期判断。
  final int at;

  /// 还原成详情页/阅读器需要的条目。
  MediaItem toMediaItem() => MediaItem(
    id: id,
    title: title,
    cover: cover,
    author: author,
    badge: '',
    ep: '',
    kind: kind.isEmpty ? 'book' : kind,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'cover': cover,
    'kind': kind,
    'at': at,
  };

  static CuratedResolution fromJson(Map<String, dynamic> json) =>
      CuratedResolution(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        author: json['author']?.toString() ?? '',
        cover: json['cover']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'book',
        at: int.tryParse('${json['at']}') ?? 0,
      );
}

/// 书单条目 → 书城书籍的解析器（单例）。
///
/// 规则：
/// * 只在 SharedPreferences 里缓存结果，7 天后视为过期重新解析；
/// * 解析失败返回 null（不抛异常），由页面回退到搜索页；
/// * 搜索函数可注入，测试里不联网。
class CuratedResolver {
  CuratedResolver._();

  static final CuratedResolver instance = CuratedResolver._();

  static const prefsKey = 'curated_resolution_v1';

  /// 缓存有效期：书城书源会变（下架/换源），太久的结果宁可重查。
  static const ttl = Duration(days: 7);

  final Map<String, CuratedResolution> _entries = {};
  final Map<String, Future<CuratedResolution?>> _inflight = {};

  bool _loaded = false;

  /// 【青茄修复·新增】解析出新条目后自增，首页据此重绘真实封面。
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// 可注入的搜索实现：默认把各 tab 的结果拍平成一个列表。
  Future<List<MediaItem>> Function(String query) search = _defaultSearch;

  static Future<List<MediaItem>> _defaultSearch(String query) async {
    final tabs = await ApiClient.instance.searchTabs(query);
    return [for (final tab in tabs) ...tab.items];
  }

  /// 从本地读回缓存（幂等）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is! Map) return;
        final resolution = CuratedResolution.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (resolution.id.isNotEmpty) {
          _entries[key.toString()] = resolution;
        }
      });
    } catch (_) {
      // 缓存损坏不影响使用：当作没有缓存，重新解析。
    }
  }

  /// 同步取缓存，UI 首帧就能用上封面。
  CuratedResolution? cached(String curatedId) => _entries[curatedId];

  /// 解析一本书：缓存命中且未过期就直接返回，否则走搜索并写回缓存。
  ///
  /// 失败（搜索抛错 / 没有可选结果）返回 null，绝不向上抛。
  Future<CuratedResolution?> resolve(CuratedBook book, {bool force = false}) {
    final existing = _entries[book.id];
    if (!force && existing != null && !_isStale(existing)) {
      return Future<CuratedResolution?>.value(existing);
    }
    // 首页预取和用户点击可能同时解析同一本书，复用同一个请求。
    final inflight = _inflight[book.id];
    if (!force && inflight != null) return inflight;

    final future = _resolveRemote(book);
    _inflight[book.id] = future;
    return future.whenComplete(() {
      if (identical(_inflight[book.id], future)) {
        _inflight.remove(book.id);
      }
    });
  }

  Future<CuratedResolution?> _resolveRemote(CuratedBook book) async {
    try {
      await load();
      final items = await search(book.keyword);
      final best = pickBest(
        items,
        book.title,
        book.author,
        preferAudio: book.audio,
      );
      if (best == null) return null;
      final resolution = CuratedResolution(
        id: best.id,
        title: best.title,
        author: best.author,
        cover: best.cover,
        kind: best.kind.isEmpty ? 'book' : best.kind,
        at: DateTime.now().millisecondsSinceEpoch,
      );
      _entries[book.id] = resolution;
      changes.value++;
      await _persist();
      return resolution;
    } catch (_) {
      // 离线/接口异常都静默返回 null，由页面走搜索兜底。
      return null;
    }
  }

  /// 后台补齐缺失封面：限制并发，失败静默，不阻塞首页。
  ///
  /// 返回的 Future 在本轮队列跑完（或全部跳过）后完成，方便测试等待；
  /// 页面侧照旧不 await。
  Future<void> prefetch(
    Iterable<CuratedBook> books, {
    int concurrency = 2,
  }) async {
    // 必须先读盘，否则首帧 prefetch 会把已缓存的书重新搜一遍。
    await load();
    // 【青茄修复】队列按 book.id 去重：调用方会把「今日荐读」插到最前，
    // 它同时也在 books 里，不去重会让同一本书被两个 worker 同时解析。
    final seen = <String>{};
    final queue = books
        .where((book) {
          if (book.id.isEmpty || !seen.add(book.id)) return false;
          final cached = _entries[book.id];
          return cached == null || _isStale(cached);
        })
        .toList(growable: false);
    if (queue.isEmpty) return;

    final limit = concurrency < 1 ? 1 : concurrency;
    var next = 0;

    Future<void> worker() async {
      while (next < queue.length) {
        final book = queue[next++];
        await resolve(book);
      }
    }

    await Future.wait([
      for (var i = 0; i < limit && i < queue.length; i++) worker(),
    ]);
  }

  bool _isStale(CuratedResolution resolution) {
    if (resolution.at <= 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - resolution.at;
    return age > ttl.inMilliseconds;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode({
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        }),
      );
    } catch (_) {
      // 持久化失败不影响本次会话的解析结果。
    }
  }

  /// 纯函数：从搜索结果里挑出最像这本书的一本。
  ///
  /// 1. 剔除 video/manju/manga/audio，只留 'book' 或空 kind；
  /// 2. 归一化（去书名号/空白/标点/尾部括号说明）后完全同名 → 取第一本；
  /// 3. 退一步用双向包含匹配；
  /// 4. 都不匹配时取第一本；同一批候选里作者能对上则优先。
  static MediaItem? pickBest(
    List<MediaItem> items,
    String title,
    String author, {
    bool preferAudio = false,
  }) {
    // 【青茄修复·听书分类】有声书优先在音频源里按书名匹配；匹配不到
    // 再退回文字书（能读总比打不开强），匹配逻辑完全一致。
    // 注意这层要放在「无文字书源」的兜底之前：搜索可能只返回音频源，
    // 不能因为文字书列表为空就把音频结果一起丢掉。
    if (preferAudio) {
      final audios = items
          .where((item) => item.id.isNotEmpty && item.kind == 'audio')
          .toList(growable: false);
      final audioHit = _matchTitle(audios, title, author);
      if (audioHit != null) return audioHit;
    }
    final books = items
        // id 为空的结果无法交给详情页，直接剔除，避免解析出「打不开的书」。
        .where(
          (item) =>
              item.id.isNotEmpty && (item.kind.isEmpty || item.kind == 'book'),
        )
        .toList(growable: false);
    if (books.isEmpty) return null;

    final target = _normalize(title);
    // 【青茄修复】书名匹配不上时返回 null（调用方回退搜索页），
    // 不再赌「第一条结果」——宁可让用户挑，也不能打开一本不相干的书。
    if (target.isEmpty) return null;

    final hit = _matchTitle(books, title, author);
    return hit;
  }

  /// 在候选里按「标题完全相等 → 双向包含」两级匹配，同级内作者对得上优先。
  static MediaItem? _matchTitle(
    List<MediaItem> candidates,
    String title,
    String author,
  ) {
    if (candidates.isEmpty) return null;
    final target = _normalize(title);
    if (target.isEmpty) return null;
    final exact = candidates
        .where((item) => _normalize(item.title) == target)
        .toList(growable: false);
    if (exact.isNotEmpty) return _preferAuthor(exact, author);

    final loose = candidates
        .where((item) {
          final normalized = _normalize(item.title);
          return normalized.isNotEmpty &&
              (normalized.contains(target) || target.contains(normalized));
        })
        .toList(growable: false);
    if (loose.isNotEmpty) return _preferAuthor(loose, author);
    return null;
  }

  /// 同名多条时优先作者能对上的那条，否则保持搜索排序。
  static MediaItem _preferAuthor(List<MediaItem> candidates, String author) {
    final target = _normalize(author);
    if (target.isNotEmpty) {
      for (final item in candidates) {
        final normalized = _normalize(item.author);
        if (normalized.isEmpty) continue;
        if (normalized.contains(target) || target.contains(normalized)) {
          return item;
        }
      }
    }
    return candidates.first;
  }

  /// 标题/作者归一化：去掉尾部括号说明、书名号、空白与常见标点。
  static String _normalize(String raw) {
    var text = raw.toLowerCase().trim();
    // 《小王子（全译版）》这种括号尾巴先剥掉（可能叠加多层）。
    final trailing = RegExp(r'\s*[（(\[【][^）)\]】]{0,24}[）)\]】]\s*$');
    while (trailing.hasMatch(text)) {
      text = text.replaceFirst(trailing, '');
    }
    text = text.replaceAll(RegExp(r'[《》〈〉「」『』]'), '');
    text = text.replaceAll(RegExp(r'[\s\u3000]'), '');
    text = text.replaceAll(
      RegExp(r'''[，。、；：！？,.;:!?"'“”‘’·—\-_~`|/\\]+'''),
      '',
    );
    return text;
  }

  /// 测试用：清空内存缓存，让下一次 resolve 重新读盘/重新搜索。
  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _inflight.clear();
    _loaded = false;
    changes.value = 0;
  }
}
