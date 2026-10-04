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

/// Why a car is wrecked (M0: only falls; M1 adds armor at 0).
pub const Wreck = enum(u8) { none, fall };

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
    /// Race position 1..6; final once the car has `finished`.
    rank: u8 = 0,
    /// The car's own message (FINAL LAP, the finish, a wreck), shown on the
    /// badge that follows it, and its ticks left.
    msg: Message = .none,
    msg_ticks: u8 = 0,
};

pub const Phase = enum(u8) { countdown, racing, finished };

/// What both badges agree on before a race (SPEC 7.3): track, seed and the
/// racers the two humans drive (`no_human` for an empty slot).
pub const Setup = struct {
    track: u8 = 0,
    seed: u32 = 0x1234_5678,
    humans: [2]u8 = .{ no_human, no_human },
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
};
