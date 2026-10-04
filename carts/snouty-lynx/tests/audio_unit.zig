//! audio: Mikey's four audio channels and the mix into `Lynx.audio_out`
//! (PLAN.md "M5 Sound: contract", Track A; core/audio.zig). Registers
//! are driven through Mikey (or the bus) on a halted console (a cart that
//! does not boot: the CPU never runs, time and Mikey do), or on a Mikey of
//! its own where nothing is rendered.
const std = @import("std");
const core = @import("core");
const files = @import("testfiles.zig");
const runner = @import("runner.zig");
const audio = core.audio;
const mikey = core.mikey;
const Mikey = mikey.Mikey;
const Lynx = core.Lynx;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const A = audio.Reg;
const C = mikey.Ctla;
const integrate = audio.Control.integrate;

/// Register of channel c: base (`audio.Reg`, channel 0) + 8 c.
fn reg(base: u8, c: u8) u8 {
    return base + 8 * c;
}

const S = struct {
    var l: Lynx = undefined;
    var small: Lynx.Small = undefined;
    var out1: [audio.samples_per_frame]u8 = undefined;
    var ram: [0x10000]u8 = undefined;
};

/// Not a Lynx program: the boot refuses it, the console halts and only
/// time, Mikey and the audio run.
const no_boot: [600]u8 = @splat(0x12);
var no_boot_layout: core.cart.Layout = undefined;

fn halted() *Lynx {
    no_boot_layout = core.cart.parse(&no_boot, no_boot.len);
    S.l.init_in_place(core.Cart.from_slice(&no_boot_layout, &no_boot));
    std.debug.assert(S.l.halted);
    return &S.l;
}

/// A CPU write to $FD00 + addr through the bus (ticks charged, Mikey
/// synced first).
fn poke(l: *Lynx, addr: u8, v: u8) void {
    l.write(0xFD00 | @as(u16, addr), v);
}

fn peek(l: *Lynx, addr: u8) u8 {
    return l.read(0xFD00 | @as(u16, addr));
}

/// One software clock of channel c (OTHER bit 1, its count at 0): the
/// poly counter shifts once. Keeps shift bits 11-8 as they are.
fn clock_once(m: *Mikey, c: u8) void {
    const other = m.read(reg(A.other, c));
    m.write(reg(A.other, c), (other & 0xF0) | mikey.Ctlb.borrow_in);
}

fn shift12(m: *Mikey, c: u8) u16 {
    return @as(u16, m.read(reg(A.other, c)) >> 4) << 8 | m.read(reg(A.shift, c));
}

fn set_shift(m: *Mikey, c: u8, v: u12) void {
    m.write(reg(A.shift, c), @truncate(v));
    m.write(reg(A.other, c), @as(u8, @truncate(v >> 8)) << 4);
}

/// FEEDBACK and CONTROL bit 7 for a 12-bit tap mask (taps 0-5, 7, 10, 11).
fn set_taps(m: *Mikey, c: u8, taps: u16, control: u8) void {
    m.write(reg(A.feedback, c), @as(u8, @truncate(taps & 0x3F)) | @as(u8, @truncate((taps >> 4) & 0xC0)));
    m.write(reg(A.control, c), control | @as(u8, @truncate(taps & 0x80)));
}

test "audio: the Epyx tap table: taps $02E give periods 15, 5, 3 and the $03F lockup" {
    // lynx7.html "More to sound": "a feedback tap setting of $02E can count
    // in any one of 8 different sequences depending on the shifter initial
    // value. Initial values of $000, $005, $00B all have a period of 15
    // [...] $002, $00E, $016 have period 5 [...] $009 has period 3, and
    // $03F is a lockup- period of 1." The register's bits above the top tap
    // only carry history, so the period is that of the low six bits. The
    // inverted XOR is what makes $03F lock (a plain XOR would not).
    const cases = [_]struct { init: u12, period: u32 }{
        .{ .init = 0x000, .period = 15 }, .{ .init = 0x005, .period = 15 }, .{ .init = 0x00B, .period = 15 },
        .{ .init = 0x002, .period = 5 },  .{ .init = 0x00E, .period = 5 },  .{ .init = 0x016, .period = 5 },
        .{ .init = 0x009, .period = 3 },  .{ .init = 0x03F, .period = 1 },
    };
    for (cases) |cs| {
        var m: Mikey = .{};
        set_taps(&m, 1, 0x02E, 0);
        set_shift(&m, 1, cs.init);
        var n: u32 = 0;
        while (true) {
            clock_once(&m, 1);
            n += 1;
            if (shift12(&m, 1) & 0x3F == cs.init or n > 100) break;
        }
        try expectEqual(cs.period, n);
    }
}

