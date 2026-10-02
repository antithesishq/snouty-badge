# Review follow-up: parallel workstreams

Implementation plan for the findings in [README.md](README.md). Written 2026-10-01 after comparing the review baseline against `origin/main`. Each workstream below is self-contained so one agent can take it without reading the others. Finding IDs (G1, EM-03, INF05, ...) refer to the detail notes in this directory: [games.md](games.md), [emulators.md](emulators.md), [infrastructure.md](infrastructure.md), [docs-ux.md](docs-ux.md). Read the finding's own section before starting on it; it has the file/line evidence, the trigger, and the acceptance check.

## Baseline correction every agent must know

The review ran on the local `main` checkout at `79b7e89`, which is **165 commits behind `origin/main`**. Against `origin/main`:

| Finding | Review said | Actual state on `origin/main` |
|---|---|---|
| EM-02 Boy external-clock serial | fix on a later branch | **already merged** (`15709ae`). Dropped. |
| G2 Flyover coordinate wrap | branch only | Flyover M4 is **on main**. Ships today. |
| G3 Reflections half30 frozen budget | branch only | Reflections M4 is **on main**. Ships today. |
| EM-05 Lynx headered oversize | branch only | Lynx M4 is **on main**. Ships today. |
| everything else | main | unchanged on `origin/main`, still live |

The `lib/romfs.zig` change on `origin/main` since the baseline (`bbb6ce3`, incremental CRC) does **not** address INF01.

**Start every workstream from `origin/main`**, in a fresh worktree:

```sh
cd /home/exedev/snouty-badge && git fetch origin
git worktree add /home/exedev/snouty-badge-<stream> -b <stream>/m1 origin/main
```

Do not work in `/home/exedev/snouty-badge` itself: its `main` has uncommitted edits (README, Boy CLAUDE.md/build.zig/RUNNING.md, calibrate README, SDK gitlink) that are not yours to resolve. This review directory is untracked there; read it by absolute path `/home/exedev/snouty-badge/docs/reviews/2026-10-01/`.

## House rules (from project guidance)

- Zig is `/home/exedev/.local/bin/zig`. Root gate: `zig build test --summary all`. Default soft-float gate: `zig build check-float`.
- Build everything, no placeholders. Perf is tuned against calibrated badge-bench, never guessed; hardware checks are deferred to show day and never block a merge.
- Keep comptime light (Adrian builds on a Mac where heavy comptime OOMs this Zig). Use host generators for tables.
- `build.zig` must never branch on file existence or environment variables (configure-phase cache).
- No audio work. Neopixels stay off.
- Every fix lands with the regression test the finding names. Do not add tests that merely mirror the implementation.
- When a stream's verification is green, **merge to main and push without asking** (temp-worktree merge if the main checkout is dirty), tag it `review-2026-10-01/<stream>`, and record what was done in the stream section of this file. Adrian tests on a real badge from main.
- Default every open decision the way this plan says; do not stop to ask unless Adrian has to run the simulator to unblock.

## Workstream A: honest test gate (small, do first)

**Why first.** The root gate is red (G5) and incomplete (G4, EM-04), and the float check can inspect the wrong artifact (INF05). Every other stream needs a trustworthy green gate to land against. No runtime behavior changes in this stream.

