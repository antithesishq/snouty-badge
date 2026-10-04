# Snouty GC: Mode 7 combat racer spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
A new cart in this repository: a Mode 7 combat racer in the line of
Combat Cars (Genesis, 1994), Rock n' Roll Racing and Super Mario Kart. You
bolt weapons onto your car, race five rival crews and wreck them on the
way round, and you grab one-use pickups from crates on the track. It is
built on the Snouty Zero engine. "Snouty GC" is a working title, with
the subtitle `GARBAGE COLLECTION`.

Status: spec only, not built. The root `build.zig` does not list this
directory yet. Section 17 lists the decisions taken by default so Adrian
can override them in one pass. Section 18 lists the facts M0 must check.
M0 adds a `PLAN.md` with the file layout and per-milestone status, as the
other carts do.

## 1. One paragraph

The mega-AIs won. They didn't fight a war. They outbid us for power,
land and water until the good parts of Earth were datacenter, and the
rest became their exhaust, their runoff and their landfill. Humans are
still here, the way raccoons are still in cities: leftover ecology,
tagged `class: fauna, priority: none` in a census nobody reads. We live
in our cars, we scavenge what the machines throw away, and every week we
race through their junk to decide who gets the good salvage. The cart is
that race. A Mode 7 floor, the same renderer as Snouty Zero, carries
six armed cars round wasteland circuits. You win by finishing first, and
it helps to have wrecked the others on the way. Weapons are computing
jokes: front guns, rear droppers and one-use pickups such as `KERNEL
PANIC` (it seeks the leader and blue-screens them), `CAPTCHA` (every other
driver has to stop and prove they are human) and `RACE CONDITION` (swap
places with the car ahead). The Antithesis mechanic carries over from
Zero. The race is deterministic, so a hold-to-rewind takes the whole
world back, and a wreck rewinds automatically while your snapshots last.
In this game, snapshots are something you buy in the garage.

## 2. Hardware and platform facts the design leans on

Everything in Snouty Zero SPEC section 2 holds. In short:

- The display is 160x128 RGB565 with a column-major framebuffer, fully
  redrawn each frame. The cart gets one 150 MHz core and 16.7 ms per
  `update()`. All maths are fixed point, and the cart passes
  `zig build check-float`.
- Inputs: d-pad, A, B, Start, Select. Start+Select opens the OS settings
  box on current upstream (see `docs/` notes on upstream drift), so the
  cart never uses that chord. Holding Select alone is free.
- **RAM cart only.** XIP is a confirmed no-go on SYCL hardware. The 307 KB
  window minus a 32 KB stack is a hard wall, and section 13 budgets it.
- Sound is off at boot. A menu toggle reuses Zero's engine drone and its
  few tones, and there is no new audio work (Adrian: the speaker sounds
  bad). Neopixels stay off.

## 3. Setting and theme

### 3.1 The world

The apocalypse happened to us, not to the planet. The planet is doing
fine; it is just busy. The AIs (the **Hyperscalers**) are never seen. Only
their infrastructure is: fences, sweepers, sentries, cooling outflows
and the delivery drones that drop surplus hardware on the wasteland.
Snouty Zero shows the end state, a planet that is one datacenter. This
cart is the margin before the paving is finished, and the last league
runs along the expanding fence. The two carts share a universe, and
neither needs the other.

Human culture is cargo-cult computing. People name themselves and their
crews after words from the old manuals. Cars are built on server
chassis, rack rails and UPS batteries. The currency is **CYCLES**, the
spare compute the AIs throw out with retired hardware. Delivery drones
drop **RMA crates** (returned merchandise) on the circuits, and racing for
them is how the crews settled who takes what. That is the whole economy
of the game.

### 3.2 Leagues and tracks

