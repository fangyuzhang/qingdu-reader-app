import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/chapter_text_formatter.dart';
import '../../services/reader_preferences.dart';
import '../../services/reader_underline_store.dart';
import 'reader_bubble.dart';
import 'reader_illustration.dart';
import '../../models/chapter_ideas.dart';
import 'reader_note_block.dart';
import 'reader_text_selection.dart';
import 'reader_theme.dart';

/// Layout inputs exclude brightness and page mode, which do not change text.
@immutable
class ReaderLayoutSpec {
  final Size viewport;
  final TextScaler textScaler;
  final TextStyle bodyStyle;
  final TextStyle titleStyle;
  final TextAlign titleAlign;
  final double horizontalPadding;
  final double verticalPadding;
  final double paragraphSpacing;

  ReaderLayoutSpec({
    required this.viewport,
    required this.textScaler,
    required ReaderPreferences preferences,
    required String? fontFamily,
  }) : horizontalPadding = preferences.horizontalPadding,
       verticalPadding = preferences.verticalPadding,
       paragraphSpacing = preferences.paragraphSpacing,
       titleAlign = preferences.titleAlignment == ReaderTitleAlignment.center
           ? TextAlign.center
           : TextAlign.start,
       bodyStyle = TextStyle(
         inherit: false,
         color: preferences.themePreset.textColor,
         fontFamily: fontFamily,
         fontSize: preferences.fontSize,
         fontWeight: FontWeight.values[preferences.fontWeight ~/ 100 - 1],
         height: preferences.lineHeight,
         letterSpacing: preferences.letterSpacing,
         textBaseline: TextBaseline.alphabetic,
       ),
       titleStyle = TextStyle(
         inherit: false,
         color: preferences.themePreset.textColor,
         fontFamily: fontFamily,
         fontSize: preferences.titleSize,
         fontWeight: FontWeight.w600,
         height: 1.55,
         letterSpacing: 0,
         textBaseline: TextBaseline.alphabetic,
       );

  double get width => math.max(1, viewport.width - horizontalPadding * 2);
  double get pagePadding => math.min(verticalPadding, viewport.height / 4);
  double get pageHeight => math.max(1, viewport.height - pagePadding * 2);
  double get navigationHeight => math.max(48, textScaler.scale(14) * 1.4 + 24);
  double get footerHeight => navigationHeight + 12;

  @override
  bool operator ==(Object other) =>
      other is ReaderLayoutSpec &&
      viewport == other.viewport &&
      textScaler == other.textScaler &&
      bodyStyle == other.bodyStyle &&
      titleStyle == other.titleStyle &&
      titleAlign == other.titleAlign &&
      horizontalPadding == other.horizontalPadding &&
      verticalPadding == other.verticalPadding &&
      paragraphSpacing == other.paragraphSpacing;

  @override
  int get hashCode => Object.hash(
    viewport,
    textScaler,
    bodyStyle,
    titleStyle,
    titleAlign,
    horizontalPadding,
    verticalPadding,
    paragraphSpacing,
  );
}

@immutable
class ReaderTextLine {
  final int start;
  final int end;
  final double top;
  final double bottom;

  const ReaderTextLine(this.start, this.end, this.top, this.bottom);

  double get height => bottom - top;
}

/// 行内批注块（蜗牛读书式）的排版数据。
///
/// 【青茄重构·新增】批注块在排版层是一个「单行、整块高度」的合成块：
/// 分页时整块落页（本页放不下就整块推到下一页，绝不从中间切断），
/// 滚动时按同一高度占位。分页与滚动因此共用一套测量结果，
/// 不需要为两种阅读模式各写一套批注排版。
@immutable
class ReaderInlineNote {
  const ReaderInlineNote({
    required this.id,
    required this.start,
    required this.end,
    required this.quote,
    required this.thought,
    this.isExcerpt = false,
  });

  /// 存储键（`ReaderAnnotationStore.keyFor`）——批注块内的编辑/删除回写用。
  final String id;

  /// 章节展示文本坐标，与 [ReaderRangeUnderline] 同一空间。
  final int start;
  final int end;

  /// 被标注的原文。
  final String quote;

  /// 想法；书摘为空串。
  final String thought;

  /// true = 书摘（角标「摘」），false = 批注（角标「批」）。
  final bool isExcerpt;

  /// 块内展示的文字：有想法用想法，书摘/纯收藏用原文。
  String get body => thought.trim().isEmpty ? quote : thought;
}

@immutable
class ReaderContentBlock {
  final int index;
  final String text;
  final int start;
  final int legacyStart;
  final double top;
  final double height;
  final TextSpan span;
  final TextAlign align;
  final List<ReaderTextLine> lines;
  final ChapterImage? illustration;

  /// Upstream paragraph id, when the source carried one. Paragraph-comment
  /// bubbles are keyed by this, not by the block's ordinal position.
  final int? paraIndex;

  /// Identity of this paragraph for local features (划线, the long-press menu):
  /// [paraIndex] when the markup carried one, else an ordinal-derived id. The
  /// title block has none — it is not a paragraph the user edits.
  final int? textId;

  /// Start of this paragraph's audio in the chapter, in milliseconds, when the
  /// chapter shipped a spoken timeline. 从本段听 seeks to this.
  final int? startMs;

  /// Paragraph-comment count rendered as a bubble at the end of the last line;
  /// null when the paragraph has none or the upstream gate did not pass.
  final int? bubbleCount;

