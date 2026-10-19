import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/widgets/curated/curated_book_cover.dart';

/// 封面组件：有网络封面时渲染图片，缺省/失败时回退文字封面。
void main() {
  const book = CuratedBook(
    id: 'b1',
    title: '小王子',
    author: '圣埃克苏佩里',
    category: 'classic',
    blurb: '',
    tags: [],
    age: '12+',
  );

  const category = CuratedCategory(
    key: 'classic',
    label: '世界文学',
    desc: '',
    gradient: [Color(0xFF2FA98C), Color(0xFF1F7F69)],
  );

  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('没有 coverUrl 时只渲染文字封面', (tester) async {
    await tester.pumpWidget(
      wrap(const CuratedBookCover(book: book, category: category)),
    );

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(CuratedBookCover.fallbackKey), findsOneWidget);
    expect(find.text('小王子'), findsOneWidget);
  });

  testWidgets('coverUrl 为空白时按无封面处理，不发图片请求', (tester) async {
    await tester.pumpWidget(
      wrap(
        const CuratedBookCover(book: book, category: category, coverUrl: '   '),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byKey(CuratedBookCover.fallbackKey), findsOneWidget);
  });

  testWidgets('有 coverUrl 时渲染网络封面，加载/失败时回退文字封面', (tester) async {
    await tester.pumpWidget(
      wrap(
        const CuratedBookCover(
          book: book,
          category: category,
          coverUrl: 'https://example.com/cover.jpg',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    // 测试环境没有网络：占位/错误态都应该是文字封面，而不是白块。
    expect(find.byKey(CuratedBookCover.fallbackKey), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(CuratedBookCover.fallbackKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
