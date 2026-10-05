# Universal Paperclips (cart notes)

A faithful port of *Universal Paperclips* (Frank Lantz and Bennett Foddy,
2017; ported with their permission) to the SYCL badge. `SPEC.md` is the
design, `PLAN.md` the milestones, the three tracks and the gate. The root
`CLAUDE.md` has the hardware, the cart API and the repository policies.
`reference/` holds the original JavaScript, HTML, CSS and title picture,
unchanged: the specification, never built.

## Layout

- `cart/src/game/` (track L): the port of the JS, no cart API, host
  testable. The `game` module, rooted at `game/game.zig`: `Game`, `init`,
  `advance_ms`, `Action`, `act`, `enabled`, panel visibility in
  `g.panels`, messages, projects (PLAN.md has the interface). Only track L
  edits it. `snapshot.zig` is the saved game (+ `snapshot_tests.zig`,
  ReleaseSafe in `zig build test`).
- `cart/src/main.zig`: `start`/`update`, the badge seed (clock-mixed; wasm
  uses `cart.rand()`), the wasm shims (`present_wasm`, `read_controls`),
  the debug exports and the badge-bench hooks (`paperclips_bench`,
  `paperclips_seed`).
- `cart/src/ui/` (track U):
  - `app.zig`: the UI state machine without the cart API (host tests
    drive it): title and its code, pages, cursor and scrolling, held
    repeats, Start/Select on release and never during the OS chord, news
    marks, the message log, the HypnoDrones flash, the M1 stage 2 wall,
    and the virtual clock (17, 17, 16 ms per frame).
  - `pages.zig`: which pages exist (the original's panel visibility) and
    their rows, rebuilt from the game state every frame. The one file that
    reads the game's fields for display.
  - `render.zig`: draws the App: header, status line, tab bar, rows,
    footer (a project's price and description), ticker, log.
  - `draw.zig`, `font.zig` + `gen/font5x7.zig`, `layout.zig`, `text.zig`
    (per-frame text arena, word wrap), `numfmt.zig` (compact formats; the
    game's exact JS formats are `game/fmt.zig`), `title.zig` + `gen/title.*`.
  - `saves.zig`: save and continue over lib/save.zig (probe, title
    menu state, autosave timing, calm frames, the exit hook, errors).
  - `tests.zig`: the UI host tests (in `zig build test`).
- `tools/`: `check.sh` (the gate), `gen_font.py`, `gen_title.py`,
  `gen_scripts.py` (the input scripts in `scripts/`); track O's oracle:
  `js_oracle.mjs`, `oracle_runner.zig`, `compare.mjs`, `oracle/`.

## Generated, committed files

`cart/src/ui/gen/font5x7.zig` (`tools/gen_font.py`), `gen/title.zig` and
`gen/title.bin` (`tools/gen_title.py`, 160x125, 16 greys, 4 bits per pixel),
`tools/scripts/*.json` (`tools/gen_scripts.py`). Each generator has
`--check`; `tools/check.sh gen` runs them. Regenerate instead of editing.

## Rules of thumb

- The UI never changes game state except through `G.act` (or the cheat
  actions); what the original does in its display code (buttonUpdate and
  friends) belongs to the game port.
- RAM cart, ReleaseSmall (size; the frame budget has room), no sound, no
  neopixels. Saves (branch `saves/m1`, the patched OS only):
  `game/snapshot.zig` is the blob (the whole `Game`, layout-hashed, so
  any change to `Game` refuses older saves: fine, but say so in the
  commit), `ui/saves.zig` the policy (docs/RUNNING.md section 9).
- Every frame redraws the whole screen (`.no_copy_full_frame`): no dirty
  rect bookkeeping.
- Keep comptime light (the Mac build): data comes from the generators.
- Zig here is 0.17-dev: `@splat` instead of `**` repetition,
  `std.bit_set` `.empty`, `@typeInfo(T).@"enum".field_names`.

## Checks

`tools/check.sh` (build, test, gen, oracle, preview, bench, size);
`docs/RUNNING.md` has the commands, the controls and the debug exports.
