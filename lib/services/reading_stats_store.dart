import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读量与打卡统计（按天记字数）。
///
/// 【青茄重构·新增】上游只记录「时长」，热力图因此只能按时长着色；
/// 产品要求「总共读了多少万字 / 连续打卡多少天」，所以在 Dart 侧补一个
/// 轻量计数器：
///
/// * 数据只有一张 `{日期: 字数}` 表 + 全量累计值，SharedPreferences 单键存 JSON
///   （一年 365 条量级，不需要上 Hive）；
/// * 写入走内存累加 + 2 秒防抖落盘，避免每翻一章就写一次磁盘；
/// * 字数按「本章排版后的正文字符数」计（翻到该章计一次），是**估算**而非
///   逐字精确统计，用于展示量级足够。
class ReadingStatsStore {
  ReadingStatsStore._();

  static final ReadingStatsStore instance = ReadingStatsStore._();

  static const _prefsKey = 'reading_stats_v1';

  /// 落盘防抖窗口。
  static const _persistDelay = Duration(seconds: 2);

  final ValueNotifier<int> changes = ValueNotifier(0);

  Map<String, int> _dayChars = {};
  int _totalChars = 0;
  Timer? _persistTimer;
  bool _loaded = false;

  /// 按天字数，键为 `yyyy-M-d`（与 LibraryStore 的日统计键一致）。
  Map<String, int> get dayChars => Map.unmodifiable(_dayChars);

  int get totalChars => _totalChars;

  /// 连续打卡天数：从今天（或昨天，容忍「今天还没读」）往前数连续有阅读的天数。
  int get currentStreakDays {
    if (_dayChars.isEmpty) return 0;
    final today = DateTime.now();
    var cursor = _dayChars.containsKey(_key(today))
        ? today
        : today.subtract(const Duration(days: 1));
    var streak = 0;
    while (_dayChars.containsKey(_key(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  static String _key(DateTime day) => '${day.year}-${day.month}-${day.day}';

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final days = <String, int>{};
      var total = 0;
      (decoded['days'] as Map?)?.forEach((key, value) {
        if (key is String && value is num && value > 0) {
          days[key] = value.toInt();
          total += value.toInt();
        }
      });
      _dayChars = days;
      _totalChars = total;
      changes.value++;
    } catch (_) {
      // 统计是附加能力，读坏了就当没有，不影响阅读。
    }
  }

  /// 记一次阅读量（正文字符数）。
  void addCharacters(int chars, {DateTime? at}) {
    if (chars <= 0) return;
    unawaited(init());
    final key = _key(at ?? DateTime.now());
    _dayChars[key] = (_dayChars[key] ?? 0) + chars;
    _totalChars += chars;
    changes.value++;
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDelay, () => unawaited(_persist()));
  }

  /// 立即落盘（退出阅读器 / 应用进后台时调用）。
  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({'days': _dayChars, 'total': _totalChars}),
      );
    } catch (_) {
      // 写失败不抛给 UI：下一次 addCharacters 会重试。
    }
  }

  @visibleForTesting
  void resetForTest() {
    _dayChars = {};
    _totalChars = 0;
    _loaded = false;
    _persistTimer?.cancel();
  }
}

/// 把字符数格式化成「万」字单位，用于概览卡。
String formatCharacterCount(int chars) {
  if (chars < 10000) return '$chars 字';
  final wan = chars / 10000;
  return '${wan.toStringAsFixed(wan >= 100 ? 0 : 1)} 万字';
}
