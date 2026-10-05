# ROMs from the badge drive (shared design for the emulator carts)

Status: 2026-09-29, host side built (`lib/romfs.zig`, `tools/make_romfs.py`,
badge-bench `--romfs` / `--flash-read-cycles`; section 6 checks 1-2 done).
Not yet tried on hardware. Used by
`carts/snouty-gear` and `carts/snouty-lynx`; `carts/snouty-genesis` came
to the same design independently (its `docs/ROM_STREAMING.md` is the
original investigation, with the 2 MB-and-up and firmware-change
options) and plans its own `cart/src/frontend/romfs.zig`. Whichever cart
builds it first puts it in `lib/romfs.zig` and the others use that.
Snouty Boy could adopt it later. If the hardware checks in section 6 fail, carts fall back to
packing the ROM into the cart image (section 7).

## 1. Idea

The badge's USB drive is the OS's `romfs` region of the internal 2 MB
flash (no microSD; the OS has no SD driver). The user copies a ROM file
onto the drive next to the cart's UF2. At `start()` the cart finds the
file in the FAT12 volume and afterwards reads ROM bytes straight from the
XIP flash window by pointer. Nothing is copied, compressed or embedded,
the cart is an ordinary RAM cart (the mode proven on hardware), and the
cart ships as an emulator with the user supplying the ROM.

Which carts still need XIP: only those whose code plus console state
exceeds cart RAM. Snouty Gear and Snouty Lynx do not; Snouty Genesis does
(its SPEC section 13: ~110 KB of code, ~136 KB of console state, a 68000
decode table).

## 2. Facts it relies on (checked in `sycl-badge/src/os`, 2026-09-29)

- `linker.ld`: OS `0x10000000` 512 KB, `romfs` `0x10080000` 1280 KB,
  `cart_xip` `0x101C0000` 256 KB.
- `loader/storage.zig`: super-floppy FAT12, boot sector at `0x10080000`,
  512-byte sectors, 1 reserved sector, 2 FATs, 32 root entries, 1 sector
  per cluster, long file names written by hosts.
- The OS sets up no MPU, SAU or ACCESSCTRL restriction, so Core 1 can read
  the whole flash window. The cart API's `read_flash` is a stub that
  returns 0, so a pointer is the only route.
- `listCarts` (`storage.zig:445`) lists every file, so the ROM file shows
  in the OS cart menu and fails to load if picked. Cosmetic.
- The OS writes flash (`flushPending`) with only Core 0's interrupts
  disabled. A host writing the drive while a cart runs could corrupt
  reads. **Rule: eject the drive before playing** (Adrian always does); no
  mitigation beyond a checksum at start.

## 3. Capacity

Cart UF2 files cost twice their payload on the drive, and a RAM cart's
UF2 also carries its zero-filled `.bss` (root PLAN.md: snouty-boy's RAM
UF2 is 484 KB against 161 KB for XIP, because of its 165 KB keyframe
ring). An emulator RAM cart with ~100 KB of code and ~130 KB of console
state and rewind ring in `.bss` is therefore a ~460 KB UF2, leaving about
810 KB of the 1280 KB drive for ROM files. An XIP cart's UF2 holds only
its flash image (Snouty Genesis: 236-380 KB). Either way 512 KB ROMs fit
with room to spare, 1 MB does not in practice, and every other cart on
the drive eats into this.

Since 2026-10-04 the default (`drive`) badge build of every emulator cart
carries no ROM of its own, which saves twice the old fallback ROM's size
on the drive. Default RAM-cart UF2s before and after: Snouty Boy 271,872 ->
204,288 B, Snouty Gear 437,248 -> 306,176 B, Snouty Lynx 420,352 ->
364,544 B, Snouty Genesis 533,504 -> 526,336 B. With Snouty Boy at ~200 KB, a
1 MB Game Boy ROM fits beside it on an otherwise empty drive.

Keeping big buffers (the rewind ring) out of `.bss` would shrink a RAM
cart's UF2 by their size, for example by placing them in the free RAM
between the end of `.bss` and the stack at `start()`. Worth checking in
the first cart's M0; not needed for Sonic-sized ROMs.

## 4. Cart side (`lib/romfs.zig`, shared)

- `open(ext_or_name) !Rom`: check the boot sector (0x55AA signature,
  512-byte sectors, the geometry above) at the hardcoded `0x10080000`;
  on mismatch return an error the cart shows as a message. The address is
  valid for the pinned `sycl-badge` submodule only, so bumping the pin
  means rechecking section 2. As built: `Volume.open(romfs.Image.badge())`
  (`Volume.open_badge()`), an image of `romfs.size` (1280 KB) bytes at
  that address. Every range the boot sector implies (total sectors, FATs,
  root directory, data area) must lie inside the image and the FAT must
  hold an entry for every cluster, else `BadGeometry` before any directory
  or data read. Host tests open fixtures cut after their last used sector
  with `Image.truncated_test(bytes)`: the volume may claim up to 1280 KB,
  its FATs and root directory must be present, and `map` refuses
  (`BadChain`) any cluster past the bytes given.
