#!/usr/bin/env python3
"""Compile the CC0 mmiron tabla bols (Freesound pack 8162) into a compact
tabla.sf2 for AVAudioUnitSampler.

Each dry stroke gets its own fixed key (played at recorded pitch). The ringing
dayan `tun` gets a wide zone with its root set to its detected fundamental, so
the engine can play `tonicMidi` and have the dayan ring at the chosen Sa.
"""
import os, sys, math, array, wave, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_vsco_sf2 import build_sf2   # reuse the SF2 writer

SRC = os.path.expanduser("~/Downloads/8162__mmiron__tabla-bols")
DL = os.path.expanduser("~/Downloads")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Pancham", "Resources", "Sounds", "tabla.sf2")
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache_tabla")

# Fixed keys for the dry strokes (non-overlapping, below the tun zone).
KEY_GHE, KEY_KE, KEY_TE, KEY_NA, KEY_NAOPEN = 24, 26, 28, 30, 32
KEY_DHA, KEY_DHIN = 34, 36

def prep(path):
    """Downmix any input to mono 16-bit 44.1k so wave can read it."""
    os.makedirs(CACHE, exist_ok=True)
    out = os.path.join(CACHE, "m_" + os.path.basename(path))
    if not os.path.exists(out):
        subprocess.check_call(["ffmpeg", "-y", "-loglevel", "error", "-i", path,
                               "-ac", "1", "-ar", "44100", "-sample_fmt", "s16", out])
    return out

def read_wav(path):
    w = wave.open(prep(path), "rb")
    rate = w.getframerate()
    pcm = w.readframes(w.getnframes())
    w.close()
    return pcm, rate

def normalize(pcm, peak=0.9):
    a = array.array("h"); a.frombytes(pcm)
    mx = max((abs(x) for x in a), default=1) or 1
    g = (peak * 32767.0) / mx
    if g < 1.0 or g > 1.0:
        a = array.array("h", (max(-32768, min(32767, int(x * g))) for x in a))
    return a.tobytes()

def detect_midi(pcm, rate):
    """Fundamental of a sustained one-shot via autocorrelation (80–400 Hz)."""
    a = array.array("h"); a.frombytes(pcm)
    start = int(0.15 * rate)
    win = a[start:start + int(0.35 * rate)]
    n = len(win)
    if n < 1000:
        return 60
    mean = sum(win) / n
    w = [x - mean for x in win]
    minlag, maxlag = int(rate / 400), int(rate / 80)
    best, bestlag = 0.0, 0
    for lag in range(minlag, maxlag):
        s = 0.0
        for i in range(0, n - lag, 2):
            s += w[i] * w[i + lag]
        if s > best:
            best, bestlag = s, lag
    if bestlag == 0:
        return 60
    freq = rate / bestlag
    return int(round(69 + 12 * math.log2(freq / 440.0)))

def region(path, name, root, lokey, hikey):
    pcm, rate = read_wav(path)
    return dict(name=name, pcm=normalize(pcm), rate=rate,
                root=root, lokey=lokey, hikey=hikey)

def main():
    p = lambda f: os.path.join(SRC, f)
    tun_pcm, tun_rate = read_wav(p("130416__mmiron__tun.wav"))
    tun_root = detect_midi(tun_pcm, tun_rate)
    freq = 440.0 * 2 ** ((tun_root - 69) / 12.0)
    print(f"tun fundamental ~= MIDI {tun_root} ({freq:.1f} Hz)")

    regions = [
        region(p("130406__mmiron__ghe.wav"), "ghe", KEY_GHE, KEY_GHE, KEY_GHE),
        region(p("130413__mmiron__ke.wav"),  "ke",  KEY_KE,  KEY_KE,  KEY_KE),
        region(p("130429__mmiron__te.wav"),  "te",  KEY_TE,  KEY_TE,  KEY_TE),
        region(p("130421__mmiron__na.wav"),  "na",  KEY_NA,  KEY_NA,  KEY_NA),
        region(p("130422__mmiron__na-open.wav"), "naopen", KEY_NAOPEN, KEY_NAOPEN, KEY_NAOPEN),
        # Dedicated dha/dhin strokes (ajaysm), at recorded pitch.
        region(os.path.join(DL, "171900__ajaysm__dha-stroke.wav"),  "dha",  KEY_DHA,  KEY_DHA,  KEY_DHA),
        region(os.path.join(DL, "171904__ajaysm__dhin-stroke.wav"), "dhin", KEY_DHIN, KEY_DHIN, KEY_DHIN),
        # Ringing dayan: wide zone so the engine plays tonicMidi -> rings at Sa.
        dict(name="tun", pcm=normalize(tun_pcm), rate=tun_rate,
             root=tun_root, lokey=40, hikey=90),
    ]
    sf2 = build_sf2("Tabla", regions, attack_s=0.001, release_s=0.15)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(sf2)
    print(f"wrote {OUT}  ({len(sf2)/1e6:.2f} MB)")

if __name__ == "__main__":
    main()