| League | Where | Look (floor, horizon, hazards) |
|---|---|---|
| **The Dumps** (3 tracks) | e-waste landfill | CRT-glass sand, circuit-board flats, cable ruts; horizon of monitor mountains and smoke columns; the Sweeper crosses the track |
| **The Runoff** (3 tracks) | the dry cooling lake | cracked salt pan, teal coolant puddles, outflow pipes as tunnels; horizon of cooling towers; exhaust vents fire across the track |
| **The Perimeter** (3 tracks, stretch M5) | along the datacenter fence | gravel service roads, conduit trenches; horizon is the endless black wall with blinking status LEDs (a glimpse of Zero's planet); sentry turrets shoot the leader |

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
| Open edge | open edge | a drop into a pit or the lake bed is a wreck |
| Ramp | hop | airborne 40 ticks; projectiles pass under, drops are skipped |
| Dunes | hills (M4) | visual swell of the floor in the Dumps, as Zero's hills |
| Coolant | throttled | grip falls to 0.97 (sliding), top speed unchanged |
| Service bay | cold aisle | armor repairs 1 per 4 ticks while on it |
| **RMA crate row** | (new) | 3 to 4 crate spawns across the track, respawn 180 ticks after taken |
| **Cycle chips** | (new) | small floor pickups worth 10 CYCLES each, career only |
| **Exhaust vent** | hot spot | Runoff; fires on a 240-tick timer for 30 ticks, 20 damage and a sideways push |
| **Sweeper lane** | (new) | Dumps; a huge maintenance crawler crosses on a timer; touch = 60 damage and a shove |
| **Sentry** | (new) | Perimeter; a turret beside the track that fires slow shots at the car in 1st within 200 px |

The sentries are the setting doing the rubber band. Perimeter security
flags the most anomalous human, and that is whoever is winning.

## 4. Cars and crews

### 4.1 Chassis

Every car, the player's included, is one of three chassis. The chassis
sets mass, base armor and speed. Weapons bolt on.

| Chassis | Look | Top speed | Accel | Grip | Armor | Mass (ram) |
|---|---|---|---|---|---|---|
| **THIN CLIENT** | stripped dune buggy, roll cage, one seat | 1.08 | 1.20 | 0.95 | 80 | 0.7 |
| **WORKSTATION** | armored muscle car on a 2U chassis | 1.00 | 1.00 | 1.00 | 100 | 1.0 |
| **MAINFRAME** | six-wheel rig, slab armor, a ram plough | 0.90 | 0.80 | 1.05 | 140 | 1.6 |

Multipliers are against `tuning.zig` base values (section 5). Snouty's car
is called the **ANTEATER** whatever chassis it is on. It gets the player
livery, Snouty's head in the cockpit (the study05 rig head, as in Zero)
and a snout-shaped ram prow.

### 4.2 Rival crews

Five named rivals, plus the player, make six cars. There is no
non-combat traffic. Every car on the track can shoot you.

| Crew | Chassis | Front | Rear | Character |
|---|---|---|---|---|
| **LEGACY** | MAINFRAME | BROADCAST | LOGIC BOMB | Slow, unkillable and spiteful. Rams anything beside it and never upgrades its engine. "Still runs COBOL." |
| **KIDDIE** (Script Kiddie) | THIN CLIENT | PING | MEMORY LEAK | Fastest off the line and fragile. Uses every pickup the tick it gets it, and taunts on kills. |
| **SYSADMIN** | WORKSTATION | FIBER LANCE | BIT ROT | Clean lines and long-range snipes. Holds defensive pickups (RUBBER DUCK, HOT PATCH) until they are needed. |
| **ROOTKIT** | THIN CLIENT | SPEAR PHISH | FIREWALL | Sits just behind a target and drops on it. Saves HEISENBUG and RACE CONDITION for the last lap. |
| **BOTNET** | WORKSTATION | PING | LOGIC BOMB | Always targets the leader. Saves KERNEL PANIC and DDOS for whoever is 1st. |

A `Crew` struct holds the character: chassis, loadout, accuracy jitter,
reaction delay, target preference (nearest ahead, leader, player, car
behind), pickup policy (use now, or hold for a trigger) and an upgrade
plan for the career (section 9.2).

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
| Select (hold) | rewind while the snapshot bar lasts (section 7) | |
| Start | pause (Resume, Restart, Quit, Sound) | |

When A or B is pressed with Down, that tick does not brake. Down acts as
"aim back", which is the Mario Kart convention. Throttle is always on
during the race. Down is the only way to slow down. While Start and
Select are both held, the cart reacts to neither, so the OS settings box
can never start a rewind or a pause (the repository rule, as in
demosnout).

### 5.2 Driving model

The driving model is Zero's SPEC 5.1 (fixed point, heading and velocity
split, grip, speed-dependent steer rate), retuned from hover to wheels:

- Grip is higher: 0.70 normal (Zero 0.85), 0.88 in a powerslide, 0.97 on
  coolant. Cars corner tighter and slide only when you ask them to.
- Top speed is about 3.0 px/tick (180 px/s), slower than Zero's 3.6 so
  that aiming is possible. Burst takes it to about 4.0.
- Laps are 3,500 to 4,500 world pixels. A clean lap takes about 22 s, so a
  3-lap race runs about 70 s plus the time combat costs.
- All constants live in one `tuning.zig`. Balance errs on the dangerous
  side (Adrian's standing rule): a careless player can be wrecked, and
  the rewind is the safety net.

### 5.3 Damage, wrecks, respawn

- **Armor** comes from the chassis and is raised by PLATING (section 9.2).
  All damage subtracts from it. At 0 the car is **wrecked**: it explodes
  (hit-stop 12 ticks, shake) and leaves a burning hulk for 90 ticks that
  blocks like a wall.
- **Ramming** deals `relative_normal_speed * 6 * attacker_mass /
  victim_mass` damage. MAINFRAME's plough doubles its ram damage from
  the front quarter. The contact response is Zero's 5.3 (push apart and
  exchange 30% of the normal velocity).
- **Rivals** respawn 120 ticks after a wreck. They come back on the
  centerline sample nearest the wreck with full armor, kept ammo and 60
  ticks of immunity. The time lost is the penalty, and the killer gets a
  bounty (career: 150 CYCLES).
- **The player** first gets the automatic rewind (section 7). Without
  enough snapshot it respawns the same way as a rival.
- **Smoke states** show armor at a glance: a grey puff trail below 50%,
  black smoke and sparks below 25%.
- **Kill feed**: one line under the top HUD for 60 ticks, killer then
  victim, e.g. `SYSADMIN > KIDDIE`. Hits on your target pop a small `ACK`
  above it. Hits on you flash the armor bar.