  /// Which official mask the bubble uses; see [bubbleCount].
  final ParagraphBubbleVariant? bubbleVariant;

  /// Whether this paragraph carries a locally saved 划线.
  final bool underlined;

  /// 【青茄重构·新增】非空表示这是一个行内批注块（不是正文段落）。
  final ReaderInlineNote? inlineNote;

  /// 批注块正文的实测行数（渲染时限制 maxLines，保证不发生溢出）。
  final int noteLines;

  const ReaderContentBlock({
    required this.index,
    required this.text,
    required this.start,
    required this.legacyStart,
    required this.top,
    required this.height,
    required this.span,
    required this.align,
    required this.lines,
    this.illustration,
    this.paraIndex,
    this.textId,
    this.startMs,
    this.bubbleCount,
    this.bubbleVariant,
    this.underlined = false,
    this.inlineNote,
    this.noteLines = 0,
  });

  int get end => start + text.length;
  bool get isTitle => index == 0;
  bool get isImage => illustration != null;
  bool get hasBubble => bubbleCount != null;

  /// 【青茄重构·新增】行内批注块；正文段落为 false。
  bool get isNote => inlineNote != null;

  /// 可参与选区/划线/复制的正文段落。
  bool get isBody => !isTitle && !isImage && !isNote;

  /// 仅替换纵向位置（插入批注块后需要重排后续块的 top）。
  ReaderContentBlock withTop(double value) => ReaderContentBlock(
    index: index,
    text: text,
    start: start,
    legacyStart: legacyStart,
    top: value,
    height: height,
    span: span,
    align: align,
    lines: lines,
    illustration: illustration,
    paraIndex: paraIndex,
    textId: textId,
    startMs: startMs,
    bubbleCount: bubbleCount,
    bubbleVariant: bubbleVariant,
    underlined: underlined,
    inlineNote: inlineNote,
    noteLines: noteLines,
  );
}

/// Translates a TTS sentence range into layout display-text coordinates.
///
/// TTS text is the body paragraphs (title stripped, images excluded) joined
/// by '\n'; the layout blocks are `[title, ...body]` with image blocks
/// consuming layout space only (placeholder + separator). Walking the
/// blocks while tracking the TTS cursor aligns the two spaces exactly,
/// including chapters with illustrations. A range landing on a paragraph
/// separator clamps to the previous paragraph's end; a range with no
/// overlap returns null.
({int start, int end})? narrationLayoutRange(
  ReaderChapterLayout layout,
  ({int start, int end}) ttsRange,
) {
  var ttsCursor = 0;
  var layoutStart = -1;
  var layoutEnd = -1;
  for (var i = 1; i < layout.blocks.length; i++) {
    final block = layout.blocks[i];
    if (block.isImage) continue;
    final ttsStart = ttsCursor;
    final ttsEnd = ttsCursor + block.text.length;
    final from = math.max(ttsRange.start, ttsStart) - ttsStart;
    final to = math.min(ttsRange.end, ttsEnd) - ttsStart;
    if (to > from) {
      final start = block.start + from;
      final end = block.start + to;
      if (layoutStart < 0) layoutStart = start;
      layoutEnd = end;
    }
    ttsCursor = ttsEnd + 1; // '\n' separator in TTS text.
  }
  if (layoutStart < 0) return null;
  return (start: layoutStart, end: layoutEnd);
}

/// A slice retains its original paragraph layout, including justification.
/// Reflowing a substring here would change line breaks and repeat indentation.
@immutable
class ReaderPageFragment {
  final ReaderContentBlock block;
  final int firstLine;
  final int lastLine;
  final double top;

  const ReaderPageFragment({
    required this.block,
    required this.firstLine,
    required this.lastLine,
    required this.top,
  });

  double get sourceTop => block.lines[firstLine].top;
  double get height => block.lines[lastLine].bottom - sourceTop;
  int get start => block.start + block.lines[firstLine].start;
  int get end => block.start + block.lines[lastLine].end;
  String get text =>
      block.text.substring(start - block.start, end - block.start);
}

@immutable
class ReaderTextPage {
  final List<ReaderPageFragment> fragments;

  const ReaderTextPage(this.fragments);

  int get start => fragments.first.start;
  int get end => fragments.last.end;
  double get height => fragments.last.top + fragments.last.height;
}

// Note: 两种阅读方式共用行测量，进度保存规范化正文的文字偏移；见
// .agents/notes/implemented/feature/2026-09-10-reader-pagination.md
class ReaderChapterLayout {
  /// 批注块正文最多显示的行数（排版测量与渲染共用）。
  static const int inlineNoteMaxLines = _kNoteMaxLines;

  final ReaderLayoutSpec spec;
  final List<ReaderContentBlock> blocks;
  final List<ReaderTextPage> pages;
  final int textLength;
  final double contentHeight;
  final int legacyTextLength;

  ReaderChapterLayout._(
    this.spec,
    this.blocks,
    this.pages,
    this.textLength,
    this.contentHeight,
    this.legacyTextLength,
  );

