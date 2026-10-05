//! The one plain `World` struct (SPEC 11): everything the race simulation
//! reads and writes, no pointers, so it can be copied, compared and CRC'd
//! (the M4 lockstep check). `sim.simulate(w, inputs)` is its only writer
//! during a race; rendering reads it and never writes it, and nothing in it
//! says which car a badge draws (that is main.zig's render-side `follow`).
//! New for Snouty GC (Zero's world.zig had one player and traffic).
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");

/// The race input byte (SPEC 5.1, 7.2): one byte per human per tick, which
/// is what the link carries. Bit 0 up, 1 down, 2 left, 3 right, 4 A, 5 B,
/// 6 Start, 7 Select.
pub const Input = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    a: bool = false,
    b: bool = false,
    start: bool = false,
    select: bool = false,

    pub fn byte(self: Input) u8 {
        return @bitCast(self);
    }
    pub fn of(b: u8) Input {
        return @bitCast(b);
    }
};

/// Six cars, one per racer (SPEC 4.1); there is no traffic.
pub const car_count = 6;
/// `Car.human` for an AI-driven car.
pub const no_human: u8 = 0xFF;

/// Why a car is wrecked: a fall (M0), armor at 0 (M1), ZERO-DAY (M2).
pub const Wreck = enum(u8) { none, fall, armor, zero_day };

/// Equipped weapons (SPEC 6.1, 6.2). The racer's car starts with its
/// loadout from racers.zig; the M5 garage changes it.
pub const Front = enum(u8) { ping, broadcast, lance, phish };
pub const Rear = enum(u8) { leak, bomb, rot, firewall };

/// A moving shot (SPEC 6.1). Pool slot is free when `kind == .none`.
/// `panic` (M2) is the KERNEL PANIC packet (SPEC 6.3): it runs along the
/// centerline at twice the top speed to its `target`, then homes onto it.
pub const ProjKind = enum(u8) { none, ping, broadcast, phish, panic };
pub const Projectile = struct {
    /// World position, Q16.16 (wrapping like cars).
    x: i32 = 0,
    y: i32 = 0,
    /// Velocity, Q8.8 px/tick.
    vx: i16 = 0,
    vy: i16 = 0,
    kind: ProjKind = .none,
    /// Car index that fired it (no friendly fire on the owner).
    owner: u8 = 0,
    /// Ticks left to live.
    ttl: u8 = 0,
    /// SPEAR PHISH homing target car index, or `no_car`. KERNEL PANIC: the
    /// car it runs to.
    target: u8 = no_car,
    /// KERNEL PANIC only: the centerline sample it is running toward. Its
    /// `ttl` is its direction (0 forward, 1 backward when its target was
    /// behind the user): it lives until it hits or its target leaves.
    seg: u8 = 0,
};
/// 48 in M1; the M1 soak peaked at 21 live shots, and the M2 `seg` byte
/// made each slot 20 bytes.
pub const proj_count = 40;

/// Something lying on the floor (SPEC 6.2, and the M2 pickups of 6.3).
/// Free when `kind == .none`. `fork` is one FORK BOMB `&` (they fork every
/// 60 ticks, up to 8, gone at age 480); `honeypot` the fake RMA crate;
/// `spaghetti` the 24 px cable tangle. All three are consumed by the car
/// that touches them.
pub const DropKind = enum(u8) { none, leak, bomb, caltrop, firewall, fork, honeypot, spaghetti };
pub const Drop = struct {
    x: i32 = 0,
    y: i32 = 0,
    kind: DropKind = .none,
    owner: u8 = 0,
    /// Ticks since dropped (arming, growth, expiry).
    age: u16 = 0,
    /// Kind-specific: puddle radius px (leak), half width px (firewall);
    /// fork: the generation (bits 0..1) and drift side (bit 2), internal.
    size: u8 = 0,
    /// Heading the drop was laid at (firewall orientation; fork: the drift
    /// axis is across it), turns >> 8.
    dir: u8 = 0,
};
/// 32 in M1; M2 adds up to 8 FORK BOMBs a use.
pub const drop_count = 40;

