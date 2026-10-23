import 'package:flutter/foundation.dart';

/// Result of asking the host OS to open its share sheet.
enum ShareLaunchOutcome { launched, unavailable }

/// Minimal system-share bridge. The Android host supplies the implementation.
@immutable
class SharePlusLite {
  const SharePlusLite._();

  static Future<bool> Function({required String title, required String text})?
  handler;

  static Future<ShareLaunchOutcome> share({
    required String title,
    required String text,
  }) async {
    final callback = handler;
    if (callback == null) return ShareLaunchOutcome.unavailable;
    try {
      final launched = await callback(title: title, text: text);
      return launched
          ? ShareLaunchOutcome.launched
          : ShareLaunchOutcome.unavailable;
    } catch (_) {
      return ShareLaunchOutcome.unavailable;
    }
  }
}
