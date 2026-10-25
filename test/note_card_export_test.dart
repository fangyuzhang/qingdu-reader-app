import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/note_card_exporter.dart';
import 'package:fqapp/services/reader_annotation_store.dart';

/// 长图导出：宿主无 Android 插件（MissingPluginException）时诚实降级到
/// 应用文档目录并回报 public=false；文案层据此区分「系统下载/应用目录」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出通道不可用时降级私有目录且 public=false', () async {
    final dir = await Directory.systemTemp.createTemp('fqapp-export-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fqapp/downloads');
    // path_provider → 临时目录；downloads 通道不 mock → MissingPlugin。
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => dir.path);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(channel, null);
    });

    final saved = await NoteCardExporter.export(
      notes: [
        ReaderAnnotation(
          bookId: 'b',
          chapterId: 'c',
          start: 0,
          end: 4,
          text: '山川湖海各有归处。',
          thought: '读到这里停了一下。',
          createdAt: 1,
        ),
      ],
    );

    expect(saved.public, isFalse, reason: '无插件宿主必须诚实降级');
    expect(saved.path, contains('qingqie/exports'));
    expect(await File(saved.path).exists(), isTrue);
    expect(await File(saved.path).length(), greaterThan(100));
    await dir.delete(recursive: true);
  });
}
