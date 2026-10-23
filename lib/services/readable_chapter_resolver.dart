import '../models/media_item.dart';
import 'chapter_text_formatter.dart';

/// Raised when a chapter request succeeds but contains no payload at all.
///
/// This is intentionally distinct from a title-only front-matter page. The
/// former can be a transient source/decryption failure and must stay visible;
/// the latter is a valid upstream response whose body is only the chapter
/// title and can be skipped.
class EmptyChapterBodyException implements Exception {
  const EmptyChapterBodyException([this.message = '正文为空']);

  final String message;

  @override
  String toString() => message;
}

/// A catalogue entry resolved to its actual readable body.
class ResolvedChapter {
  const ResolvedChapter({
    required this.index,
    required this.chapter,
    required this.text,
    required this.content,
  });

  final int index;
  final Chapter chapter;

  /// Cache/plain-text representation returned by the loader.
  final String text;

  final ChapterContent content;
}

/// Resolves title-only catalogue entries to a real neighbouring chapter.
///
/// Upstream frequently exposes book-title pages, volume dividers, copyright
/// pages and recommendation letters as ordinary catalogue items. A book-title
/// page whose payload is only its title is not readable; the next item usually
/// contains the opening chapter. This resolver centralizes that interpretation
/// so the reader, system TTS, offline download and export cannot drift apart.
///
/// Rules kept deliberately narrow:
/// * A valid short page with any body text is retained.
/// * An image-only page is retained (it is non-empty after the title is removed).
/// * An entirely empty response throws [EmptyChapterBodyException] and is not
///   mistaken for a skippable placeholder.
/// * Loader/network exceptions propagate unchanged.
class ReadableChapterResolver {
  ReadableChapterResolver({
    required this.chapters,
    required this.loadText,
    this.maxCandidates = 8,
  }) : assert(maxCandidates > 0);

  final List<Chapter> chapters;
  final Future<String> Function(Chapter chapter) loadText;

  /// Maximum number of catalogue entries inspected by one [resolve] call.
  /// This bounds malformed catalogues that repeat title-only pages.
  final int maxCandidates;

  /// Resolves [index] in [direction] (1 forward, -1 backward).
  ///
  /// [initialText] lets a caller reuse a body it has already loaded for
  /// [index]. [onLoaded] receives every additional catalogue entry fetched by
  /// this call, allowing the reader to preserve its fetched/cache metadata.
  Future<ResolvedChapter?> resolve({
    required int index,
    int direction = 1,
    String? initialText,
    void Function(int index, String text)? onLoaded,
  }) async {
    if (index < 0 || index >= chapters.length) return null;
    final step = direction < 0 ? -1 : 1;
    var candidateIndex = index;
    var inspected = 0;
    while (candidateIndex >= 0 &&
        candidateIndex < chapters.length &&
        inspected < maxCandidates) {
      final chapter = chapters[candidateIndex];
      final text = candidateIndex == index && initialText != null
          ? initialText
          : await loadText(chapter);
      if (candidateIndex != index || initialText == null) {
        onLoaded?.call(candidateIndex, text);
      }
      final content = _parse(text);
      if (content.isEmpty) throw const EmptyChapterBodyException();
      if (content.hasReadableBody(chapter.title)) {
        return ResolvedChapter(
          index: candidateIndex,
          chapter: chapter,
          text: text,
          content: content,
        );
      }
      candidateIndex += step;
      inspected++;
    }
    return null;
  }

  /// Resolves one catalogue position without scanning across placeholders.
  ///
  /// Batched consumers call this per entry so every real chapter is still
  /// visited exactly once. Null means this particular item is title-only.
  Future<ResolvedChapter?> resolveSingle(int index) => ReadableChapterResolver(
    chapters: chapters,
    loadText: loadText,
    maxCandidates: 1,
  ).resolve(index: index);

  /// Parses a cached or plain-text payload exactly as the reader does.
  ChapterContent parse(String text) => _parse(text);

  static ChapterContent _parse(String text) {
    try {
      return ChapterContent.fromCacheText(text);
    } on FormatException {
      // A corrupt structured cache must not be downgraded to a valid empty
      // response. The reader has a refresh path for its own caches, but batch
      // callers need to treat this as a real failure.
      rethrow;
    }
  }
}
