//! Track B: the screensaver state machine (SPEC.md sections 3, 5, 6). Each
//! tick it advances the pipes and leaves a list of draw commands for main.zig
//! to run through the renderer. Pure logic, host-tested, no cart API.
const std = @import("std");
const grid = @import("grid.zig");
const camera = @import("camera.zig");
const rng = @import("rng.zig");

/// Stable numbers: debug_state returns these.
pub const State = enum(u8) { boot = 0, grow = 1, dissolve = 2, rebuild = 3 };

pub const Cmd = union(enum) {
    cell: struct { p: grid.Prim, s0: f32, s1: f32 },
    clear_all,
    clear_blocks: struct { from: u16, to: u16 },
};

/// Buttons as main.zig sees them this tick (held and rising edge).
pub const Input = struct {
    a: bool = false,
    b: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const max_cmds = 64;

pub var state: State = .boot;
pub var cam: camera.Camera = undefined;
var cmds: [max_cmds]Cmd = undefined;
var cmd_len: usize = 0;

pub fn reset(seed: u32) void {
    _ = seed;
    state = .boot;
    cam = camera.view(0, 0);
    cmd_len = 0;
    push(.clear_all);
}

/// Advances one 1/60 s tick. `pressed` holds rising edges.
pub fn step(held: Input, pressed: Input) void {
    _ = held;
    _ = pressed;
}

/// This tick's draw commands, in order.
pub fn commands() []const Cmd {
    return cmds[0..cmd_len];
}

/// Called by main.zig after running commands().
pub fn commands_done() void {
    cmd_len = 0;
}

fn push(c: Cmd) void {
    if (cmd_len < max_cmds) {
        cmds[cmd_len] = c;
        cmd_len += 1;
    }
}
