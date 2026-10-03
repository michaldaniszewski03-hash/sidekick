"""Makes assets/sounds/ping.wav: the loud "ping" a device plays when another
one pings it (the Ping button), to find it or get someone's attention.

    pip install numpy
    python app/tool/make_ping.py        # from the repo root

Two bright bell-like notes (G6 then C7, with a little shimmer), quick to
start, ringing out for about 1.4 s, as loud as it can be without clipping.
The app plays it three times. Replace it with a recording of your own by
writing any WAV (44.1 kHz, 16-bit) to that path.
"""

import wave
from pathlib import Path

import numpy as np

RATE = 44100
OUT = Path(__file__).resolve().parent.parent / "assets/sounds/ping.wav"


def bell(freq: float, length: float) -> np.ndarray:
    t = np.arange(int(RATE * length)) / RATE
    tone = (
        np.sin(2 * np.pi * freq * t)
        + 0.45 * np.sin(2 * np.pi * freq * 2.0 * t) * np.exp(-t * 6)
        + 0.25 * np.sin(2 * np.pi * freq * 2.76 * t) * np.exp(-t * 9)
        + 0.12 * np.sin(2 * np.pi * freq * 5.4 * t) * np.exp(-t * 14)
    )
    attack = np.minimum(t / 0.004, 1.0)
    return tone * attack * np.exp(-t * 3.2)


def main() -> None:
    length = 1.6
    out = np.zeros(int(RATE * length))
    for start, freq in [(0.0, 1567.98), (0.16, 2093.0)]:
        note = bell(freq, length - start)
        i = int(RATE * start)
        out[i : i + len(note)] += note
    # Loud: soft-clip for presence, then peaks at -0.3 dBFS.
    out = np.tanh(out * 1.6)
    out *= 10 ** (-0.3 / 20) / np.max(np.abs(out))
    fade = int(RATE * 0.05)
    out[-fade:] *= np.linspace(1, 0, fade)
    stereo = np.repeat((out * 32767).astype(np.int16)[:, None], 2, axis=1)
    with wave.open(str(OUT), "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(stereo.tobytes())
    print(f"wrote {OUT} ({length:.1f} s)")


if __name__ == "__main__":
    main()
