import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reading_stats_store.dart';

/// 【青茄重构·新增】阅读字数 / 连续打卡统计的单元测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ReadingStatsStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store.resetForTest();
    await store.init();
  });

  test('按天累加字数并给出总量', () async {
    store.addCharacters(1200);
    store.addCharacters(800);
    expect(store.totalChars, 2000);
    final today = store.dayChars.keys.single;
    expect(store.dayChars[today], 2000);
    await store.flush();
  });

  test('非正数被忽略（不会把统计写脏）', () {
    store.addCharacters(0);
    store.addCharacters(-100);
    expect(store.totalChars, 0);
    expect(store.dayChars, isEmpty);
  });

  test('连续打卡从今天往前数', () async {
    final now = DateTime.now();
    for (var ago = 0; ago < 3; ago++) {
      store.addCharacters(
        100,
        at: now.subtract(Duration(days: ago)),
      );
    }
    expect(store.currentStreakDays, 3);
    await store.flush();
  });

  test('今天没读但昨天读了，连击从昨天算', () async {
    final now = DateTime.now();
    for (var ago = 1; ago <= 2; ago++) {
      store.addCharacters(100, at: now.subtract(Duration(days: ago)));
    }
    expect(store.currentStreakDays, 2);
    await store.flush();
  });

  test('中断一天即归零', () async {
    final now = DateTime.now();
    store.addCharacters(100, at: now.subtract(const Duration(days: 3)));
    store.addCharacters(100, at: now.subtract(const Duration(days: 4)));
    expect(store.currentStreakDays, 0);
    await store.flush();
  });

  test('落盘后可重新载入（跨会话保持）', () async {
    store.addCharacters(4321);
    await store.flush();

    // 模拟重启：清内存后重新 init
    store.resetForTest();
    await store.init();
    expect(store.totalChars, 4321);
  });

  test('字数格式化', () {
    expect(formatCharacterCount(0), '0 字');
    expect(formatCharacterCount(9999), '9999 字');
    expect(formatCharacterCount(12345), '1.2 万字');
    expect(formatCharacterCount(1234567), '123 万字'); // ≥100 万不保留小数
    expect(formatCharacterCount(12345678), '1235 万字');
  });

  group('字数估算（时长 × 速度，按本章封顶）', () {
    test('几乎不停留时近似为 0，不会把整章算上', () {
      expect(estimateReadCharacters(seconds: 0, chapterChars: 6000), 0);
      expect(estimateReadCharacters(seconds: 1, chapterChars: 6000), 5);
    });

    test('按 300 字/分钟折算', () {
      expect(estimateReadCharacters(seconds: 60, chapterChars: 9000), 300);
      expect(estimateReadCharacters(seconds: 600, chapterChars: 9000), 3000);
    });

    test('不超过本章正文长度', () {
      expect(estimateReadCharacters(seconds: 3600, chapterChars: 800), 800);
    });

    test('同一章已计入的部分不再重复', () {
      expect(
        estimateReadCharacters(
          seconds: 60,
          chapterChars: 800,
          alreadyCounted: 600,
        ),
        200,
      );
      expect(
        estimateReadCharacters(
          seconds: 60,
          chapterChars: 800,
          alreadyCounted: 800,
        ),
        0,
      );
    });
  });

  test('迁移：旧的虚高字数按真实阅读时长重算，且只跑一次', () async {
    SharedPreferences.setMockInitialValues({
      'reading_stats_v1': jsonEncode({
        'days': {'2026-10-20': 300000, '2026-10-21': 214000},
        'total': 514000,
      }),
    });
    store.resetForTest();
    await store.init();
    expect(store.totalChars, 514000);

    await store.migrateToTimeEstimate({
      'book-1': {'2026-10-20': 600.0},
    });
    expect(store.dayChars['2026-10-20'], 3000);
    // 时长表里没有这天：留 1 字占位，只为保住连续打卡
    expect(store.dayChars['2026-10-21'], 1);
    expect(store.totalChars, 3001);

    await store.migrateToTimeEstimate({
      'book-1': {'2026-10-20': 600.0},
    });
    expect(store.totalChars, 3001);
  });
}
