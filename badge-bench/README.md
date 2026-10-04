# badge-bench

Emulated cycle benchmark for SYCL Badge V2 carts. It runs a cart's real ELF
(`zig-out/firmware/<cart>.elf`, the file that becomes the `.uf2` you flash)
on an emulated Cortex-M33 (unicorn) from the cart's own `_start`, fakes just
enough of the badge OS, feeds it scripted button input, counts every
executed instruction and prices each one with a per-instruction cycle model.
Out come modelled milliseconds per `update()` at 150 MHz, a hot list of
functions, PNGs of the frames and annotated disassembly.

**It is a model, calibrated against one badge.** Nothing runs on a badge
here. Since 2026-09-29 the per-class costs, the FP result-latency stall and
the LCD-DMA contention factor come from a hardware run of the calibration
cart (`calibrate/calibration.toml`, applied by default; residual 0.13
cycles per instruction over the 20 calibration kernels, see
[Calibration](#calibration)). `--no-calibrate` gives the raw model: issue
cycles in zero-wait SRAM, a floor. Either way trust relative changes
(before/after an edit) more than absolute numbers; the badge's own timing
(a cart's debug overlay) is the only real number.

This generalises `carts/snouty-reflections/tools/emu/real.py` to any cart built
with the SDK's OS-cart path (`sycl-badge/src/cart/cart_ram.ld`,
`platform_cart_ram.zig`), and reproduces that tool's numbers exactly
(see [Validation](#validation)).

## Install and run

Needs `python3` 3.9 or newer with the `venv` module. Nothing else: no zig,
no node.

```sh
./bench.sh ../zig-out/firmware/snouty-bugs.elf --frames 600 --every 60 --symbols
```

(from this directory, after `zig build` at the repository root, which
writes every cart's ELF to the root `zig-out/firmware/`; from the root the
same run is `badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf ...`).

The first run creates `.venv/` next to `bench.sh` and installs
`requirements.txt` (unicorn 2.1.4, capstone 5.0.7, pyelftools; tomli on
Python < 3.11) into it, printing what it does; later runs reuse it and
reinstall only when `requirements.txt` changes. Delete `.venv/` to start
over. `python -m badge_bench ...` works too from any environment that has
those packages, with this directory on `PYTHONPATH`.

Speed depends on how long the cart's basic blocks are (one Python call
per executed block): 576 frames of snouty-reflections (4 M instructions
each, long straight-line FP blocks) take about 75 s, 600 frames of the
other carts 1 to 2.5 minutes (wall times in the first-look table, four runs
sharing two cores).

## CLI

```
badge-bench <cart.elf> [--script FILE.json] [--press BTN:T1-T2 ...] [--frames N]
            [--every K] [--budget-ms 16.7] [--out DIR] [--png [K]] [--lcd] [--listing]
            [--symbols] [--top N] [--poke SYM=VALUE ...] [--json] [--seed N]
            [--max-frame-ms 1000] [--traces N] [--config FILE | --no-config]
            [--progress] [--calibrate FILE.toml] [--flash-cycles N]
            [--romfs IMAGE] [--flash-read-cycles N] [--wav FILE.wav]
```

Put the ELF first (`--png` takes an optional number and would otherwise
try to read the ELF path as one).

| Option | Meaning |
|---|---|
| `--script FILE.json` | Button script in the carts' `preview.mjs` format: `[{"from": T1, "to": T2, "hold": ["A", "UP"]}]`, inclusive update indices, 0 = the first `update()` after `start()`. The carts' `tools/scripts/*.json` work unchanged. CLICK is refused (the OS owns it). |
| `--press BTN:T1-T2` | Same, shorthand (bare `T1-T2` means A); repeatable, comma lists allowed. ORed with the script. |
| `--frames N` | Run N updates after `start()` (default 300, or the cart's toml). |
| `--every K` | Print every K-th frame of the per-frame table (the worst frame is always shown). Also the default PNG stride. |
| `--budget-ms MS` | Frame budget for the report (default 16.7 = 60 fps). |
| `--out DIR` | Where files go (default `out/<cart>` under the current directory). |
| `--png [K]` | Write `DIR/frame_NNNN.png` for every K-th frame (default K = `--every`). |
| `--lcd` | The PNGs show the modelled LCD instead of the presented framebuffer: as on the badge, a present sends only its dirty rect (none at all when a `set_double_buffer_mode` cart marks nothing), so pixels a `.copy_forward` cart writes directly without `mark_dirty_rect` stay off the screen. The web simulator shows the whole framebuffer and hides such bugs. `tests/test_lcd_scrub.sh` uses it on the emulator menu's scrubber. |
| `--listing` | Write `DIR/listing.lst`: capstone disassembly of the 5 hottest functions, each instruction annotated with executions and modelled cycles per frame. |
| `--symbols` | Print the hot-function table (top 20, `--top N`). |
| `--poke SYM=VALUE` | Write VALUE into global SYM (its ELF symbol size if 1, 2 or 4 bytes, else a u32) after loading and before `_start`, like the reflections runner did for `dither.mode`. Repeatable. `start()` runs after the poke and may overwrite it. |
| `--json` | Write `DIR/bench.json`: every frame (insns, cycles, ms, taken branches, memory-class cycles `mem_cyc`, presents, framebuffer index, controls, neopixels (five `[r, g, b]`; any non-zero byte also adds the `neopixels written` warning), user LED, tone count; `busy_ms` when calibrated), the summary, the top 50 functions (each with `taken`, `mnemonics` = {base mnemonic: executions over the run} and `class_cyc` = {model class: cycles over the run}), traces, tones, warnings, crash/hang; `meta.calibration` when calibrated; `audio` once the cart starts streaming (Streaming audio). |
| `--seed N` | Seed of the PRNG behind `cart.rand()` (default 1). |
| `--max-frame-ms MS` | A frame that runs longer than this (modelled) without reaching the next loop iteration is a hang (default 1000). |
| `--traces N` | Print at most N `cart.trace()` strings live (default 20; all of them go to the JSON). |
| `--config FILE`, `--no-config` | Use another per-cart defaults file, or none. |
| `--progress` | One stderr line per finished frame. |
| `--flash-cycles N` | XIP carts only: add N cycles per instruction fetched from the cart flash window. Default 0, so the output of an XIP ELF matches its RAM twin; set it once the OS overlay's XIP hit and stall rates give a real number. |
| `--romfs IMAGE` | Map a badge drive image (FAT12, as `tools/make_romfs.py` builds it) read-only at `0x10080000`, where the OS keeps the drive. Default: the `romfs` key of `carts/<cart>.toml`, if any. See ROMs from the badge drive. |
| `--flash-read-cycles N` | Add N cycles per data load from the `--romfs` image. Default 0 (zero-wait, like SRAM). |
| `--calibrate FILE.toml` | Price the model classes with the fitted `[costs]` of a `calibrate/fit.py` calibration file (rounded to 0.25 cycle) and report two numbers per frame: `idle ms` (the calibrated count) and `busy ms` = idle + memory-class cycles x (factor - 1) x min(1, dma_ms / idle ms), the DMA contention of `[contention]`. Verdict and over-budget count use busy ms. Default: `calibrate/calibration.toml` when it exists (the header says so). See Calibration. |
| `--no-calibrate` | The raw model (default costs, no stall, no contention): one `ms` column, the historical floor. `tests/test_reflections.sh` uses it. |
| `--wav FILE.wav` | Write what the newer firmware's audio mixer took from the cart's stream, from its `CART_START_AUDIO` on: 8-bit unsigned mono 44,100 Hz, silence (128) wherever a 512-sample buffer found the ring short. Nothing is written for a cart that never starts audio. See Streaming audio. |

Exit status: 0 all frames ran; 1 setup error (unreadable or non-ARM ELF,
missing symbol, bad script or config); 2 usage error; 4 the cart crashed
(unmapped access or CPU exception); 5 a frame hung. Being over budget is
not an error.

Output: the report on stdout; with `--png`, `--listing` or `--json` also
`DIR/report.txt`.

## Streaming audio

The newer badge firmware (sycl-badge upstream 3392a1b, "Streaming Audio,
v1 Mixer"; the pinned SDK has no API for it, carts speak the ABI
themselves) plays a cart-owned ring of unsigned 8-bit mono samples at
44,100 Hz. Its four IPC words are where the pinned layout has the tone
fields: `audio_buffer_ptr` `0x2003509C`, `audio_buffer_len` `0x200350A0`,
`audio_buffer_head` `0x200350A4` (the cart's) and `audio_buffer_tail`
`0x200350A8` (the OS's). `badge_bench/audio.py` mirrors the OS
(`drivers/audio.zig`): on `CART_START_AUDIO` it mixes two 512-sample
buffers at once, then one more every 512 samples of wall time; each mix
takes up to 512 queued samples from the tail with the OS's exact wrap
arithmetic, writes the tail back into the cart's memory and pads the rest
with silence. The turns run from the block hook as soon as the cart's
clock passes them, so the cart sees its tail move mid-update as on the
badge.

Wall time: the fake OS answers presents at once, so for the mixer a frame
lasts at least the LCD period the OS sets for the cart's vsync request
(`find_framerate_setting` in `drivers/lcd.zig`: 1000/60 ms gives
16.74 ms, 59.74 Hz, so a cart pushing exactly 735 samples a frame runs
~190 samples/s short; its rate control has to absorb that). With vsync off
wall time is the modelled cycles (the LCD transfer is not modelled).
The calibrated DMA contention (`busy ms`) is not in the audio clock.

Report (only for a cart that started audio; every other cart's report and
JSON are unchanged), here a throwaway test-tone build of snouty-lynx under
`m3_scrub.json` (the tone starts at update 59; the menu opens at 314 and
the tone stops pushing, hence the underruns):

```
audio: streaming started in frame 59 (ring 4096 samples at 0x200543f8); 609 mixes of 512: 237,596 samples consumed (5.39 s)
  start-up silence 1,024 samples; underruns 73,188 samples in 144 mixes (first in frame 316); queue at each mix min 0 mean 1522 max 2422
```

`start-up silence` is the padding before the first real sample (the two
buffers mixed at the start word, before the cart's first push lands);
`underruns` everything padded after it. The queue (head - tail, samples)
is sampled at each mix from the first non-empty one on. `bench.json` gets
an `audio` object with these numbers and `frames`: the queue, samples
consumed and underrun samples at the end of every frame from the start.
A ring whose words are out of range (an index at or past `len`, a ring
outside SRAM) is mixed as silence with its tail untouched and warned
about. `--wav FILE.wav` writes the mixed stream. Unit tests:
`tests/test_audio.py`.

## RAM carts and XIP carts

A RAM cart ELF (`cart_ram.ld`, the default build) is loaded into SRAM by
segment, its `.bss` zeroed, SP set to the cart RAM top and execution started
at `_start`, exactly what the OS does. An XIP cart ELF (`cart_xip.ld`, built
with `zig build -Dcart-mode=xip`, named `<cart>-xip.elf`) is detected by a
loadable segment stored in the cart flash window `0x101C0000..0x10200000`:
the window is mapped, every segment is written at its load address (so the
XIP `.data` lands in flash, where the cart copies it from), and execution
starts through the vector table at the flash origin, SP from word 0 and the
reset handler from word 1, as the OS's XIP launch does. The cart's reset
handler (`build/xip/entry.zig`) then copies `.data`, zeroes `.bss` and calls
`_start`, so frame windows are cut the same way in both modes and the
start-up line includes that work. The same `carts/<cart>.toml` applies when
passed with `--config` (the defaults are keyed by ELF basename, and the XIP
name has the `-xip` suffix). Flash is modelled as zero-wait like SRAM unless
`--flash-cycles` says otherwise; the real part runs through a 16 KB XIP cache
shared with Core 0, which the OS fps overlay measures (hit and stall rates).

## ROMs from the badge drive

Emulator carts can read a ROM file from the badge's USB drive in place
(`lib/romfs.zig`, design in `docs/ROM_DRIVE.md`). The OS keeps that drive in
the `romfs` region of internal flash, `0x10080000`, 1280 KB. `--romfs IMAGE`
maps a drive image there (padded to 4 KB, at most 1280 KB), so the cart finds
the file where it would on a badge. Build an image with
`tools/make_romfs.py OUT.img ROM.gg` (`--list OUT.img` shows the layout), or
set `romfs = "path/to/drive.img"` in `carts/<cart>.toml`, relative to the
repository root; the command line wins. The header shows a `romfs:` line and
out-of-range faults near the region are named "romfs (badge drive image)".

Loads from the image cost zero wait cycles unless `--flash-read-cycles N`
says otherwise. The real reads go through the same 16 KB XIP cache as XIP
code, which is not modelled, so treat the numbers as a floor until the
hardware checks in `docs/ROM_DRIVE.md` section 6 give a figure. The penalty
hook is only installed when N > 0; without it a run with `--romfs` counts
exactly the same cycles as one without (checked on snouty-boy, 60 frames).

## What the fake OS does

From `sycl-badge/src/os/cart/platform_cart_ram.zig` (cart side of the
interface), `os_abi.zig` (shared block) and `os/ipc/mailbox.zig` (message
ids). All in `badge_bench/os_fake.py`.

| Address | What | Behaviour |
|---|---|---|
| `0x20000000..0x20080000` | SRAM | plain RAM; the ELF's PT_LOAD segments are copied in, `.bss` zeroed, SP = `0x20080000` (`__stack_top__`), LR = sentinel, PC = `_start` |
| `0x20020000` | `abi.ipc_data` | two framebuffers (`0x20020000`, `0x2002A000`), tracy ring, trace buffer (`+0x15000`), neopixels (`+0x15080`), controls (`+0x15090`), light (`0x800`) and battery (`0xFFF`) levels, dirty rect, tone fields, tracy words (left 0: tracy inactive), vsync flags/ms, clear colour |
| `0xD0000050/54/58` | SIO FIFO | `SYNC_TIME_REQ_CLR` -> `SYNC_TIME_ACK_CLR`; `SYNC_TIME_REQ_TIME` -> two words (the modelled cycle count); every present message (`0x28` tag, `PresentFlags`) or legacy `FRAMEBUFFER_READY` -> `FRAMEBUFFER_DONE` at once (the LCD flush is instant); `CART_TRACE` (`0x26`, the string in the trace buffer is printed); `CART_TONE` (`0x27`) recorded with the tone fields; the newer firmware's whole words `CART_VOLUME` (`0x29000000`, recorded with `global_volume`), `CART_STOP_AUDIO` (`0x29000001`, answered `0x29000003`, the mixer stops) and `CART_START_AUDIO` (`0x29000002`, the mixer starts: Streaming audio); `CART_RUNNING/FINISHED/CRASHED` recorded (the last two stop the run); anything else (other `0x29` words too) recorded as unknown |
| `0xD0000000`, `0xD0000100..17C` | SIO CPUID, spinlocks | CPUID reads 1 (core 1); spinlocks work (used by the tracy path) |
| `0x400B0008/0C/24/28` | TIMER0 TIMEHR/TIMELR/TIMERAWH/TIMERAWL | microseconds = modelled cycles / 150, TIMELR latches TIMEHR as on the RP2350. `micros_since_boot()` therefore reads modelled time and self-timing carts behave as they would at that speed |
| `0xE0001000/04` | DWT CTRL, CYCCNT | CYCCNT = modelled cycles |
| `0x4006000C`, `0x4006001C` | ROSC STATUS / RANDOMBIT | `cart.rand()` shifts in bit 16 of ROSC STATUS 32 times (`platform_cart_ram.zig rand()`); here that bit comes from a seeded PRNG (`--seed`), so runs are reproducible |
| `0xE000E000` page | SCS | plain RAM with CPACR set so the FPU is on |

Controls are written into `ipc_data.controls` before each `update()`;
neopixels and the user LED are read after it, and tones are counted per
frame. Carts keep the neopixels dark (`docs/NEOPIXELS.md`): if any frame
leaves a non-zero neopixel byte, the run gets one warning, `neopixels
written: frame F, max channel V`, naming the first such frame and the
brightest channel over the run (report text and `bench.json` `warnings`). Nothing else is mapped: any other access stops the run as a crash
with the PC, the faulting address and the nearest symbols (exit 4). Reads
of unmodelled registers inside the faked pages return 0 and are listed as
warnings.

## Frames

The SDK's `_start` is

```zig
os_align_cycles();  root.start();
while (true) { _ = cycles(); root.update(); cart_api.present(); }
```

and `cycles()` reads DWT_CYCCNT. `os_align_cycles()` reads it once after
asking the OS for the time; every later first read after a `present()` is
the loop's. badge-bench cuts frames there, so **frame i is one loop
iteration: `cycles()`, `update()` #i and the whole `present()` after it**
(the dirty-rect scan for carts that never set a double-buffer mode, the
FIFO handshake, the `copy_forward` memcpy or `clear_full_frame` clear, the
buffer swap). Everything before the first loop read (`os_align_cycles`,
`start()`) is reported separately as start-up.

This is the same work as the window between two present() messages that
`carts/snouty-reflections/tools/emu/real.py` uses, shifted by the tail of
`present()`, with one real difference: update #0's `present()` has no
frame in flight, so it skips one FIFO drain iteration (7 instructions, 10
cycles). `--frames N` runs updates #0..#N-1, matching the carts'
`preview.mjs` tick numbering, so a script's `from`/`to` mean the same
update in both tools. The framebuffer written to PNG is the one named in
that frame's present message, decoded in the hardware layout (column-major
`[160][128]`, Pixel is a bitcast of `DisplayColor` r:5 g:6 b:5 with red in
the low bits).

The fake OS answers `FRAMEBUFFER_DONE` immediately, so the time a cart would
spend waiting for the LCD flush or for vsync is not in the numbers: a frame
is the CPU work of one update.

## The cycle model

`badge_bench/model.py`, copied from `carts/snouty-reflections/tools/emu/model.py`
(the validation proves they agree). Issue cycles per instruction, code and
data in zero-wait SRAM. `badge_bench/classes.py` (pure Python, shared with
`calibrate/fit.py`) maps each base mnemonic to a class (`alu`, `vmul`,
`vaddsub`, `vcmp`, `vdiv`, `vsqrt`, `vfma`, `ldr`, `str`, `vldr`, `vstr`,
`ldrd_strd`, `multi`, `udiv`, plus the per-instruction events `taken` and
`fp_dep`) and holds the default cost per class; the calibration swaps in
fitted costs (`multi` always stays 1 + registers). The memory classes
(`ldr`, `str`, `vldr`, `vstr`, `ldrd_strd`, `multi`) are also counted
separately per frame (`mem_cyc`) for the DMA contention term. The defaults
(the raw model) and the badge fit of 2026-09-28:

| Class | Instructions | Default | Badge fit |
|---|---|---|---|
| `alu` | most ALU | 1 | 0.76 |
| `vmul` | VMUL, VNMUL | 1 | 1.00 |
| `vaddsub` | VADD/VSUB/VABS/VNEG, VMOV, VCVT*, VSEL*, VMAXNM/VMINNM | 1 | 0.98 |
| `vcmp` | VCMP, VCMPE, VMRS | 1 | 1.71 |
| `vdiv` | VDIV | 14 | 13.88 |
| `vsqrt` | VSQRT | 14 | 14.05 |
| `vfma` | VFMA/VFMS/VFNMA/VFNMS, VMLA/VMLS/VNMLA/VNMLS | 3 | 3 (not measured) |
| `ldr` | LDR (any width) | 2 | 1.10 |
| `str` | STR (any width) | 2 | 1.09 |
| `vldr` | VLDR | 2 | 1.99 |
| `vstr` | VSTR | 2 | 0.13 (see below) |
| `ldrd_strd` | LDRD, STRD | 3 | 3 (not measured) |
| `multi` | PUSH/POP, LDM/STM, VPUSH/VPOP, VLDM/VSTM | 1 + registers | 1 + registers |
| `udiv` | SDIV, UDIV | 6 | 11.86 |
| `taken` | a taken branch (any block entry that is not a fall-through) | +1 | +1.67 |
| `fp_dep` | an instruction that reads an FP register (or the FPSCR flags) written by the FP data-processing instruction immediately before it | +0 | +0.92 |

What the badge said (calibration kernels, idle bus, cycles per operation):
loads and stores pipeline to about 1.1 cycles each in sequence, half the
old model; UDIV with a 32-bit quotient takes 12, twice the old model; VMUL,
VDIV and VSQRT cost their nominal 1/14/14 but an instruction consuming the
result of the FP instruction *immediately before it* stalls one cycle
(`fp_dep`; a dependency two instructions back is free, VDIV does not
pipeline: four independent chains still cost 14 each); a taken branch costs
about 2.7 in total; the VCMP + VMRS + IT sequence costs 5.3. `vldr` near 2
with `vstr` near 0 is what the kernels imply (the copy kernel pairs them at
2.1 per pair; the tracer-shaped kernels put their VLDRs near 2), not a
statement about VSTR alone; a store-only kernel is on the list for the
next badge run (`calibrate/PLAN.md`, C4). The LCD DMA barely contends:
busy runs are 1.004x idle on memory kernels, 0.998 to 1.005 on compute
kernels (no fetch contention).

What the model still does not know, with the calibrated residual over the
20 kernels at 0.13 cycles per instruction:

- **VFMA and LDRD/STRD** keep their defaults, no kernel exercises them
  (LDRD/STRD is 6-7% of snouty-bugs' and snouty's cycles).
- **Framebuffer LDRH/STRH** ran 15% over the fit (1.76 vs 1.53 per op):
  halfword access, the framebuffer's SRAM bank or the load-use pairs; not
  separable with the current kernels.
- **Branch targets and IT blocks.** Unaligned 32-bit targets, BX and
  POP-to-PC returns may cost more than `taken`; instructions inside an IT
  block are charged in full whether or not their condition passes, and the
  IT itself is 1. The alternating-branch kernel ran 10% over the fit.
- **NOP** is removed before it executes on the M33 (0.63 cycles per 16-bit
  NOP measured); the model charges 1. Irrelevant outside padding.
- **The LCD flush and vsync wait** are not part of a frame (see Frames).
- One badge, one capture (2026-09-28, pass 5 of 5, checksum `c8c7be32`).

`--no-calibrate` restores the raw model, a lower bound.

## Calibration

`calibrate/` holds the badge-calibrate cart (`zig build -Dcart=badge-calibrate`
at the root) and `calibrate/fit.py`. The cart times 20 `noinline`
micro-kernels with DWT_CYCCNT, each isolating one class of the model
(VMUL chains, VDIV, VSQRT, loads, stores, framebuffer stores, branches,
UDIV, fetch, VCMP/VMRS, a table lerp, a ray-tracer mix), once while core 0's
LCD DMA is streaming the framebuffer ("busy") and twice after it ("idle"),
and prints one `CAL k=<id> ... idle_min=... busy_min=...` line per kernel on
the OS console. Run through badge-bench (`carts/badge-calibrate.toml`, 40
frames, `harness.skip_wait=1` poked so the emulator skips the 8 ms wait)
the same lines carry the modelled counts. `fit.py --hardware CAPTURE
--emulator bench.json` pairs the two by kernel id, checks the cart's
checksum on the `CAL done` line, solves least squares for the class costs
over the kernels' per-call instruction mixes (`hot[].mnemonics`,
`class_cyc`, `taken` from the JSON), derives the DMA contention factor from
the memory kernels, and writes `calibration.toml`. `fit.py --selftest
bench.json` feeds the emulator's own lines back and must reproduce the
default table; `tests/test_calibrate_selftest.sh` runs that end to end and
checks `--calibrate` on the result reproduces the uncalibrated ms. How to
flash the cart, capture its output and fit is in `calibrate/README.md`; the
design in `calibrate/SPEC.md`, the contract in `calibrate/PLAN.md`.

**Measured 2026-09-28** on a SYCL Badge V2 by a coworker (the cart built
from `5c1f56a`; the kernel needed the `DEMCR.TRCENA` fix on core 1, sycl-badge
branch `fix/core1-dwt-trcena`, or the cycle counter never runs and the cart
hangs before its first line). Capture:
`calibrate/badge-2026-09-28-pass5.txt` (5 of 5 passes, checksum
`c8c7be32`); fit: `calibrate/calibration.toml` (2026-09-29, after the
`fp_dep` class was added; residual 0.133 cycles per op RMS over the 20
kernels, down from 0.350 with per-class costs alone). `fit.py --tie
vstr=vldr` fits VLDR and VSTR as one unknown (1.10 each) at residual 0.220,
mostly the table-lookup kernel going 5% under; not used.

What the calibration does to the carts (240 frames each, worst frame as a
share of the budget; raw model first, calibrated busy ms second):

| Cart | Budget ms | Raw model, mean / worst ms | Calibrated busy ms, mean / worst | Worst frame as share of budget | `fp_dep` share of cycles |
|---|---|---|---|---|---|
| snouty-reflections | 50 | 31.85 / 34.01 | 37.67 / 40.55 | 68% -> 81% | 14.9% |
| snouty-maze | 16.7 | 10.91 / 15.44 | 9.66 / 13.61 | 92% -> 81% | 10.7% |
| snoutenstein | 16.7 | 2.62 / 5.09 | 2.15 / 4.00 | 30% -> 24% | 1.3% |
| snouty-bugs | 16.7 | 8.56 / 11.87 | 7.49 / 10.50 | 71% -> 63% | 0.1% |
| snouty-boy | 16.7 | 7.42 / 15.68 | 5.04 / 11.41 | 94% -> 68% | 0.0% |
| snouty | 16.7 | 7.32 / 8.92 | 6.40 / 7.79 | 53% -> 47% | 0.0% |

Integer carts get cheaper (loads, stores and ALU cost less than the old
model, more than the dearer taken branch costs them): snouty-boy's worst
frame drops from 94% to 68% of budget. FP carts pay for the stalls:
15% of snouty-reflections' calibrated cycles and 11% of snouty-maze's are
`fp_dep`, and reflections' worst frame goes from 68% to 81% of its 50 ms.
Run `--listing` to see which instructions stall (marked `; fp_dep stall`);
interleaving two independent chains removes them.

## Reading the per-function attribution

`--symbols` charges every executed block (and its taken-branch cycle) to
the sized `STT_FUNC` symbol that contains the block's first instruction,
over all measured frames (start-up excluded). Columns: share of the run's
modelled cycles, cycles and instructions per frame, and calls per frame
(executions of the function's entry block, so a loop that branches back to
the entry would inflate it; real calls are the usual case).

- **Inlined code lands in its caller.** The carts are built ReleaseFast/
  ReleaseSmall and LLVM inlines aggressively: `update()` is usually inlined
  into `_start`, and a hot helper inlined into a renderer shows up as the
  renderer. A large `_start` share means "update() and whatever it
  inlined", not SDK overhead. To split such a function, look at
  `--listing`, or mark the helper `noinline` for an experiment.
- **`OUTLINED_FUNCTION_N`** are LLVM machine outliner fragments (code
  shared between call sites to save size, typical of ReleaseSmall); their
  cycles belong to whoever calls them, and the listing shows which code
  they are.
- Aliases at one address are joined with `=` (for example
  `compiler_rt.memcpy.memcpySmall = memcpy`).
- Blocks outside every sized symbol are grouped as
  `[outside any function: ...]` with the nearest preceding symbol.

`--listing` then shows the top 5 functions instruction by instruction with
executions and cycles per frame: search it for the hot inner loop.

## Adding a cart

Nothing is needed for a cart built with the SDK's OS-cart path: pass its
ELF. For defaults, add `carts/<elf basename>.toml` (chosen by the ELF's
file name without `.elf`; this is `badge-bench/carts/`, which holds only
these toml files, not the repository's top-level `carts/<name>/` with the
cart sources):

```toml
budget_ms = 16.7                        # frame budget
frames = 600                            # updates to run
script = "carts/snouty-bugs/tools/scripts/m1_play.json"   # relative to the repository root
pokes = ["dither.mode=1"]               # --poke items
press = ["START:30-31"]                 # --press items
note = "shown in the report header"
```

Relative script paths resolve against the directory above `zig-out/` when
the ELF is in `<dir>/zig-out/firmware/` (for the root build, the repository
root, hence the `carts/<name>/` prefix), else the ELF's own directory. Every
command-line flag overrides its key. Python 3.11+ reads the file with
`tomllib`, older Pythons with `tomli` (installed by `bench.sh`) or, failing
that, a tiny built-in parser that understands exactly the syntax above.

If a cart touches hardware the fake OS does not provide, the run stops
with a crash naming the address; add the peripheral to `os_fake.py` (and
check the SDK for what it should return) rather than to the cart.

## Validation

Run on 2026-09-27 against the ELFs in the carts' then-separate repos
(sha256 prefixes below; the report header prints the full ELF hash of
every run). The commit hashes quoted here and in the first-look table refer
to each cart's history before it was imported into this repository; the
imported commits have new hashes, the ELF hashes are unchanged.

### 1. snouty-reflections reproduces tools/emu exactly

`tests/test_reflections.sh` (about 80 s). ELF `snouty-reflections.elf` at
tag `snouty-reflections/m1.1`, sha256 `7c76be7bd522`, the same file
`carts/snouty-reflections/tools/emu/out/real.elf` snapshots. Reference:
`tools/emu/real.py --frames 0 25 ... 575 --mode none` (its
`out/sweep/result_real_*.json`), which runs each listed frame as its
own window by poking `main.frame` and `dither.mode = 1` before it, after a
discarded warm-up update. badge-bench runs 576 consecutive updates with
`--poke dither.mode=1`; update #N renders `main.frame = N`, so it is the
same work:

| Frame | real.py insns | real.py cycles | badge-bench insns | badge-bench cycles | |
|---|---|---|---|---|---|
| 0 (update #0 of the sweep) | 4,121,645 | 5,076,056 | 4,121,638 | 5,076,046 | -7 / -10, explained below |
| 0 (after one warm-up update) | 4,121,645 | 5,076,056 | 4,121,645 | 5,076,056 | exact |
| 25 | 4,055,343 | 4,996,812 | 4,055,343 | 4,996,812 | exact |
| 300 | 3,850,813 | 4,743,235 | 3,850,813 | 4,743,235 | exact |
| 550 (worst) | 4,248,497 | 5,230,991 = 34.87 ms | 4,248,497 | 5,230,991 = 34.87 ms | exact |
| 575 | 4,208,217 | 5,183,304 | 4,208,217 | 5,183,304 | exact |

All 24 reference frames match to the instruction and the cycle (the test
prints them all). The one difference is real: update #0's `present()` is
the first of the run, has no frame in flight and so skips one iteration of
the FIFO drain loop (7 instructions, 10 cycles); real.py never measures a
first present. With `--poke main.frame=0xffffffff`, update #0 renders
frame 0xffffffff, update #1 renders frame 0 after a warm-up exactly like
real.py, and matches. Over all 576 consecutive updates: min 31.11, mean
32.11, max 35.25 ms (frame 557, between two of the reference's sampled
frames).

### 2. snouty-bugs plays

`./bench.sh ../zig-out/firmware/snouty-bugs.elf --every 60 --png --symbols --json --listing`
(defaults from `carts/snouty-bugs.toml`: `carts/snouty-bugs/tools/scripts/m1_play.json`, 600
frames, 16.7 ms). ELF sha256 `f05b25c584fd` (commit `fb52bd8`). No fault.
The PNGs show the title screen (frame 0), flying with shots (60, 120),
enemies (180), a hit and the "OFF BY ONE" rewind report (180, 240), and
play resuming with the score going up (300..540). 7.65 to 11.93 ms per
frame, mean 8.24, p95 10.19; 0 frames over 16.7 ms; comfortably under
budget. Worst frame 195 falls in the rewind sequence after the hit, most
likely the catch-up replay (`main.simulate` averages 3.8 calls per update
over the run, so some updates replay several ticks). Hot list: the nibble-packed background dominates:
`PackedIntSliceEndian(u4).get` 54.4%, `draw.draw_bg` 24.6%,
`OUTLINED_FUNCTION_4` 7.5% (called as often as `get`, part of the same
decode), `memcpy` 4.3%, `main.draw_scene` 1.8%. About 86% of a frame is
drawing the scrolling background; unpacking it per pixel through
`PackedIntSlice.get` (24,900 calls per frame) is the obvious target if the
cart ever needs time back.

## First look at the other carts (unreviewed)

2026-09-27, badge-bench at the commit that added this section, run from
this directory with `--every 60 --png --symbols --json --listing` and the
defaults in `carts/<cart>.toml`. **Unreviewed first numbers: raw model
cycles (a floor, what `--no-calibrate` gives today), not hardware.** Budget
16.7 ms (all four carts ask for 60 fps vsync). The Calibration section has
the calibrated numbers.

| Cart (ELF sha256, commit) | Input | Frames | min / mean / p95 / max ms | Worst frame | Over 16.7 | Wall |
|---|---|---|---|---|---|---|
| snouty-boy (`06cfada53162`, `af3ef3b`, ROM 2048-gb) | `--press` START 30, START 120, then RIGHT/DOWN/LEFT/UP taps (toml) | 600 | 0.30 / 8.58 / 12.16 / 18.97 | 141 | 3 (37, 136, 141) | 115 s |
| snouty-maze (`1a5f80ee723d`, `bac5406`) | `tools/scripts/m3_tour.json` (its only press is at update 700, so no input in 600) | 600 | 6.37 / 10.98 / 13.38 / 15.25 | 109 | 0 | 118 s |
| snoutenstein (`b1f93bfbbb53`, `4fe03b3`) | `tools/scripts/m1_walk.json` | 600 | 2.05 / 2.54 / 2.79 / 2.90 | 171 | 0 | 64 s |
| snouty-bugs (`f05b25c584fd`, `fb52bd8`), for comparison | `tools/scripts/m1_play.json` | 600 | 7.65 / 8.24 / 10.19 / 11.93 | 195 | 0 | 140 s |

Top 5 functions (share of the run's modelled cycles):

| Cart | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| snouty-boy | `gb.Gb.step_frame` 72.8% | `frontend.video.on_line` 9.7% | `api.text` 8.4% | `mmu.read8` 3.5% | `cpu.execute` 3.1% |
| snouty-maze | `render.raster.draw_polygon` 60.4% | `render.raster.inner_tex8` 29.9% | `render.raster.inner_tex` 4.5% | `main.update` 3.5% | `__aeabi_memclr` 1.7% |
| snoutenstein | `_start` (update and the raycaster, inlined) 68.0% | `api.text` 12.3% | `api.rect` 10.3% | `levels.Level.cell` 3.1% | `render.blit.cell` 2.4% |

Notes and oddities:

- **snouty-boy**: runs clean; the PNGs show the Snouty Boy splash, the
  2048-gb title, then the board with tiles moving and the score counting.
  Steady state is 8.3 ms per frame (the cart's own overlay, which times
  `step_frame` with `micros_since_boot`, reads "avg 7.5 ms, fps 121" in the
  PNGs: self-timing sees modelled time as intended). Three spikes over
  budget, 17 to 19 ms, a few frames after the ROM starts (37) and after the
  game starts (136, 141): Game Boy side work inside `step_frame` (the
  per-frame split is not broken down further here). Borderline: fine in
  steady state, the spikes would drop a frame. `api.text` at 8.4% is the
  debug overlay's text. With no input at all (300 frames) the splash
  chimes (2 CART_TONE messages at frame 49) and the ROM sits on its title
  screen at 8.25 ms.
- **snouty-maze**: runs, but **reads past its stack top**: from frame 37 on,
  `render/mesh.zig:131-135` (`draw_sphere`, inlined into `main.update`)
  loads garbage vertex indices (159 at the first fault) from its face table
  and reads `vv[face.idx[i]]` far beyond the 86-entry `vv` array, into SRAM8/9 above
  the stack (24,000 reads over the run; first address `0x20080364`). The
  cause is visible in the ELF: the loop over `sphere.faces` steps 40 bytes
  per `Face` (`add sl, #0x28; cmp sl, #0xf00`, 96 faces), but the comptime
  table it reads (`__anon_13524`, 4,608 bytes) was emitted with a 48-byte
  stride (`Face` holds two `@Vector(3, f32)`, 16-byte aligned). From face
  1 on the code reads normals, points and indices from the wrong offsets.
  It does not fault on hardware (that SRAM exists and holds OS stacks) but
  the sphere actors are drawn from garbage, and it is undefined behaviour
  that a safe build would trap. Looks like a Zig/LLVM disagreement about
  the layout of a struct with `@Vector(3, f32)` fields in a comptime
  constant; `extern struct` or `[3]f32` fields would sidestep it. Timing:
  under budget but only 9% headroom at the worst frames (106..111, 15 ms),
  and the model is a floor: borderline on hardware.
- **snoutenstein**: runs clean; title (frame 0), then the m1_walk route
  through the level (enemy, doors, corridors). 2.5 ms per frame; the cart's
  own HUD render timer (about 2.0 to 2.7 ms in the PNGs) agrees with the
  model. Comfortably under budget. Start-up is 3.8 ms (level setup).
- None of the carts wrote neopixels or the user LED in these runs, sent a
  trace, or touched a peripheral the fake OS lacks. The fake OS needed
  nothing beyond what snouty-reflections uses except `cart.rand()` (ROSC,
  used by snouty-maze's seed) and the SRAM8/9 mapping above. Since
  2026-09-29 every cart must keep the neopixels dark (`docs/NEOPIXELS.md`)
  and a run that writes a non-zero neopixel byte prints a `neopixels
  written: frame F, max channel V` warning.

Reproduce (from this directory, after `zig build` at the repository root;
`tests/test_reflections.sh` expects the reflections ELF built at tag
`snouty-reflections/m1.1`):

```sh
tests/test_reflections.sh
tests/test_lcd_scrub.sh        # after zig build -Dcart=snouty-lynx
.venv/bin/python tests/test_audio.py           # the streaming-audio consumer
.venv/bin/python tests/test_neopixel_warning.py
./bench.sh ../zig-out/firmware/snouty-bugs.elf   --every 60 --png --symbols --json --listing
./bench.sh ../zig-out/firmware/snouty-boy.elf     --every 60 --png --symbols --json --listing
./bench.sh ../zig-out/firmware/snouty-maze.elf   --every 60 --png --symbols --json --listing
./bench.sh ../zig-out/firmware/snoutenstein.elf --every 60 --png --symbols --json --listing
```

## Layout

```
bench.sh            entry point: creates .venv, installs requirements.txt, runs badge_bench
badge_bench/        cli.py (arguments), run.py (emulation and frame windows), os_fake.py
                    (the fake OS), model.py (cycle model, unicorn/capstone setup), elf.py
                    (ELF, symbols, DWARF lines), script.py (input), config.py (toml),
                    report.py (tables, stats, hot list, JSON), audio.py (the newer
                    firmware's streaming-audio mixer), png.py, listing.py,
                    classes.py (model classes and default costs, no emulator imports)
carts/<name>.toml   per-cart defaults (not the repository's carts/ sources)
calibrate/          badge-calibrate cart, fit.py, the badge capture and calibration.toml
                    (applied by default)
tests/              test_reflections.sh (validation 1, --calibrate FILE for calibrated ms),
                    test_calibrate_selftest.sh + make_calibrate_fixture.py (fit.py gate),
                    test_neopixel_warning.py (neopixel guard on synthetic frames),
                    test_audio.py (the audio consumer on a fake ring)
out/                default output directory (gitignored)
```
