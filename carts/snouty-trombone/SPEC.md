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

- **Slide = hand height** (the sensor's precise axis): hand close = slide
  in (1st position, highest), hand far = slide out (7th position, 6
  semitones lower). Linear in mm and in cents across a 350 mm throw
  (100..450 mm, `horn.SlideMap`), continuous, cents not snapped: a
  trombone has no frets. SNAP menu row: OFF (default) or SOFT (pulls
  toward the 7 positions with the theremin's soft curve, still
  continuous). The height is each hand zone's distance along its ray
  turned into a height (`tables.cell_depth_q12`, the wide map's
  geometry), then the nearest hand zone and every hand zone within 40 mm
  of it averaged (`hand.read`): the single nearest zone jumps between
  fingertips and knuckles as the hand moves sideways. Which zones are the
  hand is the pose's background model (lib/tof_pose.zig), so the room
  never plays.
- **Embouchure = hand side to side** (lib/tof_pose.zig coverage-weighted
  centroid x; never the argmin zone, see the theremin M1.2 lesson).
  Centroid x -0.85..0.85 is a lip tension 0..1 (`hand.lip_t`) spread in
  equal bands over partials 2..8 (Bb2 F3 Bb3 D4 F4 Ab4 Bb4 at 1st
  position; PEDAL adds partial 1, Bb1). The sounding partial is the
  nearest one with 0.15 of a partial of hysteresis (no warble at a
  boundary); away from a partial's centre (0.12 dead zone) the lip bends
  the pitch toward the next one, up to 40 cents at the crack point
  ("lipping"); past it the horn cracks over with a short split-tone
  blip. MIRROR flips x (the breakout dangles on a cable). The partials
  use the real harmonic series (the 7th is 31 cents flat, as on a real
  horn).
- **Pitch** = partial n of the fundamental Bb1 (58.27 Hz) lowered by the
  slide's cents, plus the lip bend (`horn.pitch`). Concert pitch names on
  screen, in flats (Bb, Eb, Ab).
- **Blowing:** BLOW AUTO (default): a hand in range blows; taking it away
  ends the note (3 frames, ~100 ms, then a 23 ms fade). A in AUTO
  re-tongues (a short dip and a fresh attack without moving) and blows on
  its own without a hand. BLOW A: hold A to blow, so the slide can be set
  silently and notes tongued. Every onset is a tongued attack; a note
  starting after 0.2 s of quiet starts at its own pitch instead of
  sliding from the last one.
- **Plunger mute (B held):** closes over ~70 ms (the voice's filter falls
  2.25 octaves and resonates), opens on release: the wah. Hold B and wave
  the hand for doo-wah; the "sad trombone" (wah-wah-wah-waaah) is
  playable and is the demo's last phrase.
- Despike and glide as the theremin does: 3-frame median of the height,
  one-pole glide on the slide and lip targets (half the gap per update),
  per-sample phase-increment glide in the voice (~12 ms).

## 3. Sound

Streaming 44.1 kHz u8 PCM via lib/stream_audio.zig (badge) and the
simulator `tone` import shim (wasm), like the theremin; never `cart.tone2`.
Integer per-sample DSP (`voice.zig`: u32 phase, Q15, i64 products in the
filter):

- Source: a band-limited (PolyBLEP) narrow pulse, 11% duty: harmonics
  1..6 nearly level, then rolling off, the buzz of lips in a mouthpiece.
- Brass: a Chamberlin state-variable low-pass plus some of its band
  output (a formant), cutoff in eighth octaves through a generated
  coefficient table, rising with the level (670 Hz soft to 3.3 kHz full;
  TONE MELLOW 450 Hz to 1.6 kHz).
- Attack "blat": the cutoff overshoots by 1.25 octaves and settles over
  ~50 ms, the pitch scoops up from ~27 cents flat over ~40 ms, a puff of
  breath noise; slight breath noise under every note.
- Crack: the new partial at once (landing ~13 cents flat), the old one
  fading under it over ~15 ms, a puff of noise.
- Plunger: cutoff down 2.25 octaves, the filter's resonance up (an "oo"
  vowel), the output down to ~45%; opening it is the "wah".
