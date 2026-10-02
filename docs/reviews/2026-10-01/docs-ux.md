# SYCL badge docs and novice UX review

Review date: 2026-10-01. Findings only; no implementation or existing documentation edited. Suggested priorities: P1 = address before unattended/new-user deployment; P2 = important usability or onboarding correction; P3 = polish/maintenance. Product choices below are proposals for agreement, not approved changes.

## Scope and validation

Primary baseline is `/home/exedev/snouty-badge`, main `79b7e89`, including the existing dirty README and Snouty Boy RUNNING changes. The SDK checkout is clean at 4ccc4c4 but differs from the recorded a6ce19f gitlink; SDK observations describe that installed checkout and should be rechecked against the ultimately selected pin. Read root CLAUDE.md and root README/RUNNING/SOUND, each implemented cart's README/RUNNING where present, relevant menu/input/splash/picker/HUD code, badge-manager onboarding/setup/config/server/library/UI code, and upstream simulator keyboard/menu code. Also inspected newer Lynx (`54f2cf1`), Flyover (`496aba0`), Reflections (`0d8d70d`) worktrees' user docs and frontend code; checked branch doc differences for Gear, Genesis, Demosnout and Snoutenstein. These branches are not all descendants with identical unrelated content: findings on newer worktrees are explicitly labeled.

Ran the real shared headless preview on freshly built main artifacts in `/tmp/sycl-review-build/bin` for Boy, Gear and Genesis. All three reached `debug_state == 2` after Select held at updates 100–133; inspected rendered menu PNGs at update 130. Inspected committed Genesis missing-ROM help and picker PNGs. Evidence folders: `/tmp/sycl-review-ux-snouty-{boy,gear,genesis}` and matching `-menu` folders. Initial Boy command mistakenly requested Gear's `debug_settings` export and correctly failed with a helpful valid-export list; reran successfully with `debug_state`. No physical badge, Pi, phone, screen reader or interactive browser tested. Browser/keyboard accessibility findings are static source analysis, not measured assistive-technology results. Did not install packages or fetch external docs.

## Findings

### UX-01 P1 Set Deploy wipes immediately with neither warning nor confirmation

Evidence: `badge-manager/www/index.html:397` creates a plain “Deploy” button that immediately posts `/api/deploy`. `badge-manager/badge_manager/station.py:311` documents whole-drive replacement, and line 333 invokes `_wipe` before copying. In contrast, `www/index.html:896` handles selection deployment with a second tap and “Tap again: wipe and deploy”; Wipe itself also requires two taps at line 876. The visible set detail at line 368 says only “Writes N files”, not that it removes everything already on the badge.

Scenario: a novice expects selecting a demo set to add those carts, taps Deploy, and loses all other badge files. The only advance explanation is in the long README. This is an avoidable destructive-action inconsistency, regardless of whether whole-set replacement is the intended deployment architecture.

Proposed agreement: retain replace-all deployment if desired, but show its consequence in the set action and use the same deliberate confirmation as Deploy selection. Validation: deploy a set against a fake badge with an unrelated file and ensure no mutation occurs on first activation; ensure the consequence is announced and keyboard accessible.

### UX-02 P1 A production initialization error turns the station into an apparently working demo

Evidence: `badge-manager/badge_manager/server.py:1490` catches any real Station initialization/status exception and returns None; lines 1523–1526 instantiate DemoStation even without `--demo`. DemoStation status (`server.py:521` onward) reports a fake `/dev/sda`, real-looking library and job actions, with no explicit `demo` mode field. `www/index.html:274` renders ordinary network/build information with no demo banner. The only visible clue is the log entry emitted at `server.py:458` (“Demo station started…”), eventually evicted from the 200-line log. README acknowledges the fallback at its Demo server section; this is existing intended code, but a problematic production behavior.

Scenario: permissions, invalid manifest or another startup failure prevents real station initialization. A phone still sees a badge “plug in”, successful deployments and generated carts, while its physical badge is untouched. The original diagnostic is only in server logs and the simulated success conceals the actual outage.

Proposed agreement: make demo explicit; expose a clear unavailable/error state on production failures. If fallback is retained for development, a persistent visible mode indicator and API mode flag are necessary. Validation: cause a real-station startup error and verify the service cannot report fake deployment success.

