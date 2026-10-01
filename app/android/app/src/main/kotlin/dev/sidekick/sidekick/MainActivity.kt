package dev.sidekick.sidekick

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and answers the `sidekick/android` channel, which the
 * Dart side uses for everything Android-specific: permissions, remote input,
 * the hotspot and the multicast lock.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var hotspot: WifiManager.LocalOnlyHotspotReservation? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sidekick/android")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquireMulticastLock" -> {
                            acquireMulticastLock()
                            result.success(null)
                        }
                        "startHotspot" -> startHotspot(result)
                        "stopHotspot" -> {
                            hotspot?.close()
                            hotspot = null
                            result.success(null)
                        }
                        "permissions" -> result.success(permissions())
                        "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                        "openAccessibilitySettings" -> {
                            open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(null)
                        }
                        "openAppSettings" -> {
                            open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "requestAllFilesAccess" -> {
                            requestAllFilesAccess()
                            result.success(null)
                        }
                        "playSound" -> {
                            call.argument<String>("path")?.let { playSound(it) }
                            result.success(null)
                        }
                        "input" -> {
                            val service = SidekickAccessibilityService.instance
                            val args = call.arguments as? Map<*, *>
                            if (service != null && args != null) service.handle(args)
                            result.success(service != null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("sidekick", e.message, null)
                }
            }
    }

    override fun onDestroy() {
        hotspot?.close()
        hotspot = null
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }

    private fun open(intent: Intent) {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("sidekick-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    /**
     * Opens a local-only hotspot: a private Wi-Fi network with a random name
     * and password that doesn't share mobile data. A PC joins it for a
     * direct link when the two devices aren't on the same Wi-Fi.
     */
    private fun startHotspot(result: MethodChannel.Result) {
        hotspot?.let {
            result.success(describe(it))
            return
        }
        val needed = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (checkSelfPermission(needed) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(needed), 2)
            result.error("permission", "Allow Sidekick to find nearby devices on your phone, then try again.", null)
            return
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        var answered = false
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    hotspot = reservation
                    if (!answered) {
                        answered = true
                        result.success(describe(reservation))
                    }
                }

                override fun onStopped() {
                    hotspot = null
                }

                override fun onFailed(reason: Int) {
                    if (answered) return
                    answered = true
                    val why = when (reason) {
                        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "hotspots are turned off on this phone"
                        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "turn off your regular hotspot first"
                        else -> "error $reason"
                    }
                    result.error("hotspot", "Couldn't open a hotspot: $why.", null)
                }
            }, Handler(Looper.getMainLooper()))
        } catch (e: SecurityException) {
            result.error("permission", "Turn on Location, then try again.", null)
        } catch (e: IllegalStateException) {
            result.error("hotspot", "A hotspot is already open.", null)
        }
    }

    @Suppress("DEPRECATION")
    private fun describe(reservation: WifiManager.LocalOnlyHotspotReservation): Map<String, String?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = reservation.softApConfiguration
            val security = when (config.securityType) {
                android.net.wifi.SoftApConfiguration.SECURITY_TYPE_WPA3_SAE -> "wpa3"
                else -> "wpa2"
            }
            return mapOf("ssid" to config.ssid, "passphrase" to config.passphrase, "security" to security)
        }
        val config = reservation.wifiConfiguration
        return mapOf(
            "ssid" to config?.SSID?.trim('"'),
            "passphrase" to config?.preSharedKey?.trim('"'),
            "security" to "wpa2",
        )
    }

    /** Sidekick's sounds, held until they finish: a MediaPlayer nobody
     *  holds can be garbage-collected mid-sound and go quiet. */
    private val players = mutableSetOf<MediaPlayer>()

    /** Sidekick's sounds (startup, a request, accepted, declined), on the
     *  media volume: the "system sounds" volume is muted on many phones. */
    private fun playSound(path: String) {
        val player = MediaPlayer()
        players.add(player)
        fun done(mp: MediaPlayer) {
            players.remove(mp)
            mp.release()
        }
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.setDataSource(path)
            player.setOnCompletionListener { done(it) }
            player.setOnErrorListener { mp, _, _ ->
                done(mp)
                true
            }
            player.prepare()
            player.start()
        } catch (e: Exception) {
            done(player)
        }
    }

    private fun permissions(): Map<String, Boolean> = mapOf(
        "accessibility" to (SidekickAccessibilityService.instance != null),
        "allFiles" to hasAllFilesAccess(),
    )

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                open(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (e: ActivityNotFoundException) {
                open(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                1,
            )
        }
    }
}
