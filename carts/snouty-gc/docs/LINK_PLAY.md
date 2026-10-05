# Snouty GC on two badges: LINK RACE, LINK GC and LINK BATTLE

Two SYCL Badge V2s joined by a cable race in one field (SPEC 7): both
humans, plus 4, 2 or no AI racers, on one deterministic World that each
badge runs itself, exchanging only button bytes (`docs/NET.md`). Each
badge draws its own car, camera, HUD and gags. Since M6 the host can also
pick **LINK BATTLE** (`KILL -9`, SPEC 8.3): the two humans and the AI
crews brawl on The Sandbox with lives, scored on eliminations.

**Status (M6, 2026-10-05): never run on two badges.** Everything below is
tested on the host (two badges on a simulated cable, `zig build test-gc`)
and in the simulator (where the link is offline). Section 4 is the
hardware check; items 10 and 11 are M6's.

## 1. The cable

A **JST-SH 3-pin to 3-pin cable** (1.0 mm pitch, the Raspberry Pi Debug
Probe kind) between the two badges' **UART headers (J4)**. Either
orientation works, crossed (pin 1 to pin 3) or straight (pin 1 to pin 1):
the link finds out which. A Qwiic / STEMMA QT (4-pin) cable does not fit
J4; do not use the I2C or SWD headers. Details: root `docs/LINK.md`
section 1.

Known bad: Adrian's own badge's UART header (GPIO29 reads high with
nothing attached, PIO never moved GPIO28; root `docs/LINK.md`). Use two
other badges, and run `snouty-link.uf2` first if in doubt: it shows
`CONNECTED` and each badge's buttons on the other within a second.

## 2. Flash both badges

From the repository root, on the branch or tag under test:

```sh
zig build -Dcart=snouty-gc     # zig-out/firmware/snouty-gc.uf2
```

