package dev.sidekick.sidekick

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Sidekick keeps running when it isn't on screen: after Home, after being
 * swiped away from recent apps, and from the moment the phone starts.
 *
 * The Dart side (the server paired devices talk to, the clipboard, Ping)
 * runs in one Flutter engine that outlives the screen: MainActivity borrows
 * it ([SidekickEngine.get]) instead of owning it, and SidekickService (a
 * foreground service with its "Ready to receive" notification) starts it on
 * its own when there's no screen, e.g. at boot.
 */
object SidekickEngine {
    private const val ID = "sidekick"

    /** `sidekick/android` on the engine: notification buttons answer through it. */
    var android: MethodChannel? = null
        private set

    fun get(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        // Things the Dart side needs whether or not there's a screen.
        MethodChannel(engine.dartExecutor.binaryMessenger, "sidekick/background").setMethodCallHandler { call, result ->
            when (call.method) {
                // What another device copied, into this phone's clipboard
                // (Flutter's own clipboard needs the screen).
                "setClipboard" -> {
                    val text = call.argument<String>("text") ?: ""
                    app.getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("Sidekick", text))
                    result.success(null)
                }
                "keepRunning" -> {
                    val on = call.argument<Boolean>("on") != false
                    val intent = Intent(app, SidekickService::class.java)
                    if (on) app.startForegroundService(intent) else app.stopService(intent)
                    result.success(null)
                }
                "batteryUnrestricted" -> result.success(Battery.unrestricted(app))
                "requestBatteryUnrestricted" -> {
                    Battery.request(app)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "sidekick/mirror").setMethodCallHandler { call, result ->
            ScreenMirror.handle(app, call, result)
        }
        android = MethodChannel(engine.dartExecutor.binaryMessenger, "sidekick/android")
        backgroundHandlers(app)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ID, engine)
        return engine
    }

    /**
     * What `sidekick/android` can do with no screen (MainActivity answers
     * everything while it's open): request notifications and sounds, so a
     * request or a Ping still reaches someone after boot or a swipe-away.
     */
    fun backgroundHandlers(context: Context) {
        val app = context.applicationContext
        android?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "notifyOffer" -> Notifications.offer(
                        app,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "",
                        (call.argument<Number>("timeout") ?: 60000).toLong(),
                    )
                    "offerProgress" -> Notifications.progress(
                        app,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("title") ?: "",
                        (call.argument<Number>("done") ?: 0).toLong(),
                        (call.argument<Number>("total") ?: 0).toLong(),
                    )
                    "offerDone" -> Notifications.done(
                        app,
                        call.argument<String>("id") ?: "",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "",
                        (call.argument<Number>("timeout") ?: 10000).toLong(),
                    )
                    "cancelOffer" -> Notifications.cancel(app, call.argument<String>("id") ?: "")
                    "playSound" -> call.argument<String>("path")?.let {
                        Sounds.playSound(it, call.argument<Boolean>("loud") == true)
                    }
                    "loopSound" -> call.argument<String>("path")?.let { Sounds.loopSound(it) }
                    "stopLoop" -> Sounds.stopLoop()
                    "requestNotifications" -> {}
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                result.error("sidekick", e.message, null)
            }
        }
    }

    /** Settings → Keep running (Flutter's shared_preferences), on unless turned off. */
    fun wanted(context: Context): Boolean =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.keepRunning", true)

    /** Discovery listens for multicast; Android drops it without this lock. */
    private var multicast: WifiManager.MulticastLock? = null

    fun holdMulticast(context: Context) {
        if (multicast?.isHeld == true) return
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicast = wifi.createMulticastLock("sidekick-background").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    fun releaseMulticast() {
        multicast?.let { if (it.isHeld) it.release() }
        multicast = null
    }
}

/** Battery optimisation: Android stops background apps it's "optimising". */
object Battery {
    fun unrestricted(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

    /** Android's own "Let Sidekick always run in the background?" question. */
    fun request(context: Context) {
        val ask = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(ask)
        } catch (e: Exception) {
            context.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

/** Starts Sidekick in the background when the phone starts (or Sidekick is updated). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) return
        if (!SidekickEngine.wanted(context)) return
        try {
            context.startForegroundService(Intent(context, SidekickService::class.java))
        } catch (e: Exception) {
            // Some phones refuse; Sidekick starts the next time it's opened.
        }
    }
}
