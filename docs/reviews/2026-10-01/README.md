# SYCL badge cart review for consensus

This review covers cart architecture, correctness, code quality, documentation and first-use UX, including the shared build/runtime tools and badge-manager deployment path. It records **25 findings and decision points** for discussion. Implementation changes, merges and deployment remain unapproved and were not performed.

The core architecture is worth preserving: deterministic host-testable emulator/simulation code, bounded memory, explicit hardware budgets, useful replay/debug exports and visual regression tooling. The main gaps are at boundaries: input between screens, malformed file metadata, replay patch composition, long-running coordinates, test reporting and the path from documentation to a physical badge. A new user can reach a working simulator using the updated root instructions, but hidden controls, conflicting installation recipes and misleading station success states prevent calling onboarding dependable yet.

The most urgent proposed work is to protect destructive station actions and make real versus demo operation explicit; fix Flyover's repeatable overflow before distributing that branch; then address cart correctness and restore trustworthy verification. Broad refactoring should follow those targeted corrections, after we agree on the shared behavior.

Implementation is planned in [WORKSTREAMS.md](WORKSTREAMS.md), which also corrects the baseline against `origin/main`.

Review date: 2026-10-01. Priorities are recommendations: **P1** before broad distribution of the affected feature, **P2** important correctness/reliability/usability work, **P3** lower urgency or a policy choice. A priority is not an implementation authorization. Reproduced, source-confirmed and design findings are distinguished in the detailed notes.

## Findings in priority order

