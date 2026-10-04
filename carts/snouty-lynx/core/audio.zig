//! Mikey's four audio channels, heard (PLAN.md "M5 Sound: contract",
//! SPEC.md section 9): registers $FD20-$FD3F, the Lynx II stereo
//! registers ATTEN_A-D $FD40-$FD43, MPAN $FD44 and MSTEREO $FD50, the
//! polynomial counters, integrate mode, the DAC writes, the link chain
//! timer 7 -> audio 0 -> 1 -> 2 -> 3 -> timer 1, and the mix into
//! `Lynx.audio_out`.
//!
//! Sources: the Epyx hardware appendix (https://www.monlynx.de/lynx/hardware.html,
//! "Audio": the register bits, the output value rules, "hardware clipping
//! at max and min"), the audio chapter (https://www.monlynx.de/lynx/lynx7.html:
//! the channel specification, "the inversion of the output of the gate is
//! used as the data input to the shift register", the integrate example
//! 9,18,27,18,9,0, "the running total clips rather than wrap around", the
//! prescaler registers "behave exactly as any timer", FD50/FD40-FD44 as
//! the stereo upgrade), cc65's include/_mikey.h (the channel layout,
//! ATTEN/MPAN/MSTEREO addresses and masks). Read for what the documents
//! leave open, nothing copied: Handy (libretro-handy lynx/mikie.cpp, its
//! UpdateSound: MSTEREO bit set = channel off in that ear, MPAN bit set =
//! that ear attenuated by the ATTEN nibble / 16, left ear in the high
//! nibbles) and Felix (https://github.com/laoo/Felix, MIT,
//! AudioChannel.cpp: the 12-bit tap mask from FEEDBACK and CONTROL bit 7).
//!
//! Output polarity follows the documents and Handy: the new shift-register
//! bit (the inverted XOR of the selected taps) 1 selects +VOLUME (adds it
//! in integrate mode), 0 selects -VOLUME (Felix uses the opposite sign;
//! it only flips a channel's phase, and in integrate mode the slope).
//!
//! The channel model (all CPU-visible state lives in `Mikey.audio`, so
//! `Lynx.Small`, the scrubber and determinism cover it):
//!
//! - Each channel's counter is a `mikey.Timer` and counts exactly as the
//!   timers do (core/mikey.zig: global prescaler edges, `16 << sel` ticks,
//!   reload, one-shot DONE, RESET_DONE as a level, the OTHER borrow-in bit
//!   clocking once). Sel 7 links: audio 0 to timer 7, audio n to audio
//!   n-1; audio 3's borrow clocks timer 1 when timer 1 is linked.
//! - On each underflow the 12-bit shift register shifts left, the new bit
//!   0 the complement of the XOR of the taps (FEEDBACK bits 5-0 = taps
//!   5-0, bits 7-6 = taps 11-10, CONTROL bit 7 = tap 7), and OUTPUT
//!   becomes +/-VOLUME (8-bit two's complement) or, in integrate mode,
//!   OUTPUT +/- VOLUME clamped to -128..127.
//! - A CPU write to OUTPUT sets the DAC directly (sampled sound).
//!
//! Laziness: nothing runs per underflow on Mikey's event list. The
//! channels are caught up (`catch_up`) when the CPU reads or writes any
//! audio register, before any timer register write (timer 7 may feed
//! audio 0; timer 1 may become linked), before a timer 7 read, at a
//! rebase, when timer 7 borrows into a linked audio 0 through Mikey's
//! own underflow path (timer 7 an interrupt event, linked, or a software
//! borrow), and at the end of `step_frame`. A free-running quiet timer 7
//! feeding audio 0 is followed in closed form (its underflows are an
//! arithmetic sequence from its `expire`; nothing settles it before the
//! channels are caught up). Only while timer 1 is linked and counting are
//! the channels' underflows Mikey events (`Mikey.aud_event`), so timer 1
//! counts at the right tick (rare: no known game links it).
//!
//! Speed: a catch-up runs the underflows in time order, but a channel
//! whose borrow nobody counts runs alone up to the next other underflow
//! (`run_channel`), and squares and constants (normal mode, tap 0 only or
//! no taps: Blue Lightning parks its music channels as 1 MHz squares, 16,667
//! underflows a frame each) go in closed form together (`joint`), with
//! bin values bit-identical to one underflow at a time (a test checks).
//! Settled silence fills bins with 128 directly.
//!
//! Mix (`mono_level`): per channel the left and right weights in 1/16
//! (16 = full, 0 = MSTEREO off, the ATTEN nibble when MPAN selects it),
//! averaged to mono: contribution = OUTPUT * (left + right) in 1/32. With
//! the reset values (all 0: every channel in both ears, no attenuation)
//! a Lynx I game hears the plain sum of the four DACs. The four are
//! summed (no clamp: Mikey's digital mixer is not documented further).
//!
//! Bins: the summed level is a step function of the 16 MHz clock; each of
//! the frame's 735 bins (edges at `frame_start + floor(i * n / 735)`) gets
//! its exact time average (a box filter), rendered progressively in time
//! order as the catch-ups go (`render_to`), the gain applied and clamped
//! around 128. The level at a change past the frame's end (an instruction
//! or a sprite run overshooting it) goes into a small log replayed at the
//! next `begin_frame` (`log_len` entries; beyond that a change is merged
//! into the last entry, a timing error of at most that overshoot).
//!
//! Simplified (with reasons):
//! - OTHER bits 2-0 (last clock, borrow in, borrow out) read 0, as the
//!   timers' CTLB does (core/mikey.zig): momentary states between clocks.
//! - The PWM converter's lower-nybble glitch (lynx7.html "Bug in the
//!   Lower nybble") and the 4 kHz output filter are not modelled: the
//!   badge's speaker filters far more than that.
//! - The audio units' turn in the 16-slot round robin delays only the bus
//!   access (core/bus.zig), not the clock edges (as the timers).

