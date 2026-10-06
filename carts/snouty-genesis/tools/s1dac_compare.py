#!/usr/bin/env python3
"""Compare the Sonic 1 DAC fake with the real Z80 (PLAN.md "Sonic 1 DAC fake").

Reads the two runs of tools/s1dac_trace.zig from <out-dir>:
s1dac-oracle.log/.wav (the full core, the game's Z80 driver) and
s1dac-fake.log/.wav (the RAM core with core/s1dac.zig), and prints:

- samples: every sample the driver started, in order, oracle against fake:
  the same 2A values (the fake's are a prefix of the oracle's or equal),
  the same count, the first write's time and the mean write spacing;
- the DAC write spacings of each sample kind (Z80 T-states);
- the sound: RMS of both WAVs per window (the SEGA chant, the title, Green
  Hill, the music test) and the correlation of the two over each.

    python3 carts/snouty-genesis/tools/s1dac_compare.py <out-dir>

Exit status 1 if a sample's values differ or the counts of samples differ.
"""
import array
import math
import sys
import wave

FRAME = 262 * 3420          # master clocks per frame
MCLK = 53693175             # master clock, Hz
SEGA_START = 0x79688        # the chant's first byte (bank 0x78000, window 9688)


def runs_of(path, oracle):
    """Samples as the driver started them: kind, id, [(time, value)]."""
    runs = []
    cur = None
    ids = []                # $1FFF commands, in order (both logs)
    with open(path) as f:
        for line in f:
            k, fr, t, a, v = line.split()
            if oracle:
                if k == "z80_window":
                    if int(a) != SEGA_START:
                        continue
                    cur = {"kind": "sega", "w": []}
                    runs.append(cur)
                elif k == "z80_ym":
                    a = int(a)
                    if a == 0x2B:
                        cur = {"kind": "dpcm", "w": []}
                        runs.append(cur)
                    elif a == 0x2A and cur is not None:
                        cur["w"].append((int(fr) * FRAME + int(t), int(v)))
            else:
                if k == "fake_take":
                    v = int(v)
                    cur = {"kind": "dpcm" if (v - 0x81) & 0xFF < 6 else "sega", "w": []}
                    runs.append(cur)
                elif k == "fake_dac" and cur is not None:
                    cur["w"].append((int(fr) * FRAME + int(t), int(v)))
            if k == "m68k_z80_write" and int(a) == 0x1FFF and int(v) & 0x80:
                ids.append(int(v))
    return runs, ids


def spacing(w):
    """Mean spacing of the writes in Z80 T-states (15 master clocks each)."""
    if len(w) < 2:
        return 0.0
    return (w[-1][0] - w[0][0]) / 15 / (len(w) - 1)


def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else 0


def load_wav(path):
    w = wave.open(path)
    a = array.array("B", w.readframes(w.getnframes()))
    return [x - 128 for x in a]


def window(s, f0, f1):
    return s[int(f0 * 44100 / 59.922743):int(f1 * 44100 / 59.922743)]


def rms(x):
    return math.sqrt(sum(v * v for v in x) / max(1, len(x)))


def corr(x, y):
    n = min(len(x), len(y))
    if n == 0:
        return 0.0
    mx = sum(x[:n]) / n
    my = sum(y[:n]) / n
    sxy = sum((a - mx) * (b - my) for a, b in zip(x[:n], y[:n]))
    sxx = sum((a - mx) ** 2 for a in x[:n])
    syy = sum((b - my) ** 2 for b in y[:n])
    return sxy / math.sqrt(sxx * syy) if sxx and syy else 0.0


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    d = sys.argv[1]
    o_runs, o_ids = runs_of(d + "/s1dac-oracle.log", True)
    f_runs, f_ids = runs_of(d + "/s1dac-fake.log", False)
    print(f"commands sent: oracle {len(o_ids)}, fake {len(f_ids)}; ids "
          + ", ".join(f"${i:02X} x{o_ids.count(i)}" for i in sorted(set(o_ids))))
    print(f"samples started: oracle {len(o_runs)}, fake {len(f_runs)}")
    bad = len(o_runs) != len(f_runs)
    by_kind = {}
    for o, f in zip(o_runs, f_runs):
        k = o["kind"]
        s = by_kind.setdefault(k, {"n": 0, "same": 0, "len": 0, "dt": [], "sp": [], "cut_o": 0, "cut_f": 0})
        s["n"] += 1
        ov = [v for _, v in o["w"]]
        fv = [v for _, v in f["w"]]
        n = min(len(ov), len(fv))
        if k != f["kind"] or ov[:n] != fv[:n]:
            bad = True
            print(f"  values differ: {k} oracle {len(ov)} writes, fake {len(fv)}")
        else:
            s["same"] += 1
        if len(ov) == len(fv):
            s["len"] += 1
        if o["w"] and f["w"]:
            s["dt"].append((f["w"][0][0] - o["w"][0][0]) / MCLK * 1e6)
        if len(o["w"]) > 10 and len(f["w"]) > 10:
            m = min(len(o["w"]), len(f["w"]))
            s["sp"].append(spacing(f["w"][:m]) / spacing(o["w"][:m]))
    for k, s in by_kind.items():
        dt = s["dt"]
        sp = s["sp"]
        adt = sorted(abs(x) for x in dt)
        p90 = adt[int(len(adt) * 0.9)] if adt else 0
        print(f"  {k}: {s['n']} samples, values equal {s['same']}, same length {s['len']} "
              f"(the rest cut by the next command a byte or more apart)")
        print(f"    first write, fake - oracle: median {median(dt):+.0f} us, 90% within {p90:.0f} us, "
              f"range {min(dt):+.0f} .. {max(dt):+.0f} us")
        print(f"    mean write spacing, fake / oracle (BUSREQ pauses included): median {median(sp):.4f}, "
              f"range {min(sp):.4f} .. {max(sp):.4f}")
    # The spacings themselves, by kind and delay count, oracle and fake.
    for name, runs in (("oracle", o_runs), ("fake", f_runs)):
        hist = {}
        for r in runs:
            w = r["w"]
            for i in range(len(w) - 1):
                t = round((w[i + 1][0] - w[i][0]) / 15)
                hist[t] = hist.get(t, 0) + 1
        top = sorted(hist.items(), key=lambda kv: -kv[1])[:8]
        print(f"  {name} write spacing (T-states x count): " + ", ".join(f"{t}x{n}" for t, n in top))

    o = load_wav(d + "/s1dac-oracle.wav")
    f = load_wav(d + "/s1dac-fake.wav")
    print("sound (RMS of the u8 stream around 128, oracle / fake, correlation):")
    for name, f0, f1 in (("SEGA chant", 150, 270), ("title", 400, 790), ("Green Hill", 1000, 1700),
                         ("music test", 1700, 10820), ("SEGA ($E1) with 2B off", 10810, 10930)):
        a = window(o, f0, f1)
        b = window(f, f0, f1)
        print(f"  {name:22s} frames {f0}-{f1}: {rms(a):5.1f} / {rms(b):5.1f}, r = {corr(a, b):.3f}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
