# Emulator cart review evidence for consensus 2026-10-01

Implementation was not changed. This review covers the emulator runtime/frontend boundary, ROM validation, input transitions, replay storage, rendering adapters, and a sampled review of CPU/bus/video execution. It does not claim exhaustive instruction-level or hardware verification.

## Scope and branch inventory

- Main: `/home/exedev/snouty-badge`, commit `79b7e89`; Boy, Gear and Genesis implementations.
- Gear worktree: `/home/exedev/snouty-badge-gear`, `ae16621` (`gear/m3`). Its Gear cart files match main; the worktree has older unrelated manager files, not additional Gear fixes.
- Genesis worktree: `/home/exedev/snouty-badge-genesis`, `53e1369` (`genesis/m4`). Reviewed its later undo scrubber, ROM run/cache changes, Smooth H40 frontend and tests in addition to main.
- Lynx worktree: `/home/exedev/snouty-badge-lynx`, `54f2cf1` (`lynx/m3`). Main has only Lynx plans; implementation findings below refer to this worktree. Its Genesis subtree contains the same later Genesis changes. Its Boy subtree contains an existing serial fix missing on main.
- Read root and per-cart CLAUDE guidance, selected SPEC/PLAN sections and cart running information. Shared build/romfs infrastructure is the parent reviewer's scope.

## Findings

### EM-01 P2 high confidence Boys splash-skip press also chooses a ROM

**Location:** main `carts/snouty-boy/cart/src/main.zig:100-104,133-135`; `frontend/picker.zig:29-32`.

**Trigger:** boot a drive build with two playable ROMs and press A or B during the splash. `suppress_held()` records the suppression mask, then `pick_frame()` executes in the same update. That function passes the raw `controls_state.edge`, so the picker sees the same A/B press that skipped the splash. A immediately launches the first playable drive ROM; B immediately launches the embedded fallback. The selection screen is bypassed before the user can read it. A direction used to skip also moves the initial cursor.

**Evidence:** direct control-flow trace; hardware-only drive path was not executed. Suppression is applied by `State.game_frame()` but not by `Edge.pressed()` or `picker.update`. Genesis and Lynx already have `live_edge()` helpers masking `cur` with `~suppress` before calling their pickers.

**Proposed direction:** apply the live/suppressed edge consistently on every state transition, using the existing later-cart pattern. Include menu entry too: Boy/Gear currently call their menus with raw edges on the update the hold opens them, so a simultaneous newly pressed A/B can immediately dismiss a menu.

**Validation gate:** drive frontend test with two candidates; skip splash separately with A, B, Down and Select. Picker must remain visible, held button must stay ignored, and a fresh press after release must act. This is especially valuable because normal wasm builds compile out drive picking.

### EM-02 P2 high confidence main Boy incorrectly completes external-clock serial transfers already fixed on later branches

**Location:** main `carts/snouty-boy/core/serial.zig:17-29`.

**Trigger/impact:** a game writes SC=0x80 to await a link peer. Main unconditionally overwrites SB with FF, clears the in-progress flag, and raises the serial IRQ even though no external clock exists. The existing later branch documents Tetris/Tetris DX title-screen input being blocked by this false peer response.

**Evidence:** ran the existing later branch's `tests/serial_unit.zig` against the main core, without copying or changing source. Internal-clock case passes; external-clock case fails: `expected 85, found 255`. Log: `/tmp/sycl-review-boy-serial-probe.log`.

**Existing fix:** commit `15709ae` (`snouty-boy: external-clock serial transfers never complete`) in the later branch checks SC bit 0 and has tests. This is an integration decision, not a request to rewrite the fix. No whole-branch merge is implied.

**Validation gate:** retain both internal/external clock regression cases in the main suite and smoke-test title-screen input with an authorized ROM on hardware/simulator after integration.

### EM-03 P2 high confidence malformed Genesis ROM length can abort ROM scanning

**Location:** main `carts/snouty-genesis/core/rom.zig:109-111`, caller `:223-227`; Genesis m4 same function at `:142-144`, caller `:256-260`.

**Trigger:** a 512-byte ROM with `SEGA` at offset 0x100, declared start=0 and end=0xFFFFFFFF. `declared_size()` evaluates `end - start + 1` in u32. Header checking calls this while deciding whether a candidate can run.

**Impact:** ReleaseSafe/Debug abort on integer overflow instead of returning an unplayable verdict. Production ReleaseFast removes the check, making overflow undefined behavior; it is not a reliable rejection path. A malformed copied file can therefore interrupt startup/selection even though validation is supposed to contain it.

