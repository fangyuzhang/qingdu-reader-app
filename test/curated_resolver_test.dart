import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/curated_book.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/curated_resolver.dart';

/// 书单解析服务的测试：匹配规则、缓存命中、过期重查。
///
/// 全程注入假搜索，不触碰网络。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CuratedResolver.instance.resetForTest();
  });

  MediaItem item(
    String id,
    String title, {
    String author = '',
    String kind = 'book',
    String cover = '',
  }) => MediaItem(
    id: id,
    title: title,
    cover: cover,
    author: author,
    badge: '',
    ep: '',
    kind: kind,
  );

  CuratedBook book(
    String id,
    String title, {
    String author = '',
    String? keyword,
  }) => CuratedBook(
    id: id,
    title: title,
    author: author,
    category: 'classic',
    blurb: '',
    tags: const [],
    age: '12+',
    searchKeyword: keyword,
  );

  group('pickBest', () {
    test('书名号/空白/括号尾巴差异也能完全命中', () {
      final items = [
        item('1', '小王子（插图版）', author: '圣埃克苏佩里'),
        item('2', '《小王子》', author: '圣埃克苏佩里'),
      ];
      final best = CuratedResolver.pickBest(items, '《 小王子 （全译版） 》', '圣埃克苏佩里');
      expect(best, isNotNull);
      expect(best!.title, '小王子（插图版）');
    });

    test('视频/漫画/听书结果被剔除', () {
      final items = [
        item('v', '小王子', kind: 'video'),
        item('m', '小王子', kind: 'manga'),
        item('a', '小王子', kind: 'audio'),
        item('b', '小王子', author: '圣埃克苏佩里'),
      ];
      final best = CuratedResolver.pickBest(items, '小王子', '');
      expect(best!.id, 'b');
    });

    test('同名多条时作者匹配优先', () {
      final items = [
        item('1', '西游记', author: '佚名'),
        item('2', '西游记', author: '吴承恩'),
      ];
      expect(CuratedResolver.pickBest(items, '西游记', '吴承恩')!.id, '2');
      // 作者对不上时保持搜索排序
      expect(CuratedResolver.pickBest(items, '西游记', '鲁迅')!.id, '1');
    });

    test('包含匹配：书名带副标题也能选到', () {
      final items = [
        item('1', '时间简史：从大爆炸到黑洞', author: '史蒂芬·霍金'),
        item('2', '三体', author: '刘慈欣'),
      ];
      expect(CuratedResolver.pickBest(items, '时间简史', '')!.id, '1');
    });

    test('全都不匹配时返回 null（回退搜索页），不开不相干的书', () {
      final items = [
        item('v', '毫不相干', kind: 'video'),
        item('1', '完全不同的书'),
        item('2', '另一本'),
      ];
      // 【轻读】收紧后不再赌「第一条结果」：宁可让用户在搜索页挑，
      // 也不能点《小王子》打开《完全不同的书》。
      expect(CuratedResolver.pickBest(items, '小王子', ''), isNull);
      expect(CuratedResolver.pickBest([], '小王子', ''), isNull);
      expect(
        CuratedResolver.pickBest([item('v', '小王子', kind: 'video')], '小王子', ''),
        isNull,
      );
    });

    test('有声书：搜索只返回音频源时也能命中（不被文字书空列表吞掉）', () {
      final items = [item('hit-audio', '西游记', kind: 'audio')];
      final hit = CuratedResolver.pickBest(
        items,
        '西游记',
        '吴承恩',
        preferAudio: true,
      );
      expect(hit!.id, 'hit-audio');
      // 不 preferAudio 时维持原语义：音频源不算文字书 → null。
      expect(CuratedResolver.pickBest(items, '西游记', '吴承恩'), isNull);
    });

    test('id 为空的结果被剔除，不会解析出打不开的书', () {
      final items = [item('', '小王子'), item('ok', '小王子')];
      expect(CuratedResolver.pickBest(items, '小王子', '')!.id, 'ok');
      expect(CuratedResolver.pickBest([item('', '小王子')], '小王子', ''), isNull);
    });
  });

  group('resolve 缓存', () {
    test('第一次走搜索，第二次直接命中缓存', () async {
      var calls = 0;
      CuratedResolver.instance.search = (query) async {
        calls++;
        expect(query, '小王子');
        return [item('s1', '小王子', author: '圣埃克苏佩里', cover: 'c1')];
      };

      final target = book('b1', '小王子', author: '圣埃克苏佩里');
      final first = await CuratedResolver.instance.resolve(target);
      expect(first!.id, 's1');
      expect(first.kind, 'book');
      expect(CuratedResolver.instance.cached('b1')!.id, 's1');

      final second = await CuratedResolver.instance.resolve(target);
      expect(second!.id, 's1');
      expect(calls, 1);

      // 已落盘：换一个实例（模拟重启）也能从本地读回。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(CuratedResolver.prefsKey), contains('s1'));
    });

    test('超过 7 天视为过期，会重新搜索', () async {
      final stale = CuratedResolution(
        id: 'old',
        title: '小王子',
        author: '旧作者',
        cover: 'old-cover',
        kind: 'book',
        at: DateTime.now()
            .subtract(const Duration(days: 8))
            .millisecondsSinceEpoch,
      );
      SharedPreferences.setMockInitialValues({
        CuratedResolver.prefsKey: jsonEncode({'b1': stale.toJson()}),
      });
      CuratedResolver.instance.resetForTest();
      await CuratedResolver.instance.load();
      expect(CuratedResolver.instance.cached('b1')!.id, 'old');

      var calls = 0;
      CuratedResolver.instance.search = (query) async {
        calls++;
        return [item('new', '小王子', author: '圣埃克苏佩里')];
      };
      final resolved = await CuratedResolver.instance.resolve(
        book('b1', '小王子', author: '圣埃克苏佩里'),
      );
      expect(resolved!.id, 'new');
      expect(calls, 1);
      expect(CuratedResolver.instance.cached('b1')!.id, 'new');
    });

    test('搜索抛错时返回 null，不向上抛', () async {
      CuratedResolver.instance.search = (query) async {
        throw Exception('offline');
      };
      final resolved = await CuratedResolver.instance.resolve(
        book('b9', '小王子'),
      );
      expect(resolved, isNull);
      expect(CuratedResolver.instance.cached('b9'), isNull);
    });

    test('重启后能从本地缓存命中，不再发搜索', () async {
      var calls = 0;
      CuratedResolver.instance.search = (query) async {
        calls++;
        return [item('s1', '小王子', cover: 'c1')];
      };
      final target = book('b1', '小王子');
      await CuratedResolver.instance.resolve(target);
      expect(calls, 1);

      // 模拟杀进程重启：清空内存，但 SharedPreferences 里的数据还在。
      CuratedResolver.instance.resetForTest();
      await CuratedResolver.instance.load();
      expect(CuratedResolver.instance.cached('b1')!.cover, 'c1');

      final again = await CuratedResolver.instance.resolve(target);
      expect(again!.id, 's1');
      expect(calls, 1);
    });

    test('缓存 JSON 损坏时不崩，当作没有缓存重新搜索', () async {
      SharedPreferences.setMockInitialValues({
        CuratedResolver.prefsKey: '{"b1": 这不是合法 JSON',
      });
      CuratedResolver.instance.resetForTest();

      await CuratedResolver.instance.load();
      expect(CuratedResolver.instance.cached('b1'), isNull);

      CuratedResolver.instance.search = (query) async => [item('new', '小王子')];
      final resolved = await CuratedResolver.instance.resolve(
        book('b1', '小王子'),
      );
      expect(resolved!.id, 'new');
    });

    test('结构异常但 JSON 合法的缓存也不崩', () async {
      SharedPreferences.setMockInitialValues({
        CuratedResolver.prefsKey: jsonEncode({
          'b1': 'oops',
          'b2': {'id': 2, 'title': '水浒传', 'at': 0},
        }),
      });
      CuratedResolver.instance.resetForTest();

      await CuratedResolver.instance.load();
      expect(CuratedResolver.instance.cached('b1'), isNull);
      // 条目能读出来，但 at=0 会在 resolve 时被判过期并重查。
      expect(CuratedResolver.instance.cached('b2')!.id, '2');
    });

    test('不同书 id 各自缓存，封面/书源不串', () async {
      CuratedResolver.instance.search = (query) async => [
        item('up-$query', query, cover: 'https://c/$query.jpg'),
      ];
      await CuratedResolver.instance.resolve(book('b1', '西游记'));
      await CuratedResolver.instance.resolve(book('b2', '水浒传'));

      expect(CuratedResolver.instance.cached('b1')!.id, 'up-西游记');
      expect(CuratedResolver.instance.cached('b1')!.cover, 'https://c/西游记.jpg');
      expect(CuratedResolver.instance.cached('b2')!.id, 'up-水浒传');
    });

    test('解析出新条目时 changes 自增', () async {
      CuratedResolver.instance.search = (query) async => [item('s1', '小王子')];
      var ticks = 0;
      void listener() => ticks++;
      CuratedResolver.instance.changes.addListener(listener);
      addTearDown(
        () => CuratedResolver.instance.changes.removeListener(listener),
      );

      await CuratedResolver.instance.resolve(book('b1', '小王子'));
      expect(ticks, 1);
      // 缓存命中不重复通知
      await CuratedResolver.instance.resolve(book('b1', '小王子'));
      expect(ticks, 1);
    });
  });

  group('prefetch', () {
    test('只补缺失项，并发不超过上限，失败静默', () async {
      var active = 0;
      var peak = 0;
      var calls = 0;
      CuratedResolver.instance.search = (query) async {
        calls++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        if (query == '坏书') throw Exception('offline');
        return [item('up-$query', query)];
      };

      final books = [
        for (var i = 0; i < 8; i++) book('p$i', '书$i'),
        book('bad', '坏书'),
      ];

      await CuratedResolver.instance.prefetch(books, concurrency: 2);

      expect(calls, 9);
      expect(peak, lessThanOrEqualTo(2), reason: '同时最多 2 个搜索请求');
      expect(CuratedResolver.instance.cached('p7')!.id, 'up-书7');
      expect(CuratedResolver.instance.cached('bad'), isNull);

      // 第二轮只重试失败的那本，已解析的 8 本直接跳过。
      await CuratedResolver.instance.prefetch(books, concurrency: 2);
      expect(calls, 10);
    });

    test('并发参数小于 1 时按 1 处理，不会死循环', () async {
      var peak = 0;
      var active = 0;
      CuratedResolver.instance.search = (query) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        return [item('up-$query', query)];
      };
      await CuratedResolver.instance.prefetch([
        for (var i = 0; i < 3; i++) book('z$i', '书$i'),
      ], concurrency: 0);
      expect(peak, 1);
      expect(CuratedResolver.instance.cached('z2'), isNotNull);
    });
  });
}
