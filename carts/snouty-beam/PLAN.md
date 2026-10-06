# Snouty Beam: pass carts badge to badge over the link cable

Two badges, a JST-SH cable between the UART headers (docs/LINK.md),
Snouty Beam running on both. Either badge picks a cart from its drive and
sends it. The other badge asks its owner to accept, writes the cart into
the external flash, and the firmware's menu lists it as a received cart
you can launch.

- **Sending** works on any firmware: the cart reads UF2s from the drive
  by pointer (lib/romfs.zig), exactly as the emulators read ROMs.
- **Receiving** needs the fork firmware with `feature/cart-transfer`
  (adrian-computering/sycl-badge, fork/CART_TRANSFER.md). That feature
  owns the **slot format**, the contract between this cart and the
  OS. Read that file before touching lib/beam_slot.zig.
- Over USB there is nothing to build: the badge is a USB device only, so
  two badges need a laptop between them, and then copying the UF2
  (or `badge install`) already does the job.

App id `'T'` on the link (`SNOUTY BEAM`, add it to the lockstep tables).

## Main vs branch

Receiving depends on an OS change, so per Adrian's rule it is compiled
out on main: `-Dbeam_receive` (default false). With it off, the cart is
send-only, and the Receive line reads "Receiving needs the fork firmware
build". Everything else (send, protocol, slot format code, tests) goes to
main. The test dist builds with `-Dbeam_receive=true`. Even when compiled
in, receiving switches on only at run time, when `os_flags` bits 2
(`ext_flash`) and 5 (`cart_transfer`) are both set.

## Pieces

| File | What |
|---|---|
| `lib/beam_slot.zig` | slot format v1: header build/parse/validate, CRC32, UF2 flattener (UF2 blocks -> image bytes on the fly, `load_addr`, `image_len`, descriptor offset), golden-vector tests |
| `lib/ext_flash.zig` | detection (`os_flags` bits 2 and 5, cart-area address from `0x200350F8`) and erase/program through mailbox `0x2B`, raw IPC like lib/cart_serial.zig (the pinned SDK predates the fork). The mailbox handshake matches the fork's `platform_badge.ext_flash_request`. See branch `saves/m1` lib/save.zig for how a monorepo cart talks to a fork mailbox |
| `carts/snouty-beam/cart/src/proto.zig` | transfer protocol, pure state machines `Sender` / `Receiver` over a link and a flash interface, no cart API |
| `carts/snouty-beam/cart/src/main.zig` + UI | screens, input, pump loop |
| `carts/snouty-beam/cart/src/proto_test.zig` | host tests on lib/link_virtual.zig |
| `tools` / build step `beam-slot` | host CLI: `zig build beam-slot -- in.uf2 out.bin` writes the slot area bytes (header sector + image), for the OS fixture and for checks |

## Protocol (DATA packets, at most 12 bytes)

First byte = message type, second = `xfer` (a transfer id the sender
picks, so stale packets from an aborted transfer are dropped).

| Type | Dir | Body | Meaning |
|---|---|---|---|
| `0x01 OFFER` | S->R | xfer, header_len u8 | a transfer starts; the 96-byte header follows as block `0xFFFF` |
| `0x11 BLOCK` | S->R | xfer, block u16, len u16, crc32 u32, flags u8 | the next block's packets follow (flags bit 0: all zero, no DATA follows) |
| `0x10 DATA` | S->R | xfer, seq u16, up to 8 bytes | bytes `seq*8 ..` of the current block |
| `0x12 ACK` | R->S | xfer, block u16 | block received (image blocks: and written) |
| `0x13 NAK` | R->S | xfer, block u16, first_missing u16 | go back to that seq |
| `0x03 ACCEPT` / `0x04 REJECT` | R->S | xfer, reason | owner's answer to the header; reasons: declined, too big, cannot receive, busy |
| `0x14 DONE` | R->S | xfer, status | image verified and header written (or why not) |
| `0x1F ABORT` | both | xfer, reason | cancel (B held, error) |

- Blocks are 4 KB of the image (the last one shorter), sent stop and wait:
  the receiver's core parks with interrupts masked while the OS writes the
  external flash (~50 ms erase + program per 4 KB, up to ~300 ms worst), so
  it cannot take bytes then. The sender waits for ACK/NAK, and resends the
  block after 600 ms of silence; 5 tries on one block, then it aborts.
