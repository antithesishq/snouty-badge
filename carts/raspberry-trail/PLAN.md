# The Raspberry Trail: plan

Design in `SPEC.md`. Lead worktree `/home/exedev/snouty-badge-trail`, branch
`trail/m1` (the integration branch), from origin/main c3fc0019.

## Milestones

- **M1: the whole game, playable.** The engine port matches the unmodified
  listing on every oracle script and on the fuzz set. The badge UI covers
  the HUD, log and paging, menus, the spinner, the shooting cue, the log
  history and the end screen, with a text title. Gate green, tag
  `raspberry-trail/m1`, merge to main.
- **M2: presentation.** The art title and menu, the trail strip with the
  sliding wagon, event vignettes, shooting scenes, the tombstone, the
  arrival scene and letters, help, credits, and sound (off by default).
  Gate green, tag `raspberry-trail/m2`, merge to main.

## Tracks (Opus agents, one worktree each, disjoint paths)

Each track branches from the plan commit, commits only its own paths and
never pushes. The lead merges each track into `trail/m1`.

- **L, engine**: worktree `/home/exedev/snouty-badge-trail-engine`, branch
  `trail/engine`. Owns `cart/src/game/**` and `tools/oracle_runner.zig`.
  Replaces the stub in `game.zig` with the full port (SPEC 3), keeping the
  public interface. Host tests in `game/tests.zig`: each event's
  arithmetic, each death, arrival with the weekday and date, the 950
  display quirk, the RNG draw counts, and a bot that plays 10,000 seeded
  games to the end with no assert and no overflow of `lines`/`text`.
  Writes the oracle runner to the transcript format of SPEC 6. Runs O's
  `compare.py` against its runner as soon as O has it (it can pull O's
  files read-only with `git -C ../snouty-badge-trail-oracle show
  trail/oracle:<path>`), and fixes the engine until everything matches.
- **O, oracle**: worktree `/home/exedev/snouty-badge-trail-oracle`, branch
  `trail/oracle`. Owns `tools/oracle/**`. `basic.py` runs
  `reference/oregon.bas` per SPEC 6, plus `patches.txt`, `compare.py`,
  `fuzz.py`, and hand-written scripts in `scripts/` covering every prompt,
  every invalid input path, each death, arrival, and the fort and hunting
  loops. Self-test: the interpreter plays a full game, and its output
  matches the listing's messages. O reports mismatches to the lead with
  the first diverging transcript line. L fixes them, unless the oracle is
  wrong.
- **U, cart and UI**: worktree `/home/exedev/snouty-badge-trail-ui`,
  branch `trail/ui`. Owns `build.zig`, `cart/src/main.zig`,
  `cart/src/ui/**`, `tools/gen_font.py`, `tools/check.sh`,
  `tools/scripts/**` (preview input scripts), `docs/**`, `CLAUDE.md`, and
  the root registrations (README.md carts table, root CLAUDE.md cart list,
  docs/INSTALL.md, badge-manager/sets.default.toml; root `build.zig` is
  already done). Builds SPEC 4 against the interface. The plan commit's
  stub engine walks every prompt kind, and U switches to the real engine
  when the lead merges L. Wasm debug exports for preview scripts (screen,
  prompt kind and line, turn, mileage, cursor), a badge-bench seed poke
  (`raspberry_trail_seed`), and an autoplay poke that answers prompts by
  itself for bench runs. In M2, U also integrates A's art and adds sound
  (SPEC 5).
- **A, art**: worktree `/home/exedev/snouty-badge-trail-art`, branch
  `trail/art`. Owns `tools/gen_art.py`, `cart/src/art/**` (generated data
  plus a small `art.zig` draw API with no cart API: it writes into a
  caller-supplied pixel sink so host tests can run), `docs/art_sheet.png`
  and `ASSETS.md`. Paints every SPEC 5 picture in code (Python + PIL, the
  snouty-art way: shapes, palettes, dithering), as palette-indexed data
  with transparency. Has `--check`. Starts at once, since nothing depends
  on M1.

### Interface

`cart/src/game/game.zig` as committed in the plan commit: `Game`, `init`,
`start`, `answer`, `Prompt`/`PromptKind`/`Answer`, `Line`/`Tag`, `Hud`,
`Vars`, `Outcome`, `ShotReason`, `Word`. L may add, not rename. A's
interface is its own `art.zig` (L and U do not touch it). U calls it in M2.

## Gate (`tools/check.sh`, written by U)

- build: `zig build -Dcart=raspberry-trail` (ELF, UF2, wasm).
- test: `zig build test -Dcart=raspberry-trail`.
- gen: `gen_font.py --check`, `gen_art.py --check`.
- oracle: `zig build raspberry-trail-oracle`, then `tools/oracle/compare.py`
  on every script and the fixed fuzz set (exit 0), plus the coverage
  report with no unreached PRINT lines (except ones the lead has listed as
  unreachable with a reason).
- preview: headless runs of the wasm (`../../tools/preview.mjs`). A
  scripted full game, a death, an arrival and a shooting run, each without
  a trap. The scripted game's frames go to `out/check/` for review.
- bench: calibrated badge-bench, worst <= 8 ms and mean <= 3 ms busy, on
  autoplayed games.
- size: `.text + .data + .bss` <= 160 KB.

## Status

- 2026-10-05: SPEC + PLAN + interface skeleton (plan commit). Tracks L, O,
  U, A starting.
- 2026-10-05: U's M1 UI on trail/ui with the real engine: gate green
  (oracle PASS, previews: a game, plain presses, a starvation, an arrival,
  8 shots; bench worst 2.11 ms / mean 1.21 ms busy over five autoplayed
  3000-frame runs; size 67.6 KB). docs/preview_m1.gif.
- 2026-10-05: U's M2 presentation on trail/ui (with A's art): art title
  and menu (NEW GAME, SOUND, CREDITS), trail strip with the sliding wagon,
  event vignettes in the log, shooting scenes with flash and hit/miss,
  tombstone and arrival scenes, help on Start, credits, sound through
  tone_stream (off by default). Gate green: bench worst 3.27 ms / mean
  1.70 ms busy (hunting with sound), size 108.1 KB. docs/preview_m2.gif.

## Deferred questions (defaults taken)

- `shot_time_scale` 0.75 (SPEC 4.4). Retune after a badge play.
- Spinner bounds make the original's invalid-input messages unreachable on
  the badge (SPEC 3.3). Default: clamp, because the messages are input
  validation, not gameplay.
- Theme colours: cream paper and raspberry ink (SPEC 4.1).