/// The held pickup (SPEC 6.3), in table order so that `@intFromEnum(p)` is
/// the cell of `pickups.png` (ASSETS.md); `none` is 16, the roulette blank
/// cell. Tiers (SPEC 6.4): A prefetch..spaghetti, B fork_bomb..
/// race_condition, C kernel_panic..zero_day; `prompt_injection` is the
/// Perimeter league's and never rolls on the Dumps.
pub const Pickup = enum(u8) {
    prefetch = 0,
    honeypot,
    duck,
    hot_patch,
    spaghetti,
    fork_bomb,
    bit_flip,
    deadlock,
    ddos,
    heisenbug,
    race_condition,
    kernel_panic,
    captcha,
    sudo,
    zero_day,
    prompt_injection,
    none = 16,
};

/// A DDOS packet drone (SPEC 6.3). `flying` from the user to the target
/// (straight, over walls), then `orbit`ing it for `ttl` ticks: 2 damage a
/// drone every 30 ticks, the target's top speed -20%. Shots kill it (1 HP).
pub const DroneState = enum(u8) { none, flying, orbit };
pub const Drone = struct {
    /// World position, Q16.16.
    x: i32 = 0,
    y: i32 = 0,
    state: DroneState = .none,
    owner: u8 = 0,
    target: u8 = 0,
    /// Orbit ticks left (counts only while orbiting).
    ttl: u8 = 0,
    /// Orbit angle, turns >> 8.
    angle: u8 = 0,
};
/// One DDOS swarm (a second DDOS replaces the oldest drones).
pub const drone_count = 8;
/// RMA crate spawns per track (rows of 3 or 4, `track.crate_spots`).
pub const crate_max = 16;

/// Why a car is frozen in place (`Car.frozen`): KERNEL PANIC (M2).
pub const Freeze = enum(u8) { none, panic };

/// Race rules (SPEC 8.2), chosen in the shared setup. `race`: QUICK RACE
/// (laps, first past the line wins). `gc`: GARBAGE COLLECTION, mark and
/// sweep (no lap limit; the last car running wins; `World.gc`). `attract`:
/// race rules plus the scripted KERNEL PANIC on the leader in lap 2
/// (SPEC 8.2 Attract), so the AI-only demo always shows a blue screen.
pub const Mode = enum(u8) { race, gc, attract };

/// GARBAGE COLLECTION state (SPEC 8.2, M3). Sweep points are the sector 2
/// line and the start line, passed by the race leader: sweep k (from 0)
/// is at sample 170 of lap k / 2 for even k and the start of lap
/// (k + 1) / 2 for odd k. At each sweep the MARKED car (if any) is
/// collected, then the new last car is marked. The marked car passes the
/// mark on by landing a weapon hit on another car (not a ram), once
/// `mark_ticks` has run `tuning.gc_tag_grace`; a wreck while marked is an
/// immediate collection. A collected car leaves the race (`active =
/// false`) and keeps its `rank` as its final place.
pub const Gc = struct {
    /// The MARKED car, or `no_car`.
    marked: u8 = no_car,
    /// Ticks since the mark was set or passed on (tag grace; saturates).
    mark_ticks: u16 = 0,
    /// Sweep points the leader has passed.
    sweeps: u8 = 0,
    /// Collected cars, bit i = car i.
    collected: u8 = 0,
    /// The last car running (the winner) once decided, else `no_car`.
    survivor: u8 = no_car,
};

