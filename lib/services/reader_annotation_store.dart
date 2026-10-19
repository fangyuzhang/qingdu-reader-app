import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';

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

  bool get isAnnot => type == kTypeAnnot;
  bool get isEmpty => end <= start;

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
      final pending = _opening ??= EncryptedHive.openBox<dynamic>(_hive, _boxName);
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
  Future<List<ReaderAnnotation>> loadBook(String bookId) => _serialize((box) async {
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
  Future<void> updateThought(String key, String thought) => _serialize(
    (box) async {
      final raw = box.get(key);
      final existing = ReaderAnnotation.fromMap(raw);
      if (existing == null) return;
      await box.put(
        key,
        ReaderAnnotation(
          bookId: existing.bookId,
          chapterId: existing.chapterId,
          start: existing.start,
          end: existing.end,
          text: existing.text,
          thought: thought,
          type: existing.type,
          createdAt: existing.createdAt,
          bookTitle: existing.bookTitle,
          chapterTitle: existing.chapterTitle,
        ).toMap(),
      );
      changes.value++;
    },
    onUnavailable: null,
  );

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
    for (final name in [
      _boxName,
      EncryptedHive.encryptedBoxName(_boxName),
    ]) {
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
