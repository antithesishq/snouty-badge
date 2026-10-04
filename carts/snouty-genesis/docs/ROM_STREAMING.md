# Streaming large ROMs from badge flash

Investigation of 2026-09-29, from the SDK pinned at `sycl-badge/`
(submodule commit `4ccc4c4`). SPEC.md section 11 builds on this. Paths
below are relative to `sycl-badge/` unless they start with `carts/`.

## What the cart API offers today

`read_flash(offset, dst)` and `write_flash_page(page, src)` in
`src/os/cart/api.zig:836-857` are stubs that are compiled into the cart
itself, not calls into the OS. On the badge `read_flash` returns 0 and
`write_flash_page` does nothing. The page geometry (256 B pages x 8000) is
left over from badge-v1. In the web simulator both calls are backed by a
4 MB buffer that starts zeroed (`simulator/src/runtime.ts:182`). The OS has
no handler for either call.

## Facts that make read-only streaming possible

- The flash layout (`src/os/linker.ld`) leaves no free flash:

  | Region    | Address      | Size    | Use                                    |
  |-----------|--------------|---------|----------------------------------------|
  | OS        | `0x10000000` | 512 KB  | kernel; about 84 KB actually used      |
  | `romfs`   | `0x10080000` | 1280 KB | FAT12 volume, the badge's USB drive    |
  | `cart_xip`| `0x101C0000` | 256 KB  | the running XIP cart                   |

- The cart runs on Core 1 with no MPU set up (the OS never configures it),
  so it can read the whole XIP window at `0x10000000` directly.
  **Reading needs no change to the badge firmware.**
- `romfs` format (`src/os/loader/storage.zig`): super-floppy FAT12, boot
  sector at `0x10080000`, 1 reserved sector, 2 FATs, 32 root directory
  entries, 512 B sectors, 1 sector per cluster.
- Every cart's UF2 is stored in `romfs` and costs about twice its payload
  (256 B of payload per 512 B UF2 block).

## ROM size ceiling

- **Stock firmware: about 0.9-1 MB.** The ROM file shares `romfs` with
  the emulator's own UF2 (about 2x its flash image, so a 118-190 KB XIP
  image costs 236-380 KB) and any other carts. SPEC.md section 13 has the
  arithmetic.
- **Firmware change, OS region shrunk:** moving `romfs` down to about
  `0x10020000` makes it about 1660 KB and allows about 1.3-1.4 MB ROMs.
  It needs an OS reflash on every badge, and `isSizeCorrect()` then
  reformats `romfs`, which erases every cart. It belongs upstream, and not
  without Adrian's sign-off.
- **2 MB and larger titles** (Sonic 3, Streets of Rage 2) do not fit in
  the 2 MB internal flash under any layout. The only route is a second
  flash or PSRAM chip on the RP2354B's second QSPI chip select (QMI CS1).
  The simulator's comment claims "2MB internal + 2MB external flash" for
  V2 (`simulator/src/runtime.ts:42`, `constants.ts:5`), but nothing in the
  OS uses an external chip and it is unconfirmed whether the board has one
  (SPEC.md section 18, item 6).
- Realistic target: 512 KB titles (Sonic 1, Streets of Rage, many
  homebrew). 1 MB (Sonic 2, Gunstar Heroes) is borderline.

## Design

1. The user copies the ROM (for example `SONIC.GEN`) onto the badge's USB
   drive.
2. At cart start, parse FAT12 straight from flash: find the file in the
   root directory, walk its cluster chain, and build a table from cluster
   index to flash address (a 1 MB ROM is 2048 u16 entries, 4 KB of RAM).
   Fast path: if the chain is contiguous (wipe the drive and copy the ROM
   first), keep just the base address.
3. 68000 ROM reads go through that table as direct loads from XIP flash:
   no per-access `read_flash` call and no copying. `read_flash` (offset
   into the ROM file) is implemented cart-side for setup and bulk copies
   only.
4. Keep emulator code out of flash where it is hot: the CPU core and
   renderer loops go in a RAM-text section. The 16 KB XIP cache is shared
   with the OS on Core 0, and ROM fetches will already miss often.
5. Spare RAM caches hot ROM regions (vectors, main-loop code).

## Caveats

- CPU is the real limit, not ROM size (SPEC.md section 8). Flash cache
  misses add to it.
- badge-bench does not map `romfs` or model XIP cache misses. Measure on
  the badge with the FPS overlay's XIP hit and stall counters
  (`src/os/system/fps_overlay.zig`).
- The ROM file shows in the OS cart menu (`listCarts` has no extension
  filter, `storage.zig:445`), and selecting it fails to load.
- USB mass storage stays live while a cart runs (`src/os/kernel.zig:156`).
  A host write mid-game briefly takes flash out of XIP mode and could
  corrupt a read (not verified on hardware). Rule: don't copy files while
  playing.
- The simulator has no `romfs`, so the ROM source is an interface with an
  embedded source (SPEC.md section 11); the badge build embeds no ROM and
  badge-bench maps a drive image (`--romfs`).
- Writes and save data (`write_flash_page`) need a new Core 0 mailbox
  handler running from `.ram_text` (as `storage.writeSector` does) and a
  firmware reflash. Out of scope; upstream it if ever needed.
