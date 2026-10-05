package dev.sidekick.sidekick

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Screen Mirroring from this phone to a paired computer (`sidekick/mirror`
 * on the engine; see lib/core/mirror.dart for the packets).
 *
 * Android asks the person holding the phone first ("Start now"), every
 * time; the picture then comes from a virtual display into an ImageReader,
 * in a foreground service with a "Showing your screen" notification and a
 * Stop button. Each `frame` call sends only the 64-pixel tiles that changed
 * since the last one, as exact pixels (RGBA, flagged in the packet).
 */
object ScreenMirror {
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var asking = false

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val app = context.applicationContext
        when (call.method) {
            "start" -> start(
                app,
                call.argument<Boolean>("sharp") == true,
                call.argument<String>("viewer") ?: "a computer",
                result,
            )
            "frame" -> {
                val service = ScreenCaptureService.instance
                if (service == null) {
                    result.error("stopped", "Screen sharing was stopped on this phone.", null)
                    return
                }
                service.handler.post {
                    service.frame(SystemClock.uptimeMillis() + 40) { packet -> main.post { result.success(packet) } }
                }
            }
            "keyframe" -> {
                ScreenCaptureService.instance?.keyframe = true
                result.success(null)
            }
            "sharp" -> {
                ScreenCaptureService.instance?.setSharp(call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "stop" -> {
                app.stopService(Intent(app, ScreenCaptureService::class.java))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(app: Context, sharp: Boolean, viewer: String, result: MethodChannel.Result) {
        // One session at a time: a new one replaces the last.
        app.stopService(Intent(app, ScreenCaptureService::class.java))
        val activity = MainActivity.current
        if (activity == null) {
            result.error("screen", "Open Sidekick on this phone, then try again.", null)
            return
        }
        fail("Another request replaced this one.")
        pending = result
        asking = true
        try {
            activity.askScreenCapture { code, data ->
                asking = false
                if (code != Activity.RESULT_OK || data == null) {
                    fail("Screen sharing wasn't allowed on this phone.")
                    return@askScreenCapture
                }
                ScreenCaptureService.onReady = { error ->
                    main.post {
                        val reply = pending
                        pending = null
                        if (error == null) reply?.success(null) else reply?.error("screen", error, null)
                    }
                }
                val intent = Intent(app, ScreenCaptureService::class.java)
                    .putExtra("code", code)
                    .putExtra("data", data)
                    .putExtra("sharp", sharp)
                    .putExtra("viewer", viewer)
                try {
                    app.startForegroundService(intent)
                } catch (e: Exception) {
                    ScreenCaptureService.onReady = null
                    fail("Couldn't start screen sharing on this phone.")
                }
            }
        } catch (e: Exception) {
            asking = false
            fail("Open Sidekick on this phone, then try again.")
        }
    }

    /** The screen closed while Android was asking. */
    fun cancelConsent() {
        if (asking) {
            asking = false
            fail("Screen sharing wasn't allowed on this phone.")
        }
    }

    private fun fail(message: String) {
        val reply = pending ?: return
        pending = null
        reply.error("screen", message, null)
    }
}

/**
 * Captures the screen while a computer mirrors it. Android only lets this
 * run as a foreground service of the "media projection" kind, started after
 * the person allowed it.
 */
class ScreenCaptureService : Service() {
    companion object {
        @Volatile
        var instance: ScreenCaptureService? = null

        /** Told once whether capture started (null) or why not. */
        @Volatile
        var onReady: ((String?) -> Unit)? = null

        private const val CHANNEL = "mirroring"
        private const val NOTIFICATION_ID = 7
        private const val STOP = "dev.sidekick.sidekick.STOP_MIRRORING"
        private const val TILE = 64
        private const val HEADER = 16
        private const val TILE_HEADER = 8
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val thread = HandlerThread("sidekick-mirror").apply { start() }
    val handler = Handler(thread.looper)

    @Volatile
    var keyframe = true

    /** Every pixel; otherwise half the size each way (4x fewer, still exact). */
    private var sharp = false
    private var width = 0
    private var height = 0

    /** The picture as last sent, RGBA, one Int per pixel (native order). */
    private var shown = IntArray(0)
    private var row = IntArray(0)
    private var dirty = BooleanArray(0)
    private var out = ByteArray(0)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        showNotification(intent?.getStringExtra("viewer") ?: "a computer")
        if (projection != null) return START_NOT_STICKY
        val code = intent?.getIntExtra("code", 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra("data", Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra("data")
        }
        sharp = intent?.getBooleanExtra("sharp", false) ?: false
        val projection = try {
            data?.let { getSystemService(MediaProjectionManager::class.java).getMediaProjection(code, it) }
        } catch (e: Exception) {
            null
        }
        if (projection == null) {
            ready("Couldn't start screen sharing on this phone.")
            stopSelf()
            return START_NOT_STICKY
        }
        this.projection = projection
        // Android 14+ wants this before the virtual display. Stopped from
        // the system (the status bar chip, the lock screen): stop here too.
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, handler)
        handler.post {
            try {
                configure()
                instance = this
                ready(null)
            } catch (e: Exception) {
                ready("Couldn't capture this screen: ${e.message}")
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun ready(error: String?) {
        val callback = onReady
        onReady = null
        callback?.invoke(error)
    }

    fun setSharp(on: Boolean) = handler.post {
        sharp = on
        configure()
    }

    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(WindowManager::class.java)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.maximumWindowMetrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
            Pair(metrics.widthPixels, metrics.heightPixels)
        }
    }

    /**
     * Sizes the capture to the screen as it is now (turned sideways, it
     * turns too) and the chosen sharpness. Cheap when nothing changed.
     */
    private fun configure() {
        val projection = projection ?: return
        val (sw, sh) = screenSize()
        val div = if (sharp) 1 else 2
        val w = (sw / div) and 1.inv()
        val h = (sh / div) and 1.inv()
        if (w == width && h == height && display != null) return
        val dpi = resources.displayMetrics.densityDpi / div
        val next = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        val current = display
        if (current == null) {
            display = projection.createVirtualDisplay(
                "Sidekick",
                w,
                h,
                dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                next.surface,
                null,
                handler,
            )
        } else {
            current.resize(w, h, dpi)
            current.surface = next.surface
        }
        reader?.close()
        reader = next
        width = w
        height = h
        shown = IntArray(w * h)
        row = IntArray(w)
        val tilesX = (w + TILE - 1) / TILE
        val tilesY = (h + TILE - 1) / TILE
        dirty = BooleanArray(tilesX * tilesY)
        out = ByteArray(HEADER + tilesX * tilesY * TILE_HEADER + w * h * 4)
        keyframe = true
    }

    /**
     * What changed since the last call, as a packet. Waits for a new picture
     * until [deadline] (so an idle screen isn't asked hundreds of times a
     * second), then answers with no tiles.
     */
    fun frame(deadline: Long, done: (ByteArray) -> Unit) {
        try {
            configure()
            val image = try {
                reader?.acquireLatestImage()
            } catch (e: IllegalStateException) {
                null
            }
            if (image == null) {
                if (keyframe && width > 0) {
                    done(packet(all = true))
                } else if (SystemClock.uptimeMillis() < deadline) {
                    handler.postDelayed({ frame(deadline, done) }, 6)
                } else {
                    done(packet(all = false))
                }
                return
            }
            try {
                if (image.width == width && image.height == height) compare(image)
            } finally {
                image.close()
            }
            done(packet(all = keyframe))
        } catch (e: Exception) {
            done(packet(all = false))
        }
    }

    /** Copies the new picture into [shown], marking the tiles that changed. */
    private fun compare(image: android.media.Image) {
        val plane = image.planes[0]
        val ints = plane.buffer.order(ByteOrder.nativeOrder()).asIntBuffer()
        val stride = plane.rowStride / 4
        val tilesX = (width + TILE - 1) / TILE
        for (y in 0 until height) {
            ints.position(y * stride)
            ints.get(row, 0, width)
            val base = y * width
            val band = (y / TILE) * tilesX
            for (tx in 0 until tilesX) {
                if (dirty[band + tx]) continue
                val x0 = tx * TILE
                val x1 = minOf(x0 + TILE, width)
                var x = x0
                while (x < x1) {
                    if (row[x] != shown[base + x]) {
                        dirty[band + tx] = true
                        break
                    }
                    x++
                }
            }
            System.arraycopy(row, 0, shown, base, width)
        }
    }

    /** The changed tiles (or [all] of them) as a packet; clears the marks. */
    private fun packet(all: Boolean): ByteArray {
        if (width == 0) return ByteArray(0)
        val le = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        val pixels = ByteBuffer.wrap(out).order(ByteOrder.nativeOrder()).asIntBuffer()
        val tilesX = (width + TILE - 1) / TILE
        val tilesY = (height + TILE - 1) / TILE
        var count = 0
        var o = HEADER
        for (ty in 0 until tilesY) {
            for (tx in 0 until tilesX) {
                val i = ty * tilesX + tx
                if (!all && !dirty[i]) continue
                dirty[i] = false
                val x0 = tx * TILE
                val y0 = ty * TILE
                val tw = minOf(TILE, width - x0)
                val th = minOf(TILE, height - y0)
                le.putShort(o, x0.toShort())
                le.putShort(o + 2, y0.toShort())
                le.putShort(o + 4, tw.toShort())
                le.putShort(o + 6, th.toShort())
                o += TILE_HEADER
                for (y in 0 until th) {
                    pixels.position(o / 4)
                    pixels.put(shown, (y0 + y) * width + x0, tw)
                    o += tw * 4
                }
                count++
            }
        }
        out[0] = 'S'.code.toByte()
        out[1] = 'K'.code.toByte()
        out[2] = 'M'.code.toByte()
        out[3] = '1'.code.toByte()
        le.putShort(4, width.toShort())
        le.putShort(6, height.toShort())
        le.putShort(8, (-1).toShort())
        le.putShort(10, (-1).toShort())
        le.putShort(12, count.toShort())
        // bit 0: a key frame; bit 1: RGBA rather than BGRA.
        le.putShort(14, ((if (all) 1 else 0) or 2).toShort())
        if (all) keyframe = false
        return out.copyOf(o)
    }

    private fun showNotification(viewer: String) {
        val notifications = getSystemService(NotificationManager::class.java)
        if (notifications.getNotificationChannel(CHANNEL) == null) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL, "Screen Mirroring", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while a computer sees this screen."
                },
            )
        }
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, ScreenCaptureService::class.java).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_sidekick)
            .setContentTitle("Showing your screen to $viewer")
            .setContentText("Sidekick · Screen Mirroring")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_stat_sidekick), "Stop", stop)
                    .build(),
            )
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        instance = null
        val display = display
        val reader = reader
        val projection = projection
        this.display = null
        this.reader = null
        this.projection = null
        handler.post {
            display?.release()
            reader?.close()
            projection?.stop()
            thread.quitSafely()
        }
        ready("Screen sharing stopped on this phone.")
        super.onDestroy()
    }
}
