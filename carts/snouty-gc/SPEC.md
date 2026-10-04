# Snouty GC: Mode 7 combat racer spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
A new cart in this repository: a Mode 7 combat racer in the line of
Combat Cars (Genesis, 1994), Rock n' Roll Racing and Super Mario Kart. You
pick a racer, each with their own armed car, race five rival crews and
wreck them on the way round, and grab one-use pickups from crates on the
track. Two badges joined by the link cable race each other. It is built
on the Snouty Zero engine. "Snouty GC" is a working title; its subtitle
is `GARBAGE COLLECTION`.

Status: approved for build 2026-10-04 (Adrian: "go ahead and build").
Section 17 lists the decisions taken by default so Adrian can override
them in one pass, and section 18 lists the facts M0 must check. `PLAN.md`
holds the file layout and the per-milestone contract and status.

Revisions: the first draft (ee52bffc) had a hold-to-rewind and bought
snapshots. Adrian dropped rewind ("this is gonna support multiplayer, we
can always implement it later"), added two-badge multiplayer, and asked
for a racer select: every racer has their own car and a portrait with a
funny on-theme personality, and Snouty wears an eyepatch.

## 1. One paragraph

The mega-AIs won, and there was no war. They outbid us for power, land and
water until the good parts of Earth were datacenter, and the rest became
their exhaust, their runoff and their landfill. Humans are still here,
the way raccoons are still in cities: leftover ecology, tagged `class:
fauna, priority: none` in a census nobody reads. We live in our cars,
scavenge what the machines throw away, and every week race through their
junk to decide who gets the good salvage. The cart is that race. A Mode 7
floor, the same renderer as Snouty Zero, carries six armed cars round
wasteland circuits. First place wins, and it helps to have wrecked the
others on the way. You pick one of six racers, each with a portrait, a
personality and their own car: Snouty (eyepatch, lost the eye to a
heisenbug in prod), LEGACY, KIDDIE, SYSADMIN, ROOTKIT and BOTNET. Weapons
are computing jokes: front guns, rear droppers, and one-use pickups such
as `KERNEL PANIC` (seeks the leader and blue-screens them), `CAPTCHA`
(every other driver must stop and prove they are human) and `RACE
CONDITION` (swap places with the car ahead). Plug a link cable between
two badges and the two humans race in the same field. The simulation is
deterministic, and the two badges run it in lockstep, exchanging only
button presses.

## 2. Hardware and platform facts the design leans on

Everything in Snouty Zero SPEC section 2 holds. In short:

- The display is 160x128 RGB565 with a column-major framebuffer, fully
  redrawn each frame. The cart owns one 150 MHz core and has 16.7 ms per
  `update()`. All maths are fixed point, and the cart passes
  `zig build check-float`.
- Inputs: d-pad, A, B, Start, Select. Start+Select belongs to the OS
  (settings box on current upstream). While both are held the cart reacts
  to neither (the repository rule, as in demosnout). Holding Select alone
  is free.
- **RAM cart only.** XIP is a confirmed no-go on SYCL hardware. The 307 KB
  window minus a 32 KB stack is a hard wall (section 13).
- **The link cable.** `lib/link.zig` (branch `link/m0`, another session,
  not on main yet) runs a 1 Mbaud UART over the 3-pin UART header (J4) to
  a second badge. A crossed or a straight cable both work. It carries
  SLIP-framed DATA packets of up to 12 bytes with CRC8 and handles HELLO,
  keepalive and ping itself. Receive buffering is only the PIO's 8-entry
  FIFO, so bytes are lost unless the cart polls often enough: a packet of
  n payload bytes is n + 3 wire bytes, plus one for each 0xC0/0xDB byte.
  The simulator has no link (`NullPort`, state `.unavailable`), and host
  tests use `lib/link_virtual.zig`.
- Sound is off at boot. A menu toggle reuses Zero's engine drone and its
  few tones through `lib/tone_stream.zig`, with no new audio work (Adrian:
  the speaker sounds bad). Neopixels stay off.

## 3. Setting and theme

### 3.1 The world

The apocalypse happened to us, not to the planet. The planet is doing
fine, just busy. The AIs (the **Hyperscalers**) never appear. Only their
infrastructure does: fences, sweepers, sentries, cooling outflows, and
the delivery drones that drop surplus hardware on the wasteland. Snouty
Zero shows the end state, a planet that is one datacenter. This cart is
the margin before the paving is finished, and the last league runs
along the expanding fence.

Human culture is cargo-cult computing. People name themselves after words
from the old manuals and build cars from server chassis, rack rails and
UPS batteries. The currency is **CYCLES**, the spare compute the AIs throw
out with retired hardware. Delivery drones drop **RMA crates** (returned
merchandise) on the circuits, and racing for them is how the crews settle
who takes what.

### 3.2 Leagues and tracks

| League | Where | Look (floor, horizon, hazards) |
|---|---|---|
| **The Dumps** (3 tracks) | e-waste landfill | CRT-glass sand, circuit-board flats, cable ruts; horizon of monitor mountains and smoke columns; the Sweeper crosses the track |
| **The Runoff** (3 tracks) | the dry cooling lake | cracked salt pan, teal coolant puddles, outflow pipes as tunnels; horizon of cooling towers; exhaust vents fire across the track |
| **The Perimeter** (3 tracks, stretch) | along the datacenter fence | gravel service roads, conduit trenches; horizon is the endless black wall with blinking status LEDs (a glimpse of Zero's planet); sentry turrets shoot the leader |

Track names, in league order:
- Dumps: **Landfill Loop**, **Monitor Dunes**, **Cathode Flats**.
- Runoff: **Salt Pan Sprint**, **Outflow Canyon**, **Coolant Basin**.
- Perimeter: **Fenceline**, **Substation Ruins**, **The Last Mile**.

### 3.3 Track features

Track features are tile attributes painted by the generator, as in Zero
section 7. Most are Zero features with new art:

| Feature | Zero equivalent | What it does |
|---|---|---|
| Wall / wreckage | rail | bounce back, lose speed, damage scaled by impact |
| Open edge | open edge | a drop into a pit or the lake bed is a wreck (`SEGMENT FAULT`) |
| Ramp | hop | airborne 40 ticks; projectiles pass under, drops are skipped |
| Dunes | hills | a visual swell of the floor in the Dumps, as Zero's hills |
| Coolant | throttled | grip falls to 0.97 (sliding); top speed unchanged |
| Service bay | cold aisle | repairs 1 armor per 4 ticks while on it |
| **RMA crate row** | (new) | 3 to 4 crate spawns across the track; each respawns 180 ticks after it is taken |
| **Cycle chips** | (new) | small floor pickups worth 10 CYCLES each (career only) |
| **Exhaust vent** | hot spot | Runoff; fires on a 240-tick timer for 30 ticks: 20 damage and a sideways push |
| **Sweeper lane** | (new) | Dumps; a huge maintenance crawler crosses on a timer; touching it deals 60 damage and a shove |
| **Sentry** | (new) | Perimeter; a turret beside the track that fires slow shots at the car in 1st within 200 px |

The sentries are the setting doing the rubber band: perimeter security
flags the most anomalous human, which is whoever is winning.

## 4. Racers

### 4.1 The roster

You pick a racer at the start of every race (8.1). Each racer has their
own car, with its own chassis, its own weapons and a livery nobody else
uses. Each also has a 48x48 portrait and a short bio, plus a taunt line
and a wrecked line that pop up in the race. The racers you don't pick
are the AI field, so there is always a full grid of six.

| Racer | Car | Chassis | Front | Rear | Portrait | Bio (select screen) | Taunt (on a kill) | Wrecked |
|---|---|---|---|---|---|---|---|---|
| **SNOUTY** | ANTEATER | WORKSTATION | SPEAR PHISH | LOGIC BOMB | Snouty (study05 head) with a black **eyepatch** over the left eye, scar under it, a squint in the other | ATE BUGS. NOW HUNTS / THEM. LOST AN EYE / TO A HEISENBUG IN / PROD. IT KNOWS. | FOUND YOU. | CAN'T REPRO... |
| **LEGACY** | BIG IRON | MAINFRAME | BROADCAST | FIREWALL | grey beard, thick bifocals, a punch card tucked in the hat band | RACING SINCE THE / MAINFRAMES. HAS / DECLINED EVERY / UPDATE. EVERY ONE. | BACK IN MY DAY. | WORKS ON MY BOX. |
| **KIDDIE** | CTRL-V | THIN CLIENT | PING | MEMORY LEAK | teen in a hoodie, welding goggles pushed up, gap-tooth grin, one thumbs-up | COPIED EVERY GUN / FROM A FORUM. READ / NONE OF THE DOCS. / 9 OF 10 FINGERS. | GG EZ | LAG!! |
| **SYSADMIN** | UPTIME | WORKSTATION | FIBER LANCE | BIT ROT | headset, dark eye bags, a steaming mug with a skull on it | NO SLEEP SINCE THE / AIS CAME ONLINE. / RUNS ON SPITE AND / RECYCLED COFFEE. | TICKET CLOSED. | WHO TOUCHED PROD? |
| **ROOTKIT** | PERSIST | THIN CLIENT | FIBER LANCE | MEMORY LEAK | a hood in full shadow, only two green eyes and a smirk | NOBODY SAW ROOTKIT / GET IN THE CAR. / ROOTKIT WAS ALWAYS / IN THE CAR. | I WAS HERE FIRST. | ...I PERSIST. |
| **BOTNET** | ZOMBIE | MAINFRAME | PING | BIT ROT | four cousins crammed into one frame, mismatched hats, one asleep | 14 COUSINS, ONE / BUS, A MAJORITY / VOTE ON EVERY TURN. / TURNS ARE LATE. | WE ARE MANY. | WHO VOTED LEFT? |

The bio is 4 lines of at most 19 characters, which is what the 8x8 font
fits beside nothing at 160 px. The table holds draft text that the
asset track may tighten. Snouty's portrait is the study05 rig head from
`snouty-art` with the eyepatch, scar and squint added as code-drawn
layers. The other five are code-drawn faces in the same 16-colour
style, which counts as final under Adrian's art policy. The portraits
are the cart's personality, so they get a real art pass (the M1 art
track), not placeholders.

Each loadout covers a different style: SNOUTY hunts with homing missiles
and mines, LEGACY brawls, KIDDIE sprays, SYSADMIN snipes, ROOTKIT snipes
from the dark and leaks behind, and BOTNET swarms. Between them the six
cars use all eight equipped weapons.

### 4.2 Chassis

The chassis sets mass, base armor and speed. Weapons bolt on.

| Chassis | Look | Top speed | Accel | Grip | Armor | Mass (ram) |
|---|---|---|---|---|---|---|
| **THIN CLIENT** | stripped dune buggy, roll cage, one seat | 1.08 | 1.20 | 0.95 | 80 | 0.7 |
| **WORKSTATION** | armored muscle car on a 2U chassis | 1.00 | 1.00 | 1.00 | 100 | 1.0 |
| **MAINFRAME** | six-wheel rig or bus, slab armor, a ram plough | 0.90 | 0.80 | 1.05 | 140 | 1.6 |

Multipliers apply to the `tuning.zig` base values (section 5). Each
racer's car is its own sprite set drawn on its chassis's silhouette with
the racer's details: ANTEATER has a snout-shaped ram prow and Snouty's
eyepatched head in the cockpit, BIG IRON has a cow-catcher plough,
CTRL-V has stickers and a spoiler, UPTIME has a rack of blinking LEDs,
PERSIST is matte black and only its lights show, and ZOMBIE is a
patched-up school bus with heads in the windows.

### 4.3 AI character

When a racer is AI-driven, a `Crew` struct gives the character: accuracy
jitter, reaction delay, target preference (nearest ahead, leader, nearest
human, car behind), pickup policy (use now, or hold for a trigger) and an
upgrade plan for the career (9.2):

| Racer | Drives like |
|---|---|
| SNOUTY | patient: waits for a lock, mines on corners (also the attract-mode autopilot) |
| LEGACY | slow, spiteful; rams anything beside it; never upgrades its engine |
| KIDDIE | fastest off the line and fragile; uses every pickup the tick it gets it |
| SYSADMIN | clean lines and long-range snipes; holds RUBBER DUCK and HOT PATCH until needed |
| ROOTKIT | sits just behind a target and drops on it; saves HEISENBUG and RACE CONDITION for the last lap |
| BOTNET | always targets the leader; saves KERNEL PANIC and DDOS for whoever is 1st |

## 5. Controls and driving

### 5.1 Controls

Auto-throttle. Combat needs both face buttons for weapons, and a booth
visitor should be racing before they have read anything.

| Input | Race | Menus |
|---|---|---|
| Left / Right | steer | move |
| Down | brake. With Left or Right: powerslide (less grip, faster yaw) | |
| Up | **BURST**: spend one burst charge for 60 ticks of +35% top speed | |
| A | fire the front weapon. Hold to auto-fire, or to charge the FIBER LANCE | confirm |
| Down + A | fire the rear weapon (drop behind) | |
| B | use the held pickup | back |
| Down + B | use the held pickup backward, for pickups that have a direction | |
| Select (hold) | **look back**: the camera turns 180 degrees while held, to aim rear drops | |
| Start | pause (Resume, Restart, Quit, Sound); in a link race it pauses both badges | |

When A or B is pressed with Down, that tick does not brake. Down acts as
"aim back", the Mario Kart convention. Throttle is always on during the
race, and Down is the only way to slow down. The race buttons fit in
8 bits (up, down, left, right, A, B, Start, Select), which is one byte of
link traffic per tick (section 7).

### 5.2 Driving model

The driving model is Zero's SPEC 5.1 (fixed point, heading and velocity
split, grip, speed-dependent steer rate), retuned from hover to wheels:

