import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_note_block.dart';

/// 渲染端 `ReaderNoteBlock` 的正文样式：fontSize 13 / height 1.5。
/// 排版端 `_measureInlineNote` 必须用同一套值测量，否则行数与高度对不上。
/// 行高以 TextPainter 实测为准（13 * 1.5 会被 Flutter 取整成 20）。
const double _noteFontSize = 13;
const double _noteLineHeight = 1.5;

/// 批注块纵向固定开销（容器内边距 16 + 底部外边距 6）。
const double _noteChromeHeight = 22;

const String _title = '第一章 山间来信';

/// 实测的批注单行高度。
double get _measuredLineHeight => _measureLineHeight(TextScaler.noScaling);

double _measureLineHeight(TextScaler scaler) {
  final painter = TextPainter(
    text: const TextSpan(
      text: '中',
      style: TextStyle(fontSize: _noteFontSize, height: _noteLineHeight),
    ),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('行内批注块的高度封顶', () {
    for (final width in [320.0, 60.0]) {
      for (final bodyLength in [500, 2000]) {
        test('width=$width body=$bodyLength：高度不超过 '
            '${ReaderChapterLayout.inlineNoteMaxLines} 行 + 固定开销', () {
          final layout = _layoutWithLongNote(
            width: width,
            bodyLength: bodyLength,
          );
          final note = layout.blocks.firstWhere((block) => block.isNote);
          final lineHeight = _measuredLineHeight;
          final maxHeight =
              ReaderChapterLayout.inlineNoteMaxLines * lineHeight +
              _noteChromeHeight +
              .001;

          expect(
            note.noteLines,
            lessThanOrEqualTo(ReaderChapterLayout.inlineNoteMaxLines),
            reason:
                '批注正文被量成了 ${note.noteLines} 行（body=$bodyLength，'
                'width=$width），渲染端会按同样的行数画省略号',
          );
          expect(
            note.height,
            lessThanOrEqualTo(maxHeight),
            reason:
                '修复前该块实测 ${note.height}px（body=$bodyLength，'
                'width=$width），远超 ${maxHeight}px 的上限；保存后整章重排'
                '会把上万像素的块塞进一页，真机上表现为 RenderFlex overflow '
                '并整页退出',
          );
        });
      }
    }

    test('窄视口下整块高度仍不超过页高（且不抛异常）', () {
      // 极端窄屏 / 分屏 / 放大字号：可用宽度被压到比批注块固定装饰还窄。
      for (final size in [const Size(100, 640), const Size(240, 85)]) {
        final layout = _layoutWithLongNote(viewport: size, bodyLength: 2000);
        final note = layout.blocks.firstWhere((block) => block.isNote);
        expect(
          note.height,
          lessThanOrEqualTo(layout.spec.pageHeight),
          reason:
              '${size.width}x${size.height} 下单块 ${note.height}px '
              '超过页高 ${layout.spec.pageHeight}px',
        );
        expect(note.height, greaterThan(0), reason: '把高度压成 0 会让渲染端的角标/文案溢出');
        // 半屏夹值：正常视口下必须严格小于半屏。
        if (layout.spec.pageHeight >= 160) {
          expect(note.height, lessThan(layout.spec.pageHeight / 2));
        }
      }
    });

    test('分页结果里没有超过页高的块，且批注块独占不可分割', () {
      final layout = _layoutWithLongNote(width: 60, bodyLength: 2000);
      final note = layout.blocks.firstWhere((block) => block.isNote);
      final page = layout.pages[layout.pageForOffset(note.start)];
      expect(
        page.fragments.any((fragment) => fragment.block.isNote),
        isTrue,
        reason: '批注块必须落在某个分页里，不能被丢掉',
      );
      for (final fragment in page.fragments) {
        if (!fragment.block.isNote) continue;
        expect(fragment.firstLine, 0);
        expect(fragment.lastLine, 0);
        expect(
          fragment.height,
          lessThanOrEqualTo(layout.spec.pageHeight + .001),
        );
      }
      for (final p in layout.pages) {
        if (p.height <= layout.spec.pageHeight + .001) continue;
        expect(
          p.fragments,
          hasLength(1),
          reason:
              '只有「单行块本身比页高」才允许整页只放一块，'
              '这里高度应当已被封顶',
        );
      }
      expect(layout.contentHeight.isFinite, isTrue);
      expect(
        layout.contentHeight,
        lessThan(layout.spec.pageHeight * 20),
        reason: '封顶后章高不应再被一条批注撑到几万像素',
      );
    });

    test('正常宽度下长批注仍能被完整测量（不越过封顶，但保持可读高度）', () {
      final layout = _layoutWithLongNote(width: 320, bodyLength: 2000);
      final note = layout.blocks.firstWhere((block) => block.isNote);
      expect(
        note.height,
        closeTo(
          ReaderChapterLayout.inlineNoteMaxLines * _measuredLineHeight +
              _noteChromeHeight,
          .001,
        ),
        reason: '正常宽度下长批注应当稳定占满封顶的 8 行，而不是被压成 1 行',
      );
    });

    test('短批注不会被抬高到封顶高度', () {
      final layout = _build(
        viewport: const Size(360, 640),
        notes: [
          ReaderInlineNote(
            id: 'short',
            start: _title.length + 1 + 4,
            end: _title.length + 1 + 8,
            quote: '清晨的风',
            thought: '这里写得好。',
          ),
        ],
      );
      final note = layout.blocks.firstWhere((block) => block.isNote);
      expect(note.noteLines, 1);
      expect(
        note.height,
        lessThan(4 * _noteFontSize * _noteLineHeight),
        reason: '短批注只占 1 行，不该留出整块 8 行的空白',
      );
    });

    testWidgets('渲染端用同一条行数上限，且容器不溢出', (tester) async {
      final layout = _layoutWithLongNote(width: 320, bodyLength: 2000);
      final note = layout.blocks.firstWhere((block) => block.isNote);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: layout.spec.width,
                child: ReaderBlockContent(block: note, spec: layout.spec),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ReaderNoteBlock)).height,
        closeTo(note.height, .01),
        reason: '批注块的 SizedBox 高度必须等于排版层实测高度',
      );
      final rendered = tester.widget<Text>(
        find.byKey(ValueKey('reader-note-text-${note.inlineNote!.id}')),
      );
      expect(
        rendered.maxLines,
        note.noteLines,
        reason:
            '渲染端 maxLines 必须与测量端封顶后的行数一致，'
            '否则文字会被裁掉或撑出块外',
      );
      expect(rendered.maxLines, lessThanOrEqualTo(note.noteLines));
    });
  });

  group('批注块插入位置', () {
    test('批注块紧跟所属段落，并把后续块的 top 顺移', () {
      final layout = _layoutWithLongNote(width: 320, bodyLength: 800);
      final noteIndex = layout.blocks.indexWhere((block) => block.isNote);
      expect(noteIndex, greaterThan(0));
      final anchor = layout.blocks[noteIndex - 1];
      final note = layout.blocks[noteIndex];
      final after = layout.blocks[noteIndex + 1];
      expect(anchor.isBody, isTrue);
      expect(
        note.top,
        closeTo(
          anchor.top + anchor.height + layout.spec.paragraphSpacing,
          .001,
        ),
      );
      expect(
        after.top,
        closeTo(note.top + note.height + layout.spec.paragraphSpacing, .001),
      );
    });

    test('找不到归属的批注挂到章末而不是静默丢弃', () {
      final layout = _build(
        viewport: const Size(360, 640),
        notes: [
          ReaderInlineNote(
            id: 'stale',
            start: 999999,
            end: 1000000,
            quote: '上一章残留',
            thought: '残留批注',
          ),
        ],
      );
      final notes = layout.blocks.where((block) => block.isNote).toList();
      expect(notes, hasLength(1));
      expect(notes.single.index, greaterThan(layout.blocks.length - 3));
      expect(layout.blocks.last.isNote, isTrue);
    });
  });
}

