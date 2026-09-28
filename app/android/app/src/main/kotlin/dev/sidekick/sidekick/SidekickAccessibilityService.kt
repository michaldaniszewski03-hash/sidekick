package dev.sidekick.sidekick

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Turns remote mouse/keyboard messages from a paired PC into touches on this
 * phone. A small dot shows where the "mouse" is; clicks become taps at the
 * dot, the wheel becomes swipes, and keys map to Back/Home/Recents or type
 * into the focused text field.
 *
 * Messages use the same JSON shape as the network protocol:
 * `{"t":"move","dx":3,"dy":-2}`, `{"t":"click","b":"left"}`, and so on.
 */
class SidekickAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: SidekickAccessibilityService? = null
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private var cursor: View? = null
    private var cursorParams: WindowManager.LayoutParams? = null
    private var x = 0f
    private var y = 0f
    private var dragStart: Pair<Float, Float>? = null
    private var pendingScroll = 0f

    private val hideCursor = Runnable { cursor?.visibility = View.GONE }
    private val flushScroll = Runnable { scrollNow() }

    private val windowManager: WindowManager
        get() = getSystemService(WINDOW_SERVICE) as WindowManager

    private val density: Float
        get() = resources.displayMetrics.density

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val (w, h) = screenSize()
        x = w / 2f
        y = h / 2f
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        cleanUp()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        cleanUp()
        super.onDestroy()
    }

    private fun cleanUp() {
        instance = null
        handler.removeCallbacksAndMessages(null)
        cursor?.let { runCatching { windowManager.removeView(it) } }
        cursor = null
        cursorParams = null
    }

    private fun screenSize(): Pair<Int, Int> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            val metrics = resources.displayMetrics
            Pair(metrics.widthPixels, metrics.heightPixels)
        }

    fun handle(msg: Map<*, *>) {
        fun num(key: String): Float = (msg[key] as? Number)?.toFloat() ?: 0f
        when (msg["t"]) {
            "move" -> moveBy(num("dx"), num("dy"))
            "click" -> if (msg["b"] == "right") longPress() else tap(((msg["n"] as? Number)?.toInt() ?: 1))
            "down" -> dragStart = Pair(x, y)
            "up" -> {
                val start = dragStart
                dragStart = null
                if (start != null) swipe(start.first, start.second, x, y, 400)
            }
            "scroll" -> {
                pendingScroll += num("dy")
                handler.removeCallbacks(flushScroll)
                handler.postDelayed(flushScroll, 60)
            }
            "key" -> {
                val mods = (msg["mods"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                key((msg["k"] as? String ?: "").lowercase(), mods)
            }
            "text" -> typeText(msg["s"] as? String ?: "")
        }
    }

    // ---------------------------------------------------------------- pointer

    private fun moveBy(dx: Float, dy: Float) {
        // PC mouse deltas are in desktop pixels; phones have dense screens.
        val speed = density * 0.9f
        val (w, h) = screenSize()
        x = (x + dx * speed).coerceIn(0f, w - 1f)
        y = (y + dy * speed).coerceIn(0f, h - 1f)
        showCursor()
    }

    private fun showCursor() {
        val size = (20 * density).toInt()
        if (cursor == null) {
            val view = View(this).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(Color.argb(190, 103, 80, 164))
                    setStroke((2 * density).toInt(), Color.WHITE)
                }
            }
            val params = WindowManager.LayoutParams(
                size,
                size,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.TOP or Gravity.START }
            windowManager.addView(view, params)
            cursor = view
            cursorParams = params
        }
        val view = cursor ?: return
        val params = cursorParams ?: return
        params.x = (x - size / 2f).toInt()
        params.y = (y - size / 2f).toInt()
        view.visibility = View.VISIBLE
        windowManager.updateViewLayout(view, params)
        handler.removeCallbacks(hideCursor)
        handler.postDelayed(hideCursor, 8000)
    }

    private fun dispatch(vararg strokes: GestureDescription.StrokeDescription) {
        val builder = GestureDescription.Builder()
        strokes.forEach { builder.addStroke(it) }
        dispatchGesture(builder.build(), null, null)
    }

    private fun point(px: Float, py: Float) = Path().apply { moveTo(px, py) }

    private fun tap(count: Int) {
        val strokes = (0 until count.coerceIn(1, 3)).map { i ->
            GestureDescription.StrokeDescription(point(x, y), i * 150L, 40L)
        }
        dispatch(*strokes.toTypedArray())
        showCursor()
    }

    private fun longPress() {
        dispatch(GestureDescription.StrokeDescription(point(x, y), 0L, 700L))
        showCursor()
    }

    private fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, duration: Long) {
        if (hypot(x2 - x1, y2 - y1) < 8 * density) {
            // Barely moved while "held": treat it as a long press.
            dispatch(GestureDescription.StrokeDescription(point(x2, y2), 0L, 700L))
            return
        }
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatch(GestureDescription.StrokeDescription(path, 0L, duration))
    }

    private fun scrollNow() {
        val (_, h) = screenSize()
        // 120 wheel units per notch. Wheel "up" (positive) shows content
        // above, so the finger moves down the screen.
        val distance = (pendingScroll * 1.5f).coerceIn(-h * 0.6f, h * 0.6f)
        pendingScroll = 0f
        if (abs(distance) < 5f) return
        val margin = 10f
        val startY = (y - distance / 2).coerceIn(margin, h - margin)
        val endY = (y + distance / 2).coerceIn(margin, h - margin)
        swipe(x, startY, x, endY, 250)
    }

    // ---------------------------------------------------------------- keys

    private fun focusedInput(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun key(k: String, mods: List<String>) {
        val ctrl = "ctrl" in mods
        when {
            ctrl && k == "c" -> focusedInput()?.performAction(AccessibilityNodeInfo.ACTION_COPY)
            ctrl && k == "v" -> focusedInput()?.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            ctrl && k == "x" -> focusedInput()?.performAction(AccessibilityNodeInfo.ACTION_CUT)
            ctrl && k == "a" -> focusedInput()?.let { node -> select(node, 0, currentText(node).length) }
            "alt" in mods && k == "tab" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "win" in mods && k == "l" -> lockScreen()
            k == "esc" || k == "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            k == "win" || k == "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            k == "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            k == "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            k == "quicksettings" -> performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
            k == "lock" -> lockScreen()
            k == "backspace" -> focusedInput()?.let { backspace(it) }
            k == "enter" -> enter()
        }
    }

    private fun lockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
    }

    private fun enter() {
        val node = focusedInput() ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
        } else {
            typeText("\n")
        }
    }

    private fun currentText(node: AccessibilityNodeInfo): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.isShowingHintText) return ""
        return node.text?.toString() ?: ""
    }

    /** The selection if we know it, otherwise the end of the text. */
    private fun selection(node: AccessibilityNodeInfo, text: String): Pair<Int, Int> {
        val start = node.textSelectionStart
        val end = node.textSelectionEnd
        return if (start in 0..text.length && end in start..text.length) Pair(start, end) else Pair(text.length, text.length)
    }

    private fun select(node: AccessibilityNodeInfo, start: Int, end: Int) {
        val args = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }

    private fun replaceText(node: AccessibilityNodeInfo, text: String, caret: Int) {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        select(node, caret, caret)
    }

    private fun typeText(s: String) {
        if (s.isEmpty()) return
        val node = focusedInput() ?: return
        if (!node.isEditable) return
        val text = currentText(node)
        val (start, end) = selection(node, text)
        replaceText(node, text.substring(0, start) + s + text.substring(end), start + s.length)
    }

    private fun backspace(node: AccessibilityNodeInfo) {
        if (!node.isEditable) return
        val text = currentText(node)
        val (start, end) = selection(node, text)
        when {
            start < end -> replaceText(node, text.substring(0, start) + text.substring(end), start)
            start > 0 -> replaceText(node, text.substring(0, start - 1) + text.substring(start), start - 1)
        }
    }
}
