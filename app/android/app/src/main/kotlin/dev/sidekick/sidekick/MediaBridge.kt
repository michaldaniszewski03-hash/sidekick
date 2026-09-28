package dev.sidekick.sidekick

import android.content.ComponentName
import android.content.Context
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.view.KeyEvent
import kotlin.math.roundToInt

/**
 * Only exists so Android lets us read other apps' media sessions once the
 * user grants Sidekick notification access. It doesn't read notifications.
 */
class MediaListenerService : NotificationListenerService()

/**
 * What's playing on this phone, and control over it. Answers with the same
 * JSON fields as the Windows helper (see MediaStatus in models.dart).
 *
 * Volume and play/pause/next/previous work without any permission; title,
 * position and seeking need notification access.
 */
class MediaBridge(private val context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val sessions = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager

    private fun controller(): MediaController? = try {
        val active = sessions.getActiveSessions(ComponentName(context, MediaListenerService::class.java))
        active.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: active.firstOrNull()
    } catch (e: SecurityException) {
        null // Notification access not granted.
    }

    fun status(): Map<String, Any?> {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val out = mutableMapOf<String, Any?>(
            "ok" to true,
            "available" to false,
            "volume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max,
            "muted" to audio.isStreamMute(AudioManager.STREAM_MUSIC),
        )
        val c = controller() ?: return out
        val meta = c.metadata
        val state = c.playbackState
        val duration = meta?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.coerceAtLeast(0L) ?: 0L

        var position = state?.position ?: 0L
        if (state != null && state.state == PlaybackState.STATE_PLAYING && state.lastPositionUpdateTime > 0) {
            position += ((SystemClock.elapsedRealtime() - state.lastPositionUpdateTime) * state.playbackSpeed).toLong()
        }
        if (duration > 0) position = position.coerceIn(0L, duration)

        out["available"] = true
        out["app"] = appLabel(c.packageName)
        out["title"] = meta?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
        out["artist"] = meta?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: meta?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        out["status"] = when (state?.state) {
            PlaybackState.STATE_PLAYING, PlaybackState.STATE_BUFFERING -> "playing"
            PlaybackState.STATE_PAUSED -> "paused"
            PlaybackState.STATE_STOPPED, PlaybackState.STATE_NONE -> "stopped"
            else -> "unknown"
        }
        out["positionMs"] = position
        out["durationMs"] = duration
        out["canSeek"] = state != null && duration > 0 && (state.actions and PlaybackState.ACTION_SEEK_TO) != 0L
        return out
    }

    fun perform(action: String, positionMs: Long?, volume: Double?) {
        val c = controller()
        val controls = c?.transportControls
        val playing = c?.playbackState?.state == PlaybackState.STATE_PLAYING
        when (action) {
            "playPause" -> when {
                controls == null -> mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                playing -> controls.pause()
                else -> controls.play()
            }
            "play" -> controls?.play() ?: mediaKey(KeyEvent.KEYCODE_MEDIA_PLAY)
            "pause" -> controls?.pause() ?: mediaKey(KeyEvent.KEYCODE_MEDIA_PAUSE)
            "next" -> controls?.skipToNext() ?: mediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
            "previous" -> controls?.skipToPrevious() ?: mediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            "stop" -> controls?.stop() ?: mediaKey(KeyEvent.KEYCODE_MEDIA_STOP)
            "seek" -> if (positionMs != null) controls?.seekTo(positionMs)
            "setVolume" -> if (volume != null) {
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val level = (volume.coerceIn(0.0, 1.0) * max).roundToInt()
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, level, AudioManager.FLAG_SHOW_UI)
            }
            "volumeUp" -> adjust(AudioManager.ADJUST_RAISE)
            "volumeDown" -> adjust(AudioManager.ADJUST_LOWER)
            "toggleMute" -> adjust(AudioManager.ADJUST_TOGGLE_MUTE)
        }
    }

    private fun adjust(direction: Int) =
        audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)

    private fun mediaKey(code: Int) {
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    private fun appLabel(packageName: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: Exception) {
        // Not visible to us: guess from the package name.
        val generic = setOf("com", "org", "net", "android", "google", "app", "apps", "music", "player", "mobile")
        packageName.split('.').lastOrNull { it !in generic }?.replaceFirstChar { it.uppercase() } ?: packageName
    }
}
