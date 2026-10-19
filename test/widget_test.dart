// Basic smoke test: the app boots and survives a failed backend start.
//
// Wrapped in ProviderScope to mirror main() — HomePage is a ConsumerWidget,
// so any future test that reaches it needs the provider scope present.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/curated_resolver.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  // 本地数据初始化必须放在 setUp（真实异步 zone）：testWidgets 体内是
  // 假时钟，真实文件 IO 在里面永远等不到完成，测试会整体挂起。
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-shell-test');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await CuratedLibrary.load();
    // 首页的封面预取会走网络解析：注入假搜索，避免等待真实 socket IO。
    CuratedResolver.instance.resetForTest();
    CuratedResolver.instance.search = (query) async => const <MediaItem>[];
  });

  tearDown(() async {
    await Hive.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('后端启动失败：页面照常显示，SnackBar 可重试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RootShell(
          backendStarter: () async {
            attempts++;
            throw StateError('本地服务启动失败的详细信息');
          },
        ),
      ),
    );
    await tester.pump();

    // 【青茄】启动失败不再扣住整页：壳与首页照常渲染（首页自身目录
    // 加载的转圈除外），失败只体现为一条可重试的 SnackBar。
    expect(find.byKey(const Key('home-category-bar')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 点 SnackBar 上的「重试」再试一次（先让它滑入完成）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(attempts, 2);

    // 等 SnackBar 自动关闭，避免测试结束时残留隐藏定时器。
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FqApp()));
    await tester.pump();
    // The app should show the backend startup screen or the main shell.
    expect(find.byType(FqApp), findsOneWidget);
  });
}
