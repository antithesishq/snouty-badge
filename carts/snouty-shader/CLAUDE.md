# Snouty Shader

A Shadertoy-style gallery of six abstract per-pixel shaders driven by your
hand over the TMF8820 time-of-flight breakout (docs/TOF.md). `SPEC.md` is
the design, `PLAN.md` the milestones, status, bench numbers and deferred
decisions. The repository's CLAUDE.md holds the shared hardware, cart API
and build notes.

## Layout

- `cart/src/main.zig`: `start()`, `update()`, debug exports, wasm shims.
- `cart/src/app.zig`: buttons to actions (the Start+Select chord ignored,
  Start toggles sound on release), attract. Pure, host-tested.
- `cart/src/hand.zig`: the hand and its 3x3 cells from the sensor or the
  stick (B + stick); nothing else (no attract hand: Adrian removed it so
  the sensor demos honestly). `sensor.zig` is the driver integration
  point (morph's, same orientation default).
- `cart/src/uniforms.zig` (smoothing, punch, flash, palette kick) and
  `field.zig` (3x3 to 80x64 Catmull-Rom).
- `cart/src/programs.zig` + `programs/*.zig`: INK, RIPPLE, LAVA, ECHO,
  CELLS, KALEIDO; each has `init` (tables at start), `enter`, `render`
  into the 80x64 `surface.zig` (spread RGB565, bilinear 2x upscale).
- `palette.zig` (cosine palettes), `noise.zig` (tileable gradient noise
  texture), `hud.zig` (inputs panel, toasts), `sound.zig`, `config.zig`
  (shared knobs; each program's look knobs are at the top of its file).
- `math.zig`, `text.zig`: per-cart copies (from snouty-morph).
- `tools/scripts/`: badge-bench and GIF input scripts.

## Rules that bite

- f32 only and no libm: `zig build check-float` covers this cart.
- Per-pixel loops are integer / fixed point; f32 per frame or per grid
  point only. Every program must stay under 12 ms worst in badge-bench.
- Big tables live in globals built at start() (32 KB stack; Adrian's Mac
  Zig dislikes heavy comptime).
- Sound boots off (`-Dsound=true` flips it); badge builds never call
  `cart.tone2` (lib/tone_stream.zig). Never write `cart.neopixels`.
- Never bind the stick click; nothing reacts while Start+Select are held.

## Commands (repository root)

```sh
zig build -Dcart=snouty-shader
zig build test
zig build check-float -Dcart=snouty-shader
badge-bench/bench.sh zig-out/firmware/snouty-shader.elf --symbols
```

`docs/RUNNING.md` has the simulator, preview, GIF and bench recipes.