/// Track hazards (SPEC 3.3, 19.4, M3): generic kinds parameterised by the
/// track data (`track.HazardSpec`, one per World slot), so a data-only
/// track pack (M7) can place them with its own numbers and art. `blast`:
/// a timed blast across the track (the Runoff's exhaust vents). `mover`:
/// a crossing mover shuttling between two points (the Dumps' Sweeper).
/// `turret` (the Perimeter's sentries) and `crust` (M7's breakable crust)
/// are reserved: the data may carry them, the sim leaves them idle.
pub const HazardKind = enum(u8) { none, blast, mover, turret, crust };
/// Where a hazard is in its cycle: `idle` (harmless), `warn` (the telegraph
/// before it acts: a vent spooling up, the Sweeper's beacons; still
/// harmless), `active` (a vent firing, the Sweeper crossing: it hurts).
pub const HazardState = enum(u8) { idle, warn, active };
pub const Hazard = struct {
    /// Mover: its position, Q16.16 world px (wrapping like cars); blast:
    /// the vent mouth (spec x0, y0), constant.
    x: i32 = 0,
    y: i32 = 0,
    /// Ticks into the cycle (0 .. spec period - 1), from the spec phase at
    /// reset.
    timer: u16 = 0,
    kind: HazardKind = .none,
    state: HazardState = .idle,
    /// Cars already hit in this active phase, bit i = car i (a hazard hits
    /// a car once per firing / crossing).
    hit: u8 = 0,
    /// Mover: 0 while going from end A to end B (or waiting at A), 1 the
    /// way back. Blast: 0.
    leg: u8 = 0,
};
/// Hazards per track (`track.hazard_n` of them in use).
pub const hazard_max = 4;

/// Render-facing log of what happened (kill feed, ACK, taunts, beams,
/// explosions). The sim appends; rendering keeps its own cursor (`seq`)
/// and never writes. A ring, so the World stays plain data.
pub const EventKind = enum(u8) { none, hit, wreck, lance, explode, respawn, roll, use, effect, swap, mark, collect, blast, hazard_hit, chip };
pub const Event = struct {
    /// Monotonic event number (World.event_seq at append).
    seq: u16 = 0,
    kind: EventKind = .none,
    /// hit: attacker, victim, damage. wreck: victim, killer (`no_car` for a
    /// fall), cause (Wreck). lance: owner, target or `no_car`, length px.
    /// explode: car or `no_car`, radius px. respawn: car.
    /// M2: roll: car, pickup rolled (`Pickup`), crate index (x, y = the
    /// crate; the car's roulette runs `Car.roll_ticks`). use: user, pickup,
    /// target car or `no_car` (x, y = where it lands or strikes). effect:
    /// source car or `no_car`, affected car, pickup (x, y = the affected
    /// car): a one-off impact for the gags and fx (KERNEL PANIC hit, BIT FLIP
    /// strike, DEADLOCK chain, DDOS arrival, HONEYPOT burst, SPAGHETTI
    /// tangle, RUBBER DUCK popped (affected = the duck's owner), ZERO-DAY).
    /// swap: the two cars of a RACE CONDITION, the tick they trade places.
    /// M3: mark: the newly MARKED car, the car that passed it on (a tag) or
    /// `no_car` (a sweep marked it), cause (`GcCause`). collect: the
    /// collected car, its final place, cause (`GcCause`: sweep or wreck);
    /// x, y = the car (the claw comes down there). blast: hazard index,
    /// `HazardKind`, 0 (a vent starts firing, the Sweeper starts crossing;
    /// x, y = the vent mouth or the mover). hazard_hit: hazard index, car,
    /// damage (x, y = the car). M5: chip: the car, the chip index (x, y =
    /// the chip; a cycle chip taken, worth 10 CYCLES in the career).
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    /// World position for explode / lance end, px (integer, wrapping).
    x: u16 = 0,
    y: u16 = 0,
};
pub const event_count = 16;
/// Why a `mark` or `collect` event happened (its `c`).
pub const GcCause = enum(u8) { sweep, tag, wreck };

/// "No car" in a car-index field.
pub const no_car: u8 = 0xFF;

pub const Message = enum(u8) { none, ready, three, two, one, go, final_lap, finished, fall };

