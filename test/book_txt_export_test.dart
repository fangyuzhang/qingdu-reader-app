import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/book_txt_export.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Chapter chapter(String id, String title) =>
      Chapter(itemId: id, title: title, volumeName: '');

  group('exportFileName', () {
    test('keeps the title and appends .txt', () {
      expect(exportFileName('番茄小说'), '番茄小说.txt');
    });

    test('folds path separators and other reserved characters', () {
      expect(exportFileName(r'a/b\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j.txt');
    });

    test('drops control characters and edge dots', () {
      expect(exportFileName('  ..名字\u0000\n.x  '), '名字.x.txt');
    });

    test('falls back for a whitespace-only title', () {
      expect(exportFileName('   '), 'book.txt');
    });

    test('caps a long stem without splitting a surrogate pair', () {
      expect(exportFileName('书' * 200), '${'书' * 80}.txt');
      expect(exportFileName('🎉' * 100), '${'🎉' * 80}.txt');
    });
  });

  group('PlatformTxtSink', () {
    const channel = MethodChannel('fqapp/downloads');

    test(
      'speaks the fqapp/downloads channel and reports the public path',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return <String, Object?>{
                'path': '/storage/emulated/0/Download/书.txt',
                'public': true,
              };
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final target = await const PlatformTxtSink().saveText(
          fileName: '书.txt',
          text: '正文',
        );

        expect(calls.single.method, 'saveText');
        expect(calls.single.arguments, {'fileName': '书.txt', 'text': '正文'});
        expect(target.path, '/storage/emulated/0/Download/书.txt');
        expect(target.isPublic, isTrue);
      },
    );

    test('never reports success without a path from the platform', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => <String, Object?>{},
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await expectLater(
        const PlatformTxtSink().saveText(fileName: 'a.txt', text: 'x'),
        throwsA(isA<ExportWriteException>()),
      );
    });
  });

  group('BookTxtExport', () {
    test('assembles the same shape the backend download serves', () async {
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [
          chapter('1', '第一章 开端'),
          chapter('2', '第二章 继续'),
        ],
        chapterLoader: (chapter) async =>
            chapter.itemId == '1' ? '第一段\n第二段' : '正文二',
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '测试书');

      expect(sink.calls.single.fileName, '测试书.txt');
      expect(sink.calls.single.text, '# 第一章 开端\n第一段\n第二段\n\n# 第二章 继续\n正文二\n\n');
      expect(export.value.running, isFalse);
      expect(export.value.completed, 2);
      expect(export.value.failed, 0);
      expect(export.value.target?.isPublic, isTrue);
      expect(export.value.message, contains('/sdcard/Download/测试书.txt'));
    });

    test('title-only catalogue pages are omitted from the file', () async {
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [
          chapter('1', '版权信息'),
          chapter('2', '书名'),
          chapter('3', '第一章'),
        ],
        chapterLoader: (chapter) async => switch (chapter.itemId) {
          '1' => '版权信息\n版权说明',
          '2' => '书名',
          '3' => '第一章\n正文',
          _ => '',
        },
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '测试书');

      expect(
        sink.calls.single.text,
        '# 版权信息\n版权信息\n版权说明\n\n# 第一章\n第一章\n正文\n\n',
      );
      expect(export.value.completed, 3);
      expect(export.value.skipped, 1);
      expect(export.value.message, contains('跳过 1 个无正文页'));
    });

    test(
      'structured cache exports readable text, not its JSON envelope',
      () async {
        final sink = _RecordingSink();
        final content = parseChapterContent('<h1>第一章</h1><p>第一段</p><p>第二段</p>');
        final export = BookTxtExport(
          directoryLoader: (bookId) async => [chapter('1', '第一章')],
          chapterLoader: (chapter) async => content.toCacheText(),
          sink: sink,
        );

        await export.start(bookId: 'book-1', title: '测试书');

        final text = sink.calls.single.text;
        expect(text, startsWith('# 第一章\n'));
        expect(text, contains('第一段'));
        expect(text, contains('第二段'));
        expect(text, isNot(contains('"blocks"')));
        expect(text, isNot(contains('legacyText')));
      },
    );
    test('one dead chapter keeps its heading and is reported', () async {
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [
          chapter('1', '第一章'),
          chapter('2', '第二章'),
        ],
        chapterLoader: (chapter) async {
          if (chapter.itemId == '2') throw StateError('章节取文失败');
          return '正文一';
        },
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '书');

      expect(sink.calls.single.text, '# 第一章\n正文一\n\n# 第二章\n\n');
      expect(export.value.completed, 2);
      expect(export.value.failed, 1);
      expect(export.value.message, contains('1 章取文失败'));
    });

    test('reports chapter progress while it runs', () async {
      final gate = Completer<void>();
      final seen = <String>[];
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [
          chapter('1', '一'),
          chapter('2', '二'),
        ],
        chapterLoader: (chapter) async {
          if (chapter.itemId == '1') await gate.future;
          return '正文';
        },
        sink: _RecordingSink(),
      );
      export.addListener(() {
        final state = export.value;
        if (state.running && state.total > 0) {
          seen.add('${state.completed}/${state.total}');
        }
      });

      final run = export.start(bookId: 'book-1', title: '书');
      await Future<void>.delayed(Duration.zero);
      expect(export.value.running, isTrue);
      gate.complete();
      await run;

      expect(seen, ['0/2', '1/2', '2/2']);
    });

    test('cancelling writes nothing and says so', () async {
      final gate = Completer<void>();
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [
          chapter('1', '一'),
          chapter('2', '二'),
        ],
        chapterLoader: (chapter) async {
          await gate.future;
          return '正文';
        },
        sink: sink,
      );

      final run = export.start(bookId: 'book-1', title: '书');
      await Future<void>.delayed(Duration.zero);
      expect(export.value.running, isTrue);
      export.cancel();
      gate.complete();
      await run;

      expect(sink.calls, isEmpty);
      expect(export.value.running, isFalse);
      expect(export.value.message, contains('已取消导出'));
    });

    test('a second start is ignored while one export runs', () async {
      final gate = Completer<void>();
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [chapter('1', '一')],
        chapterLoader: (chapter) async {
          await gate.future;
          return '正文';
        },
        sink: sink,
      );

      final run = export.start(bookId: 'book-1', title: '书');
      await Future<void>.delayed(Duration.zero);
      await export.start(bookId: 'book-2', title: '另一本');
      gate.complete();
      await run;

      expect(sink.calls.length, 1);
      expect(sink.calls.single.fileName, '书.txt');
    });

    test('a failed directory fetch stops before writing', () async {
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => throw StateError('offline'),
        chapterLoader: (chapter) async => '正文',
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '书');

      expect(sink.calls, isEmpty);
      expect(export.value.target, isNull);
      expect(export.value.message, contains('目录获取失败'));
    });

    test('an empty directory is reported instead of an empty file', () async {
      final sink = _RecordingSink();
      final export = BookTxtExport(
        directoryLoader: (bookId) async => const <Chapter>[],
        chapterLoader: (chapter) async => '正文',
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '书');

      expect(sink.calls, isEmpty);
      expect(export.value.message, contains('没有可导出的章节'));
    });

    test('a sink failure is reported and no target is claimed', () async {
      final sink = _RecordingSink()..error = const ExportWriteException('磁盘已满');
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [chapter('1', '一')],
        chapterLoader: (chapter) async => '正文',
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '书');

      expect(sink.calls, isEmpty);
      expect(export.value.running, isFalse);
      expect(export.value.target, isNull);
      expect(export.value.message, contains('写入 Downloads 失败'));
    });

    test('a private target is labelled as such', () async {
      final sink = _RecordingSink()
        ..overrideTarget = const ExportTarget(
          path:
              '/storage/emulated/0/Android/data/com.fqapp.fqapp/files/Download/书.txt',
          isPublic: false,
        );
      final export = BookTxtExport(
        directoryLoader: (bookId) async => [chapter('1', '一')],
        chapterLoader: (chapter) async => '正文',
        sink: sink,
      );

      await export.start(bookId: 'book-1', title: '书');

      expect(export.value.message, contains('应用私有目录'));
    });
  });
}

class _RecordingSink implements TxtSink {
  final List<({String fileName, String text})> calls = [];

  /// 平台回报的落点；缺省按写进公共「下载」目录回报。
  ExportTarget? overrideTarget;
  Object? error;

  @override
  Future<ExportTarget> saveText({
    required String fileName,
    required String text,
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    calls.add((fileName: fileName, text: text));
    return overrideTarget ??
        ExportTarget(path: '/sdcard/Download/$fileName', isPublic: true);
  }
}
