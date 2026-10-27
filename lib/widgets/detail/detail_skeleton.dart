import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 【轻读性能·新增】详情页首开骨架屏。
///
/// 详情首开要等一次上游往返（实测约 470ms，网络差时更久）。之前这段等待
/// 只有一个 22px 的转圈，页面看起来是"卡住然后突然弹出"；换成和真实版式
/// 同构的灰色占位条后，用户一眼就知道内容正在铺开，观感等待明显变短。
///
/// 只有在系统开启「减少动画」（含墨水屏）时才停止呼吸动画，避免眩晕与耗电。
class DetailSkeleton extends StatefulWidget {
  /// 骨架下方的附加内容（例如离线时的「从缓存阅读」按钮）。
  final Widget? footer;

  const DetailSkeleton({super.key, this.footer});

  @override
  State<DetailSkeleton> createState() => _DetailSkeletonState();
}

class _DetailSkeletonState extends State<DetailSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = !MediaQuery.disableAnimationsOf(context);
    if (animate && !_running) {
      _pulse.repeat(reverse: true);
      _running = true;
    } else if (!animate && _running) {
      _pulse.stop();
      _pulse.value = 0;
      _running = false;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final tone = palette.line;
    Widget bar(double width, double height, {double radius = 6}) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: tone,
            borderRadius: BorderRadius.circular(radius),
          ),
        );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [bar(96, 14), const SizedBox(height: 8), bar(64, 11)],
            ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: tone,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 22),
        bar(double.infinity, 13),
        const SizedBox(height: 10),
        bar(double.infinity, 13),
        const SizedBox(height: 10),
        bar(double.infinity, 13),
        const SizedBox(height: 10),
        FractionallySizedBox(
          widthFactor: 0.62,
          child: bar(double.infinity, 13),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            for (final w in const [64.0, 82.0, 56.0]) ...[
              Container(
                width: w,
                height: 26,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 22),
        bar(150, 12),
        const SizedBox(height: 18),
        bar(120, 15),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.line),
          ),
          child: Column(
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      bar(16, 12),
                      const SizedBox(width: 14),
                      Expanded(child: bar(double.infinity, 13)),
                      const SizedBox(width: 40),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Column(
          key: const Key('detail_skeleton'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FadeTransition(
              opacity: Tween<double>(begin: 0.45, end: 1).animate(_pulse),
              child: body,
            ),
            if (widget.footer != null) ...[
              const SizedBox(height: 18),
              Center(child: widget.footer!),
            ],
          ],
        ),
      ),
    );
  }
}