const std = @import("std");
const mikey = @import("mikey.zig");
const lynx = @import("lynx.zig");

const Mikey = mikey.Mikey;
const Timer = mikey.Timer;
const Tick = mikey.Tick;
const never = mikey.ticks_never;
const Ctla = mikey.Ctla;
const Ctlb = mikey.Ctlb;

/// The badge firmware's streaming rate (sycl-badge upstream api.zig
/// `audio_sample_rate`).
pub const sample_rate: u32 = 44100;
/// 1/60 s at `sample_rate`, exactly.
pub const samples_per_frame: u32 = sample_rate / 60;
/// The unsigned 8-bit midpoint.
pub const silence: u8 = 128;

comptime {
    if (samples_per_frame * 60 != sample_rate) @compileError("44.1 kHz / 60 must be whole");
}

/// Output gain in eighths of "one DAC step = one output step": sample =
/// 128 + (sum of the four channels' OUTPUT, DC-blocked) * 3 / 8 when no
/// stereo register is used, so the 8-bit range holds a sum of +/-340 (the
/// four DACs reach +/-512). Chosen from the games' levels (M5, run-lynx,
/// share of samples clipped / RMS of 127 at 1/4, 3/8, 1/2, 1): Blue
/// Lightning's title music and flight (three or four square channels at
/// volume 70-105) 0% / 1.0-1.3% / 5-6% / 30% clipped; Hard Drivin's
/// title music and engine (much softer) never clip, RMS 9 / 13 / 18 / 35.
/// 3/8 is the loudest setting at which the loud game clips only where its
/// channels' peaks coincide; above it Blue Lightning's music flattens
/// audibly, below it Hard Drivin' gets quieter for nothing. raycast is
/// silent (its channels stay at 0, and it switches them off in MSTEREO).
pub const gain_eighths: i32 = 3;

/// CONTROL ($FD25 etc.) bits beyond the timer's CTLA ones.
pub const Control = struct {
    pub const tap7: u8 = 0x80;
    pub const integrate: u8 = 0x20;
};

/// Register offsets ($FD00 + x) of channel 0; channel n adds 8 * n.
pub const Reg = struct {
    pub const volume: u8 = 0x20;
    pub const feedback: u8 = 0x21;
    pub const output: u8 = 0x22;
    pub const shift: u8 = 0x23;
    pub const backup: u8 = 0x24;
    pub const control: u8 = 0x25;
    pub const counter: u8 = 0x26;
    pub const other: u8 = 0x27;
    pub const atten_a: u8 = 0x40;
    pub const mpan: u8 = 0x44;
    pub const mstereo: u8 = 0x50;
};

