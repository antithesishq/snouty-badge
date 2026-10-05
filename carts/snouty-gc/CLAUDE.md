# Snouty GCP (cart notes)

Snouty GCP (Snouty Garbage Collection Prix; the cart, binary and tags
stay `snouty-gc`): a Mode 7 combat racer forked by copy from the Snouty
Zero engine. GARBAGE COLLECTION is still the name of its elimination
mode. `SPEC.md` is the design, `PLAN.md` the milestone
contract and status; read both before changing anything. The repository
rules are in the root `CLAUDE.md`. Never edit `carts/snouty-zero/` from
here: every forked file names its Zero source and commit on its first line.

## Modules (`cart/src/`)

- `main.zig`: `start`, `update`, the state machine (splash, title, main
  menu, select, race, pause, results; M4 the LINK `lobby`), the `World`
  instance, the render-side `follow` (which car this badge draws and
  hears: the player's `me`, or in the attract demo the camera's cuts, or
  the leader once GARBAGE COLLECTION has collected the player), wasm
  shims, debug exports. M4: the link (`lnk`, a `net.Net(link.Badge)`),
  the lobby and link select frames, the link race and pause frames
  (submit, one `step` a frame, the pump points, the pump loop to
  `tuning.link_pump_until_us`), `linked`, the gap probe
  (`gc_pump_probe`). M5: the CIRCUIT (`prix`, a `career.Career`; the
  `garage`, `standings` and `card` screens, `Mode.circuit`), A on the
  title for a Quick Race, the `gc_cards` bench poke. M6: BATTLE
  (`Mode.battle`: the menu row, the select, the `setup` screen over the
  arena's floor, `new_race(.battle, arena)` from `battle_ui.opts`, the
  KILL -9 card over the countdown, the kill leader's camera once out,
  LINK BATTLE from the lobby), the `gc_battle` bench poke.
- `battle_ui.zig` (M6): BATTLE's setup screen (arena, LIVES, TIME, CREWS,
  FIGHT!; `opts` is the next round's) and the `KILL -9` card.
  `battle_text.zig` (M6, no cart API, host-tested in
  `battle_ui_test.zig`): BATTLE's words, the setup rows and their
  cycling (TIME NONE never with INF), the clock, the standings lines, and
  the LINK lobby's rows and rule changes for LINK RACE / LINK GC / LINK
  BATTLE (`lobby_rows`, `lobby_change`).
- `career.zig` (M5): the CIRCUIT (the SNOUTY GCP, SPEC 8.2, 9): leagues,
  points, CYCLES booked from a finished World (place, `kills`, `chips`,
  league wins) outside `simulate`, the garage's offers, prices and
  purchases, the AIs' upgrade plans (`plans`, `ai_shop`: a share of the
  player's spending), `setup(seed)` for the next race. Pure, no cart API.
  `garage.zig` (the garage screen: portrait, turntable, slots, prices,
  the racers' reactions), `standings.zig` (the standings, league, unlock
  and end cards).
- `net.zig` (M4): GC's lockstep (`Net(L)`: lobby, `step`, pause,
  peer-left hand-over, desync check, `world_hash`), since the conversion
  GC's names over the shared `lib/lockstep.zig` (root `docs/LOCKSTEP.md`;
  `net.Game` is GC as lockstep's game: since M6 version 1 with five
  rules bytes, mode / track or arena / CREWS / LIVES / TIME, in the paged
  SETUP; `net.GameV0` the M5.1 one-byte game, tests only); `docs/NET.md`
  is its protocol and how main drives it. `net_m4.zig` is the M4
  original, test only, for `net_compat_test.zig` (GameV0's wire stays
  byte-identical to M4; v0 and v1 badges never race). `net.Resume`
  is the pause menu's RESUME (Start held until `paused` is off: `submit`
  drops bytes while `step` stalls); main's pump loop runs while
  `wants_pump()` (a race, or the link handshaking).
  `link_ui.zig` (M4): the LINK lobby screen (M6: LINK BATTLE's arena,
  LIVES and TIME rows, six rows 11 px apart), the race notices (`WAITING
  FOR PEER`, `PEER LEFT, AI DRIVING`), the `DESYNC` band. A link race
  pumps the link through the draw via `render.band_hook` /
  `render.pump_at` (render, sprites, hud call it; null outside a link
  race).
