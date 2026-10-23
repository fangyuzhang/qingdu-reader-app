import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';
import 'reader_mark_style.dart';

/// One user-defined annotation badge ("批注类型"): the corner label plus the
/// colour it is drawn in.
@immutable
class ReaderMarkerType {
  const ReaderMarkerType({required this.label, required this.colorValue});

  final String label;
  final int colorValue;

  /// Stable key: the trimmed label. Preset types key on their label too, so
  /// a preset and a hand-typed type with the same word are the same bucket.
  String get key => label.trim();

  Map<String, dynamic> toMap() => {'label': label, 'color': colorValue};

  static ReaderMarkerType? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final label = raw['label']?.toString().trim() ?? '';
    if (label.isEmpty) return null;
    final color = raw['color'];
    return ReaderMarkerType(
      label: label,
      colorValue: color is num ? color.toInt() : readerDefaultAnnotationColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderMarkerType &&
      other.label == label &&
      other.colorValue == colorValue;

  @override
  int get hashCode => Object.hash(label, colorValue);
}

/// Persists the annotation types the reader invented while writing notes, so
/// the same badge can be reused and filtered in the notes page.
///
/// Only *custom* types live here: the built-in presets stay constants in
/// [readerMarkerPresets], and the notes page merges the two catalogs (plus any
/// label already present on a saved note) when it renders its chips.
///
/// Storage mirrors [ReaderAnnotationStore] / [ReaderUnderlineStore]: one
/// encrypted Hive box, gated by [hiveReady], so a page build before local data
/// is initialised (cold start first frame, widget tests) resolves immediately
/// instead of waiting on a store that cannot open yet.
class ReaderMarkerTypeStore {
  ReaderMarkerTypeStore({HiveInterface? hive}) : _hive = hive ?? Hive;

  static final ReaderMarkerTypeStore instance = ReaderMarkerTypeStore();

  static bool hiveReady = false;

  static const _boxName = 'reader_marker_types_v1';
  static const _listKey = 'types';
  static const int maxEntries = 24;

  final HiveInterface _hive;
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();
  Zone _writesZone = Zone.current;

  /// Bumped whenever the custom catalog changes; the notes page listens.
  final ValueNotifier<int> changes = ValueNotifier(0);

  bool _loaded = false;
  List<ReaderMarkerType> _types = const [];

  List<ReaderMarkerType> get types => _types;

  Future<Box<dynamic>?> _box() async {
    if (!hiveReady) return null;
    try {
      final pending = _opening ??= EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      );
      final box = await pending;
      if (box.isOpen) return box;
      _opening = null;
    } catch (_) {
      _opening = null;
      return null;
    }
    return _box();
  }

  Future<T> _serialize<T>(
    Future<T> Function(Box<dynamic>) action, {
    required T onUnavailable,
  }) {
    if (!identical(Zone.current, _writesZone)) {
      _writes = Future<void>.value();
      _writesZone = Zone.current;
    }
    final operation = _writes.then((_) async {
      final box = await _box();
      if (box == null) return onUnavailable;
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<ReaderMarkerType>> load() {
    if (_loaded) return Future.value(_types);
    return _serialize((box) async {
      final parsed = _decode(box.get(_listKey));
      _types = List.unmodifiable(parsed);
      _loaded = true;
      return _types;
    }, onUnavailable: const <ReaderMarkerType>[]).then((types) {
      // 存储还没就绪时也算「读过了」：目录为空，用户仍可新建类型。
      _loaded = true;
      return types;
    });
  }

  /// Adds (or recolours) a type. Returns the stored record.
  Future<ReaderMarkerType> add(String label, int colorValue) async {
    final type = ReaderMarkerType(label: label.trim(), colorValue: colorValue);
    if (type.label.isEmpty) return type;
    await load();
    final merged = <ReaderMarkerType>[
      for (final existing in _types)
        if (existing.key != type.key) existing,
      type,
    ];
    // 最近定义的排在前面，超出上限时丢掉最旧的。
    final ordered = merged.reversed.toList(growable: false);
    _types = List.unmodifiable(
      ordered.length > maxEntries ? ordered.sublist(0, maxEntries) : ordered,
    );
    changes.value++;
    await _serialize((box) async {
      await box.put(_listKey, [for (final entry in _types) entry.toMap()]);
    }, onUnavailable: null);
    return type;
  }

  Future<void> remove(String label) async {
    await load();
    final key = label.trim();
    final next = _types.where((type) => type.key != key).toList();
    if (next.length == _types.length) return;
    _types = List.unmodifiable(next);
    changes.value++;
    await _serialize((box) async {
      await box.put(_listKey, [for (final entry in _types) entry.toMap()]);
    }, onUnavailable: null);
  }

  static List<ReaderMarkerType> _decode(dynamic raw) {
    if (raw is! List) return const [];
    return [for (final entry in raw) ?ReaderMarkerType.fromMap(entry)];
  }

  /// Built-in presets followed by the custom types, de-duplicated by label.
  static List<ReaderMarkerType> catalog(Iterable<ReaderMarkerType> custom) {
    final seen = <String>{};
    final out = <ReaderMarkerType>[];
    for (final preset in readerMarkerPresets) {
      if (seen.add(preset.label)) {
        out.add(
          ReaderMarkerType(label: preset.label, colorValue: preset.colorValue),
        );
      }
    }
    for (final type in custom) {
      if (type.key.isNotEmpty && seen.add(type.key)) out.add(type);
    }
    return List.unmodifiable(out);
  }

  /// 调试/测试用：把当前目录直接写出（不经过 Hive）。
  @visibleForTesting
  void seedForTest(Iterable<ReaderMarkerType> types) {
    _types = List.unmodifiable(types);
    _loaded = true;
  }

  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _types = const [];
    changes.value = 0;
  }
}
