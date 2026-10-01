# Suzy in Snouty Lynx

`core/suzy.zig` holds the sprite engine, the math unit and the Suzy
registers at `$FC00-$FCFF` (except `$B0-$B3`, which the bus serves). This
file says what the code does, which parts match the hardware exactly,
which are estimates, and what is still open. Tests:
`tests/suzy_unit.zig` (`suzy:`), `tests/math_unit.zig` (`math:`).

Sources: the Epyx hardware documentation on monlynx.de ([HW] the address
appendix `hardware.html`, [SPR] `lynx6.html`, [MATH] `lynx9.html`, [BUGS]
`lynx10.html`), cc65's `include/_suzy.h`, and the Felix emulator
(github.com/laoo/Felix, MIT), read for behaviour the documents leave
open. Felix's choices are marked [FELIX] below. Handy (GPL) was not read.

## Shape (the M1 contract)

- `write(addr, v)`: `$00-$2F` are 24 16-bit registers, even address = low
  byte; a write to a low byte zeroes the high byte ([HW] "Any CPU write
  to an LSB will set the MSB to 0"). `$30-$4F` are ignored. `$50-$6F`
  are the math bytes, where the same low-byte rule applies. `$80`
  SPRCTL0, `$81` SPRCTL1, `$82` SPRCOLL, `$83` SPRINIT, `$90` SUZYBUSEN
  are stored; `$91` SPRGO and `$92` SPRSYS are stored raw in
  `sprgo`/`sprsys`. Anything else is ignored.
- `read(addr)`: `$00-$2F` return the engine's current values (after a
  run they hold the last sprite's working state: SCBADR, SPRDLINE,
  HPOSSTRT after tilt, SPRHSIZ after stretch, and so on). `$50-$6F` the
  math bytes. `$88` SUZYHREV = `$01`. `$92` SPRSYS as below. Other
  addresses below `$80` read 0; above, `$FC` (Felix's measurement of the
  open bus noise, mostly `%11111100`).
- SPRSYS read: bit 7 math in process (always 0: math completes inside
  `write`), bit 6 math warning, bit 5 last carry, bit 4 vstretch and bit
  3 lefthand as written, bit 2 unsafe access (never set, see below), bit
  1 stop request (as written; SPRGO writes clear it), bit 0 sprite
  process running (= SPRGO bit 0 still pending; 0 after `run_sprites`).
- `sprites_pending()`: SPRGO bit 0 and SUZYBUSEN bit 0.
- `run_sprites(ram)`: walks and draws the whole list, clears SPRGO bit 0,
  returns the tick estimate.

## Sprite engine

### List walk and SCB load