- M7 track packs (`docs/PACKS.md`): `pack_format.zig` (the `.GCP`
  format v1 as Zig: header, league block, track records, `parse`, the
  `Refusal` lines), `pack.zig` (no cart API: the drive scan by 8.3 entries,
  the background CRC `tick`, `load` of one track or arena: the tiles,
  horizon and map unpacked into the built-in slots, every other section
  read in place from the drive; `load_bytes` for tests; the link `id`),
  `pack_rows.zig` (the menus' rows: built-in tracks then pack tracks, The
  Sandbox then pack arenas; refused packs; the link rules' `track` and
  `pack`, `has_rules`). A pack track is `track.pack_track` /
  `pack_league`, `Setup.track = track.pack_base + k`. main.zig scans when
  the select, BATTLE's setup or the LINK lobby open and ticks the CRC in
  their frames only (never in a race or near a save). The simulator's drive
  is `-Dgc-pack=FILE[,FILE]` (build.zig's `gc_drive` module).
- `world.zig`: the plain `World` (6 `Car`s, clock, PRNG, countdown, track
  index; no pointers), `Input` (the race byte: bit 0 up, 1 down, 2 left,
  3 right, 4 A, 5 B, 6 Start, 7 Select), `Setup` (track, seed, the two
  humans' racers, mode, M4 `crews`: AI cars past it stay off the grid;
  M5 `loadouts`, one `Loadout` per car, default the stock car, and
  `chips`).
- `sim.zig`: `reset(w, setup)` and `simulate(w, inputs: [2]u8)`, pure in
  `(World, inputs)`: auto-throttle driving, walls, armor and `damage`,
  wrecks with kill credit, hulks and the WATCHDOG respawn, contacts and
  ramming by mass, laps (and the ammo refill), rank; M5 `equip` (a
  `Loadout`'s upgrades: PLATING and ECC, CLOCK, TRACTION, BURST BUFFER,
  WATCHDOG, guns and levels) and the cycle chips. No cart API, no
  globals written.
- `weapons.zig`: the 4 front and 4 rear weapons (SPEC 6.1, 6.2), the
  projectile and drop pools, hits, the SPEAR PHISH lock, the event ring
  writer `emit`; part of `simulate`.
- `pickups.zig` (M2): RMA crates, the roulette and rank-weighted rolls,
  the 15 pickups (SPEC 6.3) and their status effects, the KERNEL PANIC
  packet, DDOS drones, FORK BOMB forking; part of `simulate`, hooked in
  by `sim` and `weapons`. Render helpers `duck_pos`, `chain_anchor`.
- `hazards.zig` (M3): the generic track hazards (a timed blast = the
  Runoff's exhaust vents, a crossing mover = the Dumps' Sweeper; turret
  and crust reserved) driven by `track.hazard_specs`, and the service
  bays; part of `simulate`. `hazards.at(spec, tick)` is the pure cycle.
- `gc_mode.zig` (M3): GARBAGE COLLECTION's mark and sweep (sweeps as the
  leader passes sector 2 and the line, tags on weapon hits, collections,
  the survivor) and the attract demo's scripted KERNEL PANIC.
- `battle.zig` (M6): BATTLE's rules (SPEC 8.3): lives, eliminations,
  the respawn pad, SAFE MODE, out of lives, the round's end, the
  standings, the refill clock, the kill leader; part of `simulate`.
  `hunt.zig` (M6): the arena hunter `ai.drive` hands battle to (target
  per crew, the navigation field `track.arena`, jump legs, the bay
  retreat); `update_nav` keeps `Car.nav`. The arena (The Sandbox,
  `track.arenas`) comes from `tools/build_arena.py`, which
  `build_tracks.py` runs.
- `ai.zig`: the centerline driver per racer `Crew` with its combat
  character (aim, reaction, drops; `update_aim` is called by `sim`) and
  pickup policy (`want_use`, CAPTCHA solve ticks), the hazard sense
  (`dodge_hazards`: wait for a firing vent, pass behind the Sweeper);
  also the autopilot.
