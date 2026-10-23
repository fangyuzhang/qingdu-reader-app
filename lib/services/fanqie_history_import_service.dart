import 'package:flutter/services.dart';

import '../models/fanqie_history.dart';
import 'fanqie_library_import_service.dart';

class FanqieHistoryImportService {
  static const _account = MethodChannel('fqapp/fanqie_account');
  static const _files = MethodChannel('fqapp/library_backup');

  Future<FanqieHistoryPreview?> pickFile() async {
    final bytes = await _files.invokeMethod<Uint8List>('openBackup');
    return bytes == null ? null : FanqieHistoryPreview.fromBytes(bytes);
  }

  Future<int> merge(FanqieHistoryPreview preview) async {
    final records = [
      for (final record in preview.validated.history)
        {...record, 'author': record['author'] ?? '', 'fanqieImported': true},
    ];
    final result = await FanqieLibraryImportService().merge(
      FanqieImportPreview(records, 0, 0, 0),
    );
    return result.history;
  }

  Future<void> clearSession() => _account.invokeMethod<void>('clearSession');

  Future<void> cancelLogin() async {
    try {
      await _account.invokeMethod<void>('cancelLogin');
    } on PlatformException {
      // Cancellation still aborts Dart/Rust; closing a missing window is best effort.
    } on MissingPluginException {
      // Non-Android hosts have no native login window.
    }
  }
}
