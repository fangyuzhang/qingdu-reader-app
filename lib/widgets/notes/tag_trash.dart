import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'note_tag_drag.dart';

/// 拖动标签时在页面顶部浮现的垃圾桶落点。
///
/// 作为 overlay 挂在页面 Stack 顶层，不参与流式布局——出现/消失不会推动
/// 任何其他图层。接受两类负载：
/// - 单枚 [NoteTagDrag]：笔记角标 → 从那条笔记上摘掉；调色板标签 →
///   从所有笔记摘除并从目录删除；
/// - 磁吸组 [NoteTagClusterDrag]：组内全部删除。
class TagTrashTarget extends StatefulWidget {
  const TagTrashTarget({
    super.key,
    required this.visible,
    required this.onDropTag,
    required this.onDropCluster,
    this.trashKey = const ValueKey('notes-tag-trash'),
  });

  /// 落点本体的 key（笔记页与批注编辑器各有实例，测试分别定位）。
  final Key trashKey;

  /// 拖动进行中 = 显示（带入场动效）；否则完全移除，不留占位。
  final bool visible;

  final ValueChanged<NoteTagDrag> onDropTag;
  final ValueChanged<NoteTagClusterDrag> onDropCluster;

  @override
  State<TagTrashTarget> createState() => _TagTrashTargetState();
}

class _TagTrashTargetState extends State<TagTrashTarget> {
  bool _hover = false;

  static bool _isTagPayload(Object? data) =>
      data is NoteTagDrag || data is NoteTagClusterDrag;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedScale(
        scale: widget.visible ? 1 : 0.4,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Center(
            child: DragTarget<Object>(
              onWillAcceptWithDetails: (details) => _isTagPayload(details.data),
              onMove: (_) {
                if (!_hover) setState(() => _hover = true);
              },
              onLeave: (_) {
                if (_hover) setState(() => _hover = false);
              },
              onAcceptWithDetails: (details) {
                if (_hover) setState(() => _hover = false);
                final data = details.data;
                if (data is NoteTagDrag) widget.onDropTag(data);
                if (data is NoteTagClusterDrag) widget.onDropCluster(data);
              },
              builder: (context, candidate, _) {
                final armed = candidate.isNotEmpty;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedScale(
                      key: widget.trashKey,
                      scale: armed ? 1.18 : 1.0,
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOutBack,
                      child: Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          color: armed
                              ? Colors.red.withValues(alpha: 0.18)
                              : palette.surface,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: armed ? Colors.red : palette.line,
                            width: armed ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: armed
                                  ? Colors.red.withValues(alpha: 0.35)
                                  : Colors.black.withValues(alpha: 0.14),
                              blurRadius: armed ? 20 : 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          LucideIcons.trash,
                          size: 24,
                          color: armed ? Colors.red : palette.muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      armed ? '松手删除' : '拖到此处删除',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: armed ? Colors.red : palette.muted,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
