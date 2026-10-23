import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/category_browse_page.dart';
import 'package:fqapp/services/category_browse_cache.dart';

void main() {
  setUp(() {
    CategoryBrowseCache.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  const category = CuratedCategory(
    key: 'classic',
    label: '古典名著',
    desc: '中国人的精神底色，从故事里读懂人情与分寸',
    gradient: [Color(0xFF2FA98C), Color(0xFF1F7F69)],
  );

  MediaItem item(String id, String title) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: '作者',
    badge: '',
    ep: '',
    kind: 'book',
  );

  Widget app(HomeCategoryBooksLoader loader) => MaterialApp(
    home: CategoryBrowsePage(category: category, loader: loader),
  );

  testWidgets('分类页会合并多个检索词，不再只有少许固定书目', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      app(
        (query, offset) async => [
          for (var i = 0; i < 5; i++) item('$query-$offset-$i', '$query 第$i本'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('category-loaded-count')), findsOneWidget);
    expect(find.text('已载入 25 本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('过时缓存留在原位，新结果追加而不是整片替换', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CategoryBrowseCache.instance.write('classic', 0, [
      item('cached-1', '缓存第一本'),
      item('cached-2', '缓存第二本'),
    ], at: DateTime.now().subtract(const Duration(hours: 7)));

    await tester.pumpWidget(
      app((query, offset) async => [item('live-$query', '$query 新书')]),
    );
    await tester.pumpAndSettle();

    // 缓存里的两本必须原地不动，新结果接在后面：2 + 5 个关键词各一本。
    expect(find.text('缓存第一本'), findsOneWidget);
    expect(find.text('缓存第二本'), findsOneWidget);
    expect(find.text('古典名著 新书'), findsOneWidget);
    expect(find.text('已载入 7 本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换一批读取下一段结果，加载更多继续追加', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];

    await tester.pumpWidget(
      app((query, offset) async {
        calls.add('$query@$offset');
        final count = offset == 0 ? 2 : (offset == 10 ? 2 : 1);
        return [
          for (var i = 0; i < count; i++)
            item('$query-$offset-$i', '$query@$offset 第$i本'),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('已载入 10 本'), findsOneWidget);

    await tester.tap(find.byKey(const Key('category-change-batch')));
    await tester.pumpAndSettle();
    expect(find.text('已载入 10 本'), findsOneWidget);
    expect(calls.where((call) => call.endsWith('@10')), hasLength(5));

    await tester.scrollUntilVisible(
      find.byKey(const Key('category-load-more')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('category-books-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const Key('category-load-more')));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.endsWith('@20')), hasLength(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存命中的分类直接铺满首屏，不再请求上游', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    CategoryBrowseCache.instance.write('classic', 0, [
      for (var i = 0; i < 12; i++) item('cached-$i', '缓存书 $i'),
    ]);

    var calls = 0;
    await tester.pumpWidget(
      app((query, offset) async {
        calls++;
        return const [];
      }),
    );
    await tester.pump();

    expect(find.text('已载入 12 本'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首个关键词返回就先渲染，不等其余搜索', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pending = List.generate(4, (_) => Completer<List<MediaItem>>());
    var index = 0;
    await tester.pumpWidget(
      app((query, offset) {
        if (index++ == 0) {
          return Future<List<MediaItem>>.value([item('fast-1', '先到的书')]);
        }
        return pending[0].future;
      }),
    );

    await tester.pump();
    await tester.pump();
    expect(find.text('已载入 1 本'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    for (final completer in pending) {
      completer.complete(const []);
    }
    await tester.pumpAndSettle();
    expect(find.text('已载入 1 本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
