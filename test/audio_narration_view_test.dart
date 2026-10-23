import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(8), child: child),
  ),
);

void main() {
  const track = SubtitleTrack([
    SubtitleCue(startMs: 0, text: '第一章开头的一句。'),
    SubtitleCue(startMs: 4000, text: '这是正在念的第二句。'),
    SubtitleCue(startMs: 9000, text: '后面还有第三句。'),
  ]);

  testWidgets('整章文字逐句铺开，当前句跟着进度高亮', (tester) async {
    final position = ValueNotifier(const Duration(milliseconds: 5200));
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _host(
        AudioNarrationBody(
          track: track,
          excerpt: '章节摘要不该出现',
          position: position,
        ),
      ),
    );
    expect(find.text('第一章开头的一句。'), findsOneWidget);
    expect(find.text('后面还有第三句。'), findsOneWidget);
    expect(find.text('章节摘要不该出现'), findsNothing);
    var current = tester.widget<Text>(
      find.byKey(const Key('audio_narration_current')),
    );
    expect(current.data, '这是正在念的第二句。');

    position.value = const Duration(milliseconds: 9500);
    await tester.pump();
    current = tester.widget<Text>(
      find.byKey(const Key('audio_narration_current')),
    );
    expect(current.data, '后面还有第三句。');
  });

  testWidgets('没有字幕轨时退回章节摘要', (tester) async {
    final position = ValueNotifier(const Duration(seconds: 3));
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _host(
        AudioNarrationBody(
          excerpt: '章节摘要',
          track: SubtitleTrack.empty,
          position: position,
        ),
      ),
    );
    expect(find.text('章节摘要'), findsOneWidget);
  });

  testWidgets('双击正文触发进入阅读页', (tester) async {
    var opened = 0;
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _host(
        AudioNarrationBody(
          track: track,
          excerpt: '',
          position: position,
          onOpenReader: () => opened++,
        ),
      ),
    );
    await tester.tap(find.text('这是正在念的第二句。'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(opened, 0, reason: '单击不进入正文');
    await tester.tap(find.text('这是正在念的第二句。'));
    await tester.tap(find.text('这是正在念的第二句。'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(opened, 1);
  });

  testWidgets('长按某一句弹出「从本句听」并回调该句起点', (tester) async {
    Duration? at;
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _host(
        AudioNarrationBody(
          track: track,
          excerpt: '',
          position: position,
          onListenFrom: (value) => at = value,
        ),
      ),
    );
    await tester.longPress(find.text('后面还有第三句。'));
    await tester.pumpAndSettle();
    expect(find.text('从本句听'), findsOneWidget);
    await tester.tap(find.text('从本句听'));
    await tester.pumpAndSettle();
    expect(at, const Duration(milliseconds: 9000));
  });

  testWidgets('顶部头部固定显示封面与当前章节', (tester) async {
    await tester.pumpWidget(
      _host(
        AudioNowPlayingHeader(
          bookTitle: '城南旧事',
          chapterTitle: '冬阳 童年 骆驼队',
          subtitle: '第 1 / 16 章',
        ),
      ),
    );
    expect(find.text('冬阳 童年 骆驼队'), findsOneWidget);
    expect(find.text('城南旧事 · 第 1 / 16 章'), findsOneWidget);
  });
}
