import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../models/ink_annotation.dart';
import '../../../services/debug_tools.dart';
import '../../home/home_design.dart';
import 'ink_controller.dart';

/// 批注模式工具栏：笔/橡皮/撤销/重做/颜色/笔宽（+调试手指开关、完成）。
///
/// 风格对齐设置卡片：palette.surface 圆角卡 + 0.6 描边；浮在内容之上，
/// 不挤压正文（README 约定 #6）。
class InkToolbar extends StatelessWidget {
  const InkToolbar({
    super.key,
    required this.controller,
    required this.onDone,
    this.showFingerToggle = debugToolsEnabled,
  });

  final InkController controller;
  final VoidCallback onDone;

  /// 手指绘制开关（仅 debugToolsEnabled 构建）。
  final bool showFingerToggle;

  static const _colors = [
    InkAnnotation.defaultColorValue,
    0xFFE53935,
    0xFF4F7CD1,
  ];
  static const _widths = [2.5, 4.0, 6.0];

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        top: false,
        child: Container(
          key: const Key('ink-toolbar'),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Row(
            children: [
              _toolButton(
                context,
                icon: LucideIcons.pen_line,
                active: controller.tool == InkTool.pen,
                onTap: () => controller.selectTool(InkTool.pen),
              ),
              _toolButton(
                context,
                icon: LucideIcons.eraser,
                active: controller.tool == InkTool.eraser,
                onTap: () => controller.selectTool(InkTool.eraser),
              ),
              const SizedBox(width: 2),
              _iconButton(
                context,
                icon: LucideIcons.undo_2,
                onTap: controller.canUndo ? controller.undo : null,
                key: const Key('ink-undo'),
              ),
              _iconButton(
                context,
                icon: LucideIcons.redo_2,
                onTap: controller.canRedo ? controller.redo : null,
                key: const Key('ink-redo'),
              ),
              const SizedBox(width: 2),
              for (final color in _colors)
                _colorDot(context, color),
              const SizedBox(width: 2),
              for (final w in _widths)
                _widthDot(context, w),
              if (showFingerToggle) ...[
                const SizedBox(width: 2),
                _iconButton(
                  context,
                  icon: LucideIcons.hand,
                  active: controller.acceptFinger,
                  onTap: controller.toggleFinger,
                  key: const Key('ink-finger-toggle'),
                ),
              ],
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: HomePalette.accent,
                  minimumSize: const Size(64, 38),
                ),
                onPressed: onDone,
                child: const Text(
                  '完成',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolButton(
    BuildContext context, {
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) =>
      _iconButton(context, icon: icon, active: active, onTap: onTap);

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback? onTap,
    bool active = false,
    Key? key,
  }) {
    final palette = HomePalette.of(context);
    return IconButton(
      key: key,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
      icon: Icon(
        icon,
        size: 19,
        color: onTap == null
            ? palette.muted.withValues(alpha: 0.45)
            : active
            ? HomePalette.accent
            : palette.ink,
      ),
      onPressed: onTap,
    );
  }

  Widget _colorDot(BuildContext context, int colorValue) {
    final selected = controller.colorValue == colorValue;
    return GestureDetector(
      onTap: () => controller.selectColor(colorValue),
      child: Container(
        key: ValueKey('ink-color-$colorValue'),
        width: 44,
        height: 44,
        alignment: Alignment.center,
        child: Container(
          width: selected ? 20 : 15,
          height: selected ? 20 : 15,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(colorValue),
            border: Border.all(
              color: selected ? HomePalette.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _widthDot(BuildContext context, double width) {
    final palette = HomePalette.of(context);
    final selected = controller.baseWidth == width;
    return GestureDetector(
      onTap: () => controller.selectWidth(width),
      child: Container(
        key: ValueKey('ink-width-$width'),
        width: 36,
        height: 44,
        alignment: Alignment.center,
        child: Container(
          width: width + 8,
          height: width + 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? HomePalette.accent : palette.muted,
          ),
        ),
      ),
    );
  }
}
