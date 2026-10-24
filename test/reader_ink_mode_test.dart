import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';

import 'support/fakes.dart';

/// 第 6 组：阅读器固定布局批注模式（分页模式）的 UI 流程。
///
/// 存储在 widget 测试里不可用（hiveReady=false 时读空/写吞错——与其它
/// reader 测试同一策略）；锚点语义（页文本区间 + 指纹）由
/// ink_annotation_store_test 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
    });
  });

  testWidgets('分页模式可进批注：画布/工具栏挂载、书写、完成退出', (tester) async {
    await tester.pumpWidget(_app(_reader()));
    await tester.pumpAndSettle();

    // 打开底部工具栏（点正文中央切换菜单），「批注」入口可见。
    await tester.tap(find.textContaining('清晨的风').first);
    await tester.pumpAndSettle();
    expect(find.text('批注'), findsOneWidget);

    await tester.tap(find.text('批注'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ink-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('ink-canvas')), findsOneWidget);
    // 进入批注模式后阅读器自身的底部工具栏收起。
    expect(find.byKey(const ValueKey('reader-controls')), findsNothing);

    // stylus 直接书写（无需调试手指开关）。
    final canvas = tester.getCenter(find.byKey(const Key('ink-canvas')));
    final gesture = await tester.startGesture(
      canvas,
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveBy(const Offset(40, 30));
    await gesture.moveBy(const Offset(10, 40));
    await gesture.up();
    await tester.pump();

    // 撤销把这一笔去掉，工具栏状态正常切换。
    await tester.tap(find.byKey(const Key('ink-undo')));
    await tester.pump();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ink-toolbar')), findsNothing);
    expect(find.byKey(const Key('ink-canvas')), findsNothing);
  });
}

const _paragraphs = [
  '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。',
  '桌上放着一封尚未拆开的信，纸张微微泛黄，封口处印着一个熟悉的名字。他在窗前坐下，将信小心地展开。',
  '“如果有一天，你再次走到这条路的尽头，请记得停下来，听一听风的声音。”',
  '窗外传来鸟鸣，清亮又遥远。那些被时光掩藏的往事，仿佛随着这句话，重新有了颜色。',
];

ReaderPage _reader() => ReaderPage(
  bookId: 'ink-mode-test',
  title: '山川来信',
  chapters: [
    Chapter(itemId: 'ch-0', title: '第一章', volumeName: ''),
    Chapter(itemId: 'ch-1', title: '第二章', volumeName: ''),
  ],
  startIndex: 0,
  localOnly: true,
  readerStore: MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async => _paragraphs.join('\n'),
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.createTheme(Brightness.light),
  home: child,
);
