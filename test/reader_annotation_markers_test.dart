import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_marker_type_store.dart';

ReaderAnnotation _note({
  String markerLabel = '疑问',
  int markerColor = 0xFFC0392B,
  List<ReaderMarkerType> extra = const [],
}) => ReaderAnnotation(
  bookId: 'b',
  chapterId: 'c',
  start: 1,
  end: 4,
  text: '原文',
  thought: '想法',
  markerLabel: markerLabel,
  markerColorValue: markerColor,
  extraMarkers: extra,
);

void main() {
  test('多个角标按主标记在前、额外标记在后，并按文案去重', () {
    final note = _note(
      extra: const [
        ReaderMarkerType(label: '待查证', colorValue: 0xFF8A5B39),
        ReaderMarkerType(label: '疑问', colorValue: 0xFF000000),
      ],
    );
    expect(
      [for (final badge in note.markerBadges) badge.label],
      ['疑问', '待查证'],
    );
  });

  test('额外角标可以写进存储并原样读回', () {
    final note = _note(
      extra: const [
        ReaderMarkerType(label: '待查证', colorValue: 0xFF8A5B39),
      ],
    );
    final restored = ReaderAnnotation.fromMap(note.toMap());
    expect(restored, isNotNull);
    expect(
      [for (final badge in restored!.markerBadges) badge.label],
      ['疑问', '待查证'],
    );
    expect(restored.extraMarkers.single.colorValue, 0xFF8A5B39);
  });

  test('旧数据没有额外角标时照常回退到主标记', () {
    final legacy = _note().toMap()..remove('extraMarkers');
    final restored = ReaderAnnotation.fromMap(legacy);
    expect(restored!.extraMarkers, isEmpty);
    expect(restored.markerBadges.single.label, '疑问');
  });

  test('normalizeMarkerTypes 去空白、去重且保持顺序', () {
    final list = ReaderAnnotationStore.normalizeMarkerTypes(const [
      ReaderMarkerType(label: ' 感悟 ', colorValue: 1),
      ReaderMarkerType(label: '感悟', colorValue: 2),
      ReaderMarkerType(label: '', colorValue: 3),
      ReaderMarkerType(label: '反驳', colorValue: 4),
    ]);
    expect([for (final type in list) type.label], ['感悟', '反驳']);
    expect(list.first.colorValue, 1);
  });
}