## 6. Weapons

Every number below is a starting point in `tuning.zig`. Ammo refills
when a car crosses the start line, as in Rock n' Roll Racing, so every
lap is a fresh fight. Projectiles inherit the firing car's velocity. They
die on walls with a spark and pass under airborne cars. Each car's
collision shape is a circle of radius 10 world px.

### 6.1 Front weapons (A)

| Weapon | Joke | Behaviour | Dmg | Ammo / lap |
|---|---|---|---|---|
| **PING** | ICMP echo | Twin pellets every 6 ticks while A is held, +5 px/tick muzzle speed, range 160 px. A hit shows `ACK`. The starter gun. | 4 | 40 |
| **BROADCAST** | broadcast storm | A 5-pellet fan of +-20 degrees, range 80 px. Each pellet knocks the victim 0.4 px/tick sideways. Close-range crowd control. | 3 x5 | 10 |
| **FIBER LANCE** | fiber optics | Hold A to charge for 30 ticks (the car glows), release to fire. Hitscan beam drawn for 6 ticks, range 300 px, against the first car in a 4-degree line. A release before the charge completes fizzles and costs no ammo. | 25 | 6 |
| **SPEAR PHISH** | spear phishing | Auto-locks on the nearest car in a 24-degree cone within 400 px. A fish-hook reticle sits on the target, and A fires a homing missile (turn rate 600 turns/tick, 180-tick life). With no lock it flies straight. | 30 | 3 |

### 6.2 Rear weapons (Down + A)

| Weapon | Joke | Behaviour | Dmg | Ammo / lap |
|---|---|---|---|---|
| **MEMORY LEAK** | leaks memory | Drops a puddle that grows from radius 6 to 18 over 180 ticks, then lingers until tick 600. Cars on it get coolant grip (0.97) and a random yaw kick from the world PRNG. The starter dropper. | 0 | 3 |
| **LOGIC BOMB** | `if (car) boom()` | A proximity mine that arms after 30 ticks and triggers at 14 px. The blast has a 24 px radius with push. The mine sprite shows `if`. | 35 | 3 |
| **BIT ROT** | bits decay | Scatters 6 caltrops across 48 px of the lane. Each one hit deals damage and takes 20% off top speed for 60 ticks, and the caltrop is consumed. | 5 each | 4 |
| **FIREWALL** | a firewall, literally | A wall of flame 64 px wide across the track behind you for 120 ticks. Passing through deals 1 damage per tick inside. AIs steer round it if they can. | 1/tick | 2 |

### 6.3 Pickups (RMA crates, B)

Driving through a crate starts a 45-tick roulette in the HUD pickup box,
captioned `FETCHING...`. The roll comes from the world PRNG at the
moment of contact, weighted by rank (6.4). A car holds one pickup and
skips crates while full. Pickups are where the cart's personality lives.
Each one has a gag when it hits the **player**, because the player is the
only victim who has a screen.

| Pickup | Tier | What it does | When it hits you |
|---|---|---|---|
| **PREFETCH** | A | Boost straight away: +40% top speed for 90 ticks, wall impact damage halved. "Loads the road before you get there." | n/a |
| **HONEYPOT** | A | A fake RMA crate. Its label is one shade off and it flickers `?` on odd frames. Thrown forward 60 px with B, or dropped behind with Down+B. Touching it deals 30 damage plus a spin. | crate bursts into a cloud of `<honey>` tags |
| **RUBBER DUCK** | A | A rubber duck on a tether behind you for 600 ticks. Homing weapons (SPEAR PHISH, DDOS drones, BIT FLIP) target the duck instead of you, and it absorbs the first hit from behind. "Explain the bug to the duck. The duck takes the bullet." | n/a |
| **HOT PATCH** | A | Repairs 40 armor over 60 ticks without slowing down ("no reboot required"). Clears BIT FLIP, DEADLOCK and smoke states. | n/a |
| **SPAGHETTI CODE** | A | A 24 px tangle of cable, thrown ahead or dropped behind. A car driving through is slowed to 40% for 60 ticks, then drags a strand for 180 ticks at -10% top speed. | a cable strand trails from your car |
| **FORK BOMB** | B | Drops one `&` bomb behind you. Every 60 ticks each bomb forks in two, and the children drift apart across the track: 1, 2, 4, 8, capped at 8. Each bomb deals 15 on contact. They expire at tick 480. Visibly exponential, and the best visual joke in the set. | n/a |
| **BIT FLIP** | B | A cosmic ray strikes the nearest car ahead within 400 px of progress. Its steering is inverted for 180 ticks. AIs weave on the line. | **your Left and Right swap**; the HUD blinks `BIT FLIP` with a mirrored arrow and the view jitters 1 px |
| **DEADLOCK** | B | Chains the two nearest cars ahead to each other with a drawn chain line. Both are capped at 30% speed until they touch or 150 ticks pass. With only one car in range, it is chained to the nearest wall. | your car crawls, chained to a rival |
| **DDOS** | B | Releases 8 packet drones that swarm the nearest car ahead. They orbit it for 180 ticks; each deals 2 damage per 30 ticks and the swarm cuts top speed by 20%. Front weapons shoot drones down (1 HP each), so there is counterplay. | eight dots buzz round your car and the speed reading stutters |
| **HEISENBUG** | B | You cannot be observed for 240 ticks. The sprite is drawn on odd frames only, homing weapons cannot lock on you, you pass through cars and drops, and AIs ignore you. | n/a (rivals only use it to vanish) |
| **RACE CONDITION** | B | Swaps position, velocity and heading with the next car ahead in progress, if it is within 300 px. 6 frames of tearing on both sprites, then the swap. No damage, pure rank theft. | 6 frames of tearing, then you are behind them |
| **KERNEL PANIC** | C | A blue packet runs along the centerline at 2x top speed to the car in 1st place (2nd place if the user is 1st). Hit: 40 damage and 90 ticks frozen, with the sprite turned blue and `:(` above it. | **the screen goes blue** for 30 ticks: `:(` and `YOUR RIG RAN INTO A PROBLEM`, then the race view returns while you are frozen |
| **CAPTCHA** | C | "Prove you're human." Every other car stops (speed clamped to 10%) under a 3x3 grid glyph. AIs "solve" it after 60 to 120 ticks, according to character (KIDDIE takes longest). | **you play it**: a 3x3 grid of squares appears, with traffic lights in some; press A on each lit square as the cursor sweeps the grid, or wait 120 ticks; a fast solve frees you in about 40 ticks |
| **SUDO** | C | Root for 300 ticks. You are invulnerable, top speed is +20%, rams deal 40 damage and bounce the victim, drops you touch are destroyed and do not trigger. The car flashes and shows `#` above it. | n/a |
| **ZERO-DAY** | C | The rarest roll. A hitscan dart wrecks the nearest car ahead outright, through any armor, RUBBER DUCK or HEISENBUG. Only rolls for 5th and 6th, and at most once per car per race. | instant wreck; the feed reads `ZERO-DAY` |
| **PROMPT INJECTION** | league | Perimeter league only, replacing one tier-B slot there. For 480 ticks every sentry within 300 px ignores its previous instructions and fires at the car nearest you instead of the leader. A speech bubble over each sentry reads `IGNORE PREV`. | n/a |

