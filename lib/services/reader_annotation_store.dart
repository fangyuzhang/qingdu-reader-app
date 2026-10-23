import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';
import 'reader_mark_style.dart';
import 'reader_marker_type_store.dart';

/// 一次新建/编辑批注时由编辑器收集的全部内容。
@immutable
class AnnotationDraft {
  const AnnotationDraft({
    this.thought = '',
    this.category = '',
    this.tags = const [],
    this.markerType = '',
    this.markerLabel = '批',
    this.markerColorValue = readerDefaultAnnotationColor,
    this.markStyle = ReaderMarkStyle.solid,
    this.markColorValue = readerDefaultAnnotationColor,
  });

  final String thought;
  final String category;
  final List<String> tags;
  final String markerType;
  final String markerLabel;
  final int markerColorValue;
  final ReaderMarkStyle markStyle;
  final int markColorValue;

  static const String customMarkerType = 'custom';

  factory AnnotationDraft.forExcerpt({
    String category = '',
    List<String> tags = const [],
  }) => AnnotationDraft(
    category: category,
    tags: tags,
    markerType: 'excerpt',
    markerLabel: '摘',
    markerColorValue: readerDefaultExcerptColor,
    markStyle: ReaderMarkStyle.solid,
    markColorValue: readerDefaultExcerptColor,
  );

  /// 分类保持原样，标签去空白、去重，并兼容中英文逗号/换行分隔。
  static List<String> normalizeTags(Iterable<String> input) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in input) {
      for (final part in raw.split(RegExp(r'[,，\n]'))) {
        final tag = part.trim();
        if (tag.isEmpty) continue;
        if (seen.add(tag)) result.add(tag);
      }
    }
    return List.unmodifiable(result);
  }
}

/// 一条本地批注/书摘（蜗牛读书式：选中文字 + 想法 + 位置）。
///
/// 【青茄重构·新增】划线与本存储的分工：
/// * `reader_underline_store.dart` 保存「划线」——只有位置与原文，没有想法；
/// * 本存储保存「批注」（带想法，行内批注块展示）与「书摘」（收藏的句子）。
/// 两个 Box 的键空间不同（划线是 4 元组 / `r` 前缀，这里是 `a` 前缀），
/// 互不冲突。
@immutable
class ReaderAnnotation {
  const ReaderAnnotation({
    required this.bookId,
    required this.chapterId,
    required this.start,
    required this.end,
    required this.text,
    this.thought = '',
    this.type = kTypeAnnot,
    this.createdAt = 0,
    this.bookTitle = '',
    this.chapterTitle = '',
    this.category = '',
    this.tags = const [],
    this.markerType = '',
    this.markerLabel = '',
    this.markerColorValue = 0,
    this.extraMarkers = const [],
    this.markStyle = ReaderMarkStyle.solid,
    this.markColorValue = 0,
  });

  static const String kTypeAnnot = 'annot';
  static const String kTypeExcerpt = 'excerpt';

  final String bookId;
  final String chapterId;

  /// Offsets into the chapter's display text — the same space as
  /// [ReaderRangeUnderline.start] / [ReaderUnderlineStore.rangeKeyFor].
  final int start;
  final int end;

  /// 被标注的原文。
  final String text;

  /// 想法；批注为空串时按「仅划线」处理。
  final String thought;

  /// [kTypeAnnot] 批注 / [kTypeExcerpt] 书摘。
  final String type;

  final int createdAt;

  /// 书名/章节名快照：笔记列表直接展示，避免每次反查目录。
  final String bookTitle;
  final String chapterTitle;

  /// 分类是归属维度：一条笔记最多一个；标签是多维标记，可有多个。
  final String category;
  final List<String> tags;

  /// 批注标记类型及角标文案/底色。旧数据为空时自动回退到「批 / 摘」。
  final String markerType;
  final String markerLabel;
  final int markerColorValue;

  /// 叠加在主标记之后的其它批注类型。
  ///
  /// 一条笔记允许同时挂多个类型（如「疑问」+「待查证」）。主标记仍写在
  /// [markerLabel] / [markerColorValue] 上，保证阅读器、导出等只认单标记的
  /// 老链路不受影响；这里只存额外的角标。
  final List<ReaderMarkerType> extraMarkers;

  /// 原文标记的线型与颜色；批注默认横线（solid）。
  final ReaderMarkStyle markStyle;
  final int markColorValue;

  bool get isAnnot => type == kTypeAnnot;
  bool get isEmpty => end <= start;

