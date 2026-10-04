//! Register-level model of sound channels 1..3 (SPEC.md section 9), plus
//! sample generation for all four channels at the badge's 44,100 Hz
//! (docs/EMU_SOUND.md at the root; "Sample generation" below). The
//! register model is what the CPU sees and what keyframes hold; the
//! wasm build's single simulator voice reads it through `pick_voice`.
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
//! `gb.io`, so a keyframe copy captures it exactly (SPEC.md 10.3). The
//! renderer's own state (`Snd`) is not console state: see below.
//!
//! Sources: Pan Docs "Audio", "Audio Registers" and "Audio details"
//! (gbdev.io/pandocs), the gbdev wiki "Gameboy sound hardware" page.
const std = @import("std");
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
    // The sound so far was made with the registers as they were.
    if (gb.audio_render) {
        render_keep(gb, 0);
        noise_write(gb, reg, v);
    }
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
    if (gb.audio_render) {
        const r = gb.snd.?;
        switch (i) {
            c1, c2 => r.sq[i].ctr = sq_period(period_regs(gb, if (i == c1) nr13 else nr23)),
            else => {
                r.w_pos = 0;
                r.w_ctr = wave_period(period_regs(gb, nr33));
            },
        }
    }
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
    if (gb.audio_render) gb.snd.?.pend += dots;
    if (!powered(gb)) return;
    const a = &gb.apu;
    a.seq_t += dots;
    while (a.seq_t >= seq_period_dots) {
        a.seq_t -= seq_period_dots;
        // The step happened `seq_t` dots ago: render up to it first.
        if (gb.audio_render) render_keep(gb, a.seq_t);
        step_sequencer(gb);
    }
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
    if (gb.audio_render) clock_noise(gb, s);
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

// ---- Sample generation (docs/EMU_SOUND.md at the root) ----
//
// With `gb.audio_render` set (and `gb.snd` given), every stepped frame
// leaves the sound of exactly its console time in `snd.out[0..gb.audio_len]`:
// unsigned 8-bit mono at 44,100 Hz, 128 = silence, 738 or 739 samples a
// frame (70,224 dots / 95.109 dots per sample = 738.4; the fraction is the
// partial bin carried to the next frame). Time is counted in dots, which
// are real time at either CPU speed, so CGB double speed changes nothing
// here.
//
// Lazy: `tick` only adds the dots to `snd.pend`. The pending time is
// rendered with the registers as they are when they are about to change:
// before every APU register or wave RAM write (mmu.write_io has synced the
// subsystems by then), before every frame sequencer step (length, sweep,
// envelopes) and at the end of the frame. Reads change nothing audible.
//
// Box filter: sample bins are whole dots, 95 or 96 by a Bresenham walk
// (95 + 1201/11025, exactly 4,194,304 / 44,100), and each output is the
// mean level over its bin: per channel the number of dots at each level is
// integrated over the bin (`acc`), so a square far above 22 kHz gives its
// mean, not an alias.
//
// Per channel (Pan Docs "Audio details"): the squares step their 8-step
// duty pattern every (2048 - period) * 4 dots, the wave channel its 32
// 4-bit samples every (2048 - period) * 2 dots, the noise channel its LFSR
// every (divisor 0 ? 8 : 16 * divisor) << shift dots (shift 14, 15: no
// clocks). A channel sounds while it is on and its DAC is on, at its
// digital level 0..15 (square: duty bit * envelope volume; wave: the
// nibble >> 0/1/2 by NR32, code 0 mute; noise: inverted LFSR bit 0 *
// envelope volume). NR51 routes each channel left and/or right and NR50
// scales each side by 1..8; mono is the sum of both sides, so a channel on
// one side only is half as loud as on both.
//
// Left out: the DACs' analog offset (a DAC switching on or off would pop;
// the levels are mixed unsigned and the DC goes through the high-pass
// filter below instead, as the console's output capacitor does, so a
// silent or toggling channel does not thump), the wave channel's
// one-sample start delay and its "buffer" first sample, the square duty
// position reset on power off, Vin, and PCM12/PCM34 (read 0 as before).
//
// Channel 4 is not in the register model (NR52 bit 3 reads 0 as before):
// its length, envelope and LFSR are render state here, clocked only while
// rendering.
//
// Render state (`Snd`) is not console state: keyframes do not hold it,
// `Gb.load_small` and turning rendering on reset it (a restored position
// starts its phases and the noise channel afresh: a few ms of slightly
// different sound, never garbage). It is caller-owned memory (3.7 KB) so
// that the hot `Gb` fields keep their offsets.