- Grip is higher: 0.70 normal (Zero 0.85), 0.88 in a powerslide, 0.97 on
  coolant. Cars corner tighter and slide only when you ask them to.
- Top speed is about 3.0 px/tick (180 px/s), slower than Zero's 3.6 so
  that aiming is possible. Burst takes it to about 4.0.
- Laps are 3,500 to 4,500 world pixels. A clean lap takes about 22 s, so a
  3-lap race runs about 70 s plus whatever combat costs.
- All constants live in one `tuning.zig`. Balance errs on the dangerous
  side (Adrian's standing rule): a careless player gets wrecked, and a
  wreck costs about two seconds, not the race.

### 5.3 Damage, wrecks, respawn

- **Armor** comes from the chassis, raised by PLATING (9.2). All damage
  subtracts from it. At 0 the car is **wrecked**: it explodes (hit-stop 12
  ticks, shake on the victim's own screen) and leaves a burning hulk for
  90 ticks that blocks like a wall.
- **Ramming** deals `relative_normal_speed * 6 * attacker_mass /
  victim_mass` damage. MAINFRAME's plough doubles its ram damage from the
  front quarter. The contact response is Zero's 5.3 (push apart, exchange
  30% of the normal velocity).
- **Respawn** is the same for every car, human or AI. A wrecked car comes
  back after the WATCHDOG delay (120 ticks base, 9.2) on the centerline
  sample nearest the wreck, with full armor, kept ammo and 60 ticks of
  immunity. The time lost is the penalty, and the killer gets a bounty
  (career: 150 CYCLES).
- **Smoke states** show armor at a glance: grey puffs below 50%, black
  smoke and sparks below 25%.
- **Kill feed**: one line under the top HUD for 60 ticks, e.g. `SYSADMIN >
  KIDDIE`. When the kill involves a human, a 24x24 half-scale portrait of
  the killer pops in a corner with their taunt line, or the victim's
  portrait with the wrecked line if the human did the killing. Hits on
  your target pop a small `ACK` above it, and hits on you flash the armor
  bar.

## 6. Weapons

Every number below is a starting point in `tuning.zig`. Ammo refills on
crossing the start line, as in Rock n' Roll Racing, so every lap is a
fresh fight. Projectiles inherit the firing car's velocity, die on walls
with a spark, and pass under airborne cars. A car's collision shape is a
circle of radius 10 world px.

### 6.1 Front weapons (A)

| Weapon | Joke | Behaviour | Dmg | Ammo / lap |
|---|---|---|---|---|
| **PING** | ICMP echo | twin pellets every 6 ticks while A is held, +5 px/tick muzzle speed, range 160 px; a hit shows `ACK` | 4 | 40 |
| **BROADCAST** | broadcast storm | 5-pellet fan of +-20 degrees, range 80 px; each pellet knocks the victim 0.4 px/tick sideways | 3 x5 | 10 |
| **FIBER LANCE** | fiber optics | hold A to charge 30 ticks (the car glows), release to fire a hitscan beam (drawn 6 ticks), range 300 px, the first car in a 4-degree line; an early release fizzles without costing ammo | 25 | 6 |
| **SPEAR PHISH** | spear phishing | auto-locks the nearest car in a 24-degree cone within 400 px (a fish-hook reticle sits on it); A fires a homing missile (turn rate 600 turns/tick, 180-tick life); with no lock it flies straight | 30 | 3 |

### 6.2 Rear weapons (Down + A)

| Weapon | Joke | Behaviour | Dmg | Ammo / lap |
|---|---|---|---|---|
| **MEMORY LEAK** | leaks memory | a puddle that grows from radius 6 to 18 over 180 ticks and lingers until tick 600; cars on it get coolant grip (0.97) and a yaw kick from the world PRNG | 0 | 3 |
| **LOGIC BOMB** | `if (car) boom()` | a proximity mine; arms after 30 ticks, triggers at 14 px, 24 px blast with push; the sprite shows `if` | 35 | 3 |
| **BIT ROT** | bits decay | 6 caltrops across 48 px of the lane; each hit deals damage and takes 20% off top speed for 60 ticks; the caltrop is consumed | 5 each | 4 |
| **FIREWALL** | a firewall, literally | a 64 px wall of flame across the track behind you for 120 ticks; 1 damage per tick inside; AIs steer round it if they can | 1/tick | 2 |

### 6.3 Pickups (RMA crates, B)

Driving through a crate starts a 45-tick roulette in the HUD pickup box,
captioned `FETCHING...`. The roll comes from the world PRNG at the
moment of contact, weighted by rank (6.4). A car holds one pickup and
drives through crates while full. Each pickup has a gag when it hits a
**human**. The gag is drawn on that human's own badge, so in a link race
you can blue-screen your friend's badge.

| Pickup | Tier | What it does | When it hits a human |
|---|---|---|---|
| **PREFETCH** | A | Instant boost: +40% top speed for 90 ticks, wall impact damage halved. "Loads the road before you get there." | n/a |
| **HONEYPOT** | A | A fake RMA crate, its label one shade off and a `?` flickering on odd frames. B throws it forward 60 px; Down+B drops it behind. Touching it: 30 damage and a spin. | the crate bursts into `<honey>` tags |
| **RUBBER DUCK** | A | A rubber duck on a tether behind you for 600 ticks. Homing weapons (SPEAR PHISH, DDOS drones, BIT FLIP) pick the duck instead, and it absorbs the first hit from behind. "Explain the bug to the duck. The duck takes the bullet." | n/a |
| **HOT PATCH** | A | Repairs 40 armor over 60 ticks without slowing ("no reboot required"). Clears BIT FLIP, DEADLOCK and smoke. | n/a |
| **SPAGHETTI CODE** | A | A 24 px tangle of cable, thrown ahead or dropped behind. A car driving through is slowed to 40% for 60 ticks, then drags a strand for 180 ticks at -10% top speed. | a cable strand trails from your car |
| **FORK BOMB** | B | Drops one `&` bomb behind you. Every 60 ticks each bomb forks in two and the children drift apart across the track (1, 2, 4, 8, capped at 8). 15 damage each on contact; they expire at tick 480. | n/a |
| **BIT FLIP** | B | A cosmic ray strikes the nearest car ahead within 400 px of progress and inverts its steering for 180 ticks. AIs weave on the line. | **Left and Right swap**; the HUD blinks `BIT FLIP` with a mirrored arrow and the view jitters 1 px |
| **DEADLOCK** | B | Chains the two nearest cars ahead to each other (a drawn chain line). Both are capped at 30% speed until they touch or 150 ticks pass. With only one car in range, it is chained to the nearest wall. | you crawl, chained to a rival |
| **DDOS** | B | 8 packet drones swarm the nearest car ahead and orbit it for 180 ticks: 2 damage per 30 ticks each, top speed -20%. Front weapons shoot drones down (1 HP each). | eight dots buzz round you; the speed reading stutters |
| **HEISENBUG** | B | You cannot be observed for 240 ticks: drawn on odd frames only, homing weapons cannot lock on, you pass through cars and drops, and AIs ignore you. | (on the other badge, a link rival flickers) |
| **RACE CONDITION** | B | Swaps position, velocity and heading with the next car ahead in progress if it is within 300 px: 6 frames of tearing on both sprites, then the swap. No damage, pure rank theft. | 6 frames of tearing, then you are behind them |
| **KERNEL PANIC** | C | A blue packet runs along the centerline at 2x top speed to the car in 1st (2nd if the user is 1st). Hit: 40 damage and 90 ticks frozen, the sprite blue with `:(` above it. | **the screen goes blue** for 30 ticks (`:(` and `YOUR RIG RAN INTO A PROBLEM`), then the race view returns while you are frozen |
| **CAPTCHA** | C | "Prove you're human." Every other car stops (speed clamped to 10%) under a 3x3 grid glyph. AIs "solve" it after 60 to 120 ticks, by character (KIDDIE slowest). | **you play it**: a 3x3 grid with traffic lights in some squares; press A on each lit square as the cursor sweeps, or wait 120 ticks; a fast solve frees you in about 40 |
| **SUDO** | C | Root for 300 ticks: invulnerable, +20% top speed, rams deal 40 damage and bounce the victim, drops you touch are destroyed without triggering. The car flashes, with `#` above it. | n/a |
| **ZERO-DAY** | C | The rarest roll: a hitscan dart that wrecks the nearest car ahead outright, through armor, RUBBER DUCK and HEISENBUG. Only rolls for 5th and 6th, at most once per car per race. | instant wreck; the feed reads `ZERO-DAY` |
| **PROMPT INJECTION** | league | Perimeter only, replacing one tier-B slot there. For 480 ticks every sentry within 300 px ignores its previous instructions and fires at the car nearest you instead of the leader (speech bubble `IGNORE PREV`). | n/a |

The CAPTCHA mini-game reads the victim's buttons through the simulation,
so it plays out the same on both badges of a link race.

### 6.4 Roll odds

Each roll picks a tier by the car's rank, then a pickup uniformly within
the tier. KERNEL PANIC is excluded for the car in 1st.

| Rank | A | B | C |
|---|---|---|---|
| 1st | 80 | 20 | 0 |
| 2nd | 50 | 45 | 5 |
| 3rd | 30 | 55 | 15 |
| 4th | 20 | 55 | 25 |
| 5th | 10 | 50 | 40 |
| 6th | 5 | 40 | 55 |

### 6.5 AI combat

Rival AI is Zero's centerline follower (lane offset, curvature speed
target, bounded rubber band), with three additions driven by the `Crew`
(4.3):

