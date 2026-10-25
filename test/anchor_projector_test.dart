import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/ink_annotation.dart';
import 'package:fqapp/services/anchor_projector.dart';

/// 第 7 组：锚点重投影纯函数的回归测试（CI 可跑，不依赖真机）。
///
/// 覆盖：字号/行距/页宽/横竖屏（等价于锚点盒的各种缩放与平移）、指纹
/// 失配、relocate 的唯一重定位/区间被删/指纹丢失、纯页锚点。
void main() {
  const storedBox = InkRect(left: 0.2, top: 0.3, right: 0.5, bottom: 0.4);

  InkAnnotation annotation({
    InkRect? anchorBox = storedBox,
    int? start = 32,
    int? end = 40,
    String before = '前文指纹前文指纹前文指纹前文指纹前文指纹前文指纹',
    String after = '后文指纹后文指纹后文指纹后文指纹后文指纹后文指纹',
  }) => InkAnnotation(
    bookId: 'b1',
    chapterId: 'c1',
    pageWidth: 400,
    pageHeight: 600,
    layoutVersion: 'flow:17.0:x',
    strokes: const [
      InkStroke(points: [InkPoint(x: 0.25, y: 0.35), InkPoint(x: 0.4, y: 0.38)]),
    ],
    createdAt: 1,
    startOffset: start,
    endOffset: end,
    contextBefore: before,
    contextAfter: after,
    anchorBox: anchorBox,
  );

  group('projectInk 变换', () {
    test('字号变化（锚点盒缩小）：墨迹等比缩小', () {
      final t = projectInk(
        annotation: annotation(),
        anchorBox: const Rect2(left: 0.3, top: 0.45, width: 0.15, height: 0.05),
      );
      expect(t.status, InkAnchorStatus.exact);
      expect(t.scaleX, closeTo(0.5, 1e-9)); // 0.15 / 0.3
      // 存储墨迹点 (0.25, 0.35) →
      // x: 0.3 - 0.5*0.2 + 0.5*0.25 = 0.325；y: 0.45 - 0.5*0.3 + 0.5*0.35 = 0.475
      final (nx, ny) = t.apply(0.25, 0.35);
      expect(nx, closeTo(0.325, 1e-9));
      expect(ny, closeTo(0.475, 1e-9));
    });

    test('行距/页宽变化（锚点盒平移）：纯平移', () {
      final t = projectInk(
        annotation: annotation(),
        anchorBox: const Rect2(left: 0.4, top: 0.2, width: 0.3, height: 0.1),
      );
      expect(t.scaleX, closeTo(1, 1e-9));
      expect(t.translateX, closeTo(0.2, 1e-9));
      expect(t.translateY, closeTo(-0.1, 1e-9));
    });

    test('横竖屏切换（盒宽高互换组合）：变换仍为平移+缩放', () {
      // 存储盒 0.3x0.1（竖屏窄高行），横屏后同样文本的盒变宽变矮。
      final t = projectInk(
        annotation: annotation(),
        anchorBox: const Rect2(left: 0.1, top: 0.5, width: 0.6, height: 0.05),
      );
      expect(t.scaleX, closeTo(2.0, 1e-9));
      expect(t.scaleY, closeTo(0.5, 1e-9));
    });

    test('指纹失配且无法 relocate：恒等变换 + mismatch（不自动修复）', () {
      final t = projectInk(
        annotation: annotation(),
        anchorBox: null,
        status: InkAnchorStatus.mismatch,
      );
      expect(t.status, InkAnchorStatus.mismatch);
      expect(t.scaleX, 1);
      expect(t.translateX, 0);
    });

    test('纯页锚点（无文本层 PDF）：恒等 + unverified', () {
      final t = projectInk(
        annotation: annotation(anchorBox: null, start: null, end: null),
        anchorBox: null,
      );
      expect(t.status, InkAnchorStatus.unverified);
      final (nx, ny) = t.apply(0.3, 0.7);
      expect(nx, 0.3);
      expect(ny, 0.7);
    });

    test('部分命中（relocate 出新盒）：partial + 新盒变换', () {
      final t = projectInk(
        annotation: annotation(),
        anchorBox: const Rect2(left: 0.35, top: 0.35, width: 0.3, height: 0.1),
        status: InkAnchorStatus.partial,
      );
      expect(t.status, InkAnchorStatus.partial);
      expect(t.scaleX, closeTo(1, 1e-9));
      expect(t.translateX, closeTo(0.15, 1e-9));
    });
  });

  group('relocateAnchor 指纹定位', () {
    const before = '前文指纹前文指纹';
    const after = '后文指纹后文指纹';
    const anchorText = '这是被锚定的原文。';

    test('锚点前插入内容：指纹唯一 → 重定位到新偏移', () {
      const text = '开头。插入了一段新内容。$before$anchorText$after结尾。';
      final hit = relocateAnchor(text, before, after);
      expect(hit, isNotNull);
      expect(text.substring(hit!.start, hit.end), anchorText);
    });

    test('锚点区间被整体删除：before/after 相邻 → null', () {
      const text = '开头。$before$after结尾。';
      expect(relocateAnchor(text, before, after), isNull);
    });

    test('指纹被改动（正文外部修改）：找不到 → null', () {
      const text = '开头。前文指纹被改掉X。原文。后文指纹也变了Y。';
      expect(relocateAnchor(text, before, after), isNull);
    });

    test('空指纹（纯页锚点）：null，不做猜测', () {
      expect(relocateAnchor('任意正文', '', after), isNull);
      expect(relocateAnchor('任意正文', before, ''), isNull);
    });
  });

  group('verifyAgainst 与 layoutVersion 语义（跨章边界）', () {
    test('章节不匹配由调用方把关：跨章内容指纹必然失配', () {
      // 模拟「锚点跨章节边界」被拆到两章：当前章文本只含后半。
      final text =
          '后文指纹后文指纹后文指纹后文指纹后文指纹后文指纹多余的尾巴';
      final a = annotation();
      expect(a.verifyAgainst(text), InkAnchorStatus.mismatch);
    });

    test('锚点命中与失配的完整链路（verify → relocate → project）', () {
      // 与 annotation() 的指纹严格对齐：前 32 字 + 8 字锚点 + 后 32 字。
      final a = annotation(before: '前' * 32, after: '后' * 32);
      final modified = '${'前' * 32}这是锚点原文啦！${'后' * 32}';
      expect(a.verifyAgainst(modified), InkAnchorStatus.exact);
      // 前面插入内容 → verify mismatch，但 relocate 唯一命中。
      final shifted = '新插入的章节开头两句话。$modified';
      expect(a.verifyAgainst(shifted), InkAnchorStatus.mismatch);
      final hit = relocateAnchor(shifted, a.contextBefore, a.contextAfter);
      expect(hit, isNotNull);
      expect(hit!.start, greaterThan(a.startOffset!));
      // 拿到新区间后由调用方算新盒，走 partial 变换。
      final t = projectInk(
        annotation: a,
        anchorBox: const Rect2(left: 0.25, top: 0.32, width: 0.28, height: 0.09),
        status: InkAnchorStatus.partial,
      );
      expect(t.status, InkAnchorStatus.partial);
    });
  });
}
