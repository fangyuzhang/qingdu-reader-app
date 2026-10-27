import '../models/media_item.dart';

/// 内容分级提示（12+ / 15+）。
///
/// 【轻读重构·新增】产品定位是面向青少年的纯净阅读器：**只做分级提示，
/// 不做硬性过滤**——按上游题材标签与简介关键词给出适龄建议，由读者
/// （或其家长）自行判断，避免把「疑似成熟题材」的经典作品直接拦在门外。
///
/// 判定规则保持可解释、可审计：
/// * 命中任一「成熟题材」关键词 → 15+
/// * 其余一律 12+（默认档，不是「无风险」承诺）
abstract final class ContentRating {
  static const age12 = '12+';
  static const age15 = '15+';

  /// 15+ 关键词：犯罪/惊悚/战争等需要更强判断力的题材。
  static const matureKeywords = <String>[
    '悬疑',
    '推理',
    '惊悚',
    '恐怖',
    '灵异',
    '犯罪',
    '凶案',
    '谋杀',
    '复仇',
    '战争',
    '末世',
    '暴力',
    '黑帮',
    '毒品',
    '自杀',
  ];

  /// 从书籍分类与简介推断分级。
  static String of({
    List<String> categories = const [],
    String intro = '',
    String title = '',
  }) {
    final haystack = [...categories, title, intro].join(' ');
    for (final keyword in matureKeywords) {
      if (haystack.contains(keyword)) return age15;
    }
    return age12;
  }

  /// 便捷重载：直接按书架上的一条作品判定。
  static String ofItem(MediaItem item) =>
      of(categories: item.categories, intro: item.intro, title: item.title);

  /// 一句话说明，用在分级标签的 tooltip / 长按提示里。
  static String explain(String rating) => rating == age15
      ? '15+：含犯罪、惊悚或战争等题材，建议 15 岁以上阅读'
      : '12+：常规题材，12 岁以上可读';
}
