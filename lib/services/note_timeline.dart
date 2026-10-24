import 'package:flutter/material.dart';

import 'reader_annotation_store.dart';

/// Sentinel category used by the notes filter for records without a category.
const String noteUncategorizedFilter = '__uncategorized__';

enum NoteTimePreset { all, today, sevenDays, thirtyDays, custom }

/// marks = 划线记录（ReaderUnderlineStore 的数据，不在注解列表里）：
/// 选中时时间线由笔记页直接渲染划线记录，[filterNoteTimeline] 对注解
/// 返回空列表。
enum NoteTypeFilter { all, annot, excerpt, marks }

/// Canonical identity of one note's marker/badge, used by the notes filter.
///
/// The badge text is what the reader actually sees, and custom marker types
/// are free-text labels (`markerType == 'custom'`), so the label — not the
/// internal type id — is the stable grouping key.
String noteMarkerKey(ReaderAnnotation note) => note.displayMarkerLabel.trim();

/// 一条笔记挂了多个批注类型角标时，任一命中即算匹配。
bool noteHasMarker(ReaderAnnotation note, String key) =>
    note.markerBadges.any((badge) => badge.key == key.trim());

/// The four independent dimensions of the notes filter.
///
/// Values in [tags] are OR-ed with each other; different dimensions are
/// AND-ed. This makes one selected tag behave like an exact tag filter while
/// selecting several tags asks for notes carrying any of them.
@immutable
class NoteTimelineFilters {
  const NoteTimelineFilters({
    this.bookId,
    this.category,
    this.tags = const {},
    this.timePreset = NoteTimePreset.all,
    this.customRange,
    this.markerKeys = const {},
  });

  final String? bookId;
  final String? category;
  final Set<String> tags;
  final NoteTimePreset timePreset;
  final DateTimeRange? customRange;

  /// Marker/badge identities, see [noteMarkerKey]. Multiple selected types
  /// are OR-ed; an empty set means "任何类型".
  final Set<String> markerKeys;

  /// Copy with selected dimensions replaced; `null` keeps the current value.
  /// Clearing a dimension goes through [without] so no sentinel is needed.
  NoteTimelineFilters copyWith({
    String? bookId,
    String? category,
    Set<String>? tags,
    NoteTimePreset? timePreset,
    DateTimeRange? customRange,
    Set<String>? markerKeys,
  }) => NoteTimelineFilters(
    bookId: bookId ?? this.bookId,
    category: category ?? this.category,
    tags: tags ?? this.tags,
    timePreset: timePreset ?? this.timePreset,
    customRange: customRange ?? this.customRange,
    markerKeys: markerKeys ?? this.markerKeys,
  );

  /// Drops the named dimensions, keeping the rest.
  NoteTimelineFilters without({
    bool bookId = false,
    bool category = false,
    bool tags = false,
    bool time = false,
    bool marker = false,
  }) => NoteTimelineFilters(
    bookId: bookId ? null : this.bookId,
    category: category ? null : this.category,
    tags: tags ? const {} : this.tags,
    timePreset: time ? NoteTimePreset.all : timePreset,
    customRange: time ? null : customRange,
    markerKeys: marker ? const {} : markerKeys,
  );

  bool get isActive =>
      bookId != null ||
      category != null ||
      tags.isNotEmpty ||
      timePreset != NoteTimePreset.all ||
      markerKeys.isNotEmpty;

  int get activeDimensions =>
      (bookId == null ? 0 : 1) +
      (category == null ? 0 : 1) +
      (tags.isEmpty ? 0 : 1) +
      (timePreset == NoteTimePreset.all ? 0 : 1) +
      (markerKeys.isEmpty ? 0 : 1);

  DateTimeRange? resolveRange(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (timePreset) {
      NoteTimePreset.all => null,
      NoteTimePreset.today => DateTimeRange(start: today, end: today),
      NoteTimePreset.sevenDays => DateTimeRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      ),
      NoteTimePreset.thirtyDays => DateTimeRange(
        start: today.subtract(const Duration(days: 29)),
        end: today,
      ),
      NoteTimePreset.custom => customRange,
    };
  }
}

/// Filters and orders the complete set of local notes for the timeline.
///
/// Sorting happens here rather than relying on store iteration order so a
/// filtered timeline is deterministic in both production and tests.
List<ReaderAnnotation> filterNoteTimeline(
  Iterable<ReaderAnnotation> notes,
  NoteTimelineFilters filters, {
  NoteTypeFilter type = NoteTypeFilter.all,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  final range = filters.resolveRange(current);
  final start = range == null
      ? null
      : DateTime(range.start.year, range.start.month, range.start.day);
  final endExclusive = range == null
      ? null
      : DateTime(
          range.end.year,
          range.end.month,
          range.end.day,
        ).add(const Duration(days: 1));

  if (type == NoteTypeFilter.marks) return const [];
  final visible = notes
      .where((note) {
        if (type == NoteTypeFilter.annot && !note.isAnnot) return false;
        if (type == NoteTypeFilter.excerpt && note.isAnnot) return false;
        if (filters.bookId != null && note.bookId != filters.bookId) {
          return false;
        }
        if (filters.category != null) {
          final matches = filters.category == noteUncategorizedFilter
              ? note.category.trim().isEmpty
              : note.category == filters.category;
          if (!matches) return false;
        }
        if (filters.tags.isNotEmpty && !note.tags.any(filters.tags.contains)) {
          return false;
        }
        if (filters.markerKeys.isNotEmpty &&
            !filters.markerKeys.any((key) => noteHasMarker(note, key))) {
          return false;
        }
        if (start != null && endExclusive != null) {
          if (note.createdAt <= 0) return false;
          final created = DateTime.fromMillisecondsSinceEpoch(note.createdAt);
          if (created.isBefore(start) || !created.isBefore(endExclusive)) {
            return false;
          }
        }
        return true;
      })
      .toList(growable: false);

  final sorted = visible.toList(growable: true)
    ..sort((a, b) {
      if (a.createdAt <= 0 && b.createdAt > 0) return 1;
      if (b.createdAt <= 0 && a.createdAt > 0) return -1;
      return b.createdAt.compareTo(a.createdAt);
    });
  return List.unmodifiable(sorted);
}