  factory ReaderChapterLayout({
    required String title,
    required ChapterContent content,
    required ReaderLayoutSpec spec,
    Map<int, int> paragraphBubbles = const {},
    Map<int, ParagraphBubbleVariant> paragraphBubbleVariants = const {},
    Set<int> underlinedParagraphs = const {},
    Widget Function(int paraIndex, int count, ParagraphBubbleVariant variant)?
    bubbleBuilder,
    List<ReaderInlineNote> inlineNotes = const [],
  }) {
    final body = content.withoutLeadingTitle(title);
    final legacyText = [
      if (title.isNotEmpty) title,
      ...splitChapterParagraphs(body.legacyText),
    ].join('\n');
    final blocks = <ReaderContentBlock>[];
    var offset = 0;
    var legacyCursor = 0;
    var top = 0.0;
    for (final element in [ChapterParagraph(title), ...body.blocks]) {
      final text = element is ChapterParagraph ? element.text : '\uFFFC';
      var legacyStart = legacyCursor;
      if (element is ChapterParagraph) {
        final found = legacyText.indexOf(text, legacyCursor);
        if (found >= 0) legacyStart = found;
        legacyCursor = (legacyStart + text.length).clamp(0, legacyText.length);
      }
      final paraIndex = element is ChapterParagraph ? element.paraIndex : null;
      final startMs = element is ChapterParagraph ? element.startMs : null;
      final bubbleCount = paraIndex == null
          ? null
          : paragraphBubbles[paraIndex];
      final bubbleVariant = paraIndex == null
          ? ParagraphBubbleVariant.plain
          : paragraphBubbleVariants[paraIndex] ?? ParagraphBubbleVariant.plain;
      final bubble = bubbleCount == null || bubbleBuilder == null
          ? null
          : bubbleBuilder(paraIndex!, bubbleCount, bubbleVariant);
      final blockIndex = blocks.length;
      // The title is block 0 and is not an editable paragraph, so the ordinal
      // used for identity starts at the first body paragraph. The title itself
      // must not take a textId: its ordinal fallback would be -(-1 + 1) = 0,
      // colliding with an upstream idx="0" on the first body paragraph.
      final textId = element is ChapterParagraph && blockIndex > 0
          ? paragraphUnderlineId(
              paraIndex: paraIndex,
              blockIndex: blockIndex - 1,
            )
          : null;
      final underlined =
          textId != null && underlinedParagraphs.contains(textId);
      final block = element is ChapterImage
          ? _measureImage(
              element,
              index: blockIndex,
              start: offset,
              legacyStart: legacyStart,
              top: top,
              spec: spec,
            )
          : _measureBlock(
              text,
              index: blockIndex,
              start: offset,
              legacyStart: legacyStart,
              top: top,
              spec: spec,
              paraIndex: paraIndex,
              textId: textId,
              startMs: startMs,
              bubbleCount: bubbleCount,
              bubbleVariant: bubbleVariant,
              bubble: bubble,
              underlined: underlined,
            );
      blocks.add(block);
      // An absent title contributes neither text nor a leading newline.
      offset += text.length + (block.isTitle && text.isEmpty ? 0 : 1);
      if (block.lines.isNotEmpty) {
        top += block.height + spec.paragraphSpacing;
      }
    }
    // 【青茄重构·新增】把批注块插到所属段落之后，并统一重排纵向位置。
    final (laidOutBlocks, contentTop) = inlineNotes.isEmpty
        ? (blocks, top)
        : _insertInlineNotes(blocks, inlineNotes, spec);
    final pages = _paginate(laidOutBlocks, spec);
    return ReaderChapterLayout._(
      spec,
      List.unmodifiable(laidOutBlocks),
      List.unmodifiable(pages),
      math.max(0, offset - 1),
      contentTop,
      legacyText.length,
    );
  }

  double get maxScroll => math.max(
    0,
    contentHeight +
        spec.verticalPadding * 2 +
        spec.footerHeight +
        32 -
        spec.viewport.height,
  );

  int pageForOffset(int offset) =>
      _floorIndex(pages.length, (index) => pages[index].start <= offset);

  int offsetFromLegacyText(int offset) {
    if (offset <= 0) return 0;
    final target = offset.clamp(0, legacyTextLength);
    var block = blocks.first;
    for (final candidate in blocks) {
      if (candidate.isImage || candidate.text.isEmpty) continue;
      if (candidate.legacyStart > target) break;
      block = candidate;
    }
    return block.start +
        (target - block.legacyStart).clamp(0, block.text.length);
  }

  int legacyOffsetForText(int offset) {
    if (offset <= 0) return 0;
    final block =
        blocks[_floorIndex(blocks.length, (i) => blocks[i].start <= offset)];
    return (block.legacyStart +
            (block.isImage
                ? 0
                : (offset - block.start).clamp(0, block.text.length)))
        .clamp(0, legacyTextLength);
  }

  /// The first visible line is the anchor, even when its top is partly clipped.
  int textOffsetAtScroll(double scroll) {
    final y = scroll - spec.verticalPadding;
    if (y <= 0) return 0;
    var index = _floorIndex(blocks.length, (index) => blocks[index].top <= y);
    var block = blocks[index];
    if (y >= block.top + block.height) {
      if (++index >= blocks.length) return textLength;
      block = blocks[index];
      return block.start;
    }
    final line = _floorIndex(
      block.lines.length,
      (index) => block.lines[index].top <= y - block.top,
    );
    return block.start + block.lines[line].start;
  }

  double scrollForTextOffset(int offset) {
    if (offset <= 0) return 0;
    if (offset >= textLength) return maxScroll;
    final block =
        blocks[_floorIndex(
          blocks.length,
          (index) => blocks[index].start <= offset,
        )];
    final line =
        block.lines[_floorIndex(
          block.lines.length,
          (index) => block.start + block.lines[index].start <= offset,
        )];
    return (spec.verticalPadding + block.top + line.top).clamp(0, maxScroll);
  }

