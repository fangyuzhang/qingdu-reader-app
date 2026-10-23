import 'package:flutter/foundation.dart';

/// 用户在阅读器里可以选择的划线呈现方式。
enum ReaderMarkStyle {
  solid('solid', '实线'),
  dashed('dashed', '虚线'),
  wavy('wavy', '波浪线'),
  highlighter('highlighter', '荧光笔');

  const ReaderMarkStyle(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static ReaderMarkStyle fromStorage(Object? value) {
    final text = value?.toString();
    for (final style in values) {
      if (style.storageValue == text) return style;
    }
    return ReaderMarkStyle.solid;
  }
}

/// 划线颜色预设。实际记录保存 ARGB 整数，因此换主题后颜色也不会漂移。
@immutable
class ReaderMarkColorPreset {
  const ReaderMarkColorPreset(this.label, this.colorValue);

  final String label;
  final int colorValue;
}

const List<ReaderMarkColorPreset> readerMarkColorPresets = [
  ReaderMarkColorPreset('朱红', 0xFFD64545),
  ReaderMarkColorPreset('橙', 0xFFE85D26),
  ReaderMarkColorPreset('金', 0xFFE9B949),
  ReaderMarkColorPreset('青绿', 0xFF3DA88A),
  ReaderMarkColorPreset('蓝', 0xFF4F7CD1),
  ReaderMarkColorPreset('紫', 0xFF8E6AC8),
];

const int readerDefaultUnderlineColor = 0xFFE85D26;
const int readerDefaultAnnotationColor = 0xFFD64545;
const int readerDefaultExcerptColor = 0xFF3DA88A;

/// 批注标记的预设类型。label 会直接成为角标文字，用户仍可继续修改。
@immutable
class ReaderMarkerPreset {
  const ReaderMarkerPreset(this.key, this.label, this.colorValue);

  final String key;
  final String label;
  final int colorValue;
}

const List<ReaderMarkerPreset> readerMarkerPresets = [
  ReaderMarkerPreset('question', '疑问', 0xFF4F7CD1),
  ReaderMarkerPreset('rebuttal', '反驳', 0xFFD64545),
  ReaderMarkerPreset('insight', '感悟', 0xFF3DA88A),
  ReaderMarkerPreset('verify', '待查证', 0xFFC28A2C),
];
