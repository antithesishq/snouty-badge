# Snouty Lynx

Badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: an Atari Lynx emulator in Zig. The badge build reads its ROM
from a `.lnx`/`.lyx` file on the badge's USB drive (docs/ROM_DRIVE.md at
the repository root) and embeds no ROM (no usable drive ROM: the no-ROM
screen, `main.zig` `draw_help`); the simulator and `-Dlynx-rom-source=embed`
embed `roms/raycast.lnx`. `SPEC.md` is the design, `PLAN.md` the current milestone's
contract. Snouty Lynx copies `../snouty-gear` (the template: a RAM-cart
emulator reading the drive through `lib/romfs.zig`) and
`../snouty-genesis` (drive scan as a module, the no-ROM help); their
CLAUDE.md and docs have the longer explanations.

## Layout

- `core/` — the emulator, badge-agnostic: no `cart-api`, no floats, no
  allocator, no clock, no randomness, no romfs. `lynx.zig` is the whole
  console (`Lynx`: 64 KB RAM, CPU, Mikey, Suzy, the cart port) with its
  bus accesses (`fetch`/`read`/`write`/`dummy`/`irq_line`, bodies in
  `bus.zig`; the CPU itself runs on `bus.Port`, `run_cpu`'s local view
  with the clock in registers, docs/CPU.md "Speed"): `init_in_place`,
  `reset` (runs `boot.post_boot`),
  `step_frame(pad)` (1/60 s of Lynx time, one instruction at a time, the
  $FE00/$FE4A boot-ROM traps, Suzy drawing on CPUSLEEP, the display copied
  into `display` at vertical blank), `frame()` (that copy plus the palette),
  `Pad` (low byte = JOYSTICK $FCB0 layout, bit 8 = Pause). `cpu65.zig`:
  the Rockwell 65C02 over a generic Bus, cycle-exact against
  SingleStepTests (docs/CPU.md). `mikey.zig`: timers, interrupts, display
  registers, palette, DMA/refresh bus steal, cart strobes. `audio.zig`:
  Mikey's four audio channels (LFSR, integrate, DAC, links, Lynx II
  stereo) and their mix into `Lynx.audio_out` (M5). `suzy.zig`: sprite engine, collision, math unit
  (docs/SUZY.md). `bus.zig`: memory map, MAPCTL overlays, tick costs,
  page-mode stream, `CartPort`. `cart.zig`: the cart as 256 block pointers
  and the `.lnx`/headerless parser. `undo.zig`: the scrubber's undo-record
  ring (copy-on-first-write 64 B blocks, swapped to step; docs/SCRUB.md). `boot.zig`: the post-boot state from
  the public write-ups (docs/BOOT.md). `uart.zig`: Mikey's UART (state
  `Mikey.uart`), running only with a ComLynx port attached
  (`Lynx.attach_link`; else the M1 stub); `comlynx.zig`: the port (frames
  sent, frames on the wire); `comlynx_virtual.zig`: 2-8 consoles on one
  bus for host tests (docs/COMLYNX.md). `step_frame` = `begin_frame` +
  `finish_frame`, `run_to` slices a frame. PLAN.md "Frozen for M1" is the
  interface contract between these files.
