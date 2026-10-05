# Running the Snouty Theremin cart

The cart lives in `carts/snouty-theremin/` of the snouty-badge repository:
a theremin for the TMF8820 time-of-flight breakout, playable with the
stick without it (`SPEC.md`). Commands run from that directory unless
noted; `zig build` and badge-bench run from the repository root (`../..`),
whose `zig-out/` holds the outputs. Prerequisites (Zig, Node, Python with
Pillow): the root [`docs/RUNNING.md`](../../../docs/RUNNING.md), sections
1 and 2.

## 1. Get it

Until the lead merges it, the cart is on branch `tof/theremin`:

```sh
git fetch && git checkout tof/theremin && git submodule update --init
```

## 2. Build and test (repository root)

```sh
zig build -Dcart=snouty-theremin              # firmware + wasm
zig build test -Dcart=snouty-theremin         # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-theremin  # no soft-float or libm in the ELF
```

Outputs: `zig-out/firmware/snouty-theremin.uf2` (the badge, a RAM cart,
~90 KB), `zig-out/firmware/snouty-theremin.elf` (badge-bench) and
`zig-out/bin/snouty-theremin.wasm` (simulator, headless tools).

## 3. Play

- **On a badge with the breakout** (once the driver is wired, PLAN.md):
  hold a hand 5 to 50 cm over the sensor; closer is higher. Left/Right
  pick 1 HAND or 2 HAND (2 HAND: right side pitch, left side volume;
  PITCH HAND in the menu swaps them). Up/Down move the octave.
- **Without the breakout** (and in the simulator): Up/Down tap through the
  scale and glide when held; Left/Right hold the note.
- A waveform, B scale, Start the settings menu (layout, wave, scale,
  snap, key, octave, pitch hand), Select mute. Sound is ON at boot.

## 4. Simulator

```sh
node ../../tools/serve-cart.mjs          # this cart's wasm on :2468
cd ../../sycl-badge/simulator && npm run dev
```

Audio in the simulator: the pinned simulator has no streaming audio, so
the wasm build re-strikes the simulator's `tone` voice every frame at the
theremin's pitch (triangle channel for SINE/TRI, pulse for SAW/SQR). It
follows the stick, but in 60 Hz steps and without the badge voice's glides,
band-limiting or filter. The badge sound is what badge-bench's `--wav`
writes. Silent in Safari (docs/SOUND.md).

## 5. Headless preview and the GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-theremin.wasm \
  --frames 900 --every 3 --out out/m1 --script tools/scripts/melody.json \
  --call-at "559 debug_set_fake_sensor:2" \
  --expect "debug_muted == 1" --expect "debug_source == 1"
python3 ../../tools/make_gif.py out/m1 docs/preview_m1.gif --scale 2 --ms 50
```

The script: B twice (MAJOR), Ode to Joy on Up/Down taps, a held glide up
and down while A cycles TRI, SAW, SQR, a scale run, a Right hold, A back to
SINE; at update 559 the demo hand (two hands) takes over; Select mutes at
841.

Debug exports (wasm only): `debug_set_fake_sensor(0|1|2)` (the demo hand:
off, one hand, two hands in 2 HAND), `debug_note` (cents above MIDI 0,
A4 = 6900), `debug_level` (voice level, 65536 full), `debug_source` (0
stick, 1 sensor), `debug_muted`, `debug_menu`, `debug_wave`,
`debug_scale`, `debug_set_scale(0..3)`, `debug_set_snap(0|1)`,
`debug_set_wave(0..3)`.

## 6. badge-bench (repository root)

```sh
badge-bench/bench.sh zig-out/firmware/snouty-theremin.elf --symbols --wav /tmp/theremin.wav
badge-bench/bench.sh zig-out/firmware/snouty-theremin.elf --no-config --frames 900 \
  --poke snouty_theremin_fake=2 --wav /tmp/theremin_hand.wav
```

The first run uses `badge-bench/carts/snouty-theremin.toml` (the melody
script, 900 frames); the second runs the demo hand through the sensor
path. Both must show `underruns 0 samples` in the audio report. PLAN.md
has the numbers.

## 7. Regenerating tables

`python3 tools/gen_tables.py` rewrites `cart/src/gen/tables.zig` (sine,
semitone and cent ratios, the MIDI-0 phase increment); `--check` exits 1
if the committed file differs.
