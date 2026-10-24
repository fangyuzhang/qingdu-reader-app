import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/services/ink_annotation_store.dart';

/// 第 3 组：墨迹批注模型与存储的落盘测试。
///
/// 覆盖：序列化往返无损、锚点指纹命中/失配两条路径、updateAnchor 换版本
/// 重写键、未就绪兜底。全部纯 Dart，不依赖真机。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late InkAnnotationStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fqapp-ink-store-');
    Hive.init(dir.path);
    InkAnnotationStore.hiveReady = true;
    store = InkAnnotationStore();
  });

  tearDown(() async {
    InkAnnotationStore.hiveReady = false;
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows 上盒文件句柄偶发延迟释放；临时目录由系统清理。
    }
  });

  // 章节正文 80 字，锚点区间取 [32, 40)，上下文各 32 字符。
  final chapterText = '零一二三四五六七八九' * 8;
  // 把后文窗口内（偏移 50）的一个字符改掉：指纹必然失配。
  final chapterTextModified = () {
    final chars = chapterText.split('');
    chars[50] = 'X';
    return chars.join();
  }();

  InkAnnotation sample({String bookId = 'b1', String? text}) {
    final chapter = text ?? chapterText;
    final (before, after) = InkAnnotation.contextOf(chapter, 32, 40);
    return InkAnnotation(
      bookId: bookId,
      chapterId: 'c1',
      pageWidth: 400,
      pageHeight: 600,
      layoutVersion: 'pdf-fixed',
      strokes: [
        InkStroke(
          baseWidth: 3.5,
          colorValue: 0xFFE53935,
          points: [
            InkPoint(x: 0.10, y: 0.20, pressure: 0.3, t: 0),
            InkPoint(x: 0.15, y: 0.22, pressure: 0.8, t: 16),
            InkPoint(x: 0.21, y: 0.25, pressure: 0.55, t: 33),
          ],
        ),
        InkStroke(
          points: const [InkPoint(x: 0.5, y: 0.5)],
        ),
      ],
      createdAt: 1700000000000,
      startOffset: 32,
      endOffset: 40,
      contextBefore: before,
      contextAfter: after,
      anchorBox: const InkRect(left: 0.1, top: 0.15, right: 0.3, bottom: 0.2),
      updatedAt: 1700000000100,
    );
  }

  test('序列化往返：存入后原样读出，字段无损', () async {
    final item = sample();
    await store.save(item);

    final loaded = await store.loadByChapter('b1', 'c1');
    expect(loaded, hasLength(1));
    final back = loaded.single;
    expect(back.toMap(), item.toMap());

    final stroke = back.strokes.first;
    expect(stroke.baseWidth, 3.5);
    expect(stroke.colorValue, 0xFFE53935);
    expect(stroke.points, hasLength(3));
    expect(stroke.points[1].x, closeTo(0.15, 1e-9));
    expect(stroke.points[1].pressure, closeTo(0.8, 1e-9));
    expect(stroke.points[1].t, 16);
    expect(back.anchorBox?.toMap(), item.anchorBox?.toMap());
    expect(back.updatedAt, 1700000000100);
    expect(back.hasTextAnchor, isTrue);
  });

  test('锚点指纹命中：verifyAgainst 返回 exact', () async {
    final item = sample();
    await store.save(item);

    final reviews = await store.loadByChapterVerified('b1', 'c1', chapterText);
    expect(reviews, hasLength(1));
    expect(reviews.single.status, InkAnchorStatus.exact);
    expect(reviews.single.needsReview, isFalse);
  });

  test('锚点指纹失配：返回 mismatch 且不丢弃条目', () async {
    final item = sample();
    await store.save(item);

    // 正文后文窗口内被外部改动，锚点指纹对不上 → 需人工确认。
    final reviews = await store.loadByChapterVerified(
      'b1',
      'c1',
      chapterTextModified,
    );
    expect(reviews, hasLength(1));
    expect(reviews.single.status, InkAnchorStatus.mismatch);
    expect(reviews.single.needsReview, isTrue);
    expect(reviews.single.annotation.key, item.key);

    // 原始条目仍在（没有被静默删除或改写）。
    expect(await store.loadByChapter('b1', 'c1'), hasLength(1));
  });

  test('纯页锚点（无文本层）：verifyAgainst 返回 unverified', () async {
    await store.save(
      InkAnnotation(
        bookId: 'b1',
        chapterId: 'p1',
        pageWidth: 400,
        pageHeight: 600,
        layoutVersion: 'pdf-fixed',
        strokes: const [
          InkStroke(points: [InkPoint(x: 0.2, y: 0.2), InkPoint(x: 0.4, y: 0.4)]),
        ],
        createdAt: 1,
      ),
    );
    final reviews = await store.loadByChapterVerified('b1', 'p1', '任何正文');
    expect(reviews.single.status, InkAnchorStatus.unverified);
  });

  test('updateAnchor：换 layoutVersion 重写键，旧键删除', () async {
    final item = sample();
    await store.save(item);

    final (before, after) = InkAnnotation.contextOf(chapterText, 30, 38);
    await store.updateAnchor(
      item.key,
      item.copyWith(
        startOffset: 30,
        endOffset: 38,
        contextBefore: before,
        contextAfter: after,
        layoutVersion: 'flow-v2',
      ),
    );

    final inChapter = await store.loadByChapter('b1', 'c1');
    expect(inChapter, hasLength(1));
    expect(inChapter.single.layoutVersion, 'flow-v2');
    expect(inChapter.single.startOffset, 30);
    expect(inChapter.single.endOffset, 38);
    // 新锚点对当前正文是 exact。
    final reviews = await store.loadByChapterVerified('b1', 'c1', chapterText);
    expect(reviews.single.status, InkAnchorStatus.exact);
  });

  test('删除与按书清空；未就绪时写入抛错、读取为空', () async {
    final item = sample();
    await store.save(item);
    await store.save(sample(bookId: 'b2'));
    expect(await store.countAll(), 2);

    await store.delete(item.key);
    expect(await store.loadByChapter('b1', 'c1'), isEmpty);
    expect(await store.loadByChapter('b2', 'c1'), hasLength(1));

    await store.clearBook('b2');
    expect(await store.countAll(), 0);

    InkAnnotationStore.hiveReady = false;
    expect(() => store.save(sample()), throwsA(isA<StateError>()));
    expect(await store.loadByChapter('b1', 'c1'), isEmpty);
  });

  test('fromMap 容错：坏条目返回 null，不影响其它记录', () async {
    // 直接写一条非法 map 进盒（模拟旧版本/损坏数据）。
    final box = await Hive.openBox<dynamic>(
      'reader_ink_annotations_v1',
    );
    await box.put('bad', {'bookId': '', 'strokes': 'not-a-list'});
    await box.put('ink:b1:c1:pdf-fixed', sample().toMap());
    await box.close();

    final loaded = await store.loadByChapter('b1', 'c1');
    expect(loaded, hasLength(1));
  });
}
