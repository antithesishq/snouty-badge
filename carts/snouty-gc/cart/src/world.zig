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
pub const ProjKind = enum(u8) { none, ping, broadcast, phish };
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
    /// SPEAR PHISH homing target car index, or `no_car`.
    target: u8 = no_car,
};
pub const proj_count = 48;

/// Something lying on the floor (SPEC 6.2). Free when `kind == .none`.
pub const DropKind = enum(u8) { none, leak, bomb, caltrop, firewall };
pub const Drop = struct {
    x: i32 = 0,
    y: i32 = 0,
    kind: DropKind = .none,
    owner: u8 = 0,
    /// Ticks since dropped (arming, growth, expiry).
    age: u16 = 0,
    /// Kind-specific: puddle radius px (leak), half width px (firewall).
    size: u8 = 0,
    /// Heading the drop was laid at (firewall orientation), turns >> 8.
    dir: u8 = 0,
};
pub const drop_count = 32;

/// Render-facing log of what happened (kill feed, ACK, taunts, beams,
/// explosions). The sim appends; rendering keeps its own cursor (`seq`)
/// and never writes. A ring, so the World stays plain data.
pub const EventKind = enum(u8) { none, hit, wreck, lance, explode, respawn };
pub const Event = struct {
    /// Monotonic event number (World.event_seq at append).
    seq: u16 = 0,
    kind: EventKind = .none,
    /// hit: attacker, victim, damage. wreck: victim, killer (`no_car` for a
    /// fall), cause (Wreck). lance: owner, target or `no_car`, length px.
    /// explode: car or `no_car`, radius px. respawn: car.
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    /// World position for explode / lance end, px (integer, wrapping).
    x: u16 = 0,
    y: u16 = 0,
};
pub const event_count = 16;

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
    /// In the race (false only for a car not on the grid; M3's GC mode
    /// takes collected cars out).
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
    /// Upgrade levels 1..3 (M5 garage; 1 until then).
    front_level: u8 = 1,
    rear_level: u8 = 1,
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
    /// Race tallies for the results screen.
    kills: u8 = 0,
    wrecks: u8 = 0,
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
};

pub const Phase = enum(u8) { countdown, racing, finished };

/// What both badges agree on before a race (SPEC 7.3): track, seed and the
/// racers the two humans drive (`no_human` for an empty slot).
pub const Setup = struct {
    track: u8 = 0,
    seed: u32 = 0x1234_5678,
    humans: [2]u8 = .{ no_human, no_human },
    /// Weapons and damage on (false only for the completable tests).
    combat: bool = true,
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
};
