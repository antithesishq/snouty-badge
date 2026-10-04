# Snouty GC: plan

`SPEC.md` is the design. This file is the contract for the milestone being
built, detailed enough that parallel tracks (Opus agents) can work without
talking to each other. Status lines go at the bottom of each milestone
block. Decisions taken without Adrian are listed under "Deferred questions"
at the end, so he can override them in one pass.

Build approved by Adrian on 2026-10-04: "go ahead and build", using
subagents, progressing through the milestones until blocked on feedback,
decisions or device testing.

## File layout (target; M0 creates the engine half, the art track the art half)

```
carts/snouty-gc/
  build.zig              pub fn add: RAM cart (+ the XIP build every cart has), host tests, check-float
  CLAUDE.md              cart notes for agents (modules, gates, commands)
  SPEC.md, PLAN.md, ASSETS.md
  cart/src/main.zig      start/update, state machine, wasm shims, debug exports
  cart/src/fixed.zig     Q16.16, sin/cos, xorshift Rng            (Zero)
  cart/src/gen/sin.zig   committed sine table                      (Zero)
  cart/src/font.zig      8x8 font blit                             (Zero)
  cart/src/input.zig     buttons -> the 8-bit race input byte (SPEC 5.1)
  cart/src/camera.zig    follow camera, look back                  (Zero)
  cart/src/render.zig    Mode 7 floor, horizon, fog, shake         (Zero)
  cart/src/hills.zig                                               (Zero)
  cart/src/sprites.zig   scaled blit, depth list                   (Zero)
  cart/src/track.zig     embedded league art + track data, LZ unpack (Zero)
  cart/src/tracks/*.track
  cart/src/world.zig     World: 6 cars + pools, no pointers
  cart/src/sim.zig       simulate(world, inputs: [2]u8)
  cart/src/ai.zig        centerline AI, crews, autopilot           (Zero, extended)
  cart/src/racers.zig    roster table (SPEC 4.1)                   (M1)
  cart/src/weapons.zig, pickups.zig, fx.zig                        (M1, M2)
  cart/src/hud.zig, menu.zig, select.zig, results.zig              (Zero / M1, M3)
  cart/src/net.zig                                                 (M4)
  cart/src/garage.zig, career.zig                                  (M5)
  cart/src/tuning.zig    every gameplay constant
  cart/src/host_tests.zig
  cart/build/convert_gfx.zig   per-cart copy
  assets/gen/            generated, committed (tracks, tilesets, horizons, font, sprites)
  assets/gen/art/        the art track's sheets (portraits, cars, weapons, pickups, fx)
  tools/build_tracks.py, tools/leagues.py, tools/gen_sin.py, tools/gen_font.py   (Zero)
  tools/draw_art.py      the art track's generator (portraits, cars, weapons, pickups, fx)
  tools/scripts/*.json   preview.mjs / badge-bench input scripts
  tools/check.sh         the cart gate
  docs/RUNNING.md, docs/*.gif, docs/*.png
badge-bench/carts/snouty-gc.toml
```

## M0 Fork

Goal: a playable 6-car race on Landfill Loop in the Dumps, on Zero's engine
with no rewind, plus the cart's whole art set drawn in parallel.

### Track A: engine fork (worktree /home/exedev/snouty-badge-gc, branch gc/spec)

Owns everything in the layout except `tools/draw_art.py`, `assets/gen/art/`
and `ASSETS.md`'s art section.

1. Copy Zero (`carts/snouty-zero` at origin/main) into `carts/snouty-gc`,
   with a provenance line at the top of each copied file
   (`//! Forked from snouty-zero/<file> at <sha>.`). Rename the binary,
   the module names and the debug exports. Register the cart in the root
   `build.zig`, the root `CLAUDE.md` cart list, and
   `badge-bench/carts/snouty-gc.toml`.
2. Strip what this cart doesn't have: `history.zig` and every rewind
   path, Overclock and the thermal bar, traffic, Zero's nine tracks and
   three leagues, the Grand Prix and machine select. Keep the menu
   skeleton, splash, title, pause and results as simple placeholders,
   which M1 and M3 replace. Keep the engine drone behind the sound
   toggle.
3. **Dumps league art** from `tools/leagues.py` (forked): a **128-tile**
   tileset (SPEC 13.2) with CRT-glass sand, circuit-board flats, cable
   ruts, wreckage walls, a monitor-pile background and a start line; the
   horizon pair (monitor mountains, smoke columns) and palette.
   **Landfill Loop** `.track`, 3,500 to 4,500 world px a lap, with walls,
   an open-edge pit section, a ramp and a coolant puddle. Mark where crate
   rows and a service bay will go as comments (M1 and M2 add the feature
   words).
4. **Driving**: SPEC 5.1 and 5.2. Auto-throttle, Down brake, Down+dir
   powerslide, Up burst (charges per lap), wheel grip values, all in
   `tuning.zig`. `input.zig` packs the race byte (bit 0 up, 1 down, 2 left,
   3 right, 4 A, 5 B, 6 start, 7 select). `sim.simulate(w: *World,
   inputs: [2]u8)`. The World has `cars: [6]Car`, each with
   `racer: u8` (0..5, SPEC 4.1 order: SNOUTY, LEGACY, KIDDIE, SYSADMIN,
   ROOTKIT, BOTNET), `human: u8` (0 or 1 = which input byte drives it,
   0xFF = AI) and the chassis multipliers. Nothing in `simulate` knows
   which car this badge draws; `main.zig` keeps a render-side
   `follow: u8`.
