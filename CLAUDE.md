# Snouty Badge

Animated badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis. The cart shows pixel-art sprites of Snouty, the Antithesis mascot,
animated on the badge screen.

## Layout

- `assets/` — source art (PNG sprite sheets, reference images). Dropped in via scp.
- `cart/` — the Zig cart: `cart/src/main.zig` exports `start()` and `update()`.
- `../sycl-badge/` — upstream badge repo (ZigEmbeddedGroup/sycl-badge), cloned as a
  sibling. Treat it as read-only reference and SDK; do not commit changes there.

## Target hardware (SYCL Badge V2)

- MCU: RP2354B. Core 0 runs the OS kernel, Core 1 runs the cart.
- Screen: 160x128, RGB565 (`DisplayColor` is packed r:u5 g:u6 b:u5; use
  `DisplayColor.rgb(0xRRGGBB)`).
- Framebuffer is column-major: `cart.framebuffer[x][y]`, type `Pixel`, write with
  `Pixel.from_color(color)` (handles wasm vs hardware byte order).
- Inputs: `cart.controls.*` (start, select, a, b, click, up, down, left, right).
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

Upstream pins Zig `0.17.0-dev.1936+5a625d5f3` (see `sycl-badge/build.zig.zon`).
Zig is not installed yet. The exact build is still available at
`https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz`;
unpack it into
`~/.local/zig/` and put it on PATH. Nightly builds rotate off ziglang.org, so if the
download 404s try the machengine.org mirror or the `zigup` tool.

Two ways to build the cart, in order of preference:

1. **As a Zig package depending on sycl-badge.** `add_os_cart` in
   `sycl-badge/build.zig` is `pub` and takes a `*Build.Dependency`, so a
   `build.zig.zon` with `.sycl_badge = .{ .path = "../sycl-badge" }` plus
   `.microzig`/`.zigimg` should work. If `add_os_cart` resolves paths via `b.path`
   instead of `dep.builder.path` (the wasm tracy_protocol import does), fall back to 2.
2. **In-tree.** Symlink `sycl-badge/showcase/carts/snouty -> ../../../snouty-badge/cart`
   and add an `add_os_cart` entry with `.custom_builder` to `sycl-badge/build.zig`.
   Keep that patch small and never commit it upstream.

Outputs land in `zig-out/firmware/*.uf2`. Flash by copying the UF2 onto the badge's
USB mass-storage drive over `CURRENT.UF2`.

## Simulator

`sycl-badge/simulator` is a Parcel/TypeScript web app (Node 22 is installed). The
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