pub const Car = struct {
    /// World position, Q16.16, wrapping at 1024.
    x: i32 = 0,
    y: i32 = 0,
    /// Velocity, Q16.16 px/tick.
    vx: i32 = 0,
    vy: i32 = 0,
    heading: fixed.Turn = 0,
    /// Racer id 0..5 in SPEC 4.1 order (racers.zig).
    racer: u8 = 0,
    /// Which input byte drives this car (0 or 1), or `no_human` for the AI.
    human: u8 = no_human,
    /// Chassis multipliers (SPEC 4.2), copied from the racer's chassis at
    /// reset so the world is self-contained (the M5 garage edits them).
    top_q8: u16 = 256,
    accel_q8: u16 = 256,
    grip_q8: u16 = 256,
    mass_q8: u16 = 256,
    armor_max: u8 = 100,
    /// Laps completed; sector bits seen since the last start line crossing.
    lap: u8 = 0,
    sectors: u8 = 0,
    /// Nearest centerline sample (0..255).
    progress: u8 = 0,
    /// Ticks left in the air / of BURST / immune / shaking.
    hop: u8 = 0,
    burst: u8 = 0,
    burst_charges: u8 = tuning.burst_per_lap,
    immune: u8 = 0,
    shake: u8 = 0,
    /// Steering this tick (-1, 0, 1) and the powerslide, for the sprite.
    steer: i8 = 0,
    slide: bool = false,
    /// On a coolant / service-bay tile this tick.
    on_coolant: bool = false,
    on_bay: bool = false,
    /// In the race (false for a car not on the grid, and for a car GARBAGE
    /// COLLECTION has collected: `World.gc.collected` tells them apart).
    active: bool = true,
    finished: bool = false,
    /// Race time at the finish, ticks.
    finish_tick: u32 = 0,
    /// Best lap and the tick the current lap started.
    best_lap: u32 = 0,
    lap_start: u32 = 0,
    /// Wrecked: the cause and the WATCHDOG ticks until the respawn.
    wreck: Wreck = .none,
    wreck_ticks: u8 = 0,
    /// Up held last tick: BURST fires on the press edge.
    up_was: bool = false,
    /// Combat (M1, SPEC 5.3, 6). Armor 0..armor_max; at 0 the car wrecks.
    armor: u8 = 100,
    front: Front = .ping,
    rear: Rear = .leak,
    /// Weapon levels 1..3 (M5 garage, `Loadout`): front L2 +25% ammo, L3
    /// also +25% damage; rear L2 +1 ammo, L3 also +25% effect.
    front_level: u8 = 1,
    rear_level: u8 = 1,
    /// M5 garage (`Loadout`, SPEC 9.2): PLATING L3 = ECC (a hit of
    /// `tuning.ecc_ignore` or less is ignored); BURST charges a lap (BURST
    /// BUFFER); the WATCHDOG delay, ticks, from a wreck to the respawn.
    ecc: bool = false,
    burst_max: u8 = tuning.burst_per_lap,
    watchdog: u8 = tuning.watchdog_ticks,
    /// Ammo left this lap; refilled on the start line.
    ammo_front: u8 = 0,
    ammo_rear: u8 = 0,
    /// Ticks until the front weapon may fire again.
    fire_cd: u8 = 0,
    /// FIBER LANCE charge ticks while A is held.
    charge: u8 = 0,
    /// SPEAR PHISH lock target, or `no_car`.
    lock: u8 = no_car,
    /// Last car to damage this one and the ticks since (kill credit).
    last_hit_by: u8 = no_car,
    last_hit_ticks: u8 = 0,
    /// Per-car hit-stop after a wreck (no world-wide freeze: a link race
    /// must not stop both badges), and the hit flash for the sprite.
    hitstop: u8 = 0,
    hit_flash: u8 = 0,
    /// A and the Down+A chord last tick (press edges).
    a_was: bool = false,
    rear_was: bool = false,
    /// Race tallies for the results screen (and the career's CYCLES:
    /// `kills` are the last-hit wrecks credited, `chips` the cycle chips
    /// taken, M5).
    kills: u8 = 0,
    wrecks: u8 = 0,
    chips: u8 = 0,
    /// Race position 1..6; final once the car has `finished`.
    rank: u8 = 0,
    /// The car's own message (FINAL LAP, the finish, a wreck), shown on the
    /// badge that follows it, and its ticks left.
    msg: Message = .none,
    msg_ticks: u8 = 0,
    /// Track A additions (M1). BIT ROT slow: ticks left at -20% top speed.
    rot_ticks: u8 = 0,
    /// Ticks until the rear weapon may drop again.
    rear_cd: u8 = 0,
    /// On a MEMORY LEAK puddle: set by the drop update, read by the next
    /// tick's grip (coolant grip and the yaw kick).
    on_leak: bool = false,
    /// AI aim (SPEC 6.5), kept by `sim` for every car and read only by
    /// `ai.drive`: the car in the front weapon's cone (`no_car` for none)
    /// and the consecutive ticks it has been there (the reaction delay).
    aim: u8 = no_car,
    aim_ticks: u8 = 0,

    // --- Pickups (M2, SPEC 6.3). Timers count down a tick at a time; 0 = off.
    /// The held pickup; while `roll_ticks > 0` it is the roulette's hidden
    /// result (`FETCHING...`) and B does nothing.
    pickup: Pickup = .none,
    roll_ticks: u8 = 0,
    /// ZERO-DAY rolled once already this race.
    zero_day_used: bool = false,
    /// B held last tick (B uses the pickup on its press edge).
    b_was: bool = false,
    /// PREFETCH boost (+40% top speed, wall damage halved).
    prefetch: u8 = 0,
    /// RUBBER DUCK on its tether behind the car.
    duck: u16 = 0,
    /// HOT PATCH repair running (40 armor over 60 ticks).
    patch: u8 = 0,
    /// SPAGHETTI: tangled (speed held to 40%), then dragging a strand
    /// (top speed -10%).
    tangle: u8 = 0,
    strand: u8 = 0,
    /// HONEYPOT spin (no steering, the car turns and sheds speed).
    spin: u8 = 0,
    /// BIT FLIP: Left and Right swapped.
    bit_flip: u8 = 0,
    /// DEADLOCK: chained to `chain` (or to the nearest wall when `chain` is
    /// `no_car`) while `chain_ticks > 0`; speed held to 30%.
    chain: u8 = no_car,
    chain_ticks: u8 = 0,
    /// HEISENBUG: unobservable (no locks, no AI attention, passes through
    /// cars and drops; drawn on odd frames).
    heisen: u8 = 0,
    /// Frozen in place (KERNEL PANIC: 90 ticks, the first 30 the blue
    /// screen on a human's badge) and why.
    frozen: u8 = 0,
    frozen_by: Freeze = .none,
    /// CAPTCHA: ticks left until it frees the car (speed held to 10%). The
    /// mini-game (humans; AIs only wait): `captcha_cursor` 0..8 sweeps the
    /// 3x3 grid, cells are bits of `captcha_lit` (traffic lights) and
    /// `captcha_done` (cleared); A on a lit cell clears it, A on an unlit
    /// one clears the board again; all lit cells cleared frees the car.
    captcha: u8 = 0,
    captcha_cursor: u8 = 0,
    captcha_lit: u16 = 0,
    captcha_done: u16 = 0,
    /// SUDO: root (invulnerable, +20% top speed, rams deal 40 and bounce,
    /// drops it touches are destroyed).
    sudo: u16 = 0,
    /// RACE CONDITION: tearing for `swap_ticks` with `swap_with`, then the
    /// two cars trade places (set on both cars).
    swap_with: u8 = no_car,
    swap_ticks: u8 = 0,
};