- The receiver NAKs when data stops for ~5 ms with a gap, or on a bad
  block CRC (from seq 0).
- `link.session` changing (cable out, partner restart) aborts both sides.
  The receiver's slot stays invalid, because the header sector is erased
  first and programmed last (fork/CART_TRANSFER.md write order).
- Pump: during a transfer the cart polls the link in a tight loop until
  ~14 ms into the frame and draws only a progress bar.
  `link.rp2350.rx_dma = 11` (the DMA receive ring) is on.
- Expected speed: 8 data bytes per 15-16 wire bytes at 1 Mbaud is
  ~50 KB/s, plus ~50 ms of flash per 4 KB: about 6 s for a 150 KB image.
  Pipelining writes with a bigger DMA ring is a later option, not M1.

## Screens

- **Home**: link state line (PLUG IN THE CABLE / WRONG CART: x /
  connected), the cart list to send (drive 1, drive 2 if present, the
  received slot if present). Each row shows name and image KB, greyed
  with a reason when it can't be sent (XIP UF2, too big for a slot, not a
  cart). A sends the highlighted cart. A footer line says whether this
  badge can receive, and what its slot holds.
- **Sending**: name, bar, KB/s, B (held) cancels. Ends with "SENT" or the
  reason it failed.
- **Offer** (receiver): "RECEIVE <name>, <KB> KB?", "replaces <old>" if
  the slot is full, A accept / B decline. Unanswered in 30 s = decline.
- **Receiving**: bar, then "RECEIVED <name>. Open the menu to run it."
- Clear the slot: Select on the received row, then confirm.

## Tests (`zig build test`)

- lib/beam_slot.zig: golden header bytes, every validity rule, a real cart
  UF2 flattened == the RAM image the UF2 loader would build (model it in
  the test), XIP UF2 refused, too big refused, out-of-order UF2 handled or
  refused with a reason.