- `cart/src/` — the badge frontend. `main.zig` exports `start()`/`update()`,
  the wasm shims and exports, the state machine (splash -> running | pick | help, running <-> menu,
  menu -> pick -> running | help), the status strip and the no-ROM screen. `frontend/`: `video` (Lynx frame ->
  rows 0..101, 16-entry palette cache), `input` (pad word, Select tap =
  Option 1 after the 200 ms double-tap window, Select hold = menu,
  Select double tap and hold = fast forward, Left during it = the
  chorded rewind, `Repeat` shared with the menu; main.zig `run_frame`), `drive` (drive scan and Cart from a drive
  file; a module of its own, host-tested), `romsrc` (drive ROM, embedded
  ROM in wasm/embed builds only, or none with the reason), `splash` (Iris mark, `lib/iris_mark.zig`),
  `debug` (step timing, FPS), `text` (Snouty Gear's fast font, verbatim),
  `menu` (the
  frozen-frame menu: Resume, Buttons swap, Sound, Press Option 2, Restart
  Pause+Opt1, Debug overlay, Reset, Pick ROM, Party, About; PLAN.md M2, M6), `picker`
  (the drive file list, restarts into the chosen file), `linkport` (the
  linked mode, the cart serial port and lobby client), `lynxnet`
  (ComLynx over lib/party.zig), `party` (the PARTY lobby screen; the
  menu's Party row; docs/COMLYNX.md section 10), `rewind` (the time
  scrubber over `core.undo`: arena from the linker symbols, M3), `tuning`
  (stack guard, wasm arena, the fast-forward knobs), `strip` (the status strip), `audio` (M5:
  `audio_out` into the streaming ring of `lib/stream_audio.zig`, rate
  control, ramp out / prime on resume; host-tested by
  `tests/stream_unit.zig`). `debug.enabled` is off at boot and a menu row;
  `audio.enabled` (Sound) is `build_options.sound` at boot (off unless
  `-Dsound=true`) and a menu row (not in wasm).
- `tests/` — host tests, entry `tests/all.zig` (one `_ = @import` line per
  file): `cpu65_single_step.zig` (SingleStepTests rockwell65c02, data from
  `tools/fetch_test_roms.sh`), `suzy_unit.zig`, `math_unit.zig`,
  `mikey_unit.zig` (timers, bus, port, traps, sleep), `golden.zig` +
  `runner.zig` (scripted runs of the shipped ROM and drhelius's lynx-tests
  carts, frame hashes), `boot_*.zig`, `cart_unit.zig`, `drive_unit.zig`
  (against `tests/fixtures/*.img` from `tests/fixtures/make_fixtures.py`),
  `stream_unit.zig` (the frontend's sound path against a model of the
  firmware's 512-sample reads), `input_unit.zig` (frontend/input.zig with
  the SDK's cart-api for `Controls`: menu hold, held-back tap, fast
  forward, chorded rewind), `ff_determinism.zig` (fast-forward stepping
  equals 1x), `comlynx_unit.zig` / `comlynx_warbirds.zig` /
  `comlynx_party.zig` (the UART, lynx-tests uart1-4, cc65 token rings in
  `tests/comlynx/`, Warbirds from `~/roms/lynx/` on the virtual bus and
  the lobby model). `tools/check_chord_rewind.sh`: the chorded rewind and the
  menu scrubber land on the same frame and play on identically (wasm). `tests/roms/` is gitignored.
- `roms/` — `raycast.lnx` (shipped, Apache-2.0, `LICENSE-raycast.txt`,
  `docs/ROM_CANDIDATES.md`) and `placeholder.lnx` (576 B,
  `tools/make_placeholder_rom.py`, not a Lynx program, only for the drive
  fixtures). `*.lnx`/`*.lyx` are gitignored at the root; commercial dumps
  live in `~/roms/lynx/` on the VM.
- `tools/` — `run_rom.zig` (`zig build run-lynx -- <rom> <script|-> <updates>
  <outdir>`: headless run, frame images and hashes, `--wav` sound,
  docs/RUNNING.md 2a),
  `run_link.zig` (`zig build run-lynx-link`: N consoles on the virtual
  ComLynx bus), `comlynx_sweep.py` (the latency sweep),
  `make_comlynx_roms.sh` (cc65 test carts), `lynx_e2e.zig` / `lynx_e2e.sh`
  (Warbirds through the real `badge lobby`, ports 27500-27549),
  `fetch_test_roms.sh`, `romcheck.py`, `bootrom_crosscheck.py` (needs
  Adrian's local boot ROM, never in the repo), `make_placeholder_rom.py`,
  `scripts/*.json` (preview and badge-bench input). Shared tools
  (`preview.mjs`, `serve-cart.mjs`, `make_gif.py`, `make_romfs.py`) are in
  `../../tools/`.

## Building

Zig `0.17.0-dev.1936+5a625d5f3` at `~/.local/bin/zig`; `zig build` runs
from the repository root only.

- `zig build -Dcart=snouty-lynx` -> `zig-out/firmware/snouty-lynx.uf2`,
  `.elf`, `snouty-lynx-xip.uf2`/`.elf` (both cart modes by default; the
  XIP one is the scrubber's hope, docs/SCRUB.md) and `zig-out/bin/snouty-lynx.wasm`. `-Dlynx-rom=PATH` (repo-relative,
  absolute or `~/x.lnx`; no cart-relative form, the build never probes the
  filesystem), `-Dlynx-rom-source=drive|embed|pack` (`pack`, SPEC.md 13.1,
  is not built: it prints a note and builds `drive`), `-Dcart-optimize=`.
- Generated `rom` module: `data`, `name`, `source` (`.drive`/`.embed`).
  Drive badge builds must not reference `rom.data` (romsrc.zig keeps every
  use behind `!use_drive`), so the ROM's bytes stay out of the UF2.
- `zig build test-lynx` (this cart) or `zig build test` (all);
  `-Dtest-filter=cart`, `-Dtest-optimize=`. `zig build run-lynx -- ...`
  runs a ROM headless (tools/run_rom.zig).
- `zig fmt carts/snouty-lynx` before committing.

## Rules

- build.zig never branches on file existence or environment (this Zig
  caches the configure graph by build files + options). Comptime stays
  light (Adrian's Mac runs out of memory on heavy comptime): tables from
  host generators or runtime init.
- The console is ~66 KB: a static, `init_in_place`, never by value.
- Neopixels: never written (docs/NEOPIXELS.md; `debug_led_max` must read 0).
  Sound (M5, the one cart with sound since the 2026-09-30 "no audio" call,
  PLAN.md "M5 Sound: contract"): only through the new firmware's streaming
  ring (`lib/stream_audio.zig`: never `tone2`, never CART_STOP_AUDIO),
  off at boot unless `-Dsound=true` (docs/SOUND.md), the menu's Sound row
  toggles it; off clears `audio_render` and pushes nothing;
  the wasm build is silent and hides the row. `core/` produces
  `audio_out` and stays float-free.
- ROMs: `*.lnx`/`*.lyx` are gitignored at the root; only shipped ROMs with
  a license get an exception line. Adrian's dumps (`~/roms/lynx/`, 128 KB
  headerless) are for local `-Dlynx-rom=` builds and `out/` romfs images only.
- Commit messages: short imperative subject, body explains why.
