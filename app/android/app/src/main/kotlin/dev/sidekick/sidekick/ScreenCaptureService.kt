package dev.sidekick.sidekick

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * Mirrors the phone's screen into an [ImageReader] while a paired device
 * views it. Android requires screen capture to run in a foreground service
 * (with a notification), started only after the user allowed it.
 */
class ScreenCaptureService : Service() {
    companion object {
        @Volatile
        var instance: ScreenCaptureService? = null

        /** Told once whether capture started (null) or why not. */
        @Volatile
        var onReady: ((String?) -> Unit)? = null

        private const val CHANNEL = "screen"
        private const val NOTIFICATION_ID = 42
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private val thread = HandlerThread("sidekick-screen").apply { start() }
    val handler = Handler(thread.looper)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        showNotification()
        if (projection != null) return START_NOT_STICKY
        val code = intent?.getIntExtra("code", 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra("data", Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra("data")
        }
        val maxWidth = intent?.getIntExtra("maxWidth", 1280) ?: 1280
        val manager = getSystemService(MediaProjectionManager::class.java)
        val projection = try {
            data?.let { manager.getMediaProjection(code, it) }
        } catch (e: Exception) {
            null
        }
        if (projection == null) {
            finish("Couldn't start screen sharing on the phone.")
            stopSelf()
            return START_NOT_STICKY
        }
        this.projection = projection
        // Android 14+ requires the callback before creating the display.
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, handler)

        val (width, height) = screenSize()
        val outWidth = minOf(width, maxWidth)
        val outHeight = (height.toLong() * outWidth / width).toInt()
        val reader = ImageReader.newInstance(outWidth, outHeight, PixelFormat.RGBA_8888, 2)
        this.reader = reader
        display = projection.createVirtualDisplay(
            "Sidekick",
            outWidth,
            outHeight,
            resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            handler,
        )
        instance = this
        finish(null)
        return START_NOT_STICKY
    }

    private fun finish(error: String?) {
        val callback = onReady
        onReady = null
        callback?.invoke(error)
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

    /** The newest frame as JPEG, or null if nothing changed. Call on [handler]. */
    fun frame(quality: Int): ByteArray? {
        val image = reader?.acquireLatestImage() ?: return null
        try {
            val plane = image.planes[0]
            val pixelStride = plane.pixelStride
            val rowPadding = plane.rowStride - pixelStride * image.width
            val padded = Bitmap.createBitmap(
                image.width + rowPadding / pixelStride,
                image.height,
                Bitmap.Config.ARGB_8888,
            )
            padded.copyPixelsFromBuffer(plane.buffer)
            val bitmap = if (rowPadding == 0) padded else Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(20, 95), out)
            if (bitmap !== padded) bitmap.recycle()
            padded.recycle()
            return out.toByteArray()
        } finally {
            image.close()
        }
    }

    private fun showNotification() {
        val notifications = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Sidekick is sharing your screen")
            .setContentText("A paired device can see this screen. Open Sidekick to stop.")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onDestroy() {
        instance = null
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection?.stop()
        projection = null
        finish("Screen sharing stopped on the phone.")
        thread.quitSafely()
        super.onDestroy()
    }
}
