# Snoutenstein 3D

Third badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a Wolfenstein-style raycaster starring Snouty, with keyed doors,
three weapons, a Doom-style portrait HUD and a time rewind implemented as
deterministic replay. `SPEC.md` is the design, `PLAN.md` the per-milestone
execution plan and contracts, `ASSETS.md` the pixel-art brief. Sibling repos
`../snouty-badge` and `../snouty-bugs` solved the toolchain first; their
CLAUDE.md files have the long explanations, this one summarises.

## Layout

- `cart/src/main.zig` — entry, top-level modes, wasm shims, debug exports.
- `cart/src/fixed.zig`, `state.zig`, `sim.zig`, `levels.zig` — the simulation.
  Pure Zig, no cart-api import, `zig test cart/src/sim.zig` runs on the host.
- `cart/src/render/` — raycaster, textures, sprites, HUD (cart-api users).
- `cart/src/levels/*.txt` — ASCII levels, embedded at comptime (must live
  under the module root, hence not a top-level `levels/`).
- `cart/build/convert_gfx.zig`, `cart/src/packed_int_array.zig` — upstream copies.
- `assets/gen/*.png` — build inputs (committed); `tools/prepare_assets.py` writes them.
- `tools/` — `preview.mjs` (headless wasm -> PNG + export assertions),
  `serve-cart.mjs`, `make_gif.py`, `import_wolf.py`, input scripts in `tools/scripts/`.
- `../sycl-badge/` — upstream SDK, read-only path dependency.

## Hardware (SYCL Badge V2)

RP2354B, Cortex-M33 at 150 MHz with FPU, Core 1 runs the cart. Screen
160x128 RGB565, framebuffer column-major `cart.framebuffer[x][y]` of
`Pixel` (`Pixel.from_color` handles wasm byte order; on hardware it is a
bitcast). Cart RAM 307 KB, binary at most 256 KB; our budget ELF
`.text`+`.data` <= 140 KB, `.bss` <= 120 KB (`size -A`). Inputs
`cart.controls`; the OS owns Start+Select and joystick click. `tone2` one
voice. Neopixels at or below 10/255 per channel.

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
- This Zig (`0.17.0-dev.1936`) has no `**` array repetition (use `@splat`),
  `std.mem.trimEnd` not `trimRight`, `@export(&fn, .{ .name })`.
- Levels: `#`/`1`-`8` walls, `.` floor, `D C I G E` doors, `S>` start with
  facing, `c i g + % $ *` pickups, `a w b s H` enemies (a = gnat).

## Building and previewing

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`). `zig build` writes
`zig-out/firmware/snoutenstein.{uf2,elf}` and `zig-out/bin/snoutenstein.wasm`.
Cold build about 4 min, warm seconds. `src/os/system/tracy_protocol.zig`
is a symlink into `../sycl-badge` (repos must be siblings).

```
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 600 --every 6 --out out/ \
  --script tools/scripts/m1_walk.json --dump-exports debug_mode,debug_render_us --expect "debug_mode == 1"
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 100
```

Browser: `node tools/serve-cart.mjs` plus `npm run dev` in
`../sycl-badge/simulator` (docs/RUNNING.md). Simulator quirks (framebuffer
at 0x20, buttons at 0x04, red/blue swap) are handled by `present_wasm` and
`read_controls` in `main.zig`.

## Conventions

snake_case, 4-space indent, `zig fmt`. Fixed pools, no allocation,
tick-based timing (1 tick = 1/60 s). Never commit the generated `gfx.zig`.
Commit messages: short imperative subject, body explains why. Milestone
hand-off: tag, GIF in `docs/`, "pull and run this" note.
