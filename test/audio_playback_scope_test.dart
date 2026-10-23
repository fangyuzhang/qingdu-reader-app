import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/widgets/audio/listening_capsule.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    AudioRouteWatcher.instance.resetForTest();
    ReadingCapsuleHost.instance.resetForTest();
  });

  testWidgets(
    'the capsule stays fully usable when the reader toolbar collapses',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      app.navigator.currentState!.pop();
      await _flush(tester);
      // 非阅读页：保持完整胶囊。
      expect(find.byType(ListeningCapsule), findsOneWidget);

      ReadingCapsuleHost.instance.enterReader();
      await _flush(tester);
      // 阅读页工具栏收起：不再退化成底部小按钮，完整胶囊（播放/暂停、
      // 设置、关闭）必须仍然可用。
      expect(find.byType(ListeningCapsule), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mini-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mini-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mini-close')), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mini-collapsed')), findsNothing);
      expect(find.text('停止听书'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('audio-mini-toggle')));
      await _flush(tester);
      expect(app.players.single.isPlaying, isFalse);

      ReadingCapsuleHost.instance.setToolbarVisible(true);
      await _flush(tester);
      expect(find.byType(ListeningCapsule), findsOneWidget);
      expect(find.byKey(const ValueKey('audio-mini-collapsed')), findsNothing);

      // 置顶弹窗（护眼提醒）期间：胶囊整体隐藏，不遮挡弹窗。
      ReadingCapsuleHost.instance.setDialogOpen(true);
      await _flush(tester);
      expect(find.byType(ListeningCapsule), findsNothing);
      expect(find.byKey(const ValueKey('audio-mini-collapsed')), findsNothing);
    },
  );

  testWidgets(
    'popping the audio page preserves playback and reopening reuses it',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final player = app.players.single;
      player.emitPosition(const Duration(seconds: 37));
      await _flush(tester);

      app.navigator.currentState!.pop();
      await _flush(tester);
      expect(player.disposed, isFalse);
      expect(player.isPlaying, isTrue);
      expect(ListeningSession.instance.playing, isTrue);
      expect(find.byKey(const ValueKey('audio-mini-open')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('audio-mini-open')));
      await _flush(tester);
      expect(app.players, hasLength(1));
      expect(player.position, const Duration(seconds: 37));
      expect(find.byKey(const ValueKey('audio-mini-open')), findsNothing);

      app.navigator.currentState!.pop();
      await _flush(tester);
      await tester.tap(find.byKey(const ValueKey('audio-mini-close')));
      await _flush(tester);
      expect(player.disposed, isTrue);
      expect(ListeningSession.instance.bookId, isNull);
      expect(find.byKey(const ValueKey('audio-mini-open')), findsNothing);
    },
  );

  testWidgets('a sheet over the audio page does not reveal the capsule', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    expect(find.byKey(const ValueKey('audio-mini-open')), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-mini-open')), findsNothing);
  });

  testWidgets(
    'switching books waits for old native release before creating another',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final player = app.players.single;
      final release = Completer<void>();
      player.releaseGate = release;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      app.navigator.currentState!.pop();
      await _flush(tester);
      app.open(bookId: 'second');
      await _flush(tester);
      expect(app.players, hasLength(1));
      expect(player.disposed, isTrue);

      release.complete();
      await _flush(tester);
      expect(app.players, hasLength(2));
      expect(app.players.last.isPlaying, isTrue);
      expect(ListeningSession.instance.bookId, 'second');
    },
  );

  testWidgets(
    'paragraph requests seek the live work and route changes keep playing',
    (tester) async {
      final app = await _mount(tester);
      app.open();
      await _flush(tester);
      final previous = app.players.single;
      app.navigator.currentState!.pop();
      await _flush(tester);
      app.open(startIndex: 1, startPosition: const Duration(seconds: 42));
      await _flush(tester);
      expect(previous.disposed, isTrue);
      expect(app.players.last.position, const Duration(seconds: 42));
      expect(ListeningSession.instance.chapterId, 'book-2');

      unawaited(
        app.navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('正文阅读页')),
          ),
        ),
      );
      await _flush(tester);
      expect(app.players.last.isPlaying, isTrue);
      expect(find.byKey(const ValueKey('audio-mini-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audio-mini-toggle')));
      await _flush(tester);
      expect(app.players.last.isPlaying, isFalse);
    },
  );

  testWidgets('the floating capsule opens 听书设置 with 定时/语速/音色', (tester) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    expect(find.byType(ListeningCapsule), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('audio-mini-settings')));
    await _flush(tester);
    expect(find.text('听书设置'), findsOneWidget);
    expect(find.text('定时关闭'), findsOneWidget);
    expect(find.text('语速'), findsOneWidget);
    expect(find.text('音色'), findsOneWidget);
  });

  testWidgets('the capsule can be dragged somewhere else', (tester) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    final capsule = find.byType(ListeningCapsule);
    final before = tester.getTopLeft(capsule);
    await tester.drag(capsule, const Offset(-40, -220));
    await tester.pump();
    final after = tester.getTopLeft(capsule);
    expect(after.dy, lessThan(before.dy));
    expect(after.dx, lessThan(before.dx));
  });

  testWidgets(
    'another media request cancels narration still waiting for its source',
    (tester) async {
      final app = await _mount(tester);
      final source = Completer<AudioSource>();
      app.sourceGate = source;
      app.open();
      await _flush(tester);
      expect(app.players, isEmpty);
      final video = ControlledNativePlayer();
      await NativePlayer.beforePlay!(video);
      source.complete(
        AudioSource(itemId: 'book-1', url: 'https://example.invalid/audio.mp3'),
      );
      await _flush(tester);
      expect(app.players.single.isPlaying, isFalse);
      await video.dispose();
    },
  );
}

Future<_Harness> _mount(WidgetTester tester) async {
  final app = _Harness();
  await tester.binding.setSurfaceSize(const Size(430, 932));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: app.navigator,
      navigatorObservers: [AudioRouteWatcher.instance],
      builder: (_, child) =>
          AudioPlaybackScope(navigatorKey: app.navigator, child: child!),
      home: const Scaffold(body: Text('书架')),
    ),
  );
  return app;
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  // Route pop transitions advance per frame, not per elapsed time: a
  // single long pump does not finish them. Pump several more frames so
  // the popped page disposes and the scope rebuilds its mini bar.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

class _Harness {
  final navigator = GlobalKey<NavigatorState>();
  final store = ControlledReaderStore();
  final players = <ControlledNativePlayer>[];
  Completer<AudioSource>? sourceGate;

  void open({
    String bookId = 'book',
    int startIndex = 0,
    Duration? startPosition,
  }) {
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => AudioPage(
            bookId: bookId,
            title: bookId,
            chapters: [
              for (var i = 1; i <= 2; i++)
                Chapter(itemId: '$bookId-$i', title: '第 $i 章', volumeName: ''),
            ],
            startIndex: startIndex,
            startPosition: startPosition,
            historyStore: store,
            sourceLoader: (id, {toneId}) async => sourceGate != null
                ? await sourceGate!.future
                : AudioSource(
                    itemId: id,
                    url: 'https://example.invalid/audio.mp3',
                    toneId: toneId ?? '0',
                  ),
            voicesLoader: () async => const [],
            playerFactory: () {
              final player = ControlledNativePlayer();
              players.add(player);
              return player;
            },
          ),
        ),
      ),
    );
  }
}
