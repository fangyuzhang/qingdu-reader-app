package com.fqapp.fqapp

import android.app.Activity
import android.os.Build
import android.util.Log
import android.view.Display

/**
 * 【轻读·高刷适配】把窗口刷新率偏好指到面板最高档。
 *
 * 背景：主流机型面板 90~180Hz，但国产 ROM（MIUI/ColorOS/OriginOS 的
 * 「智能刷新率」）默认把**未声明偏好**的应用锁在 60Hz——只有白名单大厂
 * 应用或显式投票的应用能跑到面板原生刷新率。Flutter 引擎本身跟随
 * Choreographer 的 vsync，不设帧率上限；缺的只是这一票。
 *
 * 策略：
 * - `preferredRefreshRate`（API 21+）投「本应用支持高刷」一票，厂商 DCS
 *   大多放行到面板原生档；
 * - 同分辨率里选最高刷新率模式，不跨分辨率（QHD+60 的设备不会被强行
 *   降到 FHD+120 换帧率，避免清晰度 surprise）；
 * - 面板最高档就是当前档（60Hz 面板、或系统默认已最高）时不干预、零
 *   属性变化；
 * - 静态内容（阅读正文）Flutter 不持续提交帧，Android 12+ 的投票机制
 *   仍可降档省电；代价是部分 ROM 上面板会保持高刷，属「高刷适配」的
 *   市场标准取舍。
 *
 * 匹配逻辑抽成纯函数（同 RendererCompatibility 的做法），可用本地
 * Display.Mode 替身单测，不依赖 Android statics。
 */
internal object RefreshRatePolicy {
    fun apply(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val display = currentDisplay(activity) ?: return
        val modes = display.supportedModes ?: return
        val current = display.mode ?: return
        val best = pickPreferredMode(current, modes.toList()) ?: run {
            Log.i(
                "FqRefreshRate",
                "policy=skip panel-max=${current.refreshRate}fps already-active",
            )
            return
        }
        val window = activity.window
        val attributes = window.attributes
        attributes.preferredDisplayModeId = best.modeId
        attributes.preferredRefreshRate = best.refreshRate
        window.attributes = attributes
        Log.i(
            "FqRefreshRate",
            "policy=high-frame-rate mode=${best.modeId} fps=${best.refreshRate} " +
                "was=${current.refreshRate}",
        )
    }

    private fun currentDisplay(activity: Activity): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }

    /**
     * 纯函数：与当前模式同分辨率的最高刷新率模式；面板最高档不高于当前
     * 档（差值容差 0.5Hz 抵浮点噪声）时返回 null = 不干预。
     */
    internal fun pickPreferredMode(
        current: Display.Mode,
        modes: List<Display.Mode>,
    ): Display.Mode? =
        modes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxByOrNull { it.refreshRate }
            ?.takeIf { it.refreshRate > current.refreshRate + 0.5f }
}
