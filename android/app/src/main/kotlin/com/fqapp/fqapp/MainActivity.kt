package com.fqapp.fqapp

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 音量键翻页桥。Dart 侧在阅读页且开启“音量键翻页”时通过 setEnabled(true)
    // 通知原生拦截音量键，原生 dispatchKeyEvent 吃掉按键（系统音量不再变化）并通过
    // volumeKey 回调让 Dart 翻页。该方案在原生层拦截，不受 Flutter 生命周期
    // 过渡事件漏发导致的 HardwareKeyboard 派发丢失影响。
    private var volumeKeyEnabled = false
    private var volumeChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 【青茄·启动配色】系统深色 + App 浅色（或反过来）时，启动窗口的
        // windowBackground 只跟随系统，进 App 那一瞬间顶部状态栏会先闪一条
        // 系统底色（浅色系统上常见为一条黑边）。这里在 Flutter 首帧之前按
        // 「App 自己保存的主题」把窗口底色与状态栏图标亮度摆正，之后由页面
        // 内的 SystemUiOverlayStyle 接管。
        applyStartupThemeColors()
        // 【青茄·高刷适配】向系统声明刷新率偏好，逃出国产 ROM 对未声明
        // 应用的 60Hz 锁；60Hz 面板自动跳过（见 RefreshRatePolicy）。
        RefreshRatePolicy.apply(this)
        // 文件管理器/浏览器「打开方式」交给本应用的 PDF：冷启动路径，
        // 引擎就绪前先记在插件静态字段里，Dart 启动后 consume。
        PdfViewIntentPlugin.capture(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 应用已在运行时再收到 ACTION_VIEW PDF 的热启动路径。
        PdfViewIntentPlugin.capture(intent)
    }

    private fun applyStartupThemeColors() {
        val mode = savedThemeMode()
        val dark = when (mode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        val windowColor =
            if (dark) Color.parseColor("#201F1D") else Color.parseColor("#FAF9F6")
        window.setBackgroundDrawable(ColorDrawable(windowColor))
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        // 【青茄修复·冷启动灰条】Android 10+ 对「透明状态栏」默认开启对比度
        // 保护——系统会在状态栏后面垫一层半透明灰色渐变 scrim，这就是用户
        // 看到的小灰条（进过阅读器后消失，是因为阅读页状态栏用不透明正文
        // 底色，不触发 scrim）。必须显式声明不强制对比度，从窗口创建起就
        // 关掉，早于 Flutter 首帧。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = !dark
            isAppearanceLightNavigationBars = !dark
        }
    }

    /// Flutter 侧 SharedPreferences 落到 `FlutterSharedPreferences`，键前缀 `flutter.`。
    private fun savedThemeMode(): String? = try {
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getString("flutter.theme_mode", null)
    } catch (_: Throwable) {
        null
    }

    override fun getFlutterShellArgs(): FlutterShellArgs = super.getFlutterShellArgs().also {
        // Runs before the engine/FlutterLoader starts; configureFlutterEngine is
        // too late to select the process-wide rendering backend.
        RendererCompatibility.configure(it)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer host for encrypted audiobook playback (CENC streaming decrypt).
        flutterEngine.plugins.add(NativePlayerPlugin())
        flutterEngine.plugins.add(ReaderDevicePlugin())
        flutterEngine.plugins.add(SystemTtsPlugin())
        flutterEngine.plugins.add(LocalBookPickerPlugin())
        // 文件管理器/浏览器 ACTION_VIEW PDF 的导入通道（配合 manifest 的
        // application/pdf intent-filter）。
        flutterEngine.plugins.add(PdfViewIntentPlugin())
        flutterEngine.plugins.add(LibraryBackupPlugin())
        flutterEngine.plugins.add(FanqieAccountPlugin())
        // 官方系统分享是 Intent.ACTION_SEND；没有可分享的应用时回 false。
        flutterEngine.plugins.add(SharePlugin())
        // 整本 TXT 导出：MediaStore.Downloads 或应用外部目录，见 DownloadsPlugin。
        flutterEngine.plugins.add(DownloadsPlugin())
        // 海信墨水屏整屏刷新（压残影）：反射调用厂商 EPD 接口。
        flutterEngine.plugins.add(EinkRefreshPlugin())

        // 音量键翻页通道：Dart -> 原生 setEnabled 控制是否拦截；原生 -> Dart
        // volumeKey 回调翻页方向（+1 下一页 / -1 上一页）。
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fqapp/volume-key",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        volumeKeyEnabled = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (volumeKeyEnabled && event != null) {
            val key = event.keyCode
            if (key == KeyEvent.KEYCODE_VOLUME_DOWN || key == KeyEvent.KEYCODE_VOLUME_UP) {
                // 仅在首次按下（非长按重复）触发一次翻页，避免按住连翻。
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    val direction = if (key == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1
                    volumeChannel?.invokeMethod("volumeKey", direction)
                }
                // 无论按下/抬起都吃掉音量键，系统音量面板不再弹出。
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
