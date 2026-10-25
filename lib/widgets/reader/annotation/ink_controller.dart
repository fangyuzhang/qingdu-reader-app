import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import '../../../models/ink_annotation.dart';

/// 墨迹会话控制器（第 5 组）：模式内的笔迹缓冲、撤销/重做、工具状态，
/// 以及套索圈选（Kindle Scribe 式）：圈选 → 移动/缩放/复制/剪切/删除/粘贴。
///
/// 仓库没有 ViewModel 层（见勘察报告 §0/§4），ChangeNotifier 即批注模式的
/// 状态载体；一切落盘由宿主页面（PdfReaderPage / 阅读器批注模式）通过
/// [onChanged] 防抖后走 InkAnnotationStore——控制器自己不碰存储，符合
/// 「Widget 不写 IO」红线。
///
/// 坐标约定：套索路径与选中包围盒与笔迹点同一坐标系（0~1 归一化，相对
/// 批注页面），画布把像素坐标换算后传入，控制器内是纯几何计算。
class InkController extends ChangeNotifier {
  InkTool tool = InkTool.pen;
  int colorValue = InkAnnotation.defaultColorValue;

  /// 笔宽（页宽 1000 基准的逻辑像素），预设 2.5 / 4 / 6。
  double baseWidth = 4;

  /// 调试用手指绘制开关（debugToolsEnabled 时工具栏可见；正式版手指
  /// 不作画——笔迹只认 stylus，见 stylus_probe_page 实测结论）。
  /// 套索工具不受此开关限制：手指和笔都参与圈选。
  bool acceptFinger = false;

  List<InkStroke> _strokes = const [];
  final List<_InkOp> _undoStack = [];
  final List<_InkOp> _redoStack = [];

  /// 套索拖圈中的路径（归一化坐标；非拖圈时为空）。
  final List<Offset> _lassoPath = [];

  /// 选中笔迹的下标集（移动/缩放保持下标不变；列表长度变化后裁剪）。
  final Set<int> _selection = <int>{};

  /// 剪贴板：选中笔迹的深拷贝（控制器内存字段，不落盘）。
  List<InkStroke> _clipboard = const [];

  /// 变换事务深度：拖拽移动/缩放期间每帧调用 moveSelected/scaleSelected，
  /// 抬手 endTransform 时把整段变换合并为**一条**撤销记录。
  int _transactionDepth = 0;
  List<InkStroke>? _transactionBefore;

  /// 会话内是否有编辑（宿主判断是否需要保存）。
  bool dirty = false;

  List<InkStroke> get strokes => _strokes;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  // ── 套索 / 选中状态 ──────────────────────────────────────────────────

  /// 是否正在拖圈（路径非空）。
  bool get isLassoing => _lassoPath.isNotEmpty;

  /// 当前套索路径（归一化坐标，只读视图）。
  List<Offset> get lassoPath => List.unmodifiable(_lassoPath);

  /// 选中笔迹下标（只读视图）。
  Set<int> get selectedIndices => Set.unmodifiable(_selection);

  bool get hasSelection => _selection.isNotEmpty;

  /// 选中笔迹的归一化包围盒；无选中为 null。
  Rect? get selectionBounds => _boundsOf(_selectedStrokes);

  /// 剪贴板是否有内容（工具栏据此决定是否显示粘贴）。
  bool get hasClipboard => _clipboard.isNotEmpty;

  /// 宿主提供的「内容变了」回调（防抖保存的触发源）。
  final VoidCallback? onChanged;

  InkController({this.onChanged});

  /// 进入批注模式时用已保存的墨迹初始化（同页多次编辑共用一条记录）。
  void seed(List<InkStroke> saved) {
    _strokes = List.unmodifiable(saved);
    _undoStack.clear();
    _redoStack.clear();
    _lassoPath.clear();
    _selection.clear();
    dirty = false;
    notifyListeners();
  }

  void addStroke(InkStroke stroke) {
    _strokes = List.unmodifiable([..._strokes, stroke]);
    _undoStack.add(_InkOp(_InkOpKind.add, stroke: stroke));
    _redoStack.clear();
    dirty = true;
    notifyListeners();
    onChanged?.call();
  }

