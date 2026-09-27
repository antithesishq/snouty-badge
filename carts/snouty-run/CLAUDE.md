# Snouty Badge

Animated badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis. The cart shows pixel-art sprites of Snouty, the Antithesis mascot,
animated on the badge screen.

## Layout

- `assets/` — source art (PNG sprite sheets, reference images). Dropped in via scp.
- `cart/` — the Zig cart: `cart/src/main.zig` exports `start()` and `update()`.
- `../../sycl-badge/` — upstream badge repo (ZigEmbeddedGroup/sycl-badge), a git
  submodule at the repository root. Treat it as read-only reference and SDK; do not
  commit changes there.

## Target hardware (SYCL Badge V2)

- MCU: RP2354B. Core 0 runs the OS kernel, Core 1 runs the cart.
- Screen: 160x128, RGB565 (`DisplayColor` is packed r:u5 g:u6 b:u5; use
  `DisplayColor.rgb(0xRRGGBB)`).
- Framebuffer is column-major: `cart.framebuffer[x][y]`, type `Pixel`, write with
  `Pixel.from_color(color)` (handles wasm vs hardware byte order).
- Inputs: `cart.controls.*` (start, select, a, b, click, up, down, left, right).
  On wasm the simulator writes the button word to address 0x04 and upstream's
  platform never reads it, so `main.zig` has a wasm-only `read_controls()`.
- 5 neopixels (`cart.neopixels`, GRB, very bright; scale to ~10/255), one user LED,
  light sensor, battery level, speaker (`tone2`).
- Flash: 8000 pages of 256 bytes available via the cart API (`Zone`).

## Cart API (from `sycl-badge/src/os/cart/api.zig`)

Import as `@import("cart-api")`. Every cart must contain
`comptime { cart.export_start_code(); }`. Key calls:

- Frame pacing: `set_vsync_enabled(1000.0 / 60.0)`, `set_vsync_disabled()`,
  `set_vsync_dynamic()`. `present()` is called automatically after `update()`.
- Double buffering: `set_double_buffer_mode(.copy_forward | .no_copy_dirty_rect |
  .no_copy_full_frame | .{ .clear_full_frame = color })`. For a full-screen
  animation prefer `.no_copy_full_frame` or `.clear_full_frame` and redraw all.
- Drawing: `blit(BlitOptions)` (sprite `[*]const DisplayColor`, supports src_x/src_y,
  stride for atlases, flip_x/flip_y/rotate), `rect`, `oval`, `line`, `hline`,
  `vline`, `text` (8x8 font). `blit` has no transparency; skip a key color manually
  or write pixels directly like the dvd cart does.
- `mark_dirty_rect` if you write the framebuffer directly and use dirty-rect modes.
- `rand()`, `micros_since_boot()`, `trace()` for debug output.

Reference carts: `sycl-badge/showcase/carts/dvd` (bouncing PNG sprite, simplest
asset pipeline), `zeroman` (sprite atlases with palettes + transparency),
`plasma`/`lcd-text` (minimal).

## Asset pipeline

Two generator scripts write build inputs into `assets/gen/` (committed):
`tools/prepare_assets.py` (Snouty strip with magenta key, Iris 16x16) and
`tools/prepare_background.py` (four Green Hill Zone backdrop frames from the
rips in `assets/ref/`, plus the grass strip). PLAN.md v3 explains the palette
cycle and the column-dither waterfall. Backdrop frames are 8-bit, everything
else 4-bit.


Upstream converts PNGs to Zig at build time with `build/convert_gfx.zig` (uses the
`zigimg` dependency). Each input takes `bits` (1/2/4/8 palette bits per pixel) and a
`transparency` flag; output is a `gfx.zig` module exposing
`.width`, `.height`, `.colors` (palette of `DisplayColor`) and `.indices`
(`PackedIntSlice`). Copy `dvd/build/convert_gfx.zig` and `dvd/src/packed_int_array.zig`
into `cart/build/` and `cart/src/` rather than importing across repos.

Sprite guidance: indexed-color PNGs, at most 16 colors per sheet (4 bits) keeps flash
and RAM small. Animation frames go in one horizontal strip per animation; frame
width/height are constants in `main.zig`. Screen is 160x128 so a hero Snouty of
roughly 48-64 px tall reads well from a lanyard.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` (upstream's pin) is installed at
`~/.local/bin/zig`; `export PATH="$HOME/.local/bin:$PATH"`.

Commands in this file run from this cart's directory (`carts/snouty-run/`)
unless noted; `zig build` runs from the repository root, two levels up.

```
zig build                    # from the repository root: every cart
zig build -Dcart=snouty-run  # only this one (`-Dcart=snouty` works too)
```

produces `zig-out/firmware/snouty.uf2`, `zig-out/firmware/snouty.elf` and
`zig-out/bin/snouty.wasm` at the repository root (`../../zig-out/` from here).
A clean build of every cart takes several minutes; `-Dcart=` keeps it short.

The repository root is one Zig package: its `build.zig.zon` has the path
dependency `.sycl_badge = .{ .path = "sycl-badge" }` (the submodule) plus
`.microzig`/`.zigimg` entries, and its `build.zig` calls this cart's
`build.zig`, which is a module with `pub fn add(...)`. That calls upstream's
`add_os_cart` with a `custom_builder` that runs `cart/build/convert_gfx.zig` on
`assets/gen/*.png` to make the `gfx` module. Nothing in `sycl-badge` is patched.

Wrinkle: `add_os_cart` resolves `src/os/system/tracy_protocol.zig` with the
consumer's `b.path`, so the repository root has one committed symlink
`src/os/system/tracy_protocol.zig` into the `sycl-badge` submodule (there is no
per-cart copy any more).

Zig fetches dependencies into `zig-pkg/` at the repository root (gitignored).

The cart links to about 94 KB (`size -A ../../zig-out/firmware/snouty.elf`: `.text`,
which includes `.rodata`, plus `.data`), under the 256 KB cart RAM limit. The
sprite strip is 72 KB; the four 8-bit backdrop frames share one merged 15 KB
index array and differ only in palette. Watch this if more art is added.

Upstream's wasm platform never presents a frame and the simulator reads a legacy
framebuffer at linear address 0x20, so `main.zig` has a wasm-only
`present_wasm()` that copies the frame there (swapping r and b, because the
simulator's compositor reads red from the bits where `DisplayColor` keeps blue). Without it the optimizer drops all framebuffer writes and
the simulator shows nothing (upstream `dvd.wasm` has the same problem).
`tools/preview.mjs` renders what the simulator shows; `--raw-colors` shows what
the cart API defines.

Flash by copying the UF2 onto the badge's USB mass-storage drive over
`CURRENT.UF2`.

## Simulator

`sycl-badge/simulator` (at the repository root) is a Parcel/TypeScript web app (Node 22 is installed). The
same build also emits a `.wasm` of the cart; `api.zig` switches to wasm externs at
comptime. Run `npm install && npm run dev` there, and serve `cart.wasm` on
`http://localhost:2468`. Hosted fallback: https://badgesim.microzig.tech/.
On this exe.dev VM, expose dev servers through the exe.dev HTTPS proxy
(https://exe.dev/docs/proxy.md) rather than raw ports.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent, `zig fmt`.
- Keep per-frame work cheap: no allocation, no float-heavy loops over the whole
  screen. Precompute at `start()` or comptime.
- Commit generated `gfx.zig` never; it is a build artifact.
- Commit messages: short imperative subject, body explains why.
