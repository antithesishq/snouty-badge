# Snouty Trombone: plan

## M1: playable trombone (branch trombone/m1, tag snouty-trombone/m1)

1. Cart skeleton from snouty-theremin's structure, registered in the root
   build (app letter, carts list, CI release list, README cart table).
2. horn.zig: slide + embouchure + lip-bend model, host tests (positions
   1..7 hit equal-tempered semitones, partial hysteresis, monotonic slide
   gliss, crack only at boundaries).
3. hand.zig on lib/tof_pose.zig centroid + distance median; stick fallback;
   demo hand.
4. voice.zig brass voice + plunger mute, integer DSP, audio CPU benched.
5. Pixel-art trombone (host generator), slide moves with the hand, position
   ruler, partial ladder, note readout, bell notes.
6. Gates: `zig build`, `zig build test`, `zig build check-float
   -Dcart=snouty-trombone`, badge-bench worst update under budget with the
   demo hand and with `-Dtof-fake=true`, preview GIF docs/preview_m1.gif,
   docs/RUNNING.md.
7. Merge to main + push (Adrian asked 2026-10-06), tag snouty-trombone/m1.

Build from the repository root:

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-trombone          # zig-out/firmware/snouty-trombone.{uf2,elf}, zig-out/bin/snouty-trombone.wasm
zig build test -Dcart=snouty-trombone     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-trombone
python3 carts/snouty-trombone/tools/gen_tables.py --check
python3 carts/snouty-trombone/tools/gen_art.py --check
badge-bench/bench.sh zig-out/firmware/snouty-trombone.elf
```

## Deferred questions (defaults taken)

1. Slide on hand height (distance), embouchure on hand left/right
   (centroid x). Default: as briefed, sensor facing up.
2. Blowing: AUTO (hand in range sounds) default; BLOW A option. In AUTO,
   A also blows without a hand (so the stick-less sensor player can hold
   a note while moving the hand out of range); say if A should only
   re-tongue.
3. B = plunger mute (wah). Nothing displaced (new cart). B that closes
   the menu is not the plunger until it is let go.
4. Sound boots ON like the theremin.
5. Badge check: hardware feel of the throw (100..450 mm) and the
   left/right partial spacing. On synthetic frames lib/tof_pose.zig's x
   moves in steps across the 3x3 zones (a hand covering whole zones
   reads the same x over a range of positions), so with 7 partials the
   middle ones have narrow hand ranges at some heights (~10 mm for
   partials 4 and 6 at 4th position, wider elsewhere; a slow sweep still
   reaches every partial at every height, host test). If it is fiddly on
   the badge: a RANGE row (2..6 instead of 2..8), or a wider `lip_span`
   (hand.Config, 0.85 now).
6. Slide map linear in cents (equal hand movement = equal interval, 58 mm
   per semitone) rather than a real slide's lengths (each position ~6%
   longer than the last); the drawn positions are evenly spaced too.
7. The 7th partial is the real harmonic (31 cents flat, as on a real
   horn), not tempered; the tuning needle shows it.
8. The height is the mean of the hand zones within 40 mm of the nearest
   (as heights, not ray distances), not the closest zone alone (which
   jumps between fingertips and knuckles when the hand moves sideways),
   and not the pose's One Euro-filtered z (lag). The pose decides which
   zones are the hand (its background model), so a hand held perfectly
   still (within 6 mm) for 8 s would be absorbed into the background and
   the note would stop; real hands drift more than that.
9. Wide SPAD map (6, 41x52 deg) as the theremin: the near end of the
   throw (10 cm) sees ~75 mm across, so the hand still has lateral room.
10. Stick: the stick has no analogue axis, so Up/Down tap whole positions
    and glide when held (the theremin's pattern); Left/Right tap partials
    and bend when held. A gentle auto vibrato on long stick notes.
11. App letter: none. The letters in docs/LOCKSTEP.md (`lockstep.apps`)
    identify link-cable games to each other; the trombone has no link
    play (nor do the theremin, morph and shader). CI needs no change
    either: `tools/release_carts.sh` publishes every UF2 the build
    writes.
12. Brass voice: an 11%-duty band-limited pulse (harmonics 1..6 nearly
    level) rather than a saw (too dull: its spectral centroid at Bb3 was
    ~470 Hz against ~830 Hz now); output gain chosen for loudness with a
    soft knee (rms ~41 of 127 open; the theremin's sine is louder). Real
    speaker loudness and tone are unverified.

## Status

- 2026-10-06: SPEC + PLAN written; M1 built on `trombone/m1`, steps 1-6
  done; step 7 (merge to main, push) is the lead's: the branch and the
  tag `snouty-trombone/m1` are local, not pushed.

### M1 results (2026-10-06)

- Host tests: 33 in the cart (horn 8, hand 4, play 7, voice 8, audio 3,
  input 3), all passing under `zig build test`. Among them: positions
  1..7 hit equal-tempered semitones on every partial; partial
  hysteresis; a slow lip sweep cracks exactly once per boundary and bends
  smoothly between; the slide glisses monotonically (at most 2 cents per
  mm); a synthetic hand sweeping left to right through the real pose
  walks the partials up 2..8 without going back (and mirrored); the
  demo hand plays its whole tune through the sensor path with every
  note checked; the voice sounds the asked pitch at every partial
  (autocorrelation), the attack starts without a click and blats, the
  crack's split tone is gone within 50 ms, the plunger darkens and
  reopens in ~70 ms, rarely clips anywhere in the range.
- badge-bench, calibrated (2026-10-06), busy ms:
  - stick script (`badge-bench/carts/snouty-trombone.toml`, 900 frames
    of `tools/scripts/stick.json`): mean 1.37, p95 1.73, **worst 2.79**
    (frame 0, the first ring fill); 17% of the 16.7 ms budget. Hot:
    `voice.Voice.segment` 116 k cycles/frame (the voice, ~0.8 ms),
    `main.update` (drawing inlined) 69 k.
  - demo hand (`--no-config --frames 900 --poke snouty_trombone_fake=1`:
    synthetic frames, the pose and the player): mean 1.96, p95 3.18,
    **worst 3.31**; 20%.
  - `-Dtof-fake=true` (the real driver against the virtual TMF8820,
    900 frames): mean 2.84, p95 4.43, **worst 4.69** (the driver's bus
    transfers, 216 k cycles/frame); 28%.
  - Audio in all three: 1299 mixes, **0 underruns** after the
    1024-sample start-up, queue min 1536 mean ~1873 max 2048.
  - The theremin's numbers for comparison: stick 0.93 worst, `-Dtof-fake`
    3.65 worst; the trombone's voice costs ~4.7x the theremin's sine.
- WAVs (scratch only, not committed): a spectrogram of the demo-hand run
  shows the bugle call's partial steps, a smooth glissando curve, the
  plunger's darkened harmonics on each sad-trombone note and the
  wah-wah on the last.
- Preview: `docs/preview_m1.gif` (wasm, 19 s): the stick (Bb3, cracks to
  D4 and back, the sad trombone with wahs, a glissando out and back, lip
  slurs and a bend), then the demo hand (bugle call, glissando, sad
  trombone with the plunger), then MUTED.
- Size: `.text` 64 KB, `.data` 5 KB, `.bss` 11 KB (RAM cart, ~82 KB of
  the 307 KB window); UF2 163 KB.
- Unverified: everything on hardware (sensor feel, partial spacing, the
  speaker's rendering of the brass voice, loudness).
