#!/usr/bin/env python3
"""Compile selected VSCO-2-CE SFZ instruments into compact SoundFont (.sf2)
files that Apple's AVAudioUnitSampler can load.

Strategy: our engine plays at a fixed velocity (100), so we keep only the
SFZ regions whose velocity range contains 100 (one layer), downmix each WAV
to 16-bit mono and trim it, then emit a minimal but spec-correct SF2 with one
preset -> one instrument -> one zone per sample (global root key + amp env).
"""
import os, re, sys, struct, subprocess, urllib.parse, urllib.request, wave

RAW = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/"
WORK = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(WORK, "cache")
os.makedirs(CACHE, exist_ok=True)

FIXED_VEL = 100
TRIM_SECONDS = 7.0
FADE = 0.2

# ---- SFZ parsing -----------------------------------------------------------

def fetch_sfz(name):
    url = RAW + urllib.parse.quote(name)
    return urllib.request.urlopen(url).read().decode("utf-8", "replace")

def parse_sfz(txt):
    m = re.search(r"default_path=(.+)", txt)
    default_path = m.group(1).strip().replace("\\", "/") if m else ""
    g = {}
    head = txt.split("<region>")[0]
    for key in ("ampeg_attack", "ampeg_release"):
        mm = re.search(key + r"\s*=\s*([0-9.]+)", head)
        if mm:
            g[key] = float(mm.group(1))
    regions = []
    for blk in txt.split("<region>")[1:]:
        r = {}
        for key in ("sample", "lokey", "hikey", "pitch_keycenter", "lovel", "hivel"):
            mm = re.search(key + r"\s*=\s*(.+)", blk)
            if mm:
                r[key] = mm.group(1).strip()
        if "sample" in r:
            regions.append(r)
    return default_path, g, regions

# ---- sample fetch + convert ------------------------------------------------

