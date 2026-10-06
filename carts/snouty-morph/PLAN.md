# Snouty Morph: plan

`SPEC.md` is the design. Worktree `/home/exedev/snouty-badge-morph`,
branch `tof/morph` (not merged, not pushed: the lead integrates it with
the sensor driver). This cart is milestone M3 of docs/TOF.md.

Every milestone ends with: `zig build` (whole repository), `zig build
test`, `zig build check-float`, badge-bench numbers recorded here, a
preview GIF in `docs/`, and a local annotated tag `snouty-morph/mN`.

## M0: pose library, meshes, transform, ghost hand, stick

- `lib/tof_pose.zig`: Config, Estimator (background model, coverage,
  centroid with sub-zone shift, z, plane-fit tilt, moment yaw, swirl, One
  Euro filters, presence hysteresis), Pose. Re-exports `types`
  (tof_types) and `synth`.
- `lib/tof_synth.zig`: hand scene to Frame (+ Histograms).
- Host tests in those files, wired through `lib/tests.zig`.
- `carts/snouty-morph`: build.zig, root build.zig entry, CLAUDE.md list,
  badge-bench toml; `cart/src/` main (shims, debug exports), input, math,
  palette, text, config (knobs), mesh (generators: KNOT, BLOB, SNOUTY,
  IRIS), render (transform, lighting, bucket sort, flat + Gouraud column
  fill), hand (sources: sensor via `sensor.sensor_frame()`, stick, ghost
  through synth + estimator; spring follow), sensor (the integration
  point, returns null), hud (source label, mini map, toasts).
- Plain dark gradient backdrop.

Acceptance:
- Pose tests: z within 3 % over 100..500 mm; x/y continuous across cells
  and within 0.15 of the half field of view; pitch/roll within 6 degrees
  for +-30 degrees on a full-grid hand; yaw within 20 degrees on an
  elongated hand; absent, single-zone, and background-learning cases; the
  filter steady on a still hand and responsive on a step.
- The cart builds for badge and wasm, Start cycles four meshes, the ghost
  moves the mesh through all six DoF, stick input takes over and hands
  back, `zig build test` and `check-float` pass, badge-bench worst frame
  under 12 ms.

## M1: deformations, backdrops, polish, sound

- REACH, JELLY, TWIST, SHOCKWAVE (SPEC 3), palette flash, backdrop flash,
  screen shake.
- Backdrops: copper bars + stars, plasma, gradient + stars, cool copper.
- Greetings scroller in GHOST, toasts (mesh, sound), mini map polish.
- Sound: drone + punch thump, Select toggle, boots silent.
- Preview GIFs (`docs/preview_ghost.gif` ghost hand across meshes,
  `docs/preview_deform.gif` stick-driven deformations), docs/RUNNING.md.
- Perf pass with the knobs; numbers below.

Acceptance: each deformation visible in the GIFs; worst frame under 12 ms
over a run that visits all four meshes with punches; gate green.

## Status

### M0 — DONE 2026-10-05 (commit 454b557a, local tag `snouty-morph/m0`)

Pose library and the cart skeleton landed together; the first cut already
carried the deformations, backdrops and HUD, so M1 was tuning, perf and
polish. First full bench: worst 12.57 ms (25 % of cycles in software
64-bit divides in the edge setup), fixed in M1.

### M1 — DONE 2026-10-05 (local tag `snouty-morph/m1`)

- Pose accuracy (synthetic hands from tof_synth, `lib/tof_pose.zig`
  tests; numbers from a sweep at 0 and 2 mm noise): z worst 0.43 % over
  100..500 mm (test bound 3 %); lateral worst 3.8 mm from confidences, 2.0
  mm with histograms, for a 70 mm wide hand swept across the grid at 300
  mm where a zone is 58 mm (bounds 8 / 6 mm, monotonic); pitch/roll worst
  0.7 degrees for +-30 degrees on a hand covering the grid (bound 6); yaw
  worst 8.5 degrees on a 44 x 220 mm hand at 250 mm (bound 20), confidence
  under 0.1 for a hand covering all nine zones; One Euro: z spread under 3
  mm on a still hand with +-4 mm noise, a 200 -> 120 mm step within 8 mm
  after 10 frames; a 1.5 m/s approach reads under -800 mm/s. Caveat: the
  confidence model is the synth's own, so the no-histogram coverage is
  only as right as that model; retune `Config` against a real capture.
- badge-bench (calibrated, ELF sha256 `c21a00cd504c`, 3840 frames,
  `bench_m0.json`): busy ms worst 9.33 (frame 1239, BOING close up with
  the stick), mean 4.69, p95 8.22, 0 frames over 16.7 ms. Per mesh, worst
  / mean: KNOT 8.99 / 7.17, BOING 9.33 / 5.62, SNOUTY 4.34 / 2.68, IRIS
  4.73 / 3.28. Hot: update (vertex pipeline, backdrop) 46 %, column fills
  26 %, triangle setup 14 %, `api.text` 8 % (scroller and HUD), memcpy 6 %
  (backdrop columns). Under the 12 ms rule; knobs in `config.zig` if a
  mesh grows.
- Sizes (`size -A`): `.text` 83,056, `.data` 5,220, `.bss` 134,104 (mesh
  pools 2048 vertices / 4096 faces, per-frame buffers for 640 / 1152):
  222 KB of the 307 KB window, 32 KB of it stack.
- GIFs: `docs/preview_ghost.gif` (the ghost routine on KNOT),
  `docs/preview_deform.gif` (the stick through all four meshes).