**Evidence:** isolated host test `/tmp/sycl-review-rom-probe.zig`, importing the real Genesis m4 ROM module, aborts with `panic: integer overflow`. `/tmp/sycl-review-genesis-probe.log`. The relevant arithmetic is unchanged from main.

**Proposed direction:** calculate/check the span in u64 or validate endpoints before narrowing; represent invalid lengths explicitly rather than accidentally converting them into a plausible size.

**Validation gate:** header spans at zero, max u32, reversed bounds, exactly 4 MiB, and just above the supported range must return stable verdicts in safe and fast builds. Exercise the drive scan with a malformed candidate alongside a valid one.

### EM-04 P2 test-quality finding high confidence unavailable Gear oracle suites count as passing tests

**Location:** main/Gear `carts/snouty-gear/tests/z80_single_step.zig:272-275`; `tests/z80_zex.zig:76-80` (also optional early returns in the ZEX test wrappers).

**Trigger:** run host tests without downloaded SingleStepTests/ZEX fixtures. The tests print "skipped" and `return` successfully instead of `error.SkipZigTest` or a required-fixture failure.

**Impact/evidence:** this review's main test run reports `95/95 tests passed` for Gear while logging that SingleStepTests, zexdoc.sms, and zexall.sms are absent. The summary overstates executed CPU validation. The same Z80 is shared by Genesis, so missing oracle coverage affects confidence in two emulators. Boy's acid2 tests already use actual skip signaling.

**Proposed direction:** honest skip accounting for normal local runs and a separately named strict conformance gate requiring fixtures for release acceptance. Do not silently add fixture downloads/network work to every developer build.

**Validation gate:** run once with fixtures absent, expecting explicit skips/strict failure, and once with fixtures available, expecting nonzero oracle case counts. Preserve a report distinguishing source-level tests from external oracle cases.

### EM-05 P3 high confidence Lynx headered oversized files are silently truncated instead of refused

**Location:** Lynx worktree `carts/snouty-lynx/core/cart.zig:99-119`.

**Trigger:** valid-looking LYNX header with 512-byte block size, bank 1 zero and rotation zero, but total file size 600 KiB. The headered branch returns `.ok` after clipping data to the declared 128 KiB bank; the `> max_size` rejection is reached only by headerless files.

**Impact:** unsupported/corrupt headered content is presented as playable and part of the supplied file is silently ignored; errors surface later as game/boot failures. This also contradicts this source file's refusal contract (“a file over 512 KB”). This is lower priority than the crash above; allowing trailing padding could be intentional, but it should be an explicit documented rule with a bound.

**Evidence:** same isolated host probe expects `.too_big`, receives `.ok`; `/tmp/sycl-review-lynx-probe.log`. Existing tests cover oversized headerless files but not this headered path.

**Proposed direction/decision:** decide whether padding/trailing data is supported, enforce a consistent maximum payload size for both forms, and account for the 64-byte header when setting the accepted maximum. Keep intentionally short homebrew ROM support.

## Architecture design and UX observations for consensus

- Strong separation between pure deterministic console cores and badge frontends. Fixed storage, integer hot paths, static/in-place large console initialization, and explicit XIP/RAM budgets fit the device well. Do not replace this with allocation-heavy abstraction merely to reduce line count.
- The shared Z80 module between Gear and Genesis is a good reuse boundary. Generated decode/VDP tables, committed licensed homebrew fixtures, targeted CPU/VDP tests, frame hashes, and rewind determinism tests provide useful evidence.
- Lynx's compile-time classification of every console field into saved state or explicit exclusions is particularly good. It guards against future rewind regressions when adding fields. Genesis/Lynx undo structures make memory pressure/eviction behavior explicit; deterministic tests and sizing runs cover these tradeoffs.
- Most frontend logic is global singleton state and copied between carts. This is acceptable for one cart process, but transition/suppression fixes have already diverged (EM-01), as have no-ROM and B/cancel behavior. Prefer a small tested input/transition adapter or shared contract tests before extracting a broad common emulator framework. Preserve distinct console-specific controls and renderer hot paths.
- Emulator menu discovery is weak for a new badge holder: the logo-only splashes do not surface the Select-hold menu gesture, and settings/scrub controls require documentation or prior knowledge. Consider a short, dismissible on-device `Hold Select: menu` hint and explicit in-menu scrub/back hints. This is a product decision, not a proven rendering defect. No visual/hardware usability session was run by this reviewer.
- ROM behavior is inconsistent: Gear uses the first matching .gg/.sms without a picker, Boy only offers its picker at boot, Genesis and Lynx offer later picking; Genesis picker B launches embedded, Lynx picker B keeps the existing cart. These choices are documented individually but create transfer-of-learning cost. Agree a cross-emulator convention before implementation changes.
- ROM diagnostics differ in how visible they are (Gear/Genesis report mostly behind debug/About, Lynx always has a strip). Consider consistent actionable refusal/fallback messaging and expose all relevant errors without requiring a debug setting. Avoid turning low-level CRC/fragmentation data into the primary onboarding message.
- Reviewed intentional limitations (approximate sound, absent save persistence, mapper/RTC/address-error scope, dropped video lines) should remain explicit capability boundaries. They are not all defects. Accurate acceptance tests must also not equate deterministic self-consistency with hardware accuracy.
- Documentation has scattered milestone-era statements: e.g. Lynx frontend/main and rewind comments still describe 30-frame records while `core/undo.zig` deliberately uses 60; Lynx splash comment promises a future M2 chime while project guidance now says no sound. Keep current behavior/reference separate from historical plans. Main versus worktree status must be explicit in any newcomer guide.

