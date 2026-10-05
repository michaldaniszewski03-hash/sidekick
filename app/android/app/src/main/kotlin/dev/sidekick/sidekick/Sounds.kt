package dev.sidekick.sidekick

import android.media.AudioAttributes
import android.media.MediaPlayer

/**
 * Sidekick's sounds, played by the engine whether or not Sidekick is on
 * screen (a Ping must ring in a pocket too).
 */
object Sounds {
    /** Sidekick's sounds, held until they finish: a MediaPlayer nobody
     *  holds can be garbage-collected mid-sound and go quiet. */
    private val players = mutableSetOf<MediaPlayer>()

    /** The Ping ringtone, on repeat until [stopLoop] (the card's Found It). */
    private var ringtone: MediaPlayer? = null

    /** On the alarm volume: heard even with the phone on silent. */
    fun loopSound(path: String) {
        stopLoop()
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.setDataSource(path)
            player.isLooping = true
            player.prepare()
            player.start()
            ringtone = player
        } catch (e: Exception) {
            player.release()
        }
    }

    fun stopLoop() {
        ringtone?.let {
            try {
                it.stop()
            } catch (e: IllegalStateException) {
            }
            it.release()
        }
        ringtone = null
    }

    /** Sidekick's sounds (startup, a request, accepted, declined), on the
     *  media volume: the "system sounds" volume is muted on many phones. */
    fun playSound(path: String, loud: Boolean = false) {
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
}
