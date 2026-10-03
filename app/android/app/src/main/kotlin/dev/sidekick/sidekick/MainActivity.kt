package dev.sidekick.sidekick

import android.Manifest
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.MediaScannerConnection
import android.media.MediaPlayer
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Hosts the Flutter UI and answers the `sidekick/android` channel, which the
 * Dart side uses for everything Android-specific: permissions, remote input,
 * the hotspot and the multicast lock.
 */
class MainActivity : FlutterActivity() {
    companion object {
        /** The channel to Dart while Sidekick runs (notification buttons use it). */
        var channel: MethodChannel? = null
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var hotspot: WifiManager.LocalOnlyHotspotReservation? = null
    /** Another device's hotspot this phone joined (see joinHotspot). */
    private var joined: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sidekick/android")
        channel = ch
        ch.setMethodCallHandler { call, result ->
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
                        "joinHotspot" -> joinHotspot(
                            call.argument<String>("ssid") ?: "",
                            call.argument<String>("passphrase") ?: "",
                            call.argument<String>("security") ?: "wpa2",
                            result,
                        )
                        "leaveHotspot" -> {
                            leaveHotspot()
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
                            call.argument<String>("path")?.let { playSound(it, call.argument<Boolean>("loud") == true) }
                            result.success(null)
                        }
                        "saveToGallery" -> saveToGallery(
                            call.argument<String>("path") ?: "",
                            call.argument<String>("mime") ?: "",
                            call.argument<Boolean>("video") ?: false,
                            result,
                        )
                        "requestNotifications" -> {
                            if (Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                            ) {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4)
                            }
                            result.success(null)
                        }
                        "startService" -> {
                            startForegroundService(Intent(this, SidekickService::class.java))
                            result.success(null)
                        }
                        "notifyOffer" -> {
                            Notifications.offer(
                                this,
                                call.argument<String>("id") ?: "",
                                call.argument<String>("title") ?: "",
                                call.argument<String>("body") ?: "",
                                (call.argument<Number>("timeout") ?: 60000).toLong(),
                            )
                            result.success(null)
                        }
                        "offerProgress" -> {
                            Notifications.progress(
                                this,
                                call.argument<String>("id") ?: "",
                                call.argument<String>("title") ?: "",
                                (call.argument<Number>("done") ?: 0).toLong(),
                                (call.argument<Number>("total") ?: 0).toLong(),
                            )
                            result.success(null)
                        }
                        "offerDone" -> {
                            Notifications.done(
                                this,
                                call.argument<String>("id") ?: "",
                                call.argument<String>("title") ?: "",
                                call.argument<String>("body") ?: "",
                            )
                            result.success(null)
                        }
                        "openFolder" -> {
                            openFolder(call.argument<String>("path") ?: "")
                            result.success(null)
                        }
                        "openGallery" -> {
                            openGallery(call.argument<String>("uri"))
                            result.success(null)
                        }
                        "cancelOffer" -> {
                            Notifications.cancel(this, call.argument<String>("id") ?: "")
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

    /** Back on the last screen sends Sidekick to the background (still
     *  receiving, with its notification) instead of closing it. */
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    override fun onDestroy() {
        if (isFinishing) {
            channel = null
            stopService(Intent(this, SidekickService::class.java))
        }
        hotspot?.close()
        hotspot = null
        leaveHotspot()
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

    /**
     * Joins another device's hotspot (an Android phone's, or a Windows PC's
     * Wi-Fi Direct network) for a direct link. Android asks the user once
     * ("Connect to device?"). The whole app then uses that network (Dart's
     * sockets too) until [leaveHotspot]: it has no internet, but it's where
     * the other device is.
     */
    private fun joinHotspot(ssid: String, passphrase: String, security: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("join", "Joining another device's Wi-Fi needs Android 10 or newer.", null)
            return
        }
        leaveHotspot()
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val specifier = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
            if (security == "wpa3") setWpa3Passphrase(passphrase) else setWpa2Passphrase(passphrase)
        }.build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val main = Handler(Looper.getMainLooper())
        var answered = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivity.bindProcessToNetwork(network)
                main.post {
                    if (!answered) {
                        answered = true
                        result.success(null)
                    }
                }
            }

            override fun onUnavailable() {
                main.post {
                    if (!answered) {
                        answered = true
                        result.error("join", "Couldn't join $ssid. Is Wi-Fi turned on?", null)
                    }
                }
            }

            override fun onLost(network: Network) {
                connectivity.bindProcessToNetwork(null)
            }
        }
        joined = callback
        try {
            connectivity.requestNetwork(request, callback, 60_000)
        } catch (e: RuntimeException) {
            joined = null
            result.error("join", "Couldn't join $ssid: ${e.message}", null)
        }
    }

    private fun leaveHotspot() {
        val callback = joined ?: return
        joined = null
        val connectivity = getSystemService(ConnectivityManager::class.java)
        connectivity.bindProcessToNetwork(null)
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (e: IllegalArgumentException) {
            // Already gone.
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
    private fun playSound(path: String, loud: Boolean = false) {
        val player = MediaPlayer()
        players.add(player)
        fun done(mp: MediaPlayer) {
            players.remove(mp)
            mp.release()
        }
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    // A ping goes on the alarm volume: heard even with the
                    // phone on silent, like Find My Device.
                    .setUsage(if (loud) AudioAttributes.USAGE_ALARM else AudioAttributes.USAGE_MEDIA)
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

    /**
     * Moves a received photo or video into the shared Pictures/Sidekick or
     * Movies/Sidekick folder, so the gallery shows it. On a worker thread:
     * videos can be big. The original is removed once the copy is in.
     */
    private fun saveToGallery(path: String, mime: String, video: Boolean, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        val folder = if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 3)
            result.error("denied", "allow Sidekick to use storage", null)
            return
        }
        Thread {
            try {
                val src = File(path)
                var saved: String? = null
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val collection = if (video) {
                        MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    } else {
                        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    }
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, src.name)
                        put(MediaStore.MediaColumns.MIME_TYPE, mime)
                        put(MediaStore.MediaColumns.RELATIVE_PATH, "$folder/Sidekick")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(collection, values) ?: throw IOException("the gallery refused it")
                    try {
                        val out = contentResolver.openOutputStream(uri) ?: throw IOException("couldn't write to the gallery")
                        out.use { o -> src.inputStream().use { it.copyTo(o) } }
                    } catch (e: Exception) {
                        contentResolver.delete(uri, null, null)
                        throw e
                    }
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                    saved = uri.toString()
                } else {
                    @Suppress("DEPRECATION")
                    val dir = File(Environment.getExternalStoragePublicDirectory(folder), "Sidekick").apply { mkdirs() }
                    var dest = File(dir, src.name)
                    var n = 1
                    while (dest.exists()) dest = File(dir, "${src.nameWithoutExtension} (${n++}).${src.extension}")
                    src.copyTo(dest)
                    MediaScannerConnection.scanFile(this, arrayOf(dest.absolutePath), arrayOf(mime), null)
                }
                src.delete()
                // If the gallery had already found the original (the public
                // Download folder), this makes it forget it.
                MediaScannerConnection.scanFile(this, arrayOf(src.absolutePath), null, null)
                main.post { result.success(saved) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message ?: "couldn't save it", null) }
            }
        }.start()
    }

    /**
     * The Files app at [folder], when it's in shared storage (Download/Sidekick
     * with "All files access"). A folder only Sidekick can see (Android/data)
     * can't be shown, so Files opens at Downloads instead.
     */
    private fun openFolder(folder: String) {
        val root = Environment.getExternalStorageDirectory().absolutePath
        val docs = "com.android.externalstorage.documents"
        val uri = if (folder.startsWith("$root/") && !folder.startsWith("$root/Android/")) {
            DocumentsContract.buildDocumentUri(docs, "primary:" + folder.removePrefix("$root/"))
        } else {
            DocumentsContract.buildDocumentUri(docs, "primary:" + Environment.DIRECTORY_DOWNLOADS)
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            open(intent)
        } catch (e: ActivityNotFoundException) {
            open(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
        }
    }

    /** The gallery at [uri] (a photo or video Sidekick put there), or just the gallery. */
    private fun openGallery(uri: String?) {
        try {
            if (uri != null) {
                open(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                return
            }
        } catch (e: ActivityNotFoundException) {
        }
        open(Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY))
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
