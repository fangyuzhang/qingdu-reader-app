import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/pages/curated_book_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/search_page.dart';

/// 新首页（编辑部书单）的测试。
///
/// 旧首页测试针对的是上游网文推荐流（tab 栏 / 网格 / 分页加载），
/// 那套 UI 已被整页替换，这里按新结构重写：分类推荐、今日荐读、
/// 点书进详情、详情里「在书城搜索」仍走得通。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
  }) => CuratedBook(
    id: id,
    title: title,
    author: '作者$id',
    category: categoryKey,
    blurb: '$title 的一句话荐语。',
    tags: const ['经典'],
    age: age,
  );

  final catalog = CuratedCatalog(
    categories: [
      category('classic', '古典名著'),
      category('science', '科普百科'),
    ],
    books: [
      book('a', '西游记', 'classic'),
      book('b', '水浒传', 'classic', age: '15+'),
      book('c', '时间简史', 'science', age: '15+'),
    ],
  );

  Widget app(Widget child) => MaterialApp(home: child);

  testWidgets('首页展示今日荐读、分类条与分类书单', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    expect(find.text('青茄 · 青少年书房'), findsOneWidget);
    expect(find.byKey(const Key('home-today-pick')), findsOneWidget);
    expect(find.byKey(const Key('home-category-bar')), findsOneWidget);
    // 两个分类标题都在（分类区按顺序渲染）
    expect(find.text('古典名著'), findsWidgets);
    expect(find.text('科普百科'), findsWidgets);
    expect(find.byKey(const Key('home-search-button')), findsOneWidget);
  });

  testWidgets('点分类只显示该分类的书', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-category-science')));
    await tester.pumpAndSettle();

    // 分类说明 + 该分类书目；其它分类的书不再出现
    expect(find.text('科普百科 的说明'), findsOneWidget);
    expect(find.text('时间简史'), findsWidgets);
    expect(find.text('西游记'), findsNothing);
  });

  testWidgets('点书进详情，详情可跳书城搜索', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-today-pick')));
    await tester.pumpAndSettle();

    expect(find.byType(CuratedBookPage), findsOneWidget);
    expect(find.byKey(const Key('curated-search-button')), findsOneWidget);
    // 详情页说明「不内置正文，走搜索」
    expect(find.textContaining('不内置正文'), findsOneWidget);

    await tester.tap(find.byKey(const Key('curated-search-button')));
    // 搜索页自带加载态动画，pumpAndSettle 会等不到静止
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchPage), findsOneWidget);
  });

  testWidgets('搜索按钮打开搜索页', (tester) async {
    await tester.pumpWidget(app(HomePage(catalog: catalog)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-search-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchPage), findsOneWidget);
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
      expect(catalog.pickOfDay(now: day.add(const Duration(days: 1))), isNotNull);
      expect(catalog.books, hasLength(3));
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
}
