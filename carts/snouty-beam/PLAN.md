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
| `0x11 BLOCK` | S->R | xfer, block u16, len u16, crc32 u32 | the next block's packets follow |
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
