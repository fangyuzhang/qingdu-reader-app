import '../models/ink_annotation.dart';

/// 锚点重投影（第 7 组）：纯函数工具，不依赖 UI / 数据库 / 平台。
///
/// 输入：[InkAnnotation] 的锚点信息（存储时的锚点包围盒，归一化到存储
/// 页面）+ 当前排版下锚点文本区间的包围盒（归一化到当前页面，由调用方
/// 从字符位置表聚合而来）。输出：把「存储页归一化坐标」映射到「当前页
/// 归一化坐标」的平移 + 缩放变换（[InkTransform]），渲染时再乘当前页
/// 尺寸即可。
///
/// 三种情况：
/// - 精确命中：偏移与指纹都对（[InkAnchorStatus.exact]），用锚点盒推变换；
/// - 区间部分命中：正文改动了但指纹唯一 relocatable（partial），用新盒
///   推变换，UI 提示「位置可能变化」；
/// - 完全失配（mismatch）：无变换可用，返回恒等变换 + mismatch，
///   由 UI 展示原批注快照并交给用户确认；绝不自动修复。
class InkTransform {
  const InkTransform({
    required this.status,
    this.scaleX = 1,
    this.scaleY = 1,
    this.translateX = 0,
    this.translateY = 0,
  });

  final InkAnchorStatus status;
  final double scaleX;
  final double scaleY;
  final double translateX;
  final double translateY;

  /// 存储页归一化坐标 → 当前页归一化坐标。
  (double, double) apply(double nx, double ny) =>
      (translateX + scaleX * nx, translateY + scaleY * ny);
}

/// 由「存储锚点盒 → 当前锚点盒」推平移 + 缩放。
///
/// 无锚点盒（纯页锚点 / 失配）时按 [status] 返回恒等变换：纯页锚点在
/// 固定版式（PDF）下本来就不需要变换；流式书则会走 mismatch 提示。
InkTransform projectInk({
  required InkAnnotation annotation,
  required Rect2? anchorBox,
  InkAnchorStatus status = InkAnchorStatus.exact,
}) {
  final stored = annotation.anchorBox;
  if (stored == null || anchorBox == null || !anchorBox.hasArea) {
    return InkTransform(
      status: stored == null && anchorBox == null
          ? (status == InkAnchorStatus.exact
                ? InkAnchorStatus.unverified
                : status)
          : (anchorBox == null ? InkAnchorStatus.mismatch : status),
    );
  }
  final sx = anchorBox.width / (stored.right - stored.left);
  final sy = anchorBox.height / (stored.bottom - stored.top);
  return InkTransform(
    status: status,
    scaleX: sx,
    scaleY: sy,
    translateX: anchorBox.left - sx * stored.left,
    translateY: anchorBox.top - sy * stored.top,
  );
}

/// 指纹定位器：正文变化后，用上下文指纹把锚点 relocate 到唯一的新位置。
///
/// 规则（宁缺毋滥，找不到或歧义都返回 null）：
/// - [contextBefore] 在正文中找**最后一次**出现，[contextAfter] 找其后的
///   **第一次**出现；
/// - 两者之间的区间必须非空（区间被整体删除 → null）；
/// - 任一指纹为空或找不到 → null。
({int start, int end})? relocateAnchor(
  String text,
  String contextBefore,
  String contextAfter,
) {
  if (contextBefore.isEmpty || contextAfter.isEmpty) return null;
  final before = text.lastIndexOf(contextBefore);
  if (before < 0) return null;
  final rangeStart = before + contextBefore.length;
  final after = text.indexOf(contextAfter, rangeStart);
  if (after < 0 || after <= rangeStart) return null;
  return (start: rangeStart, end: after);
}

/// 归一化矩形（0~1，y 向下）——避免在本工具里 import dart:ui。
class Rect2 {
  const Rect2({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  bool get hasArea => width > 0 && height > 0;
}
