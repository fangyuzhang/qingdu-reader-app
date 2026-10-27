import 'package:flutter/material.dart';

import '../services/content_rating.dart';

/// 内容分级标签（12+ / 15+）。
///
/// 【轻读重构·新增】只做提示，不做拦截；15+ 用描边强调，12+ 用弱化灰。
class ContentRatingChip extends StatelessWidget {
  const ContentRatingChip({
    super.key,
    required this.rating,
    this.compact = false,
  });

  final String rating;

  /// 紧凑态用于阅读器顶栏（更小字号与内边距）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final is15 = rating == ContentRating.age15;
    final color = is15 ? const Color(0xFFD64545) : const Color(0xFF8A7B62);
    return Tooltip(
      message: ContentRating.explain(rating),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 5 : 7,
          vertical: compact ? 1 : 2,
        ),
        decoration: BoxDecoration(
          color: is15 ? const Color(0x14D64545) : const Color(0x148A7B62),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 0.7),
        ),
        child: Text(
          rating,
          style: TextStyle(
            fontSize: compact ? 10 : 11,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}
