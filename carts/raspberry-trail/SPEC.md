# The Raspberry Trail: spec

A faithful port of the 1978 MECC listing of *The Oregon Trail* (Don
Rawitsch, Bill Heinemann, Paul Dillenberger, 1971; BASIC listing printed in
Creative Computing, May-June 1978) to the SYCL badge, whose RP2350 is a
Raspberry Pi microcontroller, hence the name. The cart is called **The
Raspberry Trail**. "The Oregon Trail" is a live trademark, so it appears only
in the credits as the work this one follows. The in-game text keeps the
original's words, and those mention the historical Oregon Trail.

Adrian, 2026-10-04/05: agreed on the button-sequence shooting, the name,
reuse of the Paperclips text UI, a trail strip, and keeping the original's
formulas and quirks. "Build the whole thing, M1-M2."

## 1. Source

- `reference/oregon.bas`: the CDC Cyber BASIC 3.1 listing (686 lines),
  from github.com/clintmoyer/oregon-trail at 4a9dec46, Unlicense
  (`reference/COPYING`). **This file is the specification of the game.**
  Never edit it.
- `reference/oregon-freebasic.bas`, `oregon-qb64.bas`: that repository's
  modern transcriptions. They are useful for reading, but they are not the
  spec. Where they disagree with the original, the original wins.
- Known transcription defect: line 620 reads `PRINT ""RETURN"" KEY, ...`.
  The FreeBASIC copy has `"""RETURN"" KEY, ...`, and the intended output is
  `"RETURN" KEY, THE BETTER LUCK YOU'LL HAVE WITH YOUR GUN.`. The oracle
  applies this as its one listed patch (`tools/oracle/patches.txt`).

## 2. What the game is

A turn-based text game. You buy oxen, food, ammunition, clothing and
supplies with $700. Then you play two-week turns from MARCH 29 to DECEMBER
20 1847 over 2040 miles. Each turn you may stop at a fort (every other turn)
or hunt, choose how well to eat, and then the random events hit: riders,
15 weighted events, the mountains (South Pass at 950 miles, the Blue
Mountains at 1700), illness and cold. You die of starvation, illness,
injuries, snakebite, riders, or winter (turn 20), or you arrive. Shooting
runs a reaction-time test whose result B1 (seconds, lower is better) feeds
the formulas.

## 3. The engine (`cart/src/game/`, the `game` module)

### 3.1 Faithful port

- Every formula, threshold, message and branch of `reference/oregon.bas`,
  including the quirks. Examples: the mileage display stuck at 950 after
  South Pass (M9), the hunt option re-asking the fort question (line 2560),
  riders' hostility flipping (line 2980), the eating re-ask, the fort
  alternation X1, the final-turn fraction and the weekday computation.
- Multiple assignment as BASIC 3.1 does it: `K8=S4=F1=F2=M=M9=D3=0` (line
  820) and `LET K8=S4=0` (1980) set every named variable.
- Numbers are `f64`. Every expression is evaluated in the original's
  operator order with the same operations, so the engine and the oracle
  compute bit-identical values. Example: line 2860 is
  `((M + 200) + (A - 220) / 5) + 10 * RND`. `INT` is `@floor`. The badge
  does this in soft f64 a few dozen times a turn, which costs nothing.
- `RND(-1)`: one draw from `rng.zig` per call, in exactly the order the
  BASIC evaluates them. Every RND in a condition is drawn when the
  condition is evaluated, and only then.
- Every variable the listing uses lives in `Game.v` (`Vars`) under its
  BASIC name, with the same meaning (listing lines 6470-6790).

### 3.2 Resumable

`start` runs the program to its first INPUT. `answer` feeds the INPUT and
runs to the next one. Neither allocates. The lines printed in between land
in `Game.lines` and the INPUT in `Game.prompt` (`game.zig` is the
interface, fixed by the plan commit). `PRINT` with a trailing `;` continues
the line, so the engine emits whole lines ("MONDAY APRIL 12 1847",
"RIDERS AHEAD.  THEY DON'T LOOK HOSTILE"). Blank `PRINT`s may be emitted
as empty lines; the UI uses them as paragraph breaks.

### 3.3 Prompts

| INPUT line | Kind | UI |
|---|---|---|
| 190 instructions, 5220/5240/5260 funeral | yes_no | YES / NO |
| 760 marksman | choice 1..5 | 5 labels, default 3 |
| 860 oxen | number | 200..300, default 200 |
| 940, 990, 1040, 1090 food, ammo, clothing, supplies | number | 0..(700 minus the amounts entered so far this round), default 0 |
| 2330 fort purchases (4 times) | number | 0..T, default 0 |
| 2100 fort/hunt/continue, 2180 hunt/continue | choice | labels; the engine maps them to the numbers the BASIC expects |
| 2770 eat | choice 1..3 | default 2 |
| 3000 riders tactics | choice 1..4 | |
| 6220 shooting | shoot | word S$(S6) |

