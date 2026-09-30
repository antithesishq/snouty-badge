# Snouty Lynx

Badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: an Atari Lynx emulator in Zig. The badge build reads its ROM
from a `.lnx`/`.lyx` file on the badge's USB drive (docs/ROM_DRIVE.md at
the repository root) and falls back to an embedded ROM; the simulator
always embeds. `SPEC.md` is the design, `PLAN.md` the current milestone's
contract. Snouty Lynx copies `../snouty-gear` (the template: a RAM-cart
emulator reading the drive through `lib/romfs.zig`) and
`../snouty-genesis` (drive scan as a module, the no-ROM help); their
CLAUDE.md and docs have the longer explanations.

## Layout

- `core/` — the emulator, badge-agnostic: no `cart-api`, no floats, no
  allocator, no clock, no randomness, no romfs. `lynx.zig` is the whole
  console (`Lynx`: 64 KB RAM, CPU registers, Mikey, Suzy, the cart),
  `init_in_place`, `reset`, `step_frame(pad)`, `frame()` (the displayed
  4-bit buffer at DISPADR plus the GREEN/BLUERED palette), `Pad` (low byte
  = JOYSTICK $FCB0 layout, bit 8 = Pause). `cart.zig` is the cart as the
  core sees it: 256 block pointers (`Cart`) and the `.lnx` header /
  headerless parser (`parse` -> `Layout`, with `Refusal`). `cpu65.zig`,
  `bus.zig`, `mikey.zig`, `suzy.zig` are M0 stubs with their public shape
  (M1 fills them). `boot.zig` (post-boot state, SPEC.md 11) is M0 Track
  A's; the TODOs in `lynx.zig` and `cart/src/main.zig` mark where it plugs in.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`,
  the wasm shims and exports, the splash -> running state machine, the
  status strip and the no-ROM help. `frontend/`: `video` (Lynx frame ->
  rows 0..101, 16-entry palette cache), `input` (pad word, Select tap =
  Option 1, Select hold = menu), `drive` (drive scan and Cart from a drive
  file; a module of its own, host-tested), `romsrc` (drive or embedded
  ROM, the report line), `splash` (Iris mark, `lib/iris_mark.zig`),
  `debug` (step timing, FPS), `text` (Snouty Gear's fast font, verbatim),
  `menu` (M2 stub).
- `tests/` — host tests, entry `tests/all.zig` (one `_ = @import` line per
  file): `cart_unit.zig` (parser and block table on synthetic data),
  `drive_unit.zig` (against `tests/fixtures/*.img`, written by
  `tests/fixtures/make_fixtures.py` from the placeholder and synthetic
  data), the `lynx:` test in core/lynx.zig. `tests/roms/` is gitignored.
- `roms/` — `raycast.lnx` (shipped, Apache-2.0, `LICENSE-raycast.txt`,
  `docs/ROM_CANDIDATES.md`) and `placeholder.lnx` (576 B,
  `tools/make_placeholder_rom.py`, not a Lynx program, only for the drive
  fixtures). `*.lnx`/`*.lyx` are gitignored at the root; commercial dumps
  live in `~/roms/lynx/` on the VM.
- `core/boot.zig` — the post-boot state (loader decryption from the public
  write-ups, `docs/BOOT.md`); tests in `tests/boot_*.zig`, cross-check tool
  `tools/bootrom_crosscheck.py` (needs Adrian's local boot ROM, never in the repo).
- `tools/` — `make_placeholder_rom.py`, `scripts/*.json` (preview and
  badge-bench input). Shared tools (`preview.mjs`, `serve-cart.mjs`,
  `make_gif.py`, `make_romfs.py`) are in `../../tools/`.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`; `zig build` runs
from the repository root only.

- `zig build -Dcart=snouty-lynx` -> `zig-out/firmware/snouty-lynx.uf2`,
  `.elf`, `zig-out/bin/snouty-lynx.wasm`. `-Dlynx-rom=PATH` (repo-relative,
  absolute or `~/x.lnx`; no cart-relative form, the build never probes the
  filesystem), `-Dlynx-rom-source=drive|embed|pack` (`pack`, SPEC.md 13.1,
  is not built: it prints a note and builds `drive`), `-Dcart-optimize=`.
- Generated `rom` module: `data`, `name`, `source` (`.drive`/`.embed`).
- `zig build test-lynx` (this cart) or `zig build test` (all);
  `-Dtest-filter=cart`, `-Dtest-optimize=`.
- `zig fmt carts/snouty-lynx` before committing.

## Rules

- build.zig never branches on file existence or environment (this Zig
  caches the configure graph by build files + options). Comptime stays
  light (Adrian's Mac runs out of memory on heavy comptime): tables from
  host generators or runtime init.
- The console is ~66 KB: a static, `init_in_place`, never by value.
- Neopixels: never written (docs/NEOPIXELS.md; `debug_led_max` must read 0).
  Sound: none in M0; when added it boots silent behind a menu toggle
  initialised from `-Dsound` (docs/SOUND.md).
- ROMs: `*.lnx`/`*.lyx` are gitignored at the root; only shipped ROMs with
  a license get an exception line. Adrian's dumps (`~/roms/lynx/`, 128 KB
  headerless) are for local `-Dlynx-rom=` builds and `out/` romfs images only.
- Commit messages: short imperative subject, body explains why.
