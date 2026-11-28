package dev.bistre.bistre_app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Opt-in Android AccessibilityService powering Bistre Phone use.
 * Every action is explicitly approved in Rust before this bridge is called, and screenshots
 * are downscaled to <= 1280 px on the long edge and returned transiently (never saved to disk).
 */
class BistrePhoneUseService : AccessibilityService() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Passive: actions are driven strictly on explicit user-approved requests.
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        executor.shutdownNow()
        super.onDestroy()
    }

    fun executeAction(
        args: Map<String, Any?>,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        val action = (args["action"] as? String)?.trim().orEmpty()
        when (action) {
            "screenshot" -> captureScreenshot(callback)
            "click" -> dispatchTap(
                (args["x"] as? Number)?.toFloat() ?: 0f,
                (args["y"] as? Number)?.toFloat() ?: 0f,
                doubleTap = false,
                callback = callback,
            )
            "double_click" -> dispatchTap(
                (args["x"] as? Number)?.toFloat() ?: 0f,
                (args["y"] as? Number)?.toFloat() ?: 0f,
                doubleTap = true,
                callback = callback,
            )
            "scroll" -> {
                val x = (args["x"] as? Number)?.toFloat() ?: 0f
                val y = (args["y"] as? Number)?.toFloat() ?: 0f
                val dx = (args["delta_x"] as? Number)?.toFloat() ?: 0f
                val dy = (args["delta_y"] as? Number)?.toFloat() ?: 0f
                val path = Path().apply {
                    moveTo(x, y)
                    lineTo((x - dx).coerceAtLeast(0f), (y - dy).coerceAtLeast(0f))
                }
                val gesture = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0L, 220L))
                    .build()
                dispatchGesture(gesture, object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        callback(mapOf("ok" to true, "outputText" to "Scrolled at ($x, $y)."))
                    }
                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        callback(mapOf("ok" to false, "outputText" to "Scroll gesture cancelled."))
                    }
                }, null)
            }
            "type" -> {
                val text = (args["text"] as? String)?.take(4000).orEmpty()
                val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                if (focused == null) {
                    callback(mapOf("ok" to false, "outputText" to "No focused text field."))
                    return
                }
                val b = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                }
                val ok = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b)
                callback(mapOf("ok" to ok, "outputText" to if (ok) "Typed text." else "Set text failed."))
            }
            "key" -> {
                val key = (args["key"] as? String)?.trim()?.lowercase().orEmpty()
                val global = when (key) {
                    "back" -> GLOBAL_ACTION_BACK
                    "home" -> GLOBAL_ACTION_HOME
                    "recents" -> GLOBAL_ACTION_RECENTS
                    "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
                    else -> null
                }
                if (global == null) {
                    callback(mapOf("ok" to false, "outputText" to "Unsupported Android key: $key"))
                    return
                }
                val ok = performGlobalAction(global)
                callback(mapOf("ok" to ok, "outputText" to if (ok) "Performed $key." else "Key action failed."))
            }
            else -> callback(mapOf("ok" to false, "outputText" to "Unsupported Phone use action: $action"))
        }
    }

    private fun dispatchTap(
        x: Float,
        y: Float,
        doubleTap: Boolean,
        callback: (Map<String, Any?>) -> Unit,
    ) {
        val builder = GestureDescription.Builder()
        val p1 = Path().apply { moveTo(x, y) }
        builder.addStroke(GestureDescription.StrokeDescription(p1, 0L, 60L))
        if (doubleTap) {
            val p2 = Path().apply { moveTo(x, y) }
            builder.addStroke(GestureDescription.StrokeDescription(p2, 120L, 60L))
        }
        dispatchGesture(builder.build(), object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                callback(mapOf("ok" to true, "outputText" to "Tapped ($x, $y)."))
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                callback(mapOf("ok" to false, "outputText" to "Tap gesture cancelled."))
            }
        }, null)
    }

    private fun captureScreenshot(callback: (Map<String, Any?>) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            callback(mapOf("ok" to false, "outputText" to "Screenshots require Android 11 or newer."))
            return
        }
        takeScreenshot(Display.DEFAULT_DISPLAY, executor, object : TakeScreenshotCallback {
            override fun onSuccess(screenshot: ScreenshotResult) {
                val hw = Bitmap.wrapHardwareBuffer(screenshot.hardwareBuffer, screenshot.colorSpace)
                screenshot.hardwareBuffer.close()
                if (hw == null) {
                    callback(mapOf("ok" to false, "outputText" to "Screenshot buffer empty."))
                    return
                }
                val soft = hw.copy(Bitmap.Config.ARGB_8888, false)
                hw.recycle()
                val maxEdge = 1280
                val longEdge = maxOf(soft.width, soft.height)
                val scaled = if (longEdge > maxEdge) {
                    val ratio = maxEdge.toFloat() / longEdge.toFloat()
                    Bitmap.createScaledBitmap(
                        soft,
                        (soft.width * ratio).toInt().coerceAtLeast(1),
                        (soft.height * ratio).toInt().coerceAtLeast(1),
                        true,
                    )
                } else {
                    soft
                }
                val baos = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.PNG, 100, baos)
                val w = scaled.width
                val h = scaled.height
                if (scaled !== soft) scaled.recycle()
                soft.recycle()
                val b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP)
                callback(
                    mapOf(
                        "ok" to true,
                        "outputText" to "Captured ${w}x${h} phone screenshot.",
                        "imageBase64" to b64,
                    ),
                )
            }

            override fun onFailure(errorCode: Int) {
                callback(mapOf("ok" to false, "outputText" to "Screenshot failed (code $errorCode)."))
            }
        })
    }

    companion object {
        @Volatile
        var instance: BistrePhoneUseService? = null
    }
}