The badge UI cannot produce the out-of-range inputs that make the original
re-ask ("NOT ENOUGH", "TOO MUCH", "YOU OVERSPENT", "YOU DON'T HAVE THAT
MUCH"). The engine still implements them, and the oracle exercises them.
Exception: "YOU OVERSPENT" can still happen when the round's running total
goes over 700. The UI clamps each item to what is left, so in practice it
cannot.

### 3.4 Random numbers

`rng.zig`: splitmix64(seed) seeds xorshift64* (shifts 12, 25, 27,
multiplier 0x2545F4914F6CDD1D). `RND(-1) = (next >> 11) * 2^-53`. The badge
seeds from the microsecond clock when the player starts a game. The wasm
build seeds from `cart.rand()`. Tests and bench runs pass the seed
explicitly. The oracle uses the same bits.

### 3.5 Shooting arithmetic

Line 6240: `B1 = ((B1 - B3) * 3600) - (D9 - 1)`, where CLK(0) is in hours.
The engine computes `B1 = ((secs / 3600 - 0) * 3600) - (D9 - 1)`, and the
oracle's CLK returns 0 and then `secs / 3600`, so both agree to the bit.
`B1 < 0` becomes 0. A wrong word gives `B1 = 9`.

## 4. The badge UI (`cart/src/main.zig`, `cart/src/ui/`)

### 4.1 Screen (160x128)

Reuse Paperclips' 5x7 font in 6x8 cells (26 columns by 16 rows), copied
into this cart (`tools/gen_font.py` and `ui/gen/font5x7.zig`; carts do not
import each other). The theme is "trail paper": warm cream paper, near-black
ink, raspberry (`#E30B5C`) accents and leaf-green highlights. Every frame
redraws everything (`.no_copy_full_frame`).

- **HUD** (top, 3 rows, plus a 10 px trail strip in M2): line 1 holds the
  date and `MI 950`. Line 2 holds `F 123 B 1450 C 60 M 18 $ 52` in a compact
  form that fits 26 columns. Values come from `Game.hud` (what the original
  last printed).
- **Log** (middle): the original's lines, word-wrapped at 26 columns.
  Status-table, date and mileage lines go to the HUD and are left out of the
  log. `.question` lines are left out too, because the prompt box shows
  them.
- **Prompt box** (bottom, growing upward as needed): the short question,
  then the options or the spinner.

### 4.2 Reading

After an answer, the new lines are shown a page at a time. If they fit
above the prompt box, the prompt appears at once. Otherwise "A: MORE" pages
through them, and the prompt appears after the last page. **Select** opens
the log history (the last ~120 wrapped lines). Up/Down scroll it; A, B or
Select close it. No button does anything while Start and Select are both
held (the OS chord).

### 4.3 Answering

- **choice / yes_no**: a vertical list with a cursor. Up/Down move it and
  A picks.
- **number**: a place-value spinner showing `$ 0250`, with a caret under
  one digit. Left/Right move the caret, Up/Down add or subtract at that
  place (carrying, clamped to `min..max`), held keys repeat (0.4 s, then
  10/s), B resets to `default`, A enters. During the opening purchases a
  line under the spinner shows `LEFT $450`.
- **shoot**: section 4.4.
- **game_over**: the end screen (M1: the closing lines plus "A: NEW
  GAME"; M2: the tombstone or the arrival scene), then A goes to the title.

### 4.4 Shooting (replaces "type BANG and RETURN")

1. "GET READY" for a random 0.6-1.4 s (UI-side randomness, not the game's
   RNG). Nothing pressed yet counts. A press here is a misfire, counted as
   a wrong word (B1 = 9).
2. The cue appears: the word large (`BLAM`) and under it one button glyph
   per letter (4 or 3), each drawn from {UP, DOWN, LEFT, RIGHT, A, B} with
   no two in a row the same. The next glyph is highlighted. The timer
   starts.
3. Each right press advances. The first wrong press ends the shot as a
   wrong word (`correct = false`). The last right press ends it as
   `correct = true`. After 10 s the shot ends with `correct = true` and
   the time so far.
4. `seconds = frames / 60 * shot_time_scale`, counted in frames so that runs
   are deterministic (the cart runs at a steady 60 fps). The knob
   `shot_time_scale` defaults to 0.75: four cued presses take a sharp
   player about 1.2-1.5 s, which maps to the 0.9-1.1 s a fast typist
   needed for BANG plus RETURN. This puts the original's "ACE MARKSMAN"
   threshold (B1 <= 1) within reach of a good player.

### 4.5 Title and flow

M1: a text title ("THE RASPBERRY TRAIL", "A: START", a credits line). A
starts a game seeded from the clock. M2 replaces it with the art title
(section 5).

### 4.6 Not on the badge

No saves (cart flash I/O is a stub). Neopixels stay off. No audio in M1.

## 5. M2 presentation

- **Title**: a pixel-art covered wagon with a raspberry-red canopy, oxen,
  and a prairie and mountains at sunset, under "THE RASPBERRY TRAIL". Menu:
  NEW GAME, SOUND ON/OFF, CREDITS.
- **Trail strip** (in the HUD, about 10 px): 0..2040 miles across the
  screen width, with markers for INDEPENDENCE, SOUTH PASS (950), BLUE MTNS
  (1700) and OREGON CITY. The wagon icon sits at `hud.mileage_true` and
  slides over about 1 s when a turn's travel lands.
- **Vignettes**: when a line with an event tag first appears, a small
  picture (up to 64x40) sits beside or above the text: wagon breakdown,
  ox, sling, lost son, water, rain/hail, fire, fog, snake, river, wolves,
  cold, blizzard, mountains, fort, riders, bandits, illness (medicine
  bottle), and a food basket for the helpful-food event (no depiction of
  people for that one). The pictures are code-drawn (`tools/gen_art.py`
  writes committed generated data, Python + PIL).
- **Shooting scene**: a background per reason (a deer or buffalo for the
  hunt, riders, bandits, wolves) behind the cue, plus a muzzle flash and a
  hit or miss frame.
- **Death**: a tombstone with the cause ("DIED OF PNEUMONIA"), then the
  original's formalities questions and the Chamber of Commerce letter.
  **Arrival**: Oregon City and President Polk's letter.
- **Help** (Start): the button legend over the current screen. Start or B
  closes it.
- **Credits**: "After THE OREGON TRAIL (1971) by Don Rawitsch, Bill
  Heinemann and Paul Dillenberger. BASIC listing: MECC, 1978, Creative
  Computing May-June 1978. Transcription: github.com/clintmoyer/
  oregon-trail (public domain)."
- **Sound** (off by default, `-Dsound` seeds it, toggled on the title and
  in help; `lib/tone_stream.zig`, never `tone2`): the bell where the
  listing says "BELLS IN LINE 2660" (a big kill) and "5470, 5480"
  (arrival), a gunshot crack on the shot, a low knell at death, and a
  short fanfare at arrival.

## 6. The oracle

Purpose: prove that the engine is the 1978 program, using an independent
implementation that runs **the unmodified listing**.

- `tools/oracle/basic.py`: a small interpreter for exactly the BASIC this
  listing uses: line numbers, `REM`, `PRINT` (`;`, `,` zones, `TAB`),
  `INPUT`, `LET`, implicit LET, multiple assignment, `IF .. THEN line`,
  `GOTO`, `ON .. GOTO` (out of range falls through), `GOSUB`/`RETURN`,
  `DIM`, `READ`/`DATA`/`RESTORE`, `STOP`/`END`, `RND`, `INT`, `CLK`,
  `**`, the comparisons, and string equality. It applies
  `tools/oracle/patches.txt` (line 620 only) and nothing else.
- **Answer script** (`tools/oracle/scripts/*.txt`): a first line
  `seed <u64>`, then one answer per line: `YES`, `NO`, an integer (number
  and choice prompts), or `SHOOT <0|1> <seconds>` (correct flag, a decimal
  that both sides parse as the same f64).
- **Transcript** (both sides print it, compared exactly):
  - `T <text>`: every printed line, whitespace runs collapsed to one
    space, trimmed. Empty lines are skipped. Numbers print as BASIC 3.1
    prints them, after collapsing: an integral value prints as an integer,
    and any other value prints in the shortest round-trip form (the
    listing only prints integral values; any other is a finding).
  - `P <line> <kind>` at every INPUT, then
    `V A=.. B=.. ...`: all of `Vars` in the order declared in `game.zig`.
    An integral value prints as a decimal integer, anything else as `h`
    plus 16 hex digits of its IEEE bits.
  - `I <answer>` as the script gave it.
  - `E <outcome>` at STOP/END.
- `zig build raspberry-trail-oracle` gives `zig-out/bin/raspberry-trail-oracle
  <script>`, which prints the engine's transcript (track L writes
  `tools/oracle_runner.zig`).
- `tools/oracle/compare.py`: runs both on every script and reports the
  first diverging line with context. Exit 0 when everything matches.
- `tools/oracle/fuzz.py`: N seeded random games. The interpreter answers
  each prompt by its line number with seeded random choices (valid and
  invalid numbers, wrong words, slow and fast shots), and records the
  script. Then the comparison runs. The gate runs a fixed set (for
  example 2000 games). The fuzzer also counts coverage: every
  event, every death cause, arrival, every message line of the listing
  reached at least once over the fixed set (a list of the PRINT lines
  never reached is a finding).

## 7. Budgets

- RAM cart, ReleaseSmall: `.text + .data + .bss` under 160 KB (art
  included).
- `update()` under 8 ms worst and 3 ms mean (busy ms, calibrated
  badge-bench) on a mid-game screen, a shooting screen and the title.
- Comptime stays light; data comes from committed generated files.