- Gate: `zig build`, `zig build test` (exit 0; fresh worktrees need
  carts/snouty-boy/tests/roms copied in), `zig build check-float` (this
  cart included).
- Not done: no hardware run, sound unheard on a badge.
- M1.1 (tag snouty-morph/m1.1): `sensor.zig` runs lib/tof.zig (normal
  SPAD map, no histogram dumps); the cart imports one `tof` module that
  carries the driver, `types`, `pose` and `synth`. Bench with
  `-Dtof-fake=true`: worst 54 % of the budget.
- M1.2 (tag snouty-morph/m1.2, 2026-10-06): the GHOST attract hand is
  gone (Adrian: with the sensor pointed at nothing, or unplugged, the
  ghost still moved the mesh, which made the sensor hard to demo). Sources
  are now SENSOR (the breakout; with no hand in view the mesh rests),
  STICK, NO SENSOR; `config.hand_timeout` dropped; the scroller runs
  while no hand is in view; `docs/preview_ghost.gif` removed. badge-bench
  (calibrated, `bench_m0.json`, 3840 frames): worst 6.83 / mean 4.22 ms
  (no ghost frames any more), `-Dtof-fake=true` worst 10.10 / mean 5.72.

### M5 (docs/TOF.md M5: stripes and arm rejection) — built 2026-10-06, branch `tof/stripes`

- ZONES setting: GRID (default, the normal map 1) or STRIPES (the
  8-stripe user mask). Hold Select 1 s to flip it (`select_hold.zig`):
  Select's press still toggles the sound at once, and the hold undoes
  that toggle, so the gesture displaces nothing (every other button is
  bound; a long Select hold had no meaning). A `ZONES GRID` / `ZONES
  STRIPES` toast shows the result. Ignored during the Start+Select chord.
- `hand.set_zones` -> `sensor.set_layout` (driver `set_layout`: stop,
  pages, MEASURE, no reset) and `Estimator.set_layout` (starts afresh);
  frames of the other layout (in flight around a switch) are dropped
  before the estimator and the HUD. `-Dtof-fake=true` selects the
  model's SPAD-level hand scene (`user_scene = .hand`).
- STRIPES degrades as designed: y = 0 (the mesh rests at centre height),
  pitch and yaw confidence 0 (body.zig's tilt springs already scale by
  confidence, so they relax to rest), roll still measured; the pose's x
  is rescaled to GRID's angular scale so the mesh travels the same per
  hand movement. The HUD zone map draws `hand.geom` (8 thin bars).
- Arm rejection is the library's (x, y from the near cluster, 40 mm;
  z, tilt and yaw from the hand body, 100 mm); morph keeps the defaults.
- RAM: the `-Dtof-fake=true` ELF overflowed the window by ~2.4 KB with
  the M5 library code; `mesh.zig`'s pools went from 2048 / 4096 to
  1600 / 3072 (1458 / 2812 used, the mesh test checks it). Now ~15 KB
  left under the stack in the fake build, ~31 KB in the normal one.
- Tests: `select_hold.zig` (tap = sound only, 1 s hold = ZONES with the
  sound restored and only once, the chord never toggles), `hand.zig`
  (a STRIPES sweep: y 0, no pitch/yaw confidence, x never jumps more
  than 0.2 per frame; the same hand gives the same mesh x in GRID and
  STRIPES; stale GRID frames ignored; the hand rests across a switch).
- badge-bench (calibrated, `bench_m0.json`, 3840 frames), busy ms worst /
  mean: normal build GRID 6.83 / 4.23, STRIPES poke 6.83 / 4.23 (no
  sensor: unchanged from M1.2's 6.83 / 4.22); `-Dtof-fake=true` GRID
  10.12 / 5.73 (M1.2: 10.10 / 5.72), STRIPES 11.75 / 6.56. The STRIPES
  extra is the model tracing its hand SPAD by SPAD (360 samples per
  measurement), which a real sensor does not cost; still under the 12 ms
  rule, 0 frames over 16.7 ms.
- Not done: no hardware run. Hardware check: docs/TOF.md section 5, M5.

## Deferred questions (defaults taken)

1. Name: `snouty-morph` (binary `snouty-morph`).
2. Ghost hand runs through tof_synth + the real estimator (so attract
   shows the estimator's real behaviour); a direct path is one constant
   away if it looks worse than a pure Lissajous.
3. Hand closer = mesh closer (bigger). The opposite (push it away) is one
   sign.
4. The sensor faces the viewer; the default orientation mirrors x so the
   mesh follows the hand like a mirror. Final orientation comes from the
   M0 hardware photos (docs/TOF.md deferred question 2).
5. No histograms requested by default (30 Hz frames); the estimator uses
   them when the driver supplies them.
6. Sound off at boot (repo rule), Select toggles; the drone is quiet.
7. The Iris mark is built from arcs and a diamond rather than extruding
   the 24x24 bitmap (which would be ~1500 faces of staircase).
8. The hand's in-plane turn (yaw) turns the mesh in-plane; its tray tilt
   (pitch, roll) tilts it; twist comes from swirl and turning speed.
9. BOING is a purple and white Boing ball (UV sphere) instead of the
   icosphere blob in SPEC 3: the checker shows every deformation. An
   Amiga-style grid backdrop for it would be a nice swap for the plasma.
10. SNOUTY sticks its tongue out when the hand is very close (z > 0.78).
11. Attract scroller text is placeholder copy; Adrian may want his own.
12. `relearn()` (take the current view as background) has no button; the
    background model learns on its own. Hold-B-with-no-hand could map to
    it once the sensor is wired.
