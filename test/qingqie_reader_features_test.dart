import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/services/content_rating.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/content_rating_chip.dart';

/// 【青茄重构·新增】分级 / 书架分组 / 笔记页的单元与组件测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内容分级 ContentRating', () {
    test('命中成熟题材关键词判 15+', () {
      expect(ContentRating.of(categories: const ['悬疑', '推理']), '15+');
      expect(ContentRating.of(intro: '一场连环凶案悄然发生'), '15+');
      expect(ContentRating.of(title: '末世余晖'), '15+');
    });

    test('常规题材默认 12+', () {
      expect(ContentRating.of(categories: const ['校园', '青春']), '12+');
      expect(ContentRating.of(), '12+');
    });

    test('按 MediaItem 判定', () {
      final item = MediaItem(
        id: 'b1',
        title: '雾都夜行',
        cover: '',
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
        categories: const ['悬疑'],
      );
      expect(ContentRating.ofItem(item), '15+');
    });

    test('说明文案随分级变化', () {
      expect(ContentRating.explain('15+'), contains('15 岁'));
      expect(ContentRating.explain('12+'), contains('12 岁'));
    });
  });

  group('书架分组 ShelfStatus', () {
    test('未知/空状态兜底为在读', () {
      expect(ShelfStatus.normalize(null), ShelfStatus.reading);
      expect(ShelfStatus.normalize('nonsense'), ShelfStatus.reading);
      expect(ShelfStatus.normalize('want'), ShelfStatus.want);
      expect(ShelfStatus.normalize('done'), ShelfStatus.done);
    });

    test('分组中文名', () {
      expect(ShelfStatus.label(ShelfStatus.reading), '在读');
      expect(ShelfStatus.label(ShelfStatus.want), '想读');
      expect(ShelfStatus.label(ShelfStatus.done), '读完');
    });

    test('ShelfRecord.copyWith 只改分组', () {
      final item = MediaItem(
        id: 'b1',
        title: '测试书',
        cover: '',
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
      );
      final record = ShelfRecord(item: item, addedAt: DateTime(2026, 10, 1));
      expect(record.status, ShelfStatus.reading);
      final moved = record.copyWith(status: ShelfStatus.done);
      expect(moved.status, ShelfStatus.done);
      expect(moved.item.id, 'b1');
      expect(moved.addedAt, record.addedAt);
    });
  });

  testWidgets('笔记页空态可见（存储未就绪时不崩）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NotesPage()));
    await tester.pumpAndSettle();
    expect(find.text('笔记'), findsOneWidget);
    expect(find.textContaining('还没有'), findsOneWidget);
    // 三个筛选 chip 都在（全部/批注/书摘）
    expect(find.byType(ChoiceChip), findsNWidgets(3));
  });

  testWidgets('分级标签渲染 12+ 与 15+', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              ContentRatingChip(rating: '12+'),
              ContentRatingChip(rating: '15+'),
            ],
          ),
        ),
      ),
    );
    expect(find.text('12+'), findsOneWidget);
    expect(find.text('15+'), findsOneWidget);
  });

  test('批注记录带书名章节名可回读', () {
    final note = ReaderAnnotation(
      bookId: 'b1',
      chapterId: 'c1',
      start: 10,
      end: 20,
      text: '原文',
      thought: '想法',
      bookTitle: '书名',
      chapterTitle: '第一章',
    );
    final round = ReaderAnnotation.fromMap(note.toMap());
    expect(round, isNotNull);
    expect(round!.bookTitle, '书名');
    expect(round.chapterTitle, '第一章');
    expect(round.key, note.key);
  });
}
