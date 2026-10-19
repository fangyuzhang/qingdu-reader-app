import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/reader/reader_note_block.dart';

/// 锁死「写想法」弹层的生命周期回归：
/// 曾经把 TextEditingController / FocusNode 建在 showAnnotationEditor 函数里，
/// 用 future.whenComplete 释放，而该 Future 在退场动画开始时就完成，
/// 导致 TextField 在退场期间重建时撞上已 dispose 的 FocusNode：
///   A FocusNode was used after being disposed.
/// 以及延迟 280ms 的 requestFocus 在面板关闭后才触发。
void main() {
  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAnnotationEditor(
                  context,
                  quote: '这是一段被标注的原文，用来验证弹层里的引用区域。',
                ),
                child: const Text('写想法'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('写想法'));
    await tester.pump();
  }

  testWidgets('首帧就抢焦点：面板与键盘同时升起，不是两段式', (tester) async {
    await pumpEditor(tester);
    // pumpEditor 已走完弹层首帧；post-frame 回调在此帧末尾请求焦点。
    await tester.pump();
    await tester.pump();

    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('reader-annot-input')),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      editable.focusNode.hasFocus,
      isTrue,
      reason: '面板首帧就应该拿到焦点，让键盘和面板同一次上滑动画里出来',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('聚焦后退场（键盘收起）不抛 FocusNode 已释放', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 700);

    await pumpEditor(tester);
    // 走完入场动画与 280ms 的延迟抢焦点。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('reader-annot-input'));
    expect(input, findsOneWidget);
    // 真机上用户已经点进输入框在打字：FocusNode 上挂着监听。
    await tester.tap(input);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(input, '写一半');
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);

    // 取消：退场动画期间 TextField 仍在树上重建，同时键盘开始收起。
    await tester.tap(find.byKey(const ValueKey('reader-annot-cancel')));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-annot-input')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('极短时间内关闭：挂起的抢焦点计时器被取消', (tester) async {
    await pumpEditor(tester);
    // 只推进 60ms（远小于 180ms 的补抢焦点重试），此时退场，计时器仍在等待。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byKey(const ValueKey('reader-annot-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('保存返回去空格后的想法', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAnnotationEditor(context, quote: '原文');
                },
                child: const Text('写想法'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('写想法'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('reader-annot-input')),
      '  这段写得好  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-annot-save')));
    await tester.pumpAndSettle();

    expect(result, '这段写得好');
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入法弹出（viewInsets）时面板不溢出', (tester) async {
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 780);

    await pumpEditor(tester);
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-annot-input')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('reader-annot-cancel')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号 + 窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showAnnotationEditor(context, quote: '很长的原文' * 20),
                  child: const Text('写想法'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('写想法'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // 弹层挂在独立路由上，但 MaterialApp 的主题会顺着 DefaultTextStyle /
  // bodyLarge 漏进来。深色主题下 onSurface 是浅色，浅色字落在白色输入框上
  // 等于隐形——所以输入框正文/提示的颜色必须显式钉死，与主题无关。
  for (final dark in <bool>[false, true]) {
    final label = dark ? 'ThemeData.dark()' : 'ThemeData.light()';
    testWidgets('$label 下输入文字与提示文字仍是可读深色', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showAnnotationEditor(
                    context,
                    quote: '这是一段被标注的原文，用来验证弹层里的引用区域。',
                  ),
                  child: const Text('写想法'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('写想法'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('reader-annot-input')),
      );

      final textColor = field.style?.color;
      expect(textColor, isNotNull, reason: '输入文字颜色必须显式指定，不能继承主题');
      expect(textColor!.a, 1.0, reason: '输入文字必须是不透明色');
      expect(
        textColor.computeLuminance(),
        lessThan(0.2),
        reason: '$label 下输入文字必须是深色，否则白底输入框上看不见',
      );

      final hintColor = field.decoration?.hintStyle?.color;
      final fillColor = field.decoration?.fillColor;
      expect(hintColor, isNotNull, reason: '提示文字颜色必须显式指定');
      expect(fillColor, isNotNull, reason: '输入框底色应保持浅色填充');
      expect(
        fillColor!.computeLuminance(),
        greaterThan(0.7),
        reason: '输入框底色应是浅色，深色字才有对比',
      );
      expect(
        (fillColor.computeLuminance() - hintColor!.computeLuminance()).abs(),
        greaterThan(0.3),
        reason: '$label 下提示文字与输入框底色亮度差过小，等于看不清',
      );

      expect(tester.takeException(), isNull);
    });
  }
}