/// Most samples one frame gives (`gb.audio_len`).
pub const max_samples = 739;
const acc_len = max_samples + 1;

/// Output gain: the mean mixed level (0..960: four channels x 15 x both
/// sides x NR50 8) after the high-pass filter, times `gain` / 256, around
/// 128. Measured on Tetris (DMG) and Tetris DX (CGB) over a minute each
/// of title, menus and play (host run, 2026-10-04): the 99.9th percentile
/// swing is about +-250 levels, so 80 / 256 puts it at +-77 (Tetris) and
/// +-95 (Tetris DX) of the +-127 available, loud for the badge's weak
/// speaker; 5 and 99 of ~2.6 million samples clip (clamped, longest run
/// 16 samples, on note attacks the high-pass overshoots). 96 clipped
/// runs of 28 samples, 200 clipped all the time.
pub const gain: i32 = 80;

const duty_patterns = [4]u8{ 0x80, 0x81, 0xE1, 0x7E };

pub const Sq = struct {
    /// Dots to the next duty step (1..period).
    ctr: u32 = 1,
    pos: u3 = 0,
};

/// The renderer's state and output (see above). `reset` makes a fresh
/// one; the frontend keeps it in .bss uninitialised until then.
pub const Snd = struct {
    sq: [2]Sq = .{ .{}, .{} },
    w_ctr: u32 = 1,
    w_pos: u5 = 0,
    n_ctr: u32 = 1,
    lfsr: u16 = 0x7FFF,
    n_on: bool = false,
    n_vol: u8 = 0,
    n_env: u8 = 0,
    n_len: u16 = 0,
    /// Dots ticked and not rendered yet.
    pend: u32 = 0,
    /// Bins completed this frame; `acc[bin]` is the one being filled.
    bin: u32 = 0,
    /// Dots left in the current bin, its length, and the Bresenham carry.
    left: u32 = 95,
    cur_len: u32 = 95,
    frac: u32 = 0,
    /// Length of this frame's bin 0 and the carry after it, to recover
    /// every bin's length when the frame is finished.
    f_len0: u32 = 95,
    f_frac: u32 = 0,
    /// More bins than `max_samples` this frame (an LCD switched on
    /// mid-frame makes a frame up to twice as long); the rest is dropped.
    over: bool = false,
    /// High-pass filter: last input and output (level x 16).
    hp_x: i32 = 0,
    hp_y: i32 = 0,
    hp_primed: bool = false,
    /// Level-dots per bin, weighted by the mixer.
    acc: [acc_len]u32 = @splat(0),
    out: [max_samples]u8 = @splat(128),

    /// A fresh state, without building a 3.7 KB default to copy.
    pub fn reset(s: *Snd) void {
        s.* = .{ .acc = undefined, .out = undefined };
        @memset(&s.acc, 0);
    }
};

/// Turn rendering on or off (the frontend's Sound setting). On from off
/// starts from a fresh `Snd`; `gb.snd` must be set first.
pub fn set_render(gb: *Gb, on: bool) void {
    if (on and !gb.audio_render) gb.snd.?.reset();
    gb.audio_render = on;
    gb.audio_len = 0;
}