/// Is $FD00 + addr an audio register this file serves?
pub fn is_audio_reg(addr: u8) bool {
    return (addr >= 0x20 and addr <= Reg.mpan) or addr == Reg.mstereo;
}

pub const Channel = struct {
    /// BACKUP, CONTROL (as written, taps bit and integrate included), the
    /// count, DONE and the next underflow, as a timer's.
    timer: Timer = .{},
    /// VOLUME, two's complement.
    volume: u8 = 0,
    /// FEEDBACK as written.
    feedback: u8 = 0,
    /// OUTPUT (the DAC), two's complement.
    output: u8 = 0,
    /// The 12-bit shift register.
    shift: u16 = 0,
    /// The 12 tap enables (bit n = shift register bit n), from FEEDBACK
    /// and CONTROL bit 7.
    taps: u16 = 0,
    /// OUTPUT times the channel's mono weight (`weight`), as last mixed.
    contrib: i32 = 0,

    fn update_taps(c: *Channel) void {
        const f: u16 = c.feedback;
        c.taps = (f & 0x3F) | (@as(u16, c.timer.ctla & Control.tap7)) | ((f & 0xC0) << 4);
    }

    /// One clock of the polynomial counter and the waveshaper.
    fn clock_poly(c: *Channel) void {
        const bit: u16 = (@popCount(c.shift & c.taps) & 1) ^ 1;
        c.shift = ((c.shift << 1) | bit) & 0xFFF;
        const vol: i8 = @bitCast(c.volume);
        if (c.timer.ctla & Control.integrate != 0) {
            const o: i16 = @as(i8, @bitCast(c.output));
            const s = if (bit != 0) o + vol else o - vol;
            c.output = @bitCast(@as(i8, @intCast(std.math.clamp(s, -128, 127))));
        } else {
            c.output = @bitCast(if (bit != 0) vol else -%vol);
        }
    }
};

/// Changes logged past the frame's end (see the file comment).
pub const log_len = 16;

/// The frame renderer: the summed level integrated into the bins of the
/// current frame, in time order. Scalars (and the small log) only: it is
/// part of Mikey's state, so a restored state renders the same next frame.
pub const Render = struct {
    /// The frame's first tick and its length (`Lynx.step_frame`).
    win_start: Tick = 0,
    win_len: u32 = 0,
    win_end: Tick = 0,
    /// Rendered up to this tick.
    time: Tick = 0,
    /// The current bin, its first tick and the next bin's.
    bin: u32 = 0,
    bin_start: Tick = 0,
    edge: Tick = 0,
    /// Level x ticks of the current bin so far.
    acc: i32 = 0,
    /// The summed level at `time` (contributions in 1/32 DAC steps).
    level: i32 = 0,
    /// The DC blocker (`dc_shift`): the last bin's mean level and the
    /// filter output, 8 fraction bits.
    hp_in: i32 = 0,
    hp_out: i32 = 0,
    log_tick: [log_len]Tick = @splat(0),
    log_delta: [log_len]i32 = @splat(0),
    log_n: u8 = 0,
};

pub const Audio = struct {
    ch: [4]Channel = @splat(.{}),
    /// ATTEN_A-D: left attenuation in the high nibble, right in the low.
    atten: [4]u8 = @splat(0),
    mpan: u8 = 0,
    mstereo: u8 = 0,
    /// Every channel is caught up to this tick.
    time: Tick = 0,
    /// The earliest underflow the catch-up has to run (a free-running
    /// channel's, or a quiet timer 7's into a linked audio 0).
    next: Tick = never,
    /// This Mikey is `Lynx.mikey` (the renderer writes `Lynx.audio_out`);
    /// false for a Mikey on its own (tests): the state runs, nothing is
    /// written.
    in_console: bool = false,
    r: Render = .{},
};

/// The channel's mono weight in 1/32: left + right, each 16 (on), 0
/// (MSTEREO bit set) or the ATTEN nibble (MPAN bit set).
pub fn weight(a: *const Audio, c: u2) i32 {
    const lb = @as(u8, 0x10) << c;
    const rb = @as(u8, 0x01) << c;
    var w: i32 = 0;
    if (a.mstereo & lb == 0) w += if (a.mpan & lb != 0) a.atten[c] >> 4 else 16;
    if (a.mstereo & rb == 0) w += if (a.mpan & rb != 0) a.atten[c] & 0x0F else 16;
    return w;
}

