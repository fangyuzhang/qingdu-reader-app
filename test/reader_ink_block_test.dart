import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/models/reader_ink_block.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_ink_block_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderInkBlockStore', () {
    late Directory directory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp('fqapp-ink-block-');
      Hive.init(directory.path);
      ReaderInkBlockStore.hiveReady = true;
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    ReaderInkBlock block({int anchor = 24, String kind = ReaderInkBlock.kindCanvas}) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return ReaderInkBlock(
        bookId: 'book-a',
        chapterId: 'chapter-1',
        anchor: anchor,
        anchorContext: '清晨的风从窗边吹来，带着山间草木的清香。',
        kind: kind,
        height: ReaderInkBlock.defaultCanvasHeight,
        strokes: const [
          InkStroke(
            points: [
              InkPoint(x: 0.1, y: 0.2, pressure: 0.5, t: 0),
              InkPoint(x: 0.4, y: 0.6, pressure: 0.5, t: 12),
            ],
          ),
        ],
        createdAt: now,
        updatedAt: now,
        bookTitle: '山川来信',
        chapterTitle: '第一章',
      );
    }

    test('add/load 往返：本章可读、他章不可见', () async {
      final store = ReaderInkBlockStore();
      await store.add(block());
      final same = await store.load('book-a', 'chapter-1');
      expect(same, hasLength(1));
      expect(same.first.kind, ReaderInkBlock.kindCanvas);
      expect(same.first.strokes, hasLength(1));
      expect(same.first.anchorContext, contains('清晨的风'));
      final other = await store.load('book-a', 'chapter-2');
      expect(other, isEmpty);
    });

    test('updateStrokes/updateHeight/remove 落盘即 flush 可重读', () async {
      final store = ReaderInkBlockStore();
      final original = await store.add(block());
      final withInk = original!.withFields(
        strokes: const [
          InkStroke(
            points: [
              InkPoint(x: 0.05, y: 0.05, pressure: 0.5, t: 0),
              InkPoint(x: 0.9, y: 0.9, pressure: 0.5, t: 5),
            ],
          ),
        ],
      );
      await store.updateStrokes(withInk, withInk.strokes);
      await store.updateHeight(withInk, 220);
      final reloaded = await store.load('book-a', 'chapter-1');
      expect(reloaded.single.height, 220);
      expect(reloaded.single.strokes.single.points.last.x, closeTo(0.9, 1e-9));

      await store.remove(reloaded.single);
      expect(await store.load('book-a', 'chapter-1'), isEmpty);
    });

    test('normalized/strokesForBox 往返：盒子变化内容等比伸缩不丢失', () {
      const raw = [
        InkStroke(
          points: [
            InkPoint(x: 100, y: 50, pressure: 0.5, t: 0),
            InkPoint(x: 200, y: 150, pressure: 0.5, t: 9),
          ],
        ),
      ];
      final normalized = ReaderInkBlock.normalized(
        raw,
        boxWidth: 400,
        boxHeight: 200,
      );
      expect(normalized.single.points.first.x, closeTo(0.25, 1e-9));
      final expanded = normalized.first.points;
      // 直接从归一化展开到 800×400：
      final block = ReaderInkBlock(
        bookId: 'b',
        chapterId: 'c',
        anchor: 0,
        anchorContext: '',
        kind: ReaderInkBlock.kindCanvas,
        height: 400,
        strokes: normalized,
        createdAt: 0,
        updatedAt: 0,
      );
      final inBox = block.strokesForBox(800, 400);
      expect(inBox.single.points.first.x, closeTo(200, 1e-9));
      expect(inBox.single.points.last.y, closeTo(300, 1e-9));
      expect(expanded, isNotEmpty);
    });
  });

  group('ReaderChapterLayout 内嵌手写块', () {
    final content = ChapterContent(
      blocks: [
        List.filled(6, '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。').join(),
        List.filled(4, '山那边的雾气还未散尽，石阶一路向上延伸到竹林深处。').join(),
        '完。',
      ].map(ChapterParagraph.new).toList(),
    );

    ReaderChapterLayout layout({List<ReaderInlineNote> notes = const []}) =>
      ReaderChapterLayout(
        title: '第一章 山间来信',
        content: content,
        spec: ReaderLayoutSpec(
          viewport: const Size(390, 760),
          textScaler: TextScaler.linear(1),
          preferences: const ReaderPreferences(),
          fontFamily: null,
        ),
        inlineNotes: notes,
      );

    test('画布块占据布局空间，锚点行之后文字继续（断流下移重排）', () {
      final plain = layout();
      final withCanvas = layout(
        notes: const [
          ReaderInlineNote(
            id: 'ib-1',
            start: 60,
            end: 60,
            quote: '',
            thought: '',
            inkKind: ReaderInlineNote.inkKindCanvas,
            inkHeight: 180,
            inkFilled: true,
          ),
        ],
      );
      // 画布块存在且高度 = inkHeight + 装饰 8。
      final canvasBlocks = withCanvas.blocks
          .where((b) => b.inlineNote?.inkKind == ReaderInlineNote.inkKindCanvas)
          .toList();
      expect(canvasBlocks, hasLength(1));
      expect(canvasBlocks.single.height, closeTo(188, 0.01));
      // 文字总块数变多（锚点段落被切开）且正文没有丢字。
      List<String> textOf(ReaderChapterLayout l) => l.blocks
          .where((b) => b.inlineNote == null)
          .map((b) => b.text)
          .toList();
      expect(textOf(withCanvas).join(), textOf(plain).join());
      // 画布之后仍有文字块（下移重排，不是终点）。
      final canvasIndex = withCanvas.blocks.indexOf(canvasBlocks.single);
      expect(
        withCanvas.blocks.skip(canvasIndex + 1).any((b) => b.text.isNotEmpty),
        isTrue,
      );
    });

    test('便签/备注折叠行定高 34', () {
      final withSticky = layout(
        notes: const [
          ReaderInlineNote(
            id: 'ib-sticky',
            start: 30,
            end: 30,
            quote: '',
            thought: '',
            inkKind: ReaderInlineNote.inkKindSticky,
            inkFilled: true,
          ),
          ReaderInlineNote(
            id: 'ib-note',
            start: 90,
            end: 90,
            quote: '',
            thought: '',
            inkKind: ReaderInlineNote.inkKindNote,
            inkFilled: false,
          ),
        ],
      );
      final iconRows = withSticky.blocks
          .where(
            (b) =>
                b.inlineNote != null &&
                b.inlineNote!.inkKind != ReaderInlineNote.inkKindCanvas,
          )
          .toList();
      expect(iconRows, hasLength(2));
      for (final row in iconRows) {
        expect(row.height, closeTo(34, 0.01));
        expect(row.noteLines, 0);
      }
    });

    test('改字号（重排）后画布仍锚在原文字附近，不漂移', () {
      const note = ReaderInlineNote(
        id: 'ib-1',
        start: 60,
        end: 60,
        quote: '',
        thought: '',
        inkKind: ReaderInlineNote.inkKindCanvas,
        inkHeight: 160,
        inkFilled: true,
      );
      final small = layout(notes: const [note]);
      final big = ReaderChapterLayout(
        title: '第一章 山间来信',
        content: content,
        spec: ReaderLayoutSpec(
          viewport: const Size(390, 760),
          textScaler: TextScaler.linear(1.6),
          preferences: const ReaderPreferences(),
          fontFamily: null,
        ),
        inlineNotes: const [note],
      );
      // 画布块的 start = 锚点行的行尾（布局切片点），字号变化时行宽变化
      // 切片点随之移动——锚定的本质是「锚点字符 60 落在画布前一行内」：
      // 画布始终跟住那行文字，不按像素漂移。
      ReaderContentBlock canvasOf(ReaderChapterLayout l) =>
          l.blocks.singleWhere(
            (b) => b.inlineNote?.inkKind == ReaderInlineNote.inkKindCanvas,
          );
      int anchorLineStart(ReaderChapterLayout l) {
        final canvas = canvasOf(l);
        final index = l.blocks.indexOf(canvas);
        return index > 0
            ? canvas.start - l.blocks[index - 1].lines.last.end
            : canvas.start;
      }

      for (final l in [small, big]) {
        final canvas = canvasOf(l);
        expect(canvas.start, greaterThanOrEqualTo(60),
            reason: '画布切片点必须不早于锚点字符');
        expect(anchorLineStart(l), lessThanOrEqualTo(60),
            reason: '画布切片点必须不晚于锚点所在行的行首之后');
        expect(canvas.start - 60, lessThan(80),
            reason: '锚点行与画布间距必须在一行字符内（跟字不漂移）');
      }
      expect(canvasOf(big).height, closeTo(168, 0.01));
    });
  });
}
