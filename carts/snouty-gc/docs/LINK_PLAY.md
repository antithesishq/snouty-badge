# Snouty GC on two badges: LINK RACE and LINK GC

Two SYCL Badge V2s joined by a cable race in one field (SPEC 7): both
humans, plus 4, 2 or no AI racers, on one deterministic World that each
badge runs itself, exchanging only button bytes (`docs/NET.md`). Each
badge draws its own car, camera, HUD and gags.

**Status (M4, 2026-10-05): never run on two badges.** Everything below is
tested on the host (two badges on a simulated cable, `zig build test-gc`)
and in the simulator (where the link is offline). Section 4 is the
hardware check.

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
badge runs another cart). `-Ddebug_overlay=true` adds the link numbers to
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
   `LINK RACE` (3 laps) or `LINK GC` (GARBAGE COLLECTION, last car left
   wins), the track (six), `CREWS: 4 / 2 / 0` (AI racers on the grid).
   The guest sees them, greyed (`WAITING FOR HOST` until the first one
   arrives). `PEER` shows the other badge's racer.
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
guest's select on a taken racer) and the race notices with
`--call-at "T debug_link_notice:K"` (1 waiting, 2 peer left);
`docs/RUNNING.md` has the M4 preview commands.