  String get displayMarkerLabel {
    final value = markerLabel.trim();
    if (value.isNotEmpty) return value;
    return isAnnot ? '批' : '摘';
  }

  int get effectiveMarkerColorValue => markerColorValue != 0
      ? markerColorValue
      : (isAnnot ? readerDefaultAnnotationColor : readerDefaultExcerptColor);

  int get effectiveMarkColorValue => markColorValue != 0
      ? markColorValue
      : (isAnnot ? readerDefaultAnnotationColor : readerDefaultExcerptColor);

  /// 全部角标：主标记在前，其余按存储顺序，按文案去重。
  ///
  /// 全部被拖走时返回空列表——笔记卡片不再画角标；阅读器/导出仍可用
  /// [displayMarkerLabel] 回退到「批 / 摘」。
  List<ReaderMarkerType> get markerBadges {
    final seen = <String>{};
    final out = <ReaderMarkerType>[];
    void add(ReaderMarkerType type) {
      final key = type.key;
      if (key.isEmpty || !seen.add(key)) return;
      out.add(type);
    }

    if (markerLabel.trim().isNotEmpty) {
      add(
        ReaderMarkerType(
          label: displayMarkerLabel,
          colorValue: effectiveMarkerColorValue,
        ),
      );
    }
    for (final type in extraMarkers) {
      add(type);
    }
    return List.unmodifiable(out);
  }

  ReaderAnnotation copyWith({
    String? thought,
    String? category,
    List<String>? tags,
    String? markerType,
    String? markerLabel,
    int? markerColorValue,
    List<ReaderMarkerType>? extraMarkers,
    ReaderMarkStyle? markStyle,
    int? markColorValue,
  }) => ReaderAnnotation(
    bookId: bookId,
    chapterId: chapterId,
    start: start,
    end: end,
    text: text,
    thought: thought ?? this.thought,
    type: type,
    createdAt: createdAt,
    bookTitle: bookTitle,
    chapterTitle: chapterTitle,
    category: category ?? this.category,
    tags: tags ?? this.tags,
    markerType: markerType ?? this.markerType,
    markerLabel: markerLabel ?? this.markerLabel,
    markerColorValue: markerColorValue ?? this.markerColorValue,
    extraMarkers: extraMarkers ?? this.extraMarkers,
    markStyle: markStyle ?? this.markStyle,
    markColorValue: markColorValue ?? this.markColorValue,
  );

  String get key => ReaderAnnotationStore.keyFor(
    bookId: bookId,
    chapterId: chapterId,
    start: start,
    end: end,
  );

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'start': start,
    'end': end,
    'text': text,
    'thought': thought,
    'type': type,
    'createdAt': createdAt,
    'bookTitle': bookTitle,
    'chapterTitle': chapterTitle,
    'category': category,
    'tags': tags,
    'markerType': markerType,
    'markerLabel': markerLabel,
    'markerColorValue': markerColorValue,
    'extraMarkers': [for (final type in extraMarkers) type.toMap()],
    'markStyle': markStyle.storageValue,
    'markColorValue': markColorValue,
  };

  static ReaderAnnotation? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final text = raw['text'];
    final start = raw['start'];
    final end = raw['end'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        start is! num ||
        end is! num ||
        end <= start) {
      return null;
    }
    final thought = raw['thought'];
    final type = raw['type'];
    final createdAt = raw['createdAt'];
    final bookTitle = raw['bookTitle'];
    final chapterTitle = raw['chapterTitle'];
    final category = raw['category'];
    final rawTags = raw['tags'];
    final tags = rawTags is List
        ? AnnotationDraft.normalizeTags(
            rawTags.whereType<Object?>().map((value) => value.toString()),
          )
        : const <String>[];
    final markerType = raw['markerType'];
    final markerLabel = raw['markerLabel'];
    final markerColorValue = raw['markerColorValue'];
    final rawExtraMarkers = raw['extraMarkers'];
    final markColorValue = raw['markColorValue'];
    return ReaderAnnotation(
      bookId: bookId,
      chapterId: chapterId,
      start: start.toInt(),
      end: end.toInt(),
      text: text,
      thought: thought is String ? thought : '',
      type: type == kTypeExcerpt ? kTypeExcerpt : kTypeAnnot,
      createdAt: createdAt is num && createdAt.isFinite ? createdAt.toInt() : 0,
      bookTitle: bookTitle is String ? bookTitle : '',
      chapterTitle: chapterTitle is String ? chapterTitle : '',
      category: category is String ? category.trim() : '',
      tags: tags,
      markerType: markerType is String ? markerType : '',
      markerLabel: markerLabel is String ? markerLabel.trim() : '',
      markerColorValue: markerColorValue is num && markerColorValue.isFinite
          ? markerColorValue.toInt()
          : 0,
      extraMarkers: rawExtraMarkers is List
          ? List.unmodifiable(
              rawExtraMarkers
                  .map(ReaderMarkerType.fromMap)
                  .whereType<ReaderMarkerType>(),
            )
          : const <ReaderMarkerType>[],
      markStyle: ReaderMarkStyle.fromStorage(raw['markStyle']),
      markColorValue: markColorValue is num && markColorValue.isFinite
          ? markColorValue.toInt()
          : 0,
    );
  }
}

