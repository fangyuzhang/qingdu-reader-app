import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';


/// What the reader can do with a long-pressed paragraph.
///
/// 【青茄重构·新增】annot（批注：写想法并生成行内批注块）与
/// excerpt（书摘：收藏选中句子）为蜗牛读书式批注能力，见
/// docs/02-增删功能方案.md。
enum ReaderParagraphAction {
  copy,
  listen,
  underline,
  removeUnderline,
  annot,
  excerpt,
  // 【青茄·Active Canvas】画布（内嵌手写）/ 便签（折叠态画布）/ 备注（打字笔记图标）。
  canvas,
  sticky,
  note,
}

/// Floating action bar for a long-pressed paragraph or a dragged selection,
/// matching the official one.
///
/// The official client builds this from three decompiled pieces:
///
/// * `com/dragon/read/story/impl/feeds/selection/m.java` — a wrap-content
///   `PopupWindow` with an 8dp rounded background, one 15x8dp arrow on the side
///   facing the paragraph, and horizontal padding of 32dp for a single item or
///   10dp for several.
/// * `res/layout/wr.xml` — the root: up arrow, the item row, down arrow.
/// * `res/layout/wt.xml` — one item: 60x48dp, a 24dp icon, then a 10sp label
///   2dp below it, on a #FF303030 (day) / #FF1C1C1C (night) bar with #FFFFFFFF
///   text.
///
/// The official paragraph bar offers 从本句听 / 写段评 / 一键生图 / 分享, and its
/// selection toolbar (a sibling surface, `com/dragon/read/ui/paragraph/i.java`)
/// offers 复制 / 划线 / 查询 / 写笔记 / 错字反馈. The account- and capability-gated
/// items need endpoints the backend does not have, so this bar shows only the
/// actions it can actually perform: 从本段开始听书 when listening is available,
/// plus 复制 / 划线 / 批注. The same set stays visible for a paragraph long
/// press and a dragged character range, so the bar never changes shape
/// mid-drag. Local-only reading hides the listening item.
///
/// Note: 官方长按工具的版式与颜色取自反编译 m.java / wt.xml / wr.xml，见
/// .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
class ReaderParagraphMenu extends StatelessWidget {
  /// See `res/layout/wt.xml`.
  static const _itemWidth = 60.0;

  /// 「从本段开始听书」比其它标签长，单独加宽；整条操作栏的宽度与
  /// [resolvePosition] 都按同一组宽度计算，避免文字压到相邻按钮。
  static const _listenItemWidth = 84.0;
  static const _itemHeight = 48.0;
  static const _iconSize = 24.0;
  static const _labelTopGap = 2.0;
  static const _labelSize = 10.0;

  /// See `selection/m.java`: it uses 32dp horizontally for a single item and
  /// 10dp once there are several; current paragraph/selection bars have at least
  /// two actions.
  static const _multiPadding = 10.0;
  static const _verticalPadding = 4.0;

  /// The arrow is 15x8dp and overlaps the bar by 1dp (`wr.xml`).
  static const _arrowWidth = 15.0;
  static const _arrowHeight = 8.0;

  /// `UiUtils.getRoundRectDrawable(UIKt.getDp(8), color)` in `m.java`.
  static const _radius = 8.0;

  /// `selection/m.java#o`, confirmed against its smali: the black theme takes
  /// `s7` #FF1C1C1C and the day theme `u_` #FF303030 (the first branch jadx
  /// shows there is dead code, its result is never assigned).
  static const _barColor = Color(0xFF303030);
  static const _barColorDark = Color(0xFF1C1C1C);

  /// `@color/al` — pure white in both themes.
  static const _foreground = Color(0xFFFFFFFF);

  static const _margin = 10.0;

  final bool underlined;
  final bool isDark;

  /// True for a whole-paragraph selection (long press). Kept for the underline
  /// label (取消划线 vs 删除划线); the listen item is driven by [showListening]
  /// so it stays present for dragged ranges too.
  final bool paragraphScoped;
  final bool showListening;

  /// True when the bar sits below the touched line, so its tip points up at the
  /// paragraph (`m.java` shows downArrow instead once the popup flips above).
  final bool belowAnchor;

  /// Fired when an item is tapped. The bar is a plain overlay child of the
  /// reader page (the official one is a non-modal PopupWindow), so there is
  /// no route result to pop — the page owns the selection lifecycle.
  final ValueChanged<ReaderParagraphAction> onAction;

