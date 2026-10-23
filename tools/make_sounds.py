"""Synthesises every sound in sounds/ from noise and sine waves, so the prototype needs no recorded audio.

Run from the project folder (needs Python 3 with numpy, and ffmpeg on the PATH):

    python3 tools/make_sounds.py

Each sound is a small recipe below. Loops are built from noise shaped over the whole loop
length, which makes them repeat without a seam. Replace any .ogg with a real recording of
the same name and the game will use it instead.
"""

import os
import subprocess
import tempfile
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sounds")
rng = np.random.default_rng(1816)


# --- Building blocks -----------------------------------------------------------

def frames(seconds, block=512):
    """Sample count rounded to a whole number of blocks, so loops and the sweep filter line up."""
    return int(round(seconds * SR / block)) * block


def times(n):
    return np.arange(n) / SR


def freqs(n):
    return np.fft.rfftfreq(n, 1.0 / SR)


def lowpass(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * order))


def highpass(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-3)) ** (2 * order))


def bump(f, fc, width):
    return np.exp(-0.5 * ((f - fc) / width) ** 2)


def pink(f):
    return 1.0 / np.sqrt(np.maximum(f, 20.0))


def brown(f):
    return 1.0 / np.maximum(f, 20.0)


def shaped_noise(n, shape):
    """Noise with the given spectrum. It is periodic over n samples, so it loops seamlessly."""
    spectrum = np.fft.rfft(rng.standard_normal(n)) * shape(freqs(n))
    spectrum[0] = 0.0
    x = np.fft.irfft(spectrum, n)
    return x / (np.max(np.abs(x)) + 1e-12)


def spectral_filter(x, shape):
    """Zero-phase filter. Fine for noise beds; resonant one-shots use biquad() instead."""
    n = len(x)
    return np.fft.irfft(np.fft.rfft(x) * shape(freqs(n)), n)


def biquad(x, kind, f0, q=0.707):
    w0 = 2.0 * np.pi * f0 / SR
    alpha = np.sin(w0) / (2.0 * q)
    c = np.cos(w0)
    if kind == "lp":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    else:  # band-pass, 0 dB at the peak
        b = [alpha, 0.0, -alpha]
    a = [1 + alpha, -2 * c, 1 - alpha]
    b0, b1, b2 = (v / a[0] for v in b)
    a1, a2 = a[1] / a[0], a[2] / a[0]
    y = np.zeros(len(x))
    x1 = x2 = y1 = y2 = 0.0
    for k, v in enumerate(x):
        out = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, out
        y[k] = out
    return y


