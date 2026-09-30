"""Synthesizes Sidekick's startup chime (assets/sounds/startup.wav).

    pip install numpy
    python app/tool/make_sound.py        # from the repo root

Timed to the startup animation (lib/ui/startup.dart):
  0.00 s  the tile pops in: a soft airy lift and two mallet notes ("si-dekick")
  0.20 s  the ripples spread: a warm E major (add9) chord blooms
  0.24 s  a quiet high sparkle on top
Stereo, with a small room reverb, about 2 seconds. Played on every platform
(Settings → Startup sound).
"""

import wave
from pathlib import Path

import numpy as np

RATE = 44100
LENGTH = 2.1
OUT = Path(__file__).resolve().parents[1] / "assets/sounds/startup.wav"
N = int(RATE * LENGTH)
T = np.arange(N) / RATE


def env(start: float, attack: float, decay: float) -> np.ndarray:
    """Zero before [start], a smooth attack, then an exponential decay."""
    t = T - start
    rise = np.clip(t / attack, 0, 1)
    rise = rise * rise * (3 - 2 * rise)  # smoothstep: no clicks
    return np.where(t < 0, 0.0, rise * np.exp(-np.maximum(t, 0) * decay))


def tone(freq: float, start: float, *, cents: float = 0.0) -> np.ndarray:
    f = freq * 2 ** (cents / 1200)
    return np.sin(2 * np.pi * f * np.maximum(T - start, 0))


def mallet(freq: float, start: float, gain: float) -> np.ndarray:
    """A soft marimba-like note: a round fundamental and quick overtones."""
    body = tone(freq, start) * env(start, 0.004, 5.5)
    ring = 0.35 * tone(freq * 2, start) * env(start, 0.003, 11)
    tick = 0.12 * tone(freq * 3.98, start) * env(start, 0.002, 24)
    return gain * (body + ring + tick)


def pad(freq: float, start: float, gain: float, cents: float) -> np.ndarray:
    """A warm chord voice: slow attack, long tail, two slightly detuned copies."""
    e = env(start, 0.07, 1.7)
    voice = sum(tone(freq, start, cents=c) for c in (-cents, cents)) / 2
    warmth = 0.22 * tone(freq * 2, start, cents=cents) + 0.06 * tone(freq * 3, start)
    return gain * e * (voice + warmth)


def sparkle(freq: float, start: float, gain: float) -> np.ndarray:
    return gain * tone(freq, start) * env(start, 0.01, 7) * (1 + 0.3 * np.sin(2 * np.pi * 7 * T))


def lift(start: float, gain: float) -> np.ndarray:
    """An airy rising swish: noise with a sweeping band, very soft."""
    rng = np.random.default_rng(7)
    noise = rng.standard_normal(N)
    t = np.clip((T - start) / 0.22, 0, 1)
    # One-pole low-pass whose cutoff sweeps up: a rising "whoosh".
    cutoff = 800 + 5200 * t
    alpha = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    out = np.zeros(N)
    acc = 0.0
    for i in range(int(start * RATE), min(N, int((start + 0.35) * RATE))):
        acc += alpha[i] * (noise[i] - acc)
        out[i] = acc
    shape = np.sin(np.pi * np.clip((T - start) / 0.3, 0, 1)) ** 2
    return gain * out * shape


def reverb(x: np.ndarray, mix: float) -> np.ndarray:
    """A small Schroeder room: four combs into two all-passes."""
    wet = np.zeros_like(x)
    for delay_ms, fb in ((29.7, 0.77), (37.1, 0.75), (41.1, 0.73), (43.7, 0.71)):
        d = int(RATE * delay_ms / 1000)
        y = np.copy(x)
        for i in range(d, len(y)):
            y[i] += fb * y[i - d]
        wet += y / 4
    for delay_ms, g in ((5.0, 0.7), (1.7, 0.7)):
        d = int(RATE * delay_ms / 1000)
        y = np.zeros_like(wet)
        for i in range(len(wet)):
            y[i] = -g * wet[i] + (wet[i - d] if i >= d else 0) + (g * y[i - d] if i >= d else 0)
        wet = y
    return (1 - mix) * x + mix * wet


def main() -> None:
    left = np.zeros(N)
    right = np.zeros(N)

    def add(sig: np.ndarray, pan: float) -> None:
        """pan: -1 left … 1 right (equal-power)."""
        a = (pan + 1) * np.pi / 4
        left[:] += sig * np.cos(a)
        right[:] += sig * np.sin(a)

    add(lift(0.0, 0.05), 0.0)
    add(mallet(493.88, 0.02, 0.55), -0.25)  # B4
    add(mallet(659.26, 0.13, 0.6), 0.25)  # E5
    # E major add9, spread across the stereo field.
    for freq, gain, pan, cents in (
        (164.81, 0.20, 0.0, 3),  # E3
        (329.63, 0.22, -0.35, 4),  # E4
        (493.88, 0.18, 0.35, 5),  # B4
        (739.99, 0.12, -0.55, 6),  # F#5
        (830.61, 0.12, 0.55, 5),  # G#5
    ):
        add(pad(freq, 0.2, gain, cents), pan)
    add(sparkle(1975.53, 0.24, 0.05), -0.7)  # B6
    add(sparkle(2637.02, 0.31, 0.04), 0.7)  # E7
    add(sparkle(3322.44, 0.38, 0.025), 0.2)  # G#7

    left, right = reverb(left, 0.28), reverb(right, 0.28)
    fade = np.clip((LENGTH - T) / 0.45, 0, 1) ** 2
    stereo = np.stack([left * fade, right * fade], axis=1)
    stereo *= 0.7 / np.abs(stereo).max()  # about -3 dBFS
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((stereo * 32767).astype("<i2").tobytes())
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