  /// New positions are independent of font, page count and viewport size.
  /// Old records remain readable; pixel ratios are used only for migration.
  ({int textOffset, double scroll}) restore(
    Map<String, dynamic>? saved, {
    required String chapterId,
    required bool startAtEnd,
    required bool paged,
  }) {
    if (startAtEnd) {
      return (
        textOffset: paged ? pages.last.start : textOffsetAtScroll(maxScroll),
        scroll: maxScroll,
      );
    }
    if (saved?['chapterId']?.toString() != chapterId ||
        (saved?['kind'] != null && saved?['kind'] != 'book')) {
      return (textOffset: 0, scroll: 0);
    }
    final rawOffset = saved?['textOffset'];
    if ((saved?['positionVersion'] == 1 || saved?['positionVersion'] == 2) &&
        rawOffset is num &&
        rawOffset.isFinite &&
        rawOffset >= 0 &&
        rawOffset == rawOffset.truncateToDouble()) {
      final offset = saved?['positionVersion'] == 1
          ? offsetFromLegacyText(rawOffset.clamp(0, legacyTextLength).toInt())
          : rawOffset.clamp(0, textLength).toInt();
      return (textOffset: offset, scroll: scrollForTextOffset(offset));
    }
    final rawPosition = saved?['position'];
    final rawMax = saved?['maxScroll'];
    var scroll = 0.0;
    if (rawPosition is num && rawPosition.isFinite && rawPosition > 0) {
      scroll = rawMax is num && rawMax.isFinite && rawMax > 0
          ? maxScroll * (rawPosition / rawMax).clamp(0, 1)
          : rawPosition.toDouble().clamp(0, maxScroll);
    }
    return (textOffset: textOffsetAtScroll(scroll), scroll: scroll);
  }

  /// First-line indent width. Shared by [_measureBlock] and [blockPainter] so
  /// hit-testing and glyph boxes wrap exactly like the rendered text.
  static double _indentWidth(TextStyle style, ReaderLayoutSpec spec) {
    final scale = spec.textScaler.scale(style.fontSize!) / style.fontSize!;
    return math.min(
      (style.fontSize! + (style.letterSpacing ?? 0)) * 2,
      math.max(0.0, spec.width / scale - style.fontSize!),
    );
  }

  /// The indent placeholder: one per body block, bottom-aligned with zero
  /// height (the indent only eats width).
  static PlaceholderDimensions _indentPlaceholder(
    TextStyle style,
    ReaderLayoutSpec spec,
  ) {
    final scale = spec.textScaler.scale(style.fontSize!) / style.fontSize!;
    return PlaceholderDimensions(
      size: Size(_indentWidth(style, spec) * scale, 0),
      alignment: PlaceholderAlignment.bottom,
    );
  }

  /// The bubble placeholder sized so the trailing glyph and the bubble never
  /// overlap; null when the block carries no bubble.
  static PlaceholderDimensions? _bubblePlaceholder({
    required TextStyle style,
    required ReaderLayoutSpec spec,
    required ParagraphBubbleVariant? variant,
    required int? count,
  }) {
    if (count == null) return null;
    final scale = spec.textScaler.scale(style.fontSize!) / style.fontSize!;
    final metrics = ReaderBubbleMetrics.forFontSize(
      spec.textScaler.scale(style.fontSize!),
      variant: variant ?? ParagraphBubbleVariant.plain,
    ).forCount(count);
    // The bubble's own left gap is inside the widget, so its placeholder
    // width has to include it. RenderParagraph wraps the WidgetSpan child in
    // an auto-scaling box (the same `scale` the indent placeholder uses), so
    // the measured box must be scaled too or the last line is measured short
    // and the bubble is clipped.
    return PlaceholderDimensions(
      size: Size(
        (metrics.width + ReaderBubbleMetrics.gap) * scale,
        metrics.height * scale,
      ),
      alignment: PlaceholderAlignment.middle,
    );
  }

  /// A laid-out painter matching what [ReaderBlockText] renders, for
  /// selection hit-testing and per-glyph boxes. Placeholders mirror the
  /// measured span exactly (indent, plus the bubble when the block carries
  /// one) — [TextPainter.setPlaceholderDimensions] asserts the counts match.
  /// The caller owns and disposes the painter.
  static TextPainter blockPainter(
    ReaderContentBlock block,
    ReaderLayoutSpec spec,
  ) {
    final title = block.isTitle;
    final style = title ? spec.titleStyle : spec.bodyStyle;
    var placeholders = 0;
    block.span.visitChildren((span) {
      if (span is PlaceholderSpan) placeholders++;
      return true;
    });
    final painter = TextPainter(
      text: block.span,
      textAlign: block.align,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      locale: const Locale('zh', 'CN'),
    );
    if (!title) {
      painter.setPlaceholderDimensions([
        _indentPlaceholder(style, spec),
        if (placeholders >= 2)
          ?_bubblePlaceholder(
            style: style,
            spec: spec,
            variant: block.bubbleVariant,
            count: block.bubbleCount,
          ),
      ]);
    }
    painter.layout(minWidth: spec.width, maxWidth: spec.width);
    return painter;
  }

