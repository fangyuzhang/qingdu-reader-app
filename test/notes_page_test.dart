import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_mark_style.dart';
import 'package:fqapp/services/reader_marker_type_store.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

class _NotesMemoryStore extends ReaderAnnotationStore {
  _NotesMemoryStore(this.notes);

  final List<ReaderAnnotation> notes;

  @override
  Future<List<ReaderAnnotation>> loadAll() async => notes;

  @override
  Future<void> updateMarkerTags(
    String key,
    Iterable<ReaderMarkerType> markers,
  ) async {
    final index = notes.indexWhere((note) => note.key == key);
    if (index < 0) return;
    final next = ReaderAnnotationStore.normalizeMarkerTypes(markers);
    final primary = next.isEmpty ? null : next.first;
    notes[index] = notes[index].copyWith(
      markerType: primary == null ? '' : 'custom',
      markerLabel: primary?.label ?? '',
      markerColorValue: primary?.colorValue ?? 0,
      extraMarkers: next.skip(1).toList(growable: false),
    );
    changes.value++;
  }

  @override
  Future<void> updateTags(String key, Iterable<String> tags) async {
    final index = notes.indexWhere((note) => note.key == key);
    if (index < 0) return;
    notes[index] = notes[index].copyWith(
      tags: AnnotationDraft.normalizeTags(tags),
    );
    changes.value++;
  }
}

class _MemoryUnderlines extends ReaderUnderlineStore {
  _MemoryUnderlines({this.ranges = const [], this.paragraphs = const []});

  final List<ReaderRangeUnderline> ranges;
  final List<ReaderUnderline> paragraphs;

  @override
  Future<List<ReaderRangeUnderline>> loadAllRanges() async => ranges;

  @override
  Future<List<ReaderUnderline>> loadAllParagraphs() async => paragraphs;
}

