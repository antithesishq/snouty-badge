#!/usr/bin/env python3
"""Find a rich BATTLE round for docs/preview_m6.gif and cut the GIF.

  tools/m6_gif.py scan A0 A1 STEP      # try the FIGHT press at frames A0..A1
  tools/m6_gif.py cut  A OUTDIR GIF     # record with FIGHT at frame A, cut windows, make the GIF

Run from carts/snouty-gc (tools/m6_gif.py) after `zig build -Dcart=snouty-gc`.
The menus: Start, Start, Down x2 (BATTLE), A (select), A (setup), Up x2
to TIME, Left (2 MIN), Up to LIVES, Right (5), Down x3 to FIGHT!, A at
frame A (its frame picks the seed). The autopilot drives SNOUTY.
"""
import json, os, shutil, subprocess, sys

WASM = "../../zig-out/bin/snouty-gc.wasm"
PREVIEW = "../../tools/preview.mjs"
SAMPLES = "debug_screen,debug_stunt,debug_safe,debug_me_out,debug_feed,debug_battle_end,debug_phase,debug_follow,debug_results_card"


def presses(a):
    return [
        "--call", "debug_set_autopilot:1",
        "--press", "START:2-2", "--press", "START:24-24",
        "--press", "DOWN:50-50,DOWN:66-66", "--press", "A:96-96",
        "--press", "A:150-150",
        "--press", "UP:190-190,UP:204-204", "--press", "LEFT:222-222",
        "--press", "UP:244-244", "--press", "RIGHT:262-262",
        "--press", "DOWN:284-284,DOWN:290-290,DOWN:296-296",
        "--press", "A:%d-%d" % (a, a),
    ]


def run(a, frames, out, every=None, extra=()):
    cmd = ["node", PREVIEW, WASM, "--frames", str(frames), "--out", out,
           "--sample", SAMPLES, "--sample-every", "1"] + presses(a) + list(extra)
    if every:
        cmd += ["--every", str(every)]
    else:
        cmd += ["--quiet"]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    j = json.load(open(os.path.join(out, "frames.json")))
    s = j["samples"]
    return s["ticks"], s["values"]


def events(ticks, v):
    ev = {"stunt": [], "safe": [], "out": None, "end": None, "kill": [], "results": None}
    prev = {}
    for i, t in enumerate(ticks):
        st = v["debug_stunt"][i]
        if st and (st & 255) == 49:
            ev["stunt"].append((t, st >> 8))
        if v["debug_safe"][i] == 90 and v["debug_follow"][i] == 0 and not v["debug_me_out"][i]:
            ev["safe"].append(t)
        f = v["debug_feed"][i]
        if f and (f & 255) == 59 and (f >> 8) == 7:
            ev["kill"].append(t)
        if v["debug_me_out"][i] and ev["out"] is None:
            ev["out"] = t
        if v["debug_battle_end"][i] and ev["end"] is None:
            ev["end"] = t
        if v["debug_screen"][i] == 5 and ev["results"] is None:
            ev["results"] = t
    return ev


def scan(a0, a1, step):
    for a in range(a0, a1 + 1, step):
        ticks, v = run(a, 9500, "out/m6scan")
        e = events(ticks, v)
        print(a, "stunts", e["stunt"], "safe", e["safe"][:3], "kills", len(e["kill"]), "out", e["out"], "end", e["end"], "results", e["results"], flush=True)


def cut(a, outdir, gif):
    raw = outdir + "_raw"
    shutil.rmtree(raw, ignore_errors=True)
    ticks, v = run(a, 9500, raw + "_probe")
    e = events(ticks, v)
    res = e["results"]
    # A then A: the winner card, then the standings.
    extra = ["--press", "A:%d-%d" % (res + 100, res + 100)]
    ticks, v = run(a, res + 200, raw, every=1, extra=extra)
    keep = []

    def span(lo, hi, every=3):
        keep.extend(range(max(0, lo), hi, every))

    # Every third update (real time at 50 ms a frame), menus quicker.
    span(0, 30, 6)            # splash / title
    span(30, a + 1, 4)        # menu, BATTLE row, select, setup
    span(a + 1, a + 215)      # the KILL -9 card and the countdown
    span(a + 215, a + 300)    # the first seconds of the round
    for t, k in e["stunt"][:3]:
        span(t - 24, t + 40)  # STACK SMASH / CLEAN LANDING
    for t in e["kill"][:1]:
        span(t - 30, t + 30)  # kill -9 in the feed
    if e["safe"]:
        t = e["safe"][0]
        span(t - 60, t + 60)  # a wreck, the respawn, SAFE MODE
    if e["out"]:
        span(e["out"] - 40, e["out"] + 130)   # the last life: the claw
        span(e["out"] + 200, e["out"] + 290)  # the kill leader's camera
    span(e["end"] - 100, e["end"] + 40)       # the clock runs out
    span(res, res + 60, 4)                    # the winner card
    span(res + 101, res + 200, 4)             # the standings
    keep = sorted(set(keep))
    shutil.rmtree(outdir, ignore_errors=True)
    os.makedirs(outdir)
    n = 0
    for f in keep:
        src = os.path.join(raw, "frame_%04d.png" % f)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(outdir, "frame_%05d.png" % n))
            n += 1
    print("events", e, "frames", n)
    subprocess.run(["python3", "../../tools/make_gif.py", outdir, gif, "--scale", "2", "--ms", "50"], check=True)


if __name__ == "__main__":
    if sys.argv[1] == "scan":
        scan(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    else:
        cut(int(sys.argv[2]), sys.argv[3], sys.argv[4])
