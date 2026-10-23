import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_annotation_store.dart';
import '../../services/reader_mark_style.dart';
import '../../services/reader_marker_type_store.dart';
import 'reader_chapter_layout.dart';

/// 行内批注块：紧跟被标注段落下方，独占一行或多行。
class ReaderNoteBlock extends StatefulWidget {
  const ReaderNoteBlock({
    super.key,
    required this.note,
    required this.height,
    required this.maxLines,
    this.store,
  });

  final ReaderInlineNote note;
  final double height;
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
    final badgeColor = Color(note.badgeColorValue);
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
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    note.badgeLabel,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                    ),
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
                key: ValueKey('reader-note-fold-${note.id}'),
                icon: _folded ? Icons.expand_more : Icons.expand_less,
                tooltip: _folded ? '展开' : '折叠',
                onTap: () => setState(() => _folded = !_folded),
              ),
              const SizedBox(width: 4),
              _NoteIcon(
                key: ValueKey('reader-note-edit-${note.id}'),
                icon: Icons.edit_outlined,
                tooltip: '编辑笔记信息',
                onTap: _editNote,
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

  Future<void> _editNote() async {
    final note = widget.note;
    final knownCategories = <String>[];
    final knownTags = <String>[];
    try {
      final all = await _store.loadAll();
      for (final entry in all) {
        if (entry.category.trim().isNotEmpty &&
            !knownCategories.contains(entry.category.trim())) {
          knownCategories.add(entry.category.trim());
        }
        for (final tag in entry.tags) {
          if (!knownTags.contains(tag)) knownTags.add(tag);
        }
      }
    } catch (_) {
      // 建议值不可用不影响编辑。
    }
    if (!mounted) return;
    final draft = await showAnnotationEditor(
      context,
      quote: note.quote,
      title: note.isExcerpt ? '编辑书摘信息' : '编辑批注',
      isExcerpt: note.isExcerpt,
      initial: note.thought,
      initialCategory: note.category,
      initialTags: note.tags,
      initialMarkerType: note.markerType,
      initialMarkerLabel: note.badgeLabel,
      initialMarkerColorValue: note.badgeColorValue,
      initialMarkStyle: note.markStyle,
      initialMarkColorValue: note.markColorValue == 0
          ? note.badgeColorValue
          : note.markColorValue,
      knownCategories: knownCategories,
      knownTags: knownTags,
    );
    if (draft == null) return;
    try {
      await _store.updateNote(note.id, draft);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    }
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
          child: Icon(icon, size: 16, color: const Color(0xFF8A7657)),
        ),
      ),
    );
  }
}

/// 新建/编辑笔记的输入面板。取消返回 null。
Future<AnnotationDraft?> showAnnotationEditor(
  BuildContext context, {
  required String quote,
  String initial = '',
  String title = '写批注',
  bool isExcerpt = false,
  String initialCategory = '',
  List<String> initialTags = const [],
  String initialMarkerType = '',
  String initialMarkerLabel = '批',
  int initialMarkerColorValue = readerDefaultAnnotationColor,
  ReaderMarkStyle initialMarkStyle = ReaderMarkStyle.solid,
  int initialMarkColorValue = readerDefaultAnnotationColor,
  List<String> knownCategories = const [],
  List<String> knownTags = const [],
  List<ReaderMarkerType> markerTypes = const [],
}) {
  return showModalBottomSheet<AnnotationDraft>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFFFBF6EC),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _AnnotationEditorSheet(
      quote: quote,
      initial: initial,
      title: title,
      isExcerpt: isExcerpt,
      initialCategory: initialCategory,
      initialTags: initialTags,
      initialMarkerType: initialMarkerType,
      initialMarkerLabel: initialMarkerLabel,
      initialMarkerColorValue: initialMarkerColorValue,
      initialMarkStyle: initialMarkStyle,
      initialMarkColorValue: initialMarkColorValue,
      knownCategories: knownCategories,
      knownTags: knownTags,
      markerTypes: markerTypes,
    ),
  );
}