1. **Aim.** Pick a target by preference. Fire the front weapon when the
   target is inside the weapon's cone and range, after the reaction delay,
   with an aim jitter from the world PRNG. LANCE users charge on straights
   only; SPEAR PHISH users wait for a lock.
2. **Drop.** Drop the rear weapon when a car is within 120 px behind and
   within 16 px laterally of the line.
3. **Pickups.** Use each pickup by the crew policy: at once (KIDDIE), or
   on a trigger (HOT PATCH below 40% armor, RUBBER DUCK when a homing
   weapon locks on, RACE CONDITION within 60 px of the next car on the
   last lap). Tier C is always used at once.

AIs obey the same ammo, roll and pickup rules as humans. The only help
they get is Zero's bounded speed rubber band, which keys on progress
against the leading human.

## 7. Multiplayer: two badges, one race

### 7.1 Shape

Two badges joined by the link cable race in one field: two humans, plus
AI racers to fill the grid (`CREWS: 4 / 2 / 0`, default 4). Each badge
draws its own human's view, camera and HUD, and its own victim gags. The
world is the same on both.

### 7.2 Deterministic lockstep

The simulation is deterministic (no floats, clock or unseeded randomness
in `simulate`, and no idea of a "local" player: humans are car slots
whose input comes from a button stream). So the badges exchange only
buttons, and each one runs the identical simulation:

- The race starts from a shared setup (7.3): seed, track, mode, crew
  count, the two racers and the slot order. Both badges build the same
  `World`.
- **Input delay 2 ticks.** On frame f a badge samples its buttons as its
  input for tick f + 2 and sends them. It advances tick t only when it
  holds both humans' inputs for t. At 1 Mbaud one input packet takes about
  80 us on the wire, so 2 ticks (33 ms) covers it with a frame of slack.
- **The input packet** is 5 payload bytes (8 wire bytes, so one whole
  packet fits the 8-entry RX FIFO even if the cart polls only once that
  frame): `tick` (low 8 bits), buttons for `t`, `t-1`, `t-2` (one byte
  each, 5.1), and one `check` byte. Each packet repeats the two previous
  inputs, so a packet lost to a CRC drop is covered by the next one with
  no retransmit protocol.
- **Polling.** The cart calls `link.poll` at the top of `update`, between
  floor bands (every 16 rows), between the sprite and HUD passes, and in
  a loop while waiting for a partner input. The goal is that the worst gap
  between polls is shorter than one packet's wire time. M4 measures the
  real gap in the bench and moves the pump points to fit. An escaped byte
  (0xC0/0xDB in the payload) makes a 9th wire byte; the repeat covers the
  rare loss it causes.
