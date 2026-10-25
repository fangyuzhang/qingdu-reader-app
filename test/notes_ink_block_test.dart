import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/models/reader_ink_block.dart';
import 'package:fqapp/pages/notes_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_ink_block_store.dart';
import 'package:fqapp/services/reader_underline_store.dart';

/// 内存版批注存储：与 notes_page_test 同一思路——子类覆写 loadAll，
/// 全程不碰 Hive（各 store 的 hiveReady 在测试里保持 false，未注入的
/// 默认单例读出来就是空表，不会拖住页面装载）。
class _NotesMemoryStore extends ReaderAnnotationStore {
  _NotesMemoryStore(this.notes);

  final List<ReaderAnnotation> notes;

  @override
  Future<List<ReaderAnnotation>> loadAll() async => notes;
}

class _MemoryUnderlines extends ReaderUnderlineStore {
  @override
  Future<List<ReaderRangeUnderline>> loadAllRanges() async => const [];

  @override
  Future<List<ReaderUnderline>> loadAllParagraphs() async => const [];
}

/// 内存版内嵌手写块存储：覆写 loadAll 返回内存列表；changes 直接用基类
/// 的 ValueNotifier，测试里手动 ++ 模拟写库通知。
class _MemoryInkBlocks extends ReaderInkBlockStore {
  _MemoryInkBlocks(this.blocks);

  final List<ReaderInkBlock> blocks;

  @override
  Future<List<ReaderInkBlock>> loadAll() async => blocks;
}

ReaderInkBlock _block({
  String bookId = 'a',
  String chapterId = 'a-c1',
  int anchor = 12,
  String kind = ReaderInkBlock.kindCanvas,
  int createdAt = 1,
  String bookTitle = '书 a',
  String chapterTitle = '第一章',
  int strokes = 2,
}) => ReaderInkBlock(
  bookId: bookId,
  chapterId: chapterId,
  anchor: anchor,
  anchorContext: '锚点上下文',
  kind: kind,
  height: ReaderInkBlock.defaultCanvasHeight,
  strokes: [
    for (var index = 0; index < strokes; index++)
      InkStroke(
        points: [
          InkPoint(x: 0.1 + 0.2 * index, y: 0.3),
          InkPoint(x: 0.3 + 0.2 * index, y: 0.6),
        ],
      ),
  ],
  createdAt: createdAt,
  updatedAt: createdAt,
  bookTitle: bookTitle,
  chapterTitle: chapterTitle,
);

