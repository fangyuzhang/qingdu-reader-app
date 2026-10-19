import 'dart:async';

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
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFFFBF6EC),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) =>
        _AnnotationEditorSheet(quote: quote, initial: initial, title: title),
  );
}

/// 【青茄重构·修复】输入面板独立成 StatefulWidget。
///
/// 之前 `TextEditingController` / `FocusNode` 建在 `showAnnotationEditor`
/// 函数里，用 `future.whenComplete` 释放：但 `showModalBottomSheet` 的 Future
/// 在**路由开始 pop 时**就完成，此时退场动画（约 250ms）还在跑，TextField
/// 仍挂在树上继续 rebuild，于是 `addListener` 撞上已 dispose 的 FocusNode，
/// 真机上直接抛 `A FocusNode was used after being disposed`，并连带出
/// RenderFlex 溢出、`_dependents.isEmpty` 等一串级联报错。
///
/// 交给 State.dispose 释放，时机严格晚于退场动画，且与 rebuild 顺序对齐。
class _AnnotationEditorSheet extends StatefulWidget {
  const _AnnotationEditorSheet({
    required this.quote,
    required this.initial,
    required this.title,
  });

  final String quote;
  final String initial;
  final String title;

  @override
  State<_AnnotationEditorSheet> createState() => _AnnotationEditorSheetState();
}

class _AnnotationEditorSheetState extends State<_AnnotationEditorSheet> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _focus = FocusNode(debugLabel: 'reader-annot-input');
    // 【青茄重构·修复】弹层首帧就把焦点交出去，让「面板上滑」和
    // 「键盘升起」同时发生，而不是先等面板停稳再弹键盘。
    //
    // 之前延迟 280ms 是为了躲开卡顿，但那个卡顿的真正来源是键盘 inset
    // 触发了阅读页整章重排（现已由 resizeToAvoidBottomInset: false +
    // viewInsets 清零解决），延迟反而制造了「先弹面板、再弹键盘」的两段式观感。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      // 个别 ROM 会在路由转场中吞掉第一次请求，补一次即可，不再无限重试。
      _focusTimer = Timer(const Duration(milliseconds: 180), () {
        if (!mounted || _focus.hasFocus) return;
        _focus.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _focusTimer = null;
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return RepaintBoundary(
      child: AnimatedPadding(
        // 只把输入法高度作为内边距，内容自身可滚动，窄屏/大字号下不会溢出。
        // 用 AnimatedPadding 而不是 Padding：Android 的 inset 是一次性跳变的，
        // 直接改 padding 会让面板内容瞬移到键盘上方；补一段 140ms 的缓动，
        // 面板与键盘看起来是同一次上滑，而不是弹两次。
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3D3427),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('reader-annot-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      // 颜色钉死：弹层是浅色米底，不能跟随深色主题的 onSurface。
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF6B5B3E),
                        ),
                      ),
                    ),
                    FilledButton(
                      key: const ValueKey('reader-annot-save'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE85D26),
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _submit,
                      child: const Text(
                        '保存',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
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
                    widget.quote,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: Color(0xFF6B5B3E),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // TextField 没有 selectionColor 参数，选中态只能走主题；
                // 单独包一层 TextSelectionTheme，避免深色主题把选区/光标也刷成浅色。
                TextSelectionTheme(
                  data: const TextSelectionThemeData(
                    cursorColor: Color(0xFF2E2A24),
                    // 品牌绿 12% 透明：选区在米白面板上可辨，又不盖住文字。
                    selectionColor: Color(0x1F3DA88A),
                    selectionHandleColor: Color(0xFF3DA88A),
                  ),
                  child: TextField(
                    key: const ValueKey('reader-annot-input'),
                    controller: _controller,
                    focusNode: _focus,
                    // 不开 autofocus：焦点由上面的 post-frame 回调在入场动画
                    // 结束后再抢，避免与路由/输入法动画抢同一批帧。
                    maxLines: 4,
                    minLines: 3,
                    textInputAction: TextInputAction.newline,
                    // 【修复】输入文字颜色必须显式指定：面板挂在独立路由上，
                    // 若宿主是深色主题，bodyLarge.color / onSurface 是浅色，
                    // 浅色字落在白色输入框上等于隐形。这里钉死深棕色，不随主题走。
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.55,
                      color: Color(0xFF2E2A24),
                    ),
                    cursorColor: const Color(0xFF2E2A24),
                    decoration: InputDecoration(
                      hintText: '写下你的想法…',
                      hintStyle: const TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: Color(0xFFA29483),
                      ),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
