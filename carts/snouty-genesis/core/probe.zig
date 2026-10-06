//! Host-only trace points for the Sonic 1 DAC oracle (PLAN.md "Sonic 1
//! DAC fake", tools/s1dac_trace.zig). `enabled` is `build_options.probe`,
//! false in every cart build, where each `note` compiles to nothing; the
//! trace tool's two host builds (the full core with the real Z80, and the
//! RAM core with the fake) set it and install `hook`.
//!
//! Times are master clocks into the frame (262 x 3420 per frame), the
//! unit of core/sound.zig.
pub const enabled: bool = @import("build_options").probe;

pub const Event = enum(u8) {
    /// The 68000 wrote Z80 RAM (`a` = Z80 address, `v` = byte).
    m68k_z80_write,
    /// BUSREQ (`v` = 1 requested) and RESET (`v` = 1 asserted) as written.
    busreq,
    reset,
    /// The Z80 wrote a YM2612 data port (`a` = part << 8 | register).
    z80_ym,
    /// The Z80 wrote its bank register (`a` = the 9-bit value after it).
    z80_bank,
    /// The Z80 read its bank window (`a` = the 68000 address).
    z80_window,
    /// The fake's DAC level changed (`v` = the 2A value).
    fake_dac,
    /// The fake's driver took a command (`v` = the id).
    fake_take,
};

pub const Hook = *const fn (ev: Event, frame: u32, t: u32, a: u32, v: u32) void;

/// The trace tool's sink; null: nothing is noted.
pub var hook: ?Hook = null;

/// The frame being stepped (`Md.step_frame_pads`): the renderer finishes a
/// frame after `frame_count` has moved on.
pub var cur_frame: u32 = 0;

/// Set by the Z80 bus around a YM2612 write: the Z80's own time, so the
/// oracle's synthesis places it there and not at the 68000's position
/// (core/sound.zig `now`).
pub var z80_t: ?u32 = null;

pub inline fn note(ev: Event, frame: u32, t: u32, a: u32, v: u32) void {
    if (comptime enabled) {
        if (hook) |h| h(ev, frame, t, a, v);
    }
}
