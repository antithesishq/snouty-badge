//! The RAM cart's streamed sound (core/sound.zig, the YM2612 `Fm` and the
//! PSG `Synth`; PLAN.md "Sound on the new firmware (2026-10-04)"). Run
//! from tests/ram_variant.zig: only the RAM cart's core has the synthesis
//! (`build_options.synth`). Names carry the `sound:` prefix.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const sound = core.sound;
const ym2612 = core.ym2612;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

comptime {
    if (!sound.enabled) @compileError("sound_synth.zig needs the core built with build_options.synth = true");
}

const blank_rom: [0x400]u8 = @splat(0);

const Rig = struct {
    md: Md,
    snd: sound.Sound,
    buf: [sound.max_samples]u8,
};

/// A console on a blank ROM with a rendering `Sound`.
fn rig() !*Rig {
    const r = try std.testing.allocator.create(Rig);
    r.md.init_in_place(core.RomSource.from_slice(&blank_rom));
    r.snd.init();
    r.md.snd = &r.snd;
    r.snd.set_render(&r.md, true);
    return r;
}

fn ym(r: *Rig, part: u1, reg: u8, v: u8) void {
    r.md.ym.write_addr(part, reg);
    sound.ym_data(&r.md, part, v);
}

fn psg(r: *Rig, v: u8) void {
    sound.psg_write(&r.md, v);
}

/// Channel 1 as one sine: algorithm 7, only operator 1 audible (TL 0,
/// attack 31, no decay, sustain level 0), the others TL 127, keyed on.
fn sine_ch1(r: *Rig, block: u3, fnum: u11, dtmul: u8) void {
    ym(r, 0, 0xB0, 0x07);
    ym(r, 0, 0xB4, 0xC0);
    const offs = [4]u8{ 0x0, 0x8, 0x4, 0xC };
    for (offs, 0..) |o, i| {
        ym(r, 0, 0x30 + o, dtmul);
        ym(r, 0, 0x40 + o, if (i == 0) 0 else 127);
        ym(r, 0, 0x50 + o, 0x1F);
        ym(r, 0, 0x60 + o, 0);
        ym(r, 0, 0x70 + o, 0);
        ym(r, 0, 0x80 + o, 0x0F);
    }
    ym(r, 0, 0xA4, @as(u8, block) << 3 | @as(u8, @truncate(fnum >> 8)));
    ym(r, 0, 0xA0, @truncate(fnum));
    ym(r, 0, 0x28, 0xF0);
}

/// Sign changes of `n` FM evaluations (twice the frequency over n / 44100 s).
fn fm_crossings(r: *Rig, n: usize) u32 {
    var last: i32 = 0;
    var count: u32 = 0;
    for (0..n) |_| {
        const v = r.snd.fm.sample(&r.md.ym);
        if (v != 0) {
            if ((v > 0) != (last > 0) and last != 0) count += 1;
            last = v;
        }
    }
    return count;
}

fn fm_peak(r: *Rig, n: usize) i32 {
    var peak: i32 = 0;
    for (0..n) |_| peak = @max(peak, @as(i32, @intCast(@abs(r.snd.fm.sample(&r.md.ym)))));
    return peak;
}

