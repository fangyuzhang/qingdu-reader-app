import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 书单分类（编辑部整理的类型划分）。
@immutable
class CuratedCategory {
  const CuratedCategory({
    required this.key,
    required this.label,
    required this.desc,
    required this.gradient,
  });

  final String key;
  final String label;

  /// 一句话说明，用户点进分类时看到的那句。
  final String desc;

  /// 文字封面的两端渐变色（没有网络封面图，用色块做视觉区分）。
  final List<Color> gradient;

  static CuratedCategory fromJson(Map<String, dynamic> json) {
    final raw = (json['gradient'] as List? ?? const [])
        .map((e) => Color(int.parse(e.toString())))
        .toList(growable: false);
    return CuratedCategory(
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      desc: json['desc']?.toString() ?? '',
      gradient: raw.length >= 2
          ? raw
          : const [Color(0xFF2FA98C), Color(0xFF1F7F69)],
    );
  }
}

/// 一本「编辑部荐读」的书。
///
/// 【青茄重构·新增】首页不再拉上游网文流，改为展示这份精选书单；
/// 条目本身只带书目信息，点「去书城找这本书」再用书名走搜索
/// （搜索能力完整保留，见 [searchKeyword]）。
@immutable
class CuratedBook {
  const CuratedBook({
    required this.id,
    required this.title,
    required this.author,
    required this.category,
    required this.blurb,
    required this.tags,
    required this.age,
    this.searchKeyword,
    this.audio = false,
  });

  final String id;
  final String title;
  final String author;

  /// 对应 [CuratedCategory.key]。
  final String category;

  /// 一句话荐语。
  final String blurb;
  final List<String> tags;

  /// 适龄提示：12+ / 15+。
  final String age;

  /// 搜索用的关键词，缺省用书名。
  final String? searchKeyword;

  /// 【青茄修复·听书分类】书城有该书的有声版：听书分类里点开会优先
  /// 解析音频源，没有音频时退回文字阅读。
  final bool audio;

  String get keyword => (searchKeyword == null || searchKeyword!.isEmpty)
      ? title
      : searchKeyword!;

  bool get isMature => age == '15+';

  static CuratedBook fromJson(Map<String, dynamic> json) => CuratedBook(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    author: json['author']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    blurb: json['blurb']?.toString() ?? '',
    tags: (json['tags'] as List? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    age: json['age']?.toString() ?? '12+',
    searchKeyword: json['search']?.toString(),
    audio: json['audio'] == true,
  );
}

/// 整份书单（分类 + 书目），只读。
@immutable
class CuratedCatalog {
  const CuratedCatalog({required this.categories, required this.books});

  final List<CuratedCategory> categories;
  final List<CuratedBook> books;

  CuratedCategory? categoryOf(String key) {
    for (final category in categories) {
      if (category.key == key) return category;
    }
    return null;
  }

  List<CuratedBook> booksOf(String key) =>
      books.where((b) => b.category == key).toList(growable: false);

  /// 按日期稳定轮换的「今日荐读」。
  ///
  /// 同一天的基础顺序固定，跨天自动换；[batch] 用于用户点「换一批」。
  /// 这避免了首页静态书单永远从同一本开始的问题。
  CuratedBook? pickOfDay({DateTime? now, int batch = 0}) {
    if (books.isEmpty) return null;
    final order = _dailyOrder(books, now ?? DateTime.now());
    return order[batch.abs() % order.length];
  }

  /// 首页推荐位的一批书：每日顺序不同，手动换一批时滚动到下一组。
  ///
  /// [limit] 小于分类总量时只返回一部分；显式进入分类页仍能看全量。
  List<CuratedBook> recommendationBatchOf(
    String key, {
    DateTime? now,
    int batch = 0,
    int limit = 4,
  }) {
    final all = booksOf(key);
    if (all.isEmpty || limit <= 0) return const [];
    final order = _dailyOrder(all, now ?? DateTime.now());
    // limit 覆盖全部分类（首页每板块 10 本）时，批次改为对日序做轮转：
    // 否则 start 恒为 0，「换一批」不再产生可感知的变化。
    if (limit >= order.length) {
      final shift = batch.abs() % order.length;
      return List.unmodifiable([
        for (var i = 0; i < order.length; i++)
          order[(i + shift) % order.length],
      ]);
    }
    final start = (batch.abs() * limit) % order.length;
    return List<CuratedBook>.generate(
      limit,
      (index) => order[(start + index) % order.length],
      growable: false,
    );
  }

  /// A stable per-day shuffle. `Random` is seeded exclusively by the calendar
  /// day, so repeated builds and pull-to-refresh return the same base order.
  static List<CuratedBook> _dailyOrder(List<CuratedBook> source, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final epoch = today.difference(DateTime(2024, 1, 1)).inDays;
    final order = List<CuratedBook>.of(source);
    order.shuffle(math.Random(0x6D2B79F5 ^ epoch));
    return order;
  }

  static const empty = CuratedCatalog(categories: [], books: []);
}

/// 书单的加载与缓存（assets/config/curated_books.json）。
class CuratedLibrary {
  CuratedLibrary._();

  static const assetPath = 'assets/config/curated_books.json';

  static CuratedCatalog? _cache;

  /// 已加载的目录；未加载时返回空目录（首页自行处理空态）。
  static CuratedCatalog get current => _cache ?? CuratedCatalog.empty;

  static Future<CuratedCatalog> load({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    try {
      final text = await rootBundle.loadString(assetPath);
      final raw = jsonDecode(text);
      if (raw is! Map) return CuratedCatalog.empty;
      final categories = (raw['categories'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => CuratedCategory.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
      final books = (raw['books'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => CuratedBook.fromJson(Map<String, dynamic>.from(e)))
          .where((b) => b.id.isNotEmpty && b.title.isNotEmpty)
          .toList(growable: false);
      return _cache = CuratedCatalog(categories: categories, books: books);
    } catch (_) {
      // 资源缺失/解析失败不该拖住首页：返回空目录，界面给「书单准备中」。
      return _cache ?? CuratedCatalog.empty;
    }
  }

  @visibleForTesting
  static void resetForTest() => _cache = null;
}
