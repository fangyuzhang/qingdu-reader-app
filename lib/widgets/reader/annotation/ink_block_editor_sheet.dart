import 'dart:async';

import 'package:flutter/material.dart';

import '../../../widgets/app_dialog.dart';

import '../../../models/ink_annotation.dart';
import '../../../models/reader_ink_block.dart';
import '../../../services/reader_ink_block_store.dart';
import 'embedded_ink_block_view.dart';

/// 【轻读·Active Canvas】便签书写面板：点正文里的便签图标从底部升起，
/// 大画布书写，每笔即时落盘，关闭/完成自动保存（规格 C4）。
class InkBlockEditorSheet extends StatefulWidget {
  const InkBlockEditorSheet({
    super.key,
    required this.block,
    this.store,
  });

  final ReaderInkBlock block;

  /// 与阅读页同一 store 实例（测试注入内存版）；null = 真实加密盒。
  final ReaderInkBlockStore? store;

  @override
  State<InkBlockEditorSheet> createState() => _InkBlockEditorSheetState();
}

class _InkBlockEditorSheetState extends State<InkBlockEditorSheet> {
  static const _editorHeight = 280.0;

  late List<InkStroke> _seed;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _seed = const [];
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _persist(List<InkStroke> raw, double boxWidth) async {
    final normalized = ReaderInkBlock.normalized(
      raw,
      boxWidth: boxWidth,
      boxHeight: _editorHeight,
    );
    await (widget.store ?? ReaderInkBlockStore.instance).updateStrokes(
      widget.block,
      normalized,
    );
  }

  void _onStrokes(List<InkStroke> raw, double boxWidth) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persist(raw, boxWidth));
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width.clamp(0.0, 560.0);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFBF6EC),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Text(
                      widget.block.isSticky ? '便签' : '手写',
                      style: const TextStyle(
                        inherit: false,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3B362C),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('ink-block-sheet-done'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: StatefulBuilder(
                  builder: (context, setSheetState) {
                    // 首帧按面板实际宽度展开存档笔迹。
                    if (_seed.isEmpty && widget.block.strokes.isNotEmpty) {
                      _seed = widget.block.strokesForBox(width, _editorHeight);
                    }
                    return EmbeddedInkCanvas(
                      key: ValueKey(
                        'ink-block-sheet-${widget.block.createdAt}',
                      ),
                      width: width - 32,
                      height: _editorHeight,
                      strokes: _seed,
                      isDraft: false,
                      selected: true,
                      onStrokesChanged: (raw) =>
                          _onStrokes(raw, width - 32),
                      onRequestDelete: () async {
                        final confirmed = await showAppDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('删除这块便签？'),
                            content: const Text(
                              '删除后图标与笔迹一并消失，不可恢复。',
                              style: TextStyle(fontSize: 13, height: 1.5),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(false),
                                child: const Text('保留'),
                              ),
                              TextButton(
                                key: const ValueKey(
                                  'reader-ink-block-delete-confirm',
                                ),
                                onPressed: () =>
                                    Navigator.of(dialogContext).pop(true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && context.mounted) {
                          unawaited(
                            ReaderInkBlockStore.instance.remove(widget.block),
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
