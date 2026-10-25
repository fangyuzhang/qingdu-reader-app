import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/ink_annotation.dart';
import 'app_log.dart';
import 'encrypted_hive.dart';

/// 手写墨迹批注的本地存储（第 3 组，加密 Hive 盒 reader_ink_annotations_v1）。
///
/// 模式与 [ReaderAnnotationStore] 一致：具体类 + 单例、写入串行化、容量
/// 淘汰、changes 通知、fromMap 容错。键空间用 `ink:` 前缀（ReaderAnnotation
/// 用 `a` 前缀 JSON 数组、划线用 `r` 前缀，互不冲突）。任务书里的
/// 「InkAnnotationRepository 接口（save / loadByChapter / delete /
/// updateAnchor）」即本类——本仓库没有独立 Repository 层，services 下的
/// store 单例就是仓库（见 EXTENSION-SURVEY-REPORT.md §4）。
class InkAnnotationStore {
  InkAnnotationStore({HiveInterface? hive, this.maxEntries = 2000})
    : _hive = hive ?? Hive;

  static final InkAnnotationStore instance = InkAnnotationStore();
  static const _boxName = 'reader_ink_annotations_v1';

  /// Set once Hive has a directory (app bootstrap).
  static bool hiveReady = false;

  final HiveInterface _hive;

  /// 墨迹点数据量大（一笔几十点、一页几十笔），容量比文本批注保守。
  final int maxEntries;
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

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
    } catch (e) {
      _opening = null;
      AppLog.w('ink-store', 'open box failed: $e');
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
          AppLog.w('ink-store', 'write dropped: box unavailable');
          throw StateError('墨迹批注存储不可用');
        }
        return onUnavailable;
      }
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  /// 保存（同键整条覆写——一页的全部笔迹作为一条记录，编辑=重写）。
  Future<void> save(InkAnnotation annotation) => _serialize(
    (box) async {
      await box.put(annotation.key, annotation.toMap());
      // 立即刷盘：force-stop（SIGKILL）没有盒关闭时机，减少半帧落盘被
      // 下次打开当损坏处理的窗口。
      await box.flush();
      await _evictBeyondMax(box);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// 某书某章（PDF=某页）的全部墨迹，按锚点起点排序。
  Future<List<InkAnnotation>> loadByChapter(String bookId, String chapterId) =>
      _serialize((box) async {
        final out = <InkAnnotation>[];
        for (final raw in box.values) {
          final entry = InkAnnotation.fromMap(raw);
          if (entry == null) continue;
          if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
          out.add(entry);
        }
        out.sort((a, b) {
          final left = a.startOffset ?? 0;
          final right = b.startOffset ?? 0;
          return left.compareTo(right);
        });
        return out;
      }, onUnavailable: const []);

  /// 带指纹校验的读取：失配条目标 [InkAnchorStatus.mismatch] 照常返回
  /// （需人工确认），绝不静默丢弃。
  Future<List<InkAnchorReview>> loadByChapterVerified(
    String bookId,
    String chapterId,
    String chapterText,
  ) => _serialize((box) async {
    final out = <InkAnchorReview>[];
    for (final raw in box.values) {
      final entry = InkAnnotation.fromMap(raw);
      if (entry == null) continue;
      if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
      out.add(
        InkAnchorReview(
          annotation: entry,
          status: entry.verifyAgainst(chapterText),
        ),
      );
    }
    out.sort((a, b) {
      final left = a.annotation.startOffset ?? 0;
      final right = b.annotation.startOffset ?? 0;
      return left.compareTo(right);
    });
    return out;
  }, onUnavailable: const []);

  /// 全部墨迹（诊断页用，第 7 组）。
  Future<List<InkAnnotation>> loadAll() => _serialize((box) async {
    final out = <InkAnnotation>[];
    for (final raw in box.values) {
      final entry = InkAnnotation.fromMap(raw);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }, onUnavailable: const []);

  /// 诊断页用：盒是否可开、条目数、首个键（不弹出任何数据细节）。
  Future<String> debugStats() async {
    if (!hiveReady) return 'hiveReady=false（LibraryStore.init 未跑）';
    try {
      final box = await _box();
      if (box == null) return 'box=null（打开失败，见 AppLog ink-store）';
      final keys = box.keys.toList();
      return 'box=ok entries=${box.length}'
          '${keys.isEmpty ? '' : ' first=${keys.first.toString().substring(0, keys.first.toString().length.clamp(0, 48))}'}';
    } catch (e) {
      return 'open threw: $e';
    }
  }

  Future<int> countAll() => _serialize((box) async {
    var count = 0;
    for (final raw in box.values) {
      if (InkAnnotation.fromMap(raw) != null) count++;
    }
    return count;
  }, onUnavailable: 0);

  Future<void> delete(String key) => _serialize(
    (box) async {
      await box.delete(key);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// 重投影后回写锚点（layoutVersion 变化时键随版本走：删旧键、写新键）。
  Future<void> updateAnchor(
    String oldKey,
    InkAnnotation updated,
  ) => _serialize((box) async {
    if (oldKey != updated.key) {
      await box.delete(oldKey);
    }
    await box.put(updated.key, updated.toMap());
    changes.value++;
  }, onUnavailable: null, failWhenUnavailable: true);

  Future<void> clearBook(String bookId) => _serialize((box) async {
    final doomed = <dynamic>[];
    for (final key in box.keys) {
      final entry = InkAnnotation.fromMap(box.get(key));
      if (entry != null && entry.bookId == bookId) doomed.add(key);
    }
    if (doomed.isNotEmpty) await box.deleteAll(doomed);
    changes.value++;
  }, onUnavailable: null);

  /// 尽力关闭墨迹盒（测试清理；与 ReaderAnnotationStore.closeSync 同因：
  /// fake-async zone 里等待未完成的 open 会挂起）。
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
        final left = InkAnnotation.fromMap(box.get(a))?.createdAt ?? 0;
        final right = InkAnnotation.fromMap(box.get(b))?.createdAt ?? 0;
        return left.compareTo(right);
      });
    await box.deleteAll(oldest.take(box.length - maxEntries));
  }
}
