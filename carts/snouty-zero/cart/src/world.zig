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
/// The solo player's machine, and the host's in a link race (M6).
pub const player = 0;
/// The guest's machine in a link race (a rival's slot, M6).
pub const guest = 1;
/// `World.humans` entry for an input slot nobody drives.
pub const no_human: u8 = 0xFF;

/// Why a machine crashed (the message bar names it).
pub const Crash = enum(u8) { none, fall, meltdown, collision };

pub const Flags = packed struct(u8) {
    /// Set when the machine is on a throttled / cold tile this tick.
    on_throttled: bool = false,
    on_cold: bool = false,
    /// Alive and racing; false after a retire (M3) or a knockout.
    active: bool = true,
    finished: bool = false,
    /// Knocked out (SPEC 5.5): wrecking through the hit-stop, then out of
    /// the race (`active` false) instead of the centerline reset.
    ko: bool = false,
    /// Up held last tick: Overclock fires on the press edge (SPEC 4).
    up_was: bool = false,
    _pad: u2 = 0,
};

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
    /// Thermal bar 0..thermal_max (SPEC 5.2).
    thermal: i16 = @intCast(tuning.thermal_max),
    /// Ticks left in the air / boosted / immune / shaking.
    hop: u8 = 0,
    boost: u8 = 0,
    immune: u8 = 0,
    shake: u8 = 0,
    /// Steering input this tick (-1, 0, 1) for the lean frame; set by simulate.
    steer: i8 = 0,
    /// The machine's bools, one byte (M6: every byte of a Machine is 44
    /// bytes of history, and the link race needed the cart RAM).
    f: Flags = .{},
    /// Race time at the finish, ticks (saturating at 65535, 18 minutes).
    finish_tick: u16 = 0,
    /// Best lap, and the race tick the current lap started (low 16 bits:
    /// a lap time is the wrapping difference).
    best_lap: u16 = 0,
    lap_start: u16 = 0,
    /// Crash in progress (hit-stop countdown) and its cause.
    crash: Crash = .none,
    hitstop: u8 = 0,
    /// Ticks left in which a crash counts as a human's doing (set by a
    /// damaging contact with a human), and which human (input slot).
    hit_by_player: u8 = 0,
    hit_by: u8 = 0,
    /// Race position 1..5 for the player and rivals (0 for traffic and
    /// inactive machines); final for a machine once it has `finished`.
    rank: u8 = 0,
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
    /// The machine each human input slot drives (`simulate`'s inputs[s]),
    /// or `no_human`: slot 0 is the solo player (and the link host), slot 1
    /// the link guest (M6).
    humans: [2]u8 = .{ player, no_human },
    /// Each human's machine select pick (`ai.player_machines` index).
    picks: [2]u8 = .{ 0, 0 },
    /// The human's partner left (link race): the AI drives that machine on
    /// to the finish; it still counts as that human's in the results.
    ai_drives: [2]bool = .{ false, false },
    /// Message bar per human slot: kind and ticks left (the countdown goes
    /// to both; crashes, laps, the finish and knockouts to the human
    /// concerned).
    msg: [2]Message = .{ .none, .none },
    msg_ticks: [2]u8 = .{ 0, 0 },
    /// Number of machines racing (1 in M1 solo, 11 with rivals and traffic).
    active_count: u8 = 1,
    /// Lap length in world px along the centerline (set by sim.reset from
    /// the track; progress in px for the rubber band).
    lap_px: u16 = 0,
    /// Machines each human knocked out this race (SPEC 5.5).
    kos: [2]u8 = .{ 0, 0 },
    /// The machine a `.ko` message names, per human slot.
    msg_who: [2]u8 = .{ 0, 0 },

    /// The input slot driving machine `i`, or null for the AI's machines.
    pub fn slot_of(self: *const World, i: usize) ?u1 {
        if (self.humans[0] == i) return 0;
        if (self.humans[1] == i) return 1;
        return null;
    }
};

pub const Message = enum(u8) { none, provisioning, three, two, one, deploy, final_lap, committed, fall, meltdown, collision, killed, ko };

pub var w: World = .{};

/// The machine this badge's camera, HUD and sound follow (meta-state, not
/// in the World): the player solo, this badge's human in a link race.
pub var view: u8 = player;
