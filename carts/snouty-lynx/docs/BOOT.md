# Booting without the boot ROM

Status 2026-09-30 (M0 Track A): `core/boot.zig` built and host-tested; the
cross-check against the real boot ROM passes for Hard Drivin' and Blue
Lightning. SPEC.md sections 11 and 18.2 are the decisions this implements.

## What the boot ROM does

From Alexander Thissen's annotated disassembly ([A], AtariAge "Annotated
Lynx boot rom", 2012,
https://forums.atariage.com/topic/191953-annotated-lynx-boot-rom/ ; the
forum blocks scripted fetches, an archived copy is at
https://web.archive.org/web/2020/https://atariage.com/forums/topic/191953-annotated-lynx-boot-rom/)
and David Huseby's zlib-licensed lynx-encryption-tools ([H],
https://github.com/dhuseby/lynx-encryption-tools, `keys.h`, `lynxdec.c`):

1. Reset vector $FF80: IODAT = 2, IODIR = 3, MAPCTL = 3, then a loop clears
   $0003-$FFFF. On its way through page $FF it writes 0 to MAPCTL ($FFF9),
   so from then on Suzy, Mikey, the ROM and the vectors are all mapped in
   (MAPCTL = 0 at the jump to the loader).
2. Mikey: TIM0 backup $9E / CTLA $18, TIM2 backup $68 / CTLA $1F, PBKUP
   $29, DISPADR $2000, DISPCTL $0D, SDONEACK 0, pens 0 and 15 set (pen 15
   is zeroed again at step 4). Suzy is not touched on the success path.
