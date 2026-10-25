import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../models/ink_annotation.dart';
import '../../../services/debug_tools.dart';
import '../../home/home_design.dart';
import 'ink_controller.dart';

/// 批注模式工具栏：笔/橡皮/套索/撤销/重做/颜色/笔宽（+调试手指开关、完成）。
///
/// 风格对齐设置卡片：palette.surface 圆角卡 + 0.6 描边；浮在内容之上，
/// 不挤压正文（README 约定 #6）。
///
/// 套索态：lasso 工具且有选中笔迹时，追加一行编辑动作
/// （复制/剪切/删除/粘贴/完成圈选），Kindle Scribe 式对可编辑笔迹对象操作。
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
          // 单行排不下（工具 5 + 颜色 3 + 笔宽 3 + 手指 + 完成 ≈ 640 逻辑
          // 像素，手机视口只有 ~390）：窄屏折两行，宽屏仍单行。此前 Row
          // 直接溢出，「完成/手指绘制」被渲染到屏幕外——批注模式既无法
          // 正常退出也无法开手指绘制（真机 1080px 实测定位）。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tools = [
                _toolButton(
                  context,
                  icon: LucideIcons.pen_line,
                  active: controller.tool == InkTool.pen,
                  onTap: () => controller.selectTool(InkTool.pen),
                  tooltip: '笔',
                ),
                _toolButton(
                  context,
                  icon: LucideIcons.eraser,
                  active: controller.tool == InkTool.eraser,
                  onTap: () => controller.selectTool(InkTool.eraser),
                  tooltip: '橡皮',
                ),
                _toolButton(
                  context,
                  icon: LucideIcons.lasso,
                  active: controller.tool == InkTool.lasso,
                  onTap: () => controller.selectTool(InkTool.lasso),
                  tooltip: '套索',
                ),
                const SizedBox(width: 2),
                _iconButton(
                  context,
                  icon: LucideIcons.undo_2,
                  tooltip: '撤销',
                  onTap: controller.canUndo ? controller.undo : null,
                  key: const Key('ink-undo'),
                ),
                _iconButton(
                  context,
                  icon: LucideIcons.redo_2,
                  tooltip: '重做',
                  onTap: controller.canRedo ? controller.redo : null,
                  key: const Key('ink-redo'),
                ),
              ];
              final palette_ = [
                const SizedBox(width: 2),
                for (final color in _colors) _colorDot(context, color),
                const SizedBox(width: 2),
                for (final w in _widths) _widthDot(context, w),
                if (showFingerToggle) ...[
                  const SizedBox(width: 2),
                  _iconButton(
                    context,
                    icon: LucideIcons.hand,
                    active: controller.acceptFinger,
                    tooltip: '手指绘制',
                    onTap: controller.toggleFinger,
                    key: const Key('ink-finger-toggle'),
                  ),
                ],
              ];
              final done = FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: HomePalette.accent,
                  minimumSize: const Size(64, 38),
                ),
                onPressed: onDone,
                child: const Text(
                  '完成',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              );
              // 套索编辑行：lasso 工具 + 有选中笔迹时才出现。
              final selectionActions =
                  controller.tool == InkTool.lasso && controller.hasSelection;
              final twoRows = constraints.maxWidth < 620;
              if (twoRows) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [...tools, const Spacer(), done]),
                    const SizedBox(height: 2),
                    Row(children: palette_),
                    if (selectionActions) ...[
                      const SizedBox(height: 2),
                      _selectionActions(context),
                    ],
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [...tools, ...palette_, const Spacer(), done]),
                  if (selectionActions) ...[
                    const SizedBox(height: 2),
                    _selectionActions(context),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 套索选中后的编辑动作行：复制/剪切/删除/粘贴（剪贴板空时隐藏）/
  /// 完成圈选（退出套索回到笔）。
  Widget _selectionActions(BuildContext context) => Row(
    children: [
      const SizedBox(width: 2),
      _iconButton(
        context,
        icon: LucideIcons.copy,
        tooltip: '复制',
        onTap: controller.copySelected,
        key: const Key('ink-copy'),
      ),
      _iconButton(
        context,
        icon: LucideIcons.scissors,
        tooltip: '剪切',
        onTap: controller.cutSelected,
        key: const Key('ink-cut'),
      ),
      _iconButton(
        context,
        icon: LucideIcons.trash,
        tooltip: '删除',
        onTap: controller.deleteSelected,
        key: const Key('ink-delete'),
      ),
      if (controller.hasClipboard)
        _iconButton(
          context,
          icon: LucideIcons.clipboard_paste,
          tooltip: '粘贴到页面中心',
          onTap: () => controller.pasteAt(const Offset(0.5, 0.5)),
          key: const Key('ink-paste'),
        ),
      const Spacer(),
      _iconButton(
        context,
        icon: LucideIcons.check,
        tooltip: '完成圈选',
        onTap: () => controller.selectTool(InkTool.pen),
        key: const Key('ink-lasso-done'),
      ),
      const SizedBox(width: 2),
    ],
  );

  Widget _toolButton(
    BuildContext context, {
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    String? tooltip,
  }) =>
      _iconButton(
        context,
        icon: icon,
        active: active,
        onTap: onTap,
        tooltip: tooltip,
      );

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback? onTap,
    bool active = false,
    Key? key,
    String? tooltip,
  }) {
    final palette = HomePalette.of(context);
    return IconButton(
      key: key,
      tooltip: tooltip,
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