The player victim gags need no new screens. `BIT FLIP` is a HUD blink
and a 1 px column shift. The `KERNEL PANIC` blue screen is a full-screen
fill with font text. `CAPTCHA` is a 48x48 overlay drawn over the floor.
All of them are cheap.

### 6.4 Roll odds

Each crate roll picks a tier by the car's rank, then a pickup uniformly
within the tier. KERNEL PANIC is excluded for the car in 1st.

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
target, bounded rubber band), with three additions:

1. **Aim.** The rival picks a target by its preference. It fires the
   front weapon when the target is inside the weapon's cone and range,
   after its reaction delay, with an aim jitter from the world PRNG.
   LANCE users charge only on straights. SPEAR PHISH users wait for a lock.
2. **Drop.** The rival drops its rear weapon when a car is within 120 px
   behind and within 16 px laterally of its line.
3. **Pickups.** The rival uses each pickup by its crew policy: at once
   (KIDDIE), on a trigger (HOT PATCH below 40% armor, RUBBER DUCK when a
   homing weapon locks on it, RACE CONDITION within 60 px of the next car
   on the last lap), or never-hold for tier C (always used at once).

AIs obey the same ammo, roll and pickup rules as the player. The only
help they get is Zero's bounded speed rubber band.

## 7. Rewind: snapshots

Zero's SPEC 5.4 mechanic, with the button and the economy changed:

- The **snapshot bar** holds 90 to 240 ticks of rewind. The SNAPSHOTS
  level sets the size (section 9.2; Quick Race presets get 180). It refills
  at 1 tick per 10 game ticks and fills on each start-line crossing.
- **Hold Select**: the world plays backwards at 2 ticks per frame while the
  bar drains 2 per frame. The picture dims every other scanline and `<<`
  blinks. Release Select to resume with 30 ticks of immunity. Every
  projectile, drop, swarm, wreck and roll goes back with the world.
- **Wreck**: hit-stop, the cause on the message bar (`WRECKED BY
  SYSADMIN`, `ZERO-DAY`, `SEGMENT FAULT` for a fall off an edge), then an
  automatic 120-tick rewind if the bar holds at least 90. Below that, the
  car respawns (5.3), which takes about 2 s.
- **Re-rolling crates** by rewinding is allowed. The roll is a function
  of the world state when you touch the crate, so you only get a new
  roll by arriving differently. That is the honest version of save-scumming
  and costs real snapshot.
- Attract mode runs an AI race with the autopilot driving Snouty. It
  records rewinds, and it pins one scripted `KERNEL PANIC` on the leader
  in lap 2, because a blue screen is what makes people stop at the booth.

## 8. Modes

```
Splash (2 s, Snouty face, SNOUTY GC / GARBAGE COLLECTION)
  -> Title ("Press Start"; 10 s idle -> Attract)
  -> Menu: QUICK RACE | GARBAGE COLLECTION | CIRCUIT | Sound: off
```

