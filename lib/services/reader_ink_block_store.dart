import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/ink_annotation.dart';
import '../models/reader_ink_block.dart';
import 'encrypted_hive.dart';

/// 正文内嵌手写块（画布/便签）存储：加密 Hive 盒 `reader_ink_blocks_v1`。
///
/// 与 [ReaderAnnotationStore] 同一套纪律：懒开盒、写操作串行化、落盘即
/// flush（force-stop 不丢）、`changes` 通知阅读器重载重排。读取走独立
/// 快照路径（读不需与写串行，见 InkAnnotationStore 的 fake-async 教训）。
class ReaderInkBlockStore {
  ReaderInkBlockStore({HiveInterface? hive}) : _hive = hive ?? Hive;

  static final ReaderInkBlockStore instance = ReaderInkBlockStore();
  static const _boxName = 'reader_ink_blocks_v1';

  /// Set once Hive has a directory (app bootstrap).
  static bool hiveReady = false;

  final HiveInterface _hive;
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  static String keyFor({
    required String bookId,
    required String chapterId,
    required int anchor,
    required String kind,
    required int createdAt,
  }) => jsonEncode(['ib', bookId, chapterId, anchor, kind, createdAt]);

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

  /// 【测试】丢弃假时钟 zone 里创建的开盒 future：widget 测试的 fake
  /// async 永不推进真实文件 IO，重置后首个调用（通常在 tester.runAsync
  /// 的真实窗口内）重新开盒。
  @visibleForTesting
  void resetForTest() {
    _opening = null;
    _writes = Future<void>.value();
  }

  /// 独立于写队列的读取路径：批量测试与页面加载不阻塞在写链尾部。
  Future<List<ReaderInkBlock>> _readBox(
    Future<List<ReaderInkBlock>> Function(Box<dynamic>) action,
  ) async {
    final box = await _box();
    if (box == null) return const [];
    return action(box);
  }

  /// 本章全部内嵌块，按锚点排序（草稿插入次序的稳定基础）。
  Future<List<ReaderInkBlock>> load(String bookId, String chapterId) =>
      _readBox((box) async {
        final out = <ReaderInkBlock>[];
        for (final raw in box.values) {
          final entry = ReaderInkBlock.fromMap(raw);
          if (entry == null) continue;
          if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
          out.add(entry);
        }
        out.sort((a, b) {
          final byAnchor = a.anchor.compareTo(b.anchor);
          if (byAnchor != 0) return byAnchor;
          return a.createdAt.compareTo(b.createdAt);
        });
        return out;
      });

  Future<ReaderInkBlock?> add(ReaderInkBlock block) {
    final key = keyFor(
      bookId: block.bookId,
      chapterId: block.chapterId,
      anchor: block.anchor,
      kind: block.kind,
      createdAt: block.createdAt,
    );
    return _serialize(
      (box) async {
        await box.put(key, block.toMap());
        await box.flush();
        changes.value++;
        return block;
      },
      onUnavailable: null,
    );
  }

  /// 调整画布高度（拖底边手柄松手时）。
  Future<void> updateHeight(ReaderInkBlock block, double height) {
    return _put(block.withFields(height: height));
  }

  /// 书写内容保存（便签面板关闭 / 画布选中态书写后）。[strokes] 必须
  /// 已经是归一化坐标（调用方用 ReaderInkBlock.normalized 收敛）。
  Future<void> updateStrokes(ReaderInkBlock block, List<InkStroke> strokes) {
    return _put(block.withFields(strokes: strokes));
  }

  Future<void> _put(ReaderInkBlock block) {
    return _serialize<void>((box) async {
      final key = keyFor(
        bookId: block.bookId,
        chapterId: block.chapterId,
        anchor: block.anchor,
        kind: block.kind,
        createdAt: block.createdAt,
      );
      await box.put(key, block.toMap());
      await box.flush();
      changes.value++;
    }, onUnavailable: null);
  }

  Future<void> remove(ReaderInkBlock block) {
    final key = keyFor(
      bookId: block.bookId,
      chapterId: block.chapterId,
      anchor: block.anchor,
      kind: block.kind,
      createdAt: block.createdAt,
    );
    return _serialize<void>((box) async {
      await box.delete(key);
      await box.flush();
      changes.value++;
    }, onUnavailable: null);
  }

  /// 全库清点（笔记页集中管理）。
  Future<List<ReaderInkBlock>> loadAll() => _readBox((box) async {
    final out = <ReaderInkBlock>[];
    for (final raw in box.values) {
      final entry = ReaderInkBlock.fromMap(raw);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  });

  Future<T> _serialize<T>(
    Future<T> Function(Box<dynamic>) action, {
    required T onUnavailable,
  }) {
    final operation = _writes.then((_) async {
      final box = await _box();
      if (box == null) return onUnavailable;
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}
