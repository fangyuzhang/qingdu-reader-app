import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/curated_book.dart';
import '../services/curated_resolver.dart';
import '../widgets/curated/curated_book_cover.dart';
import '../widgets/home/home_design.dart';
import 'detail_page.dart';
import 'search_page.dart';

/// 书单条目「查看详情」的公共链路。
///
/// 【轻读修复·新增】先把书目解析成书城里的同名书，再交给
/// `DetailPage` 展示书籍详情与目录；解析失败（离线/书城
/// 没有结果）时回退到搜索页，让用户自己挑一个来源。
///
/// 首页和荐读页共用这一条链路，避免两处行为跑偏。
Future<void> openCuratedReading(
  BuildContext context,
  CuratedBook book, {
  ValueChanged<bool>? onBusy,
}) async {
  onBusy?.call(true);
  CuratedResolution? resolution;
  try {
    resolution = await CuratedResolver.instance.resolve(book);
  } catch (_) {
    resolution = null;
  }
  onBusy?.call(false);
  if (!context.mounted) return;

  if (resolution != null) {
    final item = resolution.toMediaItem();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => DetailPage(item: item)));
    return;
  }

  // 网络失败和「书城没有这本书」都会走到这里，文案不要只说断网。
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('暂时找不到可读的书源，先帮你搜一下')));
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SearchPage(initialQuery: book.keyword),
    ),
  );
}

/// 单本荐读书目详情。
///
/// 【轻读重构·新增】首页不再直接推网文流，这里是「编辑部书单」的落点：
/// 展示书目信息 + 荐语。主按钮先进入书城详情与目录，
/// 下方仍保留「在书城搜索」作为手动挑源的次要入口。
class CuratedBookPage extends StatefulWidget {
  const CuratedBookPage({
    super.key,
    required this.book,
    required this.category,
    this.siblings = const [],
    this.categoryOf,
  });

  final CuratedBook book;
  final CuratedCategory? category;

  /// 同分类的其它书（底部「同类推荐」）。
  final List<CuratedBook> siblings;

  final CuratedCategory? Function(String key)? categoryOf;

  @override
  State<CuratedBookPage> createState() => _CuratedBookPageState();
}

class _CuratedBookPageState extends State<CuratedBookPage> {
  bool _opening = false;

  CuratedBook get book => widget.book;
  CuratedCategory? get category => widget.category;
  List<CuratedBook> get siblings => widget.siblings;
  CuratedCategory? Function(String key)? get categoryOf => widget.categoryOf;

  @override
  void initState() {
    super.initState();
    // 长按进来时封面可能还在后台解析，解析完成后要换掉文字封面。
    CuratedResolver.instance.changes.addListener(_onResolutionChanged);
  }

  @override
  void dispose() {
    CuratedResolver.instance.changes.removeListener(_onResolutionChanged);
    super.dispose();
  }

  void _onResolutionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final gradient =
        category?.gradient ?? CuratedCategory.defaultGradient;

    return Scaffold(
      backgroundColor: palette.canvas,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 264,
            backgroundColor: palette.canvas,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
            leading: IconButton(
              key: const Key('curated-back'),
              icon: const Icon(LucideIcons.arrow_left),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradient,
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -60,
                      top: -40,
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          CuratedBookCover(
                            book: book,
                            category: category,
                            width: 96,
                            showAge: false,
                            coverUrl: CuratedResolver.instance
                                .cached(book.id)
                                ?.cover,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  book.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    height: 1.25,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  book.author,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.86),
                                    fontSize: 12.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    _Pill(
                                      text: book.age,
                                      bg: Colors.white.withValues(alpha: 0.18),
                                    ),
                                    const SizedBox(width: 6),
                                    if (category != null)
                                      _Pill(
                                        text: category!.label,
                                        bg: Colors.white.withValues(
                                          alpha: 0.18,
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
                  ],
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BlurbCard(blurb: book.blurb, tags: book.tags),
                  const SizedBox(height: 16),
                  _HowToReadCard(keyword: book.keyword),
                  if (siblings.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text(
                      '同类推荐',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (final sibling in siblings.take(4))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: CuratedBookRow(
                          book: sibling,
                          category:
                              categoryOf?.call(sibling.category) ?? category,
                          coverUrl: CuratedResolver.instance
                              .cached(sibling.id)
                              ?.cover,
                          onTap: () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => CuratedBookPage(
                                book: sibling,
                                category:
                                    categoryOf?.call(sibling.category) ??
                                    category,
                                siblings: const [],
                                categoryOf: categoryOf,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  key: const Key('curated-search-button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: HomePalette.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _opening ? null : _startReading,
                  icon: _opening
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(LucideIcons.book_open, size: 18),
                  label: Text(
                    _opening ? '正在打开…' : '查看书籍详情',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              TextButton(
                key: const Key('curated-browse-button'),
                style: TextButton.styleFrom(
                  foregroundColor: palette.muted,
                  minimumSize: const Size(0, 40),
                ),
                onPressed: _browse,
                child: Text(
                  '在书城搜索',
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startReading() async {
    // 按钮要等下一帧才刷新成 disabled，同一帧的第二次点击会重复 push。
    if (_opening) return;
    await openCuratedReading(
      context,
      book,
      onBusy: (busy) {
        if (mounted) setState(() => _opening = busy);
      },
    );
  }

  void _browse() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(initialQuery: book.keyword),
      ),
    );
  }
}

class _BlurbCard extends StatelessWidget {
  const _BlurbCard({required this.blurb, required this.tags});

  final String blurb;
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.quote, size: 15, color: HomePalette.accent),
              const SizedBox(width: 6),
              Text(
                '编辑部荐语',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            blurb,
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: palette.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(fontSize: 11, color: palette.muted),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 诚实说明「书从哪来」：书单只做推荐，正文来自书城书源。
class _HowToReadCard extends StatelessWidget {
  const _HowToReadCard({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '怎么读这本书',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '书单只做推荐，正文来自书城书源；点“查看书籍详情”会先打开同名书的'
            '详情与目录，再由你决定何时进入正文。如果暂时找不到，也可以在书城'
            '搜索「$keyword」自己挑一个来源。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: palette.muted),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.bg});

  final String text;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.5,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