  /// Chapter display text inside [start]..[end], assembled block by block.
  /// Image placeholders (`\uFFFC`, one per illustration for offset math only)
  /// are dropped so copied or underlined text is what a reader would quote.
  String textInRange(int start, int end) {
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block.start >= end) break;
      if (block.end <= start) continue;
      final from = math.max(start, block.start) - block.start;
      final to = math.min(end, block.end) - block.start;
      if (to <= from) continue;
      buffer.write(block.text.substring(from, to).replaceAll('\uFFFC', ''));
    }
    return buffer.toString();
  }

  /// Bounds a selection may move within: the first editable text block's
  /// start through the last one's end (the title and image-only chapters are
  /// excluded — a selection cannot begin on a title).
  (int, int)? get selectableTextRange {
    for (final block in blocks) {
      if (block.isTitle || block.isImage || block.lines.isEmpty) continue;
      var last = block;
      for (final candidate in blocks.reversed) {
        if (candidate.isTitle || candidate.isImage || candidate.lines.isEmpty) {
          continue;
        }
        last = candidate;
        break;
      }
      return (block.start, last.end);
    }
    return null;
  }

  /// The text block holding [offset], or null past the last block.
  ReaderContentBlock? blockAtOffset(int offset) {
    for (final block in blocks) {
      // 批注块不参与正文定位：它的 start 贴着上一段末尾，若参与匹配
      // 会与下一段的字符区间重叠，命中错误的块。
      if (block.isNote) continue;
      if (block.start <= offset && offset < block.end) return block;
    }
    return null;
  }

  /// The text block a selection bound at [offset] anchors its handle to: the
  /// block holding [offset], or — when [offset] sits on the '\n' separator
  /// between two blocks — the next block for a start bound, the previous one
  /// for an end bound.
  ReaderContentBlock? blockForAnchor(int offset, {required bool isStart}) {
    final holding = blockAtOffset(offset);
    if (holding != null) return holding;
    ReaderContentBlock? previous;
    for (final block in blocks) {
      if (!block.isBody || block.lines.isEmpty) continue;
      if (block.start >= offset) return isStart ? block : previous;
      previous = block;
    }
    return previous;
  }

  static ReaderContentBlock _measureBlock(
    String text, {
    required int index,
    required int start,
    required int legacyStart,
    required double top,
    required ReaderLayoutSpec spec,
    int? paraIndex,
    int? textId,
    int? startMs,
    int? bubbleCount,
    ParagraphBubbleVariant? bubbleVariant,
    Widget? bubble,
    bool underlined = false,
  }) {
    final title = index == 0;
    final style = title ? spec.titleStyle : spec.bodyStyle;
    final decoration = underlined && !title
        ? TextDecoration.underline
        : TextDecoration.none;
    final bodyStyle = style.copyWith(
      decoration: decoration,
      decorationColor: style.color,
      decorationStyle: TextDecorationStyle.solid,
      decorationThickness: 1.6,
    );
    final align = title ? spec.titleAlign : TextAlign.justify;
    final indent = _indentWidth(style, spec);
    // The bubble rides at the very end of the paragraph's text, so it follows
    // the last line and wraps only when that line has no room left. Measuring it
    // as a placeholder keeps paint and measurement in agreement.
    final bubbleSpan = bubble == null || bubbleCount == null
        ? null
        : WidgetSpan(alignment: PlaceholderAlignment.middle, child: bubble);
    final span = TextSpan(
      style: underlined && !title ? bodyStyle : style,
      children: [
        // RenderParagraph wraps inline children in an auto-scaling box
        // (_AutoScaleInlineWidget) using the surrounding span's font size, so
        // the child stays in unscaled em and still paints at indent * scale.
        // Note: 别把这里改成 indent * scale——会双重缩放。
        // 见 .agents/notes/implemented/bug-fix/2026-09-13-code-review-fixes.md
        if (!title) WidgetSpan(child: SizedBox(width: indent, height: 0)),
        TextSpan(text: text),
        ?bubbleSpan,
      ],
    );
    if (title && text.isEmpty) {
      return ReaderContentBlock(
        index: index,
        text: text,
        start: start,
        legacyStart: legacyStart,
        top: top,
        height: 0,
        span: span,
        align: align,
        lines: const [],
        paraIndex: paraIndex,
        textId: textId,
        startMs: startMs,
        bubbleCount: bubbleCount,
        bubbleVariant: bubbleVariant,
        underlined: underlined,
      );
    }
    final painter = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
      textScaler: spec.textScaler,
      locale: const Locale('zh', 'CN'),
    );
    try {
      if (!title) {
        painter.setPlaceholderDimensions([
          _indentPlaceholder(style, spec),
          ?_bubblePlaceholder(
            style: style,
            spec: spec,
            variant: bubbleVariant,
            count: bubbleCount,
          ),
        ]);
      }
      painter.layout(minWidth: spec.width, maxWidth: spec.width);
      final metricsList = painter.computeLineMetrics();
      final starts = <int>[];
      final tops = <double>[];
      // One placeholder per `\uFFFC`: the paragraph indent, then the bubble.
      final leading = title ? 0 : 1;
      final plainText =
          '${title ? '' : '\uFFFC'}$text${bubbleSpan == null ? '' : '\uFFFC'}';
      var cursor = 0;
      for (final line in metricsList) {
        // Hit-testing by y can jump into another line's emoji/RTL glyph box.
        // Walking logical line boundaries keeps offsets ordered in all fonts.
        var range = painter.getLineBoundary(TextPosition(offset: cursor));
        if (range.end <= cursor && cursor < plainText.length) {
          range = painter.getLineBoundary(TextPosition(offset: ++cursor));
        }
        starts.add((range.start - leading).clamp(0, text.length));
        tops.add(tops.isEmpty ? 0 : line.baseline - line.ascent);
        cursor = range.end;
        if (cursor < plainText.length && plainText.codeUnitAt(cursor) == 10) {
          cursor++;
        }
      }
      // Even an empty title has one measurable line in Flutter.
      if (starts.isEmpty) {
        starts.add(0);
        tops.add(0);
      }
      final boundaries = <int>{0};
      var characterOffset = 0;
      for (final character in text.characters) {
        boundaries.add(characterOffset += character.length);
      }
      // Some fallback fonts wrap a multi-codepoint emoji onto several lines.
      // Such a cluster, and any indent-only line, must stay on the same page.
      // A line holding only the bubble also has no cut of its own: it keeps
      // riding with the previous line so the bubble never lands alone.
      final cuts = <int>[0];
      for (var i = 1; i < starts.length; i++) {
        if (starts[i] > starts[cuts.last] &&
            starts[i] < text.length &&
            boundaries.contains(starts[i])) {
          cuts.add(i);
        }
      }
      return ReaderContentBlock(
        index: index,
        text: text,
        start: start,
        legacyStart: legacyStart,
        top: top,
        height: painter.height,
        span: span,
        align: align,
        lines: List.unmodifiable([
          for (var i = 0; i < cuts.length; i++)
            ReaderTextLine(
              starts[cuts[i]],
              i + 1 < cuts.length ? starts[cuts[i + 1]] : text.length,
              tops[cuts[i]],
              i + 1 < cuts.length ? tops[cuts[i + 1]] : painter.height,
            ),
        ]),
        paraIndex: paraIndex,
        textId: textId,
        startMs: startMs,
        bubbleCount: bubbleCount,
        bubbleVariant: bubbleVariant,
      );
    } finally {
      painter.dispose();
    }
  }

  static ReaderContentBlock _measureImage(
    ChapterImage image, {
    required int index,
    required int start,
    required int legacyStart,
    required double top,
    required ReaderLayoutSpec spec,
  }) {
    final ratio = image.aspectRatio;
    final usableRatio = ratio != null && ratio.isFinite && ratio > 0
        ? ratio
        : 3 / 4;
    // Reserve the full slot before loading. A decoded image never repaginates
    // the chapter or shifts saved text, and a tall image stays on one page.
    final height = math.min(spec.pageHeight, spec.width / usableRatio);
    return ReaderContentBlock(
      index: index,
      text: '\uFFFC',
      start: start,
      legacyStart: legacyStart,
      top: top,
      height: height,
      span: const TextSpan(),
      align: TextAlign.center,
      lines: [ReaderTextLine(0, 1, 0, height)],
      illustration: image,
    );
  }

  static List<ReaderTextPage> _paginate(
    List<ReaderContentBlock> blocks,
    ReaderLayoutSpec spec,
  ) {
    final pages = <ReaderTextPage>[];
    var fragments = <ReaderPageFragment>[];
    var used = 0.0;
    void finishPage() {
      if (fragments.isEmpty) return;
      pages.add(ReaderTextPage(List.unmodifiable(fragments)));
      fragments = [];
      used = 0;
    }

    for (final block in blocks) {
      if (block.lines.isEmpty) continue;
      for (var i = 0; i < block.lines.length; i++) {
        final line = block.lines[i];
        if (fragments.isNotEmpty &&
            used + line.height > spec.pageHeight + .001) {
          finishPage();
        }
        if (fragments.isNotEmpty && identical(fragments.last.block, block)) {
          final previous = fragments.removeLast();
          fragments.add(
            ReaderPageFragment(
              block: block,
              firstLine: previous.firstLine,
              lastLine: i,
              top: previous.top,
            ),
          );
        } else {
          fragments.add(
            ReaderPageFragment(
              block: block,
              firstLine: i,
              lastLine: i,
              top: used,
            ),
          );
        }
        used += line.height;
      }
      used += spec.paragraphSpacing;
    }
    finishPage();
    return pages;
  }
}

