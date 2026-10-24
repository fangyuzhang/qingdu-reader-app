package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Handles ACTION_VIEW intents for application/pdf: file managers and browsers
 * can hand a PDF straight to the app, which imports it onto the shelf.
 *
 * The pending URI is captured by [MainActivity] (cold start + onNewIntent) and
 * pulled by Dart via `consume` (on app start and on lifecycle resume). Bytes
 * are read on demand through `read` on a worker thread with the same PDF size
 * cap as the SAF picker (64 MB).
 */
class PdfViewIntentPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    companion object {
        private const val MAX_PDF_BYTES = 64 * 1024 * 1024

        /** Set by MainActivity before the engine is ready; read once by Dart. */
        @Volatile
        var pendingUri: Uri? = null

        fun capture(intent: Intent?): Boolean {
            if (intent?.action != Intent.ACTION_VIEW) return false
            val type = intent.type ?: return false
            if (type != "application/pdf" && type != "application/x-pdf") return false
            val data = intent.data ?: return false
            pendingUri = data
            return true
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/pdf_view_intent")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consume" -> {
                val uri = pendingUri
                pendingUri = null
                result.success(uri?.toString())
            }
            "read" -> {
                val raw = call.arguments?.toString()
                val uri = raw?.let { runCatching { Uri.parse(it) }.getOrNull() }
                if (uri == null) {
                    result.error("BAD_ARGS", "文件地址无效", null)
                    return
                }
                ioExecutor.execute {
                    val loaded = runCatching { read(uri) }
                    mainHandler.post {
                        loaded.fold(
                            onSuccess = { result.success(it) },
                            onFailure = {
                                result.error(
                                    "PDF_INTENT_READ_FAILED",
                                    it.message ?: "读取 PDF 失败",
                                    null,
                                )
                            },
                        )
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun read(uri: Uri): Map<String, Any?> {
        val resolver = appContext.contentResolver
        val name = resolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0)?.take(240) else null
        } ?: "book.pdf"
        val bytes = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= MAX_PDF_BYTES) { "请选择小于 64 MB 的 PDF 文件" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("无法读取所选文件")
        return mapOf("name" to name, "byteLength" to bytes.size, "bytes" to bytes)
    }
}