  const ReaderParagraphMenu({
    super.key,
    required this.onAction,
    this.underlined = false,
    this.isDark = false,
    this.paragraphScoped = true,
    this.showListening = true,
    this.belowAnchor = true,
  });

  Color get _background => isDark ? _barColorDark : _barColor;

  /// Number of items the bar will render; the caller sizes the anchor with it.
  static int itemCount({
    required bool underlined,
    required bool paragraphScoped,
    bool showListening = true,
  }) {
    // 【青茄重构】监听项只要 showListening 就显示（不再区分整段 / 选区），
    // 另有 复制 / 划线 / 批注 / 书摘 四个常驻动作。
    return 4 + (showListening ? 1 : 0);
  }

  static double _barWidth({required bool showListening}) =>
      itemCount(
            underlined: false,
            paragraphScoped: true,
            showListening: showListening,
          ) *
          _itemWidth +
      (showListening ? _listenItemWidth - _itemWidth : 0) +
      _multiPadding * 2;

  static double barWidthFor({
    required bool underlined,
    required bool paragraphScoped,
    bool showListening = true,
  }) => _barWidth(showListening: showListening);

  /// 操作条整体高度（含朝向段落一侧的箭头）。
  static const double barHeight =
      _verticalPadding * 2 + _itemHeight + _arrowHeight;

  /// Clamped top-left for the bar anchored at [anchor] (window coordinates),
  /// plus which side of the anchor it ended up on — the geometry
  /// `selection/m.java#l` applies to its PopupWindow: centred on the anchor
  /// with a 10dp screen margin, flipping above when there is no room below.
  ///
  /// [anchor] sits at the selection's last line bottom (plus clearance for
  /// the end caret's dot); [topAnchor] is the selection's first line top.
  /// The flip places the whole bar — arrow included — above [topAnchor], so
  /// a tall selection is never covered by its own bar; without a top anchor
  /// the flip falls back to the anchor point.
  ///
  /// The reader page calls this per build, so the bar never sits on the
  /// system bars or on the reader's own bottom toolbar ([avoidBottom]).
  static (Offset, bool) resolvePosition({
    required Offset anchor,
    Offset? topAnchor,
    required bool paragraphScoped,
    required Size view,
    required EdgeInsets safeArea,
    required bool underlined,
    bool showListening = true,
    double avoidBottom = 0,
    double belowContentHeight = 0,
  }) {
    const flipClearance = 10.0;
    // 【青茄·Active Canvas】动作增至 8 项后，窄屏放不下整条：定位宽度
    // 钳到可用屏宽（内容条可横向滚动，见 build）。
    final barWidth = math.min(
      _barWidth(showListening: showListening),
      math.max(120.0, view.width - _margin * 2),
    );
    // Only the tip facing the paragraph is laid out, exactly like `m.java`:
    // it calls `UIKt.gone` on the other arrow, which takes no space. Total
    // height is 8 (tip) + 56 (body) = 64dp, the same 64dp `m.java` uses when
    // it offsets the popup above the anchor.
    const barHeight = ReaderParagraphMenu.barHeight;
    final columnHeight = barHeight + belowContentHeight;

    final minLeft = _margin;
    final maxLeft = (view.width - barWidth - _margin).clamp(
      minLeft,
      double.infinity,
    );
    final left = (anchor.dx - barWidth / 2).clamp(minLeft, maxLeft);

    final minTop = safeArea.top + _margin;
    final bottomLimit = view.height - safeArea.bottom - avoidBottom - _margin;
    final maxTop = (bottomLimit - columnHeight).clamp(minTop, double.infinity);
    final belowTop = anchor.dy + _arrowHeight;
    final below = belowTop + columnHeight <= bottomLimit;
    // Flipped above a selection: the bar's bottom (its down arrow) must sit
    // above the selection's first line top — the start caret's dot protrudes
    // 6dp above it, hence the extra clearance.
    final flippedTop =
        (topAnchor?.dy ?? anchor.dy) -
        columnHeight -
        _arrowHeight -
        (topAnchor == null ? 0 : flipClearance);
    final top = (below ? belowTop : flippedTop).clamp(minTop, maxTop);
    return (Offset(left, top), below);
  }

