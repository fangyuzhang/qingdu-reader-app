/// 导入与书架共用的书名 / 作者清洗。
///
/// 历史原因这段逻辑曾在 `imported_book_store` 与 `bookshelf_card` 各存一份，
/// 两处逐行相同；集中到这里后两边只保留调用。
///
/// 从原始书名与作者中智能拆分出干净的书名和作者名。
(String, String) splitTitleAndAuthor(String rawTitle, [String rawAuthor = '']) {
  var title = rawTitle.trim();
  var author = rawAuthor.trim();

  if (author.isEmpty || author == '未知作者') {
    final authorMatch = RegExp(
      r'[（(\[【]?\s*作者\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
    ).firstMatch(title);
    if (authorMatch != null) {
      author = authorMatch.group(1)?.trim() ?? '';
      title = title.replaceRange(authorMatch.start, authorMatch.end, '').trim();
    } else {
      final byMatch = RegExp(
        r'[（(\[【]?\s*by\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
        caseSensitive: false,
      ).firstMatch(title);
      if (byMatch != null) {
        author = byMatch.group(1)?.trim() ?? '';
        title = title.replaceRange(byMatch.start, byMatch.end, '').trim();
      }
    }
  }

  title = title
      .replaceAll(
        RegExp(
          r'[（(\[【]\s*(?:精校版?|校对版?|全本|全集|完结|完本|精修版?|无错版?|未删节|未删减|手打|更新|排版|精编)[^）)\]】]*[）)\]】]',
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  title = title.replaceAll(RegExp(r'^[_\-—\s,，:：]+|[_\-—\s,，:：]+$'), '').trim();
  author = author
      .replaceAll(RegExp(r'^(?:作者|by)[:：\s]*', caseSensitive: false), '')
      .trim();

  if (title.isEmpty) title = rawTitle.trim();
  return (title, author);
}