test "audio: a full-period tap set runs 4,095 states from $000" {
    // "there are 19 different ways to get a period of 4095. All 19 ways
    // have an initial shifter value of 00" (lynx7.html); taps 0, 2-5, 7,
    // 10, 11 is one of them.
    var m: Mikey = .{};
    set_taps(&m, 2, 0xCBD, 0);
    set_shift(&m, 2, 0);
    var n: u32 = 0;
    while (true) {
        clock_once(&m, 2);
        n += 1;
        if (shift12(&m, 2) == 0 or n > 5000) break;
    }
    try expectEqual(@as(u32, 4095), n);
}

test "audio: normal mode +/-VOLUME, integrate mode the running total, clamped" {
    var m: Mikey = .{};
    // Tap 0 only from 0: the new bit alternates 1, 0, 1, 0.
    set_taps(&m, 0, 0x001, 0);
    set_shift(&m, 0, 0);
    m.write(A.volume, 9);
    const want_sq = [_]i8{ 9, -9, 9, -9 };
    for (want_sq) |w| {
        clock_once(&m, 0);
        try expectEqual(w, @as(i8, @bitCast(m.read(A.output))));
    }
    // lynx7.html's example: bits 111000111000 with volume 9 integrate to
    // 9,18,27,18,9,0 (tap 2 only, from $000).
    m.write(A.output, 0);
    set_taps(&m, 0, 0x004, integrate);
    set_shift(&m, 0, 0);
    const want_tri = [_]i8{ 9, 18, 27, 18, 9, 0, 9, 18, 27, 18, 9, 0 };
    for (want_tri) |w| {
        clock_once(&m, 0);
        try expectEqual(w, @as(i8, @bitCast(m.read(A.output))));
    }
    // No taps: the new bit is always 1. "The running total clips rather
    // than wrap around": 100 + 100 stops at 127; a negative volume walks
    // down to -128 and stays.
    m.write(A.output, 0);
    set_taps(&m, 0, 0, integrate);
    m.write(A.volume, 100);
    const want_up = [_]i8{ 100, 127, 127 };
    for (want_up) |w| {
        clock_once(&m, 0);
        try expectEqual(w, @as(i8, @bitCast(m.read(A.output))));
    }
    m.write(A.volume, @bitCast(@as(i8, -100)));
    const want_down = [_]i8{ 27, -73, -128, -128 };
    for (want_down) |w| {
        clock_once(&m, 0);
        try expectEqual(w, @as(i8, @bitCast(m.read(A.output))));
    }
}

test "audio: register read-back" {
    var m: Mikey = .{};
    for (0..4) |k| {
        const c: u8 = @intCast(k);
        m.write(reg(A.volume, c), 0x81 + c);
        m.write(reg(A.feedback, c), 0xC5 + c);
        m.write(reg(A.output, c), 0x70 + c);
        m.write(reg(A.shift, c), 0x3C + c);
        m.write(reg(A.backup, c), 0x42 + c);
        // Stopped (no enable): the counter holds what is written.
        m.write(reg(A.control, c), 0xA0 | C.reload | 5);
        m.write(reg(A.counter, c), 0x17 + c);
        m.write(reg(A.other, c), 0x90 | mikey.Ctlb.done);
    }
    for (0..4) |k| {
        const c: u8 = @intCast(k);
        try expectEqual(0x81 + c, m.read(reg(A.volume, c)));
        try expectEqual(0xC5 + c, m.read(reg(A.feedback, c)));
        try expectEqual(0x70 + c, m.read(reg(A.output, c)));
        try expectEqual(0x3C + c, m.read(reg(A.shift, c)));
        try expectEqual(0x42 + c, m.read(reg(A.backup, c)));
        try expectEqual(@as(u8, 0xA0 | C.reload | 5), m.read(reg(A.control, c)));
        try expectEqual(0x17 + c, m.read(reg(A.counter, c)));
        // Shift bits 11-8 high, DONE; last clock and the borrows read 0.
        try expectEqual(@as(u8, 0x90 | mikey.Ctlb.done), m.read(reg(A.other, c)));
        try expectEqual(0x93C + @as(u16, c), m.audio.ch[c].shift);
    }
    // RESET_DONE clears DONE.
    m.write(reg(A.control, 0), C.reset_done);
    try expectEqual(@as(u8, 0x90), m.read(reg(A.other, 0)));
    for (0..4) |k| m.write(A.atten_a + @as(u8, @intCast(k)), 0x1F + @as(u8, @intCast(k)));
    m.write(A.mpan, 0x5A);
    m.write(A.mstereo, 0xC3);
    for (0..4) |k| try expectEqual(0x1F + @as(u8, @intCast(k)), m.read(A.atten_a + @as(u8, @intCast(k))));
    try expectEqual(@as(u8, 0x5A), m.read(A.mpan));
    try expectEqual(@as(u8, 0xC3), m.read(A.mstereo));
    // The unallocated $FD45 is still a plain stored register.
    m.write(0x45, 0x66);
    try expectEqual(@as(u8, 0x66), m.read(0x45));
}