| Item | Finding | Files | What to do |
|---|---|---|---|
| A1 | G5 | `carts/demosnout/cart/src/timeline.zig:328` | The test asserts `Cut.seamless` on a visibility tie where `veil()` returns the incoming cut. Assert the user-visible invariant instead: visibility 256 and no auto-advance while held. **Do not change `veil()` or rendering.** |
| A2 | G4 | `carts/snoutenstein/build.zig` | Register the five pure suites that `carts/snoutenstein/tools/check.sh` runs with `zig test` (sim, levels, level_parse, rewind, demo) on `opts.test_step`. Model: `carts/snouty-maze/build.zig:40-52`. Running `rewind.zig` alone already pulls the others transitively (65 tests); registering one root module is acceptable if the count matches `check.sh`. Keep generated-source freshness checks read-only. |
| A3 | EM-04 | `carts/snouty-gear/tests/z80_single_step.zig:272-275`, `tests/z80_zex.zig:76-80` and the other optional early returns in the ZEX wrappers | Replace the `print("skipped"); return;` pattern with `return error.SkipZigTest` (Boy's `tests/acid2.zig:63` is the model). Add a separate strict step, e.g. `zig build test-z80-strict -Dcart=snouty-gear`, that fails when fixtures are absent and prints the executed case count. Do not add network fetches to the default build. Genesis shares this Z80; check whether its oracle wrappers have the same pattern and treat them the same way. |
| A4 | INF05 | `carts/snouty-reflections/build.zig:43`, `carts/snouty-maze/build.zig:41`, `carts/demosnout/build.zig:33` | The float check hard-codes `<name>.elf`. Derive the checked artifact list from the selected cart mode: RAM checks `<name>.elf`, XIP checks `<name>-xip.elf`, `both` checks both. Look at how the root `build.zig` exposes the mode to carts and reuse it rather than re-reading the option. |

**Acceptance.**

```sh
zig build test --summary all                              # green, Snoutenstein suites counted
zig build test -Dcart=snouty-gear --summary all           # shows skips, not passes, with fixtures absent
zig build check-float -Dcart=snouty-reflections -Dcart-mode=xip --prefix /tmp/xipcheck   # passes from an empty prefix
zig build check-float -Dcart=snouty-reflections -Dcart-mode=both --prefix /tmp/bothcheck # reports both ELFs
```

Update `docs/RUNNING.md:54-60` (test command list) to name the strict Z80 gate and the Snoutenstein suites now in the root gate.

**Done 2026-10-02** (branch `gate/m1`, tag `review-2026-10-01/A`), no runtime behavior changed:

- A1: the Demosnout hold test asserts visibility 256 and no auto-advance while held; the tied-cut assertion is gone, `veil()` and rendering untouched. Root gate green again.
- A2: `carts/snoutenstein/cart/src/host_tests.zig` (rewind.zig, which reaches sim, levels and level_parse, plus demo.zig) registered on the shared test step: 69 tests, the union of the five suites `tools/check.sh` runs. Freshness checks stay in check.sh.
- A3: Gear's Z80 SingleStepTests/ZEXDOC/ZEXALL wrappers and Genesis's 68000 SingleStepTests return `error.SkipZigTest` when fixtures are absent (`zig build test` shows 3 and 2 skips). New strict steps outside `test`: `zig build test-z80-strict -Dcart=snouty-gear` and `zig build test-m68k-strict -Dcart=snouty-genesis -Dcart-mode=xip` set `SNOUTY_FIXTURES=required` on the run, fail with `FixtureMissing`, and print executed case counts. Verified failing with fixtures absent, and the Gear step passing with the 36-file subset plus both ZEX ROMs (36000 cases, 79 + 79 OK). The m68k strict step was not seen passing (no 68000 fixtures fetched). Gear's default test run is now `has_side_effects` like Genesis's.
- A4: `common.add_float_check(b, opts, name, mode)` derives the ELF list from `os_cart.Mode.elf_suffixes()`; the five float-checked carts use it (Zero passes `.xip`). Verified from empty prefixes: XIP checks `snouty-reflections-xip.elf` only, `both` checks both ELFs, RAM checks the four other carts' ELFs.
- Root gate after A: `zig build test --summary all` = 21/21 steps, 496/505 tests passed, 9 skipped, 0 failed (Boy's gitignored `tests/roms/` fixtures copied into the worktree; without them Boy's test binary does not compile, a pre-existing property of its `@embedFile` tests, not changed here).

## Workstream B: badge-manager station (TAKEN, another agent)

INF02, INF03, INF04, UX-01, UX-02, UX-03, UX-04. Listed only so the other streams know its scope. **One overlap:** INF04 wants a shared UF2 validator used by both `badge-manager/badge_manager/library.py` and `tools/uf2_info.py`. The validator lives on the badge-manager side; other streams must not edit `tools/uf2_info.py`.

## Workstream C: cart correctness on main

Independent of A except that you should rebase onto main after A merges so the gate counts your new tests. Items are in priority order; each is its own commit with its own test. If the stream is split across two agents, split as C1-C3 (games) and C4-C8 (emulators and shared loader): they touch disjoint files.

| Item | Finding | Files | What to do and the default decision |
|---|---|---|---|
| C1 | G2 (P1) | `carts/snouty-flyover/cart/src/camera.zig:76,229,268`, `world.zig:160-180,339-345` | Camera `y` is i32 Q16 and only grows; it wraps negative after row 32767 (about 25 min of cruise, or 128 Select skips), and the ring's generation head stays in the positive region, so terrain stops. **Default fix:** split the camera into an integral world row (`i32`, plenty of range) plus a Q16 fraction, or widen `y` to i64 Q16 and keep the row-derived values i32. Changing `+=` to `+%=` is explicitly not a fix. Every consumer of `cam.y >> fixed.Q` (`camera.zig:165,286,299,315`, world probes, segments, districts) must agree. **Tests:** (1) a crossing test that drives the camera past row 32768 and asserts `generated_row` holds for the whole window and `debug_world_check` stays clean; (2) a repeated-skip soak reproducing the review's 130-skip script (command in games.md G2). Run `zig build -Dcart=snouty-flyover` and the cart's existing golden gate afterward; the 2400-update golden must not change. Re-run badge-bench for the cart and record worst-frame ms in PLAN.md (M4 was 14.26 ms worst). |
| C2 | G1 (P2) | `carts/snoutenstein/cart/src/rewind.zig:134-138,245-256,268-274`, `main.zig:284-286` | `take_over()` calls `end_rewind()` (commit writes a `count_rewind` patch and applies it) then `set_meter()` (rewrites the patch, keeps `count_rewind`, applies again). `apply_patch` increments `s.rewinds`, so the live state counts twice while replay counts once, and `debug_desync` goes to 1. **Default fix:** make the patch idempotent by storing the absolute `rewinds` value in the patch rather than a count flag, so applying it twice is harmless; alternatively have `set_meter` update only the meter and leave the existing patch untouched. **Tests:** the takeover-during-demo-rewind scenario (exact preview command in games.md G1: press UP at update 1900, expect `debug_rewinds == 1` and `debug_desync == 0`) added to `carts/snoutenstein/tools/check.sh` and a unit test in `rewind.zig` for patch-at-same-tick composition. |
| C3 | G6 (P3) | `carts/snouty-bugs/cart/src/enemies.zig:220-226`, `hud.zig:94-95` | Boss HP is stored in a `u8` capped at 255 while `boss_max_hp()` keeps returning `60 + 20*loop`, so from stage 11 the HUD bar is never full. **Default:** cap `boss_max_hp()` at 255 too, so spawn and HUD share one maximum. Unit test on `boss_max_hp(10)` and `(20)`. |
| C4 | EM-01 (P2) | `carts/snouty-boy/cart/src/main.zig:100-104,133-135`, `frontend/picker.zig:29-32`; also Boy and Gear menu entry | The A/B press that dismisses the splash reaches `pick_frame()` in the same update through the raw `controls_state.edge`, so A launches the first ROM and B the fallback before the picker is seen. Genesis and Lynx already have a `live_edge()` helper that masks `cur` with `~suppress`. **Fix:** add the same helper to Boy (and Gear) and use it on every state transition: splash to picker, picker to game, and the update on which the Select hold opens the menu (today a simultaneous fresh A/B can dismiss the menu). **Tests:** a drive-frontend host test with two candidates that skips the splash with A, B, Down and Select in turn and asserts the picker is still showing, the held button is ignored, and a fresh press after release acts. Normal wasm builds compile drive picking out, so this must be a host test, not a preview script. |
| C5 | EM-03 (P2) | `carts/snouty-genesis/core/rom.zig` `declared_size()` and its caller in header checking | `end - start + 1` in u32 overflows for a header declaring end `0xFFFFFFFF`: panic in safe builds, UB in ReleaseFast. **Fix:** compute the span in u64 or validate `end >= start` and `end < max` before narrowing, and return an explicit unplayable verdict. **Tests:** spans at zero, max u32, reversed bounds, exactly 4 MiB, just above the supported range, in both `-OReleaseSafe` and `-OReleaseFast`; plus a drive-scan test with a malformed candidate beside a valid one. |
| C6 | INF01 (P2) | `lib/romfs.zig:81` and `find()` / `map()` | Geometry validation never bounds root/FAT/data offsets or total sectors against the backing extent, and caps the cluster count instead of rejecting an inconsistent FAT. **Fix:** give the volume an explicit backing length (the physical 1280 KiB on badge builds; the fixture length in tests) and reject any derived range outside it with `BadGeometry` before any directory or data access. Keep truncated-fixture support through an explicit test constructor, not unchecked pointers. **Tests:** the review's probe geometry (reserved 3000, 2 FATs of 8 sectors, total 4000, see infrastructure.md INF01) must return `BadGeometry`; every existing fragmented-fixture test must still pass. This lib is shared by Boy, Gear, Genesis and Lynx; run all four carts' host tests. |
| C7 | G3 (P2) | `carts/snouty-reflections/cart/src/pt.zig:41-43,126-132`, `variant.zig:68`, `main.zig:28` | The frozen path tracer's fixed 36 ms slice assumes the shipped cut20 variant's 50 ms frame; the supported `half30` variant runs 30 fps and overruns every frame while converging. **Default decision:** derive the slice from the variant's frame period minus a measured display/dither headroom, so half30 stays at 30 fps with a shorter slice. Do not drop half30 to 20 fps. **Tests:** a host test asserting slice < period for every variant in `variant.zig`; keep `tools/check_pt.mjs` (6 seed-preservation views) green. Record the per-variant slice in `docs/RUNNING.md`. The simulator takes a fixed column count, so hardware pacing is unverifiable here; note that in PLAN.md as a show-day check. |
| C8 | EM-05 (P3) | `carts/snouty-lynx/core/cart.zig:99-119` | Headered files over the declared bank size are silently clipped while raw oversized files are refused. **Default decision:** refuse both forms consistently; the accepted maximum for a headered file is the raw maximum plus the 64-byte header. Keep short homebrew ROMs working. Update the refusal comment in the file. **Tests:** the review's 600 KiB headered case returns `.too_big`; a 128 KiB + 64 byte headered file is `.ok`. |

**Acceptance for the stream.** Root gate green, every touched cart's own check script green, `zig build` for all carts in both RAM and XIP modes, and badge-bench numbers re-recorded for Flyover (C1) and Reflections (C7). Perf budgets must not regress.

**C1-C3 done 2026-10-02** (branch `cgames/m1`, unmerged):

- C1: Flyover `cam.y` is i64 Q16, every row through `camera.cam_row()` (i32); render marches with the low 32 bits; the ring check moved to `world.check()`. Host test `cart/src/host_tests.zig` (autopilot across row 32768, ring window + `world.check` every frame; crashes with the old i32 y) on the root gate; new `tools/check.sh` = render golden (12/12 unchanged) + the 130-skip soak (`tools/scripts/skip_soak.json`: row 32769 at 639, `debug_world_check == 0`). Calibrated bench worst 15.08 ms (was 15.07), mean 8.35.
- C2: Snoutenstein rewind patches store the absolute `rewinds` (idempotent); `set_meter` keeps the live count. Unit test (commit + two `set_meter` at one tick, self-checks and rewind against a reference) and the UP-at-1900 takeover preview in `tools/check.sh`; check.sh all passed.
- C3: Bugs boss HP moved to pure `boss_hp.zig`, capped at 255 for spawn and HUD; tests for loops 0/1/9/10/20/255 registered on the root gate (Bugs' first host tests). check.sh 14/14.

## Workstream D: onboarding, docs and on-device discovery

Independent of A and C in code, but **D touches each cart's `docs/RUNNING.md` and README**, and C7 also edits Reflections RUNNING. Coordinate by having D rebase on main after C merges, or by having D leave the Reflections frozen-slice paragraph to C7.

| Item | Finding | Scope | What to do and the default decision |
|---|---|---|---|
| D1 | UX-05 | Boy, Gear, Genesis, Lynx frontends (`frontend/splash.zig`, `frontend/menu.zig` in each) | Add one shared hint pattern: a small, dismissable "Hold Select: menu" line on the splash and for the first few seconds of play, a contextual "Left/Right: rewind" hint when the Resume row is selected, and a "B: back" line in the menu footer. Put the drawing helper in `lib/` next to `lib/iris_mark.zig` so the four carts share it. **Do not change the hold gesture or any button mapping.** Verify with `tools/preview.mjs` menu screenshots for each cart (commands in docs-ux.md). Each cart's existing golden frames may need re-pinning; say so in the commit. Check perf stays within each cart's budget; the hint must not run in the per-frame hot path beyond a blit. |
| D2 | DOC-03 | Snoutenstein, Bugs, Run | Add a short controls card near the top of each cart's `docs/RUNNING.md`: badge buttons first, simulator keys second, with pause, resume, sound toggle and OS exit (Start+Select). Snoutenstein's card comes from `SPEC.md:46-60`. Add a pause-screen help legend in Snoutenstein (`render/hud.zig:184-185`) and Bugs (`hud.zig:130-155`) listing the in-game actions. Fix Run's README to name the A button. |
| D3 | DOC-01 | new `docs/INSTALL.md`; links from every cart's RUNNING | One canonical install recipe: the badge's normal `SYCLBADGE` cart drive versus the RP2350 bootloader drive (OS only), exact file naming, eject, menu launch, exit chord, and how to recognize the wrong-drive mistake. Boy's `docs/RUNNING.md:381-389` is the correct source; Reflections `docs/RUNNING.md:382` and Flyover `docs/RUNNING.md:320` are wrong and must be replaced with a link. Mark the CURRENT.UF2 auto-launch behavior as "to verify on the badge at show day". |
| D4 | DOC-02 | root `README.md`, `docs/RUNNING.md` | Add a current-support matrix: cart, maturity, RAM/XIP, default or fallback ROM, ROM sources and formats, known limits, hardware-verified status. Fix the specific stale claims: Genesis described as M0 scaffold (it is M4), "emulator carts do not embed their ROMs" (they embed fallbacks), emulator carts use RAM (Genesis is XIP-only), Bugs attract mode (not implemented, SPEC M6), the six-binary list in `docs/RUNNING.md`. Also the branch drift now on main: Lynx README "Planned"/M2 status, Flyover RUNNING 60 fps line, Reflections RUNNING M3 intro. Milestone history moves to each cart's PLAN.md. Source the matrix from the current build registration in the root `build.zig`, by hand; do not add build-time generation. |
| D5 | DOC-04 | root `README.md`, `docs/RUNNING.md`, `badge-manager/README.md` | One copy-paste quick start from a fresh supported OS to a freely licensed playable cart: pinned Zig version with a real install command and version check, Python venv and Pillow install, submodule init, serve, rebuild, and recovery for missing watcher/wasm. Three short entry paths at the top of the README: play a prebuilt cart, try a cart in the simulator, develop a cart; station setup linked separately. Remove the `-b monorepo` clone recipes and say which steps depend on the team VM. The `badge-manager/README.md` `<raw setup.sh url>` placeholder belongs to Workstream B; leave it. |

**Acceptance.** A fresh-clone walkthrough transcript following only D5, ending in a running simulator cart. Menu screenshots for D1 on all four emulator carts. All links in the touched docs resolve (`grep -o '\](\([^)]*\.md[^)]*\))'` over the files and check each path exists).

**Done 2026-10-02** (branch `docs/m1`, tag `review-2026-10-01/D`; sub-branches `docs/d1-hints`, `docs/d2-games`, `docs/d345-docs`):

- D1: `lib/hint.zig` is the shared helper (strings of at most 18 glyphs, an `Overlay` timer dismissed by any fresh press, drawing through the cart-api type like `iris_mark.zig`; 5 host tests in `lib/tests.zig`). Boy, Gear, Genesis and Lynx draw "Hold Select: menu" on the splash and for the first 3 s of play (90 updates on Genesis; Lynx puts it on the strip's last line so no picture is hidden), a "B: back to game" menu footer (B or a Select tap resumes in all four), and on the Resume row "Left/Right: rewind" or "Rewind: no history" in place of the live scrub readout (no menu had room for a separate line). Boy and Gear menu rows sit 4 px higher, Genesis rows use the 8 px font pitch. No gesture or mapping changed; no goldens re-pinned (they hash core frames only). Calibrated bench worst unchanged (Boy 9.19, Gear 6.89, Lynx 10.73 RAM / 10.38 XIP ms), Genesis XIP 26.41 to 26.48 ms of 33.3. Screenshots `carts/<cart>/docs/hints_2026-10-02.png`.
- D2: a `## Controls` card at the top of Snoutenstein, Bugs and Run `docs/RUNNING.md` (badge buttons, simulator keys, pause, sound or its absence, Start+Select held 0.5 s exits per `kernel.zig`, Escape is the simulator's own menu); pause help panels in Snoutenstein and Bugs (`docs/pause_help_2026-10-02.png`); Run's README names the A button. Both check.sh green; worst frames unchanged (paused frames 4.11 to 5.03 and 7.35 to 7.92 ms, below each cart's play worst).
- D3: `docs/INSTALL.md`: the `SYCLBADGE` drive versus the RP2350 bootloader drive, file naming, several carts side by side, eject, menu launch, the exit chord, wrong-drive diagnosis; `CURRENT.UF2` auto-launch and copy timing marked to verify at show day (the kernel's single-cart auto-start is commented out, contradicting the SDK README). All 12 carts' RUNNING flash sections link it; the bootloader-mode steps in Reflections, Flyover and Zero are gone.
- D4: README support matrix (12 carts plus badge-calibrate: maturity, mode, limits, hardware status) and a ROM table from the committed build options (Boy's `-Drom` has no `~` form on main). Stale claims fixed: Genesis and Lynx "M0 scaffold", "do not embed their ROMs", Bugs attract mode, the six-binary and Boy/Maze-only test lines, Lynx README "Planned"/M2, Flyover RUNNING 60 fps, Reflections RUNNING M3 intro (the slice paragraph left to C7), Gear and Genesis READMEs at M2, Gear RUNNING "NoVolume until romfs lands".
- D5: `docs/RUNNING.md` sections 0 to 4 are one quick start: the pinned Zig from the machengine mirror (ziglang.org answers 404; the mirror was verified 2026-10-02 and the Linux tarball run, `zigup` noted as hitting the same 404), Node, venv plus Pillow, clone and submodule recovery, `zig build -Dcart=snouty-bugs`, serve, simulator, reload and watcher recovery, every command from the repository root; `-b monorepo` recipes removed everywhere, team-VM-only steps marked. Walked through in a fresh clone (UI served on 1234, cart ran under preview.mjs). 52 relative links checked, none missing.
- Gate on the merged branch (A and C1-C3 included): `zig build -Dcart-mode=both` ok; `zig build test --summary all` 26/26 steps, 9 skipped, 0 failed; `zig build check-float -Dcart-mode=both` ok; Snoutenstein and Bugs check.sh all passed.

## Not in scope now

Architecture proposals 2 and 4 from the README (shared platform adapter, authoritative cart inventory driving docs) are deliberate deferrals: no defect behind them, and the review says to do them only after the behavior tests from A and C exist. Badge-bench refinement is closed. Replay and audio are parked by prior decisions.

## Suggested parallel assignment

| Agent | Stream | Starts | Blocks on |
|---|---|---|---|
| 1 | A (gate) | now | nothing |
| 2 | B (station) | already running | nothing |
| 3 | C1-C3 (games) | now | rebase after A merges |
| 4 | C4-C8 (emulators + romfs) | now | rebase after A merges |
| 5 | D (docs + hints) | now | rebase after C7 merges before touching Reflections RUNNING |

## Status

| Stream | State | Tag / commit |
|---|---|---|
| A | **done 2026-10-02** | tag `review-2026-10-01/A` |
| B | in progress (other agent) | |
| C | C1-C3 done on `cgames/m1` (unmerged); C4-C8 other agent | |
| D | **done 2026-10-02** | tag `review-2026-10-01/D` |