const Out = ?*[samples_per_frame]u8;

/// Where the samples go: `Lynx.audio_out` while `audio_render` is set.
fn sink(m: *Mikey) Out {
    if (!m.audio.in_console) return null;
    const l: *lynx.Lynx = @alignCast(@fieldParentPtr("mikey", m));
    return if (l.audio_render) &l.audio_out else null;
}

// ---- The renderer ----

/// The DC blocker's pole, 1 - 2^-dc_shift per sample (-3 dB near 6.9 Hz
/// at 44.1 kHz, time constant 23 ms). The Lynx's speaker path is AC
/// coupled: games stop a channel with its OUTPUT anywhere (Blue Lightning
/// leaves four channels at +/-80, a constant -149 DAC steps), which is
/// silence on the hardware but would sit at the 8-bit rail here.
pub const dc_shift: u5 = 10;

/// Bin i finished with `acc` level x ticks over `width` ticks: its mean,
/// DC-blocked (y = x - x' + y' * (1 - 2^-dc_shift)), the gain, the clamp.
fn finish_bin(r: *Render, acc: i32, width: u32) u8 {
    const x = @divFloor(acc, @as(i32, @intCast(width)));
    r.hp_out = ((x - r.hp_in) << 8) + r.hp_out - (r.hp_out >> dc_shift);
    r.hp_in = x;
    const v = @divFloor((r.hp_out >> 8) * gain_eighths, 32 * 8);
    return @intCast(std.math.clamp(v + silence, 0, 255));
}

/// Integrate the level up to tick `t_in` (at most the frame's end),
/// writing every bin completed on the way.
fn render_to(r: *Render, out: Out, t_in: Tick) void {
    const t = @min(t_in, r.win_end);
    if (t <= r.time) return;
    var time = r.time;
    var acc = r.acc;
    if (t >= r.edge and r.level == 0 and acc == 0 and r.hp_in == 0 and r.hp_out >= 0 and r.hp_out < 1 << dc_shift) {
        // Settled silence (most frames of a silent game): the DC blocker
        // is at a fixed point that rounds to 128 (`finish_bin` keeps a
        // positive output below 2^dc_shift as it is), so every bin up to
        // the one holding t is 128 and nothing else changes.
        const k = @min(((t - r.win_start + 1) * samples_per_frame - 1) / r.win_len, samples_per_frame);
        if (out) |o| @memset(o[r.bin..k], silence);
        r.bin = k;
        r.bin_start = r.win_start + k * r.win_len / samples_per_frame;
        r.edge = r.win_start + (k + 1) * r.win_len / samples_per_frame;
        time = r.bin_start;
    }
    while (t >= r.edge) {
        acc += r.level * @as(i32, @intCast(r.edge - time));
        const s = finish_bin(r, acc, r.edge - r.bin_start);
        if (out) |o| o[r.bin] = s;
        acc = 0;
        time = r.edge;
        r.bin_start = r.edge;
        r.bin += 1;
        r.edge = r.win_start + (r.bin + 1) * r.win_len / samples_per_frame;
    }
    acc += r.level * @as(i32, @intCast(t - time));
    r.time = t;
    r.acc = acc;
}

/// The summed level changes by `delta` at tick `x` (never earlier than
/// anything rendered or logged before).
fn level_change(r: *Render, out: Out, x: Tick, delta: i32) void {
    if (x < r.win_end) {
        render_to(r, out, x);
        r.level += delta;
    } else if (r.log_n < log_len) {
        r.log_tick[r.log_n] = x;
        r.log_delta[r.log_n] = delta;
        r.log_n += 1;
    } else {
        r.log_delta[log_len - 1] += delta;
    }
}

/// Re-mix channel c (its OUTPUT or weight changed) at tick x.
fn remix(a: *Audio, out: Out, c: u2, x: Tick) void {
    const ch = &a.ch[c];
    const v = @as(i32, @as(i8, @bitCast(ch.output))) * weight(a, c);
    const d = v - ch.contrib;
    if (d == 0) return;
    ch.contrib = v;
    level_change(&a.r, out, x, d);
}