def get_pcm(default_path, sample):
    rel = (default_path.rstrip("/\\") + "/" + sample).replace("\\", "/")
    cache_src = os.path.join(CACHE, sample)
    cache_mono = os.path.join(CACHE, "m_" + sample)
    if not os.path.exists(cache_src):
        url = RAW + urllib.parse.quote(rel)
        data = urllib.request.urlopen(url).read()
        with open(cache_src, "wb") as f:
            f.write(data)
    if not os.path.exists(cache_mono):
        # duration for a safe end fade
        dur = float(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nk=1:nw=1", cache_src]).strip())
        target = min(dur, TRIM_SECONDS)
        fstart = max(0.0, target - FADE)
        subprocess.check_call([
            "ffmpeg", "-y", "-loglevel", "error", "-i", cache_src,
            "-ac", "1", "-ar", "44100", "-sample_fmt", "s16",
            "-t", f"{target:.3f}",
            "-af", f"afade=t=out:st={fstart:.3f}:d={FADE}",
            cache_mono])
    w = wave.open(cache_mono, "rb")
    rate = w.getframerate()
    pcm = w.readframes(w.getnframes())
    w.close()
    return pcm, rate

# ---- SF2 writing -----------------------------------------------------------

# Generator operators
GEN_KEYRANGE = 43
GEN_ATTACK = 34
GEN_RELEASE = 38
GEN_ROOTKEY = 58
GEN_SAMPLEID = 53

def timecents(seconds):
    import math
    if seconds <= 0:
        return -12000
    return int(round(1200.0 * math.log2(seconds)))

def chunk(cid, data):
    out = cid + struct.pack("<I", len(data)) + data
    if len(data) % 2:
        out += b"\x00"
    return out

def listchunk(ltype, data):
    return chunk(b"LIST", ltype + data)

def name20(s):
    b = s.encode("ascii", "replace")[:20]
    return b + b"\x00" * (20 - len(b))

def build_sf2(name, regions_pcm, attack_s, release_s):
    """regions_pcm: list of dicts {name,pcm,rate,root,lokey,hikey}."""
    GAP = 46
    smpl = bytearray()
    shdr = b""
    for r in regions_pcm:
        start = len(smpl) // 2
        smpl += r["pcm"]
        end = len(smpl) // 2
        smpl += b"\x00\x00" * GAP
        startloop = start + 8
        endloop = end - 8 if (end - 8) > startloop else end - 1
        shdr += (name20(r["name"]) + struct.pack(
            "<IIIIIBbHH", start, end, startloop, endloop, r["rate"],
            r["root"], 0, 0, 1))  # type 1 = mono
    shdr += name20("EOS") + struct.pack("<IIIIIBbHH", 0, 0, 0, 0, 0, 0, 0, 0, 0)

    # instrument generators
    igen = b""
    ibag = b""
    imod = struct.pack("<HHhHH", 0, 0, 0, 0, 0)  # single terminal mod

    def gen(op, amount):
        return struct.pack("<HH", op, amount & 0xFFFF)

    # global zone: amp envelope
    ibag += struct.pack("<HH", len(igen) // 4, 0)
    igen += gen(GEN_ATTACK, timecents(attack_s))
    igen += gen(GEN_RELEASE, timecents(release_s))

    for i, r in enumerate(regions_pcm):
        ibag += struct.pack("<HH", len(igen) // 4, 0)
        igen += gen(GEN_KEYRANGE, r["lokey"] | (r["hikey"] << 8))
        igen += gen(GEN_ROOTKEY, r["root"])
        igen += gen(GEN_SAMPLEID, i)  # sampleID must be last in the zone
    ibag += struct.pack("<HH", len(igen) // 4, 0)  # terminal bag
    igen += gen(0, 0)  # terminal gen

    inst = name20(name) + struct.pack("<H", 0)
    inst += name20("EOI") + struct.pack("<H", (len(ibag) // 4) - 1)

    # preset layer -> instrument 0
    pgen = struct.pack("<HH", 41, 0) + struct.pack("<HH", 0, 0)  # instrument, terminal
    pbag = struct.pack("<HH", 0, 0) + struct.pack("<HH", 1, 1)   # zone, terminal
    pmod = struct.pack("<HHhHH", 0, 0, 0, 0, 0)
    phdr = (name20(name) + struct.pack("<HHHIII", 0, 0, 0, 0, 0, 0)
            + name20("EOP") + struct.pack("<HHHIII", 0, 0, 1, 0, 0, 0))

    info = listchunk(b"INFO",
                     chunk(b"ifil", struct.pack("<HH", 2, 1))
                     + chunk(b"isng", b"EMU8000\x00")
                     + chunk(b"INAM", name20(name)))
    sdta = listchunk(b"sdta", chunk(b"smpl", bytes(smpl)))
    pdta = listchunk(b"pdta",
                     chunk(b"phdr", phdr) + chunk(b"pbag", pbag)
                     + chunk(b"pmod", pmod) + chunk(b"pgen", pgen)
                     + chunk(b"inst", inst) + chunk(b"ibag", ibag)
                     + chunk(b"imod", imod) + chunk(b"igen", igen)
                     + chunk(b"shdr", shdr))
    return chunk(b"RIFF", b"sfbk" + info + sdta + pdta)

# ---- per-instrument driver -------------------------------------------------

def compile_instrument(sfz_name, out_name, display):
    print(f"[{display}] fetching SFZ {sfz_name}")
    txt = fetch_sfz(sfz_name)
    default_path, g, regions = parse_sfz(txt)
    # keep one layer: regions whose velocity range contains FIXED_VEL
    chosen = []
    for r in regions:
        lo = int(r.get("lovel", 0)); hi = int(r.get("hivel", 127))
        if lo <= FIXED_VEL <= hi:
            chosen.append(r)
    chosen.sort(key=lambda r: int(r["lokey"]))
    print(f"[{display}] {len(chosen)} zones (of {len(regions)} regions)")

    regions_pcm = []
    for idx, r in enumerate(chosen):
        pcm, rate = get_pcm(default_path, r["sample"])
        lo = int(r["lokey"]); hi = int(r["hikey"])
        if idx == 0:
            lo = 0                       # extend lowest zone down
        if idx == len(chosen) - 1:
            hi = 127                     # extend highest zone up
        regions_pcm.append(dict(name=r["sample"][:20], pcm=pcm, rate=rate,
                                root=int(r["pitch_keycenter"]),
                                lokey=lo, hikey=hi))
        sys.stdout.write("."); sys.stdout.flush()
    print()
    sf2 = build_sf2(display, regions_pcm, g.get("ampeg_attack", 0.01),
                    g.get("ampeg_release", 0.6))
    out_dir = os.path.join(os.path.dirname(WORK), "Pancham", "Resources", "Sounds")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, out_name)
    with open(out, "wb") as f:
        f.write(sf2)
    print(f"[{display}] wrote {out}  ({len(sf2)/1e6:.1f} MB)")

if __name__ == "__main__":
    compile_instrument("CelloEnsSusVib.sfz", "vsco-strings.sf2", "VSCO Strings")
    compile_instrument("OrganLoud.sfz", "vsco-organ.sf2", "VSCO Organ")
