import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_mark_style.dart';
import 'package:fqapp/services/reader_marker_type_store.dart';

void main() {
  test('catalog 先放内置预设，再放自定义，按标签去重', () {
    final catalog = ReaderMarkerTypeStore.catalog([
      const ReaderMarkerType(label: '金句', colorValue: 0xFFE9B949),
      const ReaderMarkerType(label: '疑问', colorValue: 0xFF4F7CD1),
    ]);

    expect(catalog.first.label, '疑问');
    expect(catalog.length, readerMarkerPresets.length + 1);
    expect(catalog.any((type) => type.label == '金句'), isTrue);
    // 内置的「疑问」不会被自定义的同名项顶掉。
    expect(
      catalog.where((type) => type.label == '疑问').single.colorValue,
      0xFF4F7CD1,
    );
  });

  test('fromMap 拒绝空标签，颜色缺省回落到批注色', () {
    expect(ReaderMarkerType.fromMap({'label': '  '}), isNull);
    expect(ReaderMarkerType.fromMap('nope'), isNull);
    final type = ReaderMarkerType.fromMap({'label': ' 金句 '});
    expect(type!.label, '金句');
    expect(type.colorValue, readerDefaultAnnotationColor);
  });

  test('add 按最近使用排序、同名覆盖、不超过上限', () async {
    final store = ReaderMarkerTypeStore(hive: null)..seedForTest(const []);
    addTearDown(store.resetForTest);

    await store.add('甲', 0xFF111111);
    await store.add('乙', 0xFF222222);
    expect(store.types.first.label, '乙');

    await store.add('甲', 0xFF333333);
    expect(store.types.first.label, '甲');
    expect(store.types.first.colorValue, 0xFF333333);
    expect(store.types.where((type) => type.label == '甲').length, 1);

    for (var index = 0; index < ReaderMarkerTypeStore.maxEntries + 5; index++) {
      await store.add('类型$index', 0xFF000000 + index);
    }
    expect(store.types.length, ReaderMarkerTypeStore.maxEntries);
  });

  test('remove 只删同名类型', () async {
    final store = ReaderMarkerTypeStore(hive: null)
      ..seedForTest(const [
        ReaderMarkerType(label: '甲', colorValue: 0xFF111111),
        ReaderMarkerType(label: '乙', colorValue: 0xFF222222),
      ]);
    addTearDown(store.resetForTest);

    await store.remove('甲');
    expect(store.types.map((type) => type.label), ['乙']);
  });
}