### UX-03 P2 UI refresh and set expansion destroy keyboard focus; updates are not announced

Evidence: `badge-manager/www/index.html:343–345` empties and rebuilds Sets; lines 355–358 call that rebuild from the focused expand button's own click. Remove set similarly rebuilds immediately after arming (375–379). Library always clears/recreates inputs at 450–452. Every successful status poll calls all these renderers (`817–825`, `844–852`), including build-progress changes. No focus capture/restoration exists. Dynamic action/error/status nodes at lines 111, 117, 130, 136, 148, 157–172 have neither live regions nor alert/status roles.

Scenario: a keyboard user presses Enter to expand a set or arm Remove set; that focused element is removed, so the next Enter does not operate the replacement control. A running build can also dislodge focus from unrelated library choices. A screen-reader user must manually find updated errors and fit/deploy status.

Proposed agreement: preserve keyed nodes/focus, add concise status/error announcements, keep confirmation controls focusable across state updates. Positive baseline: 44px touch targets, named checkboxes, aria-expanded, and aria-pressed already exist. Validation should include keyboard-only expand/remove/select/mode-change while status polls occur, plus a screen-reader smoke test. No claim of full WCAG compliance or measured failure was made.

### UX-04 P2 Save as set silently replaces an existing set including slug collisions

Evidence: `badge-manager/www/index.html:909–921` asks “Name for the new set”, posts only title/carts/roms, and reports “Saved”. `badge_manager/library.py:542–560` derives `key = slug(title)` and replaces that existing table. Thus `Demo reel` overwrites the default set, and differently punctuated names can resolve to the same key. README explains replacement, but the actual user flow presents creation and gives no collision warning.

Proposed agreement: distinguish creating from replacing and require an explicit replacement choice when the derived key exists (or generate a unique key). Validation: existing-name and punctuation-collision scenarios should not silently change another set.

### DOC-01 P2 Cart installation instructions disagree about the required drive and launch workflow

Evidence: main `carts/snouty-reflections/docs/RUNNING.md:382` tells the user to enter bootloader mode, then copy a cart UF2 and select it in the badge menu. Newer Flyover worktree repeats this at `/home/exedev/snouty-badge-flyover/carts/snouty-flyover/docs/RUNNING.md:320`. In contrast, main `carts/snouty-boy/docs/RUNNING.md:381` correctly distinguishes the badge's SYCLBADGE cart drive from the RP2350 bootloader drive and says the latter is for the OS. Boy lines 387–389 also say replace CURRENT.UF2 and the cart starts automatically; Reflections line 385 says retain other carts and pick it from the menu. The installed SDK's `src/os/kernel.zig:612` explicitly selects a named file and invokes the cart loader.

Scenario: a new user follows Reflections/Flyover instructions onto the chip's firmware drive and cannot reach the advertised cart-menu behavior. Other pages leave them uncertain whether they should rename files, retain multiple carts, eject, or expect auto-launch.

Proposed agreement: one canonical install sequence tied to supported badge OS version: named normal cart drive, exact file naming, eject step, menu launch, exit chord, and recognizable wrong-drive diagnosis. Link every cart to it. Hardware verification is still required for the final launch/copy timing and CURRENT.UF2 behavior; the conflicting bootloader instructions themselves are confirmed.

### UX-05 P2 Emulator menu and time scrubber are hidden from a person handed the badge

Evidence: Boy `cart/src/frontend/input.zig:24` and corresponding Gear/Genesis input modules require Select held 30 frames to enter the menu; tap has different behavior. Boy splash `frontend/splash.zig:53–75`, Gear splash `:66–74`, Genesis splash `:61–69` draw branding without the menu hold hint. The inspected live main menus show Resume, settings and (Boy/Gear) “Scrub: live / 1.0s”, but no instruction to press Left/Right on Resume or B to return. Boy drawing is `frontend/menu.zig:248–299`; its dispatch distinguishes settings vs scrub rows at `:124–148`, `:168–181`. Newer Lynx follows the same hidden Select convention; its 26-row status strip (`frontend/strip.zig:32–50`) is devoted to technical ROM/source/debug information.