pub const Phase = enum(u8) { countdown, racing, finished };

/// A car's garage upgrades (SPEC 9.2, M5), applied by `sim.reset`. The
/// defaults are the racer's stock car (SPEC 4.1, 4.2): every race outside
/// the CIRCUIT, LINK included, runs on them.
pub const Loadout = struct {
    /// The guns: null = the racer's own (racers.zig), else a swap.
    front: ?Front = null,
    rear: ?Rear = null,
    /// Weapon levels 1..3.
    front_level: u8 = 1,
    rear_level: u8 = 1,
    /// PLATING (armor +30 a level; L3 = ECC), CLOCK (top speed +4% a
    /// level), TRACTION (grip +0.03 a level), BURST BUFFER (BURST charges a
    /// lap 1..4), WATCHDOG (respawn delay 120 / 90 / 60 / 40): levels 0..3.
    plating: u8 = 0,
    clock: u8 = 0,
    traction: u8 = 0,
    burst: u8 = 0,
    watchdog: u8 = 0,
};

/// Cycle chips per track (M5; `track.chip_spots`, one bit of
/// `World.chips` each).
pub const chip_max = 24;

/// What both badges agree on before a race (SPEC 7.3): track, seed and the
/// racers the two humans drive (`no_human` for an empty slot).
pub const Setup = struct {
    track: u8 = 0,
    seed: u32 = 0x1234_5678,
    humans: [2]u8 = .{ no_human, no_human },
    /// Weapons and damage on (false only for the completable tests).
    combat: bool = true,
    /// Race rules (M3): QUICK RACE, GARBAGE COLLECTION or the attract demo.
    mode: Mode = .race,
    /// M4: the AI racers on the grid, at most (a link race's CREWS 4, 2 or
    /// 0, SPEC 7.1). The AI cars past it in the seed's grid shuffle stay
    /// off the grid (`active = false` from the reset, rank 0). The default
    /// keeps every AI car (single player).
    crews: u8 = car_count,
    /// M5: each car's garage upgrades (index = car = racer); the default
    /// is the stock car.
    loadouts: [car_count]Loadout = @splat(.{}),
    /// M5: cycle chips on the floor (the CIRCUIT only).
    chips: bool = false,
};

