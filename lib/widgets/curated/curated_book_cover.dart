import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/curated_book.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';

/// 文字封面：书单本身没有封面图时，用分类渐变 + 书名排版生成，
/// 保证离线也能有稳定的视觉识别（每本书的颜色只取决于分类）。
///
/// 【青茄修复·新增】[coverUrl] 非空时改为渲染书城真实封面；加载中/失败
/// 仍然显示文字封面（占位与 errorWidget 都返回它），所以不会闪白块，
/// 断网时观感与以前完全一致。
class CuratedBookCover extends StatelessWidget {
  const CuratedBookCover({
    super.key,
    required this.book,
    required this.category,
    this.width = 104,
    this.showAge = true,
    this.coverUrl,
  });

  final CuratedBook book;
  final CuratedCategory? category;
  final double width;
  final bool showAge;

  /// 书城封面地址；空/缺省时只渲染文字封面。
  final String? coverUrl;

  /// 回退文字封面的 key（测试用来断言离线/失败态）。
  static const fallbackKey = Key('curated-cover-fallback');

  @override
  Widget build(BuildContext context) {
    final height = width * 4 / 3;
    final url = coverUrl?.trim() ?? '';
    if (url.isEmpty) return _fallbackCover();

    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        memCacheWidth: (width * ratio).round(),
        memCacheHeight: (height * ratio).round(),
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, _) => _fallbackCover(),
        errorWidget: (_, _, _) => _fallbackCover(),
      ),
    );
  }

  Widget _fallbackCover() {
    final gradient =
        category?.gradient ?? const [Color(0xFF2FA98C), Color(0xFF1F7F69)];
    final height = width * 4 / 3;
    return SizedBox(
      key: fallbackKey,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: gradient,
            ),
          ),
          child: Stack(
            children: [
              // 装饰光斑：让纯色块不呆板
              Positioned(
                right: -width * 0.28,
                bottom: -width * 0.22,
                child: Container(
                  width: width * 0.7,
                  height: width * 0.7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
              ),
              Positioned(
                left: -width * 0.16,
                top: -width * 0.2,
                child: Container(
                  width: width * 0.5,
                  height: width * 0.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  width * 0.11,
                  width * 0.12,
                  width * 0.11,
                  width * 0.10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: width * 0.15,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: width * 0.105,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              if (showAge)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      book.age,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 竖排书目行（分类页 / 搜索结果式列表用）。
class CuratedBookRow extends StatelessWidget {
  const CuratedBookRow({
    super.key,
    required this.book,
    required this.category,
    required this.onTap,
    this.onLongPress,
    this.coverUrl,
  });

  final CuratedBook book;
  final CuratedCategory? category;
  final VoidCallback onTap;

  /// 长按进「荐读页」（首页保留的荐语入口）。
  final VoidCallback? onLongPress;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      onLongPress: onLongPress,
      child: HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        semanticLabel: '${book.title}，${book.author}',
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CuratedBookCover(
                book: book,
                category: category,
                width: 62,
                showAge: false,
                coverUrl: coverUrl,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: palette.ink,
                            ),
                          ),
                        ),
                        _AgeTag(age: book.age),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      book.blurb,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: palette.ink.withValues(alpha: 0.78),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final tag in book.tags.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: palette.soft,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.3,
                                color: palette.muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 12+ / 15+ 适龄标记：15+ 用点缀色，其余用中性色。
class _AgeTag extends StatelessWidget {
  const _AgeTag({required this.age});

  final String age;

  @override
  Widget build(BuildContext context) {
    final mature = age == '15+';
    final color = mature ? HomePalette.highlight : HomePalette.accentStrong;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Text(
        age,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 横向书单里的一张卡：封面 + 书名 + 作者。
class CuratedBookTile extends StatelessWidget {
  const CuratedBookTile({
    super.key,
    required this.book,
    required this.category,
    required this.width,
    required this.onTap,
    this.onLongPress,
    this.coverUrl,
  });

  final CuratedBook book;
  final CuratedCategory? category;
  final double width;
  final VoidCallback onTap;

  /// 长按进「荐读页」（首页保留的荐语入口）。
  final VoidCallback? onLongPress;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return GestureDetector(
      onLongPress: onLongPress,
      child: HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        semanticLabel: '${book.title}，${book.author}',
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CuratedBookCover(
                book: book,
                category: category,
                width: width,
                showAge: false,
                coverUrl: coverUrl,
              ),
              const SizedBox(height: 8),
              // 用 Flexible 兜住：外层横滑列表是定高的，字号放大时宁可
              // 挤压也不允许溢出（1.8x 字号实测会差 0.15px）。
              Flexible(
                child: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