/// A new frame of `n` ticks from `start` (`Lynx.step_frame`, before it
/// runs): the bins restart, the changes logged past the last frame's end
/// are rendered.
pub fn begin_frame(m: *Mikey, start: Tick, n: u32) void {
    const r = &m.audio.r;
    r.win_start = start;
    r.win_len = n;
    r.win_end = start + n;
    r.time = start;
    r.bin = 0;
    r.bin_start = start;
    r.edge = start + n / samples_per_frame;
    r.acc = 0;
    if (r.log_n == 0) return;
    const out = sink(m);
    var k: u8 = 0;
    while (k < r.log_n and r.log_tick[k] < r.win_end) : (k += 1) {
        render_to(r, out, r.log_tick[k]);
        r.level += r.log_delta[k];
    }
    const left = r.log_n - k;
    for (0..left) |j| {
        r.log_tick[j] = r.log_tick[k + j];
        r.log_delta[j] = r.log_delta[k + j];
    }
    r.log_n = left;
}

/// The frame's end (`Lynx.step_frame`, Mikey caught up past `end`): the
/// channels run to it and every bin is written.
pub fn end_frame(m: *Mikey, end: Tick) void {
    catch_up(m, end);
}

// ---- The channels ----

/// The first underflow after `after` of a free-running quiet timer 7 into
/// a linked, counting audio 0 (else never). Mikey leaves such a timer 7
/// unsettled until the channels are caught up (see the file comment), so
/// its underflows are `expire + k * period`.
fn t7_next(m: *const Mikey, after: Tick) Tick {
    const c0 = &m.audio.ch[0].timer;
    if (!c0.linked() or !c0.running()) return never;
    if (m.event_mask & 0x80 != 0) return never;
    const t = &m.timers[7];
    if (!t.free_running() or t.expire == never) return never;
    if (t.expire > after) return t.expire;
    const v: Tick = if (t.ctla & Ctla.reload != 0) t.backup else if (t.ctla & Ctla.reset_done != 0) 0 else return never;
    const p = (v + 1) << t.shift();
    return t.expire + ((after - t.expire) / p + 1) * p;
}

/// Recompute `Audio.next` (after any change to a channel's clocking or to
/// timer 7).
pub fn relink(m: *Mikey) void {
    const a = &m.audio;
    var n = t7_next(m, a.time);
    for (&a.ch) |*c| n = @min(n, c.timer.expire);
    a.next = n;
}

/// Borrow out of channel c at tick x: its counter reloads, the poly
/// counter clocks, the output is re-mixed, and the clock goes down the
/// chain (audio c+1, or timer 1 after audio 3).
fn underflow(m: *Mikey, out: Out, c_in: u2, x: Tick) void {
    const a = &m.audio;
    var c = c_in;
    while (true) {
        const ch = &a.ch[c];
        const t = &ch.timer;
        t.done = t.ctla & Ctla.reset_done == 0;
        if (t.ctla & Ctla.reload != 0) t.value = t.backup;
        ch.clock_poly();
        remix(a, out, c, x);
        if (c == 3) return m.borrow_in(1, x);
        c += 1;
        const n = &a.ch[c].timer;
        if (!n.linked() or !n.running()) return;
        if (n.value > 0) {
            n.value -= 1;
            return;
        }
    }
}

/// A clock into channel c from its predecessor (it counts only if linked).
fn borrow_in(m: *Mikey, out: Out, c: u2, x: Tick) void {
    const t = &m.audio.ch[c].timer;
    if (!t.linked() or !t.running()) return;
    if (t.value > 0) t.value -= 1 else underflow(m, out, c, x);
}

/// Underflow of a free-running channel at its `expire` tick x.
fn expire_channel(m: *Mikey, out: Out, c: u2, x: Tick) void {
    const t = &m.audio.ch[c].timer;
    t.value = 0;
    t.expire = never;
    underflow(m, out, c, x);
    if (t.free_running()) t.expire = x + ((@as(Tick, t.value) + 1) << t.shift());
}

/// Run the channels to tick t (no-op for the clocks if they are there
/// already) and render up to it.
pub fn catch_up(m: *Mikey, t: Tick) void {
    const a = &m.audio;
    const out = sink(m);
    if (t > a.time) {
        if (a.next <= t) run(m, out, t);
        a.time = t;
    }
    render_to(&a.r, out, t);
}

