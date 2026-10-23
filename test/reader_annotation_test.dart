import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_note_block.dart';

/// 【青茄重构·新增】批注排版与展示测试。
///
/// 覆盖四件事：
/// 1. 批注块被插到所属段落之后（顺序正确）；
/// 2. 批注文字不污染正文坐标（textLength / blockAtOffset 都不受批注影响）；
/// 3. 分页时批注块整块落页、高度与测量一致（不会溢出或切断）；
/// 4. 渲染出的批注块显示想法、折叠后单行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const specSize = Size(350, 640);

  ReaderChapterLayout buildLayout({List<ReaderInlineNote> notes = const []}) =>
      ReaderChapterLayout(
        title: '第一章 山间来信',
        content: ChapterContent(
          blocks: [
            '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正在慢慢散开。',
            '他把昨天写好的信折了两折，塞进信封，又在封口处按了一下，像是要确认什么。',
            '走下山路的时候，他忽然想起母亲说过的话：离家的路总是比回家的路短。',
          ].map(ChapterParagraph.new).toList(),
        ),
        spec: ReaderLayoutSpec(
          viewport: specSize,
          textScaler: TextScaler.noScaling,
          preferences: const ReaderPreferences(),
          fontFamily: null,
        ),
        inlineNotes: notes,
      );

  test('批注块插在所属段落之后，且不改动正文长度', () {
    final plain = buildLayout();
    final withNote = buildLayout(
      notes: [
        ReaderInlineNote(
          id: 'k1',
          start: plain.blocks[1].start + 4,
          end: plain.blocks[1].start + 18,
          quote: plain.blocks[1].text.substring(4, 18),
          thought: '这里的信封是个伏笔。',
        ),
      ],
    );

    // 正文长度不受批注影响：批注文字不进入章节坐标。
    expect(withNote.textLength, plain.textLength);

    final noteIndex = withNote.blocks.indexWhere((b) => b.isNote);
    expect(noteIndex, greaterThan(0), reason: '批注块应被插入块列表');
    final note = withNote.blocks[noteIndex];
    expect(note.inlineNote!.id, 'k1');
    expect(note.isBody, isFalse);
    // 批注块紧跟在被标注的那一行之后：前一块是本段的行首到该行行尾，
    // 后一块从该行之后继续，两段拼起来仍是原文。
    final beforeNote = withNote.blocks[noteIndex - 1];
    expect(beforeNote.isBody, isTrue);
    expect(beforeNote.text, isNotEmpty);
    expect(plain.blocks[1].text.startsWith(beforeNote.text), isTrue);
    expect(
      withNote.blocks[noteIndex + 1].text,
      plain.blocks[1].text.substring(beforeNote.text.length),
    );
    // 高度为实测值，且占至少一行
    expect(note.height, greaterThan(20));
    expect(note.noteLines, greaterThanOrEqualTo(1));
  });

  test('批注块不干扰正文定位（blockAtOffset 跳过批注块）', () {
    final plain = buildLayout();
    final anchor = plain.blocks[1];
    final withNote = buildLayout(
      notes: [
        ReaderInlineNote(
          id: 'k1',
          start: anchor.start + 2,
          end: anchor.start + 10,
          quote: anchor.text.substring(2, 10),
          thought: '想法',
        ),
      ],
    );
    // 批注块 start 与正文切片相邻，定位必须仍落在正文块上，且字符与原文一致
    final offset = anchor.start + 5;
    final hit = withNote.blockAtOffset(offset);
    expect(hit, isNotNull);
    expect(hit!.isNote, isFalse);
    expect(hit.start <= offset, isTrue);
    expect(offset < hit.end, isTrue);
    expect(hit.text[offset - hit.start], anchor.text[offset - anchor.start]);
  });

  test('分页把批注块整块放下，不跨页切断', () {
    final plain = buildLayout();
    final anchor = plain.blocks[2];
    final withNote = buildLayout(
      notes: [
        ReaderInlineNote(
          id: 'k1',
          start: anchor.start + 1,
          end: anchor.start + 9,
          quote: anchor.text.substring(1, 9),
          thought: '离家与回家的比喻，全书反复出现。',
        ),
      ],
    );
    final note = withNote.blocks.firstWhere((b) => b.isNote);
    final fragments = [
      for (final page in withNote.pages)
        for (final fragment in page.fragments)
          if (identical(fragment.block, note)) fragment,
    ];
    expect(fragments, hasLength(1), reason: '批注块必须整块落在同一页');
    expect(fragments.single.firstLine, 0);
    expect(fragments.single.lastLine, 0);
    expect(fragments.single.height, moreOrLessEquals(note.height));
    expect(fragments.single.sourceTop, 0);
  });

  testWidgets('批注块渲染想法，点折叠后只显示一行', (tester) async {
    const note = ReaderInlineNote(
      id: 'k1',
      start: 0,
      end: 6,
      quote: '被标注的原文',
      thought: '这是一条比较长的想法，用来验证折叠之后确实只剩一行可见文本，而不是把整段都铺开。',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: ReaderNoteBlock(note: note, height: 120, maxLines: 4),
            ),
          ),
        ),
      ),
    );

    expect(find.text(note.thought), findsOneWidget);
    expect(find.text('批'), findsOneWidget);

    Text textWidget() => tester.widget<Text>(
      find.byKey(const ValueKey('reader-note-text-k1')),
    );
    expect(textWidget().maxLines, 4);

    await tester.tap(find.byTooltip('折叠'));
    await tester.pumpAndSettle();
    expect(textWidget().maxLines, 1);
  });

  test('ReaderAnnotation.fromMap 拒绝坏数据', () {
    expect(ReaderAnnotation.fromMap(null), isNull);
    expect(ReaderAnnotation.fromMap({'bookId': 'b'}), isNull);
    expect(
      ReaderAnnotation.fromMap({
        'bookId': 'b',
        'chapterId': 'c',
        'start': 10,
        'end': 4,
        'text': '内容',
      }),
      isNull,
      reason: 'end 必须大于 start',
    );
    final ok = ReaderAnnotation.fromMap({
      'bookId': 'b',
      'chapterId': 'c',
      'start': 4,
      'end': 10,
      'text': '内容',
      'thought': '想法',
      'type': ReaderAnnotation.kTypeExcerpt,
      'createdAt': 123,
    });
    expect(ok, isNotNull);
    expect(ok!.isAnnot, isFalse);
    expect(ok.thought, '想法');
    expect(ok.key, ReaderAnnotationStore.keyFor(
      bookId: 'b',
      chapterId: 'c',
      start: 4,
      end: 10,
    ));
  });
}