  /// 擦除命中的一笔（命中检测在画布做，控制器只记录操作）。
  void removeStroke(int index) {
    if (index < 0 || index >= _strokes.length) return;
    final removed = _strokes[index];
    _strokes = List.unmodifiable([
      for (var i = 0; i < _strokes.length; i++)
        if (i != index) _strokes[i],
    ]);
    _undoStack.add(_InkOp(_InkOpKind.erase, index: index, stroke: removed));
    _redoStack.clear();
    dirty = true;
    _pruneSelection();
    notifyListeners();
    onChanged?.call();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    final op = _undoStack.removeLast();
    switch (op.kind) {
      case _InkOpKind.add:
        _strokes = _strokes.length > 1
            ? _strokes.sublist(0, _strokes.length - 1)
            : const [];
      case _InkOpKind.erase:
        final next = [..._strokes];
        next.insert(op.index.clamp(0, next.length), op.stroke!);
        _strokes = List.unmodifiable(next);
      case _InkOpKind.replace:
        _strokes = List.unmodifiable(op.before ?? const []);
    }
    _redoStack.add(op);
    dirty = true;
    _pruneSelection();
    notifyListeners();
    onChanged?.call();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final op = _redoStack.removeLast();
    switch (op.kind) {
      case _InkOpKind.add:
        _strokes = List.unmodifiable([..._strokes, op.stroke!]);
      case _InkOpKind.erase:
        _strokes = _strokes.length > op.index &&
                _strokes[op.index] == op.stroke
            ? List.unmodifiable([
                for (var i = 0; i < _strokes.length; i++)
                  if (i != op.index) _strokes[i],
              ])
            : _strokes;
      case _InkOpKind.replace:
        _strokes = List.unmodifiable(op.after ?? const []);
    }
    _undoStack.add(op);
    dirty = true;
    _pruneSelection();
    notifyListeners();
    onChanged?.call();
  }

  /// 清空全部笔迹（整页擦除，可撤销）。
  void clearAll() {
    for (var i = _strokes.length - 1; i >= 0; i--) {
      _undoStack.add(_InkOp(_InkOpKind.erase, index: i, stroke: _strokes[i]));
    }
    _redoStack.clear();
    _strokes = const [];
    _pruneSelection();
    dirty = true;
    notifyListeners();
    onChanged?.call();
  }

  // ── 套索圈选（Kindle Scribe 式）──────────────────────────────────────

  /// 开始拖圈（画布按下时调用；坐标为归一化页面坐标）。
  void beginLasso(Offset point) {
    _lassoPath
      ..clear()
      ..add(_clamp01(point));
    notifyListeners();
  }

  /// 拖圈中追加点（同点去抖）。
  void updateLasso(Offset point) {
    if (_lassoPath.isEmpty) return;
    final p = _clamp01(point);
    if ((p - _lassoPath.last).distance < 0.0015) return;
    _lassoPath.add(p);
    notifyListeners();
  }

  /// 抬手：按闭合多边形做命中判定。
  ///
  /// 命中任一笔迹 → 命中下标成为新选中集（替换旧选中），套索路径保留供
  /// 绘制；未命中 → 清空选中与套索路径。返回是否命中。
  bool endLasso() {
    if (_lassoPath.isEmpty) return false;
    final hits = _hitTestLasso(_lassoPath);
    _lassoPath.clear();
    if (hits.isEmpty) {
      if (_selection.isNotEmpty) _selection.clear();
      notifyListeners();
      return false;
    }
    _selection
      ..clear()
      ..addAll(hits);
    notifyListeners();
    return true;
  }

  /// 手势被打断（滚动手势抢走等）：丢弃路径，不做命中判定。
  void cancelLasso() {
    if (_lassoPath.isEmpty) return;
    _lassoPath.clear();
    notifyListeners();
  }

