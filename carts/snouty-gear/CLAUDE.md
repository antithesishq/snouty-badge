# Snouty Gear

Seventh badge cart for the Software You Can Love (SYCL) conference, built
for Antithesis: a Sega Game Gear emulator in Zig. The badge build reads its
ROM from a `.gg`/`.sms` file on the badge's USB drive (docs/ROM_DRIVE.md at
the repository root) and falls back to an embedded ROM (Waternet, MIT). The
simulator always embeds. `SPEC.md` is the design; `PLAN.md` is the current
milestone's file ownership and interface contract. Snouty Gear copies
`../snouty-boy` wherever it can; that cart's CLAUDE.md and docs have the
longer explanations, this one summarises.

## Layout

- `core/` — the emulator, badge-agnostic. `gg.zig` is the whole console
  (`Gg`), `step_frame(pad)`, `Keyframe` + `snapshot`/`restore`, the
  `line_sink`; one file per subsystem (`z80.zig` generic over the bus,
  `bus.zig`, `vdp.zig`, `psg.zig`, `rom.zig`). No `cart-api` import, no
  floats, no allocator, no clock, no randomness, no romfs: the core sees the
  ROM only as `rom.Rom`, a table of 16 KB bank pointers plus a per-byte
  fallback callback. Host-testable.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`
  and holds the wasm simulator shims; `frontend/` has video (squeeze and
  the CRAM -> `Pixel` cache), input (pad byte, Select-hold state machine),
  debug (overlay), romsrc (drive or embedded ROM, the report line).
- `tests/` — host tests (`zig build test`), entry `tests/all.zig`.
  `tests/roms/` is gitignored; `tools/fetch_test_roms.sh` fills it.
- `roms/` — the shipped ROM `waternet.gg` and its license. `*.gg`/`*.sms`
  are gitignored at the root (commercial ROMs never enter the repo; Sonic
  lives at `~/sonic.gg` on the VM, read-only).
- `tools/` — `fetch_test_roms.sh` (ZEXDOC/ZEXALL; `--single-step` adds a
  36-file SingleStepTests Z80 subset, `--single-step-all` streams the whole
  1.2 GB suite in batches and logs per-file results), `gen_tables.py` and
  `gen_vdp_tables.py` (Z80 flag and VDP bit-spread tables -> `core/*_tables.zig`,
  committed), `romcheck.py` (header, mapper, port
  heuristics, SPEC.md section 11 verdict), `scripts/*.json` (preview and
  badge-bench input scripts). Shared tools (`preview.mjs`, `serve-cart.mjs`,
  `make_gif.py`, `make_romfs.py`) are in `../../tools/`.
- `../../lib/romfs.zig` — the FAT12 drive reader, shared with other carts,
  imported by the cart as the `romfs` module.

## Target hardware (SYCL Badge V2)

- RP2354B Cortex-M33 at 150 MHz, Core 1 runs the cart from RAM. Cart RAM
  307 KB total incl. 32 KB stack; code, embedded ROM and state live there.
  The drive ROM is read by pointer from the XIP flash window (romfs at
  `0x10080000`, 1280 KB).
- Screen 160x128 RGB565, column-major `cart.framebuffer[x][y]`. Game Gear
  lines 0..143 are squeezed to 128 rows (`y - y / 9`, every ninth dropped).
- Inputs `cart.controls.*`; the OS owns Start+Select (exit) and click.
  Mapping (SPEC.md section 5): d-pad, badge B = button 1, badge A = button
  2, Start; Select hold 500 ms = emulator menu (M2).

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`
(`export PATH="$HOME/.local/bin:$PATH"`); optimize modes are spelled
`.debug/.safe/.fast/.small`. `zig build` runs from the repository root
only (it calls this cart's `build.zig` `pub fn add`).

- `zig build -Dcart=snouty-gear` → `zig-out/firmware/snouty-gear.uf2`,
  `.elf`, `zig-out/bin/snouty-gear.wasm`. `-Dgg-rom=path` picks the embedded
  ROM (repo-relative, cart-relative `roms/x.gg`, absolute or `~/x.gg`);
  `-Dgg-rom-source=drive|embed|pack` (default `drive`; `pack` is SPEC.md
  13.1, not built yet: it prints a note and builds the `drive` cart);
  `-Dcart-optimize=fast|small|safe|debug`.
- The generated `rom` module has `data` (the embedded ROM), `name` (its
  file name) and `source` (`.drive` or `.embed`).
- `zig build test` → every cart's host tests; `-Dtest-filter=bus` (test names carry an area prefix: `bus:`, `psg:`, `z80:`...),
  `-Dtest-optimize=`.
- `size -A zig-out/firmware/snouty-gear.elf` against SPEC.md section 13.
- Headless: `node tools/preview.mjs zig-out/bin/snouty-gear.wasm --frames 600 --every 30 --script carts/snouty-gear/tools/scripts/m1_play.json --out carts/snouty-gear/out/`
  (from the root), then look at the PNGs.
- `zig fmt carts/snouty-gear` before committing.

## Rules

- Adrian builds on a Mac where heavy comptime makes Zig run out of memory:
  no big comptime loops over arrays, no comptime reinterpretation of
  embedded bytes. Tables come from host generators (`tools/gen_tables.py`
  in M1) or literal data; small maps (the 144-byte line map) are built at
  runtime in `init`.
- The console is ~33 KB: keep it a static and use `Gg.init_in_place`; never
  return one by value on the badge (32 KB stack, 14.7 KB in wasm).
- Core: fixed arrays, integer math, deterministic. Hot paths avoid function
  pointers except the one `LineSink` call per line and the ROM fallback for
  fragmented drive files.
- Simulator quirks (upstream `main`): the wasm platform never presents and
  the simulator reads a legacy framebuffer at 0x20 with red/blue swapped;
  buttons arrive at 0x04. `main.zig` has `present_wasm()`/`read_controls()`
  for wasm only. `micros_since_boot` adds 1000 per call in wasm, so the
  overlay always reads 1000 us / 500 fps there.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag, preview in `docs/`, a "pull and run this"
  section in the final message (Adrian reviews in the simulator and flashes).
