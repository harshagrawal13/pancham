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

def prep(path, lowpass=None):
    """Downmix any input to mono 16-bit 44.1k (optionally rolling off harsh
    highs with a low-pass) so wave can read it."""
    os.makedirs(CACHE, exist_ok=True)
    tag = f"_lp{lowpass}" if lowpass else ""
    out = os.path.join(CACHE, f"m{tag}_" + os.path.basename(path))
    if not os.path.exists(out):
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", path,
               "-ac", "1", "-ar", "44100", "-sample_fmt", "s16"]
        if lowpass:
            cmd += ["-af", f"lowpass=f={lowpass}"]
        cmd.append(out)
        subprocess.check_call(cmd)
    return out

def read_wav(path, lowpass=None):
    w = wave.open(prep(path, lowpass), "rb")
    rate = w.getframerate()
    pcm = w.readframes(w.getnframes())
    w.close()
    return pcm, rate

# Loudness target (RMS over the hit body) and peak ceiling. RMS normalization
# makes every bol sound equally loud (peak normalization does not), and the
# target is hot so the kit is loud at full velocity.
TARGET_RMS = 0.22
CEILING = 0.97

def loudness_norm(a, rate, name="", target_rms=TARGET_RMS):
    """Scale to a common body RMS so all bols match in loudness, hard-limiting
    transient tips at the ceiling (a few clipped sample tips are inaudible on a
    drum and let the body sit loud). `target_rms` can be lowered per-bol to make
    a stroke sit softer."""
    n = len(a)
    w = min(n, max(1, int(min(0.6 * n, 0.25 * rate))))   # the loud "body"
    rms = math.sqrt(sum((a[i] / 32768.0) ** 2 for i in range(w)) / w) or 1e-9
    g = target_rms / rms
    lim = int(CEILING * 32767)
    clipped = 0
    out = array.array("h", bytes(2 * n))
    for i in range(n):
        v = int(a[i] * g)
        if v > lim:
            v = lim; clipped += 1
        elif v < -lim:
            v = -lim; clipped += 1
        out[i] = v
    if name:
        peak = max((abs(x) for x in out), default=0) / 32768.0
        body = math.sqrt(sum((out[i] / 32768.0) ** 2 for i in range(w)) / w)
        print(f"  {name:8} gain x{g:4.1f}  body RMS {body:.3f}  peak {peak:.2f}  clip {clipped / n * 100:.2f}%")
    return out

def process(pcm, rate, name="", onset_frac=0.35, preroll_ms=0.5,
            attack_ms=1.0, fade_ms=40.0, fade_frac=None, target_rms=TARGET_RMS):
    """Align every bol to its strong attack onset (where it first reaches
    `onset_frac` of peak) so the transient lands on the beat regardless of how
    slowly the recording swells; a 1 ms fade-in declicks the cut, a cosine
    fade-out softens the tail, then loudness-normalize."""
    a = array.array("h"); a.frombytes(pcm)
    pk = max((abs(x) for x in a), default=1) or 1
    thr = onset_frac * pk
    onset = next((i for i, v in enumerate(a) if v > thr or v < -thr), 0)
    start = max(0, onset - int(preroll_ms / 1000.0 * rate))
    a = a[start:]
    n = len(a)
    fi = min(int(attack_ms / 1000.0 * rate), n // 8)   # declick fade-in
    for i in range(fi):
        a[i] = int(a[i] * (i / fi))
    # soften the tail: a proportion of the sample (fade_frac) or a fixed time
    fl = (min(int(fade_frac * n), n // 2) if fade_frac is not None
          else min(int(fade_ms / 1000.0 * rate), n // 4))
    if fl > 1:
        base = n - fl
        for i in range(fl):
            f = 0.5 * (1 + math.cos(math.pi * (i + 1) / fl))  # 1 -> 0, smooth
            a[base + i] = int(a[base + i] * f)
    return loudness_norm(a, rate, name, target_rms).tobytes()

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

def region(path, name, root, lokey, hikey, lowpass=None, **kw):
    pcm, rate = read_wav(path, lowpass)
    return dict(name=name, pcm=process(pcm, rate, name, **kw), rate=rate,
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
        # Dedicated dha/dhin strokes (ajaysm). These are short, dry studio slaps
        # — brash next to the ringing mmiron strokes — so soften them: low-pass
        # the harsh highs, sit them a touch quieter, and give a longer tail fade.
        region(os.path.join(DL, "171900__ajaysm__dha-stroke.wav"),  "dha",  KEY_DHA,  KEY_DHA,  KEY_DHA,
               lowpass=4000, target_rms=0.17, fade_frac=0.45),
        region(os.path.join(DL, "171904__ajaysm__dhin-stroke.wav"), "dhin", KEY_DHIN, KEY_DHIN, KEY_DHIN,
               lowpass=6000, target_rms=0.18, fade_frac=0.4),
        # Ringing dayan: wide zone so the engine plays tonicMidi -> rings at Sa.
        # Longer tail fade since it's a long sustained ring.
        dict(name="tun", pcm=process(tun_pcm, tun_rate, "tun", fade_ms=120.0),
             rate=tun_rate, root=tun_root, lokey=40, hikey=90),
    ]
    sf2 = build_sf2("Tabla", regions, attack_s=0.001, release_s=0.15)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(sf2)
    print(f"wrote {OUT}  ({len(sf2)/1e6:.2f} MB)")

if __name__ == "__main__":
    main()
