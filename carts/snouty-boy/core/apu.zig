//! Register-level model of sound channels 1..3 for the frontend's single
//! voice (SPEC.md section 9). No samples are produced: the model tracks what
//! a listener would hear per channel (enabled, period, envelope volume) so
//! the frontend can pick one voice for the badge buzzer.
//!
//! Modelled: frame sequencer at 512 Hz (2048 M-cycles per step; length on
//! steps 0/2/4/6, sweep on 2/6, envelope on 7), trigger, length counters,
//! envelopes, ch1 frequency sweep with the overflow check, DACs (NRx2 upper
//! bits for ch1/2, NR30 bit 7 for ch3), NR52 power (off clears registers,
//! length counters survive and NRx1 length writes still land, as on DMG)
//! and NR52 status bits, documented read masks. Not modelled: channel 4,
//! sample generation, wave RAM playback position, the frame sequencer's DIV
//! coupling, and the obscure length/sweep quirks (extra length clock on
//! enable, negate-mode clear).
//!
//! All state is integers in `Apu` (extern, no padding) plus the registers in
//! `gb.io`, so a keyframe copy captures it exactly (SPEC.md 10.3).
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

/// Channel indices into `Apu.ch`.
const c1 = 0;
const c2 = 1;
const c3 = 2;

/// M-cycles per frame sequencer step (8192 T-cycles).
pub const seq_period: u16 = 2048;
/// `seq_period` in dots (`seq_t` counts dots).
pub const seq_period_dots: u16 = seq_period * 4;

pub const Chan = extern struct {
    /// 1 when the channel is on (mirrors its NR52 status bit).
    on: u8 = 0,
    /// Envelope volume 0..15 (ch1/ch2 only).
    volume: u8 = 0,
    /// Envelope countdown (ch1/ch2 only).
    env_timer: u8 = 0,
    _pad: u8 = 0,
    /// Length counter: 0..64 for ch1/ch2, 0..256 for ch3.
    length: u16 = 0,
};

pub const Apu = extern struct {
    ch: [3]Chan = @splat(.{}),
    /// Ch1 period after sweep (11 bits), kept equal to NR13/NR14.
    current_period: u16 = 0,
    /// Ch1 sweep shadow register.
    sweep_shadow: u16 = 0,
    sweep_timer: u8 = 0,
    sweep_enabled: u8 = 0,
    /// Frame sequencer position (0..7), stepped at 512 Hz.
    seq: u8 = 0,
    _pad: u8 = 0,
    /// M-cycles accumulated towards the next sequencer step.
    seq_t: u16 = 0,
    _pad2: u16 = 0,
};

/// Register offsets from 0xFF00.
const nr10 = 0x10;
const nr11 = 0x11;
const nr12 = 0x12;
const nr13 = 0x13;
const nr14 = 0x14;
const nr21 = 0x16;
const nr22 = 0x17;
const nr23 = 0x18;
const nr24 = 0x19;
const nr30 = 0x1A;
const nr31 = 0x1B;
const nr32 = 0x1C;
const nr33 = 0x1D;
const nr34 = 0x1E;
const nr41 = 0x20;
const nr52 = 0x26;

/// Post-boot state to match `mmu.reset_io` (NR52 = 0xF1: ch1 on, silent).
pub fn reset(gb: *Gb) void {
    gb.apu = .{};
    gb.apu.ch[c1].on = 1;
    gb.apu.current_period = period_regs(gb, nr13);
    sync_nr52(gb);
}

inline fn powered(gb: *const Gb) bool {
    return (gb.io[nr52] & 0x80) != 0;
}

fn sync_nr52(gb: *Gb) void {
    const a = &gb.apu;
    var v: u8 = (gb.io[nr52] & 0x80) | 0x70;
    if (a.ch[c1].on != 0) v |= 1;
    if (a.ch[c2].on != 0) v |= 2;
    if (a.ch[c3].on != 0) v |= 4;
    gb.io[nr52] = v;
}

fn period_regs(gb: *const Gb, lo: u8) u16 {
    return @as(u16, gb.io[lo]) | (@as(u16, gb.io[lo + 1] & 7) << 8);
}

/// DMG read masks for 0xFF10..0xFF3F (1 bits read back as 1).
const read_masks = [0x30]u8{
    0x80, 0x3F, 0x00, 0xFF, 0xBF, // NR10..NR14
    0xFF, 0x3F, 0x00, 0xFF, 0xBF, // unused, NR21..NR24
    0x7F, 0xFF, 0x9F, 0xFF, 0xBF, // NR30..NR34
    0xFF, 0xFF, 0x00, 0x00, 0xBF, // unused, NR41..NR44
    0x00, 0x00, 0x70, // NR50, NR51, NR52
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 0x27..0x2F
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // wave RAM
};

/// Read of 0xFF10..0xFF3F (`reg` is the offset from 0xFF00).
pub fn read_reg(gb: *const Gb, reg: u8) u8 {
    return gb.io[reg] | read_masks[reg - 0x10];
}

