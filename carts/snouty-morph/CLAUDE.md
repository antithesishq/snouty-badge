# Snouty Morph

A demoscene mesh that follows your hand in 6DoF and deforms with it,
sensed by the TMF8820 time-of-flight breakout (docs/TOF.md, milestone M3
there). `SPEC.md` is the design (including what a 3x3 sensor can and
cannot tell), `PLAN.md` the milestones, status and deferred questions.
The repository's CLAUDE.md holds the shared hardware, cart API and build
notes.

## Layout

- `cart/src/main.zig`: `start()`, `update()`, debug exports, wasm shims.
- `cart/src/config.zig`: every knob (perf, camera, hand mapping,
  deformation strengths, sources). Tune here.
- `cart/src/hand.zig`: the virtual hand from the sensor or the stick
  (no attract hand: Adrian removed it so the sensor demos honestly);
  `sensor.zig` is the single integration point with the driver
  (`sensor_frame()`: lib/tof.zig on the badge, null in the simulator).
- `cart/src/select_hold.zig`: Select's press (sound) and 1 s hold
  (ZONES GRID / STRIPES, docs/TOF.md M5). Pure, host-tested.
- `hand.set_zones` switches the driver (`sensor.set_layout`) and the
  estimator; frames are read by their own `frame.layout`, and the HUD's
  zone map draws `hand.geom` (3x3 or 8 stripes).
- `cart/src/body.zig`: the 6DoF follow and the deformation springs
  (REACH, JELLY, TWIST, SHOCKWAVE) -> `Params`.
- `cart/src/mesh.zig`: the four generated meshes (`head_mesh.zig` is
  demosnout's head table, copied).
- `cart/src/render.zig` (vertex pipeline, light, bucket sort) and
  `raster.zig` (flat and Gouraud column fills).
- `cart/src/backdrop.zig`, `hud.zig`, `sound.zig`.
- `math.zig`, `palette.zig`, `input.zig`, `text.zig`: copies from
  demosnout (per-cart copies, never imported across carts).
- `../../lib/tof_pose.zig` (+ `tof_synth.zig`, `tof_types.zig`): the pose
  estimator, one module `tof_pose` (it re-exports `types` and `synth`).
- `tools/scripts/`: badge-bench (`bench_m0.json`) and GIF input scripts.

## Rules that bite

- f32 only and no libm: `zig build check-float` covers this cart. Use the
  sine table (`math.sin_turns`), `tof_pose.atan`/`atan2`, `@sqrt`.
- Host tests (`cart/src/host_tests.zig`) cover the cart-API-free modules:
  math, mesh, raster, hand, body, select_hold. lib/tof_pose's tests run from
  lib/tests.zig. Both in `zig build test`.
- No comptime-heavy data (Adrian's Mac Zig): meshes are generated at
  start(), the head is a small const table.
- Sound boots off (`-Dsound=true` flips it), Select toggles; badge builds
  never call `cart.tone2` (lib/tone_stream.zig instead).
- Never bind the stick click; ignore Start/Select while both are held.
- The `-Dtof-fake=true` build (sensor model + driver) is the RAM-tightest
  build (~15 KB left under the stack after M5); `mesh.zig`'s pools were
  trimmed to 1600 / 3072 for it. Check `size -A` when meshes or buffers grow.

## Commands (repository root)

```sh
zig build -Dcart=snouty-morph
zig build test
zig build check-float -Dcart=snouty-morph
badge-bench/bench.sh zig-out/firmware/snouty-morph.elf --symbols
node tools/preview.mjs zig-out/bin/snouty-morph.wasm --frames 960 --every 4 --out /tmp/m
```

`docs/RUNNING.md` has the simulator, preview and GIF recipes.