/// The last stepped frame's samples (empty when not rendering).
pub fn samples(gb: *const Gb) []const u8 {
    const s = gb.snd orelse return &.{};
    return s.out[0..gb.audio_len];
}

inline fn next_len(frac: *u32) u32 {
    frac.* += 1201;
    if (frac.* >= 11025) {
        frac.* -= 11025;
        return 96;
    }
    return 95;
}

pub fn sq_period(x: u16) u32 {
    return (2048 - @as(u32, x & 0x7FF)) * 4;
}

pub fn wave_period(x: u16) u32 {
    return (2048 - @as(u32, x & 0x7FF)) * 2;
}

/// LFSR clock period in dots from NR43, 0 = never clocked (shift 14, 15).
pub fn noise_period(nr43v: u8) u32 {
    const shift: u5 = @intCast(nr43v >> 4);
    if (shift >= 14) return 0;
    const div: u32 = nr43v & 7;
    return (if (div == 0) @as(u32, 8) else 16 * div) << shift;
}

/// One LFSR clock (gbdev wiki form: XOR of bits 0 and 1 into bit 14, and
/// into bit 6 too in 7-bit mode; the channel is high while bit 0 is 0).
pub inline fn lfsr_step(l: u16, short: bool) u16 {
    const x: u16 = (l ^ (l >> 1)) & 1;
    var n = (l >> 1) | (x << 14);
    if (short) n = (n & ~@as(u16, 0x40)) | (x << 6);
    return n;
}

/// A square over one render span: level-dots in the next `n` dots,
/// advancing the duty position. Steps inside are skipped by whole
/// 8-step cycles, so a parked 131 kHz square costs no more than a note.
pub const SqSpan = struct {
    st: *Sq,
    p: u32,
    pat: u8,
    vol: u32,

    inline fn bit(self: *const SqSpan, pos: u3) u32 {
        return (self.pat >> pos) & 1;
    }

    pub fn sum(self: *const SqSpan, n: u32) u32 {
        const st = self.st;
        if (n < st.ctr) {
            st.ctr -= n;
            return self.bit(st.pos) * n * self.vol;
        }
        var hi = self.bit(st.pos) * st.ctr;
        var r = n - st.ctr;
        var pos = st.pos +% 1;
        const p = self.p;
        if (r >= p) {
            const k = r / p;
            r -= k * p;
            hi += (k >> 3) * @popCount(self.pat) * p;
            var j = k & 7;
            while (j > 0) : (j -= 1) {
                hi += self.bit(pos) * p;
                pos +%= 1;
            }
        }
        hi += self.bit(pos) * r;
        st.pos = pos;
        st.ctr = p - r;
        return hi * self.vol;
    }
};

/// The wave channel over one render span (same scheme, 32 steps).
pub const WaveSpan = struct {
    s: *Snd,
    ram: *const [16]u8,
    p: u32,
    shift: u3,

    inline fn lvl(self: *const WaveSpan, pos: u5) u32 {
        const b = self.ram[pos >> 1];
        const nib = if ((pos & 1) == 0) b >> 4 else b & 15;
        return nib >> self.shift;
    }

    pub fn sum(self: *const WaveSpan, n: u32) u32 {
        const s = self.s;
        if (n < s.w_ctr) {
            s.w_ctr -= n;
            return self.lvl(s.w_pos) * n;
        }
        var acc = self.lvl(s.w_pos) * s.w_ctr;
        var r = n - s.w_ctr;
        var pos = s.w_pos +% 1;
        const p = self.p;
        if (r >= p) {
            const k = r / p;
            r -= k * p;
            if (k >= 32) {
                var cyc: u32 = 0;
                for (0..32) |i| cyc += self.lvl(@intCast(i));
                acc += (k >> 5) * cyc * p;
            }
            var j = k & 31;
            while (j > 0) : (j -= 1) {
                acc += self.lvl(pos) * p;
                pos +%= 1;
            }
        }
        acc += self.lvl(pos) * r;
        s.w_pos = pos;
        s.w_ctr = p - r;
        return acc;
    }
};

