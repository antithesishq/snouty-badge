# Snoutenstein 3D

Third badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a Wolfenstein-style raycaster starring Snouty, with keyed doors,
three weapons, a Doom-style portrait HUD and a time rewind implemented as
deterministic replay. `SPEC.md` is the design, `PLAN.md` the per-milestone
execution plan and contracts, `ASSETS.md` the pixel-art brief. Sibling carts
`../snouty-run` and `../snouty-bugs` solved the toolchain first; their
CLAUDE.md files have the long explanations, this one summarises.

## Layout

- `cart/src/main.zig` — entry, top-level modes, wasm shims, debug exports.
- `cart/src/fixed.zig`, `state.zig`, `sim.zig`, `ai.zig`, `projectiles.zig`,
  `rewind.zig`, `levels.zig` — the simulation. Pure Zig, no cart-api import,
  `zig test cart/src/<file>.zig` runs on the host. Deathmatch (M7, two
  badges): `match.zig` (the rules; `match.World` = GameState plus
  `state.Match`, and `match.G` for the lockstep) and `bot.zig` (the
  stand-in player for tests, previews and the bench), both pure;
  `deathmatch.zig` (lobby, match frame, results; cart-api). Party
  deathmatch (M8, up to 16 badges over USB and the laptop's `badge
  lobby`): `match.GN` (the N-player game for `lib/lockstep_n.zig`),
  `party.zig` (the PARTY lobby, match frame, results and the local
  bots-only match; cart-api), `render/scoreboard.zig` and
  `render/slots.zig` (rank line, kill feed, tables, slot colours);
  `match_party_test.zig` and `party_net_test.zig` (badges on the relay
  model, lib/party_virtual.zig) are its host tests. Arsenal (M9):
  `arsenal.zig` (the deathmatch-only weapons 4-7, weapon pads `@`, the
  `Match.dm_shots` pool; pure) with `arsenal_test.zig`; `render/fx.zig`
  (pad/shot/blast art, the blue death view; the warp-out is in sprites.zig). `Level.cells` is the
  packed width x height (read it through `Level.cell`).
- `cart/src/render/` — raycaster, textures, sprites, HUD (cart-api users);
  `cart/src/audio.zig` — tone2 (and the dormant neopixel effects), driven
  by diffing GameState.
- `cart/src/levels/*.txt` — ASCII levels, the source of truth. They are NOT
  parsed at comptime: `tools/gen_levels.sh` (runs `cart/src/gen_levels.zig`
  on the host through `cart/src/level_parse.zig`) writes
  `cart/src/levels/gen.zig`, plain literal data that is committed. Edit a
  `.txt`, rerun the script, commit both. `tools/check.sh` fails if `gen.zig`
  is stale. Tests parse mini-levels at run time with
  `level_parse.parse_level`.
- `cart/build/convert_gfx.zig`, `cart/src/packed_int_array.zig` — upstream copies.
- `assets/gen/*.png` — build inputs (committed); `tools/prepare_assets.py` writes them.
- `tools/` — `check_determinism.mjs`, `check_level.py`, `gen_levels.sh`,
  `import_wolf.py`, input scripts in `tools/scripts/` (the headless runner
  `preview.mjs`, wasm -> PNG + export assertions, and `serve-cart.mjs`,
  `make_gif.py` are shared, in `../../tools/`);
  `tools/check.sh` runs everything. Performance: `../../badge-bench/bench.sh
  ../../zig-out/firmware/snoutenstein.elf --script tools/scripts/X.json --symbols`
  (modelled floor; tune knobs with headroom, see PLAN.md status lines).
- `../../sycl-badge/` — upstream SDK, a git submodule at the repository root;
  read-only path dependency of the root package.

## Hardware (SYCL Badge V2)

RP2354B, Cortex-M33 at 150 MHz with FPU, Core 1 runs the cart. Screen
160x128 RGB565, framebuffer column-major `cart.framebuffer[x][y]` of
`Pixel` (`Pixel.from_color` handles wasm byte order; on hardware it is a
bitcast). Cart RAM 307 KB, binary at most 256 KB; our budget ELF
`.text`+`.data` <= 140 KB, `.bss` <= 120 KB (`size -A`). Inputs
`cart.controls`; the OS owns Start+Select and joystick click. `tone2` one
voice. Neopixels are off: the cart never writes a non-zero value; the LED
effects in `audio.zig` are compiled out and `zig build -Dcart=snoutenstein
-Dneopixels=true` re-enables them for development (docs/NEOPIXELS.md: a
coworker's badge shows the LEDs unusably bright even at 1%).

## Rules that matter here

- Simulation (`sim.zig` and what it calls) uses 16.16 fixed point only, its
  own xorshift PRNG in `GameState`, no `cart.*` calls, no f32. Replays must
  be bit-identical between the wasm simulator and the badge.
- `GameState` is plain data (no pointers); it is copied into rewind keyframes.
  Render-only state lives outside it.
- Rendering may use f32. Hot loops: no `PackedIntSlice.get`, no division per
  pixel; palettes are `Pixel` tables built at comptime or in `start()`.
- `.no_copy_full_frame`, redraw everything every frame. Upstream `blit` is
  never used.
- This Zig (`0.17.0`) has no `**` array repetition (use `@splat`),
  `std.mem.trimEnd` not `trimRight`, `@export(&fn, .{ .name })`.
- Keep comptime light. The macOS build of this Zig fails with a
  compiler-internal `error: OutOfMemory` on heavy comptime (the old comptime
  level parser triggered it; comptime `PackedIntSlice.get` loops are
  suspect too). Anything data-like goes through a host-side generator
  (`convert_gfx`, `gen_levels`) or a runtime check, never a big comptime
  loop. Adrian builds on a Mac, so this is a hard rule.
- Levels: `#`/`1`-`8` walls, `.` floor, `D C I G E` doors, `X` secret door, `S>` start with
  facing, `c i g + % $ * &` pickups, `@` deathmatch weapon pad (M9), `a w b s H` enemies (a = gnat), `P`
  deathmatch spawn (arenas only, M7).

## Building and previewing

Zig `0.17.0` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). Commands in this file run from this
cart's directory (`carts/snoutenstein/`) unless noted; `zig build` runs from
the repository root, two levels up. There `zig build -Dcart=snoutenstein` (or
plain `zig build` for every cart) writes `zig-out/firmware/snoutenstein.{uf2,elf}`
and `zig-out/bin/snoutenstein.wasm` (`../../zig-out/` from here). A cold build
of every cart takes several minutes; `-Dcart=` keeps it short. This cart's
`build.zig` is a module with `pub fn add(...)` that the root `build.zig`
calls; there is no per-cart `build.zig.zon`, and the one
`src/os/system/tracy_protocol.zig` symlink into the `sycl-badge` submodule is
at the repository root. Zig fetches packages into `zig-pkg/` there.

```
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 600 --every 6 --out out/ \
  --script tools/scripts/m1_walk.json --dump-exports debug_mode,debug_render_us --expect "debug_mode == 1"
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 100
```

Browser: `node ../../tools/serve-cart.mjs` plus `npm run dev` in
`../../sycl-badge/simulator` (docs/RUNNING.md). Simulator quirks (framebuffer
at 0x20, buttons at 0x04, red/blue swap) are handled by `present_wasm` and
`read_controls` in `main.zig`.

## Conventions

snake_case, 4-space indent, `zig fmt`. Fixed pools, no allocation,
tick-based timing (1 tick = 1/60 s). Never commit the generated `gfx.zig`.
Commit messages: short imperative subject, body explains why. Milestone
hand-off: tag, GIF in `docs/`, "pull and run this" note.