- proto_test: two badges on the virtual cable, both cable kinds, many
  seeds. Full transfer of a real cart UF2 gives a byte-identical slot; 1 in
  50 packets dropped still completes; flash stalls modelled (receiver
  doesn't poll for 50-300 ms per sector); cable pulled mid-way leaves the
  slot invalid and both sides idle; decline; sender cancel; receiver
  "power cut" after k sectors leaves no valid slot; re-sending from the
  slot gives an identical slot; a stale xfer is ignored.
- badge-bench: the cart runs with no cable, frame time recorded.

## Milestones

- **M0** plan + slot spec (this file, fork/CART_TRANSFER.md).
- **M1** in parallel: OS track (fork worktree `~/sycl-badge-fork-beam`,
  branch `feature/cart-transfer` off `feature/ext-flash`), cart track
  (this worktree, branch `beam/m0`).
- **M2** integration: the cart's `beam-slot` output as the OS fixture,
  both test suites, fork merged into the combined `main`
  (`feature/cart-transfer` stays standalone and in FEATURES), monorepo
  merged to main with `-Dbeam_receive=false`, dist in `~/beam-dist/`.

## M3: received carts as files on the drive (branch `beam/files`)

Adrian (2026-10-06): store received carts on the regular drive, on a
branch. The OS side is fork branch `feature/cart-files`
(fork/CART_FILES.md: os_flags bit 6, mailbox `0x2D`, `FileRequest`). It
lets a cart create, write and commit a file on SYCLBADGE or SYCLEXTRA, and
refuses while a USB host has the drive mounted.

- **What is sent:** in file mode, the UF2 file itself, byte for byte. The
  copy on the receiver is identical to the sender's, so XIP carts and carts
  bigger than the slot can be sent too. It is about twice the bytes of an
  image (Boy about 9 s instead of 4.5 s).
- **Choosing the mode:** the receiver advertises what it can take (file,
  slot, or nothing) in the existing link handshake, and the sender offers a
  file when the receiver takes files, else a slot image as in M1.
  Old M1 receivers keep working with slot transfers.
- **Protocol v2:** OFFER gains a kind (slot image / file). File offers carry
  the file name (up to 63 bytes) and size instead of the slot header, sent
  as block `0xFFFF` the way the slot header is. BLOCK/DATA/ACK/NAK
  unchanged. Each 4 KB block is one `write` request, and DONE follows
  `commit`.
- **Where it goes:** SYCLBADGE if it has the room (free bytes and root
  directory entries for the name), else SYCLEXTRA. If neither fits but the
  cart fits the slot, it falls back to the slot. Otherwise REJECT "no
  space". If the name is taken, the cart tries `name-2.uf2`, `name-3.uf2`,
  and so on.
- **USB warning:** while `FileFlags.usb_host` is set, the footer reads
  "UNPLUG FROM THE COMPUTER TO RECEIVE", and offers are answered with REJECT
  reason "usb". If a host attaches mid-transfer, the write fails, and the
  cart aborts and says why.
- **Cable pulled or sender cancels:** the receiver sends `abort`, and the
  drive is unchanged.
- **Screens:** Offer shows "RECEIVE <name>, <KB> KB to SYCLBADGE?".
  RECEIVED shows the drive and the final file name. Home lists carts from
  both drives (already) and greys out nothing extra in file mode.
- **Code:** `lib/cart_files.zig` (raw IPC for mailbox `0x2D`, like
  lib/ext_flash.zig, host-testable through an interface). proto.zig and
  main.zig gain the file sink beside the slot sink.
- **Gates:** proto_test covers a file transfer to a fake drive
  (byte-identical file), `exists` renames, `no_space` falls back to the
  slot, `usb_host` at offer time and mid-transfer, the cable pulled
  mid-file (abort, no file), an M1 receiver against an M3 sender and the
  reverse, and loss and stall seeds as M1 does. All monorepo tests and
  builds pass.
- **Build flag:** still `-Dbeam_receive`. The branch stays off main until
  the badge check, per Adrian's "on a branch".

## Status

**2026-10-06: M1 cart track done** (branch `beam/m0`, worktree
`~/snouty-badge-beam`, unpushed, unmerged). Everything above is built;
deviations and additions:

- **Spec change (agreed with the OS side, fork/CART_TRANSFER.md):** UF2
  blocks wholly below the IPC block's end (0x20035100) are dropped. Our
  cart linker loads the ELF and program headers at 0x20030000 (a
  framebuffer), which made every image ~20 KB longer with zeros; a block
  straddling 0x20035100 makes a UF2 non-transferable. `load_addr >=
  0x20035100` is part of "valid slot".
- BLOCK carries a flags byte: an all-zero 4 KB block is sent as the flag
  alone (no DATA), the receiver still erases and programs it.
- The sender repeats OFFER every 2 s while it waits for the answer, and
  the receiver repeats its last answer (REJECT, DONE) or ACCEPT when asked
  again: a lost ACCEPT/REJECT/DONE costs a repeat, not a 35 s timeout.
  The receiver also repeats ACCEPT / the last ACK after 600 ms without a
  BLOCK (5 tries, then it gives up).
- Both badges pressing A at once: each refuses the other (REJECT busy,
  "PARTNER IS BUSY, TRY AGAIN").
- `lib/link.zig` got `LinkQueue(Port, n)`: one poll of a full 256-byte DMA
  ring parses up to 17 DATA packets, more than the default queue of 8.
  The cart uses 32.
- Vsync is off while preparing, sending or receiving: `present` otherwise
  waits up to ~3-4 ms for the vsync, and the tests show a 3 ms gap
  overruns the 256-byte ring (74 NAKs over 4 pong transfers, all
  recovered). With vsync off the gap is the draw (~1 ms).
- lib/ext_flash.zig waits for the 0x2B answer on the SIO FIFO, where the
  pinned runtime's FRAMEBUFFER_DONE also arrives. When it swallows one it
  re-arms `present` with an empty frame for the front buffer (the pinned
  runtime would otherwise wait for it forever). Needs the badge check.
- Footer wording: send-only build "RECEIVING NEEDS THE / FORK FIRMWARE
  BUILD"; receive build on firmware without bits 2 and 5 "CAN'T RECEIVE:
  NEEDS / THE FORK FIRMWARE".

**Host tests** (`zig build test-beam`, in `zig build test`): 14 tests.
lib/beam_slot.zig adds 7 (golden header bytes checked against Python's
zlib, every validity rule, flattening vs the loader model in and out of
order with overlaps, every refusal, write_area) and lib/ext_flash.zig 2.
The pong fixture flattens to the loader model, its dropped blocks hold no
CART_MAGIC, and `beam-slot` reproduces `beam_slot_pong.bin` (also checked
against an independent Python flattener). Transfer results (two badges,
own clocks, 14 ms pump windows, 50-300 ms flash stalls):

| Case | Result |
|---|---|
| pong (23.8 KB), 24 seeds, both cable kinds, DMA ring, 0.8 ms draw gap | all byte-identical, worst 1.94 s, 0 NAKs |
| 1 in 50 packets dropped both ways, 16 seeds | all identical, worst 3.1 s (~990 NAKs and 6 resends over the 16 runs) |
| 8-byte PIO FIFO instead of the ring, 2.7 ms gap, 4 seeds | all identical, worst 7.0 s (70 KB of FIFO overflow recovered) |
| ring, 3 ms gap (vsync left on) | identical, 3 KB overflow, 74 NAKs |
| 150 KB synthetic image, typical flash (50-60 ms per 4 KB) | 5.2 s, 29 KB/s |
| cable pulled after 8 KB | both LINK LOST, slot invalid, a new transfer then works |
| decline; no answer for 30 s; firmware can't receive; too big | REJECT reasons, the old slot untouched |
| sender cancel; both offering at once | receiver sees the cancel, slot invalid; both REJECT busy |
| power cut after k = 0..15 flash writes | the old slot intact (k = 0) or none valid, never a partial one |
| re-send from the received slot | the second slot is byte-identical |
| stale transfer's packets mid-transfer | ignored by both machines |

**badge-bench** (no cable, drive image of five UF2s fragmented 7
clusters at a time, `badge-bench/carts/snouty-beam.toml`): 14.27 ms every
frame by design (it pumps the link until 14 ms). With
`--poke beam_bench_no_pump=1` the frame's own work: mean 2.66 ms, worst
3.62 ms (frame 3, analysing snouty-boy.uf2's 500 blocks), the list and
reasons as on the badge (PNG check). Stack peak 5.2 KB; the verify step
adds a 4 KB buffer when receiving. Sending and receiving are not
benchmarked (the bench has no partner).

**RAM** (`size -A`): send-only `.text` 41.0 KB, `.data` 32 B, `.bss`
18.4 KB; receive build `.text` 48.7 KB, `.data` 4.4 KB, `.bss` 18.4 KB.
About 72 KB of the 307 KB window.

**Which carts can be beamed** (`zig build beam-slot -- --info
zig-out/firmware/*.uf2`, 2026-10-06 main + this branch; a slot holds
252 KB of image): fit: snouty (150), snouty-bugs (212), snoutenstein
(235), snouty-reflections (245), snouty-boy (125), snouty-maze (147),
snouty-gear (167), snouty-lynx (219), snouty-flyover (239), siwoo (43),
snouty-gc (251, 1 KB to spare), snouty-pipes (146), snouty-link (29),
snouty-cycles (211), snouty-pong (24), paperclips (173),
raspberry-trail (109), snouty-sense (131), snouty-theremin (86),
snouty-morph (248), snouty-shader (219), badge-calibrate (101),
snouty-beam (59). Too big: demosnout (259), snouty-genesis RAM (277),
snouty-zero RAM (264). XIP (never): snouty-genesis-xip, snouty-lynx-xip,
snouty-zero-xip.

**Expected transfer time**: ~29 KB/s, so pong ~1 s, snouty-boy ~4.5 s, a
full 250 KB slot ~9 s (host model; wire 77 ms + flash ~55 ms per 4 KB).

**Open risks**

- The `present` re-arm in lib/ext_flash.zig is reasoned from the pinned
  runtime and the fork kernel, not seen on a badge.
- The DMA ring and the pump keep up in the model; on the badge the draw
  between pump windows must stay ~1 ms (the progress screens draw little).
- Readback goes through the cached 0x11000000 window; the fork flushes
  the XIP cache after every write (ext_flash.zig eraseRaw/programRaw).
- Hardware: nothing has run on a badge.

## Hardware check (Adrian)

Two badges with working UART headers (not Adrian's first badge), both
flashed with the fork firmware from `~/beam-dist/`, `snouty-beam.uf2`
(receive build) on both drives, the probe-kit JST-SH cable.

1. Start Snouty Beam on both. Both show connected, and both footers say
   they can receive.
2. On badge A pick a small cart (Snouty Pong) and press A. Badge B asks;
   accept. Both bars run, A says SENT, B says RECEIVED.
3. On B open the menu: the received cart is listed with its mark. Run it.
4. Send something big (Snouty Boy) and time it.
5. Pull the cable mid-way: both sides say so. B's menu then lists no
   received cart (the old one was erased when the transfer began).
6. Power B off mid-transfer, power on: no received cart in the menu, the
   firmware boots normally.
