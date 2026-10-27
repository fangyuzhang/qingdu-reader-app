import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'note_tag_drag.dart';

/// 标签垃圾桶落点。
///
/// [compact] = true：AppBar 图标按钮形态（与「保存长图」同款，无圆圈
/// 容器、无文案），挂在其左侧。三档状态：
/// - idle：常规灰色图标；
/// - [active]（页面有标签拖动进行中）：图标弹性放大一下并保持，示意
///   「可以拖进来删除」；
/// - armed（拖拽物悬停在落点上）：进一步放大 + 变红 + 光晕。
///
/// 默认 false：圆形容器形态（批注编辑器 sheet 顶部用），同样支持三档。
///
/// 两形态都接受两类负载：
/// - 单枚 [NoteTagDrag]：笔记角标 → 从那条笔记摘掉；调色板标签 →
///   从所有笔记摘除并从目录删除；
/// - 磁吸组 [NoteTagClusterDrag]：组内全部删除。
class TagTrashTarget extends StatefulWidget {
  const TagTrashTarget({
    super.key,
    required this.onDropTag,
    required this.onDropCluster,
    this.trashKey = const ValueKey('notes-tag-trash'),
    this.compact = false,
    this.active = false,
  });

  /// 落点本体的 key（笔记页与批注编辑器各有实例，测试分别定位）。
  final Key trashKey;

  /// AppBar 紧凑形态（图标按钮样式）。
  final bool compact;

  /// 页面有标签拖动进行中（无论是否悬停在桶上）：弹性放大示意可投递。
  final bool active;

  final ValueChanged<NoteTagDrag> onDropTag;
  final ValueChanged<NoteTagClusterDrag> onDropCluster;

  @override
  State<TagTrashTarget> createState() => _TagTrashTargetState();
}

class _TagTrashTargetState extends State<TagTrashTarget> {
  /// 唯一 armed 状态源 = DragTarget builder 的 candidate（指针确实悬停在
  /// 落点上）。不用 onMove/onLeave 另存 _hover——两者与 candidate 在边缘
  /// 交错时会不同步，反复重启动画就是「靠近时抖动」的根因。
  static bool _isTagPayload(Object? data) =>
      data is NoteTagDrag || data is NoteTagClusterDrag;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) => _isTagPayload(details.data),
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is NoteTagDrag) widget.onDropTag(data);
        if (data is NoteTagClusterDrag) widget.onDropCluster(data);
      },
      builder: (context, candidate, _) {
        final armed = candidate.isNotEmpty;
        // 三档缩放：idle 1.0 → 拖动中 1.18（弹性示意）→ 悬停 1.35。
        final scale = armed ? 1.35 : (widget.active ? 1.18 : 1.0);
        final highlight = armed || widget.active;
        if (widget.compact) {
          // AppBar 形态：与「保存长图」同款图标；拖动一开始弹性放大
          // 示意可投递，悬停时更大 + 变红 + 光晕。
          // 【轻读·无障碍】DragTarget+Icon 对读屏不可见：包一层语义
          // （按钮 + 状态：拖动标签过来可删除）。
          return Semantics(
            button: true,
            label: '删除标签',
            hint: '拖动标签到此可删除',
            child: TweenAnimationBuilder<double>(
            key: widget.trashKey,
            tween: Tween(end: scale),
            duration: Duration(milliseconds: armed ? 320 : 380),
            curve: armed
                ? Curves.easeOutBack
                : (widget.active ? Curves.elasticOut : Curves.easeOutCubic),
            builder: (context, scale, child) => Transform.scale(
              scale: scale,
              child: child,
            ),
            child: Icon(
              LucideIcons.trash,
              size: 24,
              color: armed ? Colors.red : (widget.active ? HomePalette.accent : palette.muted),
              shadows: armed
                  ? [
                      Shadow(
                        color: Colors.red.withValues(alpha: 0.6),
                        blurRadius: 12,
                      ),
                    ]
                  : (widget.active
                        ? [
                            Shadow(
                              color: HomePalette.accent.withValues(alpha: 0.4),
                              blurRadius: 8,
                            ),
                          ]
                        : null),
            ),
          ),
        );
        }
        return Column(
          key: widget.trashKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: scale),
              duration: Duration(milliseconds: armed ? 450 : 380),
              curve: armed
                  ? Curves.elasticOut
                  : (widget.active ? Curves.elasticOut : Curves.easeOutCubic),
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
                    color: armed
                        ? Colors.red
                        : (highlight ? HomePalette.accent : palette.line),
                    width: armed ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: armed
                          ? Colors.red.withValues(alpha: 0.45)
                          : (highlight
                                ? HomePalette.accent.withValues(alpha: 0.3)
                                : Colors.black.withValues(alpha: 0.12)),
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
                armed ? '松手删除' : '',
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
