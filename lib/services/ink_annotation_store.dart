import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

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

  /// 诊断轨迹（诊断页展示；release 无 print 通道，落在这里最可靠）。
  static final List<String> trace = [];
  static void logTrace(String message) {
    // 双通道：内存环（诊断页展示）+ AppLog（日志查看器可查，release 唯一
    // 可靠观测面——print 在 release 进程不落 logcat）。
    AppLog.w('ink', message);
    final now = DateTime.now();
    trace.add(
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}:'
      '${now.millisecond.toString().padLeft(3, '0')} $message',
    );
    if (trace.length > 30) trace.removeRange(0, trace.length - 30);
  }
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

  /// 只读操作：直接走单飞的 [_box]，不入写队列。读不需要与写串行；而写
  /// 队列的 `_writes` 链横跨 fake-async 测试 zone 后，新用例 await 链尾
  /// 永不完成（读必须绕开它，见 notes 页测试的教训）。
  Future<T> _read<T>(
    Future<T> Function(Box<dynamic>) action, {
    required T onUnavailable,
  }) async {
    final box = await _box();
    if (box == null) return onUnavailable;
    return action(box);
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
      logTrace('save: put ${annotation.key}');
      await box.put(annotation.key, annotation.toMap());
      logTrace('save: put done len=${box.length}');
      await _evictBeyondMax(box);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// 某书某章（PDF=某页）的全部墨迹，按锚点起点排序。
  Future<List<InkAnnotation>> loadByChapter(String bookId, String chapterId) =>
      _read((box) async {
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
  ) => _read((box) async {
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
  Future<List<InkAnnotation>> loadAll() => _read((box) async {
    final out = <InkAnnotation>[];
    for (final raw in box.values) {
      final entry = InkAnnotation.fromMap(raw);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }, onUnavailable: const []);

  /// 诊断页用：盒是否可开、条目数 + 盒文件字节（force-stop 丢数据问题的
  /// 文件级证据：重启前后对比文件大小即可判断「没写入」还是「被删重建」）。
  Future<String> debugStats() async {
    var filesInfo = '';
    try {
      final support = await getApplicationDocumentsDirectory();
      final dir = Directory(support.path);
      final names = <String>[];
      await for (final entity in dir.list(followLinks: false)) {
        final name = entity.path
            .replaceAll(Platform.pathSeparator, '/')
            .split('/')
            .last;
        if (name.startsWith('reader_ink_annotations')) {
          names.add('$name=${entity is File ? entity.lengthSync() : 'dir'}');
        }
      }
      filesInfo = names.isEmpty ? ' files=无' : ' ${names.join(' ')}';
    } catch (_) {
      filesInfo = ' files=扫描失败';
    }
    if (!hiveReady) return 'hiveReady=false$filesInfo';
    try {
      final box = await _box();
      if (box == null) return 'box=null$filesInfo';
      return 'box=ok entries=${box.length}$filesInfo';
    } catch (e) {
      return 'open threw: $e $filesInfo';
    }
  }

  Future<int> countAll() => _read((box) async {
    var count = 0;
    for (final raw in box.values) {
      if (InkAnnotation.fromMap(raw) != null) count++;
    }
    return count;
  }, onUnavailable: 0);

  Future<void> delete(String key) => _serialize(
    (box) async {
      await box.delete(key);
      // 与 save 对称：SIGKILL 后「整页擦除」不得从写缓冲复活。
      await box.flush();
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
    // 先写新键再删旧键：中途被杀残留「新旧并存」可被下次同键写覆盖，
    // 反过来（先删后写）会整条丢失——手写内容不可再生。
    await box.put(updated.key, updated.toMap());
    if (oldKey != updated.key) {
      await box.delete(oldKey);
    }
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
        // 编辑会刷新 updatedAt：淘汰按「最近一次活跃」算，否则满容量时
        // 编辑最老的一条会把它自己挤出去。
        final leftEntry = InkAnnotation.fromMap(box.get(a));
        final rightEntry = InkAnnotation.fromMap(box.get(b));
        final left = leftEntry?.updatedAt ?? leftEntry?.createdAt ?? 0;
        final right = rightEntry?.updatedAt ?? rightEntry?.createdAt ?? 0;
        return left.compareTo(right);
      });
    await box.deleteAll(oldest.take(box.length - maxEntries));
  }
}
