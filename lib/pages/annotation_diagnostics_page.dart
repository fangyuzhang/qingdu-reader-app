import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'dart:async';

import '../models/ink_annotation.dart';
import '../services/anchor_projector.dart';
import '../services/imported_book_store.dart';
import '../services/ink_annotation_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/reader/annotation/ink_strokes_painter.dart';

/// 批注诊断页（第 7 组，调试入口，debugToolsEnabled 构建可见）。
///
/// 列出全部手写墨迹批注的锚点状态：本地导入书能取到章节正文 → 实时
/// verify/relocate；书城书离线拿不到正文 / PDF 纯页锚点 → 标未校验。
/// 真机排查「批注去哪了 / 位置为什么不对」用。
class AnnotationDiagnosticsPage extends StatefulWidget {
  const AnnotationDiagnosticsPage({super.key});

  @override
  State<AnnotationDiagnosticsPage> createState() =>
      _AnnotationDiagnosticsPageState();
}

class _AnnotationDiagnosticsPageState extends State<AnnotationDiagnosticsPage>
    with WidgetsBindingObserver {
  List<_DiagRow>? _rows;
  String? _error;
  String _stats = '…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    unawaited(
      InkAnnotationStore.instance
          .debugStats()
          .then((v) => mounted ? setState(() => _stats = v) : null),
    );
    try {
      final all = await InkAnnotationStore.instance.loadAll();
      final rows = <_DiagRow>[];
      for (final item in all) {
        String? chapterText;
        if (item.format == InkAnnotation.kFormatFlow &&
            ImportedBookStore.isLocalBookId(item.bookId)) {
          try {
            chapterText = await ImportedBookStore.instance.chapterText(
              item.bookId,
              item.chapterId,
            );
          } catch (_) {
            chapterText = null;
          }
        }
        InkAnchorStatus status;
        ({int start, int end})? relocated;
        if (chapterText == null) {
          status = item.hasTextAnchor
              ? InkAnchorStatus.unverified
              : InkAnchorStatus.unverified;
        } else {
          status = item.verifyAgainst(chapterText);
          if (status == InkAnchorStatus.mismatch &&
              item.contextBefore.isNotEmpty &&
              item.contextAfter.isNotEmpty) {
            relocated = relocateAnchor(
              chapterText,
              item.contextBefore,
              item.contextAfter,
            );
          }
        }
        rows.add(_DiagRow(item, status, relocated));
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('批注诊断（调试）')),
      bottomSheet: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '存储：$_stats',
              key: const Key('ink-diag-stats'),
              style: TextStyle(fontSize: 11, color: palette.muted),
            ),
            for (final line in InkAnnotationStore.trace.take(30).toList().reversed)
              Text(
                line,
                key: const Key('ink-diag-trace'),
                style: TextStyle(
                  fontSize: 10.5,
                  color: palette.muted.withValues(alpha: 0.85),
                ),
              ),
          ],
        ),
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: TextStyle(color: palette.muted)))
          : rows == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: rows.isEmpty
                  ? ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            '暂无手写批注',
                            style: TextStyle(color: palette.muted),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _row(palette, rows[index], index),
                    ),
            ),
    );
  }

  Widget _row(HomePalette palette, _DiagRow row, int index) {
    final item = row.annotation;
    final statusLabel = switch (row.status) {
      InkAnchorStatus.exact => '锚点命中',
      InkAnchorStatus.partial => '部分命中（可重投影）',
      InkAnchorStatus.mismatch => row.relocated != null ? '失配·可重定位' : '失配·需人工确认',
      InkAnchorStatus.unverified => '未校验（正文不可得/纯页锚点）',
    };
    final statusColor = switch (row.status) {
      InkAnchorStatus.exact => HomePalette.accentStrong,
      InkAnchorStatus.partial => HomePalette.highlight,
      InkAnchorStatus.mismatch => palette.muted,
      InkAnchorStatus.unverified => palette.muted,
    };
    return ListTile(
      key: ValueKey('ink-diag-$index'),
      leading: SizedBox(
        width: 52,
        height: 52,
        child: CustomPaint(
          painter: InkStrokesPainter(strokes: item.strokes, canvasWidth: 52),
        ),
      ),
      title: Text(
        '${item.format.toUpperCase()} · ${_bookLabel(item)} · ${item.chapterId}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: palette.ink),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            statusLabel,
            style: TextStyle(fontSize: 11.5, color: statusColor),
          ),
          Text(
            '锚点 ${item.startOffset ?? '-'}~${item.endOffset ?? '-'} · 版本 ${item.layoutVersion}',
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: Icon(LucideIcons.trash, size: 18, color: palette.muted),
        tooltip: '删除该批注',
        onPressed: () => _delete(row),
      ),
    );
  }

  String _bookLabel(InkAnnotation item) =>
      ImportedBookStore.isLocalBookId(item.bookId) ? '本地导入' : '书城书籍';

  Future<void> _delete(_DiagRow row) async {
    await InkAnnotationStore.instance.delete(row.annotation.key);
    await _load();
  }
}

class _DiagRow {
  const _DiagRow(this.annotation, this.status, this.relocated);

  final InkAnnotation annotation;
  final InkAnchorStatus status;
  final ({int start, int end})? relocated;
}
