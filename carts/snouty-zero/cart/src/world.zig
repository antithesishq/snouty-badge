//! The one plain `World` struct (SPEC 10): everything the race simulation
//! reads and writes, no pointers, so a snapshot is a struct copy and
//! `history.zig` can rewind it. Rendering reads it and never writes it.
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");

/// Button word with the cart.Controls bit layout (start 0, select 1, a 2,
/// b 3, click 4, up 5, down 6, left 7, right 8), so `simulate` has no
/// cart API dependency and runs in host tests.
pub const Buttons = packed struct(u16) {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    click: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u7 = 0,
};

pub const machine_count = 11;
pub const player = 0;

/// Why a machine crashed (the message bar names it).
pub const Crash = enum(u8) { none, fall, meltdown, collision };

pub const Machine = struct {
    /// World position, Q16.16, wrapping at 1024.
    x: i32 = 0,
    y: i32 = 0,
    /// Velocity, Q16.16 px/tick.
    vx: i32 = 0,
    vy: i32 = 0,
    heading: fixed.Turn = 0,
    /// Laps completed; sector bits seen since the last start line crossing.
    lap: u8 = 0,
    sectors: u8 = 0,
    /// Nearest centerline sample (0..255).
    progress: u8 = 0,
    /// Fine progress for rank: lap * 256 + sample, plus the fraction (M2).
    thermal: i16 = @intCast(tuning.thermal_max),
    /// Ticks left in the air / boosted / immune / shaking.
    hop: u8 = 0,
    boost: u8 = 0,
    immune: u8 = 0,
    shake: u8 = 0,
    /// Steering input this tick (-1, 0, 1) for the lean frame; set by simulate.
    steer: i8 = 0,
    /// Set when the machine is on a throttled / cold tile this tick.
    on_throttled: bool = false,
    on_cold: bool = false,
    /// Alive and racing; false after a retire (M3).
    active: bool = true,
    finished: bool = false,
    /// Race time at the finish, ticks.
    finish_tick: u32 = 0,
    /// Best lap and the tick the current lap started.
    best_lap: u32 = 0,
    lap_start: u32 = 0,
    /// Crash in progress (hit-stop countdown) and its cause.
    crash: Crash = .none,
    hitstop: u8 = 0,
};

pub const Phase = enum(u8) { countdown, racing, finished };

pub const World = struct {
    machines: [machine_count]Machine = @splat(.{}),
    /// Race clock in ticks since DEPLOY (0 during the countdown).
    tick: u32 = 0,
    /// Countdown ticks remaining (4 steps of tuning.countdown_step).
    countdown: u16 = 0,
    phase: Phase = .countdown,
    rng: u32 = 0x1234_5678,
    /// Message bar: kind and ticks left.
    msg: Message = .none,
    msg_ticks: u8 = 0,
    /// Number of machines racing (1 in M1 solo, 11 with rivals and traffic).
    active_count: u8 = 1,
};

pub const Message = enum(u8) { none, provisioning, three, two, one, deploy, final_lap, committed, fall, meltdown, collision };

pub var w: World = .{};
