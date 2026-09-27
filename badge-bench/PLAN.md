# badge-bench: emulated cycle benchmark for SYCL Badge V2 carts

Owner: Adrian Hatch (Antithesis). Lives next to the carts (`carts/`) and
the `sycl-badge` submodule in the carts' repository. Generalises
`carts/snouty-reflections/tools/emu/` so any cart built
with the SDK's OS-cart path can be costed without hardware.

## 1. What it does

Runs a cart's real ELF (`zig-out/firmware/<cart>.elf`) on an emulated
Cortex-M33 (unicorn) from its own `_start`, with just enough of the badge
OS faked, feeds it scripted button input, and counts every executed
instruction. A per-instruction cycle model turns that into modelled
milliseconds per `update()` and a hot list of functions. Nothing runs on
the badge; the number is a model and the README says so.

## 2. The OS interface to fake (from `sycl-badge/src/os/cart/platform_cart_ram.zig`)

- **Shared memory** `abi.ipc_data` at a fixed address below cart RAM:
  controls (u16, same bit layout as `cart.Controls`), light_level,
  neopixels[5], user_led, battery_level, two framebuffers, vsync flags and
  target ms, dirty_rect, clear_color, tone_freq/duration, trace buffer.
  The tool writes controls before each update and reads neopixels/tone
  after it, for the report.
- **Mailbox** via SIO FIFO at 0xD0000050/54/58: `SYNC_TIME_REQ_CLR`/`ACK`,
  `SYNC_TIME_REQ_TIME` (reply two words), `FRAMEBUFFER_DONE` (0x25000002)
  reply to each present message, `CART_TONE` 0x27, `CART_VOLUME` 0x29,
  `CART_TRACE` 0x26 (string in the trace buffer; the tool prints it),
  `CART_RUNNING`/`CART_FINISHED`/`CART_CRASHED` status words.
- **Timer** TIMER0 at 0x400B0000 (TIMEHR/TIMELR) driven from modelled cycles
  at 150 MHz; **DWT_CYCCNT** at 0xE0001004 likewise. This means
  `micros_since_boot()` inside the cart reads modelled time, so carts that
  self-time still work.
- `cart.rand()` (api.zig): check its implementation; if it reads a hardware
  TRNG register, map that page and return a seeded PRNG so runs are
  reproducible.
- Faults: map nothing else; an access outside SRAM, the IPC region and the
  above peripherals is reported as a crash with the PC and the nearest
  symbol.

## 3. Interface

```
badge-bench <cart.elf> [--script FILE.json] [--frames N] [--every K]
            [--budget-ms 16.7] [--out DIR] [--png] [--listing] [--symbols]
            [--poke SYM=VALUE ...] [--json]
```

- `--script` is the same JSON as the carts' `preview.mjs` (`[{from,to,hold:[...]}]`),
  so the carts' existing `tools/scripts/*.json` work unchanged. Also
  `--press BTN:T1-T2` shorthand for parity.
- Per frame: instructions, modelled cycles, ms, fps-equivalent, over/under
  the budget; then min / mean / p95 / max and the worst frame index.
- `--symbols`: per-function attribution from the ELF symbol table (the
  games are not fully inlined, so this is the useful view), top 20 by
  cycles with percentage.
- `--png`: dump every K-th frame's framebuffer as PNG (RGB565 hardware
  layout) so the run can be eyeballed; `--listing`: capstone listing
  annotated with execution counts for the top functions.
- `--poke` sets a global by symbol before the first frame (what the
  reflections runner did for `dither.mode`).
- `--json` writes the full per-frame table for other tools.

Layout:

```
badge-bench/
  bench.sh          entry point; creates .venv, installs requirements, runs badge_bench
  badge_bench/      python package: elf.py, os_fake.py, model.py, run.py, report.py, png.py, listing.py
  requirements.txt  unicorn==2.1.4 capstone==5.0.7 pyelftools
  carts/<name>.toml optional per-cart defaults (budget, script, pokes, frames)
  README.md, PLAN.md
  tests/            smoke test on snouty-reflections (numbers must match its tools/emu)
```

## 4. Cycle model

Same as `carts/snouty-reflections/tools/emu/model.py`: 1 cycle for most
integer and VFP instructions; VDIV.F32 and VSQRT.F32 14; loads and stores
2; LDRD/STRD 3; PUSH/POP/VPUSH/VPOP 1+N; VFMA 3; taken branch +1;
integer UDIV/SDIV 3 to 12 (use 8). Blind spots, documented: SRAM bus
contention with the core-0 LCD DMA, FP pipeline stalls, VCMP/VMRS,
instruction fetch over the S-AHB from SRAM. Treat the ms as a floor.

## 5. Validation

1. `snouty-reflections` at tag `snouty-reflections/m1.1`, no script, 24
   frames 0..575 step 25 with `--poke dither.mode=1`: must reproduce its `tools/emu` real-ELF
   numbers exactly (frame 0: 4,121,645 insns, 5,076,056 cycles; worst
   frame 550: 5,230,991 cycles, 34.87 ms).
2. `snouty-bugs` with `carts/snouty-bugs/tools/scripts/m1_play.json`: runs
   600 frames without a fault, PNG dumps show gameplay (title -> flying -> enemies), report
   shows ms per frame against a 16.7 ms budget and a plausible hot list.
3. `snouty-boy`, `snouty-maze`, `snoutenstein`: run with their scripts if
   present, else no input; record the numbers in `README.md` as a first
   look, flagged as unreviewed. If a cart faults, report where and why;
   that is a finding, not a tool failure, unless the fake OS is at fault.

## 6. Out of scope

Per-pixel ray-path classification and reference-image comparison stay in
`carts/snouty-reflections/tools/emu/` (they are specific to that cart). Cycle
model calibration against real hardware waits for the first badge
measurement; when it arrives, add a `--calibrate` factor.

## Status

- 2026-09-27: plan written; build starting.
- 2026-09-27: built. Validation 1 passes (tests/test_reflections.sh: all 24
  reference frames exact; update #0 is 7 insns / 10 cycles cheaper because
  its present() has no frame in flight, explained in README). Validation 2
  and 3 recorded in README ("Validation", "First look at the other carts
  (unreviewed)"); snouty-maze reads past its stack top in draw_sphere (a
  cart finding, not a tool fault). Awaiting Adrian's review.
