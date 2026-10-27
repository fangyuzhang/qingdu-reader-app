import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of asking the host OS to open its share sheet.
enum ShareLaunchOutcome { launched, unavailable }

/// Minimal system-share bridge. The Android host supplies the implementation.
@immutable
class SharePlusLite {
  const SharePlusLite._();

  static Future<bool> Function({required String title, required String text})?
  handler;

  static const _shareChannel = MethodChannel('fqapp/share');

  /// 【轻读·笔记 PDF 分享】把已生成的文件（PDF 等）交给系统分享面板。
  /// Android 侧经 FileProvider 转 content URI（见 SharePlugin.shareFile）。
  /// 桌面/测试宿主无插件 → unavailable（与文本分享同语义）。
  static Future<ShareLaunchOutcome> shareFile({
    required String path,
    required String mime,
    required String title,
  }) async {
    try {
      final launched = await _shareChannel.invokeMethod<bool>('shareFile', {
        'path': path,
        'mime': mime,
        'title': title,
      });
      return launched == true
          ? ShareLaunchOutcome.launched
          : ShareLaunchOutcome.unavailable;
    } on MissingPluginException {
      return ShareLaunchOutcome.unavailable;
    } on PlatformException {
      return ShareLaunchOutcome.unavailable;
    }
  }

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
