//! Streamed sound for the badge's new firmware (PLAN.md "Sound on the new
//! firmware (2026-10-04)", docs/EMU_SOUND.md at the repository root): the
//! YM2612 (`ym2612.Fm`) and the PSG (`psg.Synth`) rendered from the
//! register model into unsigned 8-bit mono samples at 44.1 kHz, 128 =
//! silence, for the frontend's `audio_feed`.
//!
//! The RAM cart only (`enabled`, `build_options.synth`): its Z80 is the
//! stub, so what plays is what the 68000 writes to the chips itself (Sonic
//! 1's SMPS drives FM and PSG from the 68000; its DAC drums are the Z80's
//! and stay silent, as does all of a Z80-driven game such as Miniplanets'
//! Echo engine). The XIP cart and the simulator keep `Md.tone()`.
//!
//! Timing: a sample's bin is 1/44,100 s of console time. Positions are
//! Q12 samples from the frame's first bin: `phase` (the carried fraction
//! of the last frame's straddling bin) plus master clocks x `q12_per_clock`.
//! A write to either chip first renders up to its console time (the
//! 68000's line and cycle in it, `now`); the frame's end renders the rest.
//! After the frames of one update `out[0..len]` holds their samples (two
//! NTSC frames: 1,471 or 1,472) and the frontend `take`s them.
//!
//! Render-only: nothing here is console state, so keyframes, goldens and
//! the register model are untouched; `resync` (power on, Z80 RESET,
//! rendering switched on) starts the envelopes over from the registers.
//! `render` false: no hook does anything but the register write.
const md_mod = @import("md.zig");
const Md = md_mod.Md;
const ym2612 = @import("ym2612.zig");
const psg = @import("psg.zig");
const vdp = @import("vdp.zig");
const tunables = @import("tunables.zig");

pub const enabled: bool = ym2612.synth_enabled;

/// Most samples one frame makes (735.95 at NTSC).
pub const frame_max: u32 = 737;
/// `out`'s size: the frames of one update.
pub const max_samples: u32 = tunables.render_every * frame_max;

/// Master clocks per line and per frame (262 x 3420).
const line_clocks: u32 = 3420;
const frame_clocks: u32 = vdp.lines_per_frame * line_clocks;
/// Q12 samples per master clock, Q20: 44100 * 4096 / 53693175 * 2^20.
const q12_per_clock: u64 = 3_527_600;
const frame_q12: u32 = @intCast((@as(u64, frame_clocks) * q12_per_clock) >> 20);

/// The mix to 8 bits: (FM + PSG) * mix_gain >> 16, after the DC blocker.
/// The FM channels are +-8191 each, a PSG channel at most +-2600
/// (core/ym_tables.zig). Chosen from Sonic 1 in this cart (68000-driven
/// FM and PSG, the RAM cart's case): at 512 its title music peaks at
/// +-90..120 of the 127 available with an RMS near 23 and no clipped
/// sample, loud for the weak speaker; a full six-channel chord would clip
/// briefly rather than everything being quiet.
pub const mix_gain: i32 = 512;

/// The DC blocker's pole, Q15: 1 - 2 pi 20 / 44100.
const dc_pole: i32 = 32674;

