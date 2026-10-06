# Snouty Trombone: spec

A slide trombone for the SYCL badge, played by hand over the SparkFun Qwiic
Mini dToF Imager (ams OSRAM TMF8820, 3x3 zones) on the Qwiic port, or with
the stick when no sensor is plugged in. Sibling of carts/snouty-theremin:
same sensor path (lib/tof.zig through one `input.sensor_frame`), same
streaming audio (lib/stream_audio.zig), same button conventions. PLAN.md has
status, bench numbers and the open questions.

Adrian's brief (2026-10-06): "a trombone cart with the time of flight sensor.
pixel art trombone on the badge. up and down moves the slide. side to side
tunes the embouchure."

## 1. What the attendee sees and hears

A pixel-art trombone fills the screen sideways: mouthpiece and bell section
at the left, the slide reaching right. Raise and lower a hand over the
sensor (lying face up on the table, or held facing the ceiling) and the slide
moves in and out with it, live, with the seven slide positions marked on the
outer tube. Sweep the hand left and right and the embouchure changes: the
horn jumps between partials of the harmonic series (the lip "buzz" cracks up
or down an overtone), so slide plus embouchure reach every note of a real
tenor trombone. Glissandos are the point: a long slide sweep sounds like a
trombone gliss, not a stepped keyboard.

The screen shows: the trombone (slide extension follows the hand at frame
rate; the bell glows/vibrates with the level), a slide-position ruler 1..7,
a partial ladder (2..8, current one lit, the embouchure "lip" marker
between them), the note name and cents, a small level meter, the input
source (SENSOR green / STICK amber), SOUND or a red MUTED, and notes floating
out of the bell. Pixel art is code-drawn (host generator to a table, like
the theremin's gen/tables.zig, no heavy comptime: Adrian's Mac Zig OOMs on
it). Placeholder-quality art is acceptable; it should read as a trombone at
arm's length.

## 2. Mapping

- **Slide = hand height** (distance in mm, the sensor's precise axis): hand
  close = slide in (1st position, highest), hand far = slide out (7th
  position, 6 semitones lower). Linear in mm across a ~350 mm throw
  (100..450 mm, tunable), continuous, cents not snapped: a trombone has no
  frets. Optional SNAP menu row (OFF default, SOFT pulls toward the 7
  positions like the theremin's SOFT snap).
- **Embouchure = hand side to side** (lib/tof_pose.zig coverage-weighted
  centroid x; never the argmin zone, see the theremin M1.2 lesson). The
  centroid is a continuous "lip tension" 0..1 spread over partials 2..8
  (Bb2 F3 Bb3 D4 F4 Ab4 Bb4 at 1st position; pedal 1 excluded by default).
  The sounding partial is the nearest one with hysteresis (no warble at a
  boundary); between partials the pitch bends a little toward the lip
  (up to ~+-40 cents, "lipping") before it cracks, and a crack plays a short
  split-tone blip. MIRROR menu row flips x (the breakout dangles on a cable).
- **Pitch** = partial n of the fundamental Bb1 (58.27 Hz) lowered by the
  slide's semitones, plus the lip bend. Concert pitch names on screen.
- **Blowing:** BLOW AUTO (default): a hand in range blows; taking it away
  ends the note (~100 ms release, like the theremin). BLOW A: hold A to
  blow, so the slide can be set silently and notes tongued. A in AUTO mode
  re-tongues (a fresh attack) without moving.
- **Plunger mute (B held):** a wah: closes a low-pass/formant over ~80 ms,
  opens on release. Hold B and wave the hand for doo-wah; the "sad
  trombone" (wah-wah-wah-waaah) should be playable.
- Despike and glide as the theremin does (3-frame median of distance,
  one-pole glide on the target, per-sample phase-increment glide).

## 3. Sound

Streaming 44.1 kHz u8 PCM via lib/stream_audio.zig (badge) and the
simulator `tone` import shim (wasm), like the theremin; never `cart.tone2`.
Integer per-sample DSP (u32 phase, Q15). A brassy voice: band-limited saw or
pulse through a one-pole/two-pole low-pass whose cutoff rises with level
(brass brightens as you blow harder), a short attack "blat" (pitch scoop of
~-30 cents settling over ~40 ms, a puff of noise), slight breath noise, the
plunger mute as a second filter. Must stay inside the theremin's audio CPU
budget (bench it).

Sound boots ON (an instrument, same deferred question as the theremin, one
line flips it); Select mutes; `-Dsound` does not apply.

## 4. Controls

| Button | Stick source (no sensor) | Sensor source | Menu open |
|---|---|---|---|
| Stick Up/Down | slide in / out (analog position, held) | - | row up/down |
| Stick Left/Right | embouchure down / up a partial (tap), lip bend while held | - | change value |
| A | blow (held) in STICK mode; re-tongue / blow per BLOW mode | same | next value |
| B (held) | plunger mute | plunger mute | close |
| Start (release) | open settings menu | same | close |
| Select (release) | mute / unmute | same | same |
| Start + Select | ignored (OS settings chord), as the theremin does | | |

Settings menu: BLOW (AUTO, A), SNAP (OFF, SOFT), MIRROR (OFF, ON),
PEDAL (OFF, ON: adds partial 1), TONE (BRIGHT, MELLOW), DEMO (OFF, ON: the
demo hand plays a phrase, e.g. the sad trombone and a gliss).

A demo hand (`fake_frame`, like the theremin's) drives the same path for
the wasm `debug_set_fake_sensor` export and a badge-bench poke, for preview
GIFs and benches.

## 5. Layout

As the theremin (copy its structure, not its code wholesale where it does
not fit): `main.zig`, `input.zig` (`sensor_frame`, source selection, demo
hand), `sensor.zig`, `hand.zig` (height + centroid from a frame),
`horn.zig` (slide/partial/lip physics, note names; host-tested), `play.zig`,
`voice.zig`, `audio.zig`, `screen.zig`, `gfx.zig`, `gen/` (generated art and
tables + fonts), `host_tests.zig`, `tools/gen_*.py` with `--check`.