/// The noise channel over one render span (one LFSR clock per step).
pub const NoiseSpan = struct {
    s: *Snd,
    p: u32,
    short: bool,
    vol: u32,

    pub fn sum(self: *const NoiseSpan, n: u32) u32 {
        const s = self.s;
        var l = s.lfsr;
        if (self.p == 0) return (~l & 1) * n * self.vol;
        if (n < s.n_ctr) {
            s.n_ctr -= n;
            return (~l & 1) * n * self.vol;
        }
        var hi: u32 = (~l & 1) * s.n_ctr;
        var r = n - s.n_ctr;
        l = lfsr_step(l, self.short);
        const p = self.p;
        while (r >= p) : (r -= p) {
            hi += (~l & 1) * p;
            l = lfsr_step(l, self.short);
        }
        hi += (~l & 1) * r;
        s.lfsr = l;
        s.n_ctr = p - r;
        return hi * self.vol;
    }
};

/// Add `w` x a channel's level-dots over the next `span` dots into the
/// bins from the current one on. With `w` 0 the channel only advances.
fn add_span(s: *Snd, ch: anytype, w: u32, span: u32) void {
    if (w == 0) {
        _ = ch.sum(span);
        return;
    }
    var bin = s.bin;
    var left = s.left;
    var frac = s.frac;
    var rem = span;
    while (rem > 0) {
        const take = @min(rem, left);
        s.acc[bin] += ch.sum(take) * w;
        rem -= take;
        left -= take;
        if (left == 0) {
            if (bin < max_samples) bin += 1;
            left = next_len(&frac);
        }
    }
}

/// Move the bin cursor `span` dots on (after every channel has added).
fn advance(s: *Snd, span: u32) void {
    var rem = span;
    while (rem >= s.left) {
        rem -= s.left;
        if (s.bin < max_samples) s.bin += 1 else s.over = true;
        s.cur_len = next_len(&s.frac);
        s.left = s.cur_len;
        // The overflow bin is reused, so it starts empty each time.
        if (s.bin == max_samples and s.over) s.acc[max_samples] = 0;
    }
    s.left -= rem;
}

/// Render the pending dots but the last `keep`.
fn render_keep(gb: *Gb, keep: u32) void {
    const s = gb.snd.?;
    if (s.pend <= keep) return;
    const span = s.pend - keep;
    s.pend = keep;
    render(gb, s, span);
}

fn render(gb: *Gb, s: *Snd, span: u32) void {
    if (powered(gb)) {
        const a = &gb.apu;
        const io = &gb.io;
        const nr50v = io[0x24];
        const nr51v: u32 = io[0x25];
        const lv: u32 = ((nr50v >> 4) & 7) + 1;
        const rv: u32 = (nr50v & 7) + 1;
        var w: [4]u32 = undefined;
        for (0..4) |c| w[c] = ((nr51v >> @intCast(4 + c)) & 1) * lv + ((nr51v >> @intCast(c)) & 1) * rv;
        if (a.ch[c1].on != 0) {
            const sq: SqSpan = .{ .st = &s.sq[0], .p = sq_period(a.current_period), .pat = duty_patterns[io[nr11] >> 6], .vol = a.ch[c1].volume };
            add_span(s, &sq, if (sq.vol == 0) 0 else w[0], span);
        }
        if (a.ch[c2].on != 0) {
            const sq: SqSpan = .{ .st = &s.sq[1], .p = sq_period(period_regs(gb, nr23)), .pat = duty_patterns[io[nr21] >> 6], .vol = a.ch[c2].volume };
            add_span(s, &sq, if (sq.vol == 0) 0 else w[1], span);
        }
        if (a.ch[c3].on != 0 and dac_on(gb, c3)) {
            const code = (io[nr32] >> 5) & 3;
            const wv: WaveSpan = .{ .s = s, .ram = io[0x30..0x40], .p = wave_period(period_regs(gb, nr33)), .shift = if (code == 0) 0 else @intCast(code - 1) };
            add_span(s, &wv, if (code == 0) 0 else w[2], span);
        }
        if (s.n_on) {
            const nr43v = io[nr43];
            const nz: NoiseSpan = .{ .s = s, .p = noise_period(nr43v), .short = (nr43v & 8) != 0, .vol = s.n_vol };
            add_span(s, &nz, if (nz.vol == 0) 0 else w[3], span);
        }
    }
    advance(s, span);
}