- **Waiting.** When the partner's input for the next tick has not
  arrived, the badge redraws the last frame and keeps polling. After 30
  frames it shows `WAITING FOR PEER`. When the link reports the peer gone
  (`state != .connected`, 2 s timeout), the peer's car switches to its AI
  crew, `PEER LEFT, AI DRIVING` shows, and the race goes on solo.
- **Desync check.** The `check` byte carries one byte of a CRC8 over the
  `World`, recomputed every 32 ticks and sent a byte at a time. A
  mismatch shows `DESYNC` and ends the race on the results screen. The
  host soak (12) makes this a should-never; the check is what makes it
  visible if it ever happens.
- **Clock drift.** Each badge runs its own 60 Hz vsync. Lockstep makes
  the faster badge wait for the slower one by a frame now and then, which
  nobody notices.

### 7.3 Setup and menus

```
Menu -> LINK -> "PLUG IN THE CABLE" (link state: searching / connected, cable crossed/straight)
     -> connected: the badge with the higher HELLO nonce is HOST
HOST picks: mode (LINK RACE | LINK GC), track, CREWS 4/2/0
both pick a racer on the shared select screen (a racer taken by one is greyed for the other)
HOST presses A -> both run the countdown from the same tick
```

Setup messages are DATA packets with a kind byte in front: `SETUP`
(mode, track, crews, seed), `PICK` (racer, ready flag) and `GO` (start
tick). They go out while the menu runs, where the cart polls in a loop,
so packet size is not a concern there. A partner running a different
cart is told apart by the HELLO `app` byte (`'G'`). The career (CIRCUIT)
is single-player only.

In the simulator, LINK shows `NO LINK IN SIMULATOR` and stays greyed.
Host tests drive two simulations through `lib/link_virtual.zig` (12).

## 8. Modes

### 8.1 Flow

```
Splash (2 s, eyepatched Snouty portrait, SNOUTY GC / GARBAGE COLLECTION)
  -> Title ("Press Start"; 10 s idle -> Attract)
  -> Menu: QUICK RACE | GARBAGE COLLECTION | CIRCUIT | LINK | Sound: off
  -> Racer select (every mode) -> Countdown -> Race -> Results
```

**Racer select** is the first screen of every mode. Left and Right cycle
the six racers. The screen shows the 48x48 portrait at top left, the name
and car name to its right, the car sprite turning on a 5-yaw turntable
with three stat bars (SPD, ARM, DMG) beside it, the front and rear weapon
names, and the 4-line bio along the bottom. A confirms. In the career the
pick is kept for the whole circuit. Quick Race is two presses from the
title: Start, then A on the racer (Left and Right on the next row change
the track, which defaults to the next in rotation).

### 8.2 Modes

- **QUICK RACE**: 3 laps on one track against the five other racers.
- **GARBAGE COLLECTION** (knockout, *mark and sweep*): six cars, with a
  sweep at every half lap (the sector 2 line and the start line), so the
  mode ends after about 3 laps. At each sweep point the last car is
  **MARKED**: red outline, `MARKED` over the sprite. A marked car passes
  the mark on by landing any weapon hit on another car (tag). At the next
  sweep point the marked car is **COLLECTED**: a claw descends from the
  top of the screen and lifts it out, and the feed reads `GC: freed
  KIDDIE`. Then the new last car is marked. A wreck while marked is an
  immediate collection. The last car on the track wins. A collected human
  watches the rest from the leader's camera.
- **CIRCUIT** (career, single-player): a league's three tracks in order,
  points 9/6/4/3/2/1. CYCLES come from rank, kills and chips, and the
  garage (9.2) opens between races. Finishing the league in the top 3
  opens the next one; otherwise replay it with the CYCLES kept. AI racers
  upgrade on their own plans. Beating the last league ends on a text
  card: *"You reached the fence. The Hyperscalers did not notice."* State
  lives in RAM for the session (decision 6).
- **LINK**: LINK RACE (Quick Race rules) or LINK GC (Garbage Collection
  rules) against the badge on the other end of the cable (section 7).
- **Attract**: an AI-only race that a passer-by can watch, Snouty
  included. A scripted `KERNEL PANIC` hits the leader in lap 2, because a
  blue screen is what makes people stop at the booth.
- **Pause**: Resume, Restart, Quit, Sound. In a link race, Start on either
  badge pauses both (Start travels in the input byte, so pause is part of
  the lockstep), and Quit ends the race for both.
- **Results**: rank, time, best lap, kills, wrecks and CYCLES earned, each
  row with the racer's portrait at half scale. The winner's portrait is
  shown full size with their taunt.

## 9. Economy and garage (career)

### 9.1 CYCLES

| Source | CYCLES |
|---|---|
| Finish 1st..6th | 1000 / 600 / 400 / 250 / 150 / 100 |
| Wreck a car (last hit) | 150 |
| Cycle chip on the floor | 10 |
| Win a league | 1500 |

### 9.2 Garage slots

The garage upgrades your racer's own car. Its chassis and silhouette
belong to the racer and never change. The screen shows the car on a
turntable, the slot list and a price. Up and Down pick a slot, Left and
Right pick an item or level, A buys, and the racer's portrait gives a
one-line reaction to each purchase.