test "sound: FM pitch from F-number, block, multiple and detune" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    // fnum 1082 block 4 = 439.7 Hz (SPEC.md section 9's formula).
    sine_ch1(r, 4, 1082, 0x01);
    const one_s = 44100 / core.tunables.fm_rate_div;
    const c1 = fm_crossings(r, one_s);

    try expect(c1 >= 2 * 438 and c1 <= 2 * 441);
    // MUL 2 doubles it, MUL 0 halves it.
    ym(r, 0, 0x30, 0x02);
    const c2 = fm_crossings(r, one_s);
    try expect(c2 >= 2 * 877 and c2 <= 2 * 882);
    ym(r, 0, 0x30, 0x00);
    const c0 = fm_crossings(r, one_s);
    try expect(c0 >= 2 * 218 and c0 <= 2 * 221);
    // Detune 3 raises the increment, detune 7 lowers it by the same.
    ym(r, 0, 0x30, 0x01);
    _ = r.snd.fm.sample(&r.md.ym);
    const base = r.snd.fm.op[0][0].inc;
    ym(r, 0, 0x30, 0x31);
    _ = r.snd.fm.sample(&r.md.ym);
    const up = r.snd.fm.op[0][0].inc;
    ym(r, 0, 0x30, 0x71);
    _ = r.snd.fm.sample(&r.md.ym);
    const down = r.snd.fm.op[0][0].inc;
    try expect(up > base and down < base);
    try expect(@abs(@as(i64, up - base) - @as(i64, base - down)) <= 1);
    // A block up is an octave up: twice the increment.
    sine_ch1(r, 5, 1082, 0x01);
    _ = r.snd.fm.sample(&r.md.ym);
    const oct = r.snd.fm.op[0][0].inc;
    try expect(oct >= 2 * base - 2 and oct <= 2 * base + 2);
}

test "sound: envelope attack, decay to the sustain level, release" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    sine_ch1(r, 4, 1082, 0x01);
    // Attack 31 (rate 62+): level 0 at key-on.
    try expectEqual(@as(u16, 0), r.snd.fm.op[0][0].level);
    // Now a slow attack, D1R to SL 4 (12 dB = 128 steps), release.
    ym(r, 0, 0x28, 0x00);
    for (0..44100) |_| _ = r.snd.fm.sample(&r.md.ym);
    ym(r, 0, 0x50, 0x14); // AR 20
    ym(r, 0, 0x60, 0x0C); // D1R 12
    ym(r, 0, 0x80, 0x45); // SL 4, RR 5
    r.snd.fm.op[0][0].level = 1023;
    ym(r, 0, 0x28, 0xF0);
    try expectEqual(ym2612.EgState.attack, r.snd.fm.op[0][0].state);
    var prev: u16 = 1023;
    var n: u32 = 0;
    while (r.snd.fm.op[0][0].state == .attack and n < 44100) : (n += 1) {
        _ = r.snd.fm.sample(&r.md.ym);
        try expect(r.snd.fm.op[0][0].level <= prev);
        prev = r.snd.fm.op[0][0].level;
    }
    // Rate 40 attack: tens of ms, not instant and not seconds.
    try expect(n > 100 and n < 44100 / 4);
    while (r.snd.fm.op[0][0].state == .decay and n < 200000) : (n += 1) _ = r.snd.fm.sample(&r.md.ym);
    try expectEqual(ym2612.EgState.sustain, r.snd.fm.op[0][0].state);
    try expect(r.snd.fm.op[0][0].level >= 128 and r.snd.fm.op[0][0].level < 140);
    // D2R 0: the sustain holds.
    for (0..4410) |_| _ = r.snd.fm.sample(&r.md.ym);
    try expect(r.snd.fm.op[0][0].level < 140);
    // Key off: release (RR 15) down to silence, then the channel is skipped.
    ym(r, 0, 0x80, 0x4F);
    ym(r, 0, 0x28, 0x00);
    try expectEqual(ym2612.EgState.release, r.snd.fm.op[0][0].state);
    for (0..44100 * 2) |_| _ = r.snd.fm.sample(&r.md.ym);
    try expectEqual(@as(u16, 1023), r.snd.fm.op[0][0].level);
    try expectEqual(@as(i32, 0), fm_peak(r, 100));
}

