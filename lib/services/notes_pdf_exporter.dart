import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'note_card_exporter.dart';
import 'reader_annotation_store.dart';

/// 笔记 PDF 导出（规格 C9 v2）：把笔记渲染成 A4 比例的图片页 PDF。
///
/// 「图片页」方案：中文排版由 [NoteCardExporter.renderImage] 的 Flutter
/// 管线完成（复用长图视觉），PDF 只承载切片后的位图页——**无需打包 CJK
/// 字体**（字体子集动辄数 MB，且视觉与长图导出完全一致）。
///
/// 切片：源长图（宽 1080）按 A4 内容区比例换算页高，用 `image` 包
/// （项目既有依赖）逐段 copyCrop，每页一张完整贴图，无裁剪残留。
///
/// 范围（[NotesPdfScope]）：整本（该书全部批注/书摘）/ 当前章节。
class NotesPdfExporter {
  NotesPdfExporter._();

  /// A4 纵向（PDF 点）。
  static const _pageWidth = 595.28;
  static const _pageHeight = 841.89;
  static const _margin = 24.0;

  static Future<String> export({
    required String bookId,
    required String bookTitle,
    NotesPdfScope scope = NotesPdfScope.book,
    String? chapterId,
    String documentTitle = '我的读书笔记',
  }) async {
    // load 按章取：整本范围需先拿章节清单再聚合（目录来源 = 注解的书架
    // 历史不可靠，改为 loadAll 过滤 bookId——与笔记页同一路径）。
    final all = await ReaderAnnotationStore.instance.loadAll();
    final bookNotes = all.where((note) => note.bookId == bookId).toList();
    final notes = scope == NotesPdfScope.chapter && chapterId != null
        ? bookNotes.where((note) => note.chapterId == chapterId).toList()
        : bookNotes;
    if (notes.isEmpty) {
      throw StateError('该范围内没有笔记');
    }

    final image = await NoteCardExporter.renderImage(
      notes: notes,
      documentTitle: documentTitle,
      bookTitle: bookTitle,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final pixelWidth = image.width;
    final pixelHeight = image.height;
    image.dispose();
    if (bytes == null) {
      throw StateError('图片编码失败');
    }

    final source = img.decodePng(Uint8List.view(bytes.buffer));
    if (source == null) {
      throw StateError('长图解码失败');
    }

    // 每页承载的源像素高：按 A4 内容区宽高比换算（宽对宽等比）。
    final contentW = _pageWidth - _margin * 2;
    final contentH = _pageHeight - _margin * 2;
    final pxPerPage =
        (contentH * pixelWidth / contentW).floor().clamp(1, pixelHeight);

    final pdf = pw.Document(title: documentTitle, author: '轻读');
    final pages = (pixelHeight / pxPerPage).ceil().clamp(1, 200);
    for (var i = 0; i < pages; i++) {
      final top = i * pxPerPage;
      final sliceHeight = (pixelHeight - top).clamp(1, pxPerPage);
      final slice = img.copyCrop(
        source,
        x: 0,
        y: top,
        width: pixelWidth,
        height: sliceHeight,
      );
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(_pageWidth, _pageHeight),
          margin: const pw.EdgeInsets.all(_margin),
          build: (context) => pw.Center(
            child: pw.Image(
              pw.MemoryImage(img.encodePng(slice)),
              fit: pw.BoxFit.contain,
            ),
          ),
        ),
      );
    }

    final pdfBytes = await pdf.save();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/qingdu_notes_$stamp.pdf');
    await file.writeAsBytes(pdfBytes, flush: true);
    return file.path;
  }
}

enum NotesPdfScope { book, chapter }
