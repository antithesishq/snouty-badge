# Running the Snouty Trombone cart

The cart lives in `carts/snouty-trombone/` of the snouty-badge repository:
a slide trombone for the TMF8820 time-of-flight breakout, playable with
the stick without it (`SPEC.md`). Commands run from that directory unless
noted; `zig build` and badge-bench run from the repository root (`../..`),
whose `zig-out/` holds the outputs. Prerequisites (Zig, Node, Python with
Pillow): the root [`docs/RUNNING.md`](../../../docs/RUNNING.md), sections
1 and 2.

## 1. Get it

Until the lead merges it, the cart is on branch `trombone/m1` (tag
`snouty-trombone/m1`):

```sh
git fetch && git checkout snouty-trombone/m1 && git submodule update --init
```

## 2. Build and test (repository root)

```sh
zig build -Dcart=snouty-trombone              # firmware + wasm
zig build test -Dcart=snouty-trombone         # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-trombone  # no soft-float or libm in the ELF
```

Outputs: `zig-out/firmware/snouty-trombone.uf2` (the badge, a RAM cart,
~165 KB as a UF2, ~82 KB of RAM), `zig-out/firmware/snouty-trombone.elf`
(badge-bench) and `zig-out/bin/snouty-trombone.wasm` (simulator,
headless tools).

## 3. Play

- **On a badge with the breakout** (Qwiic port, docs/TOF.md section 5),
  sensor facing up (on the table, or the badge held flat): hold a hand
  10 to 45 cm over it. Raise and lower the hand: the slide moves out and
  in with it (close = 1st position, high notes; far = 7th, six semitones
  lower). Move the hand left and right: the embouchure climbs the
  partials (left low, right high; the ladder at the bottom shows the note
  each partial plays at the current slide, the cyan marker is your lip).
  The horn blows while a hand is in range (BLOW AUTO); A re-tongues; hold
  B for the plunger (wah). If left and right come out reversed, set
  MIRROR ON in the menu. ZONES (menu) picks how the sensor sees you:
  STRIPES (default, docs/TOF.md M5: 8 full-height stripes, side to side
  about 3x finer, so each partial is about one stripe of hand travel,
  ~25 mm at 27 cm) or GRID (M1's 3x3, the partials closer together and
  some of them narrow). If STRIPES looks scrambled (the lip marker jumps,
  or goes the wrong way where GRID does not), set ZONES GRID.
- **Without the breakout** (and in the simulator): hold A to blow; Up and
  Down tap the slide one position in or out (hold to glide); Left and
  Right tap a partial down or up (hold to lip the pitch toward the next);
  B is the plunger.
- **The sad trombone:** 5th partial (the hand in the middle, or Right
  once from the start with the stick), slide 1, 2, 3, 4 (Down taps), each
  note tongued (A) with a quick B tap at its start; hold the last one and
  wobble the slide (or let the stick's vibrato do it) while B goes on and
  off. Or turn DEMO on and listen.
- Start opens the settings menu (BLOW AUTO/A, SNAP OFF/SOFT, MIRROR,
  PEDAL, TONE BRIGHT/MELLOW, ZONES STRIPES/GRID, DEMO); Select mutes.
  Sound is ON at boot. The demo hand plays in the ZONES layout too.

## 4. Simulator

```sh
node ../../tools/serve-cart.mjs          # this cart's wasm on :2468
cd ../../sycl-badge/simulator && npm run dev
```

The pinned simulator has no streaming audio, so the wasm build re-strikes
the simulator's `tone` voice every frame at the trombone's pitch (pulse
channel, 25% duty; 50% with the plunger shut). It follows the slide and
the partials in 60 Hz steps, without the badge voice's filter, blat,
cracks or wah. The badge sound is what badge-bench's `--wav` writes.
Silent in Safari (docs/SOUND.md). The simulator has no sensor: the stick
plays, or DEMO in the menu.

## 5. Headless preview and the GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-trombone.wasm \
  --frames 1160 --every 3 --out out/m1 --script tools/scripts/preview.json \
  --call-at "424 debug_set_fake_sensor:1" \
  --expect "debug_muted == 1" --expect "debug_source == 1"
python3 ../../tools/make_gif.py out/m1 docs/preview_m1.gif --scale 2 --ms 50
```

The script (the first part of `tools/scripts/stick.json`): A blows Bb3,
Right and Left crack to D4 and back, the sad trombone on Down taps with B
wahs, a held glissando out to 7th position and back, lip slurs up the
partials and a held lip bend; at update 424 the demo hand takes over
(a bugle call on 4th position, a glissando on the 5th partial, the sad
trombone with the plunger); Select mutes at 1136.

Debug exports (wasm only): `debug_set_fake_sensor(0|1)` (the demo hand),
`debug_note` (cents above MIDI 0, A4 = 6900), `debug_partial`,
`debug_slide` (cents, 0 = 1st position .. 600 = 7th), `debug_level`
(voice level, 65536 full), `debug_mute` (plunger held), `debug_source` (0
stick, 1 sensor), `debug_muted`, `debug_menu`, `debug_set_zones(n)` (1
GRID, 2 STRIPES, 0 just asks; returns 0 GRID, 1 STRIPES).

## 6. badge-bench (repository root)

```sh
badge-bench/bench.sh zig-out/firmware/snouty-trombone.elf --symbols --wav /tmp/trombone.wav
badge-bench/bench.sh zig-out/firmware/snouty-trombone.elf --no-config --frames 900 \
  --poke snouty_trombone_fake=1 --poke snouty_trombone_zones=1 --wav /tmp/trombone_demo.wav
zig build -Dcart=snouty-trombone -Dtof-fake=true && \
  badge-bench/bench.sh zig-out/firmware/snouty-trombone.elf --no-config --frames 900 \
  --poke snouty_trombone_zones=2
```

The first run uses `badge-bench/carts/snouty-trombone.toml` (the stick
script, 900 frames); the second runs the demo hand through the sensor
path; the third the real driver against the virtual TMF8820.
`--poke snouty_trombone_zones=1` runs GRID, `=2` STRIPES (the default
when not poked); it is applied before the first sensor poll. All must
show `underruns 0 samples` in the audio report. PLAN.md has the numbers.
Rebuild without `-Dtof-fake` afterwards.

## 7. Regenerating tables and art

`python3 tools/gen_tables.py` rewrites `cart/src/gen/tables.zig` (the
harmonic series, semitone and cent ratios, the MIDI-0 phase increment,
the filter coefficients);
`python3 tools/gen_art.py` rewrites `cart/src/gen/art.zig` (the trombone;
`--png out.png` previews it). `--check` on either exits 1 if the
committed file differs.