/// 一个「批注类型」小圆片：文字即角标，左侧圆点就是它的底色。
class _MarkerChip extends StatelessWidget {
  const _MarkerChip({
    super.key,
    required this.label,
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      showCheckmark: false,
      selected: selected,
      label: Text(label),
      avatar: CircleAvatar(radius: 6, backgroundColor: Color(colorValue)),
      selectedColor: Color(colorValue).withValues(alpha: 0.18),
      onSelected: (_) => onTap(),
    );
  }
}

class _AnnotationEditorSheet extends StatefulWidget {
  const _AnnotationEditorSheet({
    required this.quote,
    required this.initial,
    required this.title,
    required this.isExcerpt,
    required this.initialCategory,
    required this.initialTags,
    required this.initialMarkerType,
    required this.initialMarkerLabel,
    required this.initialMarkerColorValue,
    required this.initialMarkStyle,
    required this.initialMarkColorValue,
    required this.knownCategories,
    required this.knownTags,
    this.markerTypes = const [],
  });

  final String quote;
  final String initial;
  final String title;
  final bool isExcerpt;
  final String initialCategory;
  final List<String> initialTags;
  final String initialMarkerType;
  final String initialMarkerLabel;
  final int initialMarkerColorValue;
  final ReaderMarkStyle initialMarkStyle;
  final int initialMarkColorValue;
  final List<String> knownCategories;
  final List<String> knownTags;

  /// 除了四个内置类型之外、用户之前自定义过的类型。
  final List<ReaderMarkerType> markerTypes;

  @override
  State<_AnnotationEditorSheet> createState() => _AnnotationEditorSheetState();
}

class _AnnotationEditorSheetState extends State<_AnnotationEditorSheet> {
  late final TextEditingController _thought;
  late final TextEditingController _category;
  late final TextEditingController _tag;
  late final TextEditingController _markerLabel;
  late final FocusNode _focus;
  late final List<String> _tags;
  late String _markerType;
  late int _markerColorValue;
  late ReaderMarkStyle _markStyle;
  late int _markColorValue;
  late List<ReaderMarkerType> _customTypes;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _thought = TextEditingController(text: widget.initial);
    _category = TextEditingController(text: widget.initialCategory);
    _tag = TextEditingController();
    _markerLabel = TextEditingController(text: widget.initialMarkerLabel);
    _focus = FocusNode(debugLabel: 'reader-annot-input');
    _tags = AnnotationDraft.normalizeTags(widget.initialTags).toList();
    _markerType = widget.initialMarkerType;
    _markerColorValue = widget.initialMarkerColorValue;
    _markStyle = widget.initialMarkStyle;
    _markColorValue = widget.initialMarkColorValue;
    _customTypes = widget.markerTypes;
    unawaited(_loadMarkerTypes());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
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
    _thought.dispose();
    _category.dispose();
    _tag.dispose();
    _markerLabel.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _markerChip({
    required Key key,
    required String label,
    required int colorValue,
    required bool selected,
    required VoidCallback onTap,
  }) => _MarkerChip(
    key: key,
    label: label,
    colorValue: colorValue,
    selected: selected,
    onTap: onTap,
  );

  /// 用户此前自定义过的批注类型随编辑器一起出现，不必再去别处管理。
  Future<void> _loadMarkerTypes() async {
    final stored = await ReaderMarkerTypeStore.instance.load();
    if (!mounted) return;
    final merged = <ReaderMarkerType>[
      ...widget.markerTypes,
      for (final type in stored)
        if (!widget.markerTypes.any((existing) => existing.key == type.key))
          type,
    ];
    if (merged.length == _customTypes.length) return;
    setState(() => _customTypes = merged);
  }

