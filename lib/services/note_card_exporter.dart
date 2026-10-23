import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_annotation_store.dart';

/// 把批注/书摘导出成一张长图（PNG）。
///
/// 【青茄重构·新增】上游只有文字分享，没有「金句卡片」。这里用
/// [ui.PictureRecorder] 直接绘制，不依赖任何图片库：
///
/// * 先量后画（两趟）：第一趟排好每段文字拿到高度，算出整图高度，
///   第二趟按 y 偏移逐段绘制，因此长图高度永远是内容高度；
/// * 输出到应用文档目录 `qingqie/exports/`，返回绝对路径供 UI 提示。
class NoteCardExporter {
  NoteCardExporter._();

  /// 画布宽度（1080 ≈ 手机 3x 屏截图宽度，发朋友圈/微博都够清晰）。
  static const double _width = 1080;
  static const double _padding = 64;
  static const double _gap = 36;

  static const _bgTop = Color(0xFFFBF6EC);
  static const _bgBottom = Color(0xFFF3E9D6);
  static const _ink = Color(0xFF3D3427);
  static const _muted = Color(0xFF8A7B62);

  /// 导出并返回 PNG 绝对路径。
  static Future<String> export({
    required List<ReaderAnnotation> notes,
    String documentTitle = '我的书摘',
    String? bookTitle,
  }) async {
    final contentWidth = _width - _padding * 2;
    final now = DateTime.now();
    final dateText =
        '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';

    // ---- 第一趟：排版并测量 ----
    final header = _paragraph(
      documentTitle,
      size: 56,
      color: _ink,
      width: contentWidth,
      weight: FontWeight.w700,
      height: 1.25,
    );
    final subtitle = _paragraph(
      [
        if (bookTitle != null && bookTitle.isNotEmpty) bookTitle,
        '${notes.length} 条 · $dateText',
        '青茄阅读',
      ].join('  ·  '),
      size: 26,
      color: _muted,
      width: contentWidth,
      height: 1.4,
    );

    final blocks = <_NoteBlock>[];
    for (final note in notes) {
      final quote = _paragraph(
        '「${note.text}」',
        size: 30,
        color: _muted,
        width: contentWidth - 16,
        height: 1.55,
        maxLines: 5,
      );
      final thought = note.thought.trim().isEmpty
          ? null
          : _paragraph(
              note.thought,
              size: 36,
              color: _ink,
              width: contentWidth - 16,
              height: 1.6,
              maxLines: 12,
            );
      final source = [
        if (note.bookTitle.isNotEmpty) note.bookTitle,
        if (note.chapterTitle.isNotEmpty) note.chapterTitle,
        if (note.category.isNotEmpty) '分类：${note.category}',
        if (note.tags.isNotEmpty)
          '标签：${note.tags.map((tag) => '#$tag').join(' ')}',
        _noteTime(note.createdAt),
      ].join(' · ');
      blocks.add(
        _NoteBlock(
          quote: quote,
          thought: thought,
          accent: Color(note.effectiveMarkerColorValue),
          // 来源行也参与测量：否则它会被画到下一块的地盘上。
          source: source.isEmpty
              ? null
              : _paragraph(
                  source,
                  size: 22,
                  color: _muted.withValues(alpha: 0.85),
                  width: contentWidth - 20,
                  height: 1.3,
                  maxLines: 1,
                ),
        ),
      );
    }

    final footer = _paragraph(
      '— 用青茄阅读写下 —',
      size: 24,
      color: _muted,
      width: contentWidth,
      height: 1.4,
    );

    var height = _padding + header.height + 12 + subtitle.height + _gap;
    for (final block in blocks) {
      height += block.height + _gap;
    }
    height += footer.height + _padding;
    height = height.clamp(400, 20000);

    // ---- 第二趟：绘制 ----
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, _width, height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          _bgTop,
          _bgBottom,
        ]),
    );

    var y = _padding;
    canvas.drawParagraph(header, Offset(_padding, y));
    y += header.height + 12;
    canvas.drawParagraph(subtitle, Offset(_padding, y));
    y += subtitle.height + _gap;

    for (final block in blocks) {
      final badgePaint = Paint()..color = block.accent;
      // 左侧强调竖线 + 小角标，呼应正文里的批注块
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(_padding, y + 4, 6, block.height - 8),
          const Radius.circular(3),
        ),
        badgePaint,
      );
      var inner = y;
      canvas.drawParagraph(block.quote, Offset(_padding + 20, inner));
      inner += block.quote.height + 10;
      final thought = block.thought;
      if (thought != null) {
        canvas.drawParagraph(thought, Offset(_padding + 20, inner));
        inner += thought.height + 6;
      }
      final source = block.source;
      if (source != null) {
        canvas.drawParagraph(source, Offset(_padding + 20, inner));
      }
      y += block.height + _gap;
    }

    canvas.drawParagraph(
      footer,
      Offset((_width - footer.width) / 2, height - _padding - footer.height),
    );

    final image = await recorder.endRecording().toImage(
      _width.toInt(),
      height.ceil(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw StateError('图片编码失败');
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/qingqie/exports');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final stamp = now.millisecondsSinceEpoch;
    final file = File('${outDir.path}/notes_$stamp.png');
    await file.writeAsBytes(Uint8List.view(bytes.buffer), flush: true);
    return file.path;
  }

  static ui.Paragraph _paragraph(
    String text, {
    required double size,
    required Color color,
    required double width,
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    int? maxLines,
  }) {
    final builder =
        ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: size,
            height: height,
            textAlign: TextAlign.left,
            maxLines: maxLines,
            ellipsis: maxLines == null ? null : '…',
          ),
        )..pushStyle(
          ui.TextStyle(
            color: color,
            fontSize: size,
            height: height,
            fontWeight: weight,
          ),
        );
    builder.addText(text);
    return builder.build()..layout(ui.ParagraphConstraints(width: width));
  }
}

class _NoteBlock {
  _NoteBlock({
    required this.quote,
    required this.thought,
    required this.accent,
    required this.source,
  });

  final ui.Paragraph quote;
  final ui.Paragraph? thought;
  final Color accent;

  /// 来源行（书名 · 章节）；没有书名时为 null。
  final ui.Paragraph? source;

  /// 整块高度：引用 + 间距 + 想法 + 间距 + 来源行。
  double get height =>
      quote.height +
      10 +
      (thought == null ? 0 : thought!.height + 6) +
      (source == null ? 0 : source!.height + 4);
}

String _noteTime(int milliseconds) {
  if (milliseconds <= 0) return '时间未知';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}.${two(date.month)}.${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