test "audio: a running channel counts as a timer (count read-back, period)" {
    var m: Mikey = .{};
    // 4 us clock (sel 2, 64 ticks), backup 9: an underflow every 640 ticks.
    set_taps(&m, 3, 0, 0);
    m.write(reg(A.backup, 3), 9);
    m.write(reg(A.counter, 3), 9);
    m.write(reg(A.control, 3), C.reload | C.count | 2);
    // Started at tick 0: edges at 64, 128, ...; count 9 until the first.
    try expectEqual(@as(u8, 9), m.read(reg(A.counter, 3)));
    m.advance_to(64 * 3);
    try expectEqual(@as(u8, 6), m.read(reg(A.counter, 3)));
    // The underflow comes on the edge after 0 (64 * 10 = 640): no taps,
    // the shift register fills with ones, one per underflow.
    m.advance_to(639);
    try expectEqual(@as(u16, 0), shift12(&m, 3));
    m.advance_to(640);
    try expectEqual(@as(u16, 1), shift12(&m, 3));
    try expectEqual(@as(u8, 9), m.read(reg(A.counter, 3)));
    m.advance_to(640 * 5 - 1);
    try expectEqual(@as(u16, 0xF), shift12(&m, 3));
    m.advance_to(640 * 5);
    try expectEqual(@as(u16, 0x1F), shift12(&m, 3));
    // Its DONE is set after the first underflow (no RESET_DONE).
    try expectEqual(mikey.Ctlb.done, m.read(reg(A.other, 3)) & 0x0F);
}

/// Timer 7 at 1 us, backup 9 (an underflow every 160 ticks from 160 on),
/// audio 0 linked to it (backup and count 4: every fifth one, 800, 1600,
/// ...), audio 1 linked to audio 0 (backup and count 1: every second of
/// those). No taps: each underflow shifts a one in.
fn chain_setup(m: *Mikey, t7_irq: bool) void {
    for (0..2) |k| set_taps(m, @intCast(k), 0, 0);
    m.write(reg(A.backup, 0), 4);
    m.write(reg(A.counter, 0), 4);
    m.write(reg(A.control, 0), C.reload | C.count | C.linked);
    m.write(reg(A.backup, 1), 1);
    m.write(reg(A.counter, 1), 1);
    m.write(reg(A.control, 1), C.reload | C.count | C.linked);
    m.write(28, 9); // TIM7BKUP
    m.write(30, 9); // TIM7CNT
    m.write(29, (if (t7_irq) C.irq_enable else 0) | C.reload | C.count | 0);
}

test "audio: link chain timer 7 -> audio 0 -> audio 1 (timer 7 quiet or an event)" {
    for ([_]bool{ false, true }) |irq| {
        var m: Mikey = .{};
        chain_setup(&m, irq);
        // Quiet timer 7: no Mikey event per underflow; as an interrupt
        // source it is one, and its underflow clocks audio 0 directly.
        try expectEqual(irq, m.event_mask & 0x80 != 0);
        m.advance_to(799);
        try expectEqual(@as(u16, 0), shift12(&m, 0));
        try expectEqual(@as(u8, 0), m.read(reg(A.counter, 0)));
        m.advance_to(800);
        try expectEqual(@as(u16, 1), shift12(&m, 0));
        try expectEqual(@as(u8, 4), m.read(reg(A.counter, 0)));
        m.advance_to(4000);
        try expectEqual(@as(u16, 0x1F), shift12(&m, 0));
        // Audio 1: count 1 -> 0 at 800, underflow at 1600, 3200.
        try expectEqual(@as(u16, 0x3), shift12(&m, 1));
        // A timer 7 read settles it; the chain keeps counting from there.
        _ = m.read(30);
        m.advance_to(8000);
        try expectEqual(@as(u16, 0x3FF), shift12(&m, 0));
        try expectEqual(@as(u16, 0x1F), shift12(&m, 1));
        // A software borrow into timer 7 at its count 0 is an extra
        // underflow: one more clock into audio 0 (count 4 -> 3).
        // (Timer 7 is at 0 from 8,624 to its underflow at 8,640; audio 0
        // counted 4 -> 1 at 8,160, 8,320, 8,480.)
        m.advance_to(8630);
        try expectEqual(@as(u8, 0), m.timer_count(7));
        try expectEqual(@as(u8, 1), m.read(reg(A.counter, 0)));
        m.write(31, mikey.Ctlb.borrow_in);
        try expectEqual(@as(u8, 0), m.read(reg(A.counter, 0)));
    }
}

