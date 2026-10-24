import 'package:flutter/foundation.dart';

import '../../../models/ink_annotation.dart';

/// 墨迹会话控制器（第 5 组）：模式内的笔迹缓冲、撤销/重做、工具状态。
///
/// 仓库没有 ViewModel 层（见勘察报告 §0/§4），ChangeNotifier 即批注模式的
/// 状态载体；一切落盘由宿主页面（PdfReaderPage / 阅读器批注模式）通过
/// [onChanged] 防抖后走 InkAnnotationStore——控制器自己不碰存储，符合
/// 「Widget 不写 IO」红线。
class InkController extends ChangeNotifier {
  InkTool tool = InkTool.pen;
  int colorValue = InkAnnotation.defaultColorValue;

  /// 笔宽（页宽 1000 基准的逻辑像素），预设 2.5 / 4 / 6。
  double baseWidth = 4;

  /// 调试用手指绘制开关（debugToolsEnabled 时工具栏可见；正式版手指
  /// 不作画——笔迹只认 stylus，见 stylus_probe_page 实测结论）。
  bool acceptFinger = false;

  List<InkStroke> _strokes = const [];
  final List<_InkOp> _undoStack = [];
  final List<_InkOp> _redoStack = [];

  /// 会话内是否有编辑（宿主判断是否需要保存）。
  bool dirty = false;

  List<InkStroke> get strokes => _strokes;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 宿主提供的「内容变了」回调（防抖保存的触发源）。
  final VoidCallback? onChanged;

  InkController({this.onChanged});

  /// 进入批注模式时用已保存的墨迹初始化（同页多次编辑共用一条记录）。
  void seed(List<InkStroke> saved) {
    _strokes = List.unmodifiable(saved);
    _undoStack.clear();
    _redoStack.clear();
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
    }
    _redoStack.add(op);
    dirty = true;
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
    }
    _undoStack.add(op);
    dirty = true;
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
    dirty = true;
    notifyListeners();
    onChanged?.call();
  }

  // ── 工具栏选择项（公开变更入口，替代外部直接改字段+notify）──────────

  void selectTool(InkTool value) {
    if (tool == value) return;
    tool = value;
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
}

enum InkTool { pen, eraser }

enum _InkOpKind { add, erase }

class _InkOp {
  const _InkOp(this.kind, {this.index = -1, this.stroke});

  final _InkOpKind kind;

  /// erase 时的原下标（撤销时插回原位）。
  final int index;
  final InkStroke? stroke;
}
