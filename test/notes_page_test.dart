import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_mark_style.dart';
import 'package:fqapp/services/reader_marker_type_store.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/notes/note_tag_drag.dart';

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

  testWidgets('批注类型也支持多选，同时选中多个类型取并集', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '疑问句', markerLabel: '疑问', createdAt: 3),
      _note(bookId: 'a', text: '反驳句', markerLabel: '反驳', createdAt: 2),
      _note(bookId: 'b', text: '金句内容', markerLabel: '金句', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-marker-疑问')));
    await tester.pumpAndSettle();
    expect(find.text('疑问句'), findsOneWidget);
    expect(find.text('反驳句'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-marker-反驳')));
    await tester.pumpAndSettle();
    expect(find.text('疑问句'), findsOneWidget);
    expect(find.text('反驳句'), findsOneWidget);
    expect(find.text('金句内容'), findsNothing);

    // 再点已选中的类型 = 只取消它，另一个仍然生效。
    await tester.tap(find.byKey(const ValueKey('notes-marker-疑问')));
    await tester.pumpAndSettle();
    expect(find.text('疑问句'), findsNothing);
    expect(find.text('反驳句'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-marker-反驳')));
    await tester.pumpAndSettle();
    expect(find.text('疑问句'), findsOneWidget);
    // 清除全部筛选后三张卡片都回到列表；第三张在测试视口（600dp）外，
    // 惰性列表需滚动后才构建，先滚到可见再断言。
    await tester.drag(
      find.byKey(const ValueKey('notes-timeline')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();
    expect(find.text('金句内容'), findsOneWidget);
  });

  testWidgets('书名固定在标题行，新增角标不会推动书名', (tester) async {
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

    final title = find.text('书 a');
    final before = tester.getTopLeft(title).dy;

    final palette = find.byKey(const ValueKey('notes-marker-反驳'));
    final card = find.byKey(ValueKey('note-card-${store.notes.first.key}'));
    final gesture = await tester.startGesture(tester.getCenter(palette));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.notes.first.markerBadges.length, 2);
    expect(tester.getTopLeft(title).dy, before);
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
    // 排序按「插到哪个缝里」计算：落在目标右边缘之外，才是排到它后面。
    await gesture.moveTo(
      Offset(tester.getTopRight(to).dx + 6, tester.getCenter(to).dy),
    );
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

  testWidgets('自由标签也支持多选，取并集后再点取消', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '只有 A',
        markerLabel: '疑问',
        tags: const ['A'],
        createdAt: 3,
      ),
      _note(
        bookId: 'a',
        text: '只有 B',
        markerLabel: '疑问',
        tags: const ['B'],
        createdAt: 2,
      ),
      _note(bookId: 'b', text: '没有标签', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('notes-tag-A')));
    await tester.pumpAndSettle();
    expect(find.text('只有 A'), findsOneWidget);
    expect(find.text('只有 B'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-tag-B')));
    await tester.pumpAndSettle();
    expect(find.text('只有 A'), findsOneWidget);
    expect(find.text('只有 B'), findsOneWidget);
    expect(find.text('没有标签'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('notes-tag-A')));
    await tester.pumpAndSettle();
    expect(find.text('只有 A'), findsNothing);
    expect(find.text('只有 B'), findsOneWidget);
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
    await gesture.moveTo(
      Offset(tester.getTopRight(to).dx + 6, tester.getCenter(to).dy),
    );
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

  testWidgets('角标拖到空白处松手 = 弹回原位，不删除', (tester) async {
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

    // 落空不再删除：角标还在笔记上。
    expect(store.notes.first.markerBadges, isNotEmpty);
    expect(badge, findsOneWidget);
  });

  testWidgets('角标拖入顶部垃圾桶即删除', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '一句话', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final noteKey = store.notes.first.key;
    final badge = find.byKey(ValueKey('note-badge-$noteKey-疑问'));
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    // 拖动期间垃圾桶 overlay 浮现。
    expect(find.byKey(const ValueKey('notes-tag-trash')), findsOneWidget);
    await gesture.moveTo(tester.getCenter(find.byKey(
      const ValueKey('notes-tag-trash'),
    )));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.notes.first.markerBadges, isEmpty);
    // 垃圾桶常驻右上角：删除后仍在（不再有显隐切换）。
    expect(find.byKey(const ValueKey('notes-tag-trash')), findsOneWidget);
  });

  testWidgets('调色板标签拖入垃圾桶 = 从所有笔记摘除并出目录', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '甲', markerLabel: '待查证', createdAt: 2),
      _note(bookId: 'b', text: '乙', markerLabel: '待查证', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    // 「待查证」是自定义类型，会出现在「全部标签」行。
    final paletteChip = find.byKey(const ValueKey('notes-marker-待查证'));
    expect(paletteChip, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(paletteChip));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(find.byKey(
      const ValueKey('notes-tag-trash'),
    )));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    // 两条笔记上的该角标都被摘除。
    for (final note in store.notes) {
      expect(
        note.markerBadges.any((badge) => badge.label == '待查证'),
        isFalse,
      );
    }
    // 自定义类型移出目录。
    expect(
      ReaderMarkerTypeStore.instance.types.any(
        (type) => type.label == '待查证',
      ),
      isFalse,
    );
  });

  testWidgets('多选标签磁吸成组拖入垃圾桶 = 组内全部删除', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      // 三本书：同书笔记的 key 会撞（_note 的 start/end 固定）。
      _note(bookId: 'a', text: '甲', markerLabel: '疑问', createdAt: 3),
      _note(bookId: 'b', text: '乙', markerLabel: '反驳', createdAt: 2),
      _note(bookId: 'c', text: '丙', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    // 选中两枚调色板标签（磁吸组）。
    await tester.tap(find.byKey(const ValueKey('notes-marker-疑问')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-marker-反驳')));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(
      find.byKey(const ValueKey('notes-marker-疑问')),
    ));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(find.byKey(
      const ValueKey('notes-tag-trash'),
    )));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    // 组内全部类型从所有笔记上摘除。
    for (final note in store.notes) {
      expect(
        note.markerBadges.any(
          (badge) => badge.label == '疑问' || badge.label == '反驳',
        ),
        isFalse,
      );
    }
  });

  testWidgets('划线类型在时间线列出范围与整段划线，线型可筛选', (tester) async {
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

    // 划线已并入类型筛选：点「划线」chip 即在时间线里列出划线记录。
    await tester.tap(find.byKey(const ValueKey('notes-type-marks')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notes-mark-timeline')),
      findsOneWidget,
    );
    expect(find.text('荧光笔画的一句'), findsOneWidget);
    expect(find.text('普通划线的一段'), findsOneWidget);
    // 「全部类型」行已切换为线型筛选（横线/波浪线/虚线/荧光笔）。
    expect(find.textContaining('荧光笔 '), findsOneWidget);
    expect(find.textContaining('虚线 '), findsOneWidget);

    // 只看荧光笔。
    await tester.tap(find.byKey(const ValueKey('notes-mark-style-highlighter')));
    await tester.pumpAndSettle();
    expect(find.text('荧光笔画的一句'), findsOneWidget);
    expect(find.text('普通划线的一段'), findsNothing);

    // 只看虚线。
    await tester.tap(find.byKey(const ValueKey('notes-mark-style-dashed')));
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

  testWidgets('把角标拖回同一张笔记：原位留半透明角标但无吸附环，且不会把标签删掉', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '拖回自己', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final noteKey = store.notes.first.key;
    final badge = find.byKey(ValueKey('note-badge-$noteKey-疑问'));
    final card = find.byKey(ValueKey('note-card-$noteKey'));
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester.widget<NoteBadgeChip>(badge).highlighted,
      isTrue,
      reason: '拖回自己时仍应标记吸附态',
    );
    // 原位保留半透明角标提示松手落点，但不再画绿色吸附环（残影感）。
    final draggable = tester.widget<LongPressDraggable<NoteTagDrag>>(
      find.descendant(
        of: badge,
        matching: find.byType(LongPressDraggable<NoteTagDrag>),
      ),
    );
    final placeholder = draggable.childWhenDragging! as Opacity;
    expect(placeholder.opacity, 0.5, reason: '原位应显示半透明角标');
    expect(
      placeholder.child,
      isA<Container>(),
      reason: '半透明角标外不得再套吸附环（Stack+描边）',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.notes.first.markerBadges.length, 1);
  });

  testWidgets('拖动排序时其他标签只横向让位，纵向位置保持不变', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '挤位', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final from = find.byKey(const ValueKey('notes-marker-疑问'));
    final anchor = find.byKey(const ValueKey('notes-marker-感悟'));
    final shifted = find.byKey(const ValueKey('notes-marker-反驳'));
    final before = tester.getTopLeft(shifted);

    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(
      Offset(tester.getTopRight(anchor).dx + 6, tester.getCenter(anchor).dy),
    );
    await tester.pumpAndSettle();

    final during = tester.getTopLeft(shifted);
    expect(during.dy, closeTo(before.dy, 0.01));
    expect(during.dx, lessThan(before.dx - 4));

    await gesture.up();
    await tester.pumpAndSettle();
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
    await tester.tap(find.byKey(const ValueKey('notes-type-marks')));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有划线'), findsOneWidget);
  });

  testWidgets('拖动悬停时磁力虚影与角标同一行，且插在落位排序上', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '目标',
        markerLabel: '疑问',
        tags: const ['重要'],
        createdAt: 1,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final noteKey = store.notes.first.key;
    final from = find.byKey(const ValueKey('notes-marker-反驳'));
    final card = find.byKey(ValueKey('note-card-$noteKey'));
    final gesture = await tester.startGesture(tester.getCenter(from));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));

    final ghost = find.byType(NoteTagGhost);
    expect(ghost, findsOneWidget, reason: '悬停目标笔记时应显示磁力虚影');
    final ghostCenter = tester.getCenter(ghost);
    final ghostTopLeft = tester.getTopLeft(ghost);
    // 虚影与已有角标同一行（不再另起一行），dy 应一致。
    final marker = find.byKey(ValueKey('note-badge-$noteKey-疑问'));
    final tag = find.byKey(ValueKey('note-badge-$noteKey-重要'));
    expect(
      tester.getCenter(marker).dy,
      moreOrLessEquals(ghostCenter.dy, epsilon: 0.5),
      reason: '磁力虚影必须和角标同一行',
    );
    // 默认顺序里类型在标签前：虚影应插在「疑问」与「重要」之间（落位预览）。
    expect(tester.getCenter(marker).dx, lessThan(ghostCenter.dx));
    expect(ghostCenter.dx, lessThan(tester.getCenter(tag).dx));

    await gesture.up();
    await tester.pumpAndSettle();
    // 松手后真实角标落在虚影预览的槽位上（虚影比角标多一个「+」图标，
    // 比较左上角：同行同位置，无跳变）。
    final landed = find.byKey(ValueKey('note-badge-$noteKey-反驳'));
    expect(landed, findsOneWidget);
    final landedTopLeft = tester.getTopLeft(landed);
    expect(landedTopLeft.dy, moreOrLessEquals(ghostTopLeft.dy, epsilon: 1));
    expect(
      landedTopLeft.dx,
      moreOrLessEquals(ghostTopLeft.dx, epsilon: 1),
      reason: '角标应落在虚影预览的行内槽位',
    );
  });

  testWidgets('跨笔记移动标签松手的瞬间源角标不再闪回原位', (tester) async {
    ReaderMarkerTypeStore.instance.resetForTest();
    addTearDown(ReaderMarkerTypeStore.instance.resetForTest);
    final store = _NotesMemoryStore([
      _note(
        bookId: 'a',
        text: '来源',
        markerLabel: '疑问',
        tags: const ['重要'],
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
    final badge = find.byKey(ValueKey('note-badge-${source.key}-重要'));
    final card = find.byKey(ValueKey('note-card-${target.key}'));
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    // 只走一帧：松手瞬间源角标必须已隐藏，不能先闪回再等异步重载消失。
    await tester.pump();
    expect(find.byKey(ValueKey('note-badge-${source.key}-重要')), findsNothing);

    await tester.pumpAndSettle();
    expect(store.notes[0].tags, isNot(contains('重要')));
    expect(store.notes[1].tags, contains('重要'));
  });

  testWidgets('角标拖到空白处松手瞬间就回原位（不消失）', (tester) async {
    final store = _NotesMemoryStore([
      _note(bookId: 'a', text: '一句话', markerLabel: '疑问', createdAt: 1),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: NotesPage(store: store, underlineStore: _MemoryUnderlines()),
      ),
    );
    await tester.pumpAndSettle();

    final noteKey = store.notes.first.key;
    final badge = find.byKey(ValueKey('note-badge-$noteKey-疑问'));
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(const Offset(20, 30));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    // 落空即弹回：角标没有消失。
    expect(find.byKey(ValueKey('note-badge-$noteKey-疑问')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(store.notes.first.markerBadges, isNotEmpty);
  });
}