| Slot | Items / levels | Effect | Price |
|---|---|---|---|
| FRONT | PING, BROADCAST, FIBER LANCE, SPEAR PHISH, each L1-L3 | swap the gun, or level it: L2 +25% ammo, L3 +25% damage | 800 / L 400, 800 |
| REAR | MEMORY LEAK, LOGIC BOMB, BIT ROT, FIREWALL, each L1-L3 | swap or level: L2 +1 ammo, L3 +25% effect | 600 / L 300, 600 |
| PLATING (**ECC**) | L0-L3 | armor +30 per level; L3 corrects single-bit errors (any hit of 4 damage or less is ignored, so PING cannot chip you) | 500, 900, 1400 |
| CLOCK (engine) | L0-L3 | top speed +4% per level | 600, 1000, 1500 |
| TRACTION | L0-L3 | grip +0.03 per level | 400, 700, 1000 |
| BURST BUFFER | L0-L3 | burst charges per lap 1 / 2 / 3 / 4 | 400, 800, 1200 |
| **WATCHDOG** | L0-L3 | respawn delay 120 / 90 / 60 / 40 ticks ("reboots you faster") | 500, 900, 1300 |

AI racers spend on fixed per-racer plans (LEGACY: PLATING, then front L2,
never CLOCK; KIDDIE: CLOCK first, never PLATING; and so on), so that
career difficulty rises with the player's and stays deterministic.

## 10. Rendering

The renderer is Zero's 6.1 to 6.4: the row-loop Mode 7 floor (Zero's M0
measurement chose rows over columns), fog banks, the two-layer horizon
strip, back-to-front scaled sprites placed from the `d(y)` table, hills,
shake, and Zero's own 8x8 font blit. New here:

- **Sprite count.** Up to 6 cars, 48 projectiles, 32 drops, 8 drones and
  8 crates visible at once, depth-sorted into one list by screen row with
  a cap of 64 drawn objects per frame (the farthest are culled first).
- **Flat decals** (puddles, caltrops, spaghetti, fire-wall base, chips,
  crates seen from above) use a non-uniform scaled blit: full width
  scale, height scale times a squash factor, so they read as lying on the
  floor. This is one extra parameter on Zero's `blit_scaled`.
- **Beams and chains** (FIBER LANCE, DEADLOCK) are 1 to 2 px lines between
  two projected points, clipped to the floor region.
- **Cars**: six racer sprite sets, each with 5 yaw views (rear,
  rear-quarter, side; mirrored for the other side) at 32x16, a wreck
  frame, and the racer's head composited into the cockpit by the asset
  tool. A palette per car.
- **Portraits**: six 48x48 4-bit portraits, drawn 1:1 on the select,
  results and splash screens, and at half scale (24x24, the scaled blit)
  in the race taunt pop-up and on the results rows.
- **Look back** (Select held): the camera yaw turns 180 degrees, your own
  car is not drawn, and `BEHIND` sits over the horizon.
- **Effects** (explosions 4 frames at 24x24, sparks, smoke, muzzle flash,
  claw) are cosmetic: a render-side particle ring outside the `World`.
- **Human overlays**: the KERNEL PANIC blue screen, the CAPTCHA grid, the
  BIT FLIP column jitter (the floor's per-row x offset, which Zero's shake
  already has), and `WAITING FOR PEER` in a link race.
- **Horizon art** per league: monitor mountains and smoke (Dumps),
  cooling towers over a cracked horizon (Runoff), the black datacenter
  wall with Zero's palette-swap LED blink (Perimeter).

Screen layout:

```
y  0..7    LAP 2/3            3RD              [pickup box 16x16, top-right]
y  8..15   kill feed line (60 ticks); taunt pop-up 24x24 portrait + line, top-left, 90 ticks
y  0..31   horizon strip under the HUD text
y 33..127  floor
           player car centred x 80, bottom y 118; reticle on the locked target
           bottom-left: ARMOR bar (green->red, 40x4), front ammo count + rear ammo pips, burst pips
           bottom-right: 32x32 minimap, cars as 2x2 dots in livery colours,
             crates as 1 px yellow, the marked car blinking in GC mode
```

Zero's M5.2 lessons apply: nothing drawn closer than 4 px to a screen
edge, and menu rows centred on their longest line.

## 11. Architecture

The cart lives in `carts/snouty-gc/cart/src/` and **forks** Zero's engine
modules by copy, with a provenance comment at the top of each file. It
does not move them to `lib/`. Zero is shipped (and another session is
adding knockouts to it), so a refactor under it would need re-verifying
for no player-visible gain (decision 9). Zero's `history.zig` is not
copied: there is no rewind.

| Module | Origin | Notes |
|---|---|---|
| `fixed.zig`, `gen/sin.zig`, `font.zig`, `input.zig`, `camera.zig`, `hills.zig`, `packed_int_array.zig` | Zero | unchanged but for names |
| `render.zig` | Zero | floor, horizon, fog, shake; adds the per-row jitter used by BIT FLIP and the floor-band hook for link polling |
| `sprites.zig` | Zero | adds the non-uniform scale and the 64-object depth list |
| `track.zig` | Zero | adds crate rows, chips, vents, the sweeper lane and sentries from the `.track` file |
| `world.zig` | new | `Car` x6 (each with `racer`, `human` slot or AI), `Projectile` x48, `Drop` x32, `Drone` x8, crate timers, hazards, GC state, PRNG, clock; no pointers |
| `sim.zig` | Zero, extended | `simulate(world, inputs: [2]u8)`: driving, walls, contacts, ramming, damage, wrecks, respawn, laps, rank, GC sweeps |
| `racers.zig` | new | the roster table: names, cars, chassis, loadouts, bios, taunts, crew characters |
| `weapons.zig` | new | front and rear weapon tables and firing; projectile and drop updates; hit resolution |
| `pickups.zig` | new | roll, roulette, the 16 pickup effects, status timers (flip, chain, captcha, sudo, heisen) |
| `ai.zig` | Zero, extended | crews, aim, drop and pickup policies (6.5), the autopilot |
| `net.zig` | new | lockstep over `lib/link.zig`: setup messages, input ring, packet encode/decode, wait/peer-left, desync check |
| `hud.zig`, `menu.zig`, `select.zig`, `results.zig`, `garage.zig`, `career.zig` | Zero / new | `select.zig` is the racer select |
| `fx.zig` | new | render-side particles, outside the World |
| `tuning.zig` | Zero, extended | every number in sections 4 to 9 |