| Priority | Finding | Scope | Effect and proposed direction |
|---|---|---|---|
| P1 | [INF02 Device identity](infrastructure.md#inf02-require-badge-identity-before-a-destructive-deployment) | Main manager | A volume label alone selects a device for whole-drive wiping. Validate real badge identity and geometry together. Mock reproduction; no real device touched. |
| P1 | [INF03 Browser mutation boundary](infrastructure.md#inf03-reject-foreign-browser-origins-on-mutation-routes) | Main manager | Foreign-origin text/plain wipe requests are accepted. Define and enforce the browser request boundary. HTTP acceptance reproduced; browser delivery not tested. |
| P1 | [UX-01 Set deployment](docs-ux.md#ux-01-p1-set-deploy-wipes-immediately-with-neither-warning-nor-confirmation) | Main manager | Plain “Deploy” immediately erases existing files, unlike the guarded selection flow. Expose replace-all semantics and use a consistent deliberate action. |
| P1 | [UX-02 Production demo fallback](docs-ux.md#ux-02-p1-a-production-initialization-error-turns-the-station-into-an-apparently-working-demo) | Main manager | A startup failure silently switches to simulated success. Require explicit demo mode or show a persistent unavailable state. Parent also reproduced fallback with a mocked initialization error. |
| P1 | [G2 Flyover coordinate overflow](games.md#g2-p1-before-shipping-flyover-signed-q16-forward-position-wraps-and-invalidates-the-world-branch-only-reproduced) | Flyover branch only | Ordinary extended flight or 128 skips wraps position and stops correct terrain generation. Rebase all related state or use a suitable coordinate representation. Reproduced. |
| P2 | [G1 Rewind takeover](games.md#g1-p2-snoutenstein-takeover-during-an-attract-demo-rewind-corrupts-the-recorded-rewind-count-main-reproduced) | Main Snoutenstein | Taking over a demo during rewind counts it twice and produces replay metadata desynchronization. Make patch composition idempotent; add this transition regression. Reproduced independently twice. |
| P2 | [EM-02 External serial clock](emulators.md#em-02-p2-high-confidence-main-boy-incorrectly-completes-external-clock-serial-transfers-already-fixed-on-later-branches) | Main Boy | A transfer awaiting a link peer completes without a clock. Existing fix `15709ae` and its tests are on a later branch; integrate that targeted fix after agreement. Regression reproduced against main. |
| P2 | [EM-01 Splash input leakage](emulators.md#em-01-p2-high-confidence-boys-splash-skip-press-also-chooses-a-rom) | Main Boy | A/B used to dismiss the splash also selects the first ROM/fallback. Apply input suppression to picker transitions. Source-confirmed; drive picking is not exercised by normal wasm. |
| P2 | [INF01 ROMFS physical bounds](infrastructure.md#inf01-reject-drive-geometry-outside-the-physical-volume) | Shared emulator loader | Corrupt volume geometry produces pointers beyond the physical drive region. Check backing bounds before directory/data access. Reproduced without dereferencing the invalid pointer. |
| P2 | [EM-03 ROM header overflow](emulators.md#em-03-p2-high-confidence-malformed-genesis-rom-length-can-abort-rom-scanning) | Main and branch Genesis | A declared range ending at `0xFFFFFFFF` overflows validation. Use checked/wider arithmetic and stable refusal. ReleaseSafe abort reproduced; fast-build behavior is not established. |
| P2 | [G3 Frozen render deadline](games.md#g3-p2-reflections-m4-frozen-tracing-budget-exceeds-the-supported-half30-frame-budget-branch-only-static-confirmed) | Reflections M4 branch | The supported 30fps variant spends at least 36ms tracing before display overhead. Derive budget from frame period or explicitly change frozen pacing. Static; no hardware timing rerun. |
| P2 | [INF04 UF2 validation](infrastructure.md#inf04-align-uf2-acceptance-with-the-loader) | Manager and shared tooling | A malformed cart passes preflight and can replace working contents before the badge rejects it. Share a validator aligned with the supported loader. Invalid payload acceptance reproduced. |
| P2 | [G4 Missing root tests](games.md#g4-p2-root-test-gate-excludes-snoutensteins-host-suite-main-static-confirmed) | Main build | Documented root test command excludes existing Snoutenstein host tests. Register that suite and name the separate integration gate. |
| P2 | [G5 Failing root assertion](games.md#g5-p2-demosnout-has-a-failing-host-assertion-that-breaks-the-root-test-gate-main-root-reviewer-reproduced) | Main Demosnout | An irrelevant transition tie choice fails the aggregate gate. Assert visible hold behavior; no rendering change is justified by this failure. Fresh-cache failure reproduced. |
| P2 | [EM-04 Misreported oracle coverage](emulators.md#em-04-p2-test-quality-finding-high-confidence-unavailable-gear-oracle-suites-count-as-passing-tests) | Gear and shared Z80 validation | Missing fixtures return successfully and count as passes. Report real skips and provide a strict conformance gate with explicit case counts. Reproduced. |
| P2 | [INF05 XIP float checks](infrastructure.md#inf05-check-the-actual-xip-artifact-for-soft-float) | Reflections, Maze, Demosnout builds | XIP checks request the RAM ELF, failing clean or checking a stale file. Check each selected artifact. Reflections XIP reproduction fails as predicted. |
| P2 | [DOC-01 Installation instructions](docs-ux.md#doc-01-p2-cart-installation-instructions-disagree-about-the-required-drive-and-launch-workflow) | Main Reflections and branch Flyover | Guides confuse the OS cart drive with the chip bootloader and disagree on naming/launch. Establish one firmware-specific copy/eject/launch recipe. |
| P2 | [UX-05 Menu discoverability](docs-ux.md#ux-05-p2-emulator-menu-and-time-scrubber-are-hidden-from-a-person-handed-the-badge) | Emulator frontends | Long-hold Select and menu scrub actions are absent from on-device hints. Add a small shared help pattern; do not change gestures without a separate decision. Menu function validated in wasm. |
| P2 | [DOC-03 Gameplay onboarding](docs-ux.md#doc-03-p2-snoutensteins-promised-running-guide-omits-the-gameplay-controls-a-novice-needs) | Main Snoutenstein and native carts | The promised running guide maps keys to buttons but leaves essential gameplay actions in the design spec. Provide a short controls card and pause help. |
| P2 | [DOC-02 Current support catalog](docs-ux.md#doc-02-p2-the-primary-catalog-contradicts-actual-supported-behavior-and-mature-per-cart-docs) | Main and branch docs | Milestone-era claims disagree with implemented Genesis, ROM fallback and Bugs behavior. Separate current capabilities from history and unmerged plans. |
| P2 | [UX-03 Focus and status updates](docs-ux.md#ux-03-p2-ui-refresh-and-set-expansion-destroy-keyboard-focus-updates-are-not-announced) | Main manager UI | Rebuilding controls discards keyboard focus; dynamic results lack announcements. Preserve focused nodes and announce meaningful status/errors. Source-confirmed; assistive technology not tested. |
| P2 | [UX-04 Set name collisions](docs-ux.md#ux-04-p2-save-as-set-silently-replaces-an-existing-set-including-slug-collisions) | Main manager | “Name for the new set” can silently overwrite an existing slug. Distinguish create from replace or generate a unique key. |
| P3 | [G6 Boss health bar](games.md#g6-p3-bugs-boss-health-display-and-actual-maximum-diverge-in-long-games-main-static-confirmed) | Main Bugs | From stage 11, capped boss HP and uncapped display maximum disagree. Use one maximum or deliberately widen health. Static arithmetic; no full 11-stage playthrough. |
| P3 | [EM-05 Lynx trailing data](emulators.md#em-05-p3-high-confidence-lynx-headered-oversized-files-are-silently-truncated-instead-of-refused) | Lynx branch only | Oversized headered files are clipped while oversized raw files are refused. Decide the permitted padding rule and test it explicitly. Acceptance reproduced; not a demonstrated crash. |
| P3 | [DOC-04 Reproducible setup](docs-ux.md#doc-04-p3-new-user-setup-remains-a-developer-handoff-rather-than-a-reproducible-quick-start) | Shared and station docs | Historical VM recipes, a setup URL placeholder and incomplete tool-install guidance impede independent setup. Publish one tested path per audience. External URL availability was not verified. |

Detailed notes contain file/line references, triggers, impact, confidence, proposed fixes and acceptance checks: [shared infrastructure](infrastructure.md), [native games and demos](games.md), [emulators](emulators.md), and [documentation and UX](docs-ux.md). The 25 entries include UX/contract decisions; they are not 25 independently proven runtime crashes.

## Validation and practical limits

| Check | Result |
|---|---|
| Main full build | 152/152 build steps passed; artifacts isolated under `/tmp/sycl-review-build`. |
| Main root tests with a fresh local cache | **461/462 reported passed**, one Demosnout assertion failed. Optional external oracle early returns overstate coverage; Snoutenstein is absent from this graph. |
| Main default soft-float checks | 156/156 steps passed; three configured RAM ELF checks passed. |
| XIP-only Reflections float check | Failed because the check requested the absent RAM ELF. |
| Badge-manager tests | **137 passed**. Initial sandbox socket failures were environmental; the elevated rerun passed. |
| Separate Snoutenstein host tests | 65 passed; targeted takeover probe still reproduces the uncovered desynchronization. |
| Maze host tests and Bugs integration | 39 Maze tests and 14 Bugs scripts passed. Maze is also included in the root total. |
| Demosnout integration | 263 timeline/order checks and 11 frame goldens passed across 6900 updates. |
| Genesis newer branch | 168 host tests passed; available CPU oracle subsets include intentional exclusions and documented disputed cases. |
| Lynx newer branch | 108 host tests passed; 240000 CPU oracle cases from 24 files passed, a subset of possible fixtures. |
| Reflections M4 | Fresh build and six accumulator seed-preservation views passed; no new hardware performance measurement. |
| Emulator menu previews | Boy, Gear and Genesis entered their menus after a Select hold; screenshots inspected. |

See [validation commands, logs, screenshots and probes](validation.md). Totals overlap and should not be summed. Deterministic golden/replay success establishes consistency, not full console fidelity. CPU/video/audio correctness was reviewed through selected code paths and available fixtures, not exhaustive ISA or title compatibility testing.

No physical badge, Pi, phone or screen reader was tested. No real deploy/wipe, firmware flash, network reconfiguration or AI build job was performed. USB timing, flash-backed execution, XIP cache behavior, physical readability, sound quality and sustained hardware frame time remain unverified. No new external fixture downloads were required. The art pipeline and benchmark model received contextual inspection, not an exhaustive separate audit.

## Architecture and design proposals

1. **Keep simulation and console cores independent of badge APIs.** In-place large-state initialization, bounded histories and allocation-free hot paths suit the device. The shared Z80 core, deterministic snapshots and Lynx's explicit classification of saved fields are good models. Preserve console-specific render/CPU paths rather than forcing them into one generic emulator engine.

2. **Extract the small platform boundary after behavior tests exist.** Repeated wasm framebuffer/input shims and frontend edge suppression have already drifted. A minimal adapter for input edges, suppression and simulator presentation could remove that risk. Native carts have different frame rates, so time units and pacing must stay explicit. Existing guidance intentionally keeps asset-converter copies per cart; changing that convention needs its own agreement.

3. **Give file-format boundaries one tested contract.** The duplicate UF2 validators demonstrably disagree with the loader. Share structural validation and keep accepted firmware/format versions explicit. Give ROMFS a backing extent and make malformed-input refusal part of the API. This proposal is about rejecting invalid input reliably, not guaranteeing arbitrary imported machine code is safe.

4. **Treat the cart catalog as maintained product metadata.** Root registration, aliases, flags, manifest entries and READMEs duplicate names and capability claims. A small authoritative inventory could drive current-support documentation and artifact checks: maturity, output names, RAM/XIP modes, default ROM, source/formats, controls and hardware verification status. Keep historical milestone prose in PLAN files.

5. **Separate fast verification from release evidence.** Reuse existing host suites, integration scripts and visual goldens behind clear commands. Report actual fixture availability; make strict conformance opt-in locally and required for any release claim that relies on it. Add transition and long-session boundary cases, especially input suppression, rewind patch composition and coordinate rollover. Avoid copying tests that merely mirror implementation.

6. **Make production failure states explicit.** The manager should distinguish a real badge, an explicit fake fixture and an explicit demo. Whole-drive replacement can remain the deployment model, but device identity, erase consequences and failures must be visible and consistent. Keep advanced CRC/timing diagnostics available without making them the first thing an attendee must understand.

These are scoped proposals. A large framework rewrite, UI framework migration, new login system or redesign of all controls is not implied by this review.

## Proposed first use experience

Documentation should offer three short entry paths: **play a prebuilt cart**, **try a cart in the simulator**, and **develop a cart**. Station administration and optional build-host setup should be linked separately. Lead each path with the expected result, prerequisites and exact working directory; put performance/replay engineering reference afterward.

A new badge holder should be able to identify the current cart, discover primary actions, find pause/menu, toggle sound, understand rewind/resume and return to the OS. For emulator carts, agree on a short “Hold Select: menu” hint and a contextual scrub/back hint. Genesis's actionable missing-ROM screen and Demosnout's picker/hold feedback are useful patterns to reuse.

Proposed acceptance walkthroughs after changes are agreed:

| Audience | Task | Evidence to collect |
|---|---|---|
| Fresh developer | Clone on a supported OS, verify tool version, build a default freely licensed cart, serve it, rebuild and see the update | Copy/paste transcript from a fresh environment, including missing dependency/watcher recovery |
| New badge holder | Start, pause/menu, enable/mute sound, rewind/resume and exit without opening SPEC.md | Observe an unfamiliar user and record where hints or labels are needed |
| Person adding ROMs | Distinguish simulator embedding from badge drive loading; recover from unsupported or malformed input | Visible refusal/fallback reason and valid ROM still selectable |
| Physical badge owner | Recognize the normal cart drive, copy multiple named carts, eject and launch | Record the supported OS revision and verified install sequence |
| Station operator | Deliberately replace a set; avoid wrong-device selection; diagnose real-station startup failure | Fake-device regression tests first, then one real station check |
| Keyboard or screen-reader user | Expand a set, select carts, change mode, confirm an action while status updates arrive | Focus remains usable and action/error feedback is announced |

These are proposed follow-up checks, not completed usability studies. No claim is made that the current experience meets a measured accessibility standard.

## Baseline and coverage

Review baseline is main `79b7e896140c646c3c162103a4e9c723a629a3c1` **plus existing local edits**, with substantive newer worktree changes reviewed separately. The optional scope question was unanswered; main plus newer worktrees was the stated default. Do not treat their combined capabilities as an already integrated release.

| Area | Baseline and coverage |
|---|---|
| Main user carts | Run, Bugs, Snoutenstein, Reflections, Boy, Maze, Gear, Genesis and Demosnout: code, controls, docs and relevant tests |
| Shared support | Root build/XIP, ROMFS, simulator tooling, relevant SDK contracts, calibration context and selected manager deployment/build paths |
| Gear | `ae16621`; cart subtree matches main |
| Genesis | `53e1369`; later undo, streaming/cache, frontend and tests |
| Lynx | `54f2cf1`; implemented cart is branch-only, main has plans |
| Flyover | `496aba0`; implemented cart is branch-only, main has a spec |
| Reflections | `0d8d70d`; M4 progressive frozen tracer reviewed separately |
| Hardware trace | `b6895e5`; unique optional tracing delta inspected |
| Snoutenstein, Scene, Simtone | `292911b`, `9a4b581`, `f53d696`; relevant work already incorporated into main |
| Manager worktree | `79b7e89`, same commit as main |
| NES | Notes-only on main; not evaluated as an implemented cart |
| Concurrent Zero work | A new `zero/spec` worktree appeared during review; its ongoing spec work is outside the frozen baseline |

Main already had edits to README, calibration README, Boy guidance/build/RUNNING, and the SDK gitlink. They were preserved. The SDK checkout was clean at `4ccc4c4cf4e518da1216f4ebd74b298fc2d14fb2`, while main records `a6ce19f0c9e07ff3d0c50f91867515b397b33db2`. That local difference includes an OS cycle-counter startup fix; building a cart does not flash that OS change. The revision/status snapshot is in [evidence](evidence/sycl-review-revisions.json). Pre-existing test-fixture and venv symlinks in feature worktrees were not created or removed by the reviewers. Standalone older repositories beside this monorepo were not treated as additional current implementations.

Three subagents reviewed emulator code, native games/demos, and documentation/UX. The parent reviewed shared infrastructure, ran the aggregate build/tests, independently reproduced selected findings, and consolidated this record. Only review documentation/evidence was added to the repository; builds produced ordinary ignored artifacts and temporary probes.

## Decisions to reach before implementation

| Decision | Recommended agreement | Status |
|---|---|---|
| Release baseline | Select branch features deliberately; bring the existing Boy serial fix and tests forward without assuming a wholesale branch merge | Proposed |
| Deployment contract | Retain whole-set replacement with verified target identity, clear erase semantics, explicit demo mode and a defined browser mutation boundary | Proposed |
| Verification contract | Repair the Demosnout assertion, include existing Snoutenstein tests, report honest oracle skips and validate the selected RAM/XIP artifacts | Proposed |
| First-use controls | Keep console-specific mappings; standardize menu/help discovery and agree picker cancel/resume semantics | Proposed |
| Documentation ownership | One canonical installation guide and current capability inventory, with links from each cart | Proposed |
| Refactoring scope | Fix confirmed defects first; then consider the small platform adapter and shared validators, with no broad rewrite | Proposed |

Suggested implementation order, once agreed: deployment integrity and reliable gates; main cart correctness; branch-specific release blockers; onboarding/docs/accessibility; then narrowly justified reuse. The report and evidence provide the discussion baseline; no fixes have been applied.
