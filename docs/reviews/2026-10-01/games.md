# Native games and visual carts review 2026-10-01

Review-only notes for consensus. No implementation or git edits made by this reviewer. Builds and tests produced ignored output; findings below are proposals, not approved changes.

## Scope and versions

Main `/home/exedev/snouty-badge`, HEAD `79b7e89`: reviewed entry/state/input code for snouty-run, snouty-bugs, snoutenstein, snouty-maze, snouty-reflections and demosnout; examined rewind/simulation architecture, render interfaces and selected hot paths, build/test wiring, cart-specific guidance and user controls. Main snouty-flyover is SPEC-only; snouty-nes is NOTES-only and neither has executable implementation to review there.

Branch-only implementation reviewed separately:

- `/home/exedev/snouty-badge-flyover`, `flyover/m0-plan` / `496aba0`: complete Flyover M4, including camera, ring terrain generation, skip handling and renderer interfaces.
- `/home/exedev/snouty-badge-reflections`, `reflections/m4` / `0d8d70d`: progressive frozen path tracer, shared arena and state changes. This worktree also includes flyover via merges; do not count it as a second independent implementation.
- `reflections/hw-trace` / `b6895e5`: unmerged delta is opt-in render timing trace plus artifact. Older branch tree is not evidence of main deletions; inspected its unique three-file delta.
- `snoutenstein-m6`, `scene/demosnout`, `sim-tone`: no unique commits beyond main at review time; reviewed their incorporated native code on main instead of treating older trees as competing current versions.

## Findings requiring decisions

### G1 P2 Snoutenstein takeover during an attract-demo rewind corrupts the recorded rewind count main reproduced

Evidence:

- `carts/snoutenstein/cart/src/main.zig:284-286`: `take_over()` first calls `end_rewind()` and then `rewind.set_meter()`.
- `carts/snoutenstein/cart/src/rewind.zig:245-256`: `commit()` writes a patch with `count_rewind` and applies it to the live state.
- `carts/snoutenstein/cart/src/rewind.zig:268-274`: `set_meter()` preserves that patch's `count_rewind` flag and applies the patch to the already-patched live state again.
- `carts/snoutenstein/cart/src/rewind.zig:134-138`: applying a patch increments rather than assigns `s.rewinds`.

Trigger: let the title start its recorded attract demo, then press Up during the demo's hold-B rewind (update 1900 is a deterministic instance). The completed rewind is counted twice in the live state, but replay applies its patch once. This breaks the deterministic history contract and increments `debug_desync`; later rewinds across that point may show a different rewind count. This reproduction establishes metadata divergence, not positional/HP corruption.

Validation on the root review's freshly built main wasm:

```sh
node tools/preview.mjs /tmp/sycl-review-build/bin/snoutenstein.wasm \
  --frames 1960 --quiet --press UP:1900-1900 \
  --out /tmp/sycl-snoutenstein-takeover \
  --at '1899 debug_mode == 6' --at '1899 debug_rewinds == 0' \
  --at '1900 debug_rewinds == 1' --expect 'debug_desync == 0' \
  --dump-exports debug_mode,debug_rewinds,debug_desync,debug_demo
```

Observed: rewind mode and zero count before takeover; count **2** at takeover rather than 1; final `debug_desync=1`, `debug_demo=0`. Exit 3. Metadata: `/tmp/sycl-snoutenstein-takeover/frames.json`.

Fix direction: make rewind patches idempotent (absolute count) or have set_meter update only the live meter while retaining the existing replay patch. Add a takeover-during-rewind regression and repeated patch-at-same-tick coverage. Confidence: high.

### G2 P1 before shipping Flyover signed Q16 forward position wraps and invalidates the world branch-only reproduced

Evidence in `/home/exedev/snouty-badge-flyover`:

- `carts/snouty-flyover/cart/src/camera.zig:76`: forward position `y` is an i32 Q16 value, maximum positive whole row 32767.
- `camera.zig:268`: forward flight continually adds speed with no rebase or wrap handling.
- `camera.zig:229`: Select skip sets `cam.y = row << fixed.Q`, silently discarding high coordinate bits.
- `carts/snouty-flyover/cart/src/world.zig:163-169`: row generation only advances toward larger row values, retaining the previous positive generation head when camera becomes negative.

Trigger: unattended flight eventually reaches row32768 (about 24–26 minutes at cruise30fps, roughly10 minutes boosted), or 128 Select skips. Position becomes negative. The ring's generation head remains in the former positive region, so it stops producing terrain for the camera and terrain probes report absent rows. This is incompatible with a looping unattended demo. ReleaseFast arithmetic also lacks a safe overflow contract.

Reproduction after an up-to-date `zig build -Dcart=snouty-flyover`: generate 130 one-frame Select presses at updates `5*i`, i=0..129; run660 updates. Script `/tmp/sycl-flyover-overflow.json`, output `/tmp/sycl-flyover-overflow/frames.json`.

