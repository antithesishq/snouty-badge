#!/usr/bin/env python3
"""Generate the background music table (SPEC.md section 8, cart/src/music.zig).

Run from the cart directory:  python3 tools/gen_music.py

Reads tools/music/gymnopedie_1.mid: Erik Satie, Gymnopedie No. 1 (1888),
typeset by Evin Robertson for the Mutopia Project (Mutopia-2014/12/14-37)
and placed in the public domain; gymnopedie_1.ly beside it is the source
the MIDI was made from. Writes cart/src/music_data.zig, deterministically.

The arrangement (the cart's voices, music.zig `Voice`):
  voice 0  lead: the melody (treble notes that sound alone)
  voice 1  echo: the melody again, `ECHO_STEPS` later and quieter
  2..7     pool: the accompaniment chords (rolled upwards, `ROLL_STEPS`
           per note) and the bass, an octave up below C3 so the badge's
           small speaker can carry it
Time is in steps of a sixteenth of a quarter note (24 MIDI ticks). The
piece is stored as its three sections (the 31-bar body and the two
8-bar endings) and played body, ending 1, body, ending 2, rest, loop.

Each note is a u32 (music.zig `Note`, a packed struct, LSB first):
  start 11 bits (step within its section), dur 8 (steps), pitch 7 (MIDI),
  voice 3, bass 1, vel 2 (0..3, from the MIDI velocity).
Needs nothing beyond the standard library.
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
MID = os.path.join(HERE, "music", "gymnopedie_1.mid")
OUT = os.path.join(HERE, "..", "cart", "src", "music_data.zig")

TICKS_PER_STEP = 24  # 384 per quarter / 16
BAR = 3 * 384  # 3/4
SECTIONS = [("body", 0, 31 * BAR), ("ending1", 31 * BAR, 39 * BAR), ("ending2", 39 * BAR, 47 * BAR)]
ORDER = ["body", "ending1", "body", "ending2"]
REST_BARS = 2  # silence before the loop
ECHO_STEPS = 6  # 3/8 of a beat
ROLL_STEPS = 1
POOL = range(2, 8)


def vlq(d, i):
    v = 0
    while True:
        b = d[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if b < 0x80:
            return v, i


def read_tracks(path):
    """Notes per track as (start_tick, dur_ticks, pitch, velocity)."""
    d = open(path, "rb").read()
    assert d[:4] == b"MThd"
    _, ntracks, division = struct.unpack(">HHH", d[8:14])
    assert division == 384, division
    i = 14
    tracks = []
    for _ in range(ntracks):
        assert d[i : i + 4] == b"MTrk"
        length = struct.unpack(">I", d[i + 4 : i + 8])[0]
        j, end, i = i + 8, i + 8 + length, i + 8 + length
        tick, status, sounding, notes = 0, 0, {}, []
        while j < end:
            dt, j = vlq(d, j)
            tick += dt
            s = d[j]
            if s == 0xFF:
                n, k = vlq(d, j + 2)
                j = k + n
                continue
            if s in (0xF0, 0xF7):
                n, k = vlq(d, j + 1)
                j = k + n
                continue
            if s & 0x80:
                status = s
                j += 1
            kind = status >> 4
            if kind in (0xC, 0xD):
                j += 1
                continue
            a, b = d[j], d[j + 1]
            j += 2
            if kind == 0x9 and b > 0:
                sounding.setdefault(a, []).append((tick, b))
            elif kind in (0x8, 0x9) and sounding.get(a):
                start, vel = sounding[a].pop(0)
                notes.append((start, tick - start, a, vel))
        tracks.append(sorted(notes))
    return tracks


def fix_collision(treble):
    """Bars 9-12: the melody's tied F#4 (4 bars from tick 9216) shares its
    pitch with the accompaniment's F#4 on each beat 2, and LilyPond's MIDI
    cuts a sounding note when the same pitch starts again, so the tie comes
    out as a quarter and each chord F#4 runs to the next one. Restore the
    score (gymnopedie_1.ly bars 9-12: `fis2.) ~ fis2. ~ fis2. ~ fis2.`)."""
    out = []
    for start, dur, pitch, vel in treble:
        if (start, pitch) == (9216, 66):
            assert dur == 384, dur
            dur = 4 * BAR
        elif pitch == 66 and 9600 <= start <= 13056 and dur != 768:
            dur = 768  # `r4 <fis d b>2`: a half note
        out.append((start, dur, pitch, vel))
    return out


def split_treble(treble):
    """Melody = notes that sound alone; a group of two or more notes with the
    same start and duration is an accompaniment chord."""
    groups = {}
    for n in treble:
        groups.setdefault((n[0], n[1]), []).append(n)
    melody, chords = [], []
    for key in sorted(groups):
        g = groups[key]
        (chords if len(g) >= 2 else melody).append(g)
    # One melody note at a time.
    starts = [g[0][0] for g in melody]
    assert len(starts) == len(set(starts)), "two single notes start together"
    return [g[0] for g in melody], [sorted(g, key=lambda n: n[2]) for g in chords]


def vel2(v):
    return 0 if v < 70 else 1 if v < 85 else 2 if v < 95 else 3


def build():
    tracks = read_tracks(MID)
    treble, bass = fix_collision(tracks[1]), tracks[2]
    melody, chords = split_treble(treble)

    # (start_step, dur_steps, pitch, role, vel) with role lead/echo/pad/bass.
    events = []
    for start, dur, pitch, vel in melody:
        s, d = start // TICKS_PER_STEP, dur // TICKS_PER_STEP
        events.append((s, d, pitch, "lead", vel2(vel)))
        events.append((s + ECHO_STEPS, d, pitch, "echo", max(vel2(vel) - 1, 0)))
    taken = set()
    for g in chords:
        for k, (start, dur, pitch, vel) in enumerate(g):
            s, d = start // TICKS_PER_STEP, dur // TICKS_PER_STEP
            off = k * ROLL_STEPS
            events.append((s + off, d - off, pitch, "pad", vel2(vel)))
            taken.add((s, pitch))
    for start, dur, pitch, vel in bass:
        s, d = start // TICKS_PER_STEP, dur // TICKS_PER_STEP
        while pitch < 48:
            pitch += 12
        if (s, pitch) in taken:
            continue  # already in the chord above, or the octave-up copy of D3
        taken.add((s, pitch))
        events.append((s, d, pitch, "bass", vel2(vel)))
    for s, d, *_ in events:
        assert s * TICKS_PER_STEP < SECTIONS[-1][2] and d > 0

    sections = {}
    for name, lo, hi in SECTIONS:
        lo_s, hi_s = lo // TICKS_PER_STEP, hi // TICKS_PER_STEP
        evs = sorted(
            (e for e in events if lo_s <= e[0] < hi_s),
            key=lambda e: (e[0], {"lead": 0, "echo": 1, "pad": 2, "bass": 3}[e[3]], e[2]),
        )
        # Echoes spilling past the section end are dropped (none do).
        evs = [(s - lo_s, min(d, 255), p, r, v) for s, d, p, r, v in evs]
        sections[name] = (pack(name, evs), hi_s - lo_s)
    return sections


def pack(name, evs):
    """Assign pool voices (the one free longest) and pack."""
    free_at = {v: -1 for v in POOL}
    words = []
    steals = 0
    for s, d, p, role, vel in evs:
        if role == "lead":
            voice = 0
        elif role == "echo":
            voice = 1
        else:
            ready = [v for v in POOL if free_at[v] <= s]
            if ready:
                voice = min(ready, key=lambda v: free_at[v])
            else:
                voice = min(POOL, key=lambda v: free_at[v])
                steals += 1
            free_at[voice] = s + d
        assert s < 2048 and d < 256 and p < 128
        bass = 1 if role == "bass" else 0
        words.append(s | d << 11 | p << 19 | voice << 26 | bass << 29 | vel << 30)
    assert steals == 0, f"{name}: {steals} pool notes had no free voice"
    return words


def main():
    sections = build()
    rest = REST_BARS * BAR // TICKS_PER_STEP
    lines = [
        "//! Generated by tools/gen_music.py from tools/music/gymnopedie_1.mid",
        "//! (Erik Satie, Gymnopedie No. 1, 1888; Mutopia Project typesetting,",
        "//! public domain). Do not edit; re-run the generator.",
        "",
        "/// MIDI ticks per quarter note / steps per quarter note.",
        f"pub const steps_per_quarter = {384 // TICKS_PER_STEP};",
        "",
    ]
    for name, (words, steps) in sections.items():
        lines.append(f"/// {len(words)} notes, {steps} steps.")
        lines.append(f"pub const {name} = [_]u32{{")
        for k in range(0, len(words), 6):
            lines.append("    " + " ".join(f"0x{w:08x}," for w in words[k : k + 6]))
        lines.append("};")
        lines.append(f"pub const {name}_steps: u16 = {steps};")
        lines.append("")
    lines.append("/// Play order; an empty section is the rest before the loop.")
    lines.append("pub const order = [_]Section{")
    for name in ORDER:
        lines.append(f"    .{{ .notes = &{name}, .steps = {name}_steps }},")
    lines.append(f"    .{{ .notes = &.{{}}, .steps = {rest} }},")
    lines.append("};")
    lines.append("")
    lines.append("pub const Section = struct { notes: []const u32, steps: u16 };")
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    total = sum(len(w) for w, _ in sections.values())
    print(f"wrote {OUT}: {total} notes, {4 * total} bytes")


if __name__ == "__main__":
    main()