def sweep_bandpass(x, centre, width_ratio, win=2048, hop=512):
    """Band-pass whose centre frequency moves over time (centre is an array, one value per sample).
    Works circularly, so a loop stays seamless."""
    n = len(x)
    window = np.hanning(win + 1)[:-1]
    f = np.fft.rfftfreq(win, 1.0 / SR)
    y = np.zeros(n)
    for start in range(0, n, hop):
        idx = np.arange(start, start + win) % n
        fc = centre[(start + win // 2) % n]
        spectrum = np.fft.rfft(x[idx] * window) * bump(f, fc, fc * width_ratio)
        np.add.at(y, idx, np.fft.irfft(spectrum, win))
    return y / 2.0  # a Hann window at 75% overlap sums to 2


def envelope(n, attack, decay, delay=0.0):
    t = times(n) - delay
    rise = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    fall = np.exp(-np.maximum(t - attack, 0.0) / decay)
    return np.where(t < 0, 0.0, rise * fall)


def fade(x, fade_in=0.0, fade_out=0.0):
    x = x.copy()
    a, b = int(fade_in * SR), int(fade_out * SR)
    if a:
        x[:a] *= np.linspace(0.0, 1.0, a)
    if b:
        x[-b:] *= np.linspace(1.0, 0.0, b)
    return x


def tone(n, freq, phase=0.0):
    """Sine whose frequency may change over time (freq can be an array)."""
    return np.sin(2.0 * np.pi * np.cumsum(np.broadcast_to(freq, (n,))) / SR + phase)


def place(track, sound, at, wrap=False):
    start = int(at * SR)
    if wrap:
        idx = (start + np.arange(len(sound))) % len(track)
        np.add.at(track, idx, sound)
    else:
        end = min(start + len(sound), len(track))
        if start < len(track):
            track[start:end] += sound[: end - start]
    return track


def periodic_wobble(n, period_frames, harmonics, rng_phase=True):
    """Slow movement from sines that divide the loop length, so it repeats without a seam."""
    t = np.arange(n) / period_frames
    out = np.zeros(n)
    for k, amp in harmonics:
        out += amp * np.sin(2.0 * np.pi * k * t + (rng.uniform(0, 2 * np.pi) if rng_phase else 0.0))
    return out


def reverb(x, seconds=2.4, wet=0.32, bright=3500.0):
    """Convolution with decaying noise: a cheap cave."""
    n_ir = int(seconds * SR)
    ir = rng.standard_normal(n_ir) * np.exp(-times(n_ir) / (seconds / 6.9))
    ir = spectral_filter(ir, lambda f: lowpass(f, bright, 1))
    ir[: int(0.012 * SR)] = 0.0
    ir /= np.sqrt(np.sum(ir ** 2))
    n = len(x) + n_ir
    tail = np.fft.irfft(np.fft.rfft(x, n) * np.fft.rfft(ir, n), n)
    dry = np.concatenate([x, np.zeros(n_ir)])
    return dry * (1.0 - wet) + tail * wet * 1.4


def normalise(x, peak):
    return x * (peak / (np.max(np.abs(x)) + 1e-12))


def save(name, x, peak=0.8, trim=True):
    x = normalise(x, peak)
    if trim:
        loud = np.nonzero(np.abs(x) > 1e-4)[0]
        if len(loud):
            x = fade(x[: loud[-1] + 1], 0.0, 0.004)
    os.makedirs(OUT, exist_ok=True)
    pcm = (np.clip(x, -1.0, 1.0) * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = tmp.name
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c:a", "libvorbis", "-q:a", "5",
                    os.path.join(OUT, name + ".ogg")], check=True)
    os.remove(path)
    print("  %-14s %.2fs" % (name, len(x) / SR))


def save_loop(name, x, peak=0.8):
    save(name, x, peak, trim=False)


# Short sound pieces used by several recipes.

def burst(seconds, decay, shape=None):
    n = int(seconds * SR)
    x = rng.standard_normal(n) * envelope(n, 0.0005, decay)
    return spectral_filter(x, shape) if shape else x


def ring(freq, decay, seconds=None, amp=1.0, attack=0.0008):
    n = int((seconds or decay * 7) * SR)
    return amp * tone(n, freq, rng.uniform(0, 6.28)) * envelope(n, attack, decay)


def pitched_thud(f_start, f_end, decay, seconds=0.5):
    n = int(seconds * SR)
    t = times(n)
    f = f_end + (f_start - f_end) * np.exp(-t / (decay * 0.6))
    return tone(n, f) * envelope(n, 0.002, decay)


def mix(*parts):
    """Adds sounds of different lengths, padding the shorter ones with silence."""
    out = np.zeros(max(len(p) for p in parts))
    for p in parts:
        out[: len(p)] += p
    return out


def impulses(n, rate, power=2.0, wrap=True):
    """Sparse clicks at random times with mostly small and a few large amplitudes."""
    track = np.zeros(n)
    count = rng.poisson(rate * n / SR)
    pos = rng.integers(0, n, count)
    track[pos] += rng.uniform(0.05, 1.0, count) ** power * rng.choice([-1, 1], count)
    return track


def convolve(track, kernel, wrap=True):
    n = len(track)
    m = n if wrap else n + len(kernel)
    out = np.fft.irfft(np.fft.rfft(track, m) * np.fft.rfft(kernel, m), m)
    return out[:n] if wrap else out


def chord_voice(n, freq, partials=10, cutoff=2400.0, vibrato=0.0015, detune_cents=4.0):
    """A soft bowed tone: harmonics rolled off above the cutoff, two slightly detuned voices."""
    t = times(n)
    out = np.zeros(n)
    for cents in (-detune_cents, detune_cents):
        f = freq * 2 ** (cents / 1200.0) * (1.0 + vibrato * np.sin(2 * np.pi * rng.uniform(4.2, 5.4) * t))
        for k in range(1, partials + 1):
            if freq * k > 9000:
                break
            out += tone(n, f * k, rng.uniform(0, 6.28)) / k ** 1.2 * np.exp(-freq * k / cutoff)
    return out


def bell(fundamental, seconds=4.0, strike=1.0):
    n = int(seconds * SR)
    out = np.zeros(n)
    for ratio, amp, decay in [(0.5, 0.35, 2.4), (1.0, 1.0, 2.0), (1.19, 0.5, 1.5), (1.5, 0.35, 1.3),
                              (2.0, 0.45, 1.0), (2.52, 0.22, 0.7), (2.67, 0.18, 0.6), (3.01, 0.15, 0.5),
                              (4.07, 0.08, 0.3)]:
        f = fundamental * ratio
        out += amp * (tone(n, f) + 0.6 * tone(n, f + 0.7)) * envelope(n, 0.003, decay)
    return out * strike


# --- Ambience ------------------------------------------------------------------

def make_wind():
    n = frames(16.0)
    period = n
    body = shaped_noise(n, lambda f: pink(f) * lowpass(f, 900) * highpass(f, 70))
    gust = 0.6 + 0.4 * np.tanh(periodic_wobble(n, period, [(1, 0.9), (2, 0.6), (3, 0.4), (5, 0.25)]))
    # A moaning whistle whose pitch wanders, like wind across the mouth of a crevasse.
    centre = 620.0 * 2.0 ** (0.45 * periodic_wobble(n, period, [(1, 0.8), (2, 0.4), (3, 0.3)]))
    whistle = sweep_bandpass(shaped_noise(n, pink), centre, 0.035)
    whistle = whistle / np.max(np.abs(whistle)) * (0.5 + 0.5 * np.tanh(2.0 * periodic_wobble(n, period, [(2, 1.0), (3, 0.6)])))
    high = shaped_noise(n, lambda f: bump(f, 2600, 900)) * 0.12
    save_loop("wind", body * gust * 0.9 + whistle * 0.28 + high * gust ** 2, peak=0.7)


def make_deep():
    n = frames(20.0)
    rumble = shaped_noise(n, lambda f: brown(f) * lowpass(f, 160, 3) * highpass(f, 28))
    swell = 0.7 + 0.3 * periodic_wobble(n, n, [(1, 0.7), (3, 0.3)])
    t = times(n)
    seconds = n / SR
    hum = sum(amp * np.sin(2 * np.pi * round(f * seconds) / seconds * t) for f, amp in ((46.0, 1.0), (69.05, 0.5)))  # whole cycles per loop * (0.5 + 0.5 * periodic_wobble(n, n, [(2, 1.0)]))
    drips = shaped_noise(n, lambda f: bump(f, 380, 120)) * 0.08
    save_loop("deep", rumble * swell + hum * 0.08 + drips, peak=0.6)


def make_groan(name, start_rate, end_rate):
    """Ice under strain: stick-slip pulses dragged through a few hollow resonances."""
    seconds = 3.2
    n = int(seconds * SR)
    track = np.zeros(n)
    t = 0.15
    while t < seconds - 0.5:
        progress = t / seconds
        rate = start_rate + (end_rate - start_rate) * progress
        track[int(t * SR)] += rng.uniform(0.5, 1.0)
        t += (1.0 / rate) * rng.uniform(0.8, 1.25)
    kernel = burst(0.004, 0.0008)
    track = convolve(track, kernel, wrap=False)[:n]
    voiced = biquad(track, "bp", 170, 5) * 1.0 + biquad(track, "bp", 390, 6) * 0.7 + biquad(track, "bp", 830, 7) * 0.35
    shape = np.sin(np.pi * np.clip(times(n) / (seconds - 0.4), 0, 1)) ** 1.5
    save(name, reverb(voiced * shape, 1.8, 0.25, 2000), peak=0.7)


def make_heartbeat():
    n = frames(1.2, block=64)
    out = np.zeros(n)
    for at, amp in ((0.0, 1.0), (0.27, 0.65)):
        beat = pitched_thud(70, 42, 0.07, 0.35) + 0.25 * burst(0.35, 0.01, lambda f: lowpass(f, 300))
        place(out, beat * amp, at)
    save_loop("heartbeat", spectral_filter(out, lambda f: lowpass(f, 220, 2)), peak=0.8)


# --- Fire ----------------------------------------------------------------------

def make_fire():
    n = frames(6.0)
    roar = shaped_noise(n, lambda f: pink(f) * lowpass(f, 650) * highpass(f, 90))
    flutter = 0.72 + 0.28 * shaped_noise(n, lambda f: lowpass(f, 5.0, 2) * highpass(f, 0.4, 1))
    crackle = convolve(impulses(n, 22, power=2.5), burst(0.005, 0.0009))
    crackle = spectral_filter(crackle, lambda f: highpass(f, 1300) * lowpass(f, 9000))
    pops = np.zeros(n)
    for k in range(rng.poisson(1.6 * 6.0)):
        pop = mix(burst(0.03, 0.002) * 0.6, ring(rng.uniform(900, 2200), 0.006, 0.04))
        place(pops, pop * rng.uniform(0.3, 1.0), rng.uniform(0, 6.0), wrap=True)
    save_loop("fire", roar * flutter * 0.55 + crackle / np.max(np.abs(crackle)) * 0.55 + pops * 0.5, peak=0.8)


def make_stove():
    n = frames(6.0)
    roar = shaped_noise(n, lambda f: pink(f) * lowpass(f, 260, 3) * highpass(f, 45))
    flutter = 0.8 + 0.2 * shaped_noise(n, lambda f: lowpass(f, 3.0, 2) * highpass(f, 0.4, 1))
    crackle = convolve(impulses(n, 7, power=2.5), burst(0.006, 0.0012))
    crackle = spectral_filter(crackle, lambda f: lowpass(f, 1100) * highpass(f, 200))
    ticks = np.zeros(n)
    for k in range(3):  # the iron ticks as it heats
        tick = mix(ring(1730, 0.03), 0.6 * ring(2890, 0.02), 0.4 * ring(4410, 0.012))
        place(ticks, tick * rng.uniform(0.4, 0.8), rng.uniform(0, 6.0), wrap=True)
    save_loop("stove", roar * flutter * 0.8 + crackle / np.max(np.abs(crackle)) * 0.35 + ticks * 0.12, peak=0.7)


def make_ignite():
    n = int(1.3 * SR)
    t = times(n)
    centre = 260.0 + 1000.0 * (1.0 - np.exp(-t / 0.25))
    whoosh = sweep_bandpass(np.concatenate([rng.standard_normal(n), np.zeros(4096)]), np.concatenate([centre, np.full(4096, 1260.0)]), 0.5)[:n]
    whoosh *= envelope(n, 0.12, 0.35)
    crackle = convolve(impulses(n, 25, 2.5, wrap=False), burst(0.004, 0.0008), wrap=False)[:n] * envelope(n, 0.2, 0.4)
    crackle = spectral_filter(crackle, lambda f: highpass(f, 1500))
    save("ignite", whoosh / np.max(np.abs(whoosh)) + 0.4 * crackle / np.max(np.abs(crackle)), peak=0.7)


def make_hiss(name, seconds, decay, peak):
    n = int(seconds * SR)
    hiss = spectral_filter(rng.standard_normal(n), lambda f: highpass(f, 2400, 2) * lowpass(f, 9500))
    sputter = 0.6 + 0.4 * spectral_filter(rng.standard_normal(n), lambda f: lowpass(f, 18, 2)) * 6
    pops = convolve(impulses(n, 10, 2.0, wrap=False), burst(0.004, 0.001), wrap=False)[:n]
    x = (hiss * np.clip(sputter, 0.1, 1.6) + pops * 0.8) * envelope(n, 0.02, decay)
    save(name, x, peak=peak)


# --- Water ---------------------------------------------------------------------

def make_drip(name, f0):
    n = int(0.16 * SR)
    t = times(n)
    f = f0 * (1.0 + 1.4 * (1.0 - np.exp(-t / 0.014)))  # the drop's bubble rings upward in pitch
    plink = tone(n, f) * envelope(n, 0.0007, 0.022)
    click = burst(0.004, 0.0006, lambda f_: highpass(f_, 2500)) * 0.25
    out = place(np.zeros(n), click, 0.0) + plink
    save(name, reverb(out, 0.9, 0.22, 5000), peak=0.6)


def make_tap(name, f0):
    n = int(0.08 * SR)
    out = burst(0.08, 0.0015, lambda f: highpass(f, 2800)) * 0.5 + ring(f0, 0.008, 0.08, 0.6) + ring(f0 * 1.63, 0.005, 0.08, 0.3)
    save(name, out[:n], peak=0.45)


def make_melt():
    n = int(0.9 * SR)
    slosh = spectral_filter(rng.standard_normal(n), lambda f: lowpass(f, 800) * highpass(f, 120))
    slosh *= envelope(n, 0.06, 0.25) * (0.7 + 0.3 * np.sin(2 * np.pi * 7 * times(n)))
    bubbles = np.zeros(n)
    for k in range(5):
        m = int(0.07 * SR)
        f = rng.uniform(280, 620) * (1.0 + 1.2 * (1.0 - np.exp(-times(m) / 0.02)))
        place(bubbles, tone(m, f) * envelope(m, 0.002, 0.018) * rng.uniform(0.3, 0.8), rng.uniform(0.03, 0.5))
    save("melt", slosh / np.max(np.abs(slosh)) + bubbles * 0.5, peak=0.5)


def make_freeze():
    n = int(0.8 * SR)
    out = np.zeros(n)
    for k in range(26):
        at = 0.6 * rng.uniform(0, 1) ** 1.8  # most of the ticks come early
        tick = ring(rng.uniform(3800, 8500), rng.uniform(0.002, 0.006), 0.04, rng.uniform(0.2, 1.0))
        place(out, tick, at)
    save("freeze", reverb(out, 0.7, 0.25, 7000), peak=0.35)


# --- Ice and digging -----------------------------------------------------------

def make_chip_ice(name):
    n = int(0.4 * SR)
    out = np.zeros(n)
    place(out, burst(0.06, 0.006, lambda f: highpass(f, 2500) * lowpass(f, 11000)) * 0.8, 0.0)
    for base in (2200, 3600, 5100, 6900):  # glassy, slightly out of tune partials
        place(out, ring(base * rng.uniform(0.9, 1.12), rng.uniform(0.02, 0.06), 0.35, rng.uniform(0.25, 0.6)), 0.0)
    place(out, pitched_thud(260, 150, 0.025, 0.2) * 0.7, 0.0)
    for k in range(rng.integers(3, 7)):  # chips of ice skittering away
        place(out, ring(rng.uniform(4000, 9000), 0.004, 0.03, rng.uniform(0.1, 0.35)), rng.uniform(0.04, 0.22))
    save(name, out, peak=0.7)


def make_crunch(name, seconds, grains, cutoff, peak):
    n = int(seconds * SR)
    out = np.zeros(n)
    for k in range(grains):
        at = (seconds * 0.7) * rng.uniform(0, 1) ** 1.3
        grain = burst(rng.uniform(0.003, 0.008), rng.uniform(0.0008, 0.002)) * rng.uniform(0.3, 1.0)
        place(out, grain, at)
    out = spectral_filter(out, lambda f: lowpass(f, cutoff) * highpass(f, 300))
    save(name, out * envelope(n, 0.002, seconds * 0.4), peak=peak)


def make_crack(name, chirps):
    """Ice cracking under heat: a sharp report, then the falling 'pew' that stressed ice makes."""
    seconds = 1.6
    n = int(seconds * SR)
    out = np.zeros(n)
    place(out, burst(0.03, 0.003) * 1.0, 0.0)
    place(out, pitched_thud(140, 70, 0.05, 0.3) * 0.6, 0.0)
    for k in range(chirps):
        at = 0.005 + 0.55 * rng.uniform(0, 1) ** 1.5
        length = rng.uniform(0.12, 0.28)
        m = int(length * SR)
        t = times(m)
        f = 3800.0 * (240.0 / 3800.0) ** (t / length) * rng.uniform(0.8, 1.15)
        place(out, tone(m, f) * envelope(m, 0.001, length * 0.35) * rng.uniform(0.35, 0.8), at)
    for k in range(rng.integers(4, 9)):
        place(out, burst(0.01, 0.001, lambda f: highpass(f, 1800)) * rng.uniform(0.15, 0.5), rng.uniform(0.02, 0.9))
    save(name, reverb(out, 1.6, 0.3, 4000), peak=0.85)


def make_fall():
    seconds = 2.0
    n = int(seconds * SR)
    out = np.zeros(n)
    place(out, pitched_thud(90, 38, 0.22, 1.2) * 1.0, 0.0)
    place(out, burst(0.8, 0.12, lambda f: lowpass(f, 1400) * highpass(f, 60)) * 0.7, 0.0)
    for k in range(40):  # the block shatters
        at = 0.6 * rng.uniform(0, 1) ** 2
        shard = ring(rng.uniform(1800, 7500), rng.uniform(0.005, 0.03), 0.2, rng.uniform(0.05, 0.4))
        place(out, shard, at)
    place(out, burst(0.4, 0.05, lambda f: highpass(f, 2500)) * 0.35, 0.0)
    save("fall", reverb(out, 2.0, 0.3, 3000), peak=0.9)


# --- Building and crates -------------------------------------------------------

def make_crate():
    n = int(1.1 * SR)
    creak = np.zeros(n)
    t = 0.0
    while t < 0.42:
        rate = 85.0 + 70.0 * (t / 0.42)
        creak[int(t * SR)] += rng.uniform(0.5, 1.0)
        t += 1.0 / rate * rng.uniform(0.85, 1.2)
    creak = convolve(creak, burst(0.003, 0.0006), wrap=False)[:n]
    creak = biquad(creak, "bp", 340, 6) + 0.7 * biquad(creak, "bp", 760, 7) + 0.4 * biquad(creak, "bp", 1500, 8)
    creak *= np.clip(1.0 - np.abs(times(n) - 0.22) / 0.26, 0, 1)
    lid = np.zeros(n)
    place(lid, pitched_thud(160, 105, 0.07, 0.4), 0.55)
    place(lid, burst(0.1, 0.02, lambda f: lowpass(f, 1600)) * 0.5, 0.55)
    for k in range(4):
        place(lid, ring(rng.uniform(500, 1400), 0.01, 0.06, 0.3), 0.6 + k * rng.uniform(0.03, 0.06))
    save("crate", reverb(creak / np.max(np.abs(creak)) * 0.6 + lid, 1.2, 0.2, 3000), peak=0.8)


def make_place():
    n = int(0.35 * SR)
    out = pitched_thud(130, 72, 0.06, 0.35) + burst(0.35, 0.012, lambda f: lowpass(f, 1800) * highpass(f, 100)) * 0.5
    save("place", out, peak=0.6)


def make_knock():
    n = int(0.35 * SR)
    out = np.zeros(n)
    for at, amp in ((0.0, 1.0), (0.11, 0.7)):
        knock = ring(430, 0.03, 0.2, 0.8) + ring(980, 0.018, 0.2, 0.5) + ring(1900, 0.008, 0.2, 0.3)
        knock += burst(0.2, 0.002, lambda f: lowpass(f, 4000)) * 0.4
        place(out, knock * amp, at)
    save("knock", out, peak=0.6)


def make_click():
    n = int(0.05 * SR)
    out = ring(2300, 0.004, 0.05, 1.0) + burst(0.05, 0.0008, lambda f: highpass(f, 3000)) * 0.3
    save("click", out[:n], peak=0.3)


# --- Story moments -------------------------------------------------------------

def make_camp():
    seconds = 6.0
    n = int(seconds * SR)
    chord = np.zeros(n)
    for freq, amp in ((110.0, 1.0), (164.81, 0.7), (246.94, 0.5), (261.63, 0.45)):  # a minor second at the top keeps it uneasy
        chord += amp * chord_voice(n, freq)
    shape = np.clip(times(n) / 1.8, 0, 1) ** 2 * np.exp(-np.maximum(times(n) - 2.6, 0) / 1.0)
    chord *= shape
    t = times(n)
    shimmer = sum(np.sin(2 * np.pi * f * t + rng.uniform(0, 6)) for f in (1760.0, 2093.0, 2637.0))
    shimmer *= (0.5 + 0.5 * np.sin(2 * np.pi * 6.5 * t)) * shape * 0.06
    boom = place(np.zeros(n), pitched_thud(70, 40, 0.4, 2.0), 0.0) * 0.6
    save("camp", reverb(chord / np.max(np.abs(chord)) + shimmer + boom, 3.0, 0.35, 3000), peak=0.7)


def make_journal():
    save("journal", reverb(bell(293.66, 4.0), 2.6, 0.3, 4000), peak=0.55)


def make_blueprint():
    n = int(4.5 * SR)
    out = np.zeros(n)
    place(out, bell(392.0, 4.0), 0.0)
    place(out, bell(587.33, 4.0, 0.8), 0.32)
    save("blueprint", reverb(out, 2.6, 0.3, 4500), peak=0.55)


def make_death():
    seconds = 6.0
    n = int(seconds * SR)
    t = times(n)
    out = np.zeros(n)
    for freq, start, length in ((146.83, 0.0, 2.2), (138.59, 1.8, 3.6)):  # D falling to C sharp
        m = int(length * SR)
        voice = chord_voice(m, freq, partials=12, cutoff=1500.0, vibrato=0.004, detune_cents=3.0)
        voice = biquad(voice, "bp", 320, 0.9) + 0.5 * biquad(voice, "bp", 900, 1.2)
        voice *= np.clip(times(m) / 0.5, 0, 1) * np.clip((length - times(m)) / 0.9, 0, 1)
        place(out, voice, start)
    wind = spectral_filter(rng.standard_normal(n), lambda f: bump(f, 500, 300)) * envelope(n, 1.5, 2.0)
    save("death", reverb(out / np.max(np.abs(out)) + wind * 0.02, 3.0, 0.35, 2500), peak=0.6)


def make_won():
    seconds = 7.0
    n = int(seconds * SR)
    out = np.zeros(n)
    for k, (freq, amp) in enumerate(((146.83, 1.0), (220.0, 0.7), (293.66, 0.6), (369.99, 0.45), (440.0, 0.35))):
        m = n - int(k * 0.35 * SR)
        voice = chord_voice(m, freq, cutoff=3000.0) * amp
        voice *= np.clip(times(m) / 1.4, 0, 1) * np.exp(-np.maximum(times(m) - 3.0, 0) / 1.3)
        place(out, voice, k * 0.35)
    out = out / np.max(np.abs(out)) + place(np.zeros(n), bell(293.66, 4.0), 0.0) * 0.08
    save("won", reverb(out, 3.0, 0.35, 3500), peak=0.7)


def make_lost():
    seconds = 7.0
    n = int(seconds * SR)
    drone = chord_voice(n, 73.42, partials=14, cutoff=900.0) + 0.8 * chord_voice(n, 77.78, partials=14, cutoff=900.0)
    drone *= np.clip(times(n) / 1.5, 0, 1) * np.exp(-np.maximum(times(n) - 2.5, 0) / 1.5)
    gust = spectral_filter(rng.standard_normal(n), lambda f: pink(f) * lowpass(f, 900) * highpass(f, 80))
    gust *= envelope(n, 2.5, 2.0)
    save("lost", reverb(drone / np.max(np.abs(drone)) + 0.25 * gust / np.max(np.abs(gust)), 3.0, 0.35, 2500), peak=0.7)


def main():
    print("Writing sounds to", os.path.normpath(OUT))
    make_wind()
    make_deep()
    make_groan("groan_1", 34, 22)
    make_groan("groan_2", 26, 40)
    make_heartbeat()
    make_fire()
    make_stove()
    make_ignite()
    make_hiss("hiss", 1.6, 0.45, 0.6)
    make_hiss("fizzle", 0.9, 0.2, 0.5)
    for k, f0 in enumerate((820, 1040, 1310)):
        make_drip("drip_%d" % (k + 1), f0)
    for k, f0 in enumerate((3300, 4100)):
        make_tap("tap_%d" % (k + 1), f0)
    make_melt()
    make_freeze()
    for k in range(3):
        make_chip_ice("chip_ice_%d" % (k + 1))
    for k in range(2):
        make_crunch("chip_snow_%d" % (k + 1), 0.16, 30, 3000, 0.55)
    for k in range(3):
        make_crunch("step_%d" % (k + 1), 0.08, 12, 1800, 0.35)
    make_crack("crack_1", 3)
    make_crack("crack_2", 5)
    make_fall()
    make_crate()
    make_place()
    make_knock()
    make_click()
    make_camp()
    make_journal()
    make_blueprint()
    make_death()
    make_won()
    make_lost()


if __name__ == "__main__":
    main()