```sh
node tools/preview.mjs zig-out/bin/snouty-flyover.wasm --frames 660 --quiet \
  --script /tmp/sycl-flyover-overflow.json --out /tmp/sycl-flyover-overflow \
  --at '634 debug_cam_y > 0' --at '639 debug_cam_y > 0' \
  --dump-exports debug_cam_y,debug_skips,debug_world_check
```

Observed row32513 at634, **-32767** at639; final `debug_skips=130`, `debug_cam_y=-32247`, `debug_world_check=256000049` (256 missing rows plus content differences). Exit3.

Fix direction: separate integral world row from fractional motion, use wider coordinates where appropriate, or explicitly rebase all camera/world/segment/district bookkeeping together. Merely changing `+=` to wrapping `+%=` does not fix the ring invariant. Add a crossing test and repeated-skip soak. Confidence: high. P1 is a proposed pre-release priority because ordinary unattended use reliably breaks; main currently does not ship this cart.

### G3 P2 Reflections M4 frozen tracing budget exceeds the supported half30 frame budget branch-only static-confirmed

Evidence in `/home/exedev/snouty-badge-reflections`:

- `carts/snouty-reflections/cart/src/variant.zig:68`: `half30` has fps30.
- `cart/src/main.zig:28`: startup retains the variant's vsync rate.
- `cart/src/pt.zig:41-43`: fixed slice36000us explicitly assumes a50ms frame.
- `pt.zig:126-132`: hardware tracing runs columns until this deadline; `main.zig` then calls full-frame display/dithering.

Trigger: build supported `-Dreflections_variant=half30`, freeze with A. Ordinary not-yet-converged path tracer updates intentionally run until at least36ms after update start, already beyond the33.3ms requested period before display/last-column overhead. Simulator takes a fixed number of columns instead of timing, so its functional tests cannot detect the hardware pacing error. Final convergence frame can return early; this does not remove the ordinary overrun.

Fix direction: derive slice from variant frame period with measured display/overshoot headroom, or explicitly switch frozen mode to20fps and document/restore pacing. Add frozen timing coverage for every advertised variant, not just shipped cut20. Confidence: high static reasoning; no fresh hardware timing run. Existing M4 plan records cut20 timing gates only.

### G4 P2 Root test gate excludes Snoutensteins host suite main static-confirmed

`carts/snoutenstein/build.zig:13-30` only installs the cart; it never registers host tests on `opts.test_step`. The file has no test registration elsewhere. Yet `carts/snoutenstein/tools/check.sh:20-24` explicitly runs sim/levels/parser/rewind/demo Zig tests and README advertises `zig build test` as every cart's host tests.

Impact: contributors can run the documented root verification and miss the FPS simulation/rewind suite entirely, including changes to complex deterministic replay code. This is particularly material for G1. Bugs' own14 headless regression scripts are also a separate command rather than part of a unified root gate; not every cart has meaningful host tests, so absence alone should not imply tests need to be invented.

Fix direction: wire existing pure Snoutenstein tests into the root test graph, and provide/document a separate comprehensive cart integration gate. Keep generated-source freshness checks read-only. Confidence: high.

### G5 P2 Demosnout has a failing host assertion that breaks the root test gate main; root reviewer reproduced

`carts/demosnout/cart/src/timeline.zig:328` expects held Plasma's veil to have cut `.seamless`, but `veil():107-111` chooses the incoming cut on a visibility tie (`vin <= vout`). At the tested frame800, both visibility values are256 and incoming cut is `.fade`.

This is an over-specific/stale assertion, **not evidence that hold fades out**: line327's visibility256 assertion passes, `render():201` treats `.fade` and `.seamless` identically, and `fx.zig:47` makes fade level16 a no-op. Root review log `/tmp/sycl-review-host-tests.log` records the failure. Independent headless Demosnout verification passes263 timeline/order checks and all11 frame goldens over6900 updates.

Fix direction: assert the user-visible invariant (full visibility with no auto-advance) rather than a tied internal cut, or deliberately define/test a canonical cut on ties if consumers need one. Do not change rendering just to satisfy this internal expectation. Confidence: high.

### G6 P3 Bugs boss health display and actual maximum diverge in long games main static-confirmed

`carts/snouty-bugs/cart/src/enemies.zig:220` caps stored boss HP at255 (`Enemy.hp` is u8), while `boss_max_hp():225-226` continues returning `60 + 20*loop`; `hud.zig:94-95` uses the uncapped value as the bar denominator. Starting at loop10 (stage11), a newly spawned boss already shows less than a full bar; the bar shrinks further in later stages while actual health remains255.

Fix direction: choose either a capped boss maximum used consistently by spawn/HUD or widen HP if unbounded stage difficulty is intended. Confidence: high static arithmetic; no full eleven-stage gameplay run. Lower priority than the ordinary-session defects above.

## Architecture and design assessment and strengths