From SCBNEXT while its **high byte** is non-zero ([BUGS]: the zero
detector only looks at the upper byte, so SCBs cannot live in page 0).
Per SCB: SPRCTL0, SPRCTL1, SPRCOLL, SCBNEXT (5 bytes); if SPRCTL1 bit 2
(skip) is set, nothing else is read and nothing is drawn or deposited.
Otherwise SPRDLINE, HPOSSTRT, VPOSSTRT, then per SPRCTL1 bits 5-4 (reload
depth) 0: nothing, 1: SPRHSIZ SPRVSIZ, 2: + STRETCH, 3: + TILT, then the
8 palette bytes unless SPRCTL1 bit 3. Registers not reloaded keep their
previous values (including SPRHSIZ as left by stretch). STRETCH applies
only at depth >= 2 and TILT only at depth 3 ([SPR]: "only takes place if
enabled by the reload bits"), whatever the registers hold. Pen index `n`
maps through palette nybble `n`: byte 0's high nybble is index 0.

### Line data

A source line is an offset byte then `offset - 1` data bytes. Offset 0
ends the sprite, offset 1 ends the current quadrant (the next quadrant's
first line follows). Bits are read MSB first.

- Packed (SPRCTL1 bit 7 clear): packets of a 1-bit literal flag and a
  4-bit count. Literal: `count + 1` pens follow. Packed: one pen, repeated
  `count + 1` times; a packed header with count 0 (`00000`) ends the line.
- Totally literal (bit 7 set): pens to the end of the line, `00000` not
  recognised.
- The pad-byte bug ([SPR], [BUGS]) as Felix models it: a field (header or
  pen) is only taken while **strictly more** bits remain in the line than
  its width, so the line's last bit (bit 0 of the last byte) is never
  used. A packet ending exactly there loses its last pen; sprite packers
  add a zero pad byte. This also applies to totally literal lines (a
  4 bpp literal line of 2 bytes draws 3 pixels), which contradicts [SPR]'s
  "the odd bits that may be left over at the end of the last byte will
  be painted" (open question 1).

### Quadrants, flips, sizes

The four quadrants are drawn in the order SE, NE, NW, SW starting from
SPRCTL1 bits 1-0 (bit 1 up, bit 0 left). In each, the drawing direction
is the quadrant's direction XOR the flips (SPRCTL0 bit 5 H, bit 4 V).
Per quadrant [FELIX]:

- VSIZACUM starts at VSIZOFF when drawing down and at 0 when drawing up;
  the horizontal accumulator starts at HSIZOFF when drawing right and 0
  when drawing left ([SPR] "Horizontal and Vertical Size Offset").
- The start row is VPOSSTRT - VOFF; a quadrant whose vertical direction
  differs from the start quadrant's starts one row further in its own
  direction, and likewise one column for the horizontal direction (so the
  halves of a multi-quadrant sprite do not overlap at the reference point).
- TILTACUM is cleared; HPOSSTRT, SPRHSIZ and SPRVSIZ are **not** restored
  between quadrants (they carry the tilt and stretch of the earlier ones).

Per source line: VSIZACUM += SPRVSIZ (16-bit); the row count is its high
byte, which is then cleared. For each of those rows: if the row is past
the screen edge in the drawing direction (>= 102 going down, < 0 going
up) the rest of the source line's rows are skipped [FELIX]; otherwise
HPOSSTRT += the signed high byte of TILTACUM (then cleared), the row is
drawn if it is on screen, and SPRHSIZ += STRETCH, TILTACUM += TILT. After
the rows, with SPRSYS bit 4 (vstretch), SPRVSIZ += STRETCH x rows.

The tilt step runs on every row, including rows above the screen (the
documents say tilt and stretch run "while the actual sprite is off
screen"); Felix only folds TILTACUM into HPOSSTRT on visible rows, which
differs only when more than 127 pixels of tilt accumulate off screen.

Per row, each source pixel's width is the high byte of `acc + HSIZ`, the
low byte is kept: a run of `n` equal pixels is one span of width
`(acc + n * HSIZ) >> 8` (the sums telescope), drawn left or right from
`HPOSSTRT - HOFF` (plus the quadrant's one-column offset). Spans are
clipped to 0..159; a row stops decoding once it has left the screen in
its drawing direction.

### Sprite types and collision

| Type | Name | Pens written to video | Pens written to collision | Depository |
|---|---|---|---|---|
| 0 | background-shadow | all (0 and F too) | all but E | no |
| 1 | background-no-collision | all | none | no |
| 2 | boundary-shadow | all but 0, F | all but 0, E | yes |
| 3 | boundary | all but 0, F | all but 0 | yes |
| 4 | normal | all but 0 | all but 0 | yes |
| 5 | non-collidable | all but 0 | none | no |
| 6 | xor-shadow | all but 0, XORed | all but 0, E | yes |
| 7 | shadow | all but 0 | all but 0, E | yes |

This is [SPR]'s table with the shadow inverter error folded in (types 0
and 6 have shadow, so E does not collide), and matches Felix. A
collidable pixel writes the sprite's collision number (SPRCOLL bits 3-0)
into the collision buffer at COLLBAS (same layout as video: 80 bytes per
line, high nybble = left pixel). For the depository types the old nybble
is read first; the highest value read during the sprite ("fred") is
written to `SCBADR + COLLOFF` when the sprite is done. SPRSYS bit 5 or
SPRCOLL bit 5 disables all of it (no buffer access, no depository).

Everon (SPRGO bit 2): a sprite is "on screen" if any of its pixel
positions (opaque or not) fell inside 160x102. With everon set, every
drawn sprite writes its depository byte, with bit 7 set when it was never
on screen; a collidable sprite's low nybble is fred, a non-collidable
sprite's is 0 ([MATH] "Everon": the bit is 1 only when everon is enabled
and the sprite is never on screen; [SPR] "Everon also causes writing to
the collision depository"). Felix sets bit 7 when the sprite *was* on
screen, which contradicts the documents (open question 2).

Video: opaque pens are written as nybbles at VIDBAS (80 bytes per line,
high nybble = left pixel); XOR sprites XOR the pen into the nybble. The
byte-boundary read-modify-write of the hardware has no visible effect
and is not modelled.

## Math unit

Registers (each group little-endian in the address space): AB = `$54`
(B, low) / `$55` (A, high), CD = `$52` (D) / `$53` (C), NP = `$56` (P) /
`$57` (N), EFGH = `$60` H .. `$63` E, JKLM = `$6C` M .. `$6F` J, ABCD (the
quotient) = `$52` D .. `$55` A.

- Writing A starts AB x CD -> EFGH. Writing E starts EFGH / NP -> ABCD
  with the remainder in JKLM (JK = 0). Nothing else starts anything.
- A low-byte write (B, D, F, H, K, M, P) zeroes its partner (A, C, E, G,
  J, L, N) without starting an operation.
- Signed (SPRSYS bit 7), on the write of C (for CD) and A (for AB): the
  operand is replaced by its magnitude and its sign saved; the product is
  negated if the saved signs differ. The hardware tests bit 15 of
  `value - 1`, so `$8000` is positive (+32768) and 0 is negative (with no
  effect on the product) ([MATH] "Bugs in MathLand"). The saved sign is
  only re-evaluated on a high-byte write, so writing only D or B keeps
  the old sign ([BUGS]: the upper-byte auto clear does not clear the sign
  flag). Both are tested.
- Accumulate (SPRSYS bit 6): JKLM += EFGH. The warning bit (SPRSYS bit 6)
  and the carry bit (bit 5) are set when the add changes bit 31 of JKLM
  [FELIX] (open question 3). A multiply clears the warning first; writing
  M clears warning and carry ([MATH]: "The write to 'M' will clear the
  accumulator overflow bit").
- Divide is unsigned in every mode. Divide by zero: ABCD = `$FFFFFFFF`,
  JKLM = 0 [FELIX], warning and carry set. The remainder bugs ([MATH]:
  "the remainder will have 2 possible errors") are not modelled: the
  remainder is exact.
- Timing: the result is ready when `write` returns; SPRSYS bit 7 never
  reads 1. Games that poll it or wait the documented 44/54 ticks (multiply)
  or 176 + 14 N ticks (divide) both work. Writing E right after A
  ("QbertRoot") divides whatever EFGH then holds.
- Unsafe access (SPRSYS bit 2) is never set: the CPU cannot touch Suzy
  while it draws in this model, and the math completes instantly. SPRSYS
  bit 2 written as 1 clears it.

## Tick model

`run_sprites` returns an estimate in 16 MHz ticks (SPEC.md section 4:
pixel output exact, drawing time approximate). The constants are in
`tick_cost` in `core/suzy.zig`, to be tuned in M4 against a measured title:

| Item | Ticks |
|---|---|
| Each drawn sprite (SCB fetch and setup) | 50 |
| Each skipped sprite | 25 |
| Each offset byte (once per source line) | 5 |
| Each data byte of a line, per destination row drawn | 5 |
| Each pixel written to video | 5 |
| Each collision buffer pixel accessed | 5 |

The pixel and collision costs are per pixel, as PLAN.md asked; the
hardware writes two pixels per byte through an 8-word FIFO, so this
probably overestimates large solid sprites by up to 2x (a full-screen
background clear charges 81,600 ticks, about 30% of a frame). Rows skipped
off the top or bottom and pixels clipped at the sides cost nothing beyond
their source bytes.

Safety cap: a run stops once its estimate passes `tick_cost.run_cap`
(4,000,000 ticks, 15 frames). Real hardware would hang on a list with a
loop or on sprite data without an end; the cap keeps the badge running.

## Performance shape

`draw_row` decodes one source line into runs of (pen index, count) and
turns each into one clipped span; the span writers (`set_nibbles`,
`xor_nibbles`, `max_set_nibbles`) do two pixels per byte with no per-pixel
branches. The per-sprite pen table folds the palette and the type's
opaque/collide rules into one byte per pen index. Hooks for M4: an
unscaled-literal fast path, skipping the decode for repeated rows of a
vertically scaled line, and per-type specialised row functions.

## Open questions (hardware behaviour not settled by the documents)

1. Totally literal lines: does the hardware paint the leftover bits at the
   end of the last byte ([SPR]) or drop the last pen when it ends on bit 0
   (Felix, implemented)? A literal line of whole pens with a zero pad byte
   draws the same either way (plus transparent pad pens).
2. Everon polarity and which sprites it writes for (docs implemented,
   Felix differs).
3. The accumulator "overflow": bit-31 change (Felix, implemented) or
   unsigned carry out of bit 31.
4. Multi-quadrant sprites with tilt/stretch: HPOSSTRT and SPRHSIZ carry
   over between quadrants (Felix, implemented) or restart per quadrant.
5. The hardware's per-8-pixel collision bursts: a pixel painted twice by
   the same sprite (overlapping quadrants after a negative size offset)
   reads its own number in this per-pixel model.
6. Pixel widths above 255 (`HSIZOFF` or `HSIZ` near `$FFFF`): Felix
   truncates each pixel's width to 8 bits; here a width is the full sum.
7. SPRCTL1 bit 6 (sizing algorithm 3, "broke" per [HW]) is ignored.
8. The divide remainder bugs and divide-by-zero's JKLM (0 here).
9. The drhelius lynx-tests `sprites` and `math` carts (Track C's golden
   runs) are the first whole-machine check of all of this.