  /// 清空选中集（退出圈选编辑，不影响笔迹本身）。
  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    notifyListeners();
  }

  // ── 选中集编辑（全部可撤销）─────────────────────────────────────────

  /// 平移选中笔迹（归一化位移）。
  void moveSelected(Offset delta) {
    if (delta == Offset.zero || _selection.isEmpty) return;
    _transformSelected(
      (s) => InkStroke(
        points: List<InkPoint>.unmodifiable([
          for (final p in s.points)
            InkPoint(x: p.x + delta.dx, y: p.y + delta.dy, pressure: p.pressure, t: p.t),
        ]),
        baseWidth: s.baseWidth,
        colorValue: s.colorValue,
      ),
    );
  }

  /// 以 [origin]（归一化）为锚点缩放选中笔迹；笔宽同步缩放保持视觉比例。
  void scaleSelected(double factor, Offset origin) {
    if (_selection.isEmpty) return;
    final f = factor.clamp(0.05, 20.0);
    if (f == 1.0) return;
    _transformSelected(
      (s) => InkStroke(
        points: List<InkPoint>.unmodifiable([
          for (final p in s.points)
            InkPoint(
              x: origin.dx + (p.x - origin.dx) * f,
              y: origin.dy + (p.y - origin.dy) * f,
              pressure: p.pressure,
              t: p.t,
            ),
        ]),
        baseWidth: math.max(0.3, s.baseWidth * f),
        colorValue: s.colorValue,
      ),
    );
  }

  /// 删除选中笔迹（单条撤销记录，可撤销恢复）。
  void deleteSelected() {
    if (_selection.isEmpty) return;
    final before = _strokes;
    _strokes = List.unmodifiable([
      for (var i = 0; i < before.length; i++)
        if (!_selection.contains(i)) before[i],
    ]);
    _selection.clear();
    _undoStack.add(_InkOp(_InkOpKind.replace, before: before, after: _strokes));
    _redoStack.clear();
    dirty = true;
    notifyListeners();
    onChanged?.call();
  }

  /// 复制选中笔迹到剪贴板（深拷贝）。返回是否复制了内容。
  bool copySelected() {
    if (_selection.isEmpty) return false;
    final copied = <InkStroke>[
      for (final i in _selection.toList()..sort())
        if (i >= 0 && i < _strokes.length) _cloneStroke(_strokes[i]),
    ];
    if (copied.isEmpty) return false;
    _clipboard = copied;
    notifyListeners();
    return true;
  }

  /// 剪切 = 复制 + 删除。返回是否剪切了内容。
  bool cutSelected() {
    if (_selection.isEmpty) return false;
    copySelected();
    deleteSelected();
    return true;
  }

  /// 把剪贴板内容粘贴到 [center]（归一化，粘贴后整体中心对齐该点），
  /// 追加到笔迹列表末尾并选中新笔迹。返回是否执行了粘贴。
  bool pasteAt(Offset center) {
    if (_clipboard.isEmpty) return false;
    final clipBounds = _boundsOf(_clipboard);
    if (clipBounds == null) return false;
    final delta = center - clipBounds.center;
    final before = _strokes;
    final pasted = [
      for (final s in _clipboard)
        InkStroke(
          points: List<InkPoint>.unmodifiable([
            for (final p in s.points)
              InkPoint(x: p.x + delta.dx, y: p.y + delta.dy, pressure: p.pressure, t: p.t),
          ]),
          baseWidth: s.baseWidth,
          colorValue: s.colorValue,
        ),
    ];
    _strokes = List.unmodifiable([...before, ...pasted]);
    _selection
      ..clear()
      ..addAll([for (var i = before.length; i < _strokes.length; i++) i]);
    _undoStack.add(_InkOp(_InkOpKind.replace, before: before, after: _strokes));
    _redoStack.clear();
    dirty = true;
    notifyListeners();
    onChanged?.call();
    return true;
  }

  // ── 变换事务（拖拽移动/缩放合并为一条撤销记录）──────────────────────

  /// 开始一段连续变换（画布在选中集内按下时调用）。
  void beginTransform() {
    _transactionDepth++;
    _transactionBefore ??= _strokes;
  }

  /// 结束事务：整段变换合并为一条撤销记录；无实际变更则不记录。
  void endTransform() {
    if (_transactionDepth == 0) return;
    _transactionDepth--;
    if (_transactionDepth > 0) return;
    final before = _transactionBefore;
    _transactionBefore = null;
    if (before == null || identical(before, _strokes)) return;
    _undoStack.add(_InkOp(_InkOpKind.replace, before: before, after: _strokes));
    _redoStack.clear();
    dirty = true;
    notifyListeners();
    onChanged?.call();
  }

  /// 事务内逐帧变换：只改笔迹 + 通知重绘，撤销记录由 endTransform 统一记。
  void _transformSelected(InkStroke Function(InkStroke) transform) {
    final outermost = _transactionDepth == 0;
    if (outermost) beginTransform();
    _strokes = List.unmodifiable([
      for (var i = 0; i < _strokes.length; i++)
        _selection.contains(i) ? transform(_strokes[i]) : _strokes[i],
    ]);
    dirty = true;
    if (outermost) {
      endTransform();
    } else {
      notifyListeners();
    }
  }

  // ── 工具栏选择项（公开变更入口，替代外部直接改字段+notify）──────────

  void selectTool(InkTool value) {
    if (tool == value) return;
    tool = value;
    // 离开套索工具即退出圈选态；进入其它工具不受选中集影响。
    if (tool != InkTool.lasso) {
      _lassoPath.clear();
      _selection.clear();
    }
    notifyListeners();
  }

  void selectColor(int value) {
    if (colorValue == value) return;
    colorValue = value;
    notifyListeners();
  }

  void selectWidth(double value) {
    if (baseWidth == value) return;
    baseWidth = value;
    notifyListeners();
  }

  void toggleFinger() {
    acceptFinger = !acceptFinger;
    notifyListeners();
  }

  // ── 内部几何 ────────────────────────────────────────────────────────

  List<InkStroke> get _selectedStrokes => [
    for (final i in _selection)
      if (i >= 0 && i < _strokes.length) _strokes[i],
  ];

  static Rect? _boundsOf(List<InkStroke> strokes) {
    double? left, top, right, bottom;
    for (final s in strokes) {
      for (final p in s.points) {
        left = left == null ? p.x : math.min(left, p.x);
        top = top == null ? p.y : math.min(top, p.y);
        right = right == null ? p.x : math.max(right, p.x);
        bottom = bottom == null ? p.y : math.max(bottom, p.y);
      }
    }
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// 选中下标越界裁剪（撤销/删除后列表长度变化时保持选中合法）。
  void _pruneSelection() {
    if (_selection.isEmpty) return;
    _selection.removeWhere((i) => i < 0 || i >= _strokes.length);
  }

  static InkStroke _cloneStroke(InkStroke s) => InkStroke(
    points: List<InkPoint>.unmodifiable(s.points),
    baseWidth: s.baseWidth,
    colorValue: s.colorValue,
  );

  static Offset _clamp01(Offset p) =>
      Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0));

  /// 套索命中：闭合多边形与笔迹「任一点在多边形内 或 任一笔段与多边形
  /// 边相交」即命中（OneNote 式相交即选中；Kindle Scribe 要求完全包住，
  /// 这里取更宽容的一档——手写笔迹常被圈得只切过一小段）。
  Set<int> _hitTestLasso(List<Offset> poly) {
    if (poly.length < 2) return {};
    final polyBounds = _boundsOfPoints(poly);
    if (polyBounds == null) return {};
    final hits = <int>{};
    for (var i = 0; i < _strokes.length; i++) {
      if (_strokeHitsPolygon(_strokes[i], poly, polyBounds)) hits.add(i);
    }
    return hits;
  }

  static bool _strokeHitsPolygon(
    InkStroke stroke,
    List<Offset> poly,
    Rect polyBounds,
  ) {
    final pts = stroke.points;
    if (pts.isEmpty) return false;
    final strokeBounds = _boundsOfPoints([
      for (final p in pts) Offset(p.x, p.y),
    ]);
    if (strokeBounds == null || !strokeBounds.overlaps(polyBounds)) {
      return false;
    }
    if (pts.length == 1) {
      return _pointInPolygon(Offset(pts[0].x, pts[0].y), poly);
    }
    for (final p in pts) {
      if (_pointInPolygon(Offset(p.x, p.y), poly)) return true;
    }
    for (var j = 1; j < pts.length; j++) {
      final a = Offset(pts[j - 1].x, pts[j - 1].y);
      final b = Offset(pts[j].x, pts[j].y);
      for (var k = 0; k < poly.length; k++) {
        final c = poly[k];
        final d = poly[(k + 1) % poly.length];
        if (_segmentsIntersect(a, b, c, d)) return true;
      }
    }
    return false;
  }

  static Rect? _boundsOfPoints(List<Offset> points) {
    if (points.isEmpty) return null;
    var left = points.first.dx;
    var top = points.first.dy;
    var right = left;
    var bottom = top;
    for (final p in points) {
      left = math.min(left, p.dx);
      top = math.min(top, p.dy);
      right = math.max(right, p.dx);
      bottom = math.max(bottom, p.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// 射线法（奇偶规则）。
  static bool _pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    var j = poly.length - 1;
    for (var i = 0; i < poly.length; j = i++) {
      final a = poly[i];
      final b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// 线段相交（含共线接触——套索贴线擦过也算圈中）。
  static bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    final d1 = _cross(p3, p4, p1);
    final d2 = _cross(p3, p4, p2);
    final d3 = _cross(p1, p2, p3);
    final d4 = _cross(p1, p2, p4);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
      return true;
    }
    return (d1 == 0 && _onSegment(p3, p4, p1)) ||
        (d2 == 0 && _onSegment(p3, p4, p2)) ||
        (d3 == 0 && _onSegment(p1, p2, p3)) ||
        (d4 == 0 && _onSegment(p1, p2, p4));
  }

  static double _cross(Offset a, Offset b, Offset p) =>
      (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);

  static bool _onSegment(Offset a, Offset b, Offset p) =>
      p.dx >= math.min(a.dx, b.dx) - 1e-9 &&
      p.dx <= math.max(a.dx, b.dx) + 1e-9 &&
      p.dy >= math.min(a.dy, b.dy) - 1e-9 &&
      p.dy <= math.max(a.dy, b.dy) + 1e-9;
}

enum InkTool { pen, eraser, lasso }

enum _InkOpKind { add, erase, replace }

class _InkOp {
  const _InkOp(
    this.kind, {
    this.index = -1,
    this.stroke,
    this.before,
    this.after,
  });

  final _InkOpKind kind;

  /// erase 时的原下标（撤销时插回原位）。
  final int index;
  final InkStroke? stroke;

  /// replace（复合/整表替换）操作的前后快照：套索移动/缩放/删除/粘贴。
  final List<InkStroke>? before;
  final List<InkStroke>? after;
}