/// 批注块左右「非正文」宽度：容器内边距 16 + 角标 20 + 间距 8 +
/// 折叠/删除图标 32 + 间隙 4 = 80；改 [ReaderNoteBlock] 布局时必须同步。
const double _kNoteChromeWidth = 80;

/// 批注块纵向固定开销：容器上下内边距 16 + 底部外边距 6。
const double _kNoteChromeHeight = 22;

/// 角标高度（批注块首行至少这么高）。
const double _kNoteBadgeHeight = 20;

/// 批注正文最多测量的行数。超出部分渲染端以省略号收尾。
///
/// 这个上限是崩溃的止血点：`_measureInlineNote` 会把 `note.body`（用户想法，
/// 但也可能是整段被选中的原文）整段排版，行数不封顶时，窄屏 / 分屏 /
/// 大字号下可用宽度会被压到几十像素，一段两千字能折出上千行、上万像素高。
/// 这个高度会作为「单行块」进入分页并参与整章重排，真机上表现为
/// `RenderFlex overflowed by 99336 pixels` 后整页退出。
const int _kNoteMaxLines = 8;

/// 批注正文测量的可用宽度下限。
///
/// 不能取 40 这种小值：`spec.width - 80` 在窄屏上会退到 40，
/// 13px 的中文一行只放得下 3 个字，行数被极端放大。
const double _kNoteMinBodyWidth = 120;

/// 批注块用的合成块 index 起点，远离正文段落序号，避免 key 冲突。
const int _kInlineNoteIndexBase = 1000000;

