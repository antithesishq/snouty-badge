# The time scrubber's store (M3)

`core/undo.zig` keeps the history the menu scrubs through (SPEC.md section
10, PLAN.md "M3 Scrub: contract"). It is Snouty Genesis M3's design
(`carts/snouty-genesis/core/undo.zig`) ported to the Lynx's two regions.
Tests: `tests/undo_unit.zig` (`undo:`), `tests/determinism.zig`
(`determinism:`), `tests/scrub_sizing.zig` (`sizing:`, print only).

## Design as built

- **Records, not snapshots.** The live console is the newest keyframe.
  Every `frames_per_record` = 30 badge frames (`record_frame` after each
  `step_frame`) the open record closes and a new one opens. A record is a
  run of 68-byte slots (`Slot`: `u16` id, `u16` pad, 64 data bytes) in one
  ring over the arena the frontend hands to `init`: first `Lynx.Small`
  (584 B, 10 slots, ids `0xF000 + chunk`), then one slot per 64-byte RAM
  block first written since the record opened (id = block number,
  `Region.ram`), holding the block as it was at the boundary.
- **Steps swap.** `step(l, dir)` swaps one record's slots with the console
  (the small state through `save_small`/`load_small`, the blocks with
  `l.ram`): the console is back at the boundary and the record now holds
  the newer bytes, so the same swap goes forward again. Left and Right are
  bit-exact and need no input log and no replay. Left from live while the
  open record is empty skips it (every step moves the picture). After a
  step, `l.refresh_display()` copies the frame at the restored latched
  DISPADR and the palette into `display`; it changes nothing else (not
  even `display_frames`), so a parked state equals the recorded one.
- **Resume.** `resume_here(l)` before the first `step_frame` after a scrub
  drops the applied records (they hold the future) and opens a fresh record
  from the parked state. `record_frame` while parked forgets the history
  (the frontend forgot `resume_here`): consistent, never corrupt.
- **Ring.** Records live in a `[max_records + 1]` table of (start, len),
  `max_records` = 64. When a new slot does not fit, the oldest closed
  record is evicted; when the open record alone outgrows the ring the
  history is lost until the next boundary (`lost_history()`; every dirty
  byte set to 1 so writes stop copying), and the boundary starts over.
- **Dirty bytes.** One byte per RAM block in `.bss` (1 KB): nonzero = the
  block is already in the open record (or nothing is being recorded:
  before `reset`, after `disable`, parked, lost). `touch(addr)` is
  `if (dirty[addr >> 6] == 0) save(block)` in line, `save` is out of line.
  `touch_range(addr, len)` loops the blocks, wrapping at 64 KB;
  `touch_short` is its in-line form for runs of up to 128 bytes (three
  byte loads in the common case). Back at live after a scrub the bytes are
  rebuilt from the open record's slot ids.

### What is console state (`Lynx.Small`)

Every `Lynx` field except `ram` (the blocks), `cart` (the ROM is read-only;
the port's block and counter are in `port`), `display` (an output copy the
game never reads) and `idle_sleep` (a setting). A comptime block in
`core/lynx.zig` fails the build when a `Lynx` field is neither in `Small`
nor in `Lynx.small_excluded`, when a type differs, or when anything in
`Small` holds a pointer (Cpu, Mikey, Suzy and CartPort hold none).
`save_small` zeroes the struct first so equal states give equal record
bytes; compare `Small`s field by field.

### Where RAM is written (the hooks)

