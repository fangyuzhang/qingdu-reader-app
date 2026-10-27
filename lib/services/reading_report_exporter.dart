import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'reading_report.dart';

/// 把当前这一期的阅读报告画成一张 PNG（1080 宽）。
///
/// 复用 [NoteCardExporter] 的路子：`PictureRecorder` 直接画，不引第三方库。
/// 报告内容本身就是确定的几个数字 + 一根柱状图，直接按固定版式绘制，
/// 不需要「先量后画」的两趟排版。
class ReadingReportExporter {
  ReadingReportExporter._();

  static const double _width = 1080;
  static const double _padding = 64;
  static const _bgTop = Color(0xFFFAFBF6);
  static const _bgBottom = Color(0xFFEFF4EC);
  static const _ink = Color(0xFF25302C);
  static const _muted = Color(0xFF7B8A83);
  static const _accent = Color(0xFF2FA98C);
  static const _line = Color(0xFFE2E9E0);

  static Future<String> export({
    required String periodLabel,
    required double minutes,
    required double averageMinutes,
    required int activeDays,
    required int noteCount,
    required int finishedCount,
    required List<ReportBar> bars,
    required List<String?> barLabels,
    required List<({String title, double minutes})> topBooks,
  }) async {
    final now = DateTime.now();
    final parts = readingDurationParts(minutes);
    const contentWidth = _width - _padding * 2;
    const chartHeight = 300.0;

    final header = _paragraph(
      '我的阅读',
      size: 54,
      color: _ink,
      weight: FontWeight.w700,
    );
    final period = _paragraph(periodLabel, size: 24, color: _muted);
    final big = _paragraph(
      parts.value,
      size: 104,
      color: _ink,
      weight: FontWeight.w700,
      height: 1.0,
    );
    final unit = _paragraph(
      parts.unit,
      size: 30,
      color: _ink,
      weight: FontWeight.w600,
    );
    final average = _paragraph(
      averageMinutes < 1
          ? '日均阅读小于 1 分钟'
          : '日均阅读 ${formatReadingDuration(averageMinutes)}',
      size: 24,
      color: _muted,
    );
    final statLabels = [
      '阅读天数 $activeDays 天',
      '读完 $finishedCount 本',
      '笔记 $noteCount 条',
    ].map((text) => _paragraph(text, size: 24, color: _ink)).toList();

    final dateText =
        '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';
    final footer = _paragraph('— 轻读 · $dateText —', size: 22, color: _muted);
    final bookLines = [
      for (final book in topBooks.take(2))
        _paragraph(
          '${book.title}    ${formatReadingDuration(book.minutes)}',
          size: 28,
          color: _ink,
          maxLines: 1,
          width: contentWidth - 40,
        ),
    ];

    // 固定版式，直接算高度。
    var height = _padding + header.height + 10 + period.height + 46;
    height += big.height + 14;
    height += average.height + 34;
    height += 30 + 34; // stats 行
    height += 28 + chartHeight + 40 + 12; // 标题 + 图 + x 轴
    height += bookLines.isEmpty ? 0 : 24 + bookLines.length * 46;
    height += 40 + footer.height + _padding;
    height = height.clamp(600, 4000);

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
    y += header.height + 10;
    canvas.drawParagraph(period, Offset(_padding, y));
    y += period.height + 46;

    canvas.drawParagraph(big, Offset(_padding, y));
    final unitOffset = _padding + big.maxIntrinsicWidth + 12;
    canvas.drawParagraph(
      unit,
      Offset(unitOffset, y + big.height - unit.height - 12),
    );
    y += big.height + 14;

    canvas.drawParagraph(average, Offset(_padding, y));
    y += average.height + 34;

    // 三个统计块横向排开，中间用细竖线分隔。
    var x = _padding;
    for (var i = 0; i < statLabels.length; i++) {
      canvas.drawParagraph(statLabels[i], Offset(x, y));
      x += contentWidth / statLabels.length;
      if (i < statLabels.length - 1) {
        canvas.drawRect(
          Rect.fromLTWH(x - 24, y + 2, 1, 26),
          Paint()..color = _line,
        );
      }
    }
    y += 30 + 34;

    // ---- 柱状图 ----
    final chartTitle = _paragraph(
      '阅读时长分布',
      size: 26,
      color: _ink,
      weight: FontWeight.w600,
    );
    canvas.drawParagraph(chartTitle, Offset(_padding, y));
    y += 28;

    var maxMinutes = 0.0;
    for (final bar in bars) {
      maxMinutes = math.max(maxMinutes, bar.minutes);
    }
    final axisMax = maxMinutes <= 0 ? 10.0 : maxMinutes * 1.15;

    // 基线 + 顶部虚线
    final dashed = Paint()
      ..color = _line
      ..strokeWidth = 1.4;
    for (var i = 0; i <= 2; i++) {
      final lineY = y + chartHeight * i / 2;
      var dashX = _padding;
      while (dashX < _padding + contentWidth) {
        canvas.drawLine(Offset(dashX, lineY), Offset(dashX + 6, lineY), dashed);
        dashX += 12;
      }
    }

    if (bars.isNotEmpty) {
      final slot = contentWidth / bars.length;
      final barWidth = math.min(slot * 0.55, 34.0);
      for (var i = 0; i < bars.length; i++) {
        final value = bars[i].minutes;
        if (value <= 0) continue;
        final barHeight = (value / axisMax) * chartHeight;
        final left = _padding + slot * i + (slot - barWidth) / 2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left,
              y + chartHeight - barHeight,
              barWidth,
              barHeight,
            ),
            const Radius.circular(6),
          ),
          Paint()..color = _accent,
        );
      }
    }
    y += chartHeight + 40;

    // x 轴刻度：只画有标签的那几格。
    if (bars.isNotEmpty) {
      final slot = contentWidth / bars.length;
      for (var i = 0; i < bars.length; i++) {
        final label = barLabels.length > i ? barLabels[i] : null;
        if (label == null || label.isEmpty) continue;
        final text = _paragraph(label, size: 18, color: _muted);
        canvas.drawParagraph(
          text,
          Offset(_padding + slot * i + (slot - text.width) / 2, y - 30),
        );
      }
    }
    y += 12;

    // ---- 阅读最久 ----
    if (bookLines.isNotEmpty) {
      final title = _paragraph(
        '阅读最久',
        size: 26,
        color: _ink,
        weight: FontWeight.w600,
      );
      canvas.drawParagraph(title, Offset(_padding, y));
      y += 24 + 12;
      for (final line in bookLines) {
        canvas.drawParagraph(line, Offset(_padding + 16, y));
        y += 46;
      }
    }

    y += 40;
    canvas.drawParagraph(footer, Offset((_width - footer.width) / 2, y));

    final image = await recorder.endRecording().toImage(
      _width.toInt(),
      height.ceil(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) throw StateError('图片编码失败');

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/qingdu/exports');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final file = File(
      '${outDir.path}/reading_report_${now.millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(Uint8List.view(bytes.buffer), flush: true);
    return file.path;
  }

  static ui.Paragraph _paragraph(
    String text, {
    required double size,
    required Color color,
    FontWeight weight = FontWeight.w400,
    double height = 1.4,
    double width = _width - _padding * 2,
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
            fontWeight: weight,
            height: height,
          ),
        );
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));
    return paragraph;
  }
}