/// 批注/书摘本地存储（Hive，加密盒）。
/// 模式与 [ReaderUnderlineStore] 一致：写入串行化、容量淘汰、变化通知。
class ReaderAnnotationStore {
  ReaderAnnotationStore({HiveInterface? hive, this.maxEntries = 5000})
    : _hive = hive ?? Hive;

  static final ReaderAnnotationStore instance = ReaderAnnotationStore();
  static const _boxName = 'reader_annotations_v1';

  /// Set once Hive has a directory (app bootstrap).
  static bool hiveReady = false;

  final HiveInterface _hive;
  final int maxEntries;
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  static String keyFor({
    required String bookId,
    required String chapterId,
    required int start,
    required int end,
  }) => jsonEncode(['a', bookId, chapterId, start, end]);

  Future<Box<dynamic>?> _box() async {
    if (!hiveReady) return null;
    try {
      final pending = _opening ??= EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      );
      final box = await pending;
      if (box.isOpen) return box;
      _opening = null;
    } catch (_) {
      _opening = null;
      return null;
    }
    return _box();
  }

  Future<T> _serialize<T>(
    Future<T> Function(Box<dynamic>) action, {
    required T onUnavailable,
    bool failWhenUnavailable = false,
  }) {
    final operation = _writes.then((_) async {
      final box = await _box();
      if (box == null) {
        if (failWhenUnavailable) {
          throw StateError('批注存储不可用');
        }
        return onUnavailable;
      }
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  /// 本章全部批注/书摘，按 [start] 排序。
  Future<List<ReaderAnnotation>> load(String bookId, String chapterId) =>
      _serialize((box) async {
        final out = <ReaderAnnotation>[];
        for (final raw in box.values) {
          final entry = ReaderAnnotation.fromMap(raw);
          if (entry == null) continue;
          if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
          out.add(entry);
        }
        out.sort((a, b) => a.start.compareTo(b.start));
        return out;
      }, onUnavailable: const []);

  /// 整本书的批注/书摘（笔记页用），按创建时间排序。
  Future<List<ReaderAnnotation>> loadBook(String bookId) =>
      _serialize((box) async {
        final out = <ReaderAnnotation>[];
        for (final raw in box.values) {
          final entry = ReaderAnnotation.fromMap(raw);
          if (entry == null) continue;
          if (entry.bookId != bookId) continue;
          out.add(entry);
        }
        out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return out;
      }, onUnavailable: const []);

  /// 全部书籍的批注/书摘（笔记页用），按创建时间倒序。
  Future<List<ReaderAnnotation>> loadAll() => _serialize((box) async {
    final out = <ReaderAnnotation>[];
    for (final raw in box.values) {
      final entry = ReaderAnnotation.fromMap(raw);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }, onUnavailable: const []);

  /// 全部书籍的批注数量（统计用）。
  Future<int> countAll() => _serialize((box) async {
    var count = 0;
    for (final raw in box.values) {
      if (ReaderAnnotation.fromMap(raw) != null) count++;
    }
    return count;
  }, onUnavailable: 0);

  Future<void> add(ReaderAnnotation annotation) => _serialize(
    (box) async {
      await box.put(annotation.key, annotation.toMap());
      await _evictBeyondMax(box);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// 更新想法（编辑批注）。
  Future<void> updateThought(String key, String thought) =>
      _serialize((box) async {
        final raw = box.get(key);
        final existing = ReaderAnnotation.fromMap(raw);
        if (existing == null) return;
        await box.put(key, existing.copyWith(thought: thought).toMap());
        changes.value++;
      }, onUnavailable: null);

  /// 编辑想法、分类、标签、角标和原文标记样式，同时保留位置与创建时间。
  Future<void> updateNote(String key, AnnotationDraft draft) => _serialize(
    (box) async {
      final existing = ReaderAnnotation.fromMap(box.get(key));
      if (existing == null) return;
      final updated = existing.copyWith(
        thought: draft.thought.trim(),
        category: draft.category.trim(),
        tags: AnnotationDraft.normalizeTags(draft.tags),
        markerType: draft.markerType.trim(),
        markerLabel: draft.markerLabel.trim(),
        markerColorValue: draft.markerColorValue,
        markStyle: draft.markStyle,
        markColorValue: draft.markColorValue,
      );
      await box.put(key, updated.toMap());
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// 只改多值标签，保留想法、分类、角标与原文位置。
  Future<void> updateTags(String key, Iterable<String> tags) =>
      _serialize((box) async {
        final existing = ReaderAnnotation.fromMap(box.get(key));
        if (existing == null) return;
        final next = AnnotationDraft.normalizeTags(tags);
        if (listEquals(next, existing.tags)) return;
        await box.put(key, existing.copyWith(tags: next).toMap());
        changes.value++;
      }, onUnavailable: null, failWhenUnavailable: true);

  /// 只改批注类型角标（可多个）。第一个角标写回主标记字段，
  /// 阅读器与长图导出这类只认单标记的链路继续可用。
  Future<void> updateMarkerTags(
    String key,
    Iterable<ReaderMarkerType> markers,
  ) => _serialize((box) async {
    final existing = ReaderAnnotation.fromMap(box.get(key));
    if (existing == null) return;
    final next = normalizeMarkerTypes(markers);
    final primary = next.isEmpty ? null : next.first;
    await box.put(
      key,
      existing
          .copyWith(
            markerType: primary == null
                ? ''
                : (primary.key == existing.markerLabel
                      ? existing.markerType
                      : AnnotationDraft.customMarkerType),
            markerLabel: primary?.label ?? '',
            markerColorValue: primary?.colorValue ?? 0,
            extraMarkers: next.skip(1).toList(growable: false),
          )
          .toMap(),
    );
    changes.value++;
  }, onUnavailable: null, failWhenUnavailable: true);

  /// 按文案去重并保持传入顺序。
  static List<ReaderMarkerType> normalizeMarkerTypes(
    Iterable<ReaderMarkerType> markers,
  ) {
    final seen = <String>{};
    final out = <ReaderMarkerType>[];
    for (final marker in markers) {
      final label = marker.label.trim();
      if (label.isEmpty || !seen.add(label)) continue;
      out.add(ReaderMarkerType(label: label, colorValue: marker.colorValue));
    }
    return List.unmodifiable(out);
  }

  Future<void> remove(String key) => _serialize(
    (box) async {
      await box.delete(key);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  Future<void> clearBook(String bookId) => _serialize((box) async {
    final doomed = <dynamic>[];
    for (final key in box.keys) {
      final entry = ReaderAnnotation.fromMap(box.get(key));
      if (entry != null && entry.bookId == bookId) doomed.add(key);
    }
    if (doomed.isNotEmpty) await box.deleteAll(doomed);
    changes.value++;
  }, onUnavailable: null);

  /// 尽力关闭批注盒（同步触发，不等待可能还悬着的 open）。
  ///
  /// 用于测试清理与退出：Windows 上不释放会占住临时目录。之所以不带 await，
  /// 是因为 widget 测试跑在 fake-async zone 里，等待一个未完成的 open
  /// 会永久挂起（encrypted_hive 注释里的 CRIT-014 同类问题）。
  void closeSync() {
    _opening = null;
    for (final name in [_boxName, EncryptedHive.encryptedBoxName(_boxName)]) {
      try {
        if (_hive.isBoxOpen(name)) unawaited(_hive.box(name).close());
      } catch (_) {
        // 盒不存在/已关闭，忽略。
      }
    }
  }

  Future<void> _evictBeyondMax(Box<dynamic> box) async {
    if (box.length <= maxEntries) return;
    final oldest = box.keys.toList()
      ..sort((a, b) {
        final left = ReaderAnnotation.fromMap(box.get(a))?.createdAt ?? 0;
        final right = ReaderAnnotation.fromMap(box.get(b))?.createdAt ?? 0;
        return left.compareTo(right);
      });
    await box.deleteAll(oldest.take(box.length - maxEntries));
  }
}
