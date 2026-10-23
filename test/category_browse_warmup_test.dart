import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/category_browse_cache.dart';
import 'package:fqapp/services/category_browse_warmup.dart';

void main() {
  setUp(() {
    CategoryBrowseCache.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  MediaItem item(String id, String title, {String kind = 'book'}) => MediaItem(
        id: id,
        title: title,
        cover: '',
        author: '作者',
        badge: '',
        ep: '',
        kind: kind,
      );

  const noDelay = Duration.zero;

  test('预热把分类首批写进缓存，同 id / 同名只留一本', () async {
    final calls = <String>[];
    await CategoryBrowseWarmup.warm(
      categories: const {'classic': '古典名著'},
      delay: noDelay,
      loader: (query, offset) async {
        calls.add('$query@$offset');
        return [
          item('a-$query', '红楼梦'),
          item('b-$query', '水浒传 $query'),
          item('c-$query', '红楼梦'),
          item('d-$query', '听书', kind: 'audio'),
          item('e-$query', '视频', kind: 'video'),
        ];
      },
    );

    expect(calls.length, 5, reason: '一个分类要并发搜全部 5 个关键词');
    final cached = CategoryBrowseCache.instance.read('classic', 0);
    expect(cached, isNotNull);
    expect(CategoryBrowseCache.instance.isFresh('classic', 0), isTrue);
    // 《红楼梦》五个关键词都返回：同名只留一本；《听书》同理留一本；
    // 《水浒传 + 关键词》书名带关键词，五本各不相同；video 被过滤。
    expect(cached!.length, 7);
    expect(cached.every((book) => book.kind != 'video'), isTrue);
    expect(cached.where((book) => book.title == '红楼梦').length, 1);
    expect(cached.where((book) => book.title.startsWith('水浒传')).length, 5);
  });

  test('只预热前 limit 个分类，且跳过仍在有效期内的缓存', () async {
    CategoryBrowseCache.instance.write('world', 0, [item('w1', '战争与和平')]);
    final calls = <String>[];
    await CategoryBrowseWarmup.warm(
      categories: const {
        'world': '世界文学',
        'classic': '古典名著',
        'history': '历史人文',
        'science': '科普百科',
      },
      limit: 2,
      delay: noDelay,
      loader: (query, offset) async {
        calls.add(query);
        return [item('$query-1', '$query 一')];
      },
    );

    // world 已新鲜：一次都不请求，但它占用一个名额。
    expect(calls.every((query) => !query.contains('世界')), isTrue);
    expect(CategoryBrowseCache.instance.read('classic', 0), isNotNull);
    expect(CategoryBrowseCache.instance.read('history', 0), isNull);
    expect(CategoryBrowseCache.instance.read('science', 0), isNull);
  });

  test('上游整批失败时不写空缓存，也不继续死缠网络', () async {
    var calls = 0;
    await CategoryBrowseWarmup.warm(
      categories: const {'classic': '古典名著', 'world': '世界文学'},
      delay: noDelay,
      loader: (query, offset) async {
        calls++;
        throw StateError('offline');
      },
    );

    expect(calls, 10, reason: '两个分类各 5 个关键词，失败后不再重试');
    expect(CategoryBrowseCache.instance.read('classic', 0), isNull);
    expect(CategoryBrowseCache.instance.read('world', 0), isNull);
  });

  test('页面销毁后立即停止，不再写缓存', () async {
    var alive = true;
    await CategoryBrowseWarmup.warm(
      categories: const {'classic': '古典名著'},
      delay: noDelay,
      shouldContinue: () => alive,
      loader: (query, offset) async {
        alive = false;
        return [item('$query-1', '$query 一')];
      },
    );

    expect(CategoryBrowseCache.instance.read('classic', 0), isNull);
  });

  test('未知分类退回用显示名当关键词', () {
    expect(CategoryBrowseWarmup.queriesFor('classic', '古典名著').first, '古典名著');
    expect(CategoryBrowseWarmup.queriesFor('mystery', '悬疑推理'), ['悬疑推理']);
  });
}
