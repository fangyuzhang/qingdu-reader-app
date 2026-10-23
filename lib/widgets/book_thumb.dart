import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/poster_cache.dart';

/// 【青茄重构·新增】小尺寸书籍封面（列表行、报告页共用）。
///
/// 统一处理三件容易各写一遍的事：空链接兜底、加载失败兜底、按显示尺寸
/// 限制解码分辨率（走 [PosterCache] 磁盘缓存，滚动回来不再重新下载）。
class BookThumb extends StatelessWidget {
  const BookThumb({
    super.key,
    required this.url,
    this.width = 40,
    this.height = 52,
    this.radius = 6,
    this.iconSize = 20,
    this.backgroundColor,
    this.iconColor,
  });

  final String url;
  final double width;
  final double height;
  final double radius;
  final double iconSize;

  /// 兜底底色 / 图标色，缺省跟随当前主题。
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: width,
      height: height,
      color: backgroundColor ?? scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.book_open,
        size: iconSize,
        color: iconColor ?? scheme.onSurfaceVariant,
      ),
    );
    final rounded = BorderRadius.circular(radius);
    if (url.isEmpty) return ClipRRect(borderRadius: rounded, child: fallback);
    return ClipRRect(
      borderRadius: rounded,
      child: CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        // 按显示尺寸的 3 倍解码，兼顾清晰度与内存。
        memCacheWidth: (width * 3).round(),
        memCacheHeight: (height * 3).round(),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