- Find the file: scan the root directory (short and long names) for the
  cart's extension (`.gg`/`.sms` for Snouty Gear, `.lnx` for Snouty Lynx).
  One match: use it. Several: the cart's menu lists them (a restart picks
  another). None: the default build carries no ROM, so the cart shows a
  "no ROM on the badge drive" screen with the reason (section 5).
- Map it: walk the cluster chain from the FAT and build a table of flash
  addresses. The fast path is a contiguous file (always true when the file
  is copied onto a freshly wiped drive, and usually true otherwise); then
  the ROM is `base[0..size]`. Otherwise keep a per-cluster table (1 MB =
  2,048 x u16, 4 KB) and give the core a mapping at its own granularity:
  each 16 KB Game Gear bank or Lynx block group that is contiguous gets a
  direct pointer, the rest go through the per-cluster table (one extra
  shift and load per read). A fragmented file shows a one-line hint
  ("wipe the drive and copy the ROM first for best speed").
- Checksum the mapped bytes at start (CRC32, shown in the debug overlay)
  as a sanity check.

The core never sees FAT: it receives a bank or block table of pointers,
the same shape an embedded ROM produces, so determinism tests and rewind
are unaffected (the ROM is read-only).

## 5. Where the ROM comes from in each build

| Build                    | ROM source                                          |
|--------------------------|-----------------------------------------------------|
| Badge (default `drive`)  | drive file only; no ROM in the cart, a "no ROM"     |
|                          | screen if none                                      |
| Badge (`embed`)          | the embedded ROM only (single-game cart)            |
| Web simulator (wasm)     | embedded ROM from `-D<cart>-rom=path` (no romfs)    |
| Host tests               | a FAT12 image built by `tools/make_romfs.py`, so    |
|                          | the parser is tested against real layouts (fresh,   |
|                          | fragmented, long names, deleted entries)            |
| badge-bench              | the same image loaded at `0x10080000` (new option,  |
|                          | section 6)                                          |

To test a commercial ROM in the simulator Adrian passes it with
`-D<cart>-rom=~/file`; it is embedded in the local wasm only and never
committed.

## 6. Checks before relying on it

Host / bench (M0 of the first cart that uses it):
1. `tools/make_romfs.py` and parser tests.
2. badge-bench: `--romfs IMAGE` maps the image at `0x10080000`; the
   existing `--flash-cycles` penalty covers instruction fetches only, so
   add a per-load penalty for data reads from flash. Treat bench numbers
   as a floor; the XIP cache is not modelled.

Hardware (the first flash of that cart):
3. A RAM cart reads a 256 KB file from the drive by pointer: throughput
   for sequential and random 1-byte reads, and the overlay's XIP hit and
   stall rates while the emulator runs.
4. Startup time to find and map the file.
5. The drive still mounts and the OS menu still works with the ROM file on
   it.

## 7. Fallback: ROM packed into the cart image

If section 6 fails (reads fault, or cache misses make the emulator too
slow), the cart builds with the ROM inside its own image, as Snouty Boy
does:

- ROM up to ~128 KB: embedded as is in a RAM cart.
- Larger ROMs: XIP cart, with the ROM compressed per bank (Game Gear) or
  per block group (Lynx) in the cart flash window and unpacked into RAM
  (Snouty Gear SPEC section 13.1 has the measured Sonic numbers; Snouty
  Lynx SPEC section 13.1 the compressed block cache). This path also needs the XIP
  cart mode proven on hardware.

The core's bank/block pointer table is the same in both paths, so
switching is a build option (`-D<cart>-rom-source=drive|embed|pack`), not
a code change.

## 8. The extra drive (ext-flash firmware)

The SYCL badge v2 carries a second, 2 MB QSPI flash chip (U8) that stock
firmware never enables. Our firmware fork,
[adrian-computering/sycl-badge](https://github.com/adrian-computering/sycl-badge)
(`main`, or `feature/ext-flash` alone; `fork/EXT_FLASH.md` there), maps
it at `0x11000000` (QMI window 1) and shows it over USB as a second drive,
"SYCLEXTRA": the same FAT12 layout, 1792 KB, 128 root entries. The rest of
the chip is a cart-writable area. That firmware (e2.3 on) sets `os_flags` bit 2 in
the cart IPC block (`0x200350EA`) and the chip size in KB as a u16 at
`0x200350F8`; older firmware clears both. Bit 1 and `0x200350F4` belong to
the cart-serial fork. The OS menu lists every file on the extra drive, as on
the badge drive.

`lib/romfs.zig` reads the IPC words directly, so no SDK bump is needed:
`Image.extra()` is null on stock firmware, and `Image.drive(i)` /
`Volume.open_drive(i)` cover drive 0 (badge) and 1 (extra). Each
`Entry.drive` records where a file came from. Boy, Gear, Lynx and Genesis
list the badge drive first, then the extra drive, in one picker (Gear still
runs the first file).

On stock firmware (and the fork without that feature) both IPC words read 0,
`Image.extra()` is null and the pickers list the badge drive only, exactly as
before (checked in badge-bench for all four emulators, 2026-10-05).

Limits: one cluster table (`max_clusters`, 1280 KB) per cart, so a file on
the extra drive larger than that reports `TooManyClusters`. Window 1 reads
are serial 0Bh at 50 MHz, slower than the badge drive's quad reads on a
cache miss.
