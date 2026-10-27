import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/curated_book_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/category_browse_cache.dart';
import 'package:fqapp/services/curated_resolver.dart';
import 'package:fqapp/widgets/curated/curated_book_cover.dart';

/// 新首页（编辑部书单）的测试。
///
/// 点书 = 解析成书城书籍后打开详情与目录；长按 = 荐读页（荐语 + 搜索入口）。
/// 所有搜索都注入假实现，禁止真联网。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CategoryBrowseCache.instance.resetForTest();
    CuratedResolver.instance.resetForTest();
    // 默认给一个「搜不到」的假搜索，避免任何用例漏注入时真的联网。
    CuratedResolver.instance.search = (query) async => const <MediaItem>[];
  });

  CuratedCategory category(String key, String label) => CuratedCategory(
    key: key,
    label: label,
    desc: '$label 的说明',
    gradient: const [Color(0xFF2FA98C), Color(0xFF1F7F69)],
  );

  CuratedBook book(
    String id,
    String title,
    String categoryKey, {
    String age = '12+',
    bool audio = false,
  }) => CuratedBook(
    id: id,
    title: title,
    author: '作者$id',
    category: categoryKey,
    blurb: '$title 的一句话荐语。',
    tags: const ['经典'],
    age: age,
    audio: audio,
  );

  final catalog = CuratedCatalog(
    categories: [category('classic', '古典名著'), category('science', '科普百科')],
    books: [
      book('a', '西游记', 'classic', audio: true),
      book('b', '水浒传', 'classic', age: '15+'),
      book('c', '时间简史', 'science', age: '15+'),
    ],
  );

  Widget app(Widget child) => MaterialApp(home: child);

  MediaItem searchHit(String title) => MediaItem(
    id: 'hit-$title',
    title: title,
    cover: 'https://example.com/$title.jpg',
    author: '作者a',
    badge: '',
    ep: '',
    kind: 'book',
  );

  /// 只让今日荐读的那本解析成功，其余返回空。
  void mockSearchFor(String title) {
    CuratedResolver.instance.search = (query) async {
      if (query == title) return [searchHit(title)];
      return const <MediaItem>[];
    };
  }

  testWidgets('首页展示今日荐读、分类条与分类书单', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    // 【轻读】问候语已删，顶栏固定：分类条 + 搜索按钮全程可见。
    expect(find.text('轻读 · 青少年书房'), findsNothing);
    expect(find.byKey(const Key('home-category-bar')), findsOneWidget);
    expect(find.byKey(const Key('home-today-pick')), findsOneWidget);
    expect(find.byKey(const Key('home-cat-button-classic')), findsOneWidget);
    // 听书入口按产品要求从首页分类条移除。
    expect(find.byKey(const Key('home-category-listen')), findsNothing);
    // 两个分类标题都在（分类区按顺序渲染）
    expect(find.text('古典名著'), findsWidgets);
    expect(find.text('科普百科'), findsWidgets);
    expect(find.byKey(const Key('home-search-button')), findsOneWidget);
  });

  testWidgets('分类功能按钮打开可继续加载的分类书城页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<List<MediaItem>> loader(String query, int offset) async =>
        offset == 0 ? [searchHit('科普读物一')] : const [];

    await tester.pumpWidget(
      app(HomePage(catalog: catalog, categoryLoader: loader)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-cat-button-science')));
    await tester.pumpAndSettle();

    // 分类「全部」视图内嵌在首页 PageView 中：不再另开路由。
    expect(find.textContaining('科普百科 的说明'), findsOneWidget);
    expect(find.byKey(const Key('category-loaded-count')), findsOneWidget);
    expect(find.text('科普百科'), findsWidgets);
    expect(find.text('科普读物一'), findsOneWidget);
  });

  testWidgets('有声书磁贴点开走直达音频详情链路', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 让「西游记」的解析命中一个 audio 源：书单里的有声书点开直接给音频。
    CuratedResolver.instance.search = (query) async {
      if (query.contains('西游记')) {
        return [
          MediaItem(
            id: 'hit-audio',
            title: '西游记',
            cover: '',
            author: '吴承恩',
            badge: '',
            ep: '',
            kind: 'audio',
          ),
        ];
      }
      return const <MediaItem>[];
    };

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    // 听书入口改为书单音频书本体：推荐板块的磁贴点开仍走直达链路。
    final tile = find.byKey(const Key('home-recommend-classic-a'));
    await tester.scrollUntilVisible(
      tile,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
    final detail = tester.widget<DetailPage>(
      find.byType(DetailPage, skipOffstage: false),
    );
    expect(detail.item.kind, 'audio');
  });

  testWidgets('滚动时不再出现浮动搜索按钮，顶部搜索入口保留', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    final list = find.byKey(const Key('home_curated'));
    for (var i = 0; i < 12; i++) {
      await tester.drag(list, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();

    // 固定顶栏的搜索按钮全程在；滚动后不再叠一个浮动搜索按钮。
    expect(find.byKey(const Key('home-search-float')), findsNothing);
    expect(find.byKey(const Key('home-search-button')), findsOneWidget);
  });

  testWidgets('顶部分类标签打开该分类书城页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<List<MediaItem>> loader(String query, int offset) async =>
        offset == 0 ? [searchHit('时间简史')] : const [];

    await tester.pumpWidget(
      app(HomePage(catalog: catalog, categoryLoader: loader)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-category-science')));
    await tester.pumpAndSettle();

    // chip 点击在 PageView 内就地切换到该分类的全部视图。
    expect(find.textContaining('科普百科 的说明'), findsOneWidget);
    expect(find.text('科普百科'), findsWidgets);
    expect(find.text('时间简史'), findsOneWidget);
    expect(find.text('西游记'), findsNothing);
  });

  testWidgets('点今日荐读先打开书籍详情与目录，不自动进正文', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pick = catalog.pickOfDay()!;
    mockSearchFor(pick.title);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final detail = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(detail.item.id, 'hit-${pick.title}');
    // 不再先进荐读页
    expect(find.byType(CuratedBookPage), findsNothing);
  });

  testWidgets('解析期间有可见反馈，快速连点只打开一个详情页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pick = catalog.pickOfDay()!;
    CuratedResolver.instance.search = (query) async {
      // 【轻读】只有今日荐读慢（让点击出现 spinner）；其余书立即返回空，
      // prefetch 的整条队列不会在测试结束时留下未到期的定时器。
      if (query != pick.keyword) return const <MediaItem>[];
      await Future<void>.delayed(const Duration(seconds: 2));
      return [searchHit(query)];
    };

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    // 同一帧内连点两下：第二次必须被闸门挡住。
    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DetailPage, skipOffstage: false), findsOneWidget);
    final detail = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(detail.item.id, 'hit-${pick.title}');
  });

  testWidgets('分类列表里的书点一下也先打开书籍详情', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final item = searchHit('时间简史');
    Future<List<MediaItem>> loader(String query, int offset) async =>
        offset == 0 ? [item] : const [];

    await tester.pumpWidget(
      app(HomePage(catalog: catalog, categoryLoader: loader)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-category-science')));
    await tester.pumpAndSettle();

    final row = find.byKey(ValueKey('category-book-${item.id}'));
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final detail = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(detail.item.id, 'hit-时间简史');
    expect(find.byType(CuratedBookPage), findsNothing);
  });

  testWidgets('荐读页连点「查看书籍详情」也只打开一个详情页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CuratedResolver.instance.search = (query) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return [searchHit('西游记')];
    };

    await tester.pumpWidget(
      app(
        CuratedBookPage(
          book: catalog.books.first,
          category: catalog.categories.first,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('curated-search-button'));
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();

    expect(find.text('正在打开…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DetailPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('长按卡片进荐读页，主按钮指向书籍详情', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pick = catalog.pickOfDay()!;
    mockSearchFor(pick.title);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('home-today-pick')));
    await tester.pumpAndSettle();

    expect(find.byType(CuratedBookPage), findsOneWidget);
    expect(find.text('查看书籍详情'), findsOneWidget);
    expect(find.byKey(const Key('curated-search-button')), findsOneWidget);
    expect(find.byKey(const Key('curated-browse-button')), findsOneWidget);
    // 免责声明同步成「正文来自书城书源」
    expect(find.textContaining('正文来自书城书源'), findsOneWidget);

    await tester.tap(find.byKey(const Key('curated-search-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DetailPage), findsOneWidget);
  });

  testWidgets('荐读页的封面在后台解析完成后会刷新', (tester) async {
    final target = catalog.books.first;
    CuratedResolver.instance.search = (query) async => [searchHit('西游记')];

    await tester.pumpWidget(
      app(CuratedBookPage(book: target, category: catalog.categories.first)),
    );
    await tester.pumpAndSettle();

    CuratedBookCover cover() =>
        tester.widget<CuratedBookCover>(find.byType(CuratedBookCover));
    expect(cover().coverUrl, isNull);

    // 模拟首页的 prefetch 在荐读页打开之后才完成。
    await CuratedResolver.instance.resolve(target);
    await tester.pump();

    expect(cover().coverUrl, isNotNull);
  });

  testWidgets('荐读页「在书城搜索」仍打开搜索页', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      app(
        CuratedBookPage(
          book: catalog.books.first,
          category: catalog.categories.first,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('curated-browse-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchPage), findsOneWidget);
  });

  testWidgets('解析失败时回退搜索页并提示', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CuratedResolver.instance.search = (query) async {
      throw Exception('offline');
    };

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    final pick = catalog.pickOfDay()!;
    expect(search.initialQuery, pick.keyword);
    expect(find.text('暂时找不到可读的书源，先帮你搜一下'), findsOneWidget);
  });

  testWidgets('书城搜不到结果时也回退搜索页并带上关键词', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // setUp 里的默认假搜索返回空列表，等价于「书城没有这本书」。
    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.initialQuery, catalog.pickOfDay()!.keyword);
    expect(find.byType(DetailPage), findsNothing);
  });

  testWidgets('解析出的真实封面会传到首页卡片', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CuratedResolver.instance.search = (query) async => [searchHit(query)];

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    final covers = tester
        .widgetList<CuratedBookCover>(find.byType(CuratedBookCover))
        .toList(growable: false);
    expect(covers, isNotEmpty);
    expect(covers.every((cover) => cover.coverUrl != null), isTrue);
  });

  testWidgets('异步解析完成后首页会重绘真实封面', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CuratedResolver.instance.search = (query) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return [searchHit(query)];
    };

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    List<CuratedBookCover> covers() => tester
        .widgetList<CuratedBookCover>(find.byType(CuratedBookCover))
        .toList(growable: false);

    // 首帧还没解析完：全部走文字封面。
    expect(covers(), isNotEmpty);
    expect(covers().every((cover) => cover.coverUrl == null), isTrue);

    // 并发上限 2：3 本书要两轮（2s + 2s），留足时间。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    // 后台解析完成 → changes 通知 → 首页 setState → 换成真实封面。
    expect(covers().every((cover) => cover.coverUrl != null), isTrue);
  });

  testWidgets('搜索按钮打开搜索页', (tester) async {
    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-search-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchPage), findsOneWidget);
  });

  testWidgets('换一批会更新今日荐读', (tester) async {
    final first = catalog.pickOfDay(batch: 0)!;
    final next = catalog.pickOfDay(batch: 1)!;
    expect(next.id, isNot(first.id));

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();
    Text title() =>
        tester.widget<Text>(find.byKey(const Key('home-today-pick-title')));
    expect(title().data, first.title);

    await tester.tap(find.byKey(const Key('home-recommendation-refresh')));
    await tester.pumpAndSettle();
    expect(title().data, next.title);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏 + 大字不溢出', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
        child: app(HomePage(catalog: catalog)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('书单数据', () {
    test('今日荐读同一天稳定、跨天轮换', () {
      final day = DateTime(2026, 10, 19);
      final first = catalog.pickOfDay(now: day);
      final again = catalog.pickOfDay(now: day.add(const Duration(hours: 6)));
      expect(first!.id, again!.id);
      expect(
        catalog.pickOfDay(now: day.add(const Duration(days: 1))),
        isNotNull,
      );
      expect(catalog.books, hasLength(3));
    });

    test('推荐位按日稳定，手动批次会轮换且每批不重复', () {
      final many = CuratedCatalog(
        categories: [category('classic', '古典名著')],
        books: [for (var i = 0; i < 8; i++) book('b$i', '书$i', 'classic')],
      );
      final day = DateTime(2026, 10, 19);
      final first = many.recommendationBatchOf('classic', now: day);
      final again = many.recommendationBatchOf('classic', now: day);
      final next = many.recommendationBatchOf('classic', now: day, batch: 1);

      expect(first, hasLength(4));
      expect(first.map((entry) => entry.id), again.map((entry) => entry.id));
      expect(first.map((entry) => entry.id).toSet(), hasLength(4));
      expect(
        next.map((entry) => entry.id).toSet(),
        isNot(first.map((entry) => entry.id).toSet()),
      );
      expect(
        many.recommendationBatchOf('classic', now: day, limit: 20),
        hasLength(8),
      );
    });

    test('limit 覆盖全部分类时，批次轮转整份日序（换一批仍有效）', () {
      final many = CuratedCatalog(
        categories: [category('classic', '古典名著')],
        books: [for (var i = 0; i < 10; i++) book('t$i', '书$i', 'classic')],
      );
      final day = DateTime(2026, 10, 19);
      final base = many.recommendationBatchOf(
        'classic',
        now: day,
        limit: 10,
      );
      expect(base, hasLength(10));
      final next = many.recommendationBatchOf(
        'classic',
        now: day,
        batch: 1,
        limit: 10,
      );
      expect(next, hasLength(10));
      // 轮转一位后整体顺序可感知变化，但仍是同一份书目。
      expect(next.map((e) => e.id).toSet(), base.map((e) => e.id).toSet());
      expect(next.first.id, isNot(base.first.id));
    });

    test('按分类取书与按 key 找分类', () {
      expect(catalog.booksOf('classic').map((b) => b.id), ['a', 'b']);
      expect(catalog.categoryOf('science')!.label, '科普百科');
      expect(catalog.categoryOf('missing'), isNull);
    });

    test('搜索关键词缺省用书名', () {
      expect(book('x', '论语', 'classic').keyword, '论语');
      const withKeyword = CuratedBook(
        id: 'y',
        title: '史记',
        author: '司马迁',
        category: 'classic',
        blurb: '',
        tags: [],
        age: '15+',
        searchKeyword: '史记 司马迁',
      );
      expect(withKeyword.keyword, '史记 司马迁');
    });

    test('15+ 判定', () {
      expect(book('m', '水浒传', 'classic', age: '15+').isMature, isTrue);
      expect(book('n', '西游记', 'classic').isMature, isFalse);
    });
  });

  testWidgets('分类卡片不再展示与「全部」对不上的本数', (tester) async {
    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    expect(find.textContaining('精选 2 本'), findsNothing);
    expect(find.text('精选书单 · 查看全部'), findsWidgets);
  });

  testWidgets('横向书架滑到末尾后继续右滑进入全部', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final many = CuratedCatalog(
      categories: [category('classic', '古典名著')],
      books: [for (var i = 0; i < 8; i++) book('rail$i', '古典名著$i', 'classic')],
    );
    Future<List<MediaItem>> loader(String query, int offset) async =>
        offset == 0 ? [searchHit('补充书')] : const [];

    await tester.pumpWidget(
      app(HomePage(catalog: many, categoryLoader: loader)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('home-rail-classic')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 先滚到末端，多出来的距离就是越过右端的 overscroll。
    await tester.drag(
      find.byKey(const Key('home-rail-classic')),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();

    // 滑到末端继续滑：就地切到「古典名著」的全部视图（不再另开页面）。
    expect(find.byKey(const Key('category-loaded-count')), findsOneWidget);
    expect(find.textContaining('古典名著 的说明'), findsOneWidget);
  });

  testWidgets('推荐磁贴的书名与作者行不重叠', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    // 列表定高若少算白卡内边距，两个 Flexible 文本会被压缩、字形互相
    // 盖住（作者名叠在书名上）。用文字盒矩形断言作者行不高于书名行底。
    final tile = find.byKey(const Key('home-recommend-classic-a'));
    final title = tester.getRect(
      find.descendant(
        of: tile,
        matching: find.byKey(const Key('curated-tile-title')),
      ),
    );
    final author = tester.getRect(
      find.descendant(
        of: tile,
        matching: find.byKey(const Key('curated-tile-author')),
      ),
    );
    expect(author.top, greaterThanOrEqualTo(title.bottom - 0.5));
  });
}