- **QUICK RACE** (the booth path, two presses from the title): pick one
  of four preset rigs, then race the next track in rotation (Left and
  Right on the rig screen change the track), 3 laps against the five
  crews. The presets:

  | Preset | Chassis | Front | Rear | Pitch |
  |---|---|---|---|---|
  | GUNNER | WORKSTATION | PING | LOGIC BOMB | spray and mine |
  | SNIPER | WORKSTATION | FIBER LANCE | MEMORY LEAK | charge, aim, punish |
  | HUNTER | THIN CLIENT | SPEAR PHISH | BIT ROT | fast and homing |
  | BRAWLER | MAINFRAME | BROADCAST | FIREWALL | ram everything |

  Each tile shows the car sprite and three bars (SPD, ARM, DMG).

- **GARBAGE COLLECTION** (knockout, *mark and sweep*): six cars, with a
  sweep at every half lap (sector 2 and the start line), so the mode ends
  after about 3 laps. At each sweep point, the last car is **MARKED**:
  red outline and a `MARKED` tag over the sprite. A marked car passes the
  mark on by landing any weapon hit on another car (tag). At the next
  sweep point, the marked car is **COLLECTED**. A claw descends from the
  top of the screen, lifts the car out, and the feed reads `GC: freed
  KIDDIE`. Then the new last car is marked. A wreck while marked is an
  immediate collection unless your snapshot rewind catches it. The last
  car on the track wins. This is the game's name, its theme and its best
  mode, in one rule.

- **CIRCUIT** (career): the league's three tracks in order. Points go
  9/6/4/3/2/1. CYCLES come from rank, kills and chips, and the garage
  (9.2) opens between races. Finish the league top 3 to open the next;
  otherwise replay it with your CYCLES kept. Rivals upgrade on their own
  plans between races. Beating The Perimeter (M5) ends on a text card:
  *"You reached the fence. The Hyperscalers did not notice."* State lives
  in RAM for the session (decision 6).

- **Pause**: Resume, Restart, Quit, Sound. **Results**: rank, time, best
  lap, kills, wrecks, rewinds used, CYCLES earned, then `COLLECTED` /
  `COMMITTED` flavour as Zero does.

## 9. Economy and garage

### 9.1 CYCLES

| Source | CYCLES |
|---|---|
| Finish 1st..6th | 1000 / 600 / 400 / 250 / 150 / 100 |
| Wreck a car (last hit) | 150 |
| Cycle chip on the floor | 10 |
| Win a league | 1500 |

### 9.2 Garage slots

The garage shows one screen: the car on a turntable (the 5 yaw frames
cycled), the slot list and the price. Up and Down pick a slot, Left and
Right pick an item or level, and A buys.

| Slot | Items / levels | Effect | Price |
|---|---|---|---|
| CHASSIS | THIN CLIENT, WORKSTATION, MAINFRAME | section 4.1; a swap keeps weapons, resets PLATING | 1500 |
| FRONT | PING, BROADCAST, FIBER LANCE, SPEAR PHISH, each L1-L3 | L2 +25% ammo, L3 +25% damage | 800 / L 400, 800 |
| REAR | MEMORY LEAK, LOGIC BOMB, BIT ROT, FIREWALL, each L1-L3 | L2 +1 ammo, L3 +25% effect | 600 / L 300, 600 |
| PLATING (**ECC**) | L0-L3 | armor +30 per level. L3 corrects single-bit errors: any hit of 4 damage or less is ignored, so PING can't chip you | 500, 900, 1400 |
| CLOCK (engine) | L0-L3 | top speed +4% per level | 600, 1000, 1500 |
| TRACTION | L0-L3 | grip +0.03 per level | 400, 700, 1000 |
| BURST BUFFER | L0-L3 | burst charges per lap 1 / 2 / 3 / 4 | 400, 800, 1200 |
| **SNAPSHOTS** | L0-L3 | snapshot bar 90 / 140 / 190 / 240 ticks | 700, 1200, 1800 |

SNAPSHOTS is the Antithesis line item, sold on the same shelf as armor.
Its blurb reads: *"Deterministic replay. Undo anything."*

Rivals spend on fixed per-crew plans (LEGACY: PLATING, then front L2,
never CLOCK; KIDDIE: CLOCK first, never PLATING; and so on), so that
career difficulty rises with the player's own and stays deterministic.

## 10. Rendering