Scenario: a user taps Select, sees nothing/menu fails to open, and concludes sound, reset, scaling or rewind is unavailable. Even after discovering the menu, “Scrub” provides status but not the action or consequence of resuming from the past.

Proposed agreement: a brief skippable startup/idle hint (“Hold Select: menu”), a contextual L/R rewind hint when Resume is selected, and obvious resume/back/exit guidance. Decide whether a transient hint or a reusable Help row best fits the limited screen; retain the existing hold behavior unless a separate control-design decision changes it. Main preview validated that long-hold entry works, so this is discoverability, not a broken control handler.

### DOC-02 P2 The primary catalog contradicts actual supported behavior and mature per-cart docs

Evidence in dirty main README (preexisting edits included): line 17 describes Genesis as M0 test-pattern scaffold, while `carts/snouty-genesis/docs/RUNNING.md:7–12` describes M2 game/picker/menu and the real preview opens that menu. README line 145 says “The emulator carts do not embed their ROMs”, contradicted by the newer section at lines 95–105 and generated fallback ROM modules in Boy `build.zig:130`, Gear `build.zig:113`, Genesis `build.zig:165`. Line 143 says emulator carts use RAM while Genesis is explicitly XIP-only at line 17. Shared `docs/RUNNING.md:54–60` lists only six binaries and only Boy/Maze tests despite additional implemented carts. README line 11 advertises Bugs attract mode, but main Bugs `main.zig:94–106` only waits at title; its SPEC defers attract demo to M6 (confirmed with native-cart reviewer).

Additional branch-only drift: Lynx README lines 7–11 calls the CPU/sprite engine/scrubber “Planned” and status M2 while the same README documents the implemented scrubber and worktree HEAD is M4 perf status. Flyover RUNNING line 115 says SPEC decides 60fps despite introduction and M2 decision of 30fps. Reflections RUNNING introduction still discusses the M3 frozen real-time behavior while later M4 sections describe the implemented progressive tracer. These are documentation-state inconsistencies, not evidence missing planned code is a defect.

Proposed agreement: a concise current-support matrix (cart, maturity, RAM/XIP, default ROM, supported ROM source/formats, known limits, verified hardware/simulator) maintained beside build metadata; preserve milestone history in PLAN rather than using historical claims as current onboarding. Avoid changing unmerged branch status in main until baseline is agreed.

### DOC-03 P2 Snoutensteins promised running guide omits the gameplay controls a novice needs

Evidence: root README sends users to each cart's RUNNING for controls. `carts/snoutenstein/docs/RUNNING.md:86–96` lists keyboard-to-badge mappings but not a playable game control table; the rest is mostly tooling, replay scripts and performance. `SPEC.md:46–60` contains the actual gameplay controls, including Select next weapon, B rewind, movement and doors opened by walking into them. Its title HUD (`cart/src/render/hud.zig:129–134`) only offers PRESS A, sound and test-level options; pause (`:184–185`) displays PAUSED without help. Bugs RUNNING is better: it explains firing/movement/pause/rewind near its keyboard table; its on-device title still only teaches A PLAY / B HARDCORE (`hud.zig:133–154`). Run README says merely “jumps with button input”, though actual input is A (`main.zig:160`).

Proposed agreement: a short play-first controls card per cart, clearly separating simulator keys from badge buttons and listing pause, resume, sound and OS exit. For multi-action games, add a brief pause help overlay instead of requiring the design spec. Include controls for automatic demos so new users can discover interaction without experimentation.

### DOC-04 P3 New-user setup remains a developer handoff rather than a reproducible quick start

Evidence: root README and RUNNING reference other paths as inline code, not navigation links; root index omits badge-manager entirely. `docs/RUNNING.md:9–13` pins an exact rotating nightly but its fallbacks are names (“machengine.org mirror or zigup”) rather than complete install/check instructions. Python/Pillow prerequisites have no venv/install command. Clone-from-VM recipes use historical `-b monorepo` (`docs/RUNNING.md:29`, Snoutenstein RUNNING:20) and depend on an individual's reachable VM. Simulator Terminal 2 cwd assumptions differ among root and cart guides. `badge-manager/README.md:26` contains a literal `<raw setup.sh url>` placeholder; its documented clone install copies that clone when rerun (`setup.sh:49–53`, `:68–69`) without pulling it, despite saying rerun is how to update. Local Pi builds additionally need a full cart checkout and agent setup; `--build-tools` alone does not establish these, while example `build_repo` still points at `/home/exedev/snouty-badge` (`station.example.toml:12`).

