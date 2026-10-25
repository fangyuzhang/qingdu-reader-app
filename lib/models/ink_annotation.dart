import 'package:flutter/foundation.dart';

/// 手写墨迹批注的领域模型（第 3 组）。
///
/// 与文本型批注（ReaderAnnotation）共存但解耦：文本批注锚定「选区」，
/// 墨迹锚定「页面快照 + 文本区间」。存储在 InkAnnotationStore（加密 Hive
/// 盒 reader_ink_annotations_v1），两种格式（PDF 固定版式 / EPUB·TXT
/// 流式排版快照）共用同一套模型。
///
/// 坐标约定：所有墨迹点都是 0~1 的归一化坐标，基准是保存时的批注页面
/// （[InkAnnotation.pageWidth] × [pageHeight]）。相对锚点包围盒归一化
/// 会在锚点重算时整体漂移，故锚点包围盒 [anchorBox] 单独存，墨迹点
/// 相对整页存——重投影时两层各自换算（AnchorProjector）。
@immutable
class InkPoint {
  const InkPoint({
    required this.x,
    required this.y,
    this.pressure = 0.5,
    this.t = 0,
    this.tilt = 0,
  });

  /// 0~1，相对批注页宽。
  final double x;

  /// 0~1，相对批注页高。
  final double y;

  /// 原始压感 0~1（手指恒 1.0，见 stylus_probe_page.dart 实测结论）。
  final double pressure;

  /// 归一化倾斜 0~1（0 = 笔垂直屏幕，1 = 笔放平；手指恒 0）。
  /// 【青茄·阶段三兼容方案】MatePad 11 + M-Pencil 3（HarmonyOS 2-4
  /// Android 兼容层）上 stylus 事件带 tilt 弧度；侧锋放平时加粗笔迹
  /// （铅笔侧锋感）。旧存档无此字段 → 0，行为不变。
  final double tilt;

  /// 相对笔迹起始点的毫秒时间戳（会话内相对时间，避免存墙钟）。
  final int t;

  Map<String, dynamic> toMap() => {
    'x': x,
    'y': y,
    'p': pressure,
    't': t,
    // 0（垂直/手指）不写：旧存档体积不变，只在真侧锋时多一个字段。
    if (tilt > 0.001) 'tl': tilt,
  };

  static InkPoint? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    final p = raw['p'];
    final t = raw['t'];
    final tl = raw['tl'];
    return InkPoint(
      x: x.toDouble(),
      y: y.toDouble(),
      pressure: p is num && p.isFinite ? p.toDouble().clamp(0, 1) : 0.5,
      t: t is num && t.isFinite ? t.toInt() : 0,
      tilt: tl is num && tl.isFinite ? tl.toDouble().clamp(0, 1) : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InkPoint &&
      other.x == x &&
      other.y == y &&
      other.pressure == pressure &&
      other.t == t &&
      other.tilt == tilt;

  @override
  int get hashCode => Object.hash(x, y, pressure, t, tilt);
}

/// 一笔墨迹：点序列 + 笔宽基准 + 颜色。
@immutable
class InkStroke {
  const InkStroke({
    required this.points,
    this.baseWidth = 3.0,
    this.colorValue = InkAnnotation.defaultColorValue,
  });

  final List<InkPoint> points;

  /// 笔宽：以页宽 1000 为基准的逻辑像素（渲染时 × 当前画布宽/1000，
  /// 见 InkStrokesPainter.widthBasis），跨字号/跨屏等比缩放。
  final double baseWidth;

  final int colorValue;

  Map<String, dynamic> toMap() => {
    'w': baseWidth,
    'c': colorValue,
    'pts': [for (final p in points) p.toMap()],
  };

  static InkStroke? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final w = raw['w'];
    final c = raw['c'];
    final pts = raw['pts'];
    if (pts is! List) return null;
    final points = List<InkPoint>.unmodifiable(
      pts.map(InkPoint.fromMap).whereType<InkPoint>(),
    );
    if (points.isEmpty) return null;
    return InkStroke(
      points: points,
      baseWidth:
          w is num && w.isFinite && w > 0 ? w.toDouble() : 3.0,
      colorValue: c is num && c.isFinite ? c.toInt() : InkAnnotation.defaultColorValue,
    );
  }
}

/// 锚点校验结果。
enum InkAnchorStatus {
  /// 指纹命中：偏移与上下文都对得上。
  exact,