/// 把批注块按字符位置插进所属段落之后。
///
/// 批注块的 `start` 落在某段落 [ReaderContentBlock.start]..[end] 之内即归属该段；
/// 找不到归属（例如跨章残留）时挂到章末，保证不会静默丢失。
/// 返回重排后的块列表与总高度。
(List<ReaderContentBlock>, double) _insertInlineNotes(
  List<ReaderContentBlock> blocks,
  List<ReaderInlineNote> inlineNotes,
  ReaderLayoutSpec spec,
) {
  final pending = List<ReaderInlineNote>.of(inlineNotes)
    ..sort((a, b) => a.start.compareTo(b.start));
  final out = <ReaderContentBlock>[];
  var cursor = 0;
  var ordinal = 0;
  var running = 0.0;

  void appendNote(ReaderInlineNote note, ReaderContentBlock anchor) {
    final noteBlock = _measureInlineNote(
      note,
      index: _kInlineNoteIndexBase + ordinal++,
      anchorStart: anchor.end,
      anchorLegacy: anchor.legacyStart + anchor.text.length,
      top: running,
      spec: spec,
    );
    out.add(noteBlock);
    running += noteBlock.height + spec.paragraphSpacing;
  }

  for (final block in blocks) {
    final placed = block.withTop(running);
    out.add(placed);
    if (placed.lines.isNotEmpty) {
      running += placed.height + spec.paragraphSpacing;
    }
    if (block.isTitle || block.isImage) continue;
    while (cursor < pending.length && pending[cursor].start <= block.end) {
      appendNote(pending[cursor++], block);
    }
  }
  if (cursor < pending.length && blocks.isNotEmpty) {
    final last = blocks.last;
    while (cursor < pending.length) {
      appendNote(pending[cursor++], last);
    }
  }
  return (out, running);
}

/// 测量一条批注块：先按批注文字风格量出正文高度，再折算成整块高度。
/// 渲染端（[ReaderNoteBlock]）用同一个高度与行数（[ReaderContentBlock.noteLines]），
/// 因此不会溢出。
///
/// 【崩溃修复】这里必须同时封顶「行数」和「高度」：
/// * 行数封顶 [_kNoteMaxLines]：`note.body` 可能是整段被选中的原文，窄屏下
///   一行只放两三个字，行数会被放大到几百上千（修复前实测 2000 字在 40px
///   可用宽度下折出 700 行、14022px 高，真机日志里见过 99336px 的溢出）。
///   渲染端用 `maxLines: block.noteLines` 画省略号，封顶行数两边就一致。
/// * 高度再夹到半屏：即使行高被 textScaler 放大，单块也不会超过一页，
///   分页不会出现「比页还高的块」，滚动模式也不会拿到异常高度。
ReaderContentBlock _measureInlineNote(
  ReaderInlineNote note, {
  required int index,
  required int anchorStart,
  required int anchorLegacy,
  required double top,
  required ReaderLayoutSpec spec,
}) {
  const style = TextStyle(
    inherit: false,
    color: Color(0xFF6B5B3E),
    fontSize: 13,
    height: 1.5,
    letterSpacing: 0,
    textBaseline: TextBaseline.alphabetic,
  );
  final body = note.body;
  // 宽度下限不能用 40：`spec.width - 80` 在窄屏 / 分屏 / 大字号下会退到
  // 几十像素，13px 中文一行只放得下 3 个字，行数被极端放大。
  final bodyWidth = math.max(
    _kNoteMinBodyWidth,
    spec.width - _kNoteChromeWidth,
  );
  final painter = TextPainter(
    text: TextSpan(text: body, style: style),
    textDirection: TextDirection.ltr,
    textScaler: spec.textScaler,
    // 测量端与渲染端一样按行数截断，多出来的字渲染端用省略号收尾。
    maxLines: _kNoteMaxLines,
    ellipsis: '…',
  );
  final int lines;
  final double rawHeight;
  try {
    painter.layout(maxWidth: bodyWidth);
    lines = painter.computeLineMetrics().length.clamp(1, _kNoteMaxLines);
    rawHeight =
        math.max(_kNoteBadgeHeight, painter.height) + _kNoteChromeHeight;
  } finally {
    painter.dispose();
  }
  // 上限：半屏。下限：角标 20 + 容器内边距 16 + 底部外边距 6 = 42，
  // 低于它渲染端的 Row 会垂直溢出（角标画不进块里）。
  final maxHeight = math.max(
    _kNoteBadgeHeight + _kNoteChromeHeight,
    spec.pageHeight / 2,
  );
  final height = math.min(rawHeight, math.min(maxHeight, spec.pageHeight));
  return ReaderContentBlock(
    index: index,
    text: body,
    start: anchorStart,
    legacyStart: anchorLegacy,
    top: top,
    height: height,
    span: TextSpan(text: body, style: style),
    align: TextAlign.start,
    // 单行、整块高度：分页时整块落页，绝不从中间切断。
    lines: [ReaderTextLine(0, 0, 0, height)],
    inlineNote: note,
    noteLines: lines,
  );
}

