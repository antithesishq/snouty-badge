# __NAME__

A cart made on the fly by the badge station (`badge-manager/build-job.sh`,
PLAN.md section 9) from `badge-manager/template-cart/`. The root `CLAUDE.md`
has the hardware, the cart API and the repository policies.

## Files

- `cart/src/main.zig`: the whole cart. `start()` sets 60 fps vsync and
  `.no_copy_full_frame`; `update()` reads the buttons, steps the state,
  redraws every pixel and ends with `present_wasm()` on wasm.
- `build.zig`: registers the cart with `os_cart.add` (ReleaseSmall, no asset
  pipeline). The root `build.zig` lists it once in `carts`.
- `summary.json` (written by the build agent): `title` (<= 20 characters),
  `description`, `controls`.

## What to edit, what not to touch

- Edit only files in this directory. More source files may sit beside
  `main.zig` and be imported with `@import("x.zig")`.
- Keep `comptime { cart.export_start_code(); }`, `read_controls()` and
  `present_wasm()` as they are: the web simulator and `tools/preview.mjs`
  need them (the root `CLAUDE.md`, "Simulator and headless preview").
- No sound, no neopixels, never bind `click`; keep comptime light, no
  allocation, 16.7 ms per `update()`.

## Build and preview (from the repository root)

```sh
zig build -Dcart=__NAME__                     # RAM cart; -Dcart-mode=both adds the XIP one
node tools/preview.mjs zig-out/bin/__NAME__.wasm --frames 180 --every 30 \
    --press A:30-40 --out carts/__NAME__/preview
python3 tools/make_gif.py carts/__NAME__/preview carts/__NAME__/preview.gif --scale 2 --ms 66
bash badge-bench/bench.sh zig-out/firmware/__NAME__.elf --frames 300
```
