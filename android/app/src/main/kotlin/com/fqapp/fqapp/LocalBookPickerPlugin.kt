package com.fqapp.fqapp

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

/** SAF picker for local novels. It grants access only to the document the user chose. */
class LocalBookPickerPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var appContext: android.content.Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/local_books")
        channel.setMethodCallHandler(this)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        cancelPending("设备配置变更，文件选择已取消")
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivity() {
        cancelPending("应用窗口已关闭")
        onDetachedFromActivityForConfigChanges()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelPending("应用已关闭")
        channel.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pickBookFile") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("PICKER_BUSY", "文件选择器正在使用", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "文件选择器尚未就绪", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("text/plain", "application/epub+zip", "application/zip", "application/octet-stream"),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (error: Exception) {
            pendingResult = null
            result.error("PICKER_UNAVAILABLE", error.message ?: "无法打开文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingResult = null
            result.success(null)
            return true
        }
        val uri = data.data!!
        ioExecutor.execute {
            val loaded = runCatching { readDocument(uri) }
            mainHandler.post {
                if (pendingResult !== result) return@post
                pendingResult = null
                loaded.fold(
                    onSuccess = { result.success(it) },
                    onFailure = {
                        result.error("BOOK_IMPORT_READ_FAILED", it.message ?: "读取书籍文件失败", null)
                    },
                )
            }
        }
        return true
    }

    private fun readDocument(uri: Uri): Map<String, Any?> {
        val resolver = appContext.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0)?.take(240) else null
        } ?: "book"
        val bytes = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= MAX_FILE_BYTES) { "请选择小于 32 MB 的 TXT 或 EPUB 文件" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("无法读取所选文件")
        val text = if (name.lowercase().endsWith(".txt")) decodeText(bytes) else null
        return if (text != null) {
            mapOf("name" to name, "byteLength" to bytes.size, "text" to text)
        } else {
            mapOf("name" to name, "byteLength" to bytes.size, "bytes" to bytes)
        }
    }

    /** TXT books commonly use GB18030/GBK; decode them on Android's charset provider. */
    private fun decodeText(bytes: ByteArray): String {
        if (bytes.size >= 3 &&
            bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() && bytes[2] == 0xbf.toByte()
        ) {
            return String(bytes, 3, bytes.size - 3, StandardCharsets.UTF_8)
        }
        if (bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte()) {
            return String(bytes, 2, bytes.size - 2, Charset.forName("UTF-16LE"))
        }
        if (bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte()) {
            return String(bytes, 2, bytes.size - 2, Charset.forName("UTF-16BE"))
        }
        val utf8 = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        try {
            return utf8.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) {
            val gb18030 = Charset.forName("GB18030").newDecoder()
                .onMalformedInput(CodingErrorAction.REPLACE)
                .onUnmappableCharacter(CodingErrorAction.REPLACE)
            return gb18030.decode(ByteBuffer.wrap(bytes)).toString()
        }
    }

    private fun cancelPending(message: String) {
        val pending = pendingResult ?: return
        pendingResult = null
        pending.error("PICKER_CANCELED", message, null)
    }

    companion object {
        private const val REQUEST_CODE = 53271
        private const val MAX_FILE_BYTES = 32 * 1024 * 1024
    }
}