test "sound: envelope rates double every two steps" {
    // Release from 0 to 1023 at RR r and r + 2 (2 rate steps = x2 speed).
    var t: [2]u32 = undefined;
    for ([2]u8{ 4, 6 }, 0..) |rr, k| {
        const r = try rig();
        defer std.testing.allocator.destroy(r);
        sine_ch1(r, 4, 1082, 0x01);
        ym(r, 0, 0x80, rr);
        ym(r, 0, 0x28, 0x00);
        var n: u32 = 0;
        while (r.snd.fm.op[0][0].level < 1023) : (n += 1) _ = r.snd.fm.sample(&r.md.ym);
        t[k] = n;
    }
    // RR 4 (rate 9 + KS) vs RR 6 (rate 13): 4 rate steps = 4x faster.
    try expect(t[0] > t[1] * 7 / 2 and t[0] < t[1] * 9 / 2);
}

test "sound: every algorithm's carriers and modulators" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    sine_ch1(r, 4, 1082, 0x01);
    const offs = [4]u8{ 0x0, 0x8, 0x4, 0xC };
    const carriers = [8]u4{ 0b1000, 0b1000, 0b1000, 0b1000, 0b1010, 0b1110, 0b1110, 0b1111 };
    for (0..8) |alg| {
        ym(r, 0, 0xB0, @intCast(alg));
        // Each operator alone at TL 0: audible exactly when a carrier.
        for (0..4) |op| {
            for (offs, 0..) |o, i| ym(r, 0, 0x40 + o, if (i == op) 0 else 127);
            for (0..8) |_| _ = r.snd.fm.sample(&r.md.ym);
            const peak = fm_peak(r, 400);
            const is_car = carriers[alg] & (@as(u4, 1) << @intCast(op)) != 0;
            if (is_car) try expect(peak > 7000) else try expectEqual(@as(i32, 0), peak);
        }
        // All four carriers of algorithm 7 sum: louder than one.
        if (alg == 7) {
            for (offs) |o| ym(r, 0, 0x40 + o, 12);
            for (0..8) |_| _ = r.snd.fm.sample(&r.md.ym);
            try expect(fm_peak(r, 400) > 8000);
        }
    }
    // A modulator changes the carrier's waveform (algorithm 0: op1 at TL 0
    // into op2 -> op3 -> op4 ...): op4 alone vs op3 modulating it.
    ym(r, 0, 0xB0, 0);
    for (offs, 0..) |o, i| ym(r, 0, 0x40 + o, if (i == 3) 0 else 127);
    for (0..8) |_| _ = r.snd.fm.sample(&r.md.ym);
    const plain = fm_crossings(r, 4410);
    ym(r, 0, 0x40 + offs[2], 0);
    for (0..8) |_| _ = r.snd.fm.sample(&r.md.ym);
    const modulated = fm_crossings(r, 4410);
    try expect(modulated > plain + 20);
}

test "sound: operator 1 feedback" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    sine_ch1(r, 4, 1082, 0x01);
    const pure = fm_crossings(r, 4410);
    ym(r, 0, 0xB0, 0x07 | 7 << 3);
    const fed = fm_crossings(r, 4410);
    // FB 7 turns the sine into a noisy, harmonic-rich wave.
    try expect(fed > pure + 20);
    try expect(r.snd.fm.ch[0].prev[0] != 0 or r.snd.fm.ch[0].prev[1] != 0);
}

