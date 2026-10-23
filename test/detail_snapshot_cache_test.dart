import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/detail_snapshot_cache.dart';
import 'package:fqapp/services/secure_key_provider.dart';

void main() {
  late Directory directory;
  late SecureKeyProvider keys;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-detail-snapshot-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Chapter chapter(String id, String title) => Chapter(
    itemId: id,
    title: title,
    volumeName: '第一卷',
    version: 'v1',
    wordCount: 1200,
    chapterType: 0,
  );

  test('详情快照重开盒子后仍然可用，章节元数据不丢', () async {
    final cache = DetailSnapshotCache(keyProvider: keys);
    await cache.load();
    cache.write(
      'book',
      detail: {'book_name': '测试书', 'abstract': '简介'},
      chapters: [chapter('c1', '第一章'), chapter('c2', '第二章')],
    );
    await cache.flush();

    final reopened = DetailSnapshotCache(keyProvider: keys);
    await reopened.load();
    final snapshot = reopened.read('book');
    expect(snapshot, isNotNull);
    expect(snapshot!.detail?['book_name'], '测试书');
    expect(snapshot.detail?['abstract'], '简介');
    expect(snapshot.chapters.map((c) => c.title), ['第一章', '第二章']);
    expect(snapshot.chapters.first.version, 'v1');
    expect(snapshot.chapters.first.wordCount, 1200);
  });

  test('过期快照仍然可读，但不再算新鲜', () async {
    final cache = DetailSnapshotCache(keyProvider: keys);
    await cache.load();
    cache.write(
      'book',
      detail: {'book_name': '测试书'},
      chapters: [chapter('c1', '第一章')],
    );
    expect(cache.isFresh('book'), isTrue);
    expect(
      cache.isFresh(
        'book',
        now: DateTime.now().add(DetailSnapshotCache.ttl * 2),
      ),
      isFalse,
    );
    // 过时也要能读：先渲染旧内容，再后台刷新。
    expect(cache.read('book'), isNotNull);
  });

  test('只保留最近的书，超出上限就淘汰最旧的', () async {
    final cache = DetailSnapshotCache(keyProvider: keys);
    await cache.load();
    for (var i = 0; i < DetailSnapshotCache.maxEntries + 3; i++) {
      cache.write(
        'book-$i',
        detail: {'book_name': '书$i'},
        chapters: [chapter('c$i', '第一章')],
      );
    }
    final kept = [
      for (var i = 0; i < DetailSnapshotCache.maxEntries + 3; i++)
        if (cache.read('book-$i') != null) i,
    ];
    expect(kept.length, DetailSnapshotCache.maxEntries);
    expect(kept, isNot(contains(0)));
  });
}
