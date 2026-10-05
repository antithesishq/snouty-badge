# The Raspberry Trail oracle

An independent check that the engine (`cart/src/game/`) is the 1978
program: a small BASIC interpreter runs the **unmodified**
`reference/oregon.bas`, and its transcript is compared, byte for byte,
with the engine runner's (`zig build raspberry-trail-oracle`). SPEC.md
section 6 is the design. Python 3 standard library only.

| File | What it does |
|---|---|
| `basic.py` | The interpreter. `basic.py run <script>` prints the transcript. |
| `patches.txt` | The one patch applied to the listing before it runs (line 620). |
| `compare.py` | Runs both sides on scripts, reports the first diverging line. |
| `fuzz.py` | Seeded random games, the engine comparison, and coverage. |
| `unreachable.txt` | PRINT lines and outcomes no game can reach, each with its reason. |
| `mkscripts.py` | Writes the named scripts in `scripts/` (seed search per scenario). |
| `scripts/*.txt` | The named answer scripts. |

## Running

From the repository root:

```
export PATH=$HOME/.local/bin:$PATH
zig build raspberry-trail-oracle -Dcart=raspberry-trail   # zig-out/bin/raspberry-trail-oracle
cd carts/raspberry-trail/tools/oracle
./compare.py                         # every scripts/*.txt, both sides
./fuzz.py --games 2000 --seed 1      # the gate's fuzz set: comparison + coverage
./basic.py run scripts/arrival.txt   # one transcript from the oracle
```

`--runner PATH` points `compare.py` and `fuzz.py` at another runner
binary. `fuzz.py --no-engine` checks coverage with the oracle alone.
`fuzz.py --seed 1 --index 17 --print-script` prints one fuzz game's
script. Differing fuzz games' scripts are written to a temporary
directory (or `--fail-dir`) and named in the report.

Exit status: `compare.py` 0 iff every script matches (transcript and exit
status); `fuzz.py` 0 iff every game matches and every PRINT line and
outcome not in `unreachable.txt` was reached; 3 when the runner is
missing.

`mkscripts.py` rewrites the named scripts (the seed search is
deterministic); `mkscripts.py --check` verifies the committed ones still
reach their goals.

## The patch

`reference/oregon.bas` line 620 reads `PRINT ""RETURN"" KEY, ...`: the
transcription dropped a quote. `patches.txt` replaces it with

```
620 PRINT """RETURN"" KEY, THE BETTER LUCK YOU'LL HAVE WITH YOUR GUN."
```

which prints `"RETURN" KEY, THE BETTER LUCK YOU'LL HAVE WITH YOUR GUN.`
Nothing else is changed.

## BASIC semantics (CDC Cyber BASIC 3.1, as the listing uses it)

- Numbers are IEEE f64. Expressions keep the listing's order: normal
  precedence (`**`, unary minus, `* /`, `+ -`, comparisons), left to
  right, nothing simplified. `X**2` is `X*X` (integral exponents multiply
  out). `INT` is floor. Unset variables are 0.
- Multiple assignment (`K8=S4=F1=F2=M=M9=D3=0`, `LET K8=S4=0`,
  `L1=C1=0`) assigns every name.
- `ON e GOTO`: `INT(e)` picks the target; out of range falls through to
  the next line.
- `DIM` can run again (the shooting subroutine re-DIMs `S$`); it changes
  nothing. `C$` and the array `C$()` are separate.
- `RND(-1)` is one draw of `cart/src/game/rng.zig`: splitmix64(seed) seeds
  xorshift64* (12, 25, 27, multiplier 0x2545F4914F6CDD1D), and the value
  is `(next >> 11) * 2^-53`. Every RND in a condition is drawn when the
  condition is evaluated. `basic.py rng <seed> <n>` prints the first
  draws; they match the Zig generator.
- `CLK(0)` returns 0 at the shot's first call (line 6210) and
  `seconds / 3600` at the second (line 6230), so line 6240 computes
  `B1 = ((seconds/3600 - 0) * 3600) - (D9 - 1)`. The `INPUT C$` at 6220
  receives the right word `S$(S6)` for `SHOOT 1`, and `XXXX` for
  `SHOOT 0` (so `B1 = 9`).
- `PRINT`: `;` joins, `,` moves to the next 15-column zone, `TAB(n)`
  moves to column n, and a trailing `;` keeps the line open. Numbers
  print as BASIC 3.1 prints them: a sign position (blank or `-`), the
  digits and a trailing blank.

## Script format

```
seed 12345
# comment lines and blank lines are ignored
NO
3
250
SHOOT 1 0.85
```

The first line is `seed <u64>`. Then one answer per line, in the order
the INPUTs come: `YES` or `NO` (yes/no prompts), an integer (number and
choice prompts, may be negative), or `SHOOT <0|1> <seconds>` (shooting:
right word or not, and a decimal parsed with `float()`, the same f64 on
both sides).

## Transcript format

One record per line on stdout:

- `T <text>`: every printed line, whitespace runs collapsed to one space,
  trimmed; empty lines skipped. A line still open after a trailing `;`
  is flushed as its own `T` line when an INPUT happens (no `?`), or at
  STOP. The listing prints integral values only (after collapsing,
  "TOTAL MILEAGE IS 950"); a non-integral value would print as Python
  `repr()` and is flagged on stderr as a finding.
- At every INPUT: `P <line> <kind>`, where kind is
  `yes_no` (190, 5220, 5240, 5260), `number` (860, 940, 990, 1040, 1090,
  2330), `choice` (760, 2100, 2180, 2770, 3000) or `shoot` (6220). Then
  `V` and every variable of `game.zig`'s `Vars` in this order, as
  `NAME=value` separated by single spaces:
  `A B B1 B3 C C1 D D1 D3 D9 E F F1 F2 F9 K8 L1 M M1 M2 M9 P R1 S4 S5 S6 T T1 X X1`.
  An integral value with |x| < 2^53 prints as a decimal integer
  (negative zero as `0`); anything else as `h` plus 16 lowercase hex
  digits of its IEEE-754 bits (`h4041b44834b056ac`). Then
  `I <answer>`, the script's answer with single spaces.
- At STOP or END: `E <outcome>`, by the first of these lines executed:
  5470 `arrived`, 5060 `starved`, 5080 `no_doctor_money`, 5110
  `no_medicine`, 1690 `winter`, 3520 `massacred`, 4260 `snakebite`;
  otherwise reaching 5120 with K8=1 gives `injuries` and with K8=0
  `pneumonia` (which no game can reach: see `unreachable.txt`).
- The script ends before the game does: `X eof` (after that INPUT's `P`
  and `V` lines), exit status 0.
- An answer of the wrong kind for the INPUT (`SHOOT` at a number prompt,
  `YES` at a choice, a non-integer): `X mismatch <line>` (after the `P`
  and `V` lines, no `I`), exit status 2.

## Fuzzing

`fuzz.py` derives each game's seed and answer policy from `--seed` and
the game's index. The policy profiles (arrive, careful, crawl, slow,
starve, broke, nomisc, noammo, random, invalid) mix valid answers with
invalid ones (negative, zero, too big, out-of-range choices, fort
overspending), right and wrong words, and shots from 0 to 12 s, which
yields every outcome, every event and every reachable PRINT line over
the fixed set. The report lists the outcomes, the events (games reaching
each line), the PRINT lines reached and unreached, and the statements
never executed.