pub const World = struct {
    cars: [car_count]Car = @splat(.{}),
    /// Race clock in ticks since GO (0 during the countdown).
    tick: u32 = 0,
    /// Countdown ticks remaining (4 steps of tuning.countdown_step).
    countdown: u16 = 0,
    phase: Phase = .countdown,
    /// The world PRNG (xorshift32, never 0).
    rng: u32 = 0x1234_5678,
    /// The shared message (the countdown and GO).
    msg: Message = .none,
    msg_ticks: u8 = 0,
    /// Index into `track.tracks`.
    track: u8 = 0,
    /// Lap length in world px along the centerline (set by sim.reset).
    lap_px: u16 = 0,
    /// Combat pools (M1).
    projs: [proj_count]Projectile = @splat(.{}),
    drops: [drop_count]Drop = @splat(.{}),
    /// Event ring: slot = seq % event_count; `event_seq` is the next seq.
    events: [event_count]Event = @splat(.{}),
    event_seq: u16 = 0,
    /// Weapons, ramming and wall damage on (Setup.combat).
    combat: bool = true,
    /// M2: each crate spawn's respawn timer, indexed like
    /// `track.crate_spots`: 0 = the crate is there, else ticks until it is.
    crates: [crate_max]u8 = @splat(0),
    /// DDOS drones.
    drones: [drone_count]Drone = @splat(.{}),
    /// M3: the race rules (Setup.mode), the laps to run (the track's,
    /// `track.Track.laps`; GARBAGE COLLECTION has no lap limit and ignores
    /// it), the GC state, and the track hazards (`track.hazard_specs[k]`
    /// drives slot k; slots past `track.hazard_n` stay `.none`).
    mode: Mode = .race,
    laps: u8 = tuning.laps,
    /// Attract: the scripted KERNEL PANIC has been handed out.
    scripted: bool = false,
    gc: Gc = .{},
    hazards: [hazard_max]Hazard = @splat(.{}),
    /// M5: cycle chips (Setup.chips): bit k set while chip k
    /// (`track.chip_spots[k]`) is taken; every chip comes back when the
    /// race leader starts a new lap (`chip_lap`: the leader's lap the
    /// chips were last laid for).
    chips_on: bool = false,
    chip_lap: u8 = 0,
    chips: u32 = 0,
};