## Validation performed

1. Main: `/home/exedev/.local/bin/zig build test -Dcart=snouty-boy,snouty-gear --summary all` — exit 0, 7/7 steps, Gear 95/95 reported; Boy/lib tests cached in this invocation. Three external Gear oracle fixtures were absent and reported as successful returns (EM-04). Parent reran root tests separately for full auditable totals.
2. Genesis m4: `/home/exedev/.local/bin/zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip --summary all` — exit 0, 168/168. Log `/tmp/sycl-genesis-tests.log`. M68k fetch-window oracle: 36 files, 290340 cases, 230306 passes, 60033 intentionally skipped address-error cases, 1 disputed, zero state/cycle-only failures. Bus-fetch oracle: 9 files, 72585 cases, 46623 passes, 25961 address-error skips, 1 disputed. Includes golden, fragmented-ROM, undo/determinism and sizing tests.
3. Lynx m3: `/home/exedev/.local/bin/zig build test-lynx -Dcart=snouty-lynx --summary all` — exit 0, 108/108. Log `/tmp/sycl-lynx-tests.log`. 65C02 SingleStepTests: 24 files, 240000 cases, zero failures. Includes boot crosschecks, undo/determinism and sizing with available fixtures. These are fixture subsets, not every opcode fixture or every commercial title.
4. Main Boy core with later existing serial tests: `/home/exedev/.local/bin/zig test -Osafe --dep core -Mroot=/home/exedev/snouty-badge-lynx/carts/snouty-boy/tests/serial_unit.zig -Mcore=/home/exedev/snouty-badge/carts/snouty-boy/core/gb.zig --test-filter 'serial:'` — internal-clock passes, external-clock fails (EM-02).
5. Isolated malformed-header probes: `/home/exedev/.local/bin/zig test -O ReleaseSafe --dep mdrom --dep lynxcart -Mroot=/tmp/sycl-review-rom-probe.zig -Mmdrom=/home/exedev/snouty-badge-genesis/carts/snouty-genesis/core/rom.zig -Mlynxcart=/home/exedev/snouty-badge-lynx/carts/snouty-lynx/core/cart.zig --test-filter Genesis` (and `--test-filter Lynx`) — expected failures described in EM-03/05. Only temporary files were written; no tests were added to repository implementation.

Some successful Zig 0.17 build logs contain a `failed command:` diagnostic following test stderr, yet the process exits 0 and reports all steps succeeded. Results above use the exit status plus final build summary, not that standalone line.

## Limits and created artifacts

No badge was attached or flashed, no USB-drive interaction or physical control timing tested, no browser visual inspection by this reviewer, no cycle/interrupt/audio accuracy audit of every opcode, no new fixture download, and no attempt to run proprietary ROMs beyond repository tests' already configured local fixtures. Large CPU/VDP/Suzy implementations were sampled and exercised by available tests, not exhaustively proven. No claim that passing source/golden tests guarantees playable coverage for arbitrary ROMs.

Created artifacts: this note; `/tmp/sycl-review-rom-probe.zig`; `/tmp/sycl-genesis-tests.log`; `/tmp/sycl-lynx-tests.log`; `/tmp/sycl-review-genesis-probe.log`; `/tmp/sycl-review-lynx-probe.log`; `/tmp/sycl-review-boy-serial-probe.log`; ordinary Zig compiler/cache artifacts from host-test commands. No symlinks were created, including `.venv` or any `tests/roms` symlinks. Those were not created by this reviewer. No implementation, git state, ROM fixtures, or docs in the repository were edited.