3. It copies its multiply routine to $5000-$50FF, points ($05/$06) at
   $0200 and calls $FE00 with A = 0 (block select: eight bits shifted MSB
   first through IODAT bit 1 on SYSCTL1 bit 0 strobes, which also reset the
   cart's ripple counter).
4. $FE4A, the frame decryptor: one count byte from RCART0 ($FB..$FF = 5..1
   blocks), then per block 51 bytes (least significant first), a range
   check, plaintext = c^3 mod N with the 408-bit public modulus at $FF9A,
   a check that the top byte is $15, and the other 50 bytes turned into
   code by a running byte sum (carried across blocks) stored at ($05),
   incrementing $05 only. The last byte must sum to 0. Then IODAT = 2 and
   JMP $0200 with A = 0, X = 0, Y = 2, I = 1, Z = 1, C/V from the last add.
5. On any failure it retries and eventually shows its INSERT GAME sprite
   (Suzy init); `boot.zig` returns an error instead.

Commercial loaders use the ROM again: the first frame (at $0200) points
$05/$06 at $0300 and jumps back to $FE4A to decrypt a second frame, and
both stages call $FE00 hundreds of times to load the game. The cross-check
tool records every ROM entry a loader makes: for both local titles it is
exactly $FE00 and $FE4A.

## The public route (`core/boot.zig`)

- `Cart.from_file`: a headered `.lnx` (trust bank 0's page size) or a
  headerless dump (SPEC 18.3: 128/256/512 KB = 512 B/1 KB/2 KB blocks).
- `post_boot(cart, ram)`: steps 1-4 above. RAM is zeroed, the loader lands
  at $0200, zero page $00-$07 is as the ROM leaves it ($05/$06 = end of
  the loader, $07 = 0), and the returned `BootState` has the CPU registers,
  MAPCTL, IODIR/IODAT/SYSCTL1, every Mikey write in order, the cart block
  (0) and counter (1 + 51 x blocks).
- `decrypt_frame(reader, ram)`: step 4 alone, for the emulator's $FE4A trap.
  `SetCartBlockExit` documents the registers $FE00 leaves (A = 0, X = 2,
  C = Z = 1, SYSCTL1 = 2, IODAT = 0) for the $FE00 trap.
- Constants and their sources are in comments beside each one. The
  modulus in [A] and [H] agree, and the cross-check shows they reproduce the
  ROM: the public constants are complete. No constant was taken from the
  local boot ROM image, and the section 18.2 fallback was not needed.
- Arithmetic: 13 x 32-bit limbs, the ROM's own shift-and-add modular
  multiply (two per block). No allocator, no floats; a five-block frame is
  about 2 x 416 iterations of a few 13-limb loops, fine at `start()`.

### What M1 needs from this

No boot ROM exists on the badge, so the emulator (M1, `core/bus.zig` and
`core/cpu65.zig`) must:

- start the CPU at `BootState.regs` with RAM from `post_boot` and the Mikey
  writes applied;
- trap PC == $FE00 and PC == $FE4A while MAPCTL bit 2 is clear: $FE00 does
  the block select on the cart port with A and returns (RTS) with
  `SetCartBlockExit`; $FE4A runs `decrypt_frame` on the cart port, applies
  `frame_mikey_writes`, merges `nvzc` into P and continues at $0200;
- read the ROM vectors as `vector_nmi` ($3000) / `vector_reset` /
  `vector_irq` ($FF80) while MAPCTL bit 3 is clear, and return something
  harmless (our own bytes, never ROM bytes) for other ROM-space reads.

## Not reproduced (and why it does not matter)

- The ROM's work buffers in zero page ($08-$0B, $0F, $11-$DC: squares,
  pointers, the reversed ciphertext) and the stack bytes its JSRs leave.
  Loaders and games initialise their own zero page; about 455 non-zero
  bytes per title differ here, all in $08-$1FF or $5000-$50FF.
- The 256-byte copy of the ROM's multiply routine at $5000-$50FF. It is ROM
  code (copyright), so it stays out; nothing calls it directly (the traps
  above replace the only callers).
- SP: the ROM pulls four bytes at $FF85 and is otherwise balanced, so SP at
  $0200 is SP-before-reset minus 3 plus 4. `sp_at_entry` assumes SP = 0
  before reset, giving $01 (the same assumption as the host 6502 below).
  Blue Lightning sets its own SP; Hard Drivin' runs its loader on SP = $01.
  This is an assumption, not a documented fact.

## Cross-check against the real ROM (host only)

The boot ROM image (512 B, md5 fcd403db69f54290b51035d82f835e7b) is
Adrian's local copy at `~/roms/lynx/lynxboot.img`. It is never committed,
never shipped, and nothing derived from it enters the repo except the fact
that the test passed.

```
cd carts/snouty-lynx
python3 -m venv tools/.venv && tools/.venv/bin/pip install py65
tools/.venv/bin/python tools/bootrom_crosscheck.py ~/roms/lynx/hard_drivin.lnx ~/roms/lynx/blue_lightning.lnx
cd ../.. && zig build test -Dcart=snouty-lynx -Dtest-filter=boot
```

`tools/bootrom_crosscheck.py` runs the image on py65's 65C02 with 64 KB
RAM, the MAPCTL overlays, RCART0 (block shift register on the SYSCTL1
strobe, counter reset while the strobe is high) and a register file for
Mikey, from reset until the loader leaves $0200-$0FFF / $5000-$50FF /
$FE00-$FFFF for the game. It writes `tests/roms/boot/<title>.boot.json`
(gitignored: it holds decrypted game code). `tests/boot_crosscheck.zig`
(skipped without the JSON) compares with `post_boot` and `decrypt_frame`:
registers, MAPCTL, IODIR/IODAT/SYSCTL1, cart block and counter, the Mikey
register values, the loader bytes, zero page $00-$07, all RAM outside the
areas above, and every later $FE4A pass (bytes, counter, flags).

Result, 2026-09-30:

| Title          | First frame | Counter | Later $FE4A passes | ROM entries   | Handover |
|----------------|-------------|---------|--------------------|---------------|----------|
| Hard Drivin'   | 3 blocks    | 154     | 1 (5 blocks, $0300)| $FE00 x331, $FE4A x1 | $3A51 |
| Blue Lightning | 5 blocks    | 256     | 1 (5 blocks, $0300)| $FE00 x266, $FE4A x1 | $137B |

Both match exactly in everything compared: A = 0, X = 0, Y = 2, P = $37
(Hard Drivin' second pass: $36, carry clear), SP = $01, MAPCTL = 0, IODIR
= 3, IODAT = 2, SYSCTL1 = 2. The host 6502 also carried both loaders to
their game entry without any timer or interrupt model, so the loaders need
nothing beyond the cart port and the two traps.