Proposed agreement: one copy/paste path from a fresh supported OS to a freely licensed playable cart; exact working directories, tool-version checks, Python environment setup, submodule checks and recovery for missing watcher/wasm. Separate “use prebuilt carts”, “develop locally”, “station deployment”, and optional AI build-host setup. Explicitly say which details depend on the team VM and which any reader can follow. URL availability and third-party installation claims were not verified online.

## Per-cart UX coverage and strengths

| Cart / surface | Coverage and observation |
|---|---|
| Snouty Run | README, RUNNING, input; passive demo with A jump; easy once known, needs button named in short README. |
| Snouty Bugs | README/RUNNING, title/pause HUD; useful inline control prose; title teaches normal/hardcore but not core play actions; attract claim premature. |
| Snoutenstein | README/RUNNING/SPEC/title/death/pause; death rewind prompt is useful; short gameplay guide missing; title shows developer test vocabulary. Newer branch gameplay reviewed by native-cart agent. |
| Snouty Reflections | Main and newer branch RUNNING/control paths; detailed controls exist, passive visual offers little in-device discovery; bootloader instructions incorrect; M3/M4 prose stale. |
| Snouty Boy | README/RUNNING/splash/input/menu/picker and live menu preview; detailed ROM errors and documented input suppression are good; long-hold/scrub undiscoverable. |
| Snouty Gear | README/RUNNING/splash/menu and live preview; clear high-contrast selected row and source/CRC diagnostics; no hidden-gesture hint. |
| Snouty Genesis | README/RUNNING/splash/menu/picker/help and live preview; missing-ROM screen gives copy/eject/restart advice and explicit fallback, disabled files carry reasons (positive pattern to reuse); root status stale. |
| Snouty Maze | RUNNING/main controls; clear external auto/manual/fly table and idle return; no ordinary README; debug chord is documented as build-dependent. |
| Demosnout | RUNNING/main; part picker and hold feedback provide useful interaction states; no ordinary README; implementation/UX independently covered by native-cart agent. |
| Snouty Flyover | Main is SPEC-only; newer worktree README/RUNNING; district captions teach contextual B action, autopilot makes idle use easy; install text wrong and fps prose inconsistent. |
| Snouty Lynx | Main is plan/spec; newer worktree README/RUNNING/splash/strip/menu; option/chord emulation is documented; state labels stale and menu gesture hidden. |
| Snouty NES | Main NOTES-only project; not treated as shipped cart or reported defective for lacking runtime onboarding. |
| Calibration/bench | Operational/engineering surface, not attendee cart; primarily reviewed by parent. No hardware timing conclusions from wasm. |
| Badge station | Mobile-friendly size/layout and actionable fit reasons are strong; destructive action consistency, fallback mode, focus and startup setup are biggest new-user issues. |
| Shared simulator | Local watcher steps in updated README clearly explain startup order and reconnect-by-refresh; upstream Escape opens simulator overlay, not hardware OS exit (Boy RUNNING:226 currently says “leaves the cart”). Distinguish emulator menu, simulator menu and badge OS menu in controls cards. |

## Suggested consensus decisions and follow-up acceptance

1. Choose the reviewed release baseline before reconciling status docs: main plus dirty edits and branch-only implementations cannot be described as one deployed release.
2. Agree on destructive deployment/overwrite UX and explicit demo-only mode before implementation changes.
3. Agree on one small on-device discovery pattern across emulators and one pause/help pattern for games; controls may remain different where the emulated hardware requires it.
4. Pick one canonical installation/quick-start guide and reduce duplicated operational recipes; keep test/replay/performance reference material readily linked but after the playable path.
5. Validate on fresh checkout + one real badge, then a phone and keyboard/screen reader: build/serve a default free ROM, find menu, enable/mute, rewind/resume, leave cart, copy/eject/run multiple named carts, deploy a station set deliberately, and diagnose a missing ROM or unavailable station. These checks are proposed; hardware/mobile results remain unknown.