- Fixed memory pools, no per-frame allocation, platform-independent simulation state and named budgets are well matched to this badge. Snoutenstein's replay keyframes, bounded input ring and span cache explicitly document tick semantics. Its65 transitive rewind/simulation tests pass, although they miss takeover patch composition.
- Bugs deliberately separates meta resources (rewind stock/fuel/high-water awards) from rewound World state. This is the right distinction and the14-script regression gate exercises rewind identities, repeated graze awards, hardcore exhaustion and boss transitions; all pass.
- Maze's generation, clipping, camera and autopilot invariants are meaningfully tested (39 tests pass). Rendering keeps clipping and simulation separate; comments capture platform-specific vector-layout hazards, a valuable engineering constraint.
- Demosnout uses a clear part interface and data-driven timeline with deterministic part resets and golden frames. A stock114s loop passes its integration gate. Table metadata appears three times (entries/bars/cuts/holds), but compile-time cross-checks prevent silent drift; this is a maintenance cost, not currently a defect.
- Reflections M4 explicitly multiplexes its large arena between realtime and path tracing, invalidating realtime tables on release. Six seed-preservation checks pass: the accumulator exactly reproduces realtime pixels and untouched columns remain unchanged after partial work. Dedicated double-precision reference/convergence tooling is a strength.
- Flyover's pure row generation and `generated_row` invariant checks give a good foundation for property/soak tests. The current golden gate checks only2400 updates, far below forward-coordinate exhaustion; G2 is an example of testing an ordinary session boundary in addition to one visual cycle.
- Repeated per-cart wasm input/framebuffer shims and copied converters increase maintenance surface. Guidance explicitly requests per-cart converter copies, so do not automatically deduplicate all of them. A future shared shim boundary could be proposed separately, with both wasm and hardware validation.
- Native carts use different meaningful timing models (60fps games, variable-rate Reflections,30fps Flyover). Shared helpers should retain explicit tick units rather than assume all carts are60fps.

## On-device UX observations coordinate with docs and UX review

- Bugs title labels only `A PLAY` and `B HARDCORE`; pause only `PAUSED` (`hud.zig:130-155`). New users are not taught A-fire, B-rewind, Start-pause on-device. Docs explain them, but a badge handed to another attendee lacks that context. Consider a brief controls page or pause legend. This is a design recommendation, not a proven input bug.
- Root README describes Bugs attract mode despite main's title state only scrolling background until input (`main.zig:96-106`). SPEC reserves demo forM6 and sound forM7; current implementation isM5. Correct status presentation rather than treating roadmap features as regressions.
- Snoutenstein has a proper title/demo takeover flow and death-rewind affordance. G1 affects a particularly discoverable interaction, touching the badge while its demo rewinds.
- Demosnout picker exposes parts and durations, wraps selection, and provides a close hint; hold toast gives immediate feedback. Stock build maps B to hold while debug build maps B to overlay; docs should identify that difference.
- Run is intentionally a very simple animation with one A-jump interaction, but name/company are hardcoded in main.zig:22-23. Decide whether this is a personal cart or a reusable badge-name product before adding configuration.
- Several native carts do not suppress their own actions while Start+Select is held (unlike Demosnout); the hardware OS owns that chord. I did not verify OS event ordering, so this is a consistency question, not a confirmed user-visible issue.

## Validation actually performed

- Main `zig test carts/snoutenstein/cart/src/rewind.zig` from its cart directory: **65/65 passed** (includes transitive simulation, AI, projectiles and parser freshness).
- Main `zig test cart/src/host_tests.zig` from Maze directory: **39/39 passed**.
- Main freshly built Bugs + `bash carts/snouty-bugs/tools/check.sh --no-build`: **14/14 scripts passed**.
- Main freshly built Demosnout + `node carts/demosnout/tools/check_timeline.mjs`: **263 ordering checks +11 frame goldens passed**,6900 updates.
- Snoutenstein targeted takeover scenario on `/tmp/sycl-review-build/bin/snoutenstein.wasm`: **fails rewind-count and desync assertions**, as G1.
- Flyover branch fresh build succeeds; repeated-skip repro **fails positive-coordinate/world-ring invariant**, as G2.
- Reflections M4 branch fresh build succeeds; `node carts/snouty-reflections/tools/check_pt.mjs --wasm zig-out/bin/snouty-reflections.wasm --checks 3 --out /tmp/sycl-reflections-pt-seed`: **6/6 views pass**, zero seed-pixel differences,36 traced/124 untouched columns.
- Root reviewer ran full build/float/test gates separately. Root test failure classified as G5. Do not collapse all validation into "tests pass".

## Limitations and consensus questions

This was risk-directed review, not an exhaustive proof of every renderer/AI line. No physical badge, subjective audio evaluation or calibrated per-cart performance rerun. Did not rerun costly full path-tracer reference/convergence suite or compare all old worktree artifacts with current main. Pure tests and wasm do not prove hardware layout, LCD contention or input ergonomics. No live browser interaction was performed by this reviewer; docs/UX agent owns visual onboarding review. NES remains a design note, so no core correctness claim is possible.

Suggested consensus: fix G1 and restore reliable root test coverage first; treat G2 as a Flyover release gate; settle variant pacing policy for G3 before publishing M4 alternatives. G5 should be corrected as test intent, without an unnecessary render behavior change. Decide separately how much on-device instruction each visual/game cart should carry. Changes remain unimplemented.
