package com.fqapp.fqapp

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * 平台导出通道（`fqapp/downloads`）：把整本 TXT 或笔记长图 PNG 写进系统「下载」目录。
 *
 * Android 10（API 29）起走 `MediaStore.Downloads`：不需要任何存储权限，
 * 文件在文件管理器的「下载」里直接可见；API 29 之前没有免权限的公共目录写法，
 * 落到应用自己的外部目录并回报 `public = false`，让 Dart 侧说清文件到底在哪，
 * 而不是谎报已经写进「下载」。
 *
 * 大书正文（整本可能十几 MB）不落在主线程上：写入在单线程池里做，结果回主线程。
 */
class DownloadsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/downloads")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val isImage = call.method == "saveImage"
        if (call.method != "saveText" && !isImage) {
            result.notImplemented()
            return
        }
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "导出通道未附着到引擎", null)
            return
        }
        val fileName = sanitize(call.argument<String>("fileName").orEmpty())
        // 【青茄·长图导出】saveImage = 笔记长图 PNG 直接入系统下载目录；
        // saveText = 整本书 TXT（原路径）。两者共用同一套落库/降级管线。
        val bytes: ByteArray = if (isImage) {
            call.argument<ByteArray>("bytes") ?: ByteArray(0)
        } else {
            call.argument<String>("text").orEmpty().toByteArray(Charsets.UTF_8)
        }
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        io.execute {
            val answer = try {
                save(
                    ctx, fileName, bytes,
                    if (isImage) "image/png" else "text/plain",
                    width, height,
                )
            } catch (error: Exception) {
                null
            }
            main.post {
                if (answer == null) {
                    result.error("write_failed", "无法写入系统下载目录", null)
                } else {
                    result.success(answer)
                }
            }
        }
    }

    private fun save(
        ctx: Context,
        fileName: String,
        bytes: ByteArray,
        mime: String,
        width: Int? = null,
        height: Int? = null,
    ): Map<String, Any> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = ctx.contentResolver
            val pending = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
                // 【青茄·长图导出修复】MIUI 实测会清理缺宽高的图片条目
                // （转正后行被删、文件消失，但 insert/write 均返回成功）：
                // 图片必须带 WIDTH/HEIGHT。
                if (width != null) put(MediaStore.MediaColumns.WIDTH, width)
                if (height != null) put(MediaStore.MediaColumns.HEIGHT, height)
            }
            val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, pending)
                ?: throw IOException("MediaStore 拒绝了导出条目")
            try {
                val out = resolver.openOutputStream(uri, "w")
                    ?: throw IOException("无法打开导出目标")
                out.use {
                    it.write(bytes)
                    it.flush()
                }
            } catch (error: Exception) {
                // A half-written pending row would show up as a broken file.
                resolver.delete(uri, null, null)
                throw error
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            // MediaStore 会为同名条目改名，所以回报的是登记后的真名。
            val stored = displayName(resolver, uri) ?: fileName
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            val finalPath = File(downloads, stored)
            // 【青茄·长图导出修复】个别 ROM 转正后静默清行：落盘实存校验，
            // 不存在就当失败（Dart 侧自动降级私有目录），绝不虚报成功。
            if (!finalPath.exists() || finalPath.length() != bytes.size.toLong()) {
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
                throw IOException("MediaStore 转正后文件不可见（ROM 清理）")
            }
            return mapOf(
                "path" to finalPath.absolutePath,
                "public" to true,
            )
        }

        val directory = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: ctx.filesDir
        val file = File(directory, fileName)
        file.writeBytes(bytes)
        return mapOf("path" to file.absolutePath, "public" to false)
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String? = resolver.query(
        uri,
        arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
        null,
        null,
        null,
    )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    /** 兜底清洗：路径分隔符绝不能进 DISPLAY_NAME；Dart 侧已做过一次同名折叠。 */
    private fun sanitize(raw: String): String {
        val name = raw.replace('/', '_').replace('\\', '_').trim()
        return name.ifEmpty { "book.txt" }
    }
}