  void _addTags() {
    final next = AnnotationDraft.normalizeTags([..._tags, _tag.text]);
    setState(() {
      _tags
        ..clear()
        ..addAll(next);
      _tag.clear();
    });
  }

  void _submit() {
    final thought = _thought.text.trim();
    if (!widget.isExcerpt && thought.isEmpty) return;
    final pendingTags = AnnotationDraft.normalizeTags([..._tags, _tag.text]);
    final label = _markerLabel.text.trim();
    if (!widget.isExcerpt && label.isNotEmpty) {
      // 记下这个角标：下次写作时它就是一个可选类型，笔记页也能按它筛选。
      unawaited(ReaderMarkerTypeStore.instance.add(label, _markerColorValue));
    }
    Navigator.of(context).pop(
      AnnotationDraft(
        thought: thought,
        category: _category.text.trim(),
        tags: pendingTags,
        markerType: widget.isExcerpt ? 'excerpt' : _markerType,
        markerLabel: _markerLabel.text.trim(),
        markerColorValue: _markerColorValue,
        markStyle: _markStyle,
        markColorValue: _markColorValue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final media = MediaQuery.of(context);
    final available = math.max(
      260.0,
      media.size.height - viewInsets.bottom - 20,
    );
    return AnimatedPadding(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.min(760, available)),
          child: SingleChildScrollView(
            key: const ValueKey('reader-annotation-scroll'),
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD9CCB5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2E2A24),
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('reader-annot-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Color(0xFF6B5B3E)),
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
                if (!widget.isExcerpt) ...[
                  const SizedBox(height: 10),
                  _field(
                    key: const ValueKey('reader-annot-input'),
                    controller: _thought,
                    focusNode: _focus,
                    hint: '写下你的想法…',
                    minLines: 3,
                    maxLines: 5,
                  ),
                ],
                const SizedBox(height: 14),
                const _EditorLabel('分类'),
                const SizedBox(height: 6),
                _field(
                  key: const ValueKey('reader-category-input'),
                  controller: _category,
                  hint: '例如：成长、历史、待实践（可自行命名）',
                  maxLines: 1,
                ),
                if (widget.knownCategories.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _suggestions(
                    values: widget.knownCategories,
                    onTap: (value) => setState(() => _category.text = value),
                  ),
                ],
                const SizedBox(height: 14),
                const _EditorLabel('标签（可多选多个）'),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('reader-tag-input'),
                  controller: _tag,
                  style: const TextStyle(color: Color(0xFF2E2A24)),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTags(),
                  decoration: _decoration('输入标签，按回车添加'),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in _tags)
                      InputChip(
                        key: ValueKey('reader-note-tag-$tag'),
                        label: Text(tag),
                        onDeleted: () => setState(() => _tags.remove(tag)),
                      ),
                  ],
                ),
                if (widget.knownTags.isNotEmpty)
                  _suggestions(
                    values: widget.knownTags,
                    onTap: (value) {
                      final next = AnnotationDraft.normalizeTags([
                        ..._tags,
                        value,
                      ]);
                      setState(() {
                        _tags
                          ..clear()
                          ..addAll(next);
                      });
                    },
                  ),
                if (!widget.isExcerpt) ...[
                  const SizedBox(height: 16),
                  const _EditorLabel('批注标记'),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final preset in readerMarkerPresets)
                        _markerChip(
                          key: ValueKey('reader-marker-${preset.key}'),
                          label: preset.label,
                          colorValue: preset.colorValue,
                          selected:
                              _markerLabel.text.trim() == preset.label ||
                              (!_customTypes.any(
                                    (type) =>
                                        type.key == _markerLabel.text.trim(),
                                  ) &&
                                  _markerType == preset.key),
                          onTap: () => setState(() {
                            _markerType = preset.key;
                            _markerLabel.text = preset.label;
                            _markerColorValue = preset.colorValue;
                          }),
                        ),
                      for (final type in _customTypes)
                        _markerChip(
                          key: ValueKey('reader-marker-type-${type.key}'),
                          label: type.label,
                          colorValue: type.colorValue,
                          selected: _markerLabel.text.trim() == type.key,
                          onTap: () => setState(() {
                            _markerType = AnnotationDraft.customMarkerType;
                            _markerLabel.text = type.label;
                            _markerColorValue = type.colorValue;
                          }),
                        ),
                      ChoiceChip(
                        key: const ValueKey('reader-marker-custom'),
                        showCheckmark: false,
                        selected:
                            _markerType.isEmpty ||
                            _markerType == AnnotationDraft.customMarkerType,
                        avatar: const Icon(
                          LucideIcons.plus,
                          size: 13,
                          color: Color(0xFF6B6459),
                        ),
                        label: const Text('新类型'),
                        onSelected: (_) => setState(
                          () => _markerType = AnnotationDraft.customMarkerType,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 120,
                        child: TextField(
                          key: const ValueKey('reader-marker-label'),
                          controller: _markerLabel,
                          // The badge is scaled to fit, so users are not limited
                          // to the four preset words when naming a marker.
                          maxLength: 12,
                          style: const TextStyle(color: Color(0xFF2E2A24)),
                          decoration: _decoration(
                            '角标文字',
                          ).copyWith(counterText: ''),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _colorDots(
                          keyPrefix: 'reader-marker-color',
                          selected: _markerColorValue,
                          allowCustom: true,
                          onTap: (value) => setState(() {
                            _markerColorValue = value;
                            if (_markerType.isEmpty) {
                              _markerType = AnnotationDraft.customMarkerType;
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const _EditorLabel('原文标记线型（默认横线）'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    children: [
                      for (final style in ReaderMarkStyle.values)
                        ChoiceChip(
                          key: ValueKey(
                            'reader-mark-style-${style.storageValue}',
                          ),
                          showCheckmark: false,
                          selected: _markStyle == style,
                          label: Text(style.label),
                          onSelected: (_) => setState(() => _markStyle = style),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _colorDots(
                    keyPrefix: 'reader-mark-color',
                    selected: _markColorValue,
                    onTap: (value) => setState(() => _markColorValue = value),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    Key? key,
    required TextEditingController controller,
    FocusNode? focusNode,
    required String hint,
    int minLines = 1,
    int maxLines = 4,
  }) => TextSelectionTheme(
    data: const TextSelectionThemeData(
      cursorColor: Color(0xFF2E2A24),
      selectionColor: Color(0x1F3DA88A),
      selectionHandleColor: Color(0xFF3DA88A),
    ),
    child: TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      minLines: minLines,
      maxLines: maxLines,
      style: const TextStyle(
        fontSize: 14,
        height: 1.55,
        color: Color(0xFF2E2A24),
      ),
      decoration: _decoration(hint),
    ),
  );

  InputDecoration _decoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(
      fontSize: 13,
      height: 1.45,
      color: Color(0xFF7A6F60),
    ),
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFFEADFC8)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFFEADFC8)),
    ),
  );

  Widget _suggestions({
    required List<String> values,
    required ValueChanged<String> onTap,
  }) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ActionChip(
              label: Text(value),
              visualDensity: VisualDensity.compact,
              onPressed: () => onTap(value),
            ),
          ),
      ],
    ),
  );

