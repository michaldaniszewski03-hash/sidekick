package dev.sidekick.sidekick

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder

/**
 * Sidekick's notifications: a small "Ready to receive" one while it runs
 * in the background ([SidekickService]), and a file request with Accept and
 * Decline, then its progress. The buttons come back through
 * [OfferActionReceiver] to Dart as `offerAction`.
 */
object Notifications {
    private const val STATUS = "status"
    private const val REQUESTS = "requests"
    const val STATUS_ID = 1

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    private fun channels(context: Context) {
        val nm = manager(context)
        if (nm.getNotificationChannel(STATUS) == null) {
            nm.createNotificationChannel(
                NotificationChannel(STATUS, "Ready to receive", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Shown while Sidekick runs in the background."
                    setShowBadge(false)
                },
            )
        }
        if (nm.getNotificationChannel(REQUESTS) == null) {
            nm.createNotificationChannel(
                NotificationChannel(REQUESTS, "File requests", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A device wants to send you files."
                },
            )
        }
    }

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun status(context: Context): Notification {
        channels(context)
        return Notification.Builder(context, STATUS)
            .setSmallIcon(R.drawable.ic_stat_sidekick)
            .setContentTitle("Sidekick")
            .setContentText("Ready to receive from your devices")
            .setContentIntent(openApp(context))
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private fun idFor(offer: String) = 1000 + (offer.hashCode() and 0xffff)

    private fun action(context: Context, offer: String, action: String, label: String): Notification.Action {
        val intent = Intent(context, OfferActionReceiver::class.java)
            .setAction("dev.sidekick.sidekick.OFFER_$action")
            .putExtra("id", offer)
            .putExtra("action", action)
        val pending = PendingIntent.getBroadcast(
            context,
            idFor(offer) * 2 + if (action == "accept") 1 else 0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(Icon.createWithResource(context, R.drawable.ic_stat_sidekick), label, pending)
            .build()
    }

    fun offer(context: Context, id: String, title: String, body: String, timeout: Long) {
        channels(context)
        val n = Notification.Builder(context, REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_sidekick)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp(context))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setTimeoutAfter(timeout)
            .addAction(action(context, id, "decline", "Decline"))
            .addAction(action(context, id, "accept", "Accept"))
            .build()
        manager(context).notify(idFor(id), n)
    }

    fun progress(context: Context, id: String, title: String, done: Long, total: Long) {
        channels(context)
        // Scaled so it fits an Int, whatever the size.
        val max = 1000
        val now = if (total > 0) (done * max / total).toInt().coerceIn(0, max) else 0
        val n = Notification.Builder(context, REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_sidekick)
            .setContentTitle(title)
            .setContentIntent(openApp(context))
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(max, now, total <= 0)
            .build()
        manager(context).notify(idFor(id), n)
    }

    fun done(context: Context, id: String, title: String, body: String, timeout: Long = 10_000) {
        channels(context)
        val n = Notification.Builder(context, REQUESTS)
            .setSmallIcon(R.drawable.ic_stat_sidekick)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp(context))
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setTimeoutAfter(timeout)
            .build()
        manager(context).notify(idFor(id), n)
    }

    fun cancel(context: Context, id: String) = manager(context).cancel(idFor(id))
}

/** Accept / Decline on a request notification: tells Dart, which answers. */
class OfferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val action = intent.getStringExtra("action") ?: return
        val channel = SidekickEngine.android
        if (channel == null) {
            // Sidekick isn't running any more: nobody to answer.
            Notifications.cancel(context, id)
            return
        }
        channel.invokeMethod("offerAction", mapOf("id" to id, "action" to action))
        if (action == "decline") Notifications.cancel(context, id)
    }
}

/**
 * Keeps Sidekick running while it's in the background, with a small
 * "Ready to receive" notification: after Home, after Sidekick is swiped away
 * from recent apps, and from boot (BootReceiver). It starts Sidekick's engine
 * itself when there's no screen (see KeepRunning.kt), and Android restarts
 * it if it has to stop it. Settings → Keep running in the background turns
 * it off.
 */
class SidekickService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Keeps Wi-Fi fully awake while Sidekick runs in the background: with the
     * screen off, Android lets Wi-Fi doze, and paired devices lose the phone
     * (missed announcements, slow or dropped connections).
     */
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        SidekickEngine.holdMulticast(this)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        // High performance, not low latency: the low-latency lock only works
        // while the app is on screen, and this is for when it isn't.
        @Suppress("DEPRECATION")
        val mode = android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = wifi.createWifiLock(mode, "sidekick:connected").apply {
            setReferenceCounted(false)
            try {
                acquire()
            } catch (e: SecurityException) {
                // No WAKE_LOCK permission: works, just less steadily.
            }
        }
    }

    override fun onDestroy() {
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        SidekickEngine.releaseMulticast()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = Notifications.status(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(Notifications.STATUS_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(Notifications.STATUS_ID, n)
        }
        // No screen (boot, or Android restarted the service): start Sidekick.
        SidekickEngine.get(applicationContext)
        return START_STICKY
    }
}
