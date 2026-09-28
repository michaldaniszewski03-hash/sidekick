package dev.sidekick.sidekick

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and answers the `sidekick/android` channel, which the
 * Dart side uses for everything Android-specific: permissions, remote input,
 * media sessions and the multicast lock.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private lateinit var media: MediaBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        media = MediaBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sidekick/android")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquireMulticastLock" -> {
                            acquireMulticastLock()
                            result.success(null)
                        }
                        "permissions" -> result.success(permissions())
                        "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                        "openAccessibilitySettings" -> {
                            open(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(null)
                        }
                        "openNotificationAccessSettings" -> {
                            open(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
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
                        "input" -> {
                            val service = SidekickAccessibilityService.instance
                            val args = call.arguments as? Map<*, *>
                            if (service != null && args != null) service.handle(args)
                            result.success(service != null)
                        }
                        "mediaStatus" -> result.success(media.status())
                        "mediaAction" -> {
                            media.perform(
                                call.argument<String>("action") ?: "",
                                call.argument<Number>("positionMs")?.toLong(),
                                call.argument<Number>("volume")?.toDouble(),
                            )
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("sidekick", e.message, null)
                }
            }
    }

    override fun onDestroy() {
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

    private fun permissions(): Map<String, Boolean> = mapOf(
        "accessibility" to (SidekickAccessibilityService.instance != null),
        "notifications" to hasNotificationAccess(),
        "allFiles" to hasAllFilesAccess(),
    )

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(this, MediaListenerService::class.java)
        return enabled.split(":").any { ComponentName.unflattenFromString(it) == me }
    }

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