/// 在一段文字里找出包含 [index] 的句子范围（半开区间，返回 `(start, end)`）。
///
/// 【青茄修复·长按选句】长按选区的默认粒度从「整段」改成「一句话」：
/// 句末按中文句读切分——`。！？!?…；;` 与换行；紧随其后的右引号/右书名号
/// 计入本句（"好吧。" 整体算一句）。与 TTS 的分句口径保持一致
/// （system_tts 的 `_speak` 用同一组断句字符）。
(int, int) sentenceRangeInText(String text, int index) {
  if (text.isEmpty) return (0, 0);
  const enders = '。！？!?…；;\n';
  const closers = '”』」》〉）)';
  final i = index.clamp(0, text.length - 1);
  // 句子起点：往回找最近的句末标点，落在其后。
  var start = 0;
  for (var j = i - 1; j >= 0; j--) {
    if (enders.contains(text[j])) {
      start = j + 1;
      break;
    }
  }
  // 起点落在右引号上（前一句刚以 "。”" 收尾）时跳过，别选出一个空壳句。
  while (start < text.length && closers.contains(text[start])) {
    start++;
  }
  // 句子终点：从按下处往后找第一个句末标点，连着右引号一起收进来。
  var end = text.length;
  for (var j = i; j < text.length; j++) {
    if (enders.contains(text[j])) {
      end = j + 1;
      while (end < text.length && closers.contains(text[end])) {
        end++;
      }
      break;
    }
  }
  if (end <= start) return (start, text.length);
  return (start, end);
}

int _floorIndex(int length, bool Function(int) atOrBefore) {
  var low = 0;
  var high = length - 1;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (atOrBefore(middle)) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

/// Shared by the scroll list and clipped page fragments.
class ReaderBlockContent extends StatelessWidget {
  final ReaderContentBlock block;
  final ReaderLayoutSpec spec;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Long-press target for a text paragraph (复制 / 从本段听 / 划线). The offset is
  /// the touch point in global coordinates, which the floating action bar
  /// anchors itself to.
  final void Function(ReaderContentBlock block, Offset globalPosition)?
  onParagraphLongPress;

  /// 官方的不抬手拖动: while the finger stays down after a long press these
  /// deliver its moves and release, so the selection reshapes without ever
  /// grabbing a handle. Global coordinates.
  final void Function(Offset globalPosition)? onParagraphLongPressMoveUpdate;
  final void Function(Offset globalPosition)? onParagraphLongPressEnd;

  /// Selection plumbing. Null = no selection support (marks layer skipped).
  final ReaderSelectionScope? selectionScope;
  final ReaderTextSelection? selection;
  final List<ReaderRangeUnderline> rangeUnderlines;

  /// 【青茄重构·新增】批注/书摘范围（红色下划线 + 行内批注块）。
  final List<ReaderRangeUnderline> annotationRanges;

  /// The sentence being narrated, in chapter display-text coordinates.
  final (int, int)? narrationRange;

  const ReaderBlockContent({
    super.key,
    required this.block,
    required this.spec,
    this.imageProviderFactory,
    this.onParagraphLongPress,
    this.onParagraphLongPressMoveUpdate,
    this.onParagraphLongPressEnd,
    this.selectionScope,
    this.selection,
    this.rangeUnderlines = const [],
    this.annotationRanges = const [],
    this.narrationRange,
  });

  @override
  Widget build(BuildContext context) {
    // 【青茄重构·新增】批注块：按排版层实测高度渲染，不再走正文/划线分支。
    final inlineNote = block.inlineNote;
    if (inlineNote != null) {
      return ReaderNoteBlock(
        note: inlineNote,
        height: block.height,
        maxLines: block.noteLines,
      );
    }
    final image = block.illustration;
    if (image != null) {
      return ReaderIllustration(
        key: ValueKey('reader-illustration-${block.index}'),
        image: image,
        providerFactory: imageProviderFactory,
      );
    }
    Widget text = ReaderBlockText(block: block, spec: spec);
    // Marks live in the block's own coordinate space, so they scroll with the
    // text; the title never takes part in a selection.
    if (selectionScope != null && !block.isTitle && block.lines.isNotEmpty) {
      text = ReaderBlockMarkLayer(
        key: ValueKey('reader-block-marks-${block.index}'),
        block: block,
        spec: spec,
        scope: selectionScope!,
        selection: selection,
        rangeUnderlines: rangeUnderlines,
        annotationRanges: annotationRanges,
        narrationRange: narrationRange,
        child: text,
      );
    }
    if (block.isTitle || onParagraphLongPress == null) return text;
    return GestureDetector(
      key: ValueKey('reader-paragraph-press-${block.index - 1}'),
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (details) =>
          onParagraphLongPress!(block, details.globalPosition),
      onLongPressMoveUpdate: onParagraphLongPressMoveUpdate == null
          ? null
          : (details) =>
                onParagraphLongPressMoveUpdate!(details.globalPosition),
      onLongPressEnd: onParagraphLongPressEnd == null
          ? null
          : (details) => onParagraphLongPressEnd!(details.globalPosition),
      child: text,
    );
  }
}

class ReaderBlockText extends StatelessWidget {
  final ReaderContentBlock block;
  final ReaderLayoutSpec spec;

  const ReaderBlockText({super.key, required this.block, required this.spec});

  @override
  Widget build(BuildContext context) {
    final key = block.isTitle
        ? const ValueKey('reader-chapter-title')
        : ValueKey('reader-paragraph-${block.index - 1}');
    return block.isTitle
        ? Text(
            block.text,
            key: key,
            style: block.span.style,
            textAlign: block.align,
            textScaler: spec.textScaler,
            textDirection: TextDirection.ltr,
            locale: const Locale('zh', 'CN'),
          )
        : Text.rich(
            block.span,
            key: key,
            style: block.span.style,
            textAlign: block.align,
            textScaler: spec.textScaler,
            textDirection: TextDirection.ltr,
            locale: const Locale('zh', 'CN'),
            semanticsLabel: block.text,
          );
  }
}
