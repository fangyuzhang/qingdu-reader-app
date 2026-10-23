import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reader_annotation_store.dart';
import 'package:fqapp/services/reader_mark_preferences.dart';
import 'package:fqapp/services/reader_mark_style.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReaderMarkPreferences.instance.resetForTest();
  });

  test('unknown or legacy mark styles fall back to solid', () {
    for (final style in ReaderMarkStyle.values) {
      expect(ReaderMarkStyle.fromStorage(style.storageValue), style);
    }
    expect(ReaderMarkStyle.fromStorage(null), ReaderMarkStyle.solid);
    expect(ReaderMarkStyle.fromStorage('legacy'), ReaderMarkStyle.solid);
  });

  test('all underline styles and colours round-trip through storage', () {
    for (final style in ReaderMarkStyle.values) {
      final color = readerMarkColorPresets[style.index].colorValue;
      final range = ReaderRangeUnderline(
        bookId: 'book',
        chapterId: 'chapter',
        start: 4,
        end: 9,
        text: 'source',
        createdAt: 123,
        style: style,
        colorValue: color,
      );
      final decoded = ReaderRangeUnderline.fromMap(range.toMap())!;
      expect(decoded.style, style);
      expect(decoded.colorValue, color);
      expect(decoded.createdAt, 123);
    }
  });

  test('the last selected underline style and colour are restored', () async {
    final preferences = ReaderMarkPreferences.instance;
    expect(preferences.choice.value.style, ReaderMarkStyle.solid);
    expect(preferences.choice.value.colorValue, readerDefaultUnderlineColor);

    await preferences.select(
      ReaderMarkStyle.wavy,
      readerMarkColorPresets[4].colorValue,
    );
    preferences.resetForTest();
    await preferences.load();

    expect(preferences.choice.value.style, ReaderMarkStyle.wavy);
    expect(
      preferences.choice.value.colorValue,
      readerMarkColorPresets[4].colorValue,
    );
  });

  test('old annotation records receive safe defaults for new fields', () {
    final restored = ReaderAnnotation.fromMap({
      'bookId': 'book',
      'chapterId': 'chapter',
      'start': 1,
      'end': 3,
      'text': 'source',
      'thought': 'thought',
      'createdAt': 456,
    })!;

    expect(restored.category, isEmpty);
    expect(restored.tags, isEmpty);
    expect(restored.markerType, isEmpty);
    expect(restored.displayMarkerLabel, '\u6279');
    expect(restored.markStyle, ReaderMarkStyle.solid);
    expect(restored.effectiveMarkerColorValue, readerDefaultAnnotationColor);
  });

  test('custom marker text, badge colour and all mark fields persist', () {
    final annotation = ReaderAnnotation(
      bookId: 'book',
      chapterId: 'chapter',
      start: 1,
      end: 3,
      text: 'source',
      thought: 'thought',
      createdAt: 456,
      category: 'custom-category',
      tags: const ['tag-a', 'tag-b'],
      markerType: AnnotationDraft.customMarkerType,
      markerLabel: '\u5f85\u67e5\u8bc1',
      markerColorValue: 0xFF4F7CD1,
      markStyle: ReaderMarkStyle.dashed,
      markColorValue: 0xFFE9B949,
    );

    final restored = ReaderAnnotation.fromMap(annotation.toMap())!;
    expect(restored.category, 'custom-category');
    expect(restored.tags, ['tag-a', 'tag-b']);
    expect(restored.markerType, AnnotationDraft.customMarkerType);
    expect(restored.markerLabel, '\u5f85\u67e5\u8bc1');
    expect(restored.markerColorValue, 0xFF4F7CD1);
    expect(restored.markStyle, ReaderMarkStyle.dashed);
    expect(restored.markColorValue, 0xFFE9B949);
  });

  test(
    'the combined action bar and style panel stay above the bottom safe area',
    () {
      const view = Size(400, 800);
      const safeArea = EdgeInsets.only(top: 24, bottom: 24);
      const avoidBottom = 60.0;
      const belowContentHeight = 118.0;

      final (position, _) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(200, 720),
        topAnchor: const Offset(200, 400),
        paragraphScoped: true,
        view: view,
        safeArea: safeArea,
        underlined: false,
        avoidBottom: avoidBottom,
        belowContentHeight: belowContentHeight,
      );

      final bottomLimit = view.height - safeArea.bottom - avoidBottom - 10;
      expect(
        position.dy + ReaderParagraphMenu.barHeight + belowContentHeight,
        lessThanOrEqualTo(bottomLimit + 0.001),
      );
    },
  );
}