test "sound: channel 3 special mode gives operators their own pitch" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    // Channel 3 (part I, +2), algorithm 7, all four at TL 0.
    ym(r, 0, 0xB2, 0x07);
    const offs = [4]u8{ 0x0, 0x8, 0x4, 0xC };
    for (offs) |o| {
        ym(r, 0, 0x32 + o, 0x01);
        ym(r, 0, 0x42 + o, 0);
        ym(r, 0, 0x52 + o, 0x1F);
        ym(r, 0, 0x82 + o, 0x0F);
    }
    ym(r, 0, 0xA6, 4 << 3 | 4);
    ym(r, 0, 0xA2, 0x3A); // 1082
    // Special mode: A9 (op1), AA (op2), A8 (op3) one octave up.
    ym(r, 0, 0x27, 0x40);
    ym(r, 0, 0xAD, 5 << 3 | 4);
    ym(r, 0, 0xA9, 0x3A);
    ym(r, 0, 0xAE, 5 << 3 | 4);
    ym(r, 0, 0xAA, 0x3A);
    ym(r, 0, 0xAC, 5 << 3 | 4);
    ym(r, 0, 0xA8, 0x3A);
    ym(r, 0, 0x28, 0xF2);
    _ = r.snd.fm.sample(&r.md.ym);
    const op = &r.snd.fm.op[2];
    try expect(op[0].inc > op[3].inc * 2 - 4 and op[0].inc < op[3].inc * 2 + 4);
    try expectEqual(op[0].inc, op[1].inc);
    try expectEqual(op[0].inc, op[2].inc);
    // Normal mode: all four on the channel's own frequency.
    ym(r, 0, 0x27, 0x00);
    _ = r.snd.fm.sample(&r.md.ym);
    try expectEqual(op[3].inc, op[0].inc);
}

test "sound: the DAC replaces channel 6 and pans" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    ym(r, 1, 0xB6, 0xC0);
    ym(r, 0, 0x2B, 0x80);
    ym(r, 0, 0x2A, 0xFF);
    try expectEqual(@as(i32, 127 << 6), r.snd.fm.sample(&r.md.ym));
    ym(r, 1, 0xB6, 0x80); // left only: half in mono
    try expectEqual(@as(i32, (127 << 6) >> 1), r.snd.fm.sample(&r.md.ym));
    ym(r, 0, 0x2B, 0x00);
    try expectEqual(@as(i32, 0), r.snd.fm.sample(&r.md.ym));
}

/// One PSG tone at period `p`, attenuation 0, the rest off.
fn psg_tone(r: *Rig, p: u10) void {
    psg(r, 0x80 | @as(u8, @truncate(p & 15)));
    psg(r, @truncate(p >> 4));
    psg(r, 0x90);
    psg(r, 0xBF);
    psg(r, 0xDF);
    psg(r, 0xFF);
}

test "sound: PSG pitch, box filter and attenuation" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    // Period 254: 3579545 / (32 * 254) = 440.4 Hz.
    psg_tone(r, 254);
    var last: i32 = 0;
    var cross: u32 = 0;
    var sum: i64 = 0;
    var peak: i32 = 0;
    for (0..44100) |_| {
        const v = r.snd.psg.sample(&r.md.psg);
        if ((v > 0) != (last > 0) and last != 0) cross += 1;
        if (v != 0) last = v;
        sum += v;
        peak = @max(peak, v);
    }
    try expect(cross >= 2 * 439 and cross <= 2 * 442);
    // A square's mean is ~0, its level the full volume.
    try expect(@abs(sum) < 44100 * 30);
    try expect(peak >= 2590 and peak <= 2600);
    // Period 2 (56 kHz): the box filter gives the mean, not a whine.
    // (the counter runs out its old period first: 254 x 240 master clocks)
    psg_tone(r, 2);
    for (0..60) |_| _ = r.snd.psg.sample(&r.md.psg);
    var big: i32 = 0;
    for (0..4410) |_| big = @max(big, @as(i32, @intCast(@abs(r.snd.psg.sample(&r.md.psg)))));
    try expect(big < 2600 / 2);
    // Periods 0 and 1: constant high (Sega), the volume itself.
    psg_tone(r, 1);
    try expectEqual(@as(i32, 2600), r.snd.psg.sample(&r.md.psg));
    // Attenuation: 2 dB a step (x0.794), 15 off.
    psg(r, 0x91);
    const a1 = r.snd.psg.sample(&r.md.psg);
    try expect(a1 >= 2060 and a1 <= 2070);
    psg(r, 0x9F);
    try expectEqual(@as(i32, 0), r.snd.psg.sample(&r.md.psg));
}

