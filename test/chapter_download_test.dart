import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_download.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/readable_chapter_resolver.dart';

/// 不触磁盘的 [ChapterCache]：读永远 miss，写只记账。
class _FakeChapterCache implements ChapterCache {
  final reads = <String>[];
  final writes =
      <
        ({
          String bookId,
          String chapterId,
          String title,
          String text,
          bool pinned,
        })
      >[];
  int saveBookCalls = 0;

  @override
  int get chapterCapacity => 500;

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async {
    reads.add(chapterId);
    return null;
  }

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    writes.add((
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    ));
  }

  @override
  Future<void> saveBook(CachedBook book) async {
    saveBookCalls++;
  }

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async => {};

  @override
  Future<CachedBook?> cachedBook(String bookId) async => null;
}

CachedBook _book(int chapterCount) => CachedBook(
  id: 'book-1',
  title: '书',
  chapters: [
    for (var i = 1; i <= chapterCount; i++)
      Chapter(itemId: 'c$i', title: '第$i章', volumeName: ''),
  ],
);

void main() {
  test('双启：运行中再次 start 被忽略，只跑一批', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final loaderCalls = <String>[];
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(3),
      loader: (chapter) async {
        loaderCalls.add(chapter.itemId);
        if (chapter.itemId == 'c1') {
          // 第一章的 loader 进来 = 批次已在跑；用门挡住它，好让第二次
          // start 有机会在运行中发生。
          if (!entered.isCompleted) entered.complete();
          await gate.future;
        }
        return '正文${chapter.itemId}内容……';
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 3);
    await entered.future;
    expect(download.value.running, isTrue);

    // 第二次 start 在运行中：立即返回，不产生第二次 loader 调用，
    // 不重置进度、不开第二批。
    await download.start(startIndex: 0, count: 3);
    expect(loaderCalls, ['c1']);

    gate.complete();
    await first;
    expect(loaderCalls, ['c1', 'c2', 'c3']);
    expect(cache.writes, hasLength(3));
    expect(download.value.running, isFalse);
    expect(download.value.completed, 3);
    expect(download.value.total, 3);
    expect(download.value.message, isNotNull);
  });

  test('标题占位页会跳过，后续真实章节仍正常缓存', () async {
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(3),
      loader: (chapter) async => switch (chapter.itemId) {
        'c1' => '第1章\n正文一',
        'c2' => '第2章',
        'c3' => '第3章\n正文三',
        _ => '',
      },
    );
    addTearDown(download.dispose);

    await download.start(startIndex: 0, count: 3);

    expect(cache.writes.map((entry) => entry.chapterId), ['c1', 'c2', 'c3']);
    expect(download.value.completed, 3);
    expect(download.value.skipped, 1);
    expect(download.value.message, contains('跳过 1 个无正文页'));
  });

  test('标题占位页以结构化格式落盘，离线可解析到下一真实章节', () async {
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(2),
      loader: (chapter) async => switch (chapter.itemId) {
        'c1' => '第1章',
        'c2' => '第2章\n正文二',
        _ => '',
      },
    );
    addTearDown(download.dispose);

    await download.start(startIndex: 0, count: 2);

    final written = {
      for (final entry in cache.writes) entry.chapterId: entry.text,
    };
    final placeholder = ChapterContent.fromCacheText(written['c1']!);
    expect(placeholder.isTitleOnlyPlaceholder('第1章'), isTrue);

    final resolver = ReadableChapterResolver(
      chapters: _book(2).chapters,
      loadText: (chapter) async => written[chapter.itemId]!,
    );
    final resolved = await resolver.resolve(
      index: 0,
      initialText: written['c1'],
    );

    expect(resolved?.index, 1);
    expect(resolved?.chapter.itemId, 'c2');
    expect(resolved?.content.legacyText, contains('正文二'));
  });
  test('取消：门开后不再落盘，已保存数保持 0', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(2),
      loader: (chapter) async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
        return '正文${chapter.itemId}内容……';
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 2);
    await entered.future;
    expect(download.value.running, isTrue);

    download.cancel();
    expect(download.value.running, isFalse);
    expect(download.value.completed, 0);
    expect(download.value.message, contains('已停止'));

    // 在途的 loader 回包后，批次必须认出 job 已死：不写盘、不改计数、
    // 不覆盖取消的终态。
    gate.complete();
    await first;
    expect(cache.writes, isEmpty);
    expect(download.value.completed, 0);
    expect(download.value.running, isFalse);
    expect(download.value.message, contains('已停止'));
  });
}