/// The underflows up to tick t, in time order (same-tick ones in the
/// order timer 7's, then channel 0 to 3). Squares and constants whose
/// borrow nobody counts go in closed form together (`joint`) up to the
/// next other underflow; another channel whose borrow nobody counts runs
/// on its own up to the next other underflow (`run_channel`); anything
/// else goes one tick at a time.
noinline fn run(m: *Mikey, out: Out, t: Tick) void {
    const a = &m.audio;
    while (a.next <= t) {
        const x = a.next;
        const t7 = t7_next(m, a.time);
        var set: u4 = 0;
        var rest = t7;
        for (&a.ch, 0..) |*ch, k| {
            if (square(m, @intCast(k))) set |= @as(u4, 1) << @intCast(k) else rest = @min(rest, ch.timer.expire);
        }
        if (set != 0 and rest > x) {
            const end = @min(@min(t, rest - 1), a.r.win_end -| 1);
            if (end >= x and underflows(a, set, end) >= toggle_min) {
                joint(m, out, set, end);
                relink(m);
                continue;
            }
        }
        var c: u8 = 4;
        var other = t7;
        for (&a.ch, 0..) |*ch, k| {
            const e = ch.timer.expire;
            if (c == 4 and e == x and t7 != x) c = @intCast(k) else other = @min(other, e);
        }
        if (c < 4 and other > x and alone(m, @intCast(c))) {
            a.time = run_channel(m, out, @intCast(c), @min(t, other - 1));
        } else {
            if (t7 == x) borrow_in(m, out, 0, x);
            for (0..4) |k| {
                if (a.ch[k].timer.expire == x) expire_channel(m, out, @intCast(k), x);
            }
            a.time = x;
        }
        relink(m);
    }
}

/// Channel c reloads and its borrow out clocks nothing (no linked
/// successor counting, or audio 3 with timer 1 not linked).
fn alone(m: *const Mikey, c: u2) bool {
    const t = &m.audio.ch[c].timer;
    if (t.ctla & Ctla.reload == 0) return false;
    const n = if (c == 3) &m.timers[1] else &m.audio.ch[c + 1].timer;
    return !(n.linked() and n.running());
}

/// The underflows of channel c (`alone`) from its `expire` up to tick
/// `end`, with nothing else happening in between: what `expire_channel`
/// does for each, in one loop. Returns the tick of the last one.
fn run_channel(m: *Mikey, out: Out, c: u2, end: Tick) Tick {
    const a = &m.audio;
    const ch = &a.ch[c];
    const t = &ch.timer;
    const p = (@as(Tick, t.backup) + 1) << t.shift();
    const w = weight(a, c);
    var x = t.expire;
    var last = x;
    while (true) {
        ch.clock_poly();
        const v = @as(i32, @as(i8, @bitCast(ch.output))) * w;
        if (v != ch.contrib) {
            level_change(&a.r, out, x, v - ch.contrib);
            ch.contrib = v;
        }
        last = x;
        x += p;
        if (x > end) break;
    }
    t.done = t.ctla & Ctla.reset_done == 0;
    t.value = t.backup;
    t.expire = x;
    return last;
}

/// Underflows (of all the `joint` channels together) from which the
/// closed form takes over. A 1 MHz square (backup 0 at 1 us, as Blue
/// Lightning parks its music channels between notes) is 16,667 underflows
/// a frame. (A variable only so the tests can switch the closed form off
/// and compare.)
pub var toggle_min: u32 = 16;

/// Channel c is free-running, `alone`, in normal mode with tap 0 only (a
/// square: OUTPUT alternates +/-VOLUME) or no taps (a constant).
fn square(m: *const Mikey, c: u2) bool {
    const ch = &m.audio.ch[c];
    return ch.timer.expire != never and ch.taps <= 1 and ch.timer.ctla & Control.integrate == 0 and alone(m, c);
}

fn period(t: *const Timer) Tick {
    return (@as(Tick, t.backup) + 1) << t.shift();
}

/// Underflows of the channels in `set` up to tick `end`.
fn underflows(a: *const Audio, set: u4, end: Tick) u32 {
    var n: u32 = 0;
    for (&a.ch, 0..) |*ch, k| {
        if (set & (@as(u4, 1) << @intCast(k)) == 0 or ch.timer.expire > end) continue;
        n += (end - ch.timer.expire) / period(&ch.timer) + 1;
    }
    return n;
}