- A soft knee before the output keeps peaks off the rails.
- Cost: ~0.8 ms of the 16.7 ms frame for 735 samples (badge-bench).

Sound boots ON (an instrument, same deferred question as the theremin, one
line flips it); Select mutes; `-Dsound` does not apply.

## 4. Controls

| Button | Stick source (no sensor) | Sensor source | Menu open |
|---|---|---|---|
| Stick Up/Down | tap: slide one position in / out; held past 0.25 s: the slide glides (accelerating) | - | row up/down |
| Stick Left/Right | tap: a partial down / up (a crack); held past 0.2 s: lip the pitch toward the next partial (up to ~38 cents, short of cracking) | - | change value |
| A | blow (held) | AUTO: re-tongue (and blow without a hand); BLOW A: blow (held) | change value |
| B (held) | plunger mute | plunger mute | close (B then is not the plunger until let go) |
| Start (release) | open settings menu | same | close |
| Select (release) | mute / unmute | same | same |
| Start + Select | ignored (OS settings chord), as the theremin does | | |
| Joystick click | never bound (the OS's FPS overlay) | | |

Settings menu: BLOW (AUTO, A), SNAP (OFF, SOFT), MIRROR (OFF, ON),
PEDAL (OFF, ON: adds partial 1), TONE (BRIGHT, MELLOW), DEMO (OFF, ON: the
demo hand plays). With the stick a gentle vibrato (+-10 cents, 5.5 Hz)
fades in on a note held still for 0.4 s; a hand brings its own.

A demo hand (`input.fake_frame`: a flat synthetic hand rendered by
lib/tof_synth.zig) drives the same path as the sensor (the pose,
`hand.read`, the player) for the DEMO row, the wasm
`debug_set_fake_sensor` export and the badge-bench poke
`snouty_trombone_fake`, and presses A and B on cue. Its tune: a bugle call
on 4th position (lip slurs D3 G3 B3 D4 B3 G3 D3), a glissando on the 5th
partial out to 7th position and back, the sad trombone (D4 Db4 C4 B3, a
plunger wah on each, the last held with slide vibrato and wah-wah), a
rest, round again (~12 s). A host test plays it through the real path and
checks every note.

## 4.1 Screen

160x128, `.no_copy_full_frame`, redrawn whole every update at 60 fps.

| Area | Content |
|---|---|
| y 0..9 | status: SENSOR / STICK / DEMO, AUTO or HOLD A, WAH while the plunger is shut, SOUND or a red MUTED |
| y 14..59 | the trombone (tools/gen_art.py): bell section, mouthpiece, chrome inner slide; the brass outer slide drawn 9 px per position out, live; the bell rim and throat glow with the level (the rim shivers when loud), sound arcs and notes float from the bell, the plunger cup sits in the bell when shut and swings away as it opens |
| y 61..72 | slide-position ruler 1..7 under the crook (the nearest position lit, green when within 12 cents), the crook marked in cyan |
| y 75..96 | the note (2x font), partial and position (P5 POS 3.9), cents and Hz, a +-50 cent tuning needle, a 7-segment level meter |
| y 97..111 | the partial ladder: one cell per partial with the note it plays at the current slide, the sounding one lit, the lip marker above |
| y 119 | rotating hints |

## 5. Layout

As the theremin (copy its structure, not its code wholesale where it does
not fit): `main.zig`, `input.zig` (`sensor_frame`, source selection, demo
hand), `sensor.zig`, `hand.zig` (height + centroid from a frame),
`horn.zig` (slide/partial/lip physics, note names; host-tested), `play.zig`,
`voice.zig`, `audio.zig`, `screen.zig`, `gfx.zig`, `gen/` (generated art and
tables + fonts), `host_tests.zig`, `tools/gen_*.py` with `--check`. As
built: `tools/gen_tables.py` (`gen/tables.zig`) and `tools/gen_art.py`
(`gen/art.zig`, rows of palette characters so the art reads in the
source).