pub const Sound = struct {
    /// Render (the frontend's Sound setting); false: hooks only write.
    render: bool = false,
    fm: ym2612.Fm = .{},
    psg: psg.Synth = .{},
    /// Where the update's samples go (the frontend's buffer for one update,
    /// `begin_update`; empty: nothing is rendered), and the count so far.
    out: []u8 = &.{},
    len: u32 = 0,
    /// This frame's first sample in `out`, and samples rendered of it.
    base: u32 = 0,
    done: u32 = 0,
    /// Q12 position of the frame's start inside its first bin.
    phase: u32 = 0,
    /// The FM value held between evaluations (`tunables.fm_rate_div`).
    fm_val: i32 = 0,
    fm_div: u32 = 0,
    /// The DC blocker's last input and output (`render_to`).
    dc_x: i32 = 0,
    dc_y: i32 = 0,

    /// Set up a `Sound` in place (it is ~2 KB: never build one by value),
    /// not rendering; `Md.snd` points at it.
    pub fn init(s: *Sound) void {
        s.render = false;
        s.out = &.{};
        s.len = 0;
        s.base = 0;
        s.done = 0;
        s.phase = 0;
        s.fm_val = 0;
        s.fm_div = 0;
        s.dc_x = 0;
        s.dc_y = 0;
        s.psg.reset();
        for (&s.fm.op) |*ops| for (ops) |*o| {
            o.* = .{};
        };
        for (&s.fm.ch) |*c| c.* = .{};
    }

    /// Switch rendering on or off between frames; on starts over from the
    /// registers (`resync`).
    pub fn set_render(s: *Sound, md: *const Md, on: bool) void {
        if (on and !s.render) {
            s.resync(md);
            s.len = 0;
        }
        s.render = on;
    }

    /// Start over from the registers (the console's power-on, its Z80
    /// RESET line, or rendering switched on).
    pub fn resync(s: *Sound, md: *const Md) void {
        s.fm.resync(&md.ym);
        s.psg.reset();
        s.fm_val = 0;
        s.fm_div = 0;
    }

    /// The next frames render into `buf` (`max_samples` holds one update).
    /// The RAM cart has no room for a static one: the frontend lends a
    /// buffer on its stack for the update (`take` before it returns).
    pub fn begin_update(s: *Sound, buf: []u8) void {
        s.out = buf;
        s.len = 0;
    }

    /// Hand the update's samples over; nothing renders until the next
    /// `begin_update`.
    pub fn take(s: *Sound) []const u8 {
        const r = s.out[0..s.len];
        s.out = &.{};
        s.len = 0;
        return r;
    }

    pub fn begin_frame(s: *Sound) void {
        // No buffer, or one already full: drop the samples.
        if (s.len + frame_max > s.out.len) s.len = 0;
        s.base = s.len;
        s.done = 0;
    }

    pub fn end_frame(s: *Sound, md: *const Md) void {
        const end = s.phase + frame_q12;
        s.render_to(md, end >> 12);
        s.phase = end & 0xFFF;
        s.len = s.base + s.done;
    }

    /// Render up to master clock `t` of the frame.
    fn catch_up(s: *Sound, md: *const Md, t: u32) void {
        const pos = s.phase + @as(u32, @intCast((@as(u64, @min(t, frame_clocks)) * q12_per_clock) >> 20));
        s.render_to(md, pos >> 12);
    }

    fn render_to(s: *Sound, md: *const Md, n: u32) void {
        const to = @min(n, frame_max);
        if (to <= s.done or s.base + frame_max > s.out.len) return;
        const dst = s.out[s.base + s.done .. s.base + to];
        for (dst) |*d| {
            if (s.fm_div == 0) s.fm_val = s.fm.sample(&md.ym);
            s.fm_div += 1;
            if (s.fm_div == tunables.fm_rate_div) s.fm_div = 0;
            // A one-pole DC blocker (~20 Hz): a DAC left enabled at a
            // constant value, or the PSG's held-high periods, would
            // otherwise sit off centre and eat half the headroom.
            const x = s.fm_val + s.psg.sample(&md.psg);
            s.dc_y = x - s.dc_x + @as(i32, @intCast((@as(i64, s.dc_y) * dc_pole) >> 15));
            s.dc_x = x;
            const v = (s.dc_y * mix_gain) >> 16;
            d.* = @intCast(@max(0, @min(255, v + 128)));
        }
        s.done = to;
    }
};

/// Console time now, master clocks into the frame: the 68000's line and
/// its cycle in the line (the only CPU that writes the chips here).
inline fn now(md: *const Md) u32 {
    const c: u32 = @min(md.vdp.line_cycles, vdp.m68k_cycles_per_line);
    return @as(u32, md.vdp.line) * line_clocks + c * 7;
}

/// The active renderer, or null.
pub inline fn active(md: *const Md) ?*Sound {
    if (comptime !enabled) return null;
    const s = md.snd orelse return null;
    return if (s.render) s else null;
}

/// A YM2612 data port write (4001 / 4003 from either CPU's side).
pub inline fn ym_data(md: *Md, part: u1, v: u8) void {
    if (comptime enabled) {
        if (active(md)) |s| return ym_data_render(s, md, part, v);
    }
    md.ym.write_data(part, v);
}

noinline fn ym_data_render(s: *Sound, md: *Md, part: u1, v: u8) void {
    const r = md.ym.addr[part];
    // Timer and mode writes that change nothing audible skip the catch-up.
    if (!(part == 0 and r >= 0x24 and r <= 0x27 and (r != 0x27 or (v ^ md.ym.regs[0][0x27]) & 0xC0 == 0)))
        s.catch_up(md, now(md));
    md.ym.write_data(part, v);
    s.fm.written(&md.ym, part, r);
}

/// A PSG port write (C00011 or Z80 7F11).
pub inline fn psg_write(md: *Md, v: u8) void {
    if (comptime enabled) {
        if (active(md)) |s| return psg_write_render(s, md, v);
    }
    md.psg.write(v);
}

noinline fn psg_write_render(s: *Sound, md: *Md, v: u8) void {
    s.catch_up(md, now(md));
    md.psg.write(v);
    s.psg.written(&md.psg);
}

/// After `md.ym` was reset (power on, Z80 RESET).
pub inline fn ym_was_reset(md: *Md) void {
    if (comptime enabled) {
        if (active(md)) |s| s.fm.resync(&md.ym);
    }
}