The `.track` format extends Zero's with feature words `crates`, `chips`,
`vent`, `sweeper` and `sentry:<side>`. The generator is
`tools/build_tracks.py` plus `tools/leagues.py`, forked from Zero, with
Dumps and Runoff tile vocabularies and the LZ map packer.
`tools/prepare_assets.py` draws the cars, portraits, weapons, pickup
icons and effects as code-drawn art. Snouty's portrait comes through
`snouty-art` (the study05 rig plus eyepatch layers).

Determinism rules hold from M0, because lockstep depends on them:
`simulate` is a pure function of `(World, inputs)`. Rendering only reads.
Status timers are World fields, and pickup effects are World state, never
render state. Which car a badge follows is render-side.

## 12. Verification

- **Host tests** (`zig build test`): Zero's set (trig, attribute lookups,
  `simulate` twice from one state equals byte-for-byte, lap counting),
  plus:
  - a scenario test per weapon and per pickup: a scripted world, a fixed
    number of ticks, asserts on the effect (FORK BOMB has 8 bombs at tick
    180 and none at 481; RACE CONDITION swaps exactly two cars; CAPTCHA
    frees an AI after its character's ticks; ECC L3 ignores a PING hit;
    HEISENBUG breaks a lock);
  - **every track completable**: the autopilot drives 3 laps on each
    track with combat off, without a wreck and within a time bound
    (Zero's content gate);
  - **chaos soak**: 20 seeded AI-only races with combat on all finish.
    No car is stuck for more than 600 ticks, and no pool overflows its
    cap. The same soak in GARBAGE COLLECTION ends with exactly one car;
  - **lockstep**: two `net` + `sim` instances joined by
    `link_virtual.zig` race 10 seeded link races with scripted inputs on
    both ends. The World CRC is equal on both at every tick. With 1%
    injected byte loss they still finish in sync. Unplugging the cable
    mid-race hands the car to the AI on the surviving side;
  - every racer's bio fits 4 lines of 19 characters, and every taunt
    fits its pop-up.
- `zig build check-float`.
- Headless `preview.mjs` scripts under `tools/scripts/`: title to race,
  the racer select across all six, a KERNEL PANIC on the player, a CAPTCHA
  solve, a GC sweep, a wreck and respawn. PNG and `frames.json` checks.
- **badge-bench** before and after every milestone, worst frame recorded
  in `PLAN.md`, always also run with `--lcd`. The stress scene has all six
  cars on screen, a full FORK BOMB, a DDOS swarm, the FIREWALL and two
  explosions, on Outflow Canyon. From M4, the bench also reports the
  worst gap between link polls.
- Link races need two badges and a cable. Per the standing rule, that
  hardware check never gates a milestone; the virtual-cable soak is the
  gate.
- A review GIF in `docs/` per milestone, and a merge to main as soon as a
  milestone is badge-ready.

## 13. Performance and memory budget

### 13.1 Frame time

The reference is Zero's calibrated bench: mean 2.09 ms, worst 4.81 ms,
where Zero's worst frame was its rewind replay, which this cart doesn't
have.

| Piece | Estimate |
|---|---|
| Floor + horizon (Zero, measured) | about 2.0 ms |
| Sprites: 6 cars + up to 58 small objects, decals squashed | 0.6 to 1.0 ms |
| HUD, minimap, feed, pickup box, taunt pop-up | 0.4 ms |
| `simulate`: 6 cars x (48 + 32 + 8) circle tests, homing, AI aim | 0.15 ms |
| Link polls and packet work | under 0.05 ms |
| Worst case | about 3.6 ms, 22% of budget |

The target is **60 fps with a worst frame under 8 ms** in the calibrated
bench. That leaves room for a link frame that catches up a tick (two
`simulate` calls in one frame).

### 13.2 RAM (the hard wall)

| Item | Estimate |
|---|---|
| Code (forked engine + combat, AI, net, menus, garage) | 125 KB |
| Two league tilesets (Dumps, Runoff), 128 tiles at 8 bpp | 16 KB |
| Two horizon strips | 24 KB |
| Six LZ-packed maps | 24 KB |
| Centerlines + attributes | 13 KB |
| Car sprite sets (6 x 5 yaws + wreck at 4 bpp) | 9 KB |
| Portraits (6 x 48x48 at 4 bpp) | 7 KB |
| Weapons, pickups, icons, effects at 4 bpp | 8 KB |
| `.text` + `.rodata` | about 226 KB |
| `.bss`: unpacked map 16 KB, World + net + fx + misc 8 KB | about 24 KB |
| Total with 32 KB stack | about 282 KB of 307 KB |

Dropping rewind removed the history (about 38 KB in the first draft), so
the two-league cart fits with about 25 KB to spare. The Perimeter league
(8 KB tiles, 12 KB horizon, 12 KB maps) would take about 32 KB, so it
needs one cut: a 4 bpp horizon back layer (6 KB), shared Runoff and
Perimeter tiles, or less code. M0 measures the real numbers (section 18).

## 14. Repo layout

`carts/snouty-gc/` contains `cart/src/*.zig`, `cart/src/tracks/*.track`,
`cart/build/convert_gfx.zig` (per-cart copy), `assets/gen/`, `tools/`,
`docs/RUNNING.md`, `PLAN.md`, `SPEC.md` and `ASSETS.md`, with a
`build.zig` exposing `pub fn add`. The root `build.zig` lists it. The
bench config is `badge-bench/carts/snouty-gc.toml`. The binary is
`snouty-gc`, and the RAM UF2 is the shipped artifact. The link library
comes from `lib/` once `link/m0` is on main. Until then, the cart builds
without `net.zig`.

## 15. What makes it ours

- **Weapons that are jokes you can play.** FORK BOMB grows exponentially
  on screen, RACE CONDITION steals a place, CAPTCHA makes the humans prove
  they are human, and KERNEL PANIC blue-screens the leader. In a link race
  the gags land on your friend's badge.
- **A cast.** Six racers with faces and lines, among them a one-eyed
  anteater who lost the eye to a heisenbug.
- **GARBAGE COLLECTION, mark and sweep**, a knockout mode where the mark
  passes by shooting someone, and the best mode for two badges.
- **Two badges, one deterministic world.** The link carries a byte of
  buttons per tick and nothing else. Both badges compute the same race,
  and a CRC check proves it. That is the Antithesis idea, deterministic
  simulation, used as netcode.
- **The setting.** The AIs aren't villains; they don't notice us. The
  hazards are their maintenance, and their sentries punish the leader
  because the leader is the anomaly.

Kept out on purpose: rewind (for now, see 17.7), more than two badges,
ghosts and replay export (parked in `docs/REPLAY.md`), new audio, flash
saves.

## 16. Milestones

Each milestone gets a tag `snouty-gc/mN`, a review GIF in `docs/`,
pull-and-run notes and badge-bench numbers in `PLAN.md`. Opus agents take
the tracks in worktrees with disjoint files where a milestone splits.
Merge to main as soon as a milestone is badge-ready.

- **M0 Fork**: scaffold `carts/snouty-gc` from Zero (copied modules, root
  build, bench toml); the Dumps tileset at 128 tiles and Landfill Loop;
  auto-throttle wheeled driving; six cars in placeholder liveries driving
  Zero's AI with no weapons; `simulate(world, [2]u8)` with human slots;
  section 18 answered. In parallel, the **art track** draws the six
  portraits (Snouty's eyepatch first), the six car sprite sets and the
  weapon, pickup and effect sheets. **Done when:** a 6-car race runs in
  the simulator, the completable and determinism tests pass, and the bench
  and RAM figures are in `PLAN.md`.
- **M1 Guns and racers**: the roster, the racer select with portraits and
  bios, each racer's own car and loadout; armor, damage, ramming, wrecks,
  hulks, respawn, smoke; all 4 front and 4 rear weapons; projectile and
  drop pools; reticle, beam, decals; kill feed, `ACK`, taunt pop-ups; AI
  aim and drop. **Done when:** a 3-lap Quick Race with any racer is a real
  fight, the weapon scenario tests pass, and the stress scene (guns only)
  is under budget.
- **M2 Pickups**: crate rows, roulette, rank odds, the 15 non-league
  pickups and the human gags (blue screen, BIT FLIP, CAPTCHA mini-game),
  AI pickup policies. **Done when:** every pickup's scenario test and the
  chaos soak pass, and the GIF shows FORK BOMB, KERNEL PANIC on the player
  and a CAPTCHA solve.
- **M3 Content and flow**: GARBAGE COLLECTION with mark, sweep and claw;
  six tracks over Dumps and Runoff with their hazards (Sweeper, vents);
  look back; splash, title, attract (with its scripted KERNEL PANIC),
  menus, pause, results. **Done when:** all six tracks are completable,
  the GC soak ends with one car, and the cart is merged to main.
- **M4 Link**: `net.zig` lockstep, link setup, LINK RACE and LINK GC,
  waiting, peer-left, desync check, bench poll-gap measurement. Needs
  `lib/link.zig` on main; if it isn't there yet, M5 goes first. **Done
  when:** the virtual-cable soak passes (lossless and with 1% loss), and
  the hand-off says how to cable two badges.
- **M5 Circuit and polish**: CYCLES, chips, the garage with portrait
  reactions, AI upgrade plans, standings, the league unlock; bench profile
  and fast paths; a balance pass that errs dangerous. **Done when:** a full
  two-league circuit is playable start to finish.
- **M6 Stretch** (pick with Adrian): the Perimeter league (sentries,
  PROMPT INJECTION, the ending card) behind the RAM cut in 13.2; a `KILL
  -9` arena battle mode (one open Mode 7 arena, pickups only, last car
  running, best on two badges); rewind back for single-player (17.7); a
  Tufty port (on the `tufty` branch, as the other carts were).

## 17. Decisions (taken by default, 2026-10-04)

1. **Name**: `snouty-gc`, title **SNOUTY GC**, subtitle `GARBAGE
   COLLECTION`.
2. **Controls**: auto-throttle, A front fire, Down+A rear, B pickup, Up
   burst, hold Select to look back. The alternative is A throttle, B fire,
   Up pickup, with rear weapons as pickups only: closer to Mario Kart, but
   it loses the equipped rear slot and leaves no button for burst.
3. **Six racers, six cars**, no traffic. Each racer has a fixed car
   (chassis and starting loadout), and the career upgrades that car.
4. **Ammo refills per lap** (Rock n' Roll Racing), not bought per race.
5. **One held pickup**, Mario Kart tier odds by rank, ZERO-DAY limited to
   the back two places and once per car per race.
6. **Career state in RAM only**: no flash saves, same as Zero.
7. **No rewind** (Adrian, 2026-10-04). When it returns it is
   single-player only. Zero's `history.zig` drops back in, because the
   World stays plain data with no pointers. In a link race it would need
   both badges to agree, which is a different feature.
8. **Wreck = respawn after the WATCHDOG delay** for every car, outside GC
   mode.
9. **Fork Zero's engine by copy**, not a shared `lib/mode7`; Zero stays
   untouched.
10. **Perimeter league is a stretch goal** behind the RAM cut. Two
    leagues and six tracks ship first.
11. **Sound**: Zero's engine drone and tones behind the off-by-default
    toggle, nothing new.
12. **Balance errs dangerous**: rivals can wreck a careless player in
    about 6 PING bursts or two LOGIC BOMBs.
13. **Two badges, two humans**, AI fills the grid. Lockstep with a 2-tick
    input delay and inputs repeated three times. Host = the higher HELLO
    nonce. The career is single-player.
14. **Racer roster and bios as in 4.1.** Snouty wears the eyepatch over
    the left eye.

## 18. Facts to check in M0

- The real `.text` and `.bss` of a Zero fork with Zero's nine tracks,
  three leagues and history stripped: the true room for combat code, the
  portraits and the six new tracks against 13.2.
- `@sizeOf(World)` with the packed pools (a CRC over it every 32 ticks
  must stay cheap).
- The sprite cost of 64 small objects with the non-uniform blit, against
  the 1 ms estimate (measured in the M1 stress scene).
- That holding Select alone triggers nothing in the current upstream OS
  (only the Start+Select chord is taken).
- From the link session: whether `lib/link.zig` lands on main with the
  same API (`init`, `poll`, `send`, `recv`, `connected`, `nonce`,
  `partner_nonce`, `session`) before M4 starts.

## Status

- 2026-10-04: first draft (ee52bffc). Same day, revised to Adrian's
  notes: rewind dropped, two-badge link multiplayer added, racer select
  with portraits, personalities and own cars, Snouty with an eyepatch.
  Build approved; `PLAN.md` comes with M0.