| Writer | Hook |
|---|---|
| CPU, `bus.write` below $FC00 (the fast path) | `undo.touch(addr)` |
| CPU, `bus.high_write` RAM tail: $FFF8, under ROM and vectors, Suzy/Mikey space with the overlay off | `undo.touch(addr)` |
| Suzy `fill_pixels`: each video span, each collision span | `undo.touch_short(line + a/2, bytes)` |
| Suzy depository byte (SCB + COLLOFF) | `undo.touch(addr)` |
| `$FE4A` trap (`boot.decrypt_frame`: $02/$05/$07 and the page at $06) | `touch` block 0, `touch_range(page, 256)` |
| A boot re-run (PC into ROM space): `post_boot` clears all RAM | `touch_range(0, 0x10000)` |
| `Lynx.init_in_place` / `reset` (power on, the menu's Reset, Pick ROM) | none: the frontend calls `undo.reset` after |

The DMA/refresh path, Mikey and the cart port write no RAM.

## Sizing

`tests/scrub_sizing.zig` runs the real store over a 4 MB arena and records
each 30-frame record's slots and blocks; the history a smaller ring holds is
computed from those sizes (closed records that fit beside a full open
record, the least over the second half of the run; each closed record is
0.5 s, the open one adds up to 0.5 s more). Arenas are the free RAM between
`__bss_end__` and `__stack_limit__` minus the 1 KB stack guard. This branch
itself takes 688 B of it (the dirty bytes and the `Small` staging, less a
little code): ReleaseFast now leaves 39,944 B.

Records (slots, after the first):

| ROM, run | Slots per record | Blocks written |
|---|---|---|
| raycast, 1800 frames, m1 script looped | 403-405 (27.5 KB) | $9F00-$FEFF: three 8 KB buffers (triple-buffered), plus ~10 blocks of game state |
| Hard Drivin', 1800 updates (A at 600 and 800, Up from 900) | menus 13-93, load 797, driving 233-371, mean 275 (18.7 KB) | $C000-$FFFF: two buffers, plus ~90 blocks of state |
| Blue Lightning, 1500 frames of attract | logo 12, flying 283-305, mean 241 (16.4 KB) | $C000-$FFFF, plus ~25 blocks |

The commercial ROMs are local only (`~/roms/lynx/`, skipped when absent);
nothing derived from them is committed beyond these sizes. The collision
buffer (COLLBAS $0000) is not written by any of the three.

History held, 30-frame records (the frozen contract):

| Arena | Slots | raycast | Hard Drivin' | Blue Lightning |
|---|---|---|---|---|
| ReleaseFast as built (M2), 40,632 B | 582 | 0 s | 0 s | 0 s |
| ReleaseFast, `exec` un-inlined, ~88,000 B (estimate) | 1,279 | 1.0 s | 1.0 s | 1.5 s |
| ReleaseSmall, 120,296 B | 1,754 | 1.5 s | 2.0 s | 2.0 s |
| XIP, 190,000 B | 2,779 | 2.5 s | 3.5 s | 4.0 s |

With longer records (the union of consecutive 30-frame records' blocks:
a game redrawing its buffers every frame writes the same blocks in 60
frames as in 30, so the history per byte doubles; steps become 1 s):

| Arena | raycast 60 | HD 60 | BL 60 | raycast 120 | HD 120 |
|---|---|---|---|---|---|
| ReleaseFast as built | 0 s | 0 s | 0 s | 0 s | 0 s |
| ReleaseFast un-inlined (~88 KB) | 2.0 s | 2.0 s | 3.0 s | 4.0 s | 4.0 s |
| ReleaseSmall | 3.0 s | 3.0 s | 4.0 s | 6.0 s | 6.0 s |
| XIP | 5.0 s | 6.0 s | 7.0 s | 10.0 s | 10.0 s |

M4 (PLAN.md "M4 perf pass"): the opcode switch moved into the run loop
(`Lynx.run_cpu`; no separate `exec`), .text 728 B smaller: 65,256 B free
(`__bss_end__` 0x20068118), 944 slots after the guard (M3: 934).

## Cost on the hot path (badge-bench)

`m2_play.json`, calibrated, game frames 0-299 (busy ms):

| Build | mean | p95 | worst |
|---|---|---|---|
| prep commit 6e16055 (no hooks) | 8.42 | 11.50 | 12.94 |
| hooks, tracking off (the frontend at this commit never calls `undo.reset`) | 8.85 | 11.95 | 13.47 |
| hooks, tracking on (local experiment: a 30 KB arena, `reset` after boot, `record_frame` after each frame) | 8.87 | 11.94 | 13.57 |

+0.45 ms mean with tracking on, inside the +0.5 ms gate. About 0.26 ms is
the CPU write check (run_cpu +16k cycles per frame) and 0.2 ms Suzy's
1,600 span checks per frame. A per-row check (one touch of the whole
line) and a per-run "buffer already saved" cache were tried: no better
(8.87 and 8.98 mean), as code layout moves more than the checks cost.
Copying the blocks themselves (~13 per frame) and opening records cost
next to nothing.

## Recommendation

No build reaches 2 s on raycast with 30-frame records except XIP (2.5 s,
untested on hardware, not before show day). ReleaseSmall gives 2.0 s on
the commercial games but 1.5 s on raycast, and its worst frame (17.0 ms
on raycast, M1 table) is over budget.

The cheapest build meeting >= 2 s on raycast and Hard Drivin' with the
budget held is **ReleaseFast with `exec` un-inlined (~1 ms, ~48 KB freed)
and `frames_per_record = 60`** (2.0 s on both, 3.0 s Blue Lightning, 1 s
steps). That needs the integrator to (1) measure the real un-inlined
arena (the 88 KB is an estimate; 2.0 s needs at least ~84 KB: 3 x 405
raycast slots of 60 frames + guard), and (2) change `frames_per_record` in
`core/undo.zig` (one constant; Track B's strings read `depth_frames` /
`history_frames`, so they follow). If 0.5 s steps matter more than reach,
keep 30 frames and accept 1.0 s on raycast with the un-inlined build.

Levers not built: run-length coding of slot data (textured walls compress
poorly, flat floors and skies well); leaving out the framebuffers not
shown at the boundary (needs a replay, which the design avoids).
