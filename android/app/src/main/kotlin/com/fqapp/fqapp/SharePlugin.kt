package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统分享桥（官方用 `Intent.ACTION_SEND` + `text/plain`，
 * 见 com.dragon.read.base.share2.utils.m0 的系统分享分支）。
 *
 * 只做一件事：把标题+正文交给系统选择器。没有可分享的应用时返回 false，
 * Dart 侧会降级为「复制链接」并提示，而不是假装分享成功。
 */
class SharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/share")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareText" -> shareText(call, result)
            "shareFile" -> shareFile(call, result)
            else -> result.notImplemented()
        }
    }

    /// 【青茄·笔记 PDF 分享】分享缓存目录里的文件（PDF 等）：
    /// 经 FileProvider 转 content URI（Android 7+ 禁 file://），交给系统
    /// 选择器；邮件类应用可直接读取（拷贝），失败如实返回 false。
    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        val path = call.argument<String>("path")
        if (ctx == null || path.isNullOrEmpty() || !File(path).exists()) {
            result.success(false)
            return
        }
        val mime = call.argument<String>("mime") ?: "application/pdf"
        val title = call.argument<String>("title") ?: ""
        try {
            val uri: Uri = FileProvider.getUriForFile(
                ctx,
                ctx.packageName + ".fileprovider",
                File(path),
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, title).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            result.success(false)
        }
    }

    private fun shareText(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.success(false)
            return
        }
        val title = call.argument<String>("title").orEmpty()
        val text = call.argument<String>("text").orEmpty()
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, title)
            putExtra(Intent.EXTRA_TEXT, text)
        }
        val chooser = Intent.createChooser(send, title).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            ctx.startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            result.success(false)
        }
    }
}