/// Finish the frame: render what is pending, turn the completed bins into
/// `snd.out`, carry the partial bin. Called by `Gb.step_frame`.
pub fn end_frame(gb: *Gb) void {
    const s = gb.snd.?;
    render_keep(gb, 0);
    const n = s.bin;
    var len = s.f_len0;
    var frac = s.f_frac;
    for (0..n) |i| {
        // Mean level x 16 over the bin.
        const x: i32 = @intCast(s.acc[i] * 16 / len);
        if (!s.hp_primed) {
            s.hp_primed = true;
            s.hp_x = x;
        }
        // y += x - x' - y / 256: a first-order high-pass at ~27 Hz, about
        // the console's output capacitor (Pan Docs "Audio details").
        s.hp_y += x - s.hp_x - (s.hp_y >> 8);
        s.hp_x = x;
        const v = 128 + ((s.hp_y * gain) >> 12);
        s.out[i] = @intCast(std.math.clamp(v, 0, 255));
        len = next_len(&frac);
    }
    gb.audio_len = @intCast(n);
    const carry = if (s.over) 0 else s.acc[n];
    @memset(s.acc[0 .. n + 1], 0);
    s.acc[0] = carry;
    s.bin = 0;
    s.over = false;
    s.f_len0 = s.cur_len;
    s.f_frac = s.frac;
}

// Channel 4 render state (not in the register model).

const nr42 = 0x21;
const nr43 = 0x22;
const nr44 = 0x23;

fn noise_write(gb: *Gb, reg: u8, v: u8) void {
    const s = gb.snd.?;
    switch (reg) {
        nr41 => s.n_len = 64 - @as(u16, v & 0x3F),
        nr42 => if (powered(gb) and (v & 0xF8) == 0) {
            s.n_on = false;
        },
        nr44 => if (powered(gb) and (v & 0x80) != 0) {
            const nr42v = gb.io[nr42];
            if (s.n_len == 0) s.n_len = 64;
            s.n_vol = nr42v >> 4;
            s.n_env = env_reload(nr42v);
            s.lfsr = 0x7FFF;
            s.n_ctr = @max(1, noise_period(gb.io[nr43]));
            s.n_on = (nr42v & 0xF8) != 0;
        },
        nr52 => if ((v & 0x80) == 0) {
            s.n_on = false;
            s.n_vol = 0;
        },
        else => {},
    }
}

/// Channel 4's share of a sequencer step `step` (length on even steps,
/// envelope on step 7), as channels 1..3 get theirs.
fn clock_noise(gb: *Gb, step: u8) void {
    const s = gb.snd.?;
    if ((step & 1) == 0 and (gb.io[nr44] & 0x40) != 0 and s.n_len != 0) {
        s.n_len -= 1;
        if (s.n_len == 0) s.n_on = false;
    }
    if (step == 7) {
        const nr42v = gb.io[nr42];
        if ((nr42v & 7) == 0) return;
        if (s.n_env > 0) s.n_env -= 1;
        if (s.n_env != 0) return;
        s.n_env = env_reload(nr42v);
        if ((nr42v & 0x08) != 0) {
            if (s.n_vol < 15) s.n_vol += 1;
        } else {
            if (s.n_vol > 0) s.n_vol -= 1;
        }
    }
}