NotesPage _page(_MemoryInkBlocks inkBlocks) => NotesPage(
  store: _NotesMemoryStore(const []),
  underlineStore: _MemoryUnderlines(),
  inkBlockStore: inkBlocks,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('手写筛选下列出画布与便签块，徽标与章节名兜底正确', (tester) async {
    final inkBlocks = _MemoryInkBlocks([
      _block(kind: ReaderInkBlock.kindCanvas, createdAt: 2),
      _block(
        kind: ReaderInkBlock.kindSticky,
        anchor: 99,
        chapterId: 'a-c2',
        createdAt: 1,
        chapterTitle: '', // 块没盖章节名、快照也没有 → 兜底「未知章节」。
        strokes: 1,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(home: _page(inkBlocks)));
    await tester.pumpAndSettle();

    // 「手写」chip 的计数把内嵌块算进手写维度。
    expect(find.text('手写 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notes-type-ink')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notes-ink-timeline')), findsOneWidget);
    // 行内徽标区分 kind：画布 / 便签。
    expect(find.text('画布'), findsOneWidget);
    expect(find.text('便签'), findsOneWidget);
    // 其余信息与墨迹批注行对齐：书名 + 笔迹笔数 + 章节名（含兜底）。
    expect(find.text('书 a'), findsNWidgets(2));
    expect(find.text('2 笔手写'), findsOneWidget);
    expect(find.text('1 笔手写'), findsOneWidget);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('未知章节'), findsOneWidget);
  });

  testWidgets('点画布块行跳回正文，锚点偏移随路由带入阅读页', (tester) async {
    // 本地导入书的根目录走 path_provider：mock 平台通道指到临时目录。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final support = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('notes_ink_block_test'),
    ))!;
    addTearDown(() async {
      // Windows 上句柄释放可能滞后，删不掉的临时目录留给系统清理，
      // 不让收尾失败掩盖测试结论。
      try {
        await support.delete(recursive: true);
      } catch (_) {}
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          // path_provider_platform_interface 的方法名是 …Directory（非 …Path）。
          if (call.method == 'getApplicationSupportDirectory') {
            return support.path;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    // 预置一本本地书（manifest + 章节文件），顺带预热 ImportedBookStore
    // 的根目录缓存：点行后的 _localChapter 只剩两次文件 IO，用 runAsync
    // 分轮喂给真实事件循环即可走完与批注行同一条跳转链。
    const bookId = 'local_1_beef';
    final prepared = await tester.runAsync(() async {
      final bookDir = Directory('${support.path}/imported_books/$bookId');
      await bookDir.create(recursive: true);
      await File('${bookDir.path}/book.json').writeAsString(
        jsonEncode({
          'id': bookId,
          'title': '本地书',
          'author': '',
          'format': 'txt',
          'addedAt': 1,
          'chapters': [
            {'id': 'c1', 'title': '第一章', 'file': 'chapter_00001.txt'},
          ],
        }),
      );
      await File(
        '${bookDir.path}/chapter_00001.txt',
      ).writeAsString('第一段正文，' * 60);
      return ImportedBookStore.instance.book(bookId);
    });
    expect(prepared, isNotNull);
    expect(prepared!.chapters.single.itemId, 'c1');

    final inkBlocks = _MemoryInkBlocks([
      _block(
        bookId: bookId,
        chapterId: 'c1',
        anchor: 42,
        kind: ReaderInkBlock.kindCanvas,
        createdAt: 2,
        bookTitle: '本地书',
        chapterTitle: '第一章',
      ),
    ]);
    await tester.pumpWidget(MaterialApp(home: _page(inkBlocks)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-type-ink')));
    await tester.pumpAndSettle();

    // 点画布行 → 与批注/划线同一套 _openChapter 跳转。
    await tester.tap(
      find.ancestor(of: find.text('画布'), matching: find.byType(InkWell)).first,
    );
    // 每轮 runAsync 让真实文件 IO 跑完，pump 推进微任务与路由帧。
    for (
      var round = 0;
      round < 6 && find.byType(ReaderPage).evaluate().isEmpty;
      round++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.byType(ReaderPage), findsOneWidget);
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.bookId, bookId);
    expect(reader.chapters.single.itemId, 'c1');
    expect(reader.localOnly, isTrue);
    // 关键断言：textOffset 用的是块锚点（章节文本偏移）。
    expect(reader.startTextOffset, 42);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('store.changes 通知触发重载，新手写块自动进时间线', (tester) async {
    final inkBlocks = _MemoryInkBlocks([
      _block(kind: ReaderInkBlock.kindCanvas, createdAt: 2),
    ]);
    await tester.pumpWidget(MaterialApp(home: _page(inkBlocks)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-type-ink')));
    await tester.pumpAndSettle();
    expect(find.text('画布'), findsOneWidget);
    expect(find.text('便签'), findsNothing);

    // 存储侧新增一条便签并通知 changes（与写库路径同一信号）。
    inkBlocks.blocks.add(
      _block(
        kind: ReaderInkBlock.kindSticky,
        anchor: 99,
        chapterId: 'a-c2',
        createdAt: 3,
        chapterTitle: '第二章',
        strokes: 1,
      ),
    );
    inkBlocks.changes.value++;
    await tester.pumpAndSettle();

    expect(find.text('画布'), findsOneWidget);
    expect(find.text('便签'), findsOneWidget);
    // 「手写」chip 计数同步到 2。
    expect(find.text('手写 2'), findsOneWidget);
  });
}