  Widget _colorDots({
    required String keyPrefix,
    required int selected,
    required ValueChanged<int> onTap,
    bool allowCustom = false,
  }) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      for (final preset in readerMarkColorPresets)
        InkWell(
          key: ValueKey('$keyPrefix-${preset.colorValue}'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => onTap(preset.colorValue),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Color(preset.colorValue),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected == preset.colorValue
                    ? const Color(0xFF2E2A24)
                    : Colors.white,
                width: selected == preset.colorValue ? 2.5 : 1.5,
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 2),
              ],
            ),
          ),
        ),
      if (allowCustom)
        InkWell(
          key: ValueKey('$keyPrefix-custom'),
          borderRadius: BorderRadius.circular(20),
          onTap: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (_) => _MarkerColorPickerDialog(initialValue: selected),
            );
            if (picked != null && mounted) onTap(picked);
          },
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  readerMarkColorPresets.any(
                    (preset) => preset.colorValue == selected,
                  )
                  ? null
                  : Color(selected),
              gradient:
                  readerMarkColorPresets.any(
                    (preset) => preset.colorValue == selected,
                  )
                  ? const SweepGradient(
                      colors: [
                        Colors.red,
                        Colors.orange,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Colors.purple,
                        Colors.red,
                      ],
                    )
                  : null,
              border: Border.all(
                color:
                    readerMarkColorPresets.any(
                      (preset) => preset.colorValue == selected,
                    )
                    ? Colors.white
                    : const Color(0xFF2E2A24),
                width:
                    readerMarkColorPresets.any(
                      (preset) => preset.colorValue == selected,
                    )
                    ? 1.5
                    : 2.5,
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x22000000), blurRadius: 2),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Arbitrary badge background colour. The preset row stays one tap away, while
/// these three HSV sliders cover any colour a reader wants for their marker.
class _MarkerColorPickerDialog extends StatefulWidget {
  const _MarkerColorPickerDialog({required this.initialValue});