/// Write of 0xFF10..0xFF3F (`reg` is the offset from 0xFF00).
pub fn write_reg(gb: *Gb, reg: u8, v: u8) void {
    if (reg >= 0x30) {
        gb.io[reg] = v; // wave RAM
        return;
    }
    if (reg == nr52) {
        write_nr52(gb, v);
        return;
    }
    if (!powered(gb)) {
        // DMG: length counters stay writable while powered off.
        switch (reg) {
            nr11, nr21 => set_length(gb, reg, v & 0x3F),
            nr31 => set_length(gb, reg, v),
            nr41 => gb.io[reg] = v & 0x3F,
            else => {},
        }
        return;
    }
    const a = &gb.apu;
    gb.io[reg] = v;
    switch (reg) {
        nr11, nr21, nr31 => set_length(gb, reg, v),
        nr12, nr22 => if ((v & 0xF8) == 0) {
            a.ch[if (reg == nr12) c1 else c2].on = 0;
        },
        nr30 => if ((v & 0x80) == 0) {
            a.ch[c3].on = 0;
        },
        nr13 => a.current_period = period_regs(gb, nr13),
        nr14 => {
            a.current_period = period_regs(gb, nr13);
            if ((v & 0x80) != 0) trigger(gb, c1);
        },
        nr24 => if ((v & 0x80) != 0) trigger(gb, c2),
        nr34 => if ((v & 0x80) != 0) trigger(gb, c3),
        else => {},
    }
    sync_nr52(gb);
}

fn set_length(gb: *Gb, reg: u8, v: u8) void {
    switch (reg) {
        nr11 => gb.apu.ch[c1].length = 64 - @as(u16, v & 0x3F),
        nr21 => gb.apu.ch[c2].length = 64 - @as(u16, v & 0x3F),
        nr31 => gb.apu.ch[c3].length = 256 - @as(u16, v),
        else => unreachable,
    }
    if (!powered(gb)) gb.io[reg] = if (reg == nr31) v else v & 0x3F;
}

fn write_nr52(gb: *Gb, v: u8) void {
    const was_on = powered(gb);
    if ((v & 0x80) == 0) {
        if (was_on) {
            // Power off: every register 0xFF10..0xFF25 reads back as zero
            // (plus masks); length counters are kept (DMG).
            var r: u8 = 0x10;
            while (r < 0x26) : (r += 1) gb.io[r] = 0;
            for (&gb.apu.ch) |*c| {
                c.on = 0;
                c.volume = 0;
                c.env_timer = 0;
            }
            gb.apu.current_period = 0;
            gb.apu.sweep_shadow = 0;
            gb.apu.sweep_timer = 0;
            gb.apu.sweep_enabled = 0;
        }
        gb.io[nr52] = 0;
    } else {
        if (!was_on) {
            // Power on: the next sequencer step is step 0.
            gb.apu.seq = 0;
            gb.apu.seq_t = 0;
        }
        gb.io[nr52] = 0x80;
    }
    sync_nr52(gb);
}

fn dac_on(gb: *const Gb, i: usize) bool {
    return switch (i) {
        c1 => (gb.io[nr12] & 0xF8) != 0,
        c2 => (gb.io[nr22] & 0xF8) != 0,
        else => (gb.io[nr30] & 0x80) != 0,
    };
}

fn trigger(gb: *Gb, i: usize) void {
    const a = &gb.apu;
    const c = &a.ch[i];
    if (c.length == 0) c.length = if (i == c3) 256 else 64;
    if (i != c3) {
        const nrx2 = gb.io[if (i == c1) nr12 else nr22];
        c.volume = nrx2 >> 4;
        c.env_timer = env_reload(nrx2);
    }
    c.on = @intFromBool(dac_on(gb, i));
    if (i == c1) {
        const nr10v = gb.io[nr10];
        const per = (nr10v >> 4) & 7;
        const shift = nr10v & 7;
        a.sweep_shadow = a.current_period;
        a.sweep_timer = if (per == 0) 8 else per;
        a.sweep_enabled = @intFromBool(per != 0 or shift != 0);
        if (shift != 0) _ = sweep_calc(gb);
    }
}

fn env_reload(nrx2: u8) u8 {
    const p = nrx2 & 7;
    return if (p == 0) 8 else p;
}

/// Next sweep period; disables ch1 when it overflows 2047.
fn sweep_calc(gb: *Gb) u16 {
    const a = &gb.apu;
    const nr10v = gb.io[nr10];
    const delta = a.sweep_shadow >> @intCast(nr10v & 7);
    const new: u16 = if ((nr10v & 0x08) != 0) a.sweep_shadow - delta else a.sweep_shadow + delta;
    if (new > 2047) a.ch[c1].on = 0;
    return new;
}

