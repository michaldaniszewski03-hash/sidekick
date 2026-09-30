"""Turns the sounds in tool/sounds/ (MP3) into the app's sound assets (WAV).

    pip install miniaudio numpy
    python app/tool/prepare_sounds.py        # from the repo root

WAV because it's what every platform's built-in player takes: Windows
PlaySound and iPhone system sounds can't play MP3. Each sound is:
  * decoded at 44.1 kHz stereo,
  * trimmed of the silence before it (so it plays the moment it's asked
    for) and after its tail has died away (below -70 dB of its peak),
  * given soft fades (no clicks),
  * brought to the same loudness as the others, peaks kept below -1 dBFS.

  appstartupchime.mp3     -> assets/sounds/startup.wav  (Sidekick opens)
  newfilesendrequest.mp3  -> assets/sounds/request.wav  (Accept/Decline card appears)
  filerequest_accept.mp3  -> assets/sounds/accept.wav   (a request is accepted)
  filerequest_deny.mp3    -> assets/sounds/decline.wav  (a request is declined)
"""

import wave
from pathlib import Path

import miniaudio
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "assets/sounds"
RATE = 44100
SOUNDS = {
    "appstartupchime.mp3": "startup.wav",
    "newfilesendrequest.mp3": "request.wav",
    "filerequest_accept.mp3": "accept.wav",
    "filerequest_deny.mp3": "decline.wav",
}
TARGET_RMS_DB = -20.0  # loudness of the audible part
PEAK_DB = -1.0


def db(x: float) -> float:
    return 20 * np.log10(max(x, 1e-9))


def prepare(src: Path, dst: Path) -> None:
    decoded = miniaudio.decode_file(
        str(src), output_format=miniaudio.SampleFormat.FLOAT32, nchannels=2, sample_rate=RATE
    )
    audio = np.frombuffer(decoded.samples, dtype=np.float32).reshape(-1, 2).astype(np.float64)

    # Trim, relative to the sound's own peak: the lead-in silence (from the
    # first moment within 45 dB of the peak, less 5 ms) and the tail once it
    # has died away (70 dB below the peak), so the natural decay stays.
    level = np.abs(audio).max(axis=1)
    peak0 = level.max()
    start = max(0, int(np.nonzero(level > peak0 * 10 ** (-45 / 20))[0][0]) - int(0.005 * RATE))
    end = min(len(audio), int(np.nonzero(level > peak0 * 10 ** (-70 / 20))[0][-1]) + 1)
    audio = audio[start:end]

    # Soft fades: 3 ms in, 150 ms out.
    n_in, n_out = int(0.003 * RATE), int(0.15 * RATE)
    audio[:n_in] *= np.linspace(0, 1, n_in)[:, None]
    audio[-n_out:] *= np.linspace(1, 0, n_out)[:, None]

    # Same loudness for all: RMS of the audible part to the target, then
    # never above the peak limit.
    active = audio[np.abs(audio).max(axis=1) > 10 ** (-40 / 20)]
    rms = float(np.sqrt((active**2).mean()))
    gain = 10 ** ((TARGET_RMS_DB - db(rms)) / 20)
    peak = float(np.abs(audio).max()) * gain
    if db(peak) > PEAK_DB:
        gain *= 10 ** ((PEAK_DB - db(peak)) / 20)
    audio *= gain

    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    print(
        f"{src.name:26} -> {dst.name:12} {len(audio) / RATE:.2f} s, "
        f"rms {db(rms * gain):.1f} dBFS, peak {db(float(np.abs(audio).max())):.1f} dBFS"
    )


def main() -> None:
    for src, dst in SOUNDS.items():
        prepare(HERE / "sounds" / src, OUT / dst)


if __name__ == "__main__":
    main()
