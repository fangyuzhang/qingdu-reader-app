import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/services/content_rating.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/content_rating_chip.dart';

/// 【轻读重构·新增】分级 / 书架分组 / 笔记页的单元与组件测试。
class _NotesMemoryStore extends ReaderAnnotationStore {
  _NotesMemoryStore(this.notes);

  final List<ReaderAnnotation> notes;

  @override
  Future<List<ReaderAnnotation>> loadAll() async => notes;
}

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
    // 五个内容 chip（全部/批注/书摘/划线/手写）+ 「全部标签」；
    // 其余类型是可长按拖动的 PaletteTagChip，不再是 ChoiceChip。
    expect(find.byType(ChoiceChip), findsNWidgets(6));
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

  testWidgets('按书查看可列出各书笔记并打开一本书的全部笔记', (tester) async {
    final firstTime = DateTime(2026, 10, 20, 8, 5);
    final secondTime = DateTime(2026, 10, 19, 21, 30);
    final thirdTime = DateTime(2026, 10, 18, 9, 10);
    final store = _NotesMemoryStore([
      ReaderAnnotation(
        bookId: 'book-a',
        chapterId: 'a1',
        start: 1,
        end: 3,
        text: 'A one',
        thought: 'A thought one',
        createdAt: firstTime.millisecondsSinceEpoch,
        bookTitle: 'Book A',
        chapterTitle: 'Chapter 1',
      ),
      ReaderAnnotation(
        bookId: 'book-b',
        chapterId: 'b1',
        start: 4,
        end: 7,
        text: 'B one',
        thought: 'B thought one',
        createdAt: secondTime.millisecondsSinceEpoch,
        bookTitle: 'Book B',
        chapterTitle: 'Chapter 1',
      ),
      ReaderAnnotation(
        bookId: 'book-a',
        chapterId: 'a2',
        start: 8,
        end: 11,
        text: 'A two',
        thought: 'A thought two',
        createdAt: thirdTime.millisecondsSinceEpoch,
        bookTitle: 'Book A',
        chapterTitle: 'Chapter 2',
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: NotesPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-view-books')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notes-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('notes-book-book-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('notes-book-book-b')), findsOneWidget);
    expect(find.text('2 条笔记 · 2 批注 · 0 书摘 · 2 个章节'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-book-book-a')));
    await tester.pumpAndSettle();

    // 留在「按书查看」里展开这本书，不再跳时间线、也不再出现「书：X」摘要。
    expect(find.byKey(const ValueKey('notes-book-back')), findsOneWidget);
    expect(find.text('书：Book A'), findsNothing);
    expect(find.text('A one'), findsOneWidget);
    expect(find.text('A two'), findsOneWidget);
    expect(find.text('B one'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-book-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-books')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'notes timeline hides timestamps and type chips toggle off on second tap',
    (tester) async {
      final firstTime = DateTime(2026, 10, 20, 8, 5);
      final secondTime = DateTime(2026, 10, 19, 21, 30);
      final store = _NotesMemoryStore([
        ReaderAnnotation(
          bookId: 'book-a',
          chapterId: 'c1',
          start: 1,
          end: 3,
          text: 'first source',
          thought: 'first thought',
          createdAt: firstTime.millisecondsSinceEpoch,
          bookTitle: 'Book A',
          chapterTitle: 'Chapter 1',
          category: 'growth',
          tags: const ['character'],
        ),
        ReaderAnnotation(
          bookId: 'book-b',
          chapterId: 'c2',
          start: 4,
          end: 7,
          text: 'second source',
          thought: 'second thought',
          type: ReaderAnnotation.kTypeExcerpt,
          createdAt: secondTime.millisecondsSinceEpoch,
          bookTitle: 'Book B',
          chapterTitle: 'Chapter 2',
          category: 'history',
          tags: const ['structure'],
        ),
      ]);

      await tester.pumpWidget(MaterialApp(home: NotesPage(store: store)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('notes-timeline')), findsOneWidget);
      // 时间戳按产品要求不再在卡片内展示。
      expect(find.text('2026-10-20 08:05'), findsNothing);
      expect(find.text('2026-10-19 21:30'), findsNothing);
      expect(
        find.byKey(ValueKey('note-timeline-${store.notes.first.key}')),
        findsOneWidget,
      );

      // 顶部「筛选」按钮与「类型：X / 清除」摘要已移除。
      expect(find.byKey(const ValueKey('notes-filter-button')), findsNothing);
      expect(find.text('\u6e05\u9664'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('notes-type-annot')));
      await tester.pumpAndSettle();
      expect(find.text('first source'), findsOneWidget);
      expect(find.text('second source'), findsNothing);

      // 再点一次取消选择，书摘回到列表。
      await tester.tap(find.byKey(const ValueKey('notes-type-annot')));
      await tester.pumpAndSettle();
      expect(find.text('second source'), findsOneWidget);
      expect(
        find.byKey(ValueKey('note-timeline-${store.notes.first.key}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('note-timeline-${store.notes.last.key}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
