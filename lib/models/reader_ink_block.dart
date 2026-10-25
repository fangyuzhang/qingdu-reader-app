import 'ink_annotation.dart';

/// 【青茄·Active Canvas】正文内嵌手写块（画布 / 粘性便签）。
///
/// 感知口径（SCRIBE-NOTES-SPEC.md C1/C3/C4）：块绑定**章节文本偏移锚点**
/// （不是屏幕像素），排版层把它插在锚定行之后、后续文字下移重排；改字号
/// /换模式后块仍在锚定文字旁边。
///
/// 笔迹以**归一化坐标**（0..1，相对块盒子）存储——与整页墨迹
/// （[InkStroke]/[InkPoint]）同一管线：画布改高/换字号时内容随盒子等比
/// 伸缩，永不裁剪丢失（D5）。渲染/编辑前经 [strokesForBox] 展开成块本地
/// 像素坐标；保存时经 [normalized] 收回归一化。
class ReaderInkBlock {
  const ReaderInkBlock({
    required this.bookId,
    required this.chapterId,
    required this.anchor,
    required this.anchorContext,
    required this.kind,
    required this.height,
    required this.strokes,
    required this.createdAt,
    required this.updatedAt,
    this.bookTitle = '',
    this.chapterTitle = '',
  });

  /// kind：`canvas` = 正文内嵌画布（内容直接在场可见、占位可调）；
  /// `sticky` = 粘性便签（正文里只显示图标行，点开才是书写区）。
  static const kindCanvas = 'canvas';
  static const kindSticky = 'sticky';

  static const minCanvasHeight = 80.0;
  static const maxCanvasHeight = 640.0;
  static const defaultCanvasHeight = 160.0;

  final String bookId;
  final String chapterId;

  /// 章节展示文本偏移锚点（与划线/批注同一坐标空间）。
  final int anchor;

  /// 锚点处 32 字符上下文指纹（完整性自检，失配不漂移只保留位置）。
  final String anchorContext;

  final String kind;

  /// 画布框高度（逻辑像素）。便签忽略此字段（图标行定高）。
  final double height;

  /// 笔迹（归一化坐标 0..1，相对块盒子；与整页墨迹同一格式）。
  final List<InkStroke> strokes;

  final int createdAt;
  final int updatedAt;
  final String bookTitle;
  final String chapterTitle;

  bool get isSticky => kind == kindSticky;
  bool get hasContent => strokes.isNotEmpty;

  /// 归一化笔迹展开成 [width]×[height] 块本地像素坐标（渲染/编辑输入）。
  List<InkStroke> strokesForBox(double width, double height) {
    if (strokes.isEmpty || width <= 0 || height <= 0) return strokes;
    return [
      for (final stroke in strokes)
        InkStroke(
          points: [
            for (final p in stroke.points)
              InkPoint(x: p.x * width, y: p.y * height, pressure: p.pressure, t: p.t),
          ],
          baseWidth: stroke.baseWidth,
          colorValue: stroke.colorValue,
        ),
    ];
  }

  /// 块本地像素笔迹收回归一化（编辑保存 / 每笔落盘时调用）。
  static List<InkStroke> normalized(
    List<InkStroke> strokes, {
    required double boxWidth,
    required double boxHeight,
  }) {
    if (strokes.isEmpty || boxWidth <= 0 || boxHeight <= 0) return strokes;
    return [
      for (final stroke in strokes)
        InkStroke(
          points: [
            for (final p in stroke.points)
              InkPoint(
                x: (p.x / boxWidth).clamp(0.0, 1.0),
                y: (p.y / boxHeight).clamp(0.0, 1.0),
                pressure: p.pressure,
                t: p.t,
              ),
          ],
          baseWidth: stroke.baseWidth,
          colorValue: stroke.colorValue,
        ),
    ];
  }

  ReaderInkBlock withFields({double? height, List<InkStroke>? strokes}) {
    return ReaderInkBlock(
      bookId: bookId,
      chapterId: chapterId,
      anchor: anchor,
      anchorContext: anchorContext,
      kind: kind,
      height: (height ?? this.height).clamp(minCanvasHeight, maxCanvasHeight),
      strokes: strokes ?? this.strokes,
      createdAt: createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      bookTitle: bookTitle,
      chapterTitle: chapterTitle,
    );
  }

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'anchor': anchor,
    'ctx': anchorContext,
    'kind': kind,
    'h': height,
    'strokes': [for (final s in strokes) s.toMap()],
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'bookTitle': bookTitle,
    'chapterTitle': chapterTitle,
  };

  static ReaderInkBlock? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final anchor = raw['anchor'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        anchor is! int) {
      return null;
    }
    final kind = raw['kind'];
    final strokesRaw = raw['strokes'];
    return ReaderInkBlock(
      bookId: bookId,
      chapterId: chapterId,
      anchor: anchor,
      anchorContext: raw['ctx'] is String ? raw['ctx'] as String : '',
      kind: kind == kindSticky ? kindSticky : kindCanvas,
      height: (raw['h'] is num && (raw['h'] as num).isFinite)
          ? (raw['h'] as num)
                .toDouble()
                .clamp(minCanvasHeight, maxCanvasHeight)
          : defaultCanvasHeight,
      strokes: strokesRaw is List
          ? strokesRaw
                .map(InkStroke.fromMap)
                .whereType<InkStroke>()
                .toList(growable: false)
          : const [],
      createdAt: raw['createdAt'] is int ? raw['createdAt'] as int : 0,
      updatedAt: raw['updatedAt'] is int ? raw['updatedAt'] as int : 0,
      bookTitle: raw['bookTitle'] is String ? raw['bookTitle'] as String : '',
      chapterTitle: raw['chapterTitle'] is String
          ? raw['chapterTitle'] as String
          : '',
    );
  }
}
