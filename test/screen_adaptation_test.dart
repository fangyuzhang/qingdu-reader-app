import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/category_browse_cache.dart';
import 'package:fqapp/services/curated_resolver.dart';
import 'package:fqapp/services/reader_device.dart';

import 'support/fakes.dart';

/// 【轻读·屏幕适配回归】市面上机型跨度：360dp 窄屏手机 ~ 1.8× 系统字号
/// 到平板/折叠屏 800dp+ 宽。这里锁定两条底线：
/// 1. 阅读器在宽屏上把正文栏钳制到 560dp 居中（行长回到舒适区间），
///    手机宽度上保持全宽不变；
/// 2. 主页面在最窄手机宽 + 最大字号、最宽平板宽下渲染无异常（溢出
///    断言在 widget 测试里表现为 exception，takeException 必须为 null）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    CategoryBrowseCache.instance.resetForTest();
    CuratedResolver.instance.resetForTest();
    CuratedResolver.instance.search = (query) async => const <MediaItem>[];
  });

  group('阅读器正文栏宽', () {
    final chapters = [
      Chapter(
        itemId: 'chapter-1',
        title: '第一章',
        volumeName: '',
        version: '1',
      ),
    ];

    Widget readerApp({double scale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ReaderPage(
        bookId: 'adapt-book',
        title: '适配之书',
        chapters: chapters,
        startIndex: 0,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (chapter) async => List.generate(
          40,
          (i) => '第$i 段。山川湖海各有归处，读者在窄屏与宽屏上都该读得舒服。',
        ).join('\n'),
        readerDevice: _Device(),
      ),
    );

    testWidgets('平板宽屏（1280×800）正文栏钳制 560dp 并居中', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(readerApp());
      await tester.pumpAndSettle();

      final column = find.byKey(const ValueKey('reader-column-box'));
      expect(column, findsOneWidget);
      expect(tester.getSize(column).width, 560);
      // 居中：栏盒中心与屏幕中心同一条竖线。
      final columnRect = tester.getRect(column);
      expect(columnRect.center.dx, closeTo(640, 0.5));
      // 正文真的渲染了（不是空白/loading）。
      expect(find.text('第一章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('手机宽（390×760）保持全宽不钳制', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(readerApp());
      await tester.pumpAndSettle();

      final column = find.byKey(const ValueKey('reader-column-box'));
      expect(column, findsOneWidget);
      expect(tester.getSize(column).width, 390);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏 + 1.8 倍字号同时生效仍无异常', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(readerApp(scale: 1.8));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(
          find.byKey(const ValueKey('reader-column-box')),
        ).width,
        560,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('主页面极端画布烟雾', () {
    CuratedCategory category(String key, String label) => CuratedCategory(
      key: key,
      label: label,
      desc: '$label 的说明',
      gradient: const [Color(0xFF2FA98C), Color(0xFF1F7F69)],
    );

    Widget homeApp({required double scale}) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: HomePage(
        catalog: CuratedCatalog(
          categories: [
            category('gudian', '古典名著'),
            category('shijie', '世界文学'),
          ],
          books: [
            CuratedBook(
              id: 'b1',
              title: '西游记',
              author: '吴承恩',
              category: 'gudian',
              blurb: '古典名著入门首选。',
              tags: const ['经典'],
              age: '12+',
            ),
            CuratedBook(
              id: 'b2',
              title: '老人与海',
              author: '海明威',
              category: 'shijie',
              blurb: '中篇经典。',
              tags: const ['外国文学'],
              age: '12+',
            ),
          ],
        ),
      ),
    );

    testWidgets('最窄主流手机（360×800）+ 1.8 倍字号无异常', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(homeApp(scale: 1.8));
      await tester.pumpAndSettle();
      expect(find.text('西游记'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('平板宽（1280×800）无异常', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(homeApp(scale: 1));
      await tester.pumpAndSettle();
      expect(find.text('西游记'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}