test "audio: audio 3 clocks a linked timer 1 (its interrupt on time)" {
    var m: Mikey = .{};
    // Audio 3 at 1 us, backup 0: an underflow every 16 ticks from 16 on.
    set_taps(&m, 3, 0, 0);
    m.write(reg(A.control, 3), C.reload | C.count | 0);
    // Timer 1 linked, backup and count 9, interrupt: its tenth borrow, at
    // tick 160, 320, ...
    m.write(4, 9);
    m.write(6, 9);
    m.write(5, C.irq_enable | C.reload | C.count | C.linked);
    try expect(m.aud_event != mikey.ticks_never);
    m.advance_to(159);
    try expectEqual(@as(u8, 0), m.pending() & 0x02);
    try expectEqual(@as(u8, 0), m.timer_count(1));
    m.advance_to(160);
    try expectEqual(@as(u8, 0x02), m.pending() & 0x02);
    m.write(0x80, 0x02);
    m.advance_to(319);
    try expectEqual(@as(u8, 0), m.pending() & 0x02);
    m.advance_to(320);
    try expectEqual(@as(u8, 0x02), m.pending() & 0x02);
    // Timer 1 unlinked: the channels are no longer events.
    m.write(5, C.reload | 0);
    try expectEqual(mikey.ticks_never, m.aud_event);
}

/// Zero crossings around 128 (a sample at 128 keeps the last side, which
/// carries over from the previous frame).
fn crossings(samples: []const u8, side: *?bool) u32 {
    var n: u32 = 0;
    for (samples) |s| {
        if (s == audio.silence) continue;
        const up = s > audio.silence;
        if (side.*) |sd| {
            if (sd != up) n += 1;
        }
        side.* = up;
    }
    return n;
}

test "audio: a square wave's pitch from BACKUP and the clock select" {
    const cases = [_]struct { sel: u8, backup: u8 }{
        .{ .sel = 0, .backup = 99 }, // 100 us half period: 5 kHz
        .{ .sel = 1, .backup = 249 }, // 500 us: 1 kHz
        .{ .sel = 3, .backup = 124 }, // 1 ms: 500 Hz
        .{ .sel = 6, .backup = 77 }, // 4.992 ms: 100.16 Hz
    };
    for (cases) |cs| {
        const l = halted();
        poke(l, A.volume, 64);
        poke(l, A.feedback, 0x01);
        poke(l, A.backup, cs.backup);
        poke(l, A.control, C.reload | C.count | cs.sel);
        // 10 frames to settle, then 50 (5/6 s).
        for (0..10) |_| l.step_frame(0);
        var n: u32 = 0;
        var side: ?bool = null;
        var lo: u8 = 255;
        var hi: u8 = 0;
        for (0..50) |_| {
            l.step_frame(0);
            n += crossings(&l.audio_out, &side);

            lo = @min(lo, std.mem.min(u8, &l.audio_out));
            hi = @max(hi, std.mem.max(u8, &l.audio_out));
        }
        const half_us: u64 = (@as(u64, cs.backup) + 1) << @intCast(cs.sel);
        const want: u64 = 1_000_000 * 5 / 6 / half_us;
        try expect(n + 2 >= want and n <= want + 2);
        // +/-64 DAC steps at 3/8: +/-24 around 128 (at 100 Hz the DC
        // blocker's droop gives +/-21..27).
        try expect(hi >= 128 + 21 and hi <= 128 + 27);
        try expect(lo >= 128 - 27 and lo <= 128 - 21);
    }
}