- `racers.zig`: roster (names, cars, chassis, placeholder liveries).
- `tuning.zig`: every constant (driving, chassis multipliers, AI).
- `track.zig`: runtime `League`/`Track` structs of slices (the built-in
  ones embed `gen/tracks/`; a pack in RAM can fill them later, SPEC 19),
  the track table (`tracks`, `leagues`), the map unpacker, `map_ram`, the
  crate spawns `crate_spots` (from the centerline samples flagged
  `flag_crates`, the `.track` word `crates`) and the hazard specs
  `hazard_specs` (from the track's `feat` records).
- `sprites.zig`: the runtime `Sheet` (every 4-bit art sheet, with blue
  and gold car tints), one blit with separate width and height (flat
  decals), the race's depth list (cars, projectiles, drops, crates,
  drones, ducks, particles; 64 drawn, cars never culled), the floor lines
  (DEADLOCK chains, duck tethers, SPAGHETTI strands) and the car states;
  M3: the MARKED outline, the GC claw, the Sweeper and the vents' blasts
  (and their warning lanes among the floor lines).
- `fx.zig`: render-side effects and HUD notices from the World's event
  ring (own cursor, never writes): explosions, sparks, smoke, muzzle
  flashes, lance beams, kill feed, taunt pop-up, ACK, wreck note, shake;
  M2: crate pops, `<honey>` tags, the duck pop, BIT FLIP's ray, the
  ZERO-DAY dart and flash, the RACE CONDITION glitch, pickup feed lines;
  M3: GC feed lines and bar notes, `TAGGED!`, the claws (`claws`, kept
  here because the World takes a collected car out), each collected car's
  sweep for the results, the vents' blast clocks and warning steam,
  hazard hits, the KERNEL PANIC victim the attract camera cuts to.
