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

(Filled in as milestones land.)

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
