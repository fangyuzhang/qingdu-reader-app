import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_mark_style.dart';

/// 划过一次划线后，下一次轻点「划线」继续使用同一套线型与颜色。
@immutable
class ReaderMarkChoice {
  const ReaderMarkChoice({
    this.style = ReaderMarkStyle.solid,
    this.colorValue = readerDefaultUnderlineColor,
  });

  final ReaderMarkStyle style;
  final int colorValue;
}

class ReaderMarkPreferences {
  ReaderMarkPreferences._();

  static final ReaderMarkPreferences instance = ReaderMarkPreferences._();

  static const _styleKey = 'reader_mark_style_v1';
  static const _colorKey = 'reader_mark_color_v1';

  final ValueNotifier<ReaderMarkChoice> choice =
      ValueNotifier<ReaderMarkChoice>(const ReaderMarkChoice());

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      choice.value = ReaderMarkChoice(
        style: ReaderMarkStyle.fromStorage(prefs.getString(_styleKey)),
        colorValue: prefs.getInt(_colorKey) ?? readerDefaultUnderlineColor,
      );
    } catch (_) {
      // 偏好读取失败时使用产品默认值，不影响划线保存。
    }
  }

  Future<void> select(ReaderMarkStyle style, int colorValue) async {
    choice.value = ReaderMarkChoice(style: style, colorValue: colorValue);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_styleKey, style.storageValue);
      await prefs.setInt(_colorKey, colorValue);
    } catch (_) {
      // 本次阅读仍沿用用户刚选的值。
    }
  }

  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    choice.value = const ReaderMarkChoice();
  }
}
