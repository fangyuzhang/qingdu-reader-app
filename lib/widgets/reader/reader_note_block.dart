import 'package:flutter/material.dart';

import '../../services/reader_annotation_store.dart';
import 'reader_chapter_layout.dart';

/// 行内批注块（蜗牛读书式）：紧跟被标注段落下方，独占一行或多行。
///
/// 【青茄重构·新增】视觉对齐蜗牛读书：米色底、圆角、左上角红色「批」字角标；
/// 正文用比正文更浅的棕色，点文字折叠/展开，右上角可编辑/删除。
///
/// 高度与行数由排版层实测后传入（见 `_measureInlineNote`），
/// 本组件只负责按给定高度渲染，因此分页与滚动两种模式都不会溢出。
class ReaderNoteBlock extends StatefulWidget {
  const ReaderNoteBlock({
    super.key,
    required this.note,
    required this.height,
    required this.maxLines,
    this.store,
  });

  final ReaderInlineNote note;

  /// 排版层实测的整块高度（含底部外边距）。
  final double height;

  /// 排版层实测的正文行数。
  final int maxLines;

  final ReaderAnnotationStore? store;

  @override
  State<ReaderNoteBlock> createState() => _ReaderNoteBlockState();
}

class _ReaderNoteBlockState extends State<ReaderNoteBlock> {
  bool _folded = false;

  ReaderAnnotationStore get _store =>
      widget.store ?? ReaderAnnotationStore.instance;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final badge = note.isExcerpt ? '摘' : '批';
    final badgeColor = note.isExcerpt
        ? const Color(0xFF3DA88A)
        : const Color(0xFFD64545);
    final textStyle = TextStyle(
      inherit: false,
      fontSize: 13,
      height: 1.5,
      letterSpacing: 0,
      color: const Color(0xFF6B5B3E),
      textBaseline: TextBaseline.alphabetic,
    );
    return SizedBox(
      height: widget.height,
      child: Padding(
        // 6 = 排版层预留的底部外边距（_kNoteChromeHeight 的一部分）。
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFBF3E2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEADFC8)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _folded = !_folded),
                  child: Text(
                    note.body,
                    key: ValueKey('reader-note-text-${note.id}'),
                    maxLines: _folded ? 1 : widget.maxLines,
                    overflow: TextOverflow.ellipsis,
                    style: textStyle,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _NoteIcon(
                key: ValueKey('reader-note-edit-${note.id}'),
                icon: _folded ? Icons.expand_more : Icons.expand_less,
                tooltip: _folded ? '展开' : '折叠',
                onTap: () => setState(() => _folded = !_folded),
              ),
              const SizedBox(width: 4),
              _NoteIcon(
                key: ValueKey('reader-note-delete-${note.id}'),
                icon: Icons.delete_outline,
                tooltip: '删除',
                onTap: _confirmDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final note = widget.note;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(note.isExcerpt ? '删除这条书摘？' : '删除这条批注？'),
        content: Text(
          note.isExcerpt ? '书摘只保存在本机，删除后不可恢复。' : '批注与下划线会一并删除。',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('reader-note-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _store.remove(note.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
    }
  }
}

/// 批注块内的 16px 图标位（固定宽度参与排版层的宽度折算）。
class _NoteIcon extends StatelessWidget {
  const _NoteIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 14,
        child: SizedBox(
          width: 16,
          height: 16,
          child: Icon(icon, size: 16, color: const Color(0xFFB0A08A)),
        ),
      ),
    );
  }
}

/// 新建/编辑批注的输入面板。返回用户输入的想法；取消返回 null。
///
/// 【青茄重构·新增】与蜗牛读书一致：顶部展示被标注的原文，下方写想法。
Future<String?> showAnnotationEditor(
  BuildContext context, {
  required String quote,
  String initial = '',
  String title = '写批注',
}) {
  final controller = TextEditingController(text: initial);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFFFBF6EC),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) {
      final viewInsets = MediaQuery.viewInsetsOf(sheetContext);
      return Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '写想法',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3D3427),
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('reader-annot-cancel'),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('reader-annot-save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE85D26),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) return;
                    Navigator.of(sheetContext).pop(text);
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF3EAD8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                quote,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: Color(0xFF8A7B62),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('reader-annot-input'),
              controller: controller,
              autofocus: true,
              maxLines: 4,
              minLines: 3,
              style: const TextStyle(fontSize: 14, height: 1.55),
              decoration: InputDecoration(
                hintText: '写下你的想法…',
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFEADFC8)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFEADFC8)),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
