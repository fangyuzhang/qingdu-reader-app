import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

class ReaderStatusBar extends StatelessWidget {
  final ReaderThemePreset preset;
  final ReaderDeviceStatus status;
  final double progress;
  final int chapterIndex;
  final int chapterCount;
  final bool paged;
  final int? pageIndex;
  final int? pageCount;
  final bool compact;

  /// 听书胶囊收缩成底部小按钮时，为它留出一条带子，避免按钮压在正文与
  /// 状态行之间各露一半。
  final bool listeningPill;

  /// 滚动模式没有真正的分页，用本章字数折算的页数顶上，保证左下角始终
  /// 显示「读到 / 共 / 剩」而不是退回时钟。
  final int estimatedPagesPerChapter;

  const ReaderStatusBar({
    super.key,
    required this.preset,
    required this.status,
    required this.progress,
    required this.chapterIndex,
    required this.chapterCount,
    this.paged = false,
    this.pageIndex,
    this.pageCount,
    this.compact = false,
    this.listeningPill = false,
    this.estimatedPagesPerChapter = 0,
  });

  @override
  Widget build(BuildContext context) {
    final time =
        '${status.time.hour.toString().padLeft(2, '0')}:'
        '${status.time.minute.toString().padLeft(2, '0')}';
    // 左下角显示「当前页/全书页 百分比」。分页模式下每章页数已知，按章数
    // 折算全书页数；滚动模式没有页的概念，继续显示时间。
    final perChapter = paged
        ? pageCount
        : (estimatedPagesPerChapter > 0 ? estimatedPagesPerChapter : null);
    final bookPages = perChapter == null ? null : chapterCount * perChapter;
    final readPage = bookPages == null || bookPages <= 0
        ? null
        : (progress.clamp(0.0, 1.0) * bookPages).round().clamp(1, bookPages);
    final percent = (progress.clamp(0.0, 1.0) * 100).toStringAsFixed(1);
    final pageCountLabel = readPage == null ? null : '$readPage/$bookPages';
    // 状态栏必须保持高度恒定。上下滑动模式下滚动的像素位置在切换日夜时
    // 原样保留，若这里随内容（分页行 / 电池块 / 百分比）增减高度，正文可用
    // 高度会变化一次，视觉上就是正文上下跳一下。分页模式没有跨页滚动所以
    // 看不出来；连续切换时高度已经稳定，所以只有第一次跳。
    // 因此行高按 compact / listeningPill 固定预留，内容只做单行省略，
    // 是否分页、是否有电池都不能改变整体高度。
    final lineHeight = MediaQuery.textScalerOf(context).scale(11) * 1.4;
    final chapterLineHeight = lineHeight + 4;
    final bottomPadding = listeningPill ? 54.0 : 10.0;
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.bodySmall!.copyWith(
        color: preset.mutedTextColor,
        // Material 3 的 labelSmall 是 11sp；10sp 页码在 1x 屏上已经偏小。
        fontSize: 11,
        height: 1.4,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: SizedBox(
        height:
            8 + lineHeight + (compact ? 0 : chapterLineHeight) + bottomPadding,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 分页信息行始终预留同样高度；滚动模式留空，避免切换模式时
              // 正文高度变化。
              if (!compact)
                SizedBox(
                  height: chapterLineHeight,
                  child: paged
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: Text(
                            '第 ${chapterIndex + 1} / $chapterCount 章 · '
                            '本章 ${pageIndex == null ? '—' : pageIndex! + 1} / ${pageCount ?? '—'} 页',
                            key: const ValueKey('reader-page-number'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        )
                      : null,
                ),
              SizedBox(
                height: lineHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: pageCountLabel == null
                          ? Text(
                              time,
                              key: const ValueKey('reader-clock'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    pageCountLabel,
                                    key: const ValueKey('reader-page-progress'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // 页数与百分比之间留两个数字的空档：原来的单个
                                // 空格让「2085/2096」和「99.5%」粘在一起，读数
                                // 时容易当成一个数。宽度按当前字号实测，换字体
                                // 或调大系统字号都跟着走。
                                SizedBox(width: _gapWidth(context)),
                                Flexible(
                                  child: Text(
                                    '$percent%',
                                    key: const ValueKey('reader-page-percent'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    if (status.battery != null) ...[
                      const SizedBox(width: 12),
                      Row(
                        key: const ValueKey('reader-battery'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            status.charging
                                ? LucideIcons.battery_charging
                                : LucideIcons.battery_medium,
                            size: 13,
                            color: preset.mutedTextColor,
                          ),
                          const SizedBox(width: 3),
                          Text('${status.battery}%'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个空格 + 两个数字的宽度，用于页数与百分比之间的分隔。
  double _gapWidth(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      text: TextSpan(text: ' 00', style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }
}