  @override
  Widget build(BuildContext context) {
    final items = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showListening)
          _Item(
            key: const ValueKey('reader-action-listen'),
            icon: LucideIcons.headphones,
            label: '从本段开始听书',
            width: _listenItemWidth,
            onTap: () => onAction(ReaderParagraphAction.listen),
          ),
        _Item(
          key: const ValueKey('reader-action-copy'),
          icon: LucideIcons.copy,
          label: '复制',
          onTap: () => onAction(ReaderParagraphAction.copy),
        ),
        _Item(
          key: const ValueKey('reader-action-underline'),
          icon: underlined ? LucideIcons.eraser : LucideIcons.highlighter,
          label: underlined ? (paragraphScoped ? '取消划线' : '删除划线') : '划线',
          onTap: () => onAction(
            underlined
                ? ReaderParagraphAction.removeUnderline
                : ReaderParagraphAction.underline,
          ),
        ),
        // 【青茄重构·新增】批注：写想法 → 红线 + 行内批注块。
        _Item(
          key: const ValueKey('reader-action-annot'),
          icon: LucideIcons.message_square,
          label: '批注',
          onTap: () => onAction(ReaderParagraphAction.annot),
        ),
        // 【青茄重构·新增】书摘：收藏选中句子（无想法）。
        _Item(
          key: const ValueKey('reader-action-excerpt'),
          icon: LucideIcons.bookmark,
          label: '书摘',
          onTap: () => onAction(ReaderParagraphAction.excerpt),
        ),
        // 【青茄·Active Canvas】画布：在此行后插入内嵌手写画布（占位、
        // 后续文字下移重排）。
        _Item(
          key: const ValueKey('reader-action-canvas'),
          icon: LucideIcons.frame,
          label: '画布',
          onTap: () => onAction(ReaderParagraphAction.canvas),
        ),
        // 【青茄·Active Canvas】便签：此处放一枚折叠便签图标。
        _Item(
          key: const ValueKey('reader-action-sticky'),
          icon: LucideIcons.file_pen,
          label: '便签',
          onTap: () => onAction(ReaderParagraphAction.sticky),
        ),
        // 【青茄·Active Canvas】备注：打字笔记图标行，不占正文空间。
        _Item(
          key: const ValueKey('reader-action-note'),
          icon: LucideIcons.message_square,
          label: '备注',
          onTap: () => onAction(ReaderParagraphAction.note),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // `m.java` shows upArrow when the popup hangs below the anchor and
          // downArrow once it flips above; the other arrow is gone, so it takes
          // no space and the painted tip always touches the paragraph.
          if (belowAnchor)
            _Arrow(pointingUp: true, color: _background)
          else
            const SizedBox.shrink(),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width - _margin * 2,
            ),
            height: _itemHeight + _verticalPadding * 2,
            padding: const EdgeInsets.symmetric(
              horizontal: _multiPadding,
              vertical: _verticalPadding,
            ),
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(_radius),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: items,
            ),
          ),
          if (!belowAnchor)
            _Arrow(pointingUp: false, color: _background)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// The 15x8dp tip that ties the bar to the touched line (`wr.xml`).
///
/// The caller only builds the arrow that faces the paragraph, mirroring the
/// `UIKt.gone`/`UIKt.visible` swap in `selection/m.java`, so no visibility
/// flag is needed here.
class _Arrow extends StatelessWidget {
  final bool pointingUp;
  final Color color;

  const _Arrow({required this.pointingUp, required this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(
      ReaderParagraphMenu._arrowWidth,
      ReaderParagraphMenu._arrowHeight,
    ),
    painter: _ArrowPainter(color: color, pointingUp: pointingUp),
  );
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final bool pointingUp;

  const _ArrowPainter({required this.color, required this.pointingUp});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointingUp) {
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height);
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.color != color || old.pointingUp != pointingUp;
}

/// One icon-over-label item; geometry from `res/layout/wt.xml`.
class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final double width;
  final VoidCallback onTap;

  const _Item({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.width = ReaderParagraphMenu._itemWidth,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: width,
      height: ReaderParagraphMenu._itemHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: ReaderParagraphMenu._iconSize,
            color: ReaderParagraphMenu._foreground,
          ),
          const SizedBox(height: ReaderParagraphMenu._labelTopGap),
          // 大字号 / 窄屏下让标签在自己的格子里等比缩小，既不压到
          // 相邻按钮，也不产生 RenderFlex 溢出。
          SizedBox(
            width: width - 4,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                  color: ReaderParagraphMenu._foreground,
                  fontSize: ReaderParagraphMenu._labelSize,
                  height: 1.0,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