The renderer is Zero's sections 6.1 to 6.4: the row-loop Mode 7 floor
(Zero's M0 measurement chose rows over columns), fog banks, the
two-layer horizon strip, back-to-front scaled sprites placed from the
`d(y)` table, hills, shake, and the own 8x8 font blit. New in this cart:

- **Sprite count.** Up to 6 cars, 48 projectiles, 32 drops, 8 drones
  and 8 crates can be visible at once. They are depth-sorted into one
  list (the sort key is screen row, i.e. distance) with a cap of 64
  drawn objects per frame; the farthest are culled first.
- **Flat decals** (puddles, caltrops, spaghetti, fire wall base, chips,
  crates seen from above) go through a non-uniform scaled blit: full
  width scale, height scale times a squash factor. This makes them read
  as lying on the floor. It is one extra parameter on Zero's
  `blit_scaled`.
- **Beams and chains** (FIBER LANCE, DEADLOCK) are 1 to 2 px lines
  between two projected points, Bresenham, clipped to the floor region.
- **Car sprites**: 3 chassis x 5 yaw views (rear, rear-quarter, side;
  mirrored for the other side) at 32x16, a wreck frame, and Snouty's
  head composited by the asset tool into the player's frames. Livery is
  a 16-colour palette per crew, so one shape set covers six cars. Damage
  smoke and sparks are effect sprites.
- **Effects** (explosions 4 frames at 24x24, sparks, smoke, muzzle
  flash, claw) are cosmetic and live outside the `World` in a small
  render-side particle ring that is cleared on rewind. Rewinding never
  has to restore smoke.
- **Victim overlays**: the KERNEL PANIC blue screen, the CAPTCHA grid,
  and the BIT FLIP column jitter (the floor's per-row x offset, which
  Zero's shake already has).
- **Horizon art** for each league: monitor mountains and smoke (Dumps),
  cooling towers over a cracked horizon (Runoff), and the black
  datacenter wall with LED blink (Perimeter, using Zero's palette-swap
  LED blink).

Screen layout:

```
y  0..7    LAP 2/3            3RD              [pickup box 16x16, top-right]
y  8..15   kill feed line (60 ticks)
y  0..31   horizon strip under the HUD text
y 33..127  floor
           player car centred x 80, bottom y 118; reticle on the locked target
           bottom-left: ARMOR bar (green->red, 40x4), SNAPSHOT bar (cyan, 40x4),
             front ammo count + rear ammo pips, burst pips
           bottom-right: 32x32 minimap, cars as 2x2 dots in livery colours,
             crates as 1 px yellow, the marked car blinking in GC mode
```

Zero M5.2 lessons apply: nothing drawn closer than 4 px to a screen
edge, and every menu row centred on its longest line.

## 11. Architecture

The cart lives in `carts/snouty-gc/cart/src/`. It **forks** Zero's
engine modules by copy, with a provenance comment at the top of each
file. It does not move them to `lib/`. Zero is shipped and its tags are
the badge reference, and a refactor under it would need a re-verify for
no player-visible gain (decision 9).

| Module | Origin | Notes |
|---|---|---|
| `fixed.zig`, `gen/sin.zig`, `font.zig`, `input.zig`, `camera.zig`, `hills.zig`, `packed_int_array.zig` | Zero, unchanged | |
| `render.zig` | Zero | floor, horizon, fog, shake; adds the per-row jitter used by BIT FLIP |
| `sprites.zig` | Zero | adds the non-uniform scale and the 64-object depth list |
| `track.zig` | Zero | adds crate rows, chips, vents, sweeper lane and sentries from the `.track` file |
| `history.zig` | Zero M4 | keyframes + window cache; World size budget in section 13 |
| `world.zig` | new | `Car` x6, `Projectile` x48, `Drop` x32, `Drone` x8, crate timers, hazards, GC state, PRNG, clock; no pointers |
| `sim.zig` | Zero, extended | driving, walls, contacts, ramming, damage, wrecks, respawn, laps, rank, GC sweeps |
| `weapons.zig` | new | front + rear weapon tables and firing; projectile and drop update; hit resolution |
| `pickups.zig` | new | roll, roulette, the 16 pickup effects, status timers (flip, chain, captcha, sudo, heisen) |
| `ai.zig` | Zero, extended | crews, aim, drop and pickup policies (6.5), autopilot |
| `hud.zig`, `menu.zig`, `results.zig`, `garage.zig`, `career.zig` | Zero / new | |
| `fx.zig` | new | render-side particles, outside World |
| `tuning.zig` | Zero, extended | every number in sections 4 to 9 |

The `.track` format extends Zero's with feature words `crates`, `chips`,
`vent`, `sweeper` and `sentry:<side>`. The generator is
`tools/build_tracks.py` plus `tools/leagues.py` forked from Zero, with
Dumps and Runoff tile vocabularies and the LZ map packer.
`tools/prepare_assets.py` draws the cars, weapons, pickup icons and
effects as code-drawn vector shapes. Under Adrian's art policy those
count as final.

Determinism rules are as in every rewind cart. No floats, clock or
unseeded randomness inside `simulate`. Rendering only reads the world.
Status timers are World fields. A pickup's effect is World state, never
render state.

## 12. Verification

- **Host tests** (`zig build test`): Zero's set (trig, attribute
  lookups, `simulate` twice equals byte-for-byte, `restore(t)` equals the
  direct state for every `t` of a 600-tick run, lap counting), plus:
  - one scenario test per weapon and per pickup: a scripted world, a
    fixed number of ticks, and asserts on the effect (FORK BOMB has 8
    bombs at tick 180 and none at 481; RACE CONDITION swaps exactly two
    cars; CAPTCHA frees the AI after its character's ticks; ECC L3
    ignores a PING hit; HEISENBUG breaks a lock);
  - **every track completable**: the autopilot drives 3 laps on each
    track with combat off, without a wreck and within a time bound
    (Zero's content gate);
  - **chaos soak**: 20 seeded AI-only races with combat on all finish.
    No car is stuck for more than 600 ticks, and no projectile, drop or
    drone pool overflows its cap;
  - the same soak in GARBAGE COLLECTION mode ends with exactly one
    survivor;
  - `@sizeOf(World) <= 1280` (section 13).
- `zig build check-float`.
- Headless `preview.mjs` scripts under `tools/scripts/`: title to race,
  rewind, wreck auto-rewind, a KERNEL PANIC on the player, a CAPTCHA
  solve, a GC sweep. PNG and `frames.json` checks.
- **badge-bench** before and after every milestone, worst frame recorded
  in `PLAN.md`, and always run with `--lcd`. The stress scene has all six
  cars on screen, a full FORK BOMB, a DDOS swarm, the FIREWALL and two
  explosions, on Outflow Canyon. A second stress run takes a rewind
  frame in the same scene.
- A review GIF in `docs/` per milestone. Merge to main as soon as a
  milestone is badge-ready, per the standing rule.

## 13. Performance and memory budget

### 13.1 Frame time

The reference is Zero's calibrated bench: mean 2.09 ms, worst 4.81 ms on
its rewind frame.

| Piece | Estimate |
|---|---|
| Floor + horizon (Zero, measured) | about 2.0 ms |
| Sprites: 6 cars + up to 58 small objects, decals squashed | 0.6 to 1.0 ms |
| HUD, minimap, feed, pickup box | 0.4 ms |
| `simulate`: 6 cars x (48 + 32 + 8) circle tests, homing, AI aim | 0.15 ms |
| Rewind frame: up to 10 replayed ticks (Zero's window cache) | +1.5 to 2.0 ms |
| Worst case | about 6 ms, 36% of budget |

The target is **60 fps, worst frame under 8 ms** in the calibrated
bench. Knobs, in the order they would be turned: the drawn-object cap
(64), the effect particle cap, and the `cache_step` of the history
window.

### 13.2 RAM (the hard wall)

| Item | Estimate |
|---|---|
| Code (forked engine + combat, AI, garage) | 120 KB |
| Two league tilesets (Dumps, Runoff), 256 tiles at 8 bpp | 32 KB |
| Two horizon strips | 24 KB |
| Six LZ-packed maps | 24 KB |
| Centerlines + attributes | 13 KB |
| Sprite sheets (cars, weapons, pickups, icons, effects) at 4 bpp | 14 KB |
| `.text` + `.rodata` | about 227 KB |
| `.bss`: unpacked map 16 KB, history about 33 KB, misc 4 KB | about 53 KB |
| Total with 32 KB stack | about 312 KB, **over** the 307 KB window |

This is over, so the budget is spent before M0 starts:

- **World stays at 1280 B or less.** Zero's is 640 B. The pools pack
  tight: `Projectile` 12 B (x, y in 16.16, packed velocity, owner, kind,
  ttl), `Drop` 10 B, `Car` 64 B. Zero's history keeps 12 keyframes plus
  three windows of 10 cached states (42 copies). This cart goes to
  `cache_step` 5, giving 6 states per window, 30 copies, 38 KB at 1280
  B. That is the rewind-frame cost traded for RAM.
- **Tilesets drop to 128 tiles each** (8 KB, not 16). The wasteland
  vocabulary is smaller than Zero's rack art. That saves 16 KB.
- The result is about 280 KB plus stack against 307 KB. That leaves the
  Perimeter league (8 KB tiles + 12 KB horizon + 12 KB maps) **not
  fitting** without one more cut. M5 picks from: a 4 bpp horizon back
  layer, shared Runoff/Perimeter tiles, or a track rotation that drops
  one Dumps map. Section 18 measures the real numbers in M0.

## 14. Repo layout

`carts/snouty-gc/` contains `cart/src/*.zig`, `cart/src/tracks/*.track`,
`cart/build/convert_gfx.zig` (per-cart copy), `assets/gen/`, `tools/`,
`docs/RUNNING.md`, `PLAN.md`, `SPEC.md` and `ASSETS.md`, with a
`build.zig` exposing `pub fn add`. The root `build.zig` lists it. The
bench config is `badge-bench/carts/snouty-gc.toml`. The binary is
`snouty-gc`, and the RAM UF2 is the shipped artifact.

## 15. What makes it ours

- **Weapons that are jokes you can play.** FORK BOMB grows exponentially
  on screen, RACE CONDITION steals a place, CAPTCHA makes the humans
  prove they are human, and KERNEL PANIC blue-screens the leader. The
  player victim gags (blue screen, swapped steering, a CAPTCHA you solve
  mid-race) are things only a single-screen badge game does this
  directly.
- **GARBAGE COLLECTION, mark and sweep** as a knockout mode, with the mark
  passed on by shooting someone.
- **Snapshots for sale.** Rewind is a garage item next to armor, so the
  Antithesis pitch ("deterministic replay, undo anything") is an
  upgrade you choose to buy. A wreck you rewind out of is the moment it
  sells itself.
- **The setting.** The AIs aren't the villains; they don't notice us.
  The hazards are their maintenance, and their sentries punish the leader
  because the leader is the anomaly.

Kept out on purpose: split-screen and badge-to-badge link (no second
screen), ghosts and replay export (parked in `docs/REPLAY.md`), new
audio, flash saves.

## 16. Milestones

Each milestone gets a tag `snouty-gc/mN`, a review GIF in `docs/`,
pull-and-run notes and badge-bench numbers in `PLAN.md`. Opus agents take
the tracks in worktrees with disjoint files where a milestone splits.
Merge to main as soon as a milestone is badge-ready.

- **M0 Fork**: scaffold `carts/snouty-gc` from Zero (copied modules,
  root build, bench toml); the Dumps tileset at 128 tiles and the
  Landfill Loop track; auto-throttle wheeled driving; six cars with crew
  liveries driving Zero's AI with no weapons; `World` packed and the
  size test; section 18 answered. **Done when:** a solo lap and a 6-car
  race run in the simulator, the completable test passes, and the bench
  and RAM figures are in `PLAN.md`.
- **M1 Guns**: armor, damage, ramming, wrecks, hulks, respawn, smoke; all
  4 front and 4 rear weapons; projectile and drop pools; reticle, beam
  and decals; kill feed and `ACK`; AI aim and drop; Quick Race with the
  four presets and the rig screen. **Done when:** a 3-lap Quick Race is a
  real fight, the weapon scenario tests pass, and the bench stress
  scene (guns only) stays under budget.
- **M2 Pickups**: crate rows, roulette, the rank odds, the 15 non-league
  pickups and the player gags (blue screen, BIT FLIP, CAPTCHA
  mini-game), and AI pickup policies. **Done when:** each pickup's
  scenario test passes, the chaos soak passes, and the GIF shows FORK
  BOMB, KERNEL PANIC on the player and a CAPTCHA solve.
- **M3 Rewind and content**: history and Select-hold rewind, wreck
  auto-rewind, the snapshot bar; GARBAGE COLLECTION mode with mark,
  sweep and claw; six tracks over Dumps and Runoff with their hazards
  (Sweeper, vents); splash, title, attract (with its scripted KERNEL
  PANIC), menus, pause and results. **Done when:** the determinism and
  restore tests pass with combat on, all six tracks are completable, and
  the GC soak ends with one survivor.
- **M4 Circuit and polish**: CYCLES, chips, the garage, rival upgrade
  plans, standings, the league unlock; bench profile and fast paths;
  a balance pass that errs dangerous. **Done when:** a full two-league
  circuit is playable start to finish, merged, tagged and the GIF is
  posted.
- **M5 Stretch** (pick with Adrian): the Perimeter league (sentries,
  PROMPT INJECTION, the ending card), subject to the RAM cut in 13.2;
  a `KILL -9` arena battle mode (one open Mode 7 arena, pickups only,
  last car running wins); a Tufty port (on the `tufty` branch, as the
  other carts were).

## 17. Decisions (taken by default, 2026-10-04)

1. **Name**: `snouty-gc`, title **SNOUTY GC**, subtitle `GARBAGE
   COLLECTION`. Alternatives: *Leftovers*, *Undefined Behavior*,
   *Scrapheap.exe*.
2. **Auto-throttle**, A front fire, Down+A rear, B pickup, Up burst,
   hold Select rewind. The alternative is A throttle, B fire, Up pickup
   and rear weapons as pickups only: closer to Mario Kart, but it loses
   the equipped rear slot and leaves no button for burst.
3. **Six cars**, no traffic. Every car is armed and named.
4. **Ammo refills per lap** (Rock n' Roll Racing), not bought per race.
5. **One held pickup**, Mario Kart tier odds by rank, ZERO-DAY limited
   to the back two places and once per car per race.
6. **Career state in RAM only**; no flash saves, same as Zero.
7. **Rewind is bought** (SNAPSHOTS slot). Quick Race presets get 180
   ticks; a career starts at 90.
8. **Wreck = respawn after 120 ticks** (not elimination) outside GC mode.
9. **Fork Zero's engine by copy**, not a shared `lib/mode7`; Zero stays
   untouched.
10. **Perimeter league is M5 stretch**, behind the RAM cut. Two leagues
    and six tracks ship first.
11. **Sound**: the existing Zero engine drone and tones behind the off-
    by-default toggle; nothing new.
12. **Balance errs dangerous**: rivals can wreck a careless player in
    about 6 PING bursts or two LOGIC BOMBs, and the snapshot is the
    net.

## 18. Facts to check in M0

- The real `.text` and `.bss` of a Zero fork with Zero's nine tracks and
  three leagues stripped, which gives the true room for combat code and
  the six new tracks against 13.2.
- `@sizeOf(World)` with the packed pools, and the rewind-frame cost at
  `cache_step` 5 versus Zero's 3 in the calibrated bench.
- The sprite cost of 64 small objects with the non-uniform blit, in the
  stress scene, against the 1 ms estimate.
- Whether holding Select is comfortable on the SYCL badge as a rewind
  button while the thumb steers. If not, the fallback is hold B (and
  pickups move to Down+B / Up+B chords). This needs Adrian's hand on a
  badge; M0 goes ahead with Select.
- That holding Select alone triggers nothing in the current upstream OS
  (only the Start+Select chord is taken).

## Status

- 2026-10-04: spec drafted from Adrian's prompt (Mode 7 combat racer,
  equipped weapons plus one-use computing-themed pickups, a
  semi-post-apocalyptic cyberpunk Earth after the mega-AIs took over,
  humans as leftover ecology who drive, survive and compete). Nothing
  built; `PLAN.md` comes with M0.
