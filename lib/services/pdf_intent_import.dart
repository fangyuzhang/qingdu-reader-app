import 'package:flutter/services.dart';

import 'imported_book_store.dart';
import 'shelf_store.dart';

/// 消费原生侧「打开方式」交进来的 PDF（ACTION_VIEW，见
/// android/.../PdfViewIntentPlugin.kt）并导入书架。
///
/// 通道：`fqapp/pdf_view_intent`
/// - `consume` → String? 待处理的 content URI（取后即清）；
/// - `read(uri)` → {name, byteLength, bytes}，原生线程读字节（64MB 上限）。
///
/// 调用点在 RootShell：启动后首帧与 lifecycle resume 各消费一次，导入
/// 成功弹 SnackBar，失败弹可重试提示。
class PdfIntentImporter {
  static const _channel = MethodChannel('fqapp/pdf_view_intent');

  static bool _busy = false;

  /// 拉取并导入待处理的 PDF；没有待处理项时静默返回 null。
  static Future<String?> consumePending() async {
    if (_busy) return null;
    _busy = true;
    try {
      final uri = await _channel.invokeMethod<String>('consume');
      if (uri == null || uri.isEmpty) return null;
      final raw = await _channel.invokeMapMethod<Object?, Object?>('read', uri);
      if (raw == null) return null;
      final name = raw['name']?.toString() ?? 'book.pdf';
      final rawBytes = raw['bytes'];
      final bytes = rawBytes is Uint8List
          ? rawBytes
          : rawBytes is List<int>
          ? Uint8List.fromList(rawBytes)
          : null;
      if (bytes == null || bytes.isEmpty) return null;
      final book = await ImportedBookStore.instance.importBytes(
        fileName: name,
        bytes: bytes,
      );
      await ShelfStore.instance.add(book.toMediaItem());
      return book.title;
    } on PlatformException {
      return null;
    } finally {
      _busy = false;
    }
  }
}