/// Advance `dots` dots (4 per normal-speed M-cycle): the frame sequencer
/// runs at 512 Hz at either CPU speed (SPEC.md 19.1).
/// Inlined into the per-instruction tick; a sequencer step calls out.
pub inline fn tick(gb: *Gb, dots: u16) void {
    if (!powered(gb)) return;
    const a = &gb.apu;
    a.seq_t += dots;
    if (a.seq_t < seq_period_dots) return;
    a.seq_t -= seq_period_dots;
    step_sequencer(gb);
}

/// One 512 Hz frame sequencer step. Public for tests.
pub fn step_sequencer(gb: *Gb) void {
    const a = &gb.apu;
    const s = a.seq;
    a.seq = (s + 1) & 7;
    if ((s & 1) == 0) clock_length(gb);
    if (s == 2 or s == 6) clock_sweep(gb);
    if (s == 7) {
        clock_envelope(gb, c1, gb.io[nr12]);
        clock_envelope(gb, c2, gb.io[nr22]);
    }
    sync_nr52(gb);
}

fn clock_length(gb: *Gb) void {
    const nrx4 = [3]u8{ nr14, nr24, nr34 };
    for (&gb.apu.ch, nrx4) |*c, r| {
        if ((gb.io[r] & 0x40) == 0 or c.length == 0) continue;
        c.length -= 1;
        if (c.length == 0) c.on = 0;
    }
}

fn clock_envelope(gb: *Gb, i: usize, nrx2: u8) void {
    const c = &gb.apu.ch[i];
    if ((nrx2 & 7) == 0) return;
    if (c.env_timer > 0) c.env_timer -= 1;
    if (c.env_timer != 0) return;
    c.env_timer = env_reload(nrx2);
    if ((nrx2 & 0x08) != 0) {
        if (c.volume < 15) c.volume += 1;
    } else {
        if (c.volume > 0) c.volume -= 1;
    }
}

fn clock_sweep(gb: *Gb) void {
    const a = &gb.apu;
    if (a.sweep_timer > 0) a.sweep_timer -= 1;
    if (a.sweep_timer != 0) return;
    const nr10v = gb.io[nr10];
    const per = (nr10v >> 4) & 7;
    a.sweep_timer = if (per == 0) 8 else per;
    if (a.sweep_enabled == 0 or per == 0) return;
    const new = sweep_calc(gb);
    if (new <= 2047 and (nr10v & 7) != 0) {
        a.sweep_shadow = new;
        a.current_period = new;
        gb.io[nr13] = @truncate(new);
        gb.io[nr14] = (gb.io[nr14] & 0xF8) | @as(u8, @intCast(new >> 8));
        _ = sweep_calc(gb);
    }
}

// ---- Frontend query (SPEC.md section 9) ----

pub const Voice = struct {
    /// 1..3, 0 = nothing audible.
    channel: u8 = 0,
    /// 11-bit period value x.
    period: u16 = 0,
    /// 0..15; for ch3 the NR32 code mapped to 15/7/3.
    volume: u8 = 0,
    /// NRx1 bits 7..6 for ch1/ch2.
    duty: u8 = 0,
    /// NR32 bits 6..5 for ch3.
    wave_volume_code: u8 = 0,
};

/// Ch3 output level code (NR32 bits 6..5) as a 0..15 volume.
pub fn wave_code_volume(code: u8) u8 {
    return switch (code & 3) {
        0 => 0,
        1 => 15,
        2 => 7,
        else => 3,
    };
}

/// The channel the buzzer should play: the loudest enabled channel, ties
/// ch1 > ch2 > ch3. `channel == 0` when nothing is audible.
pub fn pick_voice(gb: *const Gb) Voice {
    var best: Voice = .{};
    if (!powered(gb)) return best;
    const a = &gb.apu;
    if (a.ch[c1].on != 0 and a.ch[c1].volume > 0) {
        best = .{ .channel = 1, .period = a.current_period, .volume = a.ch[c1].volume, .duty = gb.io[nr11] >> 6 };
    }
    if (a.ch[c2].on != 0 and a.ch[c2].volume > best.volume) {
        best = .{ .channel = 2, .period = period_regs(gb, nr23), .volume = a.ch[c2].volume, .duty = gb.io[nr21] >> 6 };
    }
    const code = (gb.io[nr32] >> 5) & 3;
    const wv = wave_code_volume(code);
    if (a.ch[c3].on != 0 and dac_on(gb, c3) and wv > best.volume) {
        best = .{ .channel = 3, .period = period_regs(gb, nr33), .volume = wv, .wave_volume_code = code };
    }
    return best;
}

/// Tone frequency in whole Hz (rounded): 131072 / (2048 - x) for the
/// squares (ch1/ch2), 65536 / (2048 - x) for the wave channel (ch3).
pub fn period_to_hz(channel: u8, period: u16) u32 {
    const num: u32 = if (channel == 3) 65536 else 131072;
    const d: u32 = 2048 - @as(u32, period & 0x7FF);
    return (num + d / 2) / d;
}
