import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

import 'support/fakes.dart';

const _html = '<article><p>第一段话。</p><p>第二段话。</p><p>第三段话。</p></article>';

void main() {
  testWidgets('护眼提醒弹出时隐藏听书胶囊，收起后恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ReaderPage.eyeCareInterval = const Duration(milliseconds: 30);
    addTearDown(() => ReaderPage.eyeCareInterval = const Duration(minutes: 45));
    ReadingCapsuleHost.instance.resetForTest();
    addTearDown(ReadingCapsuleHost.instance.resetForTest);
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'book',
          title: '测试书',
          chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '正文')],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => parseChapterContent(_html).toCacheText(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-eye-care-dialog')),
      findsOneWidget,
    );
    // 弹窗期间胶囊整体隐藏：胶囊挂在 Navigator 之外，不隐藏就会盖住弹窗。
    expect(ReadingCapsuleHost.instance.dialogOpen, isTrue);

    await tester.tap(find.byKey(const ValueKey('reader-eye-care-later')));
    await tester.pumpAndSettle();
    expect(ReadingCapsuleHost.instance.dialogOpen, isFalse);
    expect(tester.takeException(), isNull);
  });
}
