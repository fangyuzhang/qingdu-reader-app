import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_mark_style.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

class _NotesMemoryStore extends ReaderAnnotationStore {
  _NotesMemoryStore(this.notes);

  final List<ReaderAnnotation> notes;

  @override
  Future<List<ReaderAnnotation>> loadAll() async => notes;
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
    // 选中的类型以筛选摘要 chip 的形式留在顶部。
    expect(find.text('类型：金句'), findsOneWidget);
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
