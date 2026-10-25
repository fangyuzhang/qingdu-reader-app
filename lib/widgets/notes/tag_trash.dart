import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'note_tag_drag.dart';

/// 右上角常驻的垃圾桶落点。
///
/// 作为 overlay 挂在页面 Stack 顶层，不参与流式布局。接受两类负载：
/// - 单枚 [NoteTagDrag]：笔记角标 → 从那条笔记上摘掉；调色板标签 →
///   从所有笔记摘除并从目录删除；
/// - 磁吸组 [NoteTagClusterDrag]：组内全部删除。
///
/// 拖拽物靠近时进入 armed 态：容器弹性放大 + 红色光晕扩散 + 文案切换。
class TagTrashTarget extends StatefulWidget {
  const TagTrashTarget({
    super.key,
    required this.onDropTag,
    required this.onDropCluster,
    this.trashKey = const ValueKey('notes-tag-trash'),
  });

  /// 落点本体的 key（笔记页与批注编辑器各有实例，测试分别定位）。
  final Key trashKey;

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
    return DragTarget<Object>(
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
          key: widget.trashKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 靠近时弹性放大（elasticOut 过冲回弹）+ 光晕扩散。
            TweenAnimationBuilder<double>(
              tween: Tween(end: armed ? 1.28 : 1.0),
              duration: Duration(milliseconds: armed ? 450 : 200),
              curve: armed ? Curves.elasticOut : Curves.easeOutCubic,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: armed
                      ? Colors.red.withValues(alpha: 0.16)
                      : palette.surface.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: armed ? Colors.red : palette.line,
                    width: armed ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: armed
                          ? Colors.red.withValues(alpha: 0.45)
                          : Colors.black.withValues(alpha: 0.12),
                      blurRadius: armed ? 26 : 10,
                      spreadRadius: armed ? 3 : 0,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(
                  LucideIcons.trash,
                  size: armed ? 26 : 22,
                  color: armed ? Colors.red : palette.muted,
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              child: Text(
                armed ? '松手删除' : '拖到此处删除',
                key: ValueKey(armed),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: armed ? Colors.red : palette.muted,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
