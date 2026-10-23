import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/note_timeline.dart';
import 'package:fqapp/services/reader_annotation_store.dart';

ReaderAnnotation note({
  required String bookId,
  required int createdAt,
  String category = '',
  List<String> tags = const [],
  String type = ReaderAnnotation.kTypeAnnot,
}) => ReaderAnnotation(
  bookId: bookId,
  chapterId: 'chapter-$bookId',
  start: createdAt.abs() % 100,
  end: createdAt.abs() % 100 + 1,
  text: 'source-$bookId-$createdAt',
  thought: 'thought-$bookId-$createdAt',
  type: type,
  createdAt: createdAt,
  bookTitle: 'book-$bookId',
  category: category,
  tags: tags,
);

void main() {
  DateTime local(int year, int month, int day, [int hour = 12]) =>
      DateTime(year, month, day, hour);

  test('book, time, category and tags are AND-ed; tags are OR-ed', () {
    final notes = [
      note(
        bookId: 'a',
        createdAt: local(2026, 10, 20).millisecondsSinceEpoch,
        category: 'growth',
        tags: ['character', 'question'],
      ),
      note(
        bookId: 'a',
        createdAt: local(2026, 10, 20).millisecondsSinceEpoch,
        category: 'growth',
        tags: ['structure'],
      ),
      note(
        bookId: 'b',
        createdAt: local(2026, 10, 20).millisecondsSinceEpoch,
        category: 'growth',
        tags: ['character'],
      ),
      note(
        bookId: 'a',
        createdAt: local(2026, 10, 20).millisecondsSinceEpoch,
        category: 'history',
        tags: ['character'],
      ),
    ];

    final result = filterNoteTimeline(
      notes,
      NoteTimelineFilters(
        bookId: 'a',
        category: 'growth',
        tags: const {'character', 'structure'},
        timePreset: NoteTimePreset.today,
      ),
      now: local(2026, 10, 20, 23),
    );

    expect(result, hasLength(2));
    expect(result.every((entry) => entry.bookId == 'a'), isTrue);
    expect(result.every((entry) => entry.category == 'growth'), isTrue);
    expect(
      result.every(
        (entry) => entry.tags.any(const {'character', 'structure'}.contains),
      ),
      isTrue,
    );
  });

  test('the uncategorised filter only keeps notes with a blank category', () {
    final notes = [
      note(bookId: 'a', createdAt: 1),
      note(bookId: 'b', createdAt: 2, category: 'history'),
    ];

    final result = filterNoteTimeline(
      notes,
      const NoteTimelineFilters(category: noteUncategorizedFilter),
    );

    expect(result.map((entry) => entry.bookId), ['a']);
  });

  test(
    'today, seven days and thirty days include whole local calendar days',
    () {
      final now = local(2026, 10, 20, 23);
      final notes = [
        note(
          bookId: 'today-start',
          createdAt: local(2026, 10, 20, 0).millisecondsSinceEpoch,
        ),
        note(
          bookId: 'today-end',
          createdAt: local(2026, 10, 20, 23).millisecondsSinceEpoch,
        ),
        note(
          bookId: 'seven-start',
          createdAt: local(2026, 10, 14, 0).millisecondsSinceEpoch,
        ),
        note(
          bookId: 'seven-before',
          createdAt: local(2026, 10, 13, 23).millisecondsSinceEpoch,
        ),
        note(
          bookId: 'thirty-start',
          createdAt: local(2026, 9, 21, 0).millisecondsSinceEpoch,
        ),
        note(
          bookId: 'thirty-before',
          createdAt: local(2026, 9, 20, 23).millisecondsSinceEpoch,
        ),
      ];

      Set<String> ids(NoteTimePreset preset) => filterNoteTimeline(
        notes,
        NoteTimelineFilters(timePreset: preset),
        now: now,
      ).map((entry) => entry.bookId).toSet();

      expect(ids(NoteTimePreset.today), {'today-start', 'today-end'});
      expect(
        ids(NoteTimePreset.sevenDays),
        containsAll(['today-start', 'today-end', 'seven-start']),
      );
      expect(ids(NoteTimePreset.sevenDays), isNot(contains('seven-before')));
      expect(ids(NoteTimePreset.thirtyDays), contains('thirty-start'));
      expect(ids(NoteTimePreset.thirtyDays), isNot(contains('thirty-before')));
    },
  );

  test('custom range and note type can be combined', () {
    final notes = [
      note(
        bookId: 'a',
        createdAt: local(2026, 10, 5).millisecondsSinceEpoch,
        type: ReaderAnnotation.kTypeExcerpt,
      ),
      note(
        bookId: 'b',
        createdAt: local(2026, 10, 15).millisecondsSinceEpoch,
        type: ReaderAnnotation.kTypeAnnot,
      ),
      note(bookId: 'c', createdAt: local(2026, 10, 20).millisecondsSinceEpoch),
    ];

    final result = filterNoteTimeline(
      notes,
      NoteTimelineFilters(
        timePreset: NoteTimePreset.custom,
        customRange: DateTimeRange(
          start: local(2026, 10, 1),
          end: local(2026, 10, 15),
        ),
      ),
      type: NoteTypeFilter.annot,
      now: local(2026, 10, 20),
    );

    expect(result.map((entry) => entry.bookId), ['b']);
  });

  test('timeline is newest first and unknown times are last', () {
    final result = filterNoteTimeline([
      note(bookId: 'unknown', createdAt: 0),
      note(bookId: 'old', createdAt: 100),
      note(bookId: 'new', createdAt: 300),
      note(bookId: 'middle', createdAt: 200),
    ], const NoteTimelineFilters());

    expect(result.map((entry) => entry.bookId), [
      'new',
      'middle',
      'old',
      'unknown',
    ]);
  });
}
