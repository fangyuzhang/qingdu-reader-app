import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/reader_ink_block.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/annotation/embedded_ink_block_view.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';

import 'support/fakes.dart';

/// 【青茄·Active Canvas】阅读器集成：画布/便签/备注入口与草稿状态机
/// （规格 C1/C2/C4/C6 的验收路径）。存储注入内存版，全程无真实 IO。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget app(MemoryInkBlockStore inkStore) => MaterialApp(
    home: ReaderPage(
      bookId: 'ink-book',
      title: '画布之书',
      chapters: [
        Chapter(
          itemId: 'chapter-1',
          title: '第一章',
          volumeName: '',
          version: '1',
        ),
      ],
      startIndex: 0,
      readerStore: MemoryReaderStore(),
      chapterCache: MemoryChapterCache(),
      chapterLoader: (chapter) async => List.generate(
        30,
        (i) => '第$i 段。山川湖海各有归处，读者随手写下一句话，正文会为它让出位置。',
      ).join('\n'),
      readerDevice: _Device(),
      inkBlockStore: inkStore,
    ),
  );

  /// 选区菜单 8 项超窄屏宽 → 内容条可横向滚动；把目标按钮拖进可视区。
  Future<void> revealMenuAction(WidgetTester tester, Key key) async {
    final screen = tester.getSize(find.byType(MaterialApp)).width;
    final barScrollable = find
        .descendant(
          of: find.byType(ReaderParagraphMenu),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var round = 0; round < 5; round++) {
      final center = tester.getCenter(find.byKey(key));
      if (center.dx < screen - 44) return;
      await tester.drag(barScrollable, const Offset(-200, 0));
      await settleFrames(tester);
    }
    fail('菜单按钮始终没有滚进可视区: $key');
  }

  Future<void> openSelectionMenu(WidgetTester tester) async {
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    expect(surface, findsOneWidget);
    final rect = tester.getRect(surface);
    final position = Offset(rect.left + rect.width * 0.5, rect.top + 220);
    final gesture = await tester.startGesture(position);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await settleFrames(tester);
  }

  testWidgets('选区菜单出现画布/便签/备注，点画布生成草稿并确认落库', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inkStore = MemoryInkBlockStore();
    await tester.pumpWidget(app(inkStore));
    await settleFrames(tester);

    await openSelectionMenu(tester);
    expect(find.byKey(const ValueKey('reader-action-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-sticky')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-action-note')), findsOneWidget);

    await revealMenuAction(tester, const ValueKey('reader-action-canvas'));
    await tester.tap(find.byKey(const ValueKey('reader-action-canvas')));
    await settleFrames(tester);

    // 草稿画布出现：带取消/确认按钮。
    expect(find.byKey(const ValueKey('ink-block-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('ink-block-confirm')), findsOneWidget);

    // 取消：草稿消失（不落库）。
    await tester.tap(find.byKey(const ValueKey('ink-block-cancel')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('ink-block-confirm')), findsNothing);
    expect(inkStore.blocks, isEmpty);

    // 再开一次草稿并确认：落库、重排、画布保留（无确认按钮）。
    await openSelectionMenu(tester);
    await revealMenuAction(tester, const ValueKey('reader-action-canvas'));
    await tester.tap(find.byKey(const ValueKey('reader-action-canvas')));
    await settleFrames(tester);
    await tester.tap(find.byKey(const ValueKey('ink-block-confirm')));
    await settleFrames(tester);
    expect(inkStore.blocks, hasLength(1));
    expect(inkStore.blocks.values.single.kind, ReaderInkBlock.kindCanvas);
    expect(find.byKey(const ValueKey('ink-block-confirm')), findsNothing);
  });

  testWidgets('画布选中态垃圾桶需二次确认；确认后画布与占位一起消失', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inkStore = MemoryInkBlockStore();
    await tester.pumpWidget(app(inkStore));
    await settleFrames(tester);

    // 先落一块已确认画布。
    await openSelectionMenu(tester);
    await revealMenuAction(tester, const ValueKey('reader-action-canvas'));
    await tester.tap(find.byKey(const ValueKey('reader-action-canvas')));
    await settleFrames(tester);
    await tester.tap(find.byKey(const ValueKey('ink-block-confirm')));
    await settleFrames(tester);
    expect(inkStore.blocks, hasLength(1));

    // 轻点画布 → 选中态出现垃圾桶。
    await tester.tap(find.byType(EmbeddedInkCanvas).first);
    await settleFrames(tester);
    final trash = find.byKey(const ValueKey('ink-block-trash'));
    expect(trash, findsOneWidget);
    await tester.tap(trash);
    await settleFrames(tester);
    // 二次确认弹层 → 删除。
    await tester.tap(
      find.byKey(const ValueKey('reader-ink-block-delete-confirm')),
    );
    await settleFrames(tester);
    expect(inkStore.blocks, isEmpty);
  });

  testWidgets('便签工具：点按正文放置折叠图标，点图标开书写面板并自动保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inkStore = MemoryInkBlockStore();
    await tester.pumpWidget(app(inkStore));
    await settleFrames(tester);

    // 打开底部面板 → 便签工具。
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    final rect = tester.getRect(surface);
    await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height * 0.5));
    await settleFrames(tester);
    final stickyTool = find.byKey(const ValueKey('reader-sticky-tool'));
    expect(stickyTool, findsOneWidget);
    await tester.tap(stickyTool);
    await settleFrames(tester);

    // 放置模式：轻点正文某行 → 便签图标出现。
    final afterRect = tester.getRect(surface);
    await tester.tapAt(Offset(afterRect.center.dx, afterRect.top + 260));
    await settleFrames(tester);
    expect(inkStore.blocks, hasLength(1));
    expect(inkStore.blocks.values.single.kind, ReaderInkBlock.kindSticky);
    final iconRow = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith('reader-ink-icon-'),
    );
    expect(iconRow, findsOneWidget);

    // 点便签图标 → 书写面板。
    await tester.tap(iconRow.first);
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('ink-block-sheet-done')), findsOneWidget);

    // 写一笔 → 自动落盘（内存 store 即时可见）。从画布中心起笔。
    final canvasCenter = tester.getCenter(
      find.descendant(
        of: find.byType(EmbeddedInkCanvas),
        matching: find.byType(CustomPaint),
      ).first,
    );
    final gesture = await tester.startGesture(canvasCenter.translate(-30, -20));
    for (var i = 1; i <= 12; i++) {
      await gesture.moveBy(const Offset(10, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 900));
    final withInk = inkStore.blocks.values.single;
    expect(withInk.strokes, isNotEmpty);

    // 完成 → 面板收起，图标仍在。
    await tester.tap(find.byKey(const ValueKey('ink-block-sheet-done')));
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('ink-block-sheet-done')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
              'reader-ink-icon-',
            ),
      ),
      findsOneWidget,
    );
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
