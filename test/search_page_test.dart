import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/search_history_store.dart';
import 'package:fqapp/widgets/media_card.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'a category can be chosen before search and survives new queries',
    (tester) async {
      final requests = <(String, int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            searchLoader:
                (query, {required int tabType, required int offset}) async {
                  requests.add((query, tabType, offset));
                  return [
                    SearchTab(
                      title: '书籍',
                      items: [_item(query, '$query 结果')],
                      hasMore: false,
                    ),
                  ];
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      for (final query in ['修仙', '悬疑']) {
        await tester.enterText(find.byType(TextField), query);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(requests.last, (query, 3, 0));
        expect(find.text('$query 结果'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '小说'))
            .selected,
        isTrue,
      );
      expect(requests, hasLength(2));
    },
  );

  testWidgets(
    'rating-empty pages keep manual continuation at upstream cursors',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SearchPage(
            searchLoader:
                (query, {required int tabType, required int offset}) async {
                  offsets.add(offset);
                  return [
                    SearchTab(
                      title: '综合',
                      items: switch (offset) {
                        0 => [_item('low', '低分作品', score: 8.2)],
                        14 => [_item('unknown', '未评分作品')],
                        _ => [_item('high', '高分作品', score: 9.3)],
                      },
                      hasMore: offset < 27,
                      nextOffset: offset == 0 ? 14 : 27,
                    ),
                  ];
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search-minimum-score')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9 分及以上').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '评分');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(offsets, [0]);
      expect(find.byType(MediaCard), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.byType(MediaCard), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14, 27]);
      expect(find.text('高分作品'), findsOneWidget);
      expect(find.text('9.3分'), findsOneWidget);
      expect(find.text('没有更多了'), findsOneWidget);
      await tester.tap(find.byKey(const Key('search-minimum-score')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('评分不限').last);
      await tester.pumpAndSettle();
      expect(_gridCount(tester), 3);
      expect(offsets, [0, 14, 27]);
    },
  );

  testWidgets('cover-free list reuses results and persists on reopening', (
    tester,
  ) async {
    var requests = 0;
    Future<List<SearchTab>> loader(
      String query, {
      required int tabType,
      required int offset,
    }) async {
      requests++;
      return [
        SearchTab(
          title: '综合',
          items: [_item('novel', '列表作品', score: 9.1)],
          hasMore: false,
        ),
      ];
    }

    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-layout-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsNothing);
    expect(find.text('列表作品'), findsOneWidget);
    expect(find.text('小说 · 9.1分'), findsOneWidget);
    expect(requests, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool('search_list_view'),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(find.byType(MediaCard), findsNothing);
    expect(find.text('列表作品'), findsOneWidget);
    expect(find.byTooltip('切换为封面视图'), findsOneWidget);
  });

  testWidgets(
    'fixed categories request their own source and filter copied hits',
    (tester) async {
      final requests = <(String, int, int)>[];
      // 【轻读重构】删除 短剧/漫剧/漫画 后仅保留 综合/小说/听书；
      // mixed 仍含全部种类，用于验证三类被过滤、其余保留。
      final mixed = [
        for (final kind in ['book', 'video', 'manju', 'manga', 'audio'])
          _item('shared-id', '$kind 作品', kind: kind),
      ];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((query, tabType, offset));
          // Old bridge responses copy all general hits into the other tabs.
          return [
            for (final title in [
              '用户',
              '漫画',
              '全文',
              '综合',
              '社区',
              '短剧',
              '书籍',
              '听书',
              '买书',
            ])
              SearchTab(
                title: title,
                items: mixed,
                hasMore: false,
                nextOffset: 0,
              ),
          ];
        }),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .map((chip) => (chip.label as Text).data),
        ['综合', '小说', '听书'],
      );
      // 综合结果过滤掉 短剧/漫剧/漫画，仅剩 小说/听书
      expect(_visibleKinds(tester), ['book', 'audio']);
      expect(requests, [('测试', 1, 0)]);

      for (final category in [
        ('小说', 'book', 3),
        ('听书', 'audio', 2),
      ]) {
        await tester.tap(find.widgetWithText(ChoiceChip, category.$1));
        await tester.pumpAndSettle();
        expect(_visibleKinds(tester), [category.$2]);
        expect(requests.last, ('测试', category.$3, 0));
      }
      expect(requests.map((request) => request.$2), [1, 3, 2]);

      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(_visibleKinds(tester), ['book', 'audio']);
      expect(
        requests,
        hasLength(3),
        reason: 'Completed categories keep their cache',
      );
    },
  );

  testWidgets('an empty first page can continue at the actual cursor 14', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 14 ? [_item('book', '后续小说')] : [],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);
    expect(find.text('加载更多'), findsOneWidget);
    expect(find.text('没有更多了'), findsNothing);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续小说'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets(
    'a short category loads its own pages and preserves other cursors',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <(int, int)>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          // 【轻读重构】漫画分类已删除，改用听书（tabType 2）验证同类行为。
          if (tabType == 1) {
            return [
              SearchTab(
                title: '综合',
                items: offset == 0
                    ? [for (var i = 0; i < 30; i++) _item('b$i', '小说 $i')]
                    : [_item('b30', '末页小说')],
                hasMore: offset == 0,
                nextOffset: offset == 0 ? 14 : 0,
              ),
              SearchTab(
                title: '听书',
                items: [_item('old', '综合里的听书', kind: 'audio')],
                hasMore: false,
              ),
            ];
          }
          return [
            SearchTab(
              title: '听书',
              items: [_item('m$offset', '听书 $offset', kind: 'audio')],
              hasMore: offset == 0,
              nextOffset: offset == 0 ? 23 : 0,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(requests, [(1, 0)]);
      await tester.tap(find.widgetWithText(ChoiceChip, '听书'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (2, 0), (2, 23)]);
      expect(find.text('听书 23'), findsOneWidget);
      expect(find.text('综合里的听书'), findsNothing);

      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(requests.last, (1, 14));
      expect(find.text('末页小说'), findsOneWidget);
      // 综合结果过滤掉已删除的三类后仅剩小说
      expect(_visibleKinds(tester).toSet(), {'book'});
    },
  );

  testWidgets(
    'duplicate pages preserve their advancing cursor without looping',
    (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [
                _item('one', '第一本'),
                if (offset == 27) _item('two', '第二本'),
              ],
              hasMore: offset != 27,
              nextOffset: offset == 0 ? 14 : (offset == 14 ? 27 : 0),
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [
        0,
        14,
      ], reason: 'No automatic loop through duplicate pages');
      expect(find.text('加载更多'), findsOneWidget);
      expect(find.text('没有更多了'), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 14, 27]);
      expect(find.text('第一本'), findsOneWidget);
      expect(find.text('第二本'), findsOneWidget);
      expect(_gridCount(tester), 2);
    },
  );

  testWidgets(
    // 【轻读重构】漫剧/短剧分类已删除，改用 小说/听书 验证同一行为：
    // 分类内按 kind 过滤、翻页游标独立推进、跨分类结果互不串扰。
    'filtered-empty pages continue independently of other categories',
    (tester) async {
      final requests = <(int, int)>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          if (tabType == 1) {
            return [SearchTab(title: '综合', items: [], hasMore: false)];
          }
          if (tabType == 3) {
            return [
              SearchTab(
                title: '综合',
                items: [_item('unrelated', '其他栏目的内容', kind: 'manju')],
                hasMore: true,
                nextOffset: 99,
              ),
              SearchTab(
                title: '书籍',
                items: offset == 0
                    ? const []
                    : [_item('next', '后续小说', kind: 'book')],
                hasMore: true,
                nextOffset: offset == 0 ? 17 : 0,
              ),
            ];
          }
          return [
            SearchTab(
              title: '听书',
              items: offset == 0
                  ? const []
                  : [_item('audio-next', '后续讲书', kind: 'audio')],
              hasMore: true,
              nextOffset: offset == 0 ? 23 : 0,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (3, 0)]);
      expect(find.byType(MediaCard), findsNothing);
      expect(find.text('其他栏目的内容'), findsNothing);
      expect(find.text('加载更多'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests.last, (3, 17));
      expect(find.text('后续小说'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '听书'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (3, 0), (3, 17), (2, 0)]);
      expect(find.byType(MediaCard), findsNothing);
      expect(find.text('后续小说'), findsNothing);
      expect(find.text('加载更多'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests.last, (2, 23));
      expect(find.text('后续讲书'), findsOneWidget);
    },
  );

  for (final terminal in <({String label, bool? hasMore, int? next})>[
    (label: 'explicit exhaustion', hasMore: false, next: 28),
    (label: 'unchanged cursor', hasMore: true, next: 14),
    (label: 'backward cursor', hasMore: true, next: 7),
    (label: 'missing cursor', hasMore: true, next: null),
  ]) {
    testWidgets('pagination stops on ${terminal.label}', (tester) async {
      final offsets = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          offsets.add(offset);
          return [
            SearchTab(
              title: '综合',
              items: [_item('one', '唯一作品')],
              hasMore: offset == 0 ? true : terminal.hasMore,
              nextOffset: offset == 0 ? 14 : terminal.next,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(offsets, [0, 14]);
      expect(find.text('没有更多了'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
    });
  }

  testWidgets('a valid cursor can advance when has_more is omitted', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0 ? [] : [_item('one', '后续作品')],
            nextOffset: offset == 0 ? 14 : null,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('后续作品'), findsOneWidget);
  });

  testWidgets(
    'initial errors stay in their category and retry at offset zero',
    (tester) async {
      final requests = <(int, int)>[];
      var attempts = 0;
      await tester.pumpWidget(
        // 【轻读重构】漫画分类已删除，改用听书（tabType 2）验证：
        // 某分类的首屏错误不影响其他分类，重试只重试失败的那个分类。
        _app((query, {required int tabType, required int offset}) async {
          requests.add((tabType, offset));
          if (tabType == 1 && attempts++ == 0) throw Exception('首屏失败');
          return [
            SearchTab(
              title: tabType == 1 ? '综合' : '听书',
              items: [
                _item('success', '成功作品', kind: tabType == 1 ? 'book' : 'audio'),
              ],
              hasMore: false,
            ),
          ];
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('加载失败，点击重试'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '听书'));
      await tester.pumpAndSettle();
      expect(_visibleKinds(tester), ['audio']);
      expect(find.textContaining('首屏失败'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '综合'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (2, 0)]);
      await tester.tap(find.text('加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(requests, [(1, 0), (2, 0), (1, 0)]);
      expect(_visibleKinds(tester), ['book']);
    },
  );

  testWidgets('pagination failures retain results and retry the same cursor', (
    tester,
  ) async {
    final offsets = <int>[];
    var failed = false;
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        if (offset == 14 && !failed) {
          failed = true;
          throw Exception('分页失败');
        }
        return [
          SearchTab(
            title: '综合',
            items: [_item('$offset', '作品 $offset')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0, 14]);
    expect(find.text('作品 0'), findsOneWidget);
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14], reason: 'Scrolling must not retry a failed page');
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 14, 14]);
    expect(find.text('作品 14'), findsOneWidget);
    expect(_gridCount(tester), 2);
  });

  testWidgets(
    'out of order category responses keep results and loading isolated',
    (tester) async {
      // 【轻读重构】漫画分类已删除，改用小说（tabType 3）验证同一行为：
      // 两个分类的乱序响应互不污染，各自的加载态与结果保持隔离。
      final novel = Completer<List<SearchTab>>();
      final audio = Completer<List<SearchTab>>();
      final requests = <int>[];
      await tester.pumpWidget(
        _app((query, {required int tabType, required int offset}) async {
          requests.add(tabType);
          if (tabType == 3) return novel.future;
          if (tabType == 2) return audio.future;
          return [SearchTab(title: '综合', items: [], hasMore: false)];
        }),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '听书'));
      await tester.pump();
      novel.complete([
        SearchTab(
          title: '书籍',
          items: [_item('novel', '小说结果', kind: 'book')],
          hasMore: false,
        ),
      ]);
      await tester.pump();
      expect(find.text('小说结果'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      audio.complete([
        SearchTab(
          title: '听书',
          items: [_item('audio', '听书结果', kind: 'audio')],
          hasMore: false,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('听书结果'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pumpAndSettle();
      expect(find.text('小说结果'), findsOneWidget);
      expect(requests, [1, 3, 2]);
    },
  );

  for (final failLate in [false, true]) {
    testWidgets(
      'a new query ignores a late page ${failLate ? 'error' : 'result'}',
      (tester) async {
        final oldPage = Completer<List<SearchTab>>();
        final requests = <(String, int, int)>[];
        await tester.pumpWidget(
          _app((query, {required int tabType, required int offset}) async {
            requests.add((query, tabType, offset));
            if (query == '测试' && offset == 14) return oldPage.future;
            return [
              SearchTab(
                title: '综合',
                items: [_item(query, '$query 作品')],
                hasMore: query == '测试',
                nextOffset: query == '测试' ? 14 : 0,
              ),
            ];
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(requests, [('测试', 1, 0), ('测试', 1, 14)]);
        await tester.enterText(find.byType(TextField), '新关键词');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        if (failLate) {
          oldPage.completeError(Exception('过期请求失败'));
        } else {
          oldPage.complete([
            SearchTab(
              title: '综合',
              items: [_item('stale', '过期作品')],
              hasMore: true,
              nextOffset: 27,
            ),
          ]);
        }
        await tester.pumpAndSettle();
        expect(find.text('新关键词 作品'), findsOneWidget);
        expect(find.text('过期作品'), findsNothing);
        expect(find.text('加载失败，点击重试'), findsNothing);
        expect(requests.last, ('新关键词', 1, 0));
        expect(requests, hasLength(3));
      },
    );
  }

  testWidgets('clearing input and disposing ignore pending responses', (
    tester,
  ) async {
    final pending = <Completer<List<SearchTab>>>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) {
        final result = Completer<List<SearchTab>>();
        pending.add(result);
        return result.future;
      }),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    pending.first.complete([
      SearchTab(title: '综合', items: [_item('stale', '过期作品')]),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    // 【轻读重构】搜索分类删除 短剧/漫剧/漫画 后为 综合/小说/听书 三个。
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    await tester.tap(find.text('测试'));
    await tester.pump();
    expect(pending, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    pending.last.completeError(Exception('页面已关闭'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('history can search again, delete one entry and clear all', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': ['小王子', '测试小说'],
    });
    final queries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (query, {required int tabType, required int offset}) async {
                queries.add(query);
                return [];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('小王子'));
    await tester.pumpAndSettle();
    expect(queries, ['小王子']);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 小王子'));
    await tester.pumpAndSettle();
    expect(find.text('小王子'), findsNothing);
    expect(find.text('测试小说'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空').last);
    await tester.pumpAndSettle();
    expect(find.text('暂无搜索历史'), findsOneWidget);
    expect(await SearchHistoryStore.instance.load(), isEmpty);
  });

  testWidgets('late initial history cannot replace a newly searched keyword', (
    tester,
  ) async {
    final history = _DelayedHistory();
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          initialQuery: '新搜索',
          historyStore: history,
          searchLoader:
              (query, {required int tabType, required int offset}) async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    history.initial.complete(['旧搜索']);
    await tester.pump();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('新搜索'), findsOneWidget);
    expect(find.text('旧搜索'), findsNothing);
  });

  testWidgets('loads and deduplicates the next search page near the bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final offsets = <int>[];
    await tester.pumpWidget(
      _app((query, {required int tabType, required int offset}) async {
        offsets.add(offset);
        return [
          SearchTab(
            title: '综合',
            items: offset == 0
                ? [for (var i = 1; i <= 30; i++) _item('$i', '第$i本')]
                : [_item('30', '重复条目'), _item('31', '第31本')],
            hasMore: offset == 0,
            nextOffset: offset == 0 ? 14 : 0,
          ),
        ];
      }),
    );
    await tester.pumpAndSettle();
    expect(offsets, [0]);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(offsets, [0, 14]);
    expect(_gridCount(tester), 31);
    expect(find.text('第31本'), findsOneWidget);
    expect(find.text('重复条目'), findsNothing);
  });
}

Widget _app(SearchPageLoader loader) => MaterialApp(
  home: SearchPage(
    initialQuery: '测试',
    searchLoader: loader,
    historyStore: _DelayedHistory()..initial.complete([]),
  ),
);

List<String> _visibleKinds(WidgetTester tester) => tester
    .widgetList<MediaCard>(find.byType(MediaCard))
    .map((card) => card.item.kind)
    .toList();

int _gridCount(WidgetTester tester) {
  final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
  return (grid.delegate as SliverChildBuilderDelegate).childCount!;
}

MediaItem _item(
  String id,
  String title, {
  String kind = 'book',
  double? score,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
  score: score,
);

class _DelayedHistory implements SearchHistoryRepository {
  final initial = Completer<List<String>>();
  List<String> items = [];
  @override
  Future<List<String>> load() => initial.future;
  @override
  Future<List<String>> add(String query) async =>
      items = mergeSearchHistory(items, query);
  @override
  Future<List<String>> remove(String query) async =>
      items = items.where((value) => value != query).toList();
  @override
  Future<void> clear() async => items = [];
}
