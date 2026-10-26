import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/notes_pdf_exporter.dart';
import 'package:fqapp/services/reader_annotation_store.dart';

/// 笔记 PDF 导出（规格 C9 v2）：图片页方案——中文渲染走 Flutter 长图
/// 管线（无需打包 CJK 字体），PDF 只承载 A4 切页位图。
///
/// 普通 test()（非 testWidgets）：Hive 真实 IO 在普通 zone 正常推进；
/// ui.PictureRecorder.toImage 已由 note_card_export_test 验证可行。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-pdf-');
    Hive.init(directory.path);
    ReaderAnnotationStore.hiveReady = true;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async => directory.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      await Hive.close();
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Windows 句柄偶发延迟释放；临时目录由系统清理。
      }
    });
  });

  ReaderAnnotation note({
    required String chapter,
    required String text,
    int createdAt = 0,
  }) => ReaderAnnotation(
    bookId: 'pdf-book',
    chapterId: chapter,
    start: 1,
    end: 5,
    text: text,
    thought: '$text 的想法。',
    type: ReaderAnnotation.kTypeAnnot,
    createdAt: createdAt,
    bookTitle: 'PDF 之书',
    chapterTitle: '第一章',
  );

  test('整本导出：PDF 生成、结构完整（%PDF 头 + %%EOF 尾 + 页对象）', () async {
    final store = ReaderAnnotationStore.instance;
    await store.add(note(chapter: 'c1', text: '第一段的金句。', createdAt: 1));
    await store.add(note(chapter: 'c2', text: '第二段的金句。', createdAt: 2));

    final pdfPath = await NotesPdfExporter.export(
      bookId: 'pdf-book',
      bookTitle: 'PDF 之书',
      scope: NotesPdfScope.book,
      documentTitle: 'PDF 之书 读书笔记',
    );

    final file = File(pdfPath);
    expect(file.existsSync(), isTrue);
    final bytes = await file.readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
    expect(String.fromCharCodes(bytes.sublist(bytes.length - 6)), contains('%%EOF'));
    expect(String.fromCharCodes(bytes), contains('/Type/Pages'));
  });

  test('章节范围：只含该章笔记也能产出', () async {
    final store = ReaderAnnotationStore.instance;
    await store.add(note(chapter: 'c1', text: '仅第一章有一条。', createdAt: 1));

    final pdfPath = await NotesPdfExporter.export(
      bookId: 'pdf-book',
      bookTitle: 'PDF 之书',
      scope: NotesPdfScope.chapter,
      chapterId: 'c1',
    );
    expect(File(pdfPath).existsSync(), isTrue);
  });

  test('空范围抛「该范围内没有笔记」', () async {
    await expectLater(
      NotesPdfExporter.export(
        bookId: 'empty-book',
        bookTitle: '空书',
        scope: NotesPdfScope.book,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '该范围内没有笔记',
        ),
      ),
    );
  });
}