/// One `joint` channel: its contribution `prev` until its next underflow
/// `x0`, then `va`, `vb`, `va`, ... every `p` ticks.
const Lane = struct {
    x0: Tick,
    p: Tick,
    prev: i64,
    va: i64,
    vb: i64,

    /// The integral of the contribution from `t0` to `s`.
    fn integral(l: *const Lane, t0: Tick, s: Tick) i64 {
        if (s <= l.x0) return l.prev * (s - t0);
        const d = s - l.x0;
        const j = d / l.p;
        const rem = d - j * l.p;
        const ev: i64 = (j + 1) / 2;
        const od: i64 = j / 2;
        return l.prev * (l.x0 - t0) + (ev * l.va + od * l.vb) * l.p + @as(i64, rem) * (if (j & 1 == 0) l.va else l.vb);
    }
};

/// The channels in `set` (`square`) from `Audio.time` to tick `end`
/// (inside the frame, before any other underflow) in closed form: each
/// one's integral over a span is arithmetic, so every bin gets exactly
/// the integer sum one change at a time gives, and each channel ends in
/// the same state: after 12 clocks its shift register repeats with period
/// 2 (or 1), so only the last 12 or 13 clocks are run.
fn joint(m: *Mikey, out: Out, set: u4, end: Tick) void {
    const a = &m.audio;
    const r = &a.r;
    const t0 = a.time;
    render_to(r, out, t0);
    var lanes: [4]Lane = undefined;
    var ks: [4]u2 = undefined;
    var n: usize = 0;
    var base: i32 = r.level;
    for (0..4) |k| {
        if (set & (@as(u4, 1) << @intCast(k)) == 0) continue;
        const ch = &a.ch[k];
        const w = weight(a, @intCast(k));
        var probe = ch.*;
        probe.clock_poly();
        const va = @as(i32, @as(i8, @bitCast(probe.output))) * w;
        probe.clock_poly();
        const vb = @as(i32, @as(i8, @bitCast(probe.output))) * w;
        lanes[n] = .{ .x0 = ch.timer.expire, .p = period(&ch.timer), .prev = ch.contrib, .va = va, .vb = vb };
        ks[n] = @intCast(k);
        base -= ch.contrib;
        n += 1;
    }
    var u = t0;
    var iu: [4]i64 = @splat(0);
    var acc = r.acc;
    while (true) {
        const v = @min(r.edge, end);
        var sum: i64 = @as(i64, base) * (v - u);
        for (lanes[0..n], iu[0..n]) |*l, *i| {
            const iv = l.integral(t0, v);
            sum += iv - i.*;
            i.* = iv;
        }
        acc += @intCast(sum);
        u = v;
        if (v == r.edge) {
            const smp = finish_bin(r, acc, r.edge - r.bin_start);
            if (out) |o| o[r.bin] = smp;
            acc = 0;
            r.bin_start = r.edge;
            r.bin += 1;
            r.edge = r.win_start + (r.bin + 1) * r.win_len / samples_per_frame;
        }
        if (v == end) break;
    }
    r.acc = acc;
    r.time = end;
    var level = base;
    for (lanes[0..n], ks[0..n]) |*l, c| {
        const ch = &a.ch[c];
        const t = &ch.timer;
        if (end >= l.x0) {
            const k = (end - l.x0) / l.p + 1;
            const clocks = if (k <= 13) k else 12 + ((k - 12) & 1);
            for (0..clocks) |_| ch.clock_poly();
            ch.contrib = @as(i32, @as(i8, @bitCast(ch.output))) * weight(a, c);
            t.done = t.ctla & Ctla.reset_done == 0;
            t.value = t.backup;
            t.expire = l.x0 + k * l.p;
        }
        level += ch.contrib;
    }
    r.level = level;
    a.time = end;
}

/// Timer 7 borrowed through Mikey's underflow path at tick `at` (an
/// interrupt event, linked, or a software borrow): clock a linked audio 0.
pub fn timer7_borrow(m: *Mikey, at: Tick) void {
    const c0 = &m.audio.ch[0].timer;
    if (!c0.linked() or !c0.running()) return;
    catch_up(m, at);
    borrow_in(m, sink(m), 0, at);
    relink(m);
}

