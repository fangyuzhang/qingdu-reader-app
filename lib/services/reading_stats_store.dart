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
/// * 字数按「停留时长 × 阅读速度」估算，并以**本章正文长度封顶**（见
///   [estimateReadCharacters]）。早先「打开一章就把整章字数记上」的算法会让
///   目录直接跳最后一章、或一路狂滑不看也涨字数，已废弃。
class ReadingStatsStore {
  ReadingStatsStore._();

  static final ReadingStatsStore instance = ReadingStatsStore._();

  static const _prefsKey = 'reading_stats_v1';

  /// 字数口径版本：2 = 时长估算 + 本章封顶（v1 是「打开整章即整章计」）。
  static const _schemaKey = 'reading_stats_schema';
  static const _charsSchema = 2;

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

  /// 把旧口径（打开一章就整章计数）的历史字数，按真实阅读时长重算一次。
  ///
  /// 只在第一次升级到 v2 口径时执行：已有用户的总字数会从「虚高」回落到
  /// 「时长 × 300 字/分钟」。日期键全部保留，连续打卡天数不受影响；某天在
  /// 时长表里找不到记录时留 1 字占位，同样只为保住打卡日。
  Future<void> migrateToTimeEstimate(
    Map<String, Map<String, double>> readTimeSeconds,
  ) async {
    await init();
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(_schemaKey) ?? 1) >= _charsSchema) return;
      final days = <String, int>{};
      readTimeSeconds.forEach((_, perDay) {
        perDay.forEach((day, seconds) {
          if (seconds <= 0) return;
          final chars = (seconds * kReadingCharsPerSecond).round();
          if (chars <= 0) return;
          days[day] = (days[day] ?? 0) + chars;
        });
      });
      for (final day in _dayChars.keys) {
        days.putIfAbsent(day, () => 1);
      }
      _dayChars = days;
      _totalChars = days.values.fold<int>(0, (sum, value) => sum + value);
      await prefs.setInt(_schemaKey, _charsSchema);
      changes.value++;
      await _persist();
    } catch (_) {
      // 迁移失败就沿用旧数据，下次启动再试。
    }
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

/// 中文连续阅读约 300 字/分钟。
const double kReadingCharsPerSecond = 5;

/// 一次停留折算成多少字。
///
/// 只认「真的读了一段时间」：打开就跳走、快速划过，时长极小，折算出来也接近
/// 0；同时用本章正文长度封顶，读得再久也不会凭空多出一章之外的字数。
int estimateReadCharacters({
  required double seconds,
  required int chapterChars,
  int alreadyCounted = 0,
  double charsPerSecond = kReadingCharsPerSecond,
}) {
  if (seconds <= 0 || chapterChars <= 0) return 0;
  final remaining = chapterChars - alreadyCounted;
  if (remaining <= 0) return 0;
  final estimate = (seconds * charsPerSecond).round();
  if (estimate <= 0) return 0;
  return estimate > remaining ? remaining : estimate;
}

/// 把字符数格式化成「万」字单位，用于概览卡。
String formatCharacterCount(int chars) {
  if (chars < 10000) return '$chars 字';
  final wan = chars / 10000;
  return '${wan.toStringAsFixed(wan >= 100 ? 0 : 1)} 万字';
}