  /// 区间部分命中（AnchorProjector 找到了唯一的新位置，坐标需重投影）。
  partial,

  /// 指纹失配：正文变化，需人工确认，不得静默丢弃或自动修复。
  mismatch,

  /// 未校验（调用方没有提供当前正文，如纯页锚点/离线场景）。
  unverified,
}

/// 归一化矩形（0~1，相对批注页面）。
@immutable
class InkRect {
  const InkRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, dynamic> toMap() => {
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
  };

  static InkRect? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final l = raw['l'];
    final t = raw['t'];
    final r = raw['r'];
    final b = raw['b'];
    if (l is! num || t is! num || r is! num || b is! num) return null;
    return InkRect(
      left: l.toDouble(),
      top: t.toDouble(),
      right: r.toDouble(),
      bottom: b.toDouble(),
    );
  }
}

/// 一组墨迹 + 锚点信息（第 3 组核心模型，PDF 与流式共用）。
@immutable
class InkAnnotation {
  const InkAnnotation({
    required this.bookId,
    required this.chapterId,
    required this.pageWidth,
    required this.pageHeight,
    required this.layoutVersion,
    required this.strokes,
    required this.createdAt,
    this.format = kFormatPdf,
    this.startOffset,
    this.endOffset,
    this.contextBefore = '',
    this.contextAfter = '',
    this.anchorBox,
    this.updatedAt,
  });

  /// PDF 固定版式批注。
  static const String kFormatPdf = 'pdf';

  /// EPUB/TXT 排版快照批注（进入批注模式时固化排版参数）。
  static const String kFormatFlow = 'flow';

  /// 上下文指纹长度：锚点前后各取 32 字符。
  static const int contextLength = 32;

  /// 默认墨色（HomePalette.accent 的字面值；模型层不 import widgets）。
  static const int defaultColorValue = 0xFF2FA98C;

  final String bookId;

  /// PDF=页 itemId；流式书=章节 itemId（与 ReaderAnnotation 同一 id 空间）。
  final String chapterId;

  /// 'pdf'（固定版式，版式恒定）或 'flow'（排版参数版本号）。
  final String format;

  /// 锚点文本区间：章节展示文本的字符偏移，与 ReaderAnnotation.start/end
  /// 同一坐标系。纯页锚点（无文本层 PDF）为 null。
  final int? startOffset;
  final int? endOffset;

  /// 上下文指纹（原文快照）：锚点前/后各 [contextLength] 字符。
  /// 失配时判定为 [InkAnchorStatus.mismatch]，交给用户确认。
  final String contextBefore;
  final String contextAfter;

  /// 锚点文本区间包围盒（0~1 相对批注页面）；无文本锚点时为 null。
  final InkRect? anchorBox;

  /// 批注页面快照尺寸（逻辑像素），墨迹点/笔宽的归一化基准。
  final double pageWidth;
  final double pageHeight;

  /// 排版版本：PDF 恒 'pdf-fixed'；流式书为排版参数指纹（第 6 组定义）。
  final String layoutVersion;

  final List<InkStroke> strokes;
  final int createdAt;
  final int? updatedAt;

  /// 存储键：一书一页（流式书一页=一次批注会话的固化排版）。
  /// 同页多次编辑（加笔/擦除/撤销）都整条覆写同一个键。
  static String keyFor({
    required String bookId,
    required String chapterId,
    required String layoutVersion,
  }) => 'ink:$bookId:$chapterId:$layoutVersion';

  String get key =>
      keyFor(bookId: bookId, chapterId: chapterId, layoutVersion: layoutVersion);

  bool get hasTextAnchor =>
      startOffset != null && endOffset != null && endOffset! > startOffset!;

  /// 校验锚点指纹：偏移落在正文内且前后文与快照一致 → exact；
  /// 偏移可用但上下文对不上 → mismatch（需人工确认）；偏移越界 → mismatch。
  ///
  /// 不做「自动另找位置」（partial 由 AnchorProjector 的定位器给出，
  /// 见第 7 组）；这里只判「当前锚点还可不可信」。
  InkAnchorStatus verifyAgainst(String chapterText) {
    final start = startOffset;
    final end = endOffset;
    if (start == null || end == null || end <= start) {
      return contextBefore.isEmpty && contextAfter.isEmpty
          ? InkAnchorStatus.unverified
          : InkAnchorStatus.mismatch;
    }
    if (start < 0 || end > chapterText.length) {
      return InkAnchorStatus.mismatch;
    }
    final beforeOk = _tail(chapterText, 0, start) == contextBefore;
    final afterOk = _head(chapterText, end) == contextAfter;
    return beforeOk && afterOk
        ? InkAnchorStatus.exact
        : InkAnchorStatus.mismatch;
  }

