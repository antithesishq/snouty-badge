//! SN76489 register model and voice pick (core/psg.zig).
const std = @import("std");
const core = @import("core");
const psg = core.psg;
const expectEqual = std.testing.expectEqual;

test "psg: post-reset state is silent" {
    const p: psg.Psg = .{};
    try expectEqual([4]u8{ 15, 15, 15, 15 }, p.atten);
    try expectEqual([3]u16{ 0, 0, 0 }, p.tone);
    try expectEqual(@as(?psg.Voice, null), p.voice());
}

test "psg: latch + data assemble a 10-bit period on each tone channel" {
    var p: psg.Psg = .{};
    for (0..3) |ci| {
        const c: u8 = @intCast(ci);
        p.write(0x80 | c << 5 | 0x0B); // latch tone, low 4 bits B
        try expectEqual(c << 1, p.latch);
        p.write(0x3F); // data: high 6 bits 3F
        try expectEqual(@as(u16, 0x3FB), p.tone[ci]);
        p.write(0x80 | c << 5 | 0x04); // latch again: only the low bits change
        try expectEqual(@as(u16, 0x3F4), p.tone[ci]);
        p.write(0x01); // data: high bits 01, low bits kept
        try expectEqual(@as(u16, 0x014), p.tone[ci]);
        p.write(0x40 | 0x02); // bit 6 of a data byte is ignored
        try expectEqual(@as(u16, 0x024), p.tone[ci]);
    }
    try expectEqual([4]u8{ 15, 15, 15, 15 }, p.atten);
}

test "psg: attenuation by latch and by data byte" {
    var p: psg.Psg = .{};
    for (0..4) |ci| {
        const c: u8 = @intCast(ci);
        p.write(0x90 | c << 5 | 0x07);
        try expectEqual(c << 1 | 1, p.latch);
        try expectEqual(@as(u8, 7), p.atten[ci]);
        p.write(0x0C); // data byte to the latched volume register
        try expectEqual(@as(u8, 0x0C), p.atten[ci]);
        p.write(0x32); // only the low 4 bits
        try expectEqual(@as(u8, 0x02), p.atten[ci]);
    }
    try expectEqual([3]u16{ 0, 0, 0 }, p.tone);
}

test "psg: noise control bits" {
    var p: psg.Psg = .{};
    p.write(0xE5); // latch noise: white (bit 2), rate 1
    try expectEqual(@as(u8, 6), p.latch);
    try expectEqual(@as(u8, 5), p.noise);
    p.write(0xEF); // only 3 bits
    try expectEqual(@as(u8, 7), p.noise);
    p.write(0x02); // data byte to noise: low 3 bits
    try expectEqual(@as(u8, 2), p.noise);
    p.write(0xFA); // ch3 attenuation 10
    try expectEqual(@as(u8, 10), p.atten[3]);
    try expectEqual(@as(u8, 2), p.noise);
    try expectEqual([3]u16{ 0, 0, 0 }, p.tone);
}

fn set(p: *psg.Psg, ch: u8, period: u16, att: u8) void {
    p.write(0x80 | ch << 5 | @as(u8, @intCast(period & 0x0F)));
    p.write(@intCast(period >> 4));
    p.write(0x90 | ch << 5 | att);
}

test "psg: voice picks the loudest tone, ties to the lowest channel" {
    var p: psg.Psg = .{};
    set(&p, 0, 0x0FE, 8);
    set(&p, 1, 0x200, 4);
    set(&p, 2, 0x100, 4);
    const v = p.voice().?;
    try expectEqual(@as(u2, 1), v.channel);
    try expectEqual(@as(u16, 0x200), v.period);
    try expectEqual(@as(u4, 4), v.atten);
    try expectEqual(@as(u32, 3_579_545 / (32 * 0x200)), v.hz);
    try expectEqual(@as(u32, 218), v.hz);

    set(&p, 0, 0x0FE, 4); // tie with 1 and 2: channel 0 wins
    try expectEqual(@as(u2, 0), p.voice().?.channel);
    try expectEqual(@as(u32, 440), p.voice().?.hz); // 3579545 / (32 * 254)
}

test "psg: voice skips silent channels, tiny periods and noise" {
    var p: psg.Psg = .{};
    set(&p, 0, 1, 0); // period 1: DC trick
    set(&p, 1, 0, 0); // period 0
    set(&p, 2, 0x300, 15); // silent
    p.write(0xF0); // noise at full volume: never a voice
    try expectEqual(@as(?psg.Voice, null), p.voice());
    set(&p, 2, 0x300, 14);
    const v = p.voice().?;
    try expectEqual(@as(u2, 2), v.channel);
    try expectEqual(@as(u4, 14), v.atten);
    set(&p, 0, psg.min_period, 13);
    try expectEqual(@as(u2, 0), p.voice().?.channel);
}