- `select.zig` (the racer select, SPEC 8.1; M3 the track row's panel;
  M4 `select.link`: the link select's `TAKEN`, ready marks and rules panel),
  `menu.zig` (splash, title, main menu with M6's BATTLE row: 7 rows, the
  pause list; its hint lines and the menu's geometry in `menu_text.zig`),
  `pickup_page.zig` (the menu's PICKUPS page: the
  pickups' icons by tier, a cursor, what each does; screen `pickups`) and
  `pickup_text.zig` (that page's words and grid moves, host-tested; keep
  them true to `pickups.zig` and `tuning.zig` when a pickup changes),
  `roster_text.zig` (bios,
  taunts, wrecked lines, weapon and pickup names, HUD liveries, stat
  bars), `stress.zig` (the render stress scene: `gc_stress` /
  `debug_stress`; `force_effect` behind the wasm `debug_effect`).
- `render.zig` (row-loop floor, horizon, fog, BIT FLIP's row jitter),
  `camera.zig` (follow, look back, culling projection), `hills.zig`,
  `hud.zig` (also the pickup box and the gags: blue screen, CAPTCHA,
  BIT FLIP, DDOS; M3 `SWEEP n`, MARKED tags, the spectator view; M6 the
  battle HUD: ELIM, the clock, lives pips, the refill sweep, the
  whole-arena minimap, SAFE MODE, the stunt pops),
  `font.zig`, `results.zig` (M3 the survivor card and GC table; M6
  BATTLE's winner card and standings),
  `sound.zig` + `engine.zig` (Zero's tones and drone), `input.zig` (edges,
  the Start+Select chord mask, `race_byte`).
- Host tests: `host_tests.zig` root, `sim_test.zig` (determinism, laps,
  completable with combat off, chassis), `weapons_test.zig` (a scenario
  per weapon on a frozen arena, ramming, wrecks, hulks, kill credit, AI
  combat, the 20-race combat soak), `pickups_test.zig` (roll odds,
  crates, a scenario per pickup, AI policies, the pickup soak),
  `content_test.zig` (M3: hazards, bays, the AI's hazard sense, every
  track's soak, GARBAGE COLLECTION and its soak, attract),
  `panel_text_test.zig` (every menu hint and PICKUPS line fits the 152 px
  panel: 18 characters; the menu's layout fits 7 rows; the page's grid,
  cursor and odds lines), `net_test.zig`
  (M4: two `Net`s and Worlds on `lib/link_virtual.zig`: link races in
  sync, loss, unplug, desync, pause, quit and rematch, CREWS; M6 LINK
  BATTLE rounds in sync to their end, clean and 1% loss),
  `battle_ui_test.zig` (M6: BATTLE's text, rows, clock, standings, lobby),
  `career_test.zig` (M5: the M0-M4 races' recorded fingerprints, each
  upgrade, ECC, chips, CYCLES, the garage, the AI plans, a full-circuit
  soak to the end card), tests in
  `track.zig`, `hazards.zig`, `gc_mode.zig`, `fixed.zig`, `engine.zig`.

## Data

The league and track data (`cart/src/gen/tracks/*.bin`) come from
`tools/build_tracks.py` (+ `tools/leagues.py`) and `cart/src/tracks/*.track`,
committed; since M3 `track.zig` embeds them with `@embedFile` (plain
slices, no comptime decoding: the Mac OOM rule), so a new track needs no
`build.zig` entry. `assets/gen/*.bin` (the font, and until build.zig drops
them the M0 copies of the Dumps and Landfill Loop files) reach the cart
through the `assets` module `build.zig` generates. Tilesets are 128 tiles. Engine
sprites: `ASSETS_ENGINE.md`. The art track owns `tools/draw_art.py`,
`assets/gen/art/` and `ASSETS.md` (M3: `tools/art/hazards.py`, the
Sweeper sheet `hazards.png`).

## Gates

- `tools/check.sh`: build, `zig build test` (falls back to `zig build
  test-gc` when other carts' runners fail, and says so), check-float,
  generator determinism, headless preview runs, badge-bench plain and
  `--lcd` (worst frame under 8 ms).
- The RAM cart is the shipped artifact; record bench mean/worst and
  `size -A` in `PLAN.md` per milestone. Since M3 it builds
  **ReleaseSmall** (`build.zig`): ReleaseFast no longer fits the 274 KB
  window (PLAN M3 status). The hot loops are written so ReleaseSmall
  keeps them fast (`inline for`, `inline fn`, a loop specialised per
  case in `sprites.blit_rect`, `hud.fill_rect` instead of the API's
  `rect` for fills); keep new per-pixel code the same way and bench it.
- Determinism is a gate from M0 (M4 is lockstep netcode): nothing in
  `simulate` may read the clock, `cart.rand`, floats or render state.
- Never bind the joystick click; react to neither Start nor Select while
  both are held. No neopixel code; sound off at boot with a toggle.
- M4: only the agreed input bytes and the agreed setup reach `simulate`
  in a link race; single player never touches the link, and the input
  scripts' World checksums (`check.sh` preview) must not change. The
  link race is host-tested only (`net_test.zig`); `docs/LINK_PLAY.md`
  has the two-badge check.
- M5: the stock `Setup` must stay the M0-M4 car: `check.sh` pins the four
  input scripts' `debug_world_sum` and `career_test.zig` the seeded
  races' fingerprints. Upgrades and chips reach the World only through
  `Setup` (`loadouts`, `chips`); LINK keeps the defaults.
- M7: the link protocol is version 2 (eight rules bytes: v1's five and
  the pack's 24-bit id; 4-bit picks, bit 3 `lacks`); `net.GameV1` and
  `GameV0` stay for net_compat_test. Pack data reaches `simulate` only as
  track data (`track.pack_track`; its sections are read in place from the
  drive, the same CRC-checked bytes on both badges).
  RAM: 16,312 B free at M7 (keep it at 16 KB or more; the saves branch
  takes 5,128). Never iterate a big global array by value (`for
  (track.map_ram)` copies 16 KB onto the stack): use `&`.
- M6: the link protocol is version 1 (`net.Game.version`); change it
  again whenever the rules bytes, the input bits or what `simulate` does
  with them change (root `docs/LOCKSTEP.md` 4.7). The KILL -9 card and
  every other battle screen are render-only: nothing waits on them in a
  link battle. Menu changes move the rows check.sh's previews and
  `m5_circuit_race.json` press through (BATTLE is the third row).
