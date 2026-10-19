import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/services/reader_annotation_store.dart';

/// 【青茄重构】批注存储的落盘测试。
///
/// 真机上曾出现「保存失败，请重试」：`ReaderAnnotationStore.hiveReady`
/// 从未被置位，`_box()` 恒为 null，`add()` 直接抛错。这里把
/// 「就绪 → 写入 → 读回 → 编辑 → 删除」和「未就绪 → 抛错」两条路径都钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fqapp-annot-store-');
    Hive.init(dir.path);
    ReaderAnnotationStore.hiveReady = true;
  });

  tearDown(() async {
    ReaderAnnotationStore.hiveReady = false;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ReaderAnnotation note() => ReaderAnnotation(
    bookId: 'b1',
    chapterId: 'c1',
    start: 5,
    end: 12,
    text: '被标注的原文',
    thought: '第一次想法',
    createdAt: 1700000000000,
    bookTitle: '测试书',
    chapterTitle: '第一章',
  );

  test('保存后可按章节读回，并支持编辑想法与删除', () async {
    final store = ReaderAnnotationStore();
    final item = note();

    await store.add(item);

    final loaded = await store.load('b1', 'c1');
    expect(loaded, hasLength(1));
    expect(loaded.single.thought, '第一次想法');
    expect(loaded.single.bookTitle, '测试书');
    expect(loaded.single.start, 5);

    await store.updateThought(item.key, '第二次想法');
    expect((await store.load('b1', 'c1')).single.thought, '第二次想法');

    await store.remove(item.key);
    expect(await store.load('b1', 'c1'), isEmpty);
  });

  test('全书列表与计数包含所有章节', () async {
    final store = ReaderAnnotationStore();
    await store.add(note());
    await store.add(
      ReaderAnnotation(
        bookId: 'b1',
        chapterId: 'c2',
        start: 1,
        end: 4,
        text: '第二章原文',
        type: ReaderAnnotation.kTypeExcerpt,
        createdAt: 1700000001000,
      ),
    );

    expect(await store.countAll(), 2);
    final all = await store.loadAll();
    expect(all, hasLength(2));
    // 按创建时间倒序：后写入的在前
    expect(all.first.chapterId, 'c2');
    expect(all.first.isAnnot, isFalse);
  });

  test('未就绪时写入抛错（v2.1 真机「保存失败」的根因）', () async {
    ReaderAnnotationStore.hiveReady = false;
    final store = ReaderAnnotationStore();

    expect(() => store.add(note()), throwsA(isA<StateError>()));
    // 读路径不抛：不可用时返回空集合，界面按「没有笔记」处理
    expect(await store.load('b1', 'c1'), isEmpty);
  });

  test('清空某本书不影响其它书', () async {
    final store = ReaderAnnotationStore();
    await store.add(note());
    await store.add(
      ReaderAnnotation(
        bookId: 'b2',
        chapterId: 'c9',
        start: 0,
        end: 3,
        text: '另一本书',
        createdAt: 1700000002000,
      ),
    );

    await store.clearBook('b1');
    expect(await store.load('b1', 'c1'), isEmpty);
    expect(await store.load('b2', 'c9'), hasLength(1));
  });
}