5. **Six cars** on the grid in placeholder liveries (Zero's machine
   sprite re-paletted is fine: the art track replaces it in M1), five
   driven by Zero's AI with per-racer chassis multipliers (SPEC 4.2:
   SNOUTY and SYSADMIN WORKSTATION, LEGACY and BOTNET MAINFRAME, KIDDIE
   and ROOTKIT THIN CLIENT). The player is SNOUTY until the M1 select.
   Rank, laps, minimap and results work. No weapons, no armor bar yet.
6. **Tests and gate**: host tests for trig, attribute lookups, lap
   counting, `simulate` twice from one state equals byte-for-byte, a
   2,000-tick run with random inputs equal across two runs, the
   completable test on Landfill Loop (autopilot, 3 laps, no fall, time
   bound), `@sizeOf(World)` printed. `zig build check-float`.
   `tools/check.sh` runs build, test, check-float and a preview script.
7. **Measure** (SPEC 18): `size -A` of the RAM ELF (`.text`, `.data`,
   `.bss`) and the bench (`--symbols`, and once with `--lcd`) on a
   600-frame race script, mean and worst. Holding Select alone in the
   upstream OS: read `sycl-badge/src/os` for any Select-only handling and
   record the answer.
8. A preview GIF `docs/preview_m0.gif` and `docs/RUNNING.md` (simulator
   and headless commands). Tag `snouty-gc/m0` when the gate is green.

### Track B: art (worktree /home/exedev/snouty-badge-gc-art, branch gc/art off gc/spec)

Owns `carts/snouty-gc/tools/draw_art.py`, `carts/snouty-gc/assets/gen/art/`,
`carts/snouty-gc/ASSETS.md` and `carts/snouty-gc/docs/art_*.png`. No Zig.

Every sheet is an RGB PNG with `#FF00FF` as the transparent key and at
most 15 other colours (the per-cart `convert_gfx` at 4 bits), laid out as
a horizontal strip of equal cells, as Zero's `machine.png` is. Code-drawn
in Python with Pillow, deterministic, regenerated by one command.

1. **Portraits** `portraits.png`: six 48x48 cells in SPEC 4.1 order, each
   a character, readable at 1:1 and at half scale (24x24 nearest). Each
   portrait gets its own 15-colour palette, so either use one sheet per
   portrait (`portrait_<racer>.png`) or keep a shared palette across the
   strip; ASSETS.md says which. **Snouty** comes from the study05 rig
   (`snouty-art/`, `styles/study05`; see `snouty-art/CLAUDE.md` and
   `tools/install_badge.py` for how carts take heads), with a black
   **eyepatch** over the left eye, its strap round the head, a small scar
   under it, and a squint in the other eye. LEGACY, KIDDIE, SYSADMIN,
   ROOTKIT and BOTNET as in SPEC 4.1's portrait column. These are the
   cart's personality, so they get a real art pass: distinct silhouettes,
   faces that read, a little humour in each.
2. **Cars**: one sheet per racer, `car_<racer>.png`, cells 32x16: rear,
   rear-quarter right, side right (the renderer mirrors for left), plus
   a wreck frame, plus an airborne frame. Silhouette by chassis (SPEC 4.2)
   and details by racer (ANTEATER snout prow with Snouty's eyepatched
   head in the cockpit; BIG IRON plough; CTRL-V stickers and spoiler;
   UPTIME LED rack; PERSIST matte black with lights; ZOMBIE patched bus
   with heads in the windows). Livery colours are distinct on the minimap.
3. **Weapons** `weapons.png`, 8x8 cells: PING pellet, BROADCAST pellet,
   SPEAR PHISH missile (rear, side and 3/4 views), LOGIC BOMB (`if`),
   MEMORY LEAK puddle (flat, drawn as seen from above, 16x8 in its own
   sheet `decals.png` with BIT ROT caltrop, SPAGHETTI tangle, FIREWALL base,
   cycle chip), FIREWALL flame (2 frames, 16x16 in `fx.png`).
4. **Pickups** `pickups.png`, 16x16 icons for the HUD box: the 16 pickups
   of SPEC 6.3 plus the roulette blank and the RMA crate (a 16x16 crate
   sprite, plus HONEYPOT's off-by-a-shade fake), the RUBBER DUCK sprite,
   the `&` FORK BOMB, the DDOS drone (4x4), the KERNEL PANIC packet.
5. **Effects** `fx.png`, 24x24: explosion 4 frames, smoke puff 2,
   spark 2, muzzle flash, the GC claw (24x32 own sheet `claw.png`).
6. **Screens**: `bsod.png` is not needed (drawn in code). The CAPTCHA grid
   is drawn in code. The fish-hook reticle is 12x12 in `hud.png`, with the
   lock/unlocked frames, a burst pip, an ammo pip and the `ACK` glyph if it
   reads better as art.
7. **Review**: `docs/art_contact.png`, every sheet at 3x on one page with
   labels, and `docs/art_select_mock.png`, a 160x128 mock of the racer
   select (SPEC 8.1) at 3x for each of the six racers, using the font in
   `carts/snouty-zero/assets/gen/font.bin` (96 glyphs of 8 bytes, ASCII
   32..127, bit 7 = left pixel) so the bios are seen at real size.
8. Commit on `gc/art` with ASSETS.md describing every sheet (file, cell
   size, frames, palette, what M1 must wire). The lead merges it into
   the cart branch.

### M0 gate

`tools/check.sh` green (build, `zig build test`, check-float, preview);
the completable and determinism tests pass; bench mean/worst and the RAM
figures recorded below; `docs/preview_m0.gif`; art contact sheet
reviewed by the lead; tag `snouty-gc/m0`; merged to main.

### M0 status

(empty)

## Deferred questions

(none yet; see SPEC 17 for the defaults)