test "sound: PSG noise LFSR, white and periodic" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    psg(r, 0x9F);
    psg(r, 0xF0);
    // Periodic noise, rate /512: the 16-bit register shifts its one bit
    // round, so the output is high one shift in 16.
    psg(r, 0xE0);
    try expectEqual(@as(u16, 0x8000), r.snd.psg.lfsr);
    var highs: u32 = 0;
    for (0..44100) |_| {
        if (r.snd.psg.sample(&r.md.psg) > 0) highs += 1;
    }
    try expect(highs > 44100 / 16 - 400 and highs < 44100 / 16 + 400);
    // White noise (taps 0 and 3): the register's sequence from 0x8000.
    psg(r, 0xE4);
    try expectEqual(@as(u16, 0x8000), r.snd.psg.lfsr);
    var l: u16 = 0x8000;
    for (0..20) |_| {
        const fb = (l ^ (l >> 3)) & 1;
        l = (l >> 1) | (fb << 15);
    }
    // 20 shifts at rate /512 take 20 * 2 * 16 * 240 master clocks.
    var mc: u32 = 0;
    while (mc < 20 * 2 * 16 * 240 + 100) : (mc += 1218) _ = r.snd.psg.sample(&r.md.psg);
    try expectEqual(l, r.snd.psg.lfsr);
}

test "sound: a write lands in the bin of its console time" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    var buf: [sound.max_samples]u8 = undefined;
    r.snd.begin_update(&buf);
    r.snd.begin_frame();
    // Line 131 of 262, cycle 0: half the frame's 735.95 samples.
    r.md.vdp.line = 131;
    r.md.vdp.line_cycles = 0;
    sine_ch1(r, 4, 1082, 0x01);
    r.md.vdp.line = 0;
    r.snd.end_frame(&r.md);
    const out = r.snd.take();
    try expect(out.len == 735 or out.len == 736);
    var first: usize = out.len;
    for (out, 0..) |s, i| if (s != 128) {
        first = i;
        break;
    };
    try expect(first >= 366 and first <= 369);
}

test "sound: two frames make 1,471 or 1,472 samples, the fraction carried" {
    const r = try rig();
    defer std.testing.allocator.destroy(r);
    var buf: [sound.max_samples]u8 = undefined;
    var total: u32 = 0;
    for (0..60) |_| {
        r.snd.begin_update(&buf);
        for (0..2) |_| {
            r.md.step_frame(0, false);
        }
        const n: u32 = @intCast(r.snd.take().len);

        try expect(n == 1471 or n == 1472);
        total += n;
    }
    // 120 frames at 59.92 Hz = 2.0026 s.
    try expect(total >= 88312 and total <= 88315);
}

test "sound: rendering does not change the console; off renders nothing" {
    const rom_file = @import("rom").data;
    var hashes: [2]u64 = undefined;
    for (0..2) |k| {
        const r = try std.testing.allocator.create(Rig);
        defer std.testing.allocator.destroy(r);
        r.md.init_in_place(core.RomSource.from_slice(rom_file));
        r.snd.init();
        r.md.snd = &r.snd;
        r.snd.set_render(&r.md, k == 1);
        var buf: [sound.max_samples]u8 = undefined;
        for (0..150) |_| {
            r.snd.begin_update(&buf);
            r.md.step_frame(0, false);
            r.md.step_frame(core.Pad.start, false);
            const n = r.snd.take().len;
            if (k == 0) try expectEqual(@as(usize, 0), n) else try expect(n >= 1471);
        }
        var w = std.hash.Wyhash.init(0);
        w.update(&r.md.work_ram);
        w.update(&r.md.vdp.vram);
        w.update(std.mem.asBytes(&r.md.ym.regs));
        w.update(std.mem.asBytes(&r.md.psg.tone));
        w.update(std.mem.asBytes(&r.md.cpu.pc));
        hashes[k] = w.final();
    }
    try expectEqual(hashes[0], hashes[1]);
}