  final int initialValue;

  @override
  State<_MarkerColorPickerDialog> createState() =>
      _MarkerColorPickerDialogState();
}

class _MarkerColorPickerDialogState extends State<_MarkerColorPickerDialog> {
  late HSVColor _color;

  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(Color(widget.initialValue));
    if (_color.saturation < 0.15) {
      _color = _color.withSaturation(0.65).withValue(0.85);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _color.toColor();
    final previewText = preview.computeLuminance() > 0.5
        ? const Color(0xFF2E2A24)
        : Colors.white;
    return AlertDialog(
      key: const ValueKey('reader-marker-color-picker'),
      backgroundColor: const Color(0xFFFBF6EC),
      title: const Text('自定义底色'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey('reader-marker-color-preview'),
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: preview,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFEADFC8)),
              ),
              child: Text(
                '批注',
                style: TextStyle(
                  color: previewText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),
            _slider(
              sliderKey: 'reader-marker-color-hue',
              label: '色相',
              value: _color.hue,
              min: 0,
              max: 360,
              display: '${_color.hue.round()}°',
              onChanged: (value) =>
                  setState(() => _color = _color.withHue(value)),
            ),
            _slider(
              sliderKey: 'reader-marker-color-saturation',
              label: '饱和度',
              value: _color.saturation,
              min: 0,
              max: 1,
              display: '${(_color.saturation * 100).round()}%',
              onChanged: (value) =>
                  setState(() => _color = _color.withSaturation(value)),
            ),
            _slider(
              sliderKey: 'reader-marker-color-value',
              label: '明度',
              value: _color.value,
              min: 0,
              max: 1,
              display: '${(_color.value * 100).round()}%',
              onChanged: (value) =>
                  setState(() => _color = _color.withValue(value)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('reader-marker-color-apply'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE85D26),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(preview.toARGB32()),
          child: const Text('使用此颜色'),
        ),
      ],
    );
  }

  Widget _slider({
    required String sliderKey,
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B5B3E),
            ),
          ),
          const Spacer(),
          Text(
            display,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A7B62)),
          ),
        ],
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: const Color(0xFFE85D26),
          thumbColor: const Color(0xFFE85D26),
          overlayColor: const Color(0x22E85D26),
        ),
        child: Slider(
          key: ValueKey(sliderKey),
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
    ],
  );
}

class _EditorLabel extends StatelessWidget {
  const _EditorLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: Color(0xFF6B5B3E),
    ),
  );
}