test "audio: the clock rebase keeps a square's pitch" {
    const l = halted();
    poke(l, A.volume, 64);
    poke(l, A.feedback, 0x01);
    poke(l, A.backup, 249);
    poke(l, A.control, C.reload | C.count | 1);
    // The clock is rebased before it reaches 2^30 ticks (frame ~4,026).
    while (l.tick_base == 0) {
        l.step_frame(0);
        if (l.frame_count == 3990) break;
    }
    try expectEqual(@as(u64, 0), l.tick_base);
    var n: u32 = 0;
    var side: ?bool = null;
    for (0..60) |_| {
        l.step_frame(0);
        n += crossings(&l.audio_out, &side);
    }
    try expect(l.tick_base != 0);
    // 1 kHz for one second: 2,000 crossings.
    try expect(n + 2 >= 2000 and n <= 2000 + 2);
}

test "audio: a DAC write lands in its bin" {
    const l = halted();
    l.step_frame(0);
    l.step_frame(0);
    const m = &l.mikey;
    // (A halted console's clock runs past the frame end by the frame's
    // refresh steal; the window here starts where Mikey is.)
    const start = m.now;
    const n: u32 = 266_667;
    audio.begin_frame(m, start, n);
    // Halfway into bin 300.
    const e300 = 300 * n / 735;
    const e301 = 301 * n / 735;
    m.advance_to(start + (e300 + e301) / 2);
    m.write(A.output, 100);
    m.advance_to(start + n);
    audio.end_frame(m, start + n);
    for (l.audio_out[0..300]) |s| try expectEqual(audio.silence, s);
    // 100 DAC steps at 3/8 = 37.5 (the DC blocker has barely moved).
    const full = l.audio_out[301];
    try expect(full >= 128 + 36 and full <= 128 + 38);
    const half = l.audio_out[300];
    try expect(half >= 128 + 17 and half <= 128 + 20);
    // Then the DC blocker pulls it back towards 128 (AC coupling).
    try expect(l.audio_out[734] < full and l.audio_out[734] > 128);
}

test "audio: stereo and attenuation mixed to mono" {
    var a: audio.Audio = .{};
    // Reset values: both ears, no attenuation.
    for (0..4) |c| try expectEqual(@as(i32, 32), audio.weight(&a, @intCast(c)));
    // MSTEREO: a set bit disconnects (bits 7-4 left, 3-0 right).
    a.mstereo = 0x11;
    try expectEqual(@as(i32, 0), audio.weight(&a, 0));
    a.mstereo = 0x02;
    try expectEqual(@as(i32, 16), audio.weight(&a, 1));
    a.mstereo = 0;
    // MPAN selects the ATTEN nibble (left high, right low) in 1/16.
    a.mpan = 0x04 | 0x40;
    a.atten[2] = 0xF3;
    try expectEqual(@as(i32, 15 + 3), audio.weight(&a, 2));
    a.mpan = 0x40;
    try expectEqual(@as(i32, 15 + 16), audio.weight(&a, 2));

    // End to end: two channels' DACs at +60; channel 1 off in both ears
    // halves the step, panned to one ear at ATTEN 8/16 it adds a quarter.
    const levels = [_]struct { mstereo: u8, mpan: u8, atten: u8, want: u8 }{
        .{ .mstereo = 0x00, .mpan = 0x00, .atten = 0x00, .want = 128 + 45 },
        .{ .mstereo = 0x22, .mpan = 0x00, .atten = 0x00, .want = 128 + 22 },
        .{ .mstereo = 0x02, .mpan = 0x20, .atten = 0x80, .want = 128 + 28 },
    };
    for (levels) |lv| {
        const l = halted();
        l.step_frame(0);
        poke(l, A.atten_a + 1, lv.atten);
        poke(l, A.mpan, lv.mpan);
        poke(l, A.mstereo, lv.mstereo);
        poke(l, reg(A.output, 0), 60);
        poke(l, reg(A.output, 1), 60);
        l.step_frame(0);
        // (The writes land a few bins into the frame: a halted console's
        // clock is past the frame end by the refresh steal.)
        const got = l.audio_out[40];
        try expect(got + 2 >= lv.want and got <= lv.want + 2);
    }
}