Copy `snouty-gc.uf2` onto each badge's `SYCLBADGE` drive and eject
(root `docs/INSTALL.md`). Both badges must run this same build: the
lockstep assumes the same simulation code on both (a different build is
a `DESYNC` within half a second of racing, or `WRONG CART` if the other
badge runs another cart). An M6 build against an older one (M4 to M5.1:
the link protocol went to version 1 for LINK BATTLE's rules) never
races: an M5.1 badge and an M6 badge both show `WRONG VERSION`; an M4
badge waits on its LINK screen and the M6 one shows `WRONG VERSION`. `-Ddebug_overlay=true` adds the link numbers to
the race (section 5).

## 3. Start a link race

1. Join the cable, start Snouty GC on both badges, Start through the
   title, and pick **LINK** on the main menu (A) on both.
2. The LINK screen says `PLUG IN THE CABLE` / `SEARCHING...` until the
   other badge is on its LINK screen too. Within about a second both show
   the rows, one badge **HOST** and the other **GUEST** (the badge whose
   link nonce is higher hosts; it changes from session to session), and
   the cable kind (`CROSSED` / `STRAIGHT`) at the right. `WRONG CART`: the
   other badge runs another cart that uses the link.
3. **The host** sets the rules: Up/Down a row, Left/Right its value:
   `LINK RACE` (3 laps), `LINK GC` (GARBAGE COLLECTION, last car left
   wins) or `LINK BATTLE` (M6), the track (six; in LINK BATTLE the arena,
   `THE SANDBOX`), `CREWS: 4 / 2 / 0` (AI racers on the grid), and in
   LINK BATTLE two more rows, `LIVES: 1 / 3 / 5 / 9 / INF` and `TIME: 2 /
   3 / 5 MIN / NONE` (NONE is skipped with INF lives). The guest sees
   them, greyed (`WAITING FOR HOST` until the first one arrives). `PEER`
   shows the other badge's racer.
4. **A** on either badge opens the racer select. Left/Right a racer, **A**
   marks it `READY`. A racer the other badge is ready on is greyed
   `TAKEN`; if both mark the same racer at once, the host keeps it and
   the guest's mark goes. **B** takes the mark back, B again returns to
   the LINK screen.
5. With both `READY`, the host's bottom row blinks `A START`: the host's
   **A** starts the race on both badges (the guest's reads `HOST
   STARTS`). Both run the countdown from the same tick.

### In the race

- Driving, weapons, pickups: as single player (`docs/RUNNING.md`).
- **Start** on either badge pauses both on the same tick (`PAUSED`:
  RESUME, QUIT, SOUND). Start (on either), B, or A on RESUME resumes
  both. QUIT leaves the race: the other badge gets `PEER LEFT, AI
  DRIVING` (`PEER QUIT`) and races on with its AI driving your car.
- `WAITING FOR PEER`: the other badge's buttons are half a second late
  (the race freezes until they come). Normal for a frame now and then;
  steady means the cable is bad or out.
- `PEER LEFT, AI DRIVING` (3 s), with `CABLE OUT`, `PEER RESTARTED` or
  `PEER QUIT`: the other badge is gone; this badge finishes the race
  alone with the AI on the other car.
- `DESYNC: RACE ENDED` over the results: the two Worlds differ (checked
  every 32 ticks; should never happen with the same build on both).
- After the finish each badge shows its own results (A steps through);
  then both are back on the LINK screen, ready flags cleared, for a
  rematch (a new seed each race).

### In a LINK BATTLE (M6)

- Both badges show the `KILL -9` card over the countdown's first two
  steps (drawn by each badge; the lockstep runs under it), then `2`,
  `1`, `GO` together.
- The HUD: `ELIM n` and the lives pips top left, the round clock in the
  middle, your standing beside it; the minimap is the whole arena with
  every car (the kill leader ringed cyan). Each badge's feed reads the
  same `SNOUTY kill -9 KIDDIE` lines at the same moment.
- A wreck costs a life; you come back on a spawn pad blinking in `SAFE
  MODE` (no firing, no hits) for 1.5 s. Your last life: the claw lifts
  your hulk out (`REAPED`), and your badge rides with the kill leader's
  camera until the end. The other badge plays on.
- The round ends on both badges on the same tick: one car left with
  lives (`LAST ONE STANDING`) or the clock (`TIME UP`). Both show the
  same standings (eliminations, lives, time survived).

Leaving the LINK screen (B to the main menu) stops the link; the other
badge goes back to `SEARCHING...` about 2 s later. Single-player modes
never touch the link.

## 4. Hardware check (show day, two working badges)

Each item says what to look for; note anything else.

1. **Connect.** Both on LINK: rows and HOST / GUEST within ~1 s, opposite
   roles, the same cable kind on both. Unplug: both back to `SEARCHING...`
   (within ~0.1 s); replug: rows again.
2. **Rules reach the guest.** Host: LINK GC, Cathode Flats, CREWS: 2.
   The guest's greyed rows follow within a frame or two.
3. **Select.** Both on the select; ready the same racer on both: the
   guest's mark drops, `TAKEN` on its portrait. Guest picks another,
   ready: host shows `A START`; host A: both start on the same countdown
   (watch both screens: `3`, `2`, `1`, `GO` together).
4. **One World.** CREWS: 2 LINK RACE: 4 cars on the grid on both badges.
   Drive both cars; each badge's minimap and rank show the same field
   (the dots in the same places), the same crates taken, and a hit on
   one badge shows as the same hit on the other. Finish: the same
   results table (places and times) on both.
5. **Pause.** Start on the guest: both paused; Start on the host: both
   resume. A on RESUME also works (one press).
6. **Stalls.** Race a whole LINK RACE with `-Ddebug_overlay=true` builds:
   the line under the lap counter reads `W` (frames that waited for the
   other badge), `C` (link CRC drops), `G` (the worst gap between two
   link polls, us). Expected: W in the single digits or tens over a
   race and no `WAITING FOR PEER`, C at or near 0, G under about 1500
   (badge-bench puts the worst gap inside a frame at 0.8 ms: one big
   sprite; PLAN M4 status). Note the three numbers from both badges.
7. **Peer gone.** Mid-race pull the cable: both show `PEER LEFT, AI
   DRIVING` / `CABLE OUT` within ~0.1 s and race on; the other car keeps
   driving (its AI). Finish, results, LINK screen shows `SEARCHING...`.
   Repeat with QUIT from the pause menu (`PEER QUIT`) and by switching
   one badge's cart off (`CABLE OUT` or after 2 s).
8. **LINK GC.** A whole LINK GC race with CREWS: 4: marks, tags and
   claws the same on both, one survivor, `LAST PROCESS RUNNING` on both.
9. **Rematch.** After the results, back on LINK; a second race starts
   and runs in sync (a new seed: the AI grid order and crate rolls
   differ from the first).
10. **LINK BATTLE (M6).** Host: Right on the mode row to `LINK BATTLE`:
    the track row reads `THE SANDBOX` and `LIVES` / `TIME` rows appear
    on both badges (the guest's greyed copy follows within a frame or
    two). Set LIVES 3, TIME 2 MIN, CREWS 2; the select's panel reads
    `THE SANDBOX  CREWS 2` / `3 LIVES, 2 MIN` on both. Start: the
    `KILL -9` card on both, then the countdown together. Then check:
    - **One arena**: the same four cars on the same spawn pads on both
      minimaps; the same crates; the same feed lines (`kill -9`,
      `SMASHED`, `REAPED`) at the same moments; the same clock on both
      (within a frame).
    - **Lives**: wreck the other badge's car (or let an AI): its pips
      drop by one on its own badge, it respawns blinking `SAFE MODE` on
      the same pad on both screens, and your `ELIM` counts it.
    - **Stunts**: a jump over the bit bucket landing clean shows `CLEAN
      LANDING` on that badge only; a landing on a car shows `STACK
      SMASH!` on the lander's badge and `STACK SMASHED` on the victim's.
    - **Out**: run one human out of lives: the claw on both screens,
      `REAPED` bottom left on that badge, which then follows the kill
      leader (its name under the clock); the other badge keeps playing.
    - **End**: the round ends on the same tick on both (`TIME UP` or
      `LAST ONE STANDING`), the same winner card (TOP KILLER / LAST
      PROCESS UP) and the same standings on both; back to LINK, a
      rematch runs in sync.
    - **Pause**: Start on either pauses both in a battle too, and the
      clock stops on both.
    - Note `W`, `C`, `G` from the overlay build as in item 6 for one
      whole round (the arena's floor has more on screen than a track).
11. **Versions (M6).** Flash one badge with an M5.1 build (tag
    `snouty-gc/m5.1`) and the other with this one: both LINK screens
    show `WRONG VERSION` within ~1 s and neither ever reaches the racer
    select. Swap which badge has which build: the same.

If it never connects: run `snouty-link.uf2` on both (root
`docs/LINK.md`, its hardware check) to tell the cable or a header from
this cart.

## 5. What the debug overlay shows

`-Ddebug_overlay=true` (both badges): the frame time top right (in a
link race it reads about 14000 us: the cart keeps polling the link until
14 ms into each frame) and, in a link race, `W n C n G n` under the lap
counter: frames without a tick, the link's CRC drops, the worst gap
between two link polls inside a frame this race (us).

## 6. Simulator

The simulator has no link: LINK is greyed and A on it flashes `NO LINK IN
SIMULATOR`. The headless preview can show made-up LINK screens with
`--call debug_link_view:K` (1 searching, 2 the host's lobby, 3 the
guest's, 4 another cart, 5 the host's select with both ready, 6 the
guest's select on a taken racer, 7 another version) and the race notices
with `--call-at "T debug_link_notice:K"` (1 waiting, 2 peer left);
`--call debug_link_mode:2` puts the made-up lobby on LINK BATTLE (its
rows then respond to the pad, as the host's); `docs/RUNNING.md` has the
M4 and M6 preview commands.
