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
The drhelius lynx-tests hardware test carts (github.com/drhelius/lynx-tests,
MIT: `math`, `memio`, `sprites1`-`sprites5` and the author's
`lynx-sprite-performance.md`) decide where the documents are unclear and
calibrate the tick model; the test wins over a reading of the documents
(it passes on a real Lynx). drhelius's Gearlynx (GPL-3) was read only to
interpret what those tests check (the math flags, the size offsets of a
flipped quadrant); no code was taken from it.

## Shape (the M1 contract)

- `write(addr, v)`: `$00-$2F` are 24 16-bit registers, even address = low
  byte; a write to a low byte zeroes the high byte ([HW] "Any CPU write
  to an LSB will set the MSB to 0"). `$40-$6F` are the same 48 bytes
  (lynx-tests memio "SUZY MIRRORS": Suzy has 48 physical registers and
  the math unit's are the sprite engine's, see "Math unit"); a write
  there also runs the math command of that address. `$30-$3F` and
  `$70-$7F` are ignored. `$80` SPRCTL0, `$81` SPRCTL1, `$82` SPRCOLL,
  `$83` SPRINIT, `$90` SUZYBUSEN are stored; `$91` SPRGO and `$92` SPRSYS
  are stored raw in `sprgo`/`sprsys`. Anything else is ignored.
- `read(addr)`: `$00-$2F` (and `$40-$6F`) return the engine's current
  values (after a run they hold the last sprite's working state: SCBADR,
  SPRDLINE, HPOSSTRT after tilt, SPRHSIZ after stretch, and so on).
  `$88` SUZYHREV = `$01`. `$92` SPRSYS as below. Other addresses below
  `$80` read 0; above, `$FC` (Felix's measurement of the open bus noise,
  mostly `%11111100`).
- `write_at(addr, v, now)` / `read_at(addr, now)` are the same with the
  bus tick: a math operation started at `now` reads as running (SPRSYS
  bit 7) for its documented duration. `write`/`read` are `now` = 0 /
  never-busy, so a bus that does not pass the clock sees instant math.
- SPRSYS read: bit 7 math in process (timed accesses only), bit 6 math
  warning, bit 5 last carry, bit 4 vstretch and bit 3 lefthand as
  written, bit 2 unsafe access, bit 1 stop request (as written; SPRGO
  writes clear it), bit 0 sprite process running (= SPRGO bit 0 still
  pending; 0 after `run_sprites`).
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

- VSIZACUM starts at VSIZOFF in the down quadrants (SE, SW) and at 0 in
  the up ones; the horizontal accumulator starts at HSIZOFF in the right
  quadrants (SE, NE) and at 0 in the left ones ([SPR] "Horizontal and
  Vertical Size Offset"). The quadrant decides, not the drawing direction
  after the flips: an H-flipped SE quadrant draws left but starts at
  HSIZOFF (lynx-tests sprites2 ALPINE FLIP, the check Alpine Games' copy
  protection makes on pixel 159; [SPR] reads as if the direction decided).
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
quotient) = `$52` D .. `$55` A. They are the sprite registers seen at
`$40-$6F`: ABCD is SPRDLINE/HPOSSTRT (`$12-$15`), NP VPOSSTRT (`$16`),
EFGH SPRDOFF/SPRVPOS (`$20-$23`), JKLM SCBADR/PROCADR (`$2C-$2F`), so a
sprite run overwrites them and math clobbers those engine registers
(memio "SUZY MIRRORS"). Writing the sprite-register addresses
themselves (`$12-$17`, `$20-$23`, `$2C-$2F`) starts nothing.

- Writing A starts AB x CD -> EFGH. Writing E starts EFGH / NP -> ABCD
  with the remainder in JKLM (JK = 0). Nothing else starts anything.
- A low-byte write (B, D, F, H, K, M, P) zeroes its partner (A, C, E, G,
  J, L, N) without starting an operation.
- Signed (SPRSYS bit 7), on the write of C (for CD) and A (for AB): the
  operand is replaced by its magnitude and its sign saved; the product is
  negated if the saved signs differ. The hardware tests bit 15 of
  `value - 1`, so `$8000` is positive (+32768) and 0 is negative (with no
  effect on the product) ([MATH] "Bugs in MathLand"; math MUL $8000 BUG).
  The saved sign is only re-evaluated on a high-byte write, so writing
  only D or B keeps the old sign ([BUGS]; math SIGNED MUL part 2).
- Flags, as lynx-tests math checks them on a Lynx I: every operation
  sets SPRSYS bit 2 (unsafe access; writing SPRSYS with bit 2 set clears
  it, as does nothing else). Last carry (bit 5): a multiply sets it when
  it negated a non-zero signed product; an accumulating multiply sets it
  and the warning (bit 6) from the carry out of bit 31 of JKLM + EFGH
  (an unsigned carry, not a sign change: open question 3 settled by math
  ACCUM MUL, `$FFFFFFF0 + $100`); a divide sets the carry when the
  remainder is not zero and clears the warning. Writing M clears the
  warning but not the carry ([MATH]: "The write to 'M' will clear the
  accumulator overflow bit").
- Divide is unsigned in every mode. Divide by zero: ABCD = `$FFFFFFFF`,
  JKLM = 0 [FELIX], warning and carry set (math DIV BY ZERO). The
  remainder bugs ([MATH]: "the remainder will have 2 possible errors")
  are not modelled: the remainder is exact (math SIMPLE DIV does not
  check M).
- Timing: results are visible as soon as the write returns, but with
  `write_at`/`read_at` SPRSYS bit 7 reads 1 for 44 ticks (multiply), 54
  (signed or accumulating) or 176 + 14 N (divide, N = leading zero bits
  of NP) from the starting write ([MATH]). A write to a register below
  `$70` while it runs sets the unsafe bit. Writing E right after A
  ("QbertRoot") divides whatever EFGH then holds.

## Tick model

`run_sprites` returns the engine's time in 16 MHz ticks. The model is
fitted to the drhelius lynx-tests sprite suites (sprites1-5, MIT): each
case's Lynx I time (the suites' expected windows are hardware centre
+-16 us, minimum of three runs, display DMA off except one) less the
runner's own CPU time in this emulator (~260 ticks) and DRAM refresh,
and to the slopes in the suite author's `lynx-sprite-performance.md`
(MIT). It is not a cycle model of the silicon (the guide is explicit
that Suzy's pipeline is not documented at that level); it is a per-row
formula from counts the decoder makes anyway. Constants: `tick_cost` in
`core/suzy.zig` (per-sprite ones in ticks, per-row ones in 1/64 tick).

Per sprite: 64 for the SCB, + 8 for the size reload block, + 8 for the
palette, + 27 for the first sprite of a run or after a skipped SCB (the
cold pipeline). Linked sprites measured ~80 more than another row
(sprites4 LINK 2/4). A skipped sprite: 25.

Per drawn row, from what the row asked of the engine:

- Output pipeline: 65.6 + 1.953 x max(pens decoded, outputs generated),
  counting the one output past the screen edge that stops a row; a row
  that instead ran out of source data pays its tail, 3.7 at 1 bpp and
  6.9 at 2-4 bpp, and a 1 bpp row ending in a half-written byte 6 more
  (sprites2 ALIGN 1B X0 vs X1).
- Totally literal rows are also bus bound: outputs x 2.40, 2.40, 2.46,
  2.63, 2.94 ticks at 0..4 source bits per output (interpolated); the row
  takes the slower of the two (sprites1 LIT 1B-4B FULL: 2529, 2586, 2760,
  3081 us, while the W20 downscales of the same sources stay at ~390
  ticks a row: the guide's source-bound frontier).
- Packed rows: + 4.3 per packet header (the end-of-line header too) and
  0.25 per pen of a literal packet, - 7.9 (sprites4 PACK RLE W32/W64,
  PACK LIT W64).
- Collision, when the row touches the collision buffer at all: + 19.5,
  + 1.65 per 8-pixel screen group only written (background) or only
  read (pen E of the shadow types), + 10 per group read, compared and
  written (the depository types). Fitted to sprites3 (the eight types
  over pens 0, E, F, 1) and sprites4 PACK PEN E / XOR F.
- XOR: + 2 per video byte XORed (the guide's downstream XOR stage).
- Stretch (reload depth >= 2): + 8 per row; tilt (depth 3): + 18
  (sprites5, the guide's stage costs).
- A row that cannot reach the screen (super clipping: it starts off the
  screen drawing away) is rejected without decoding: 45.7 (sprites2
  SUPER CLIP; the guide's 46.5). A row before the screen moving towards
  it costs the same (untested). The rows of a line past the screen edge
  in the drawing direction cost 20 once; a source line downscaled to no
  rows 20 (the guide's offset read plus reject stage; sprites2 VCLIP
  DOWN, sprites5 ZOOM OUT).

Video bytes only read (transparent pixels) cost nothing extra: NONCOLL
with pen-0 holes measured the same as BACKNONCOLL (sprites3). Display
DMA is the machine's business (core/lynx.zig charges its bus time to the
CPU clock, also while Suzy draws; on hardware Suzy hides about half of
it, see "lynx-tests results").

Safety cap: a run stops once its estimate passes `tick_cost.run_cap`
(4,000,000 ticks, 15 frames). Real hardware would hang on a list with a
loop or on sprite data without an end; the cap keeps the badge running.

## lynx-tests results

With the machine as merged on `lynx/m1` (9a2766e) plus the bus passing
its tick to `read_at`/`write_at`:

- math: SIMPLE MUL, ACCUM MUL, SIGNED MUL, MUL $8000 BUG, SIMPLE DIV, NO
  REM DIV, DIV BY ZERO pass. TIMING fails stage 1 with 17 us where the
  hardware takes 16 (multiply stage passes): with Suzy's 218-tick divide
  the CPU's poll loop (`lda SPRSYS / and / bne` plus the two `lda
  TIM6CNT`) must total 256-271 ticks between the two timer reads. In
  this emulator the result jumps from 17 straight to 13 us when the
  divide is made 40 ticks shorter (16 shorter still gives 17), so the
  poll loop's emulated cost decides it: a CPU/bus timing question, not
  the divider's.
- sprites1-5: all 40 rows pass but sprites4 DMA EXP W24 (code 3: 872 us
  against 818-850). With display DMA on the machine adds its full
  video-DMA steal (~11%) to the sprite run; the hardware loses ~5% on
  that row.
- memio: MIKEY COLORS, SUZY SPR REGS, SUZY MIRRORS pass.

## Performance shape

`draw_row` decodes one source line into runs of (pen index, count) and
turns each into one clipped span; the span writers (`set_nibbles`,
`xor_nibbles`, `max_set_nibbles`) do two pixels per byte with no per-pixel
branches. The tick model's counts are per span too (`Units` classifies
the video bytes and collision groups a span touches in O(1)), and
`row_ticks` runs once per drawn row. The per-sprite pen table folds the palette and the type's
opaque/collide rules into one byte per pen index. Hooks for M4: an
unscaled-literal fast path, skipping the decode for repeated rows of a
vertically scaled line, and per-type specialised row functions.

## Open questions (hardware behaviour not settled by the documents)

1. Totally literal lines: does the hardware paint the leftover bits at the
   end of the last byte ([SPR]) or drop the last pen when it ends on bit 0
   (Felix, implemented)? A literal line of whole pens with a zero pad byte
   draws the same either way (plus transparent pad pens). The lynx-tests
   CRCs (sprites1 W20, sprites2 ALIGN, ALPINE) pass with the Felix rule.
2. Everon polarity and which sprites it writes for (docs implemented,
   Felix differs; the drhelius guide agrees with the docs: bit 7 = 1 only
   when never on screen).
3. Settled: the accumulator overflow is the unsigned carry out of bit 31
   (lynx-tests math ACCUM MUL).
4. Multi-quadrant sprites with tilt/stretch: HPOSSTRT and SPRHSIZ carry
   over between quadrants (Felix, implemented) or restart per quadrant.
5. The hardware's per-8-pixel collision bursts: a pixel painted twice by
   the same sprite (overlapping quadrants after a negative size offset)
   reads its own number in this per-pixel model.
6. Pixel widths above 255 (`HSIZOFF` or `HSIZ` near `$FFFF`): Felix
   truncates each pixel's width to 8 bits; here a width is the full sum.
7. SPRCTL1 bit 6 (sizing algorithm 3, "broke" per [HW]) is ignored.
8. The divide remainder bugs and divide-by-zero's JKLM (0 here).
9. The tick model outside what the suites measured: wide collidable or
   XOR rows, packed rows at 1-3 bpp, rows off the top moving down, mixed
   transparent/opaque bytes (the guide says they cost more; the suites'
   mixed rows did not show it), the palette-at-`xxFA` page bug (not
   modelled), display DMA overlap.
