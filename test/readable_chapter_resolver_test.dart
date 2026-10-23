import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/readable_chapter_resolver.dart';

void main() {
  Chapter chapter(String id, String title, {int? wordCount}) =>
      Chapter(itemId: id, title: title, volumeName: '', wordCount: wordCount);

  test(
    'skips consecutive title-only pages without dropping real front matter',
    () async {
      final chapters = [
        chapter('copyright', '版权信息', wordCount: 98),
        chapter('book-title', '老人与海', wordCount: 4),
        chapter('volume', '第一部', wordCount: 3),
        chapter('opening', '1', wordCount: 3189),
      ];
      final loaded = <String>[];
      final resolver = ReadableChapterResolver(
        chapters: chapters,
        loadText: (entry) async {
          loaded.add(entry.itemId);
          return switch (entry.itemId) {
            'book-title' => '老人与海',
            'volume' => '第一部',
            'opening' => '1\n老人独自在湾流里打鱼。',
            _ => '版权信息\n版权说明',
          };
        },
      );

      final resolved = await resolver.resolve(index: 0);

      expect(resolved, isNotNull);
      expect(resolved!.index, 0);
      expect(resolved.content.hasReadableBody('版权信息'), isTrue);
      expect(loaded, ['copyright']);

      final opening = await resolver.resolve(index: 1);
      expect(opening, isNotNull);
      expect(opening!.index, 3);
      expect(opening.text, contains('湾流'));
      expect(loaded, ['copyright', 'book-title', 'volume', 'opening']);
    },
  );

  test('an actually empty response is an error, not a placeholder', () async {
    final resolver = ReadableChapterResolver(
      chapters: [chapter('empty', '第一章'), chapter('body', '第二章')],
      loadText: (entry) async => entry.itemId == 'empty' ? '' : '第二章\n正文',
    );

    await expectLater(
      resolver.resolve(index: 0),
      throwsA(isA<EmptyChapterBodyException>()),
    );
  });

  test('image-only pages remain readable', () async {
    final resolver = ReadableChapterResolver(
      chapters: [chapter('cover', '彩插')],
      loadText: (_) async => parseChapterContent(
        '<h1>彩插</h1><img src="https://images.test/cover.webp"/>',
      ).toCacheText(),
    );

    final resolved = await resolver.resolve(index: 0);

    expect(resolved, isNotNull);
    expect(resolved!.content.hasImages, isTrue);
    expect(resolved.content.hasReadableBody('彩插'), isTrue);
  });

  test('loader failures propagate instead of being skipped', () async {
    final resolver = ReadableChapterResolver(
      chapters: [chapter('placeholder', '书名'), chapter('body', '第一章')],
      loadText: (entry) async {
        if (entry.itemId == 'body') throw StateError('network down');
        return '书名';
      },
    );

    await expectLater(resolver.resolve(index: 0), throwsA(isA<StateError>()));
  });

  test('backward resolution and candidate bounds are enforced', () async {
    final chapters = [
      chapter('body', '第一章'),
      chapter('p1', '书名'),
      chapter('p2', '书名'),
    ];
    final resolver = ReadableChapterResolver(
      chapters: chapters,
      loadText: (entry) async =>
          entry.itemId == 'body' ? '第一章\n正文' : entry.title,
      maxCandidates: 2,
    );

    final tooShort = await resolver.resolve(index: 2, direction: -1);
    expect(tooShort, isNull);

    final broadEnough = ReadableChapterResolver(
      chapters: chapters,
      loadText: resolver.loadText,
      maxCandidates: 3,
    );
    final resolved = await broadEnough.resolve(index: 2, direction: -1);
    expect(resolved?.chapter.itemId, 'body');
  });
}
