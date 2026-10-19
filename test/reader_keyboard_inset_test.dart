import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';

import 'support/fakes.dart';

/// 锁死「键盘弹出把正文顶得上下乱跳」的回归。
///
/// 键盘升起时框架会改两个值，两个都能改变阅读页的正文视口：
///   1. `viewInsets.bottom` → Scaffold 默认 resizeToAvoidBottomInset 会缩 body；
///   2. `padding` 从「安全区」变成「安全区减键盘」，手势条那 30px 被吃掉。
/// 视口一高一低，`ReaderLayoutSpec.viewport` 就变，整章重新测量分页 ——
/// 真机上表现为正文连同插图跳一下、随后卡几百毫秒。
/// 阅读页本身没有输入框，键盘只应该影响弹层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
  });

  /// 模拟输入法升起：inset 出现，同时框架把 padding 里的手势条高度减掉。
  void showKeyboard(WidgetTester tester) {
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
  }

  void hideKeyboard(WidgetTester tester) {
    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.padding = const FakeViewPadding(bottom: 90);
  }

  testWidgets('滚动模式下键盘升降不移动正文', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 90 物理像素 ÷ 3 倍屏 = 30 逻辑像素的手势条。
    hideKeyboard(tester);

    await tester.pumpWidget(_readerApp());
    await tester.pumpAndSettle();

    final paragraph = find.textContaining('这是 第一章 的正文');
    expect(paragraph, findsOneWidget);
    final before = tester.getTopLeft(paragraph);
    final viewport = find.byKey(const ValueKey('reader-page-surface'));
    final sizeBefore = tester.getSize(viewport);

    showKeyboard(tester);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(paragraph),
      before,
      reason: '键盘弹出后正文不应位移',
    );
    expect(
      tester.getSize(viewport),
      sizeBefore,
      reason: '正文视口不应随输入法变化（否则会触发全章重新分页）',
    );
    expect(tester.takeException(), isNull);

    // 键盘收起同样不应引起回弹。
    hideKeyboard(tester);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(paragraph), before);
    expect(tester.getSize(viewport), sizeBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页模式下键盘升降不改变当前页', (tester) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    hideKeyboard(tester);

    await tester.pumpWidget(_readerApp(loader: _longChapterLoader));
    await tester.pumpAndSettle();

    final firstPage = find.textContaining('第 1 段', findRichText: true);
    expect(firstPage, findsOneWidget);
    final before = tester.getTopLeft(firstPage);
    final viewport = find.byKey(const ValueKey('reader-page-surface'));
    final sizeBefore = tester.getSize(viewport);

    showKeyboard(tester);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(firstPage), before);
    expect(tester.getSize(viewport), sizeBefore);
    expect(tester.takeException(), isNull);
  });
}

Widget _readerApp({ChapterTextLoader? loader}) {
  return MaterialApp(
    home: ReaderPage(
      bookId: 'reader-inset-test',
      title: '测试书籍',
      chapters: _chapters,
      startIndex: 0,
      localOnly: true,
      chapterLoader: loader ?? _shortChapterLoader,
      readerStore: MemoryReaderStore(),
      chapterCache: MemoryChapterCache(),
    ),
  );
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: '正文'),
];

Future<String> _shortChapterLoader(Chapter chapter) async =>
    '${chapter.title}\n这是 ${chapter.title} 的正文。';

Future<String> _longChapterLoader(Chapter chapter) async {
  return List.generate(
    40,
    (index) => '第 ${index + 1} 段。这是一段用于验证翻页与键盘 inset 的测试正文。',
  ).join('\n\n');
}