/// Fast squares (tap 0, 1 us, backup 0 and 2), a constant (no taps) at
/// 2 us, a slow noise channel, and DAC writes and volume changes from the
/// bus at odd ticks: 20 frames of `audio_out` and the final channel state.
fn fast_run(l: *Lynx, out: *[20][audio.samples_per_frame]u8) void {
    poke(l, reg(A.volume, 0), 77);
    poke(l, reg(A.feedback, 0), 0x01);
    poke(l, reg(A.control, 0), C.reload | C.count | 0);
    poke(l, reg(A.volume, 1), @bitCast(@as(i8, -128)));
    poke(l, reg(A.feedback, 1), 0x01);
    poke(l, reg(A.backup, 1), 2);
    poke(l, reg(A.control, 1), C.reload | C.count | 0);
    poke(l, reg(A.volume, 2), 50);
    poke(l, reg(A.backup, 2), 0);
    poke(l, reg(A.control, 2), C.reload | C.count | 1);
    poke(l, reg(A.volume, 3), 33);
    poke(l, reg(A.feedback, 3), 0x2E);
    poke(l, reg(A.backup, 3), 40);
    poke(l, reg(A.control, 3), C.reload | C.count | 1);
    for (out, 0..) |*o, f| {
        l.step_frame(0);
        o.* = l.audio_out;
        poke(l, reg(A.volume, 0), @intCast(20 + f * 5));
        poke(l, reg(A.output, 2), @intCast(f * 3));
        if (f == 7) poke(l, reg(A.mstereo, 0), 0x01);
    }
}

test "audio: the closed form for fast squares equals one underflow at a time" {
    const S2 = struct {
        var a: [20][audio.samples_per_frame]u8 = undefined;
        var b: [20][audio.samples_per_frame]u8 = undefined;
        var ma: Mikey = undefined;
    };
    defer audio.toggle_min = 16;
    audio.toggle_min = 16;
    fast_run(halted(), &S2.a);
    S2.ma = S.l.mikey;
    audio.toggle_min = std.math.maxInt(u32);
    fast_run(halted(), &S2.b);
    for (S2.a, S2.b) |x, y| try expectEqual(x, y);
    try expect(std.meta.eql(S2.ma.audio, S.l.mikey.audio));
    var moved = false;
    for (S2.a) |x| {
        for (x) |s| moved = moved or s != audio.silence;
    }
    try expect(moved);
}

test "audio: scrub round trip (a restored state renders the same next frame)" {
    const l = halted();
    // A square, a noise channel and an integrating one, all running.
    poke(l, reg(A.volume, 0), 40);
    poke(l, reg(A.feedback, 0), 0x01);
    poke(l, reg(A.backup, 0), 57);
    poke(l, reg(A.control, 0), C.reload | C.count | 1);
    poke(l, reg(A.volume, 1), 30);
    poke(l, reg(A.feedback, 1), 0xFD);
    poke(l, reg(A.backup, 1), 3);
    poke(l, reg(A.control, 1), 0x80 | C.reload | C.count | 0);
    poke(l, reg(A.volume, 2), 7);
    poke(l, reg(A.feedback, 2), 0x04);
    poke(l, reg(A.backup, 2), 20);
    poke(l, reg(A.control, 2), integrate | C.reload | C.count | 2);
    for (0..5) |_| l.step_frame(0);
    // A DAC write after the frame's end (the bus clock is past it): it
    // waits in the log for the next frame.
    poke(l, reg(A.output, 3), 90);
    try expect(l.mikey.audio.r.log_n > 0);
    l.save_small(&S.small);
    l.step_frame(0);
    S.out1 = l.audio_out;
    var moved = false;
    for (S.out1) |s| moved = moved or s != audio.silence;
    try expect(moved);
    l.step_frame(0);
    l.load_small(&S.small);
    l.step_frame(0);
    try expectEqual(S.out1, l.audio_out);
}

test "audio: Hard Drivin' (local dump) is heard, and a restored state renders the same" {
    var buf: [1 << 18]u8 = undefined;
    const rom = files.read_home_file("roms/lynx/hard_drivin.lnx", &buf) orelse return error.SkipZigTest;
    const cart = switch (runner.cart_from_file(rom)) {
        .ok => |c| c,
        .refused => return error.TestUnexpectedResult,
    };
    S.l.init_in_place(cart);
    // The title music plays from about frame 200.
    var loud: u32 = 0;
    for (0..400) |_| {
        S.l.step_frame(0);
        for (S.l.audio_out) |s| {
            if (s > 128 + 8 or s < 128 - 8) loud += 1;
        }
    }
    try expect(loud > 10_000);
    S.l.save_small(&S.small);
    S.ram = S.l.ram;
    S.l.step_frame(0);
    S.out1 = S.l.audio_out;
    S.l.load_small(&S.small);
    S.l.ram = S.ram;
    S.l.step_frame(0);
    try expectEqual(S.out1, S.l.audio_out);
}