ReaderChapterLayout _layoutWithLongNote({
  double? width,
  Size? viewport,
  required int bodyLength,
}) {
  final size = viewport ?? Size((width ?? 320) + 40, 640);
  final unit = '清晨的风从窗边吹来，带着山间草木的清香。';
  final body = List.filled(
    (bodyLength / unit.length).ceil(),
    unit,
  ).join().substring(0, bodyLength);
  return _build(
    viewport: size,
    notes: [
      ReaderInlineNote(
        id: 'long',
        start: _title.length + 1 + 5,
        end: _title.length + 1 + 40,
        // 相当于「书摘」或用户直接粘贴了一整段原文：body 就是这 500/2000 字。
        quote: body.substring(0, math.min(body.length, 40)),
        thought: body,
      ),
    ],
  );
}

ReaderChapterLayout _build({
  required Size viewport,
  required List<ReaderInlineNote> notes,
}) {
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return ReaderChapterLayout(
    title: _title,
    content: ChapterContent(
      blocks: [
        ChapterParagraph(List.filled(12, '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗。').join()),
        ChapterParagraph('第二段：他把信笺摊在桌上，逐字读了两遍。'),
        ChapterParagraph('第三段：山里的雾气还没有散，远处的钟声已经响过。'),
      ],
    ),
    spec: spec,
    inlineNotes: notes,
  );
}