  /// 章节正文的 [from, to) 前缀与锚点后文比对时，取末尾 [contextLength] 字符。
  static String _tail(String text, int from, int to) {
    final slice = text.substring(from, to);
    return slice.length <= contextLength
        ? slice
        : slice.substring(slice.length - contextLength);
  }

  static String _head(String text, int from) {
    final slice = text.substring(
      from,
      text.length - from >= contextLength ? from + contextLength : text.length,
    );
    return slice;
  }

  /// 从章节正文提取锚点上下文（保存时调用）。
  static (String, String) contextOf(String chapterText, int start, int end) =>
      (_tail(chapterText, 0, start), _head(chapterText, end));

  InkAnnotation copyWith({
    List<InkStroke>? strokes,
    int? startOffset,
    int? endOffset,
    String? contextBefore,
    String? contextAfter,
    InkRect? anchorBox,
    String? layoutVersion,
    int? updatedAt,
  }) =>
      InkAnnotation(
        bookId: bookId,
        chapterId: chapterId,
        pageWidth: pageWidth,
        pageHeight: pageHeight,
        layoutVersion: layoutVersion ?? this.layoutVersion,
        strokes: strokes ?? this.strokes,
        createdAt: createdAt,
        format: format,
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        contextBefore: contextBefore ?? this.contextBefore,
        contextAfter: contextAfter ?? this.contextAfter,
        anchorBox: anchorBox ?? this.anchorBox,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'format': format,
    'start': startOffset,
    'end': endOffset,
    'ctxBefore': contextBefore,
    'ctxAfter': contextAfter,
    'anchorBox': anchorBox?.toMap(),
    'pageWidth': pageWidth,
    'pageHeight': pageHeight,
    'layoutVersion': layoutVersion,
    'strokes': [for (final s in strokes) s.toMap()],
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  static InkAnnotation? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final pageWidth = raw['pageWidth'];
    final pageHeight = raw['pageHeight'];
    final layoutVersion = raw['layoutVersion'];
    final createdAt = raw['createdAt'];
    final rawStrokes = raw['strokes'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        pageWidth is! num ||
        pageHeight is! num ||
        pageWidth <= 0 ||
        pageHeight <= 0 ||
        layoutVersion is! String ||
        layoutVersion.isEmpty ||
        rawStrokes is! List) {
      return null;
    }
    final strokes = List<InkStroke>.unmodifiable(
      rawStrokes.map(InkStroke.fromMap).whereType<InkStroke>(),
    );
    if (strokes.isEmpty) return null;
    final format = raw['format'];
    final start = raw['start'];
    final end = raw['end'];
    final updatedAt = raw['updatedAt'];
    return InkAnnotation(
      bookId: bookId,
      chapterId: chapterId,
      pageWidth: pageWidth.toDouble(),
      pageHeight: pageHeight.toDouble(),
      layoutVersion: layoutVersion,
      strokes: strokes,
      createdAt: createdAt is num && createdAt.isFinite
          ? createdAt.toInt()
          : 0,
      format: format == kFormatFlow ? kFormatFlow : kFormatPdf,
      startOffset: start is num && start.isFinite ? start.toInt() : null,
      endOffset: end is num && end.isFinite ? end.toInt() : null,
      contextBefore: raw['ctxBefore'] is String ? raw['ctxBefore'] as String : '',
      contextAfter: raw['ctxAfter'] is String ? raw['ctxAfter'] as String : '',
      anchorBox: InkRect.fromMap(raw['anchorBox']),
      updatedAt: updatedAt is num && updatedAt.isFinite
          ? updatedAt.toInt()
          : null,
    );
  }
}

/// 带校验状态的读取结果（loadByChapterVerified 返回）。
/// 失配条目照常返回并标 [InkAnchorStatus.mismatch]，由 UI 提示用户确认。
@immutable
class InkAnchorReview {
  const InkAnchorReview({required this.annotation, required this.status});

  final InkAnnotation annotation;
  final InkAnchorStatus status;

  bool get needsReview => status == InkAnchorStatus.mismatch;
}