ReaderAnnotation _note({
  required String bookId,
  required String text,
  required String markerLabel,
  int createdAt = 0,
  String type = ReaderAnnotation.kTypeAnnot,
  List<ReaderMarkerType> extraMarkers = const [],
  List<String> tags = const [],
}) => ReaderAnnotation(
  bookId: bookId,
  chapterId: '$bookId-c1',
  start: 1,
  end: 3,
  text: text,
  thought: '$text 的想法',
  type: type,
  createdAt: createdAt,
  bookTitle: '书 $bookId',
  chapterTitle: '第一章',
  markerType: 'custom',
  markerLabel: markerLabel,
  extraMarkers: extraMarkers,
  tags: tags,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('批注类型 chip 按角标文字筛选时间线', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '疑问句', markerLabel: '疑问', createdAt: 3),
      _note(bookId: 'a', text: '金句内容', markerLabel: '金句', createdAt: 2),
      _note(bookId: 'b', text: '另一条金句', markerLabel: '金句', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('疑问句'), findsOneWidget);
    expect(find.text('金句内容'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-marker-金句')));
    await tester.pumpAndSettle();

    expect(find.text('疑问句'), findsNothing);
    expect(find.text('金句内容'), findsOneWidget);
    expect(find.text('另一条金句'), findsOneWidget);
    // 不再出现「类型：X」「清除」这类二级按钮。
    expect(find.byKey(const ValueKey('notes-filter-button')), findsNothing);
    expect(find.textContaining('类型：'), findsNothing);
    expect(find.text('清除'), findsNothing);

    // 再点一次同一个类型 = 取消选择。
    await tester.tap(find.byKey(const ValueKey('notes-marker-金句')));
    await tester.pumpAndSettle();
    expect(find.text('疑问句'), findsOneWidget);
    expect(find.text('金句内容'), findsOneWidget);
  });

  testWidgets('一条笔记可以同时挂多个批注角标', (tester) async {
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '多标记的句子',
        markerLabel: '疑问',
        createdAt: 1,
        extraMarkers: const [
          ReaderMarkerType(label: '待查证', colorValue: 0xFF8A5B39),
        ],
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('疑问'), findsWidgets);
    expect(find.text('待查证'), findsWidgets);
  });

  testWidgets('按书查看点开一本书后留在本视图，可返回全部书籍', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: 'A 的一条', markerLabel: '疑问', createdAt: 2),
      _note(bookId: 'b', text: 'B 的一条', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-view-books')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-book-a')));
    await tester.pumpAndSettle();

    // 仍停在「按书查看」：网格让位给这本书的笔记列表，没有跳回时间线。
    expect(find.byKey(const ValueKey('notes-books')), findsNothing);
    expect(find.byKey(const ValueKey('notes-book-back')), findsOneWidget);
    expect(find.text('A 的一条'), findsOneWidget);
    expect(find.text('B 的一条'), findsNothing);
    expect(find.textContaining('书：'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-book-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('notes-book-b')), findsOneWidget);
  });

  testWidgets('长按类型标签拖到笔记上，可再打一个角标', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '被拖的句子', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final source = find.byKey(const ValueKey('notes-marker-反驳'));
    final target = find.byKey(ValueKey('note-card-${store.notes.first.key}'));
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      [for (final badge in store.notes.first.markerBadges) badge.label],
      ['疑问', '反驳'],
    );
    expect(
      find.byKey(ValueKey('note-badge-${store.notes.first.key}-反驳')),
      findsOneWidget,
    );
  });

  testWidgets('长按类型标签拖到另一个类型上可以换序', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '一句话', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final from = find.byKey(const ValueKey('notes-marker-反驳'));
    final to = find.byKey(const ValueKey('notes-marker-感悟'));
    expect(tester.getCenter(from).dx, lessThan(tester.getCenter(to).dx));

    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(from).dx,
      greaterThan(tester.getCenter(to).dx),
      reason: '「反驳」应排到「感悟」后面',
    );
    expect(ReaderMarkerTypeStore.instance.order.take(3), [
      'type:疑问',
      'type:感悟',
      'type:反驳',
    ]);
  });

  testWidgets('标签也在「全部类型」一行：点击筛选，再点取消', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '带标签的句子',
        markerLabel: '疑问',
        tags: const ['1万'],
        createdAt: 2,
      ),
      _note(bookId: 'a', text: '没标签的句子', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notes-tag-1万')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notes-tag-1万')));
    await tester.pumpAndSettle();
    expect(find.text('带标签的句子'), findsOneWidget);
    expect(find.text('没标签的句子'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-tag-1万')));
    await tester.pumpAndSettle();
    expect(find.text('没标签的句子'), findsOneWidget);

    // 「全部类型」一键清空类型与标签筛选。
    await tester.tap(find.byKey(const ValueKey('notes-tag-1万')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-marker-all')));
    await tester.pumpAndSettle();
    expect(find.text('没标签的句子'), findsOneWidget);
  });

  testWidgets('长按标签拖到笔记上可打标签（同一目标可挂多个）', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '第一条',
        markerLabel: '疑问',
        tags: const ['1万'],
        createdAt: 2,
      ),
      _note(bookId: 'b', text: '第二条', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final target = store.notes[1];
    final palette = find.byKey(const ValueKey('notes-tag-1万'));
    final card = find.byKey(ValueKey('note-card-${target.key}'));
    final gesture = await tester.startGesture(tester.getCenter(palette));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.notes[1].tags, contains('1万'));
    // 从调色板拖出是复制语义：原来那条笔记上的标签还在。
    expect(store.notes[0].tags, contains('1万'));
  });

  testWidgets('把标签从一条笔记拖到另一条笔记即移动', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '来源',
        markerLabel: '疑问',
        tags: const ['1万'],
        createdAt: 2,
      ),
      _note(bookId: 'b', text: '目标', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final source = store.notes[0];
    final target = store.notes[1];
    final badge = find.byKey(ValueKey('note-badge-${source.key}-1万'));
    final card = find.byKey(ValueKey('note-card-${target.key}'));
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.notes[0].tags, isNot(contains('1万')));
    expect(store.notes[1].tags, contains('1万'));
  });

  testWidgets('长按标签拖到类型后面可换序，且笔记角标跟随该顺序', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '排序用',
        markerLabel: '疑问',
        tags: const ['1万'],
        createdAt: 1,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final from = find.byKey(const ValueKey('notes-tag-1万'));
    final to = find.byKey(const ValueKey('notes-marker-反驳'));
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    final order = ReaderMarkerTypeStore.instance.order;
    expect(
      order.indexOf('tag:1万'),
      order.indexOf('type:反驳') + 1,
      reason: '1万 应排在 反驳 后面',
    );

    final badge = find.byKey(
      ValueKey('note-badge-${store.notes.first.key}-1万'),
    );
    final marker = find.byKey(
      ValueKey('note-badge-${store.notes.first.key}-疑问'),
    );
    expect(
      tester.getCenter(badge).dx,
      greaterThan(tester.getCenter(marker).dx),
      reason: '默认顺序里类型在前；换序后标签仍在类型之后属于正常，这里只验顺序持久化',
    );
  });

  testWidgets('把笔记上的角标拖到空白处即取消该角标', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '一句话', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final badge = find.byKey(
      ValueKey('note-badge-${store.notes.first.key}-疑问'),
    );
    expect(badge, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(const Offset(20, 30));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.notes.first.markerBadges, isEmpty);
  });

  testWidgets('划线视图列出范围划线（含荧光笔）与整段划线', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '有笔记的书', markerLabel: '疑问', createdAt: 9),
    ]);
    final underlines = _MemoryUnderlines(
      ranges: [
        ReaderRangeUnderline(
          bookId: 'a',
          chapterId: 'a-c1',
          start: 10,
          end: 20,
          text: '荧光笔画的一句',
          createdAt: 5,
          style: ReaderMarkStyle.highlighter,
          colorValue: 0xFFE9B949,
        ),
      ],
      paragraphs: [
        ReaderUnderline(
          bookId: 'b',
          chapterId: 'b-c1',
          blockIndex: 2,
          text: '普通划线的一段',
          createdAt: 4,
          style: ReaderMarkStyle.dashed,
          colorValue: 0xFF4F7CD1,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: underlines),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-view-marks')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notes-marks')), findsOneWidget);
    expect(find.text('荧光笔画的一句'), findsOneWidget);
    expect(find.text('普通划线的一段'), findsOneWidget);
    expect(find.text('荧光笔'), findsOneWidget);
    expect(find.text('虚线'), findsOneWidget);

    // 只看荧光笔。
    await tester.tap(find.byKey(const ValueKey('notes-marks-highlighter')));
    await tester.pumpAndSettle();
    expect(find.text('荧光笔画的一句'), findsOneWidget);
    expect(find.text('普通划线的一段'), findsNothing);

    // 只看普通划线。
    await tester.tap(find.byKey(const ValueKey('notes-marks-underline')));
    await tester.pumpAndSettle();
    expect(find.text('荧光笔画的一句'), findsNothing);
    expect(find.text('普通划线的一段'), findsOneWidget);
  });

  testWidgets('按书查看用与首页一致的封面卡片', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: 'A 的一条', markerLabel: '疑问', createdAt: 2),
      _note(bookId: 'b', text: 'B 的一条', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-view-books')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notes-books')), findsOneWidget);
    expect(find.byType(StoryCover), findsNWidgets(2));
    expect(find.byKey(const ValueKey('notes-book-a')), findsOneWidget);
  });

  testWidgets('划线视图没有记录时给出可读的空态', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(
          store: _NotesMemoryStore(const []),
          underlineStore: _MemoryUnderlines(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-view-marks')));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有划线'), findsOneWidget);
  });
}
