import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';

import 'support/fakes.dart';

void main() {
  group('U03 detail download', () {
    for (final scenario in <({int chapters, int? resume})>[
      (chapters: 1, resume: null),
      (chapters: 3, resume: null),
      (chapters: 3, resume: 2),
    ]) {
      testWidgets('${scenario.chapters} chapters, resume ${scenario.resume}: '
          'one tap caches the rest of the catalogue', (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final chapters = <Chapter>[
          for (var index = 0; index < scenario.chapters; index++)
            Chapter(
              itemId: 'chapter-$index',
              title: '第${index + 1}章',
              volumeName: '',
            ),
        ];
        final cache = MemoryChapterCache();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              item: MediaItem(
                id: 'book',
                title: '缓存范围测试',
                cover: '',
                author: '',
                badge: '',
                ep: '',
                kind: 'book',
              ),
              detailLoader: (_, {String tab = '小说'}) async => {},
              directoryLoader: (_, {String tab = '小说'}) async => [chapters],
              readerStore: MemoryReaderStore(
                entry: scenario.resume == null
                    ? null
                    : {
                        'id': 'book',
                        'kind': 'book',
                        'chapterId': 'chapter-${scenario.resume}',
                        'episode': scenario.resume,
                      },
              ),
              chapterCache: cache,
              chapterLoader: (chapter) async => ChapterContent.fromPlainText(
                '正文${chapter.itemId}',
                illustrationsChecked: true,
              ).toCacheText(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
        // The detail page downloads: no sheet, no range to choose.
        expect(find.byType(ChapterCacheSheet), findsNothing);
        final start = scenario.resume ?? 0;
        expect(await cache.cachedChapterIds('book'), {
          for (var index = start; index < scenario.chapters; index++)
            'chapter-$index',
        });
        expect(find.textContaining('缓存完成'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  // 【青茄重构·删除】U04（首页保活分页）随旧首页一起下线：新首页是打包书单，
  // 不再请求上游 feed，也就没有「隐藏后停止分页」这件事了。
}
