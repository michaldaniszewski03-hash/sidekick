"""Synthesizes Sidekick's startup chime (assets/sounds/startup.wav).

    pip install numpy
    python app/tool/make_sound.py        # from the repo root

A soft, bell-like rising arpeggio (E5, B5, E6, G#6) with a gentle echo.
Played once when Sidekick starts on a Mac (Settings → Startup sound).
"""

import wave
from pathlib import Path

import numpy as np

RATE = 44100
OUT = Path(__file__).resolve().parents[1] / "assets/sounds/startup.wav"


def bell(freq: float, length: float, decay: float) -> np.ndarray:
    t = np.arange(int(RATE * length)) / RATE
    # A few inharmonic partials make it sound like a small glass bell.
    tone = (
        np.sin(2 * np.pi * freq * t)
        + 0.35 * np.sin(2 * np.pi * freq * 2.0 * t) * np.exp(-t * 6)
        + 0.12 * np.sin(2 * np.pi * freq * 3.01 * t) * np.exp(-t * 10)
    )
    attack = np.clip(t / 0.006, 0, 1)
    return tone * attack * np.exp(-t * decay)


def main() -> None:
    total = 1.9
    out = np.zeros(int(RATE * total))
    notes = [(659.25, 0.00, 0.8), (987.77, 0.09, 0.75), (1318.5, 0.18, 0.7), (1661.2, 0.27, 0.55)]
    for freq, start, gain in notes:
        s = bell(freq, total - start, decay=3.2) * gain
        i = int(start * RATE)
        out[i : i + len(s)] += s[: len(out) - i]
    # Two soft echoes for a sense of space.
    for delay, gain in [(0.16, 0.22), (0.33, 0.1)]:
        d = int(delay * RATE)
        out[d:] += out[:-d] * gain
    fade = np.clip((total - np.arange(len(out)) / RATE) / 0.3, 0, 1)
    out *= fade
    out = out / np.abs(out).max() * 0.7
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((out * 32767).astype("<i2").tobytes())
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
