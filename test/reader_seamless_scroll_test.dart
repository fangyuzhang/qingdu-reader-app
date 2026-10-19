import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';

import 'support/fakes.dart';

/// 【青茄】上下滚动模式跨章无缝：不点任何按钮，往下滚就能直接滚进下一章，
/// 视口越过章节边界后进度记录静默切到下一章；章末不再有
/// 「上一章 / 下一章 / 本章评论」按钮。
Finder get _list => find.byKey(const ValueKey('reader-paragraph-list'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
  });

  Widget app() {
    return MaterialApp(
      home: ReaderPage(
        bookId: 'reader-seamless-test',
        title: '测试书籍',
        chapters: _chapters,
        startIndex: 0,
        localOnly: true,
        chapterLoader: _chapterLoader,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
      ),
    );
  }

  testWidgets('章末没有上一章/下一章/本章评论按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('上一章'), findsNothing);
    expect(find.text('下一章'), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-scroll-chapter-comments')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('不点按钮，往下滚就能滚进下一章', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('这是第二章的正文'), findsNothing);

    // 一屏一屏往下拖，直到第二章的段落出现在同一棵列表里。
    var reached = false;
    for (var i = 0; i < 40 && !reached; i++) {
      await tester.drag(_list, const Offset(0, -520));
      await tester.pump(const Duration(milliseconds: 60));
      reached = find.textContaining('这是第二章的正文').evaluate().isNotEmpty;
    }
    expect(reached, isTrue, reason: '滚动到章末应能直接看到下一章的段落');

    // 继续滚，越过章节边界（视口中心进入第二章）。
    for (var i = 0; i < 6; i++) {
      await tester.drag(_list, const Offset(0, -520));
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 进度保存有 500ms 防抖。
    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.takeException(), isNull);
  });

  testWidgets('越过边界后进度记录切到下一章', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = MemoryReaderStore();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'reader-seamless-test',
          title: '测试书籍',
          chapters: _chapters,
          startIndex: 0,
          localOnly: true,
          chapterLoader: _chapterLoader,
          readerStore: store,
          chapterCache: MemoryChapterCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 60; i++) {
      await tester.drag(_list, const Offset(0, -520));
      await tester.pump(const Duration(milliseconds: 60));
      if (store.entry?['chapterId'] == 'chapter-2') break;
    }
    await tester.pump(const Duration(milliseconds: 700));

    expect(
      store.entry?['chapterId'],
      'chapter-2',
      reason: '视口进入下一章后，进度应该静默切到下一章',
    );
    expect(tester.takeException(), isNull);
  });
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: '正文'),
  Chapter(itemId: 'chapter-3', title: '第三章', volumeName: '正文'),
];

Future<String> _chapterLoader(Chapter chapter) async {
  final body = List.generate(
    30,
    (index) => '第$index段：这是${chapter.title}的正文内容，用来验证跨章无缝滚动是否正常。',
  ).join('\n\n');
  return '${chapter.title}\n$body';
}