/// Silence every channel now (a boot re-run: `Lynx.reboot` keeps the
/// renderer across `Mikey.reset`, which zeroes the channels).
pub fn mute(m: *Mikey) void {
    catch_up(m, m.now);
    const a = &m.audio;
    const out = sink(m);
    for (&a.ch, 0..) |*c, k| {
        c.output = 0;
        remix(a, out, @intCast(k), m.now);
    }
}

/// Move every clock value back by `d` (`Mikey.rebase`, after a catch-up).
pub fn rebase(m: *Mikey, d: Tick) void {
    const a = &m.audio;
    for (&a.ch) |*c| {
        if (c.timer.expire != never) c.timer.expire -|= d;
    }
    a.time -|= d;
    if (a.next != never) a.next -|= d;
    const r = &a.r;
    r.win_start -|= d;
    r.win_end -|= d;
    r.time -|= d;
    r.bin_start -|= d;
    r.edge -|= d;
    for (r.log_tick[0..r.log_n]) |*x| x.* -|= d;
}

// ---- Registers ----

fn count(m: *const Mikey, t: *const Timer) u8 {
    if (t.expire == never) return t.value;
    const s = t.shift();
    const next_edge = ((m.now >> s) + 1) << s;
    return @intCast((t.expire - next_edge) >> s);
}

fn freeze(m: *const Mikey, t: *Timer) void {
    if (t.expire == never) return;
    t.value = count(m, t);
    t.expire = never;
}

fn thaw(m: *const Mikey, t: *Timer) void {
    if (!t.free_running()) return;
    const s = t.shift();
    const next_edge = ((m.now >> s) + 1) << s;
    t.expire = next_edge + (@as(Tick, t.value) << s);
}

/// An audio register read at $FD00 + addr (`is_audio_reg`), Mikey's
/// clock at the access.
pub fn read(m: *Mikey, addr: u8) u8 {
    catch_up(m, m.now);
    const a = &m.audio;
    if (addr >= Reg.atten_a) {
        return switch (addr) {
            Reg.mpan => a.mpan,
            Reg.mstereo => a.mstereo,
            else => a.atten[addr & 3],
        };
    }
    const c = &a.ch[(addr - 0x20) >> 3];
    return switch (addr & 7) {
        0 => c.volume,
        1 => c.feedback,
        2 => c.output,
        3 => @truncate(c.shift),
        4 => c.timer.backup,
        5 => c.timer.ctla,
        6 => count(m, &c.timer),
        // Shift bits 11-8 and DONE; last clock and the borrows read 0
        // (file comment).
        else => @as(u8, @truncate(c.shift >> 8)) << 4 | (if (c.timer.done) Ctlb.done else 0),
    };
}

/// An audio register write at $FD00 + addr (`is_audio_reg`). Mikey
/// reschedules after it (`Mikey.write`).
pub fn write(m: *Mikey, addr: u8, v: u8) void {
    catch_up(m, m.now);
    const a = &m.audio;
    const out = sink(m);
    if (addr >= Reg.atten_a) {
        switch (addr) {
            Reg.mpan => a.mpan = v,
            Reg.mstereo => a.mstereo = v,
            else => a.atten[addr & 3] = v,
        }
        for (0..4) |k| remix(a, out, @intCast(k), m.now);
        return;
    }
    const ci: u2 = @intCast((addr - 0x20) >> 3);
    const c = &a.ch[ci];
    const t = &c.timer;
    switch (addr & 7) {
        0 => c.volume = v,
        1 => {
            c.feedback = v;
            c.update_taps();
        },
        2 => {
            c.output = v;
            remix(a, out, ci, m.now);
        },
        3 => c.shift = (c.shift & 0xF00) | v,
        else => {
            freeze(m, t);
            switch (addr & 7) {
                4 => t.backup = v,
                5 => {
                    t.ctla = v;
                    if (v & Ctla.reset_done != 0) t.done = false;
                    c.update_taps();
                },
                6 => t.value = v,
                else => {
                    c.shift = (c.shift & 0x0FF) | (@as(u16, v & 0xF0) << 4);
                    t.done = v & Ctlb.done != 0 and t.ctla & Ctla.reset_done == 0;
                    // Software borrow in: one clock now.
                    if (v & Ctlb.borrow_in != 0) {
                        if (t.value > 0) t.value -= 1 else underflow(m, out, ci, m.now);
                    }
                },
            }
            thaw(m, t);
        },
    }
    relink(m);
}
