//! core/rom.zig: the bank table built from a slice, and the fallback path.
const std = @import("std");
const core = @import("core");
const Rom = core.Rom;
const bank = core.rom.bank_size;

test "rom: 64 KB slice gives 4 banks at the right offsets" {
    var data: [0x10000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i >> 8);
    const r = Rom.from_slice(&data);
    try std.testing.expectEqual(@as(u32, 0x10000), r.size);
    try std.testing.expectEqual(@as(u8, 4), r.bank_count);
    for (0..4) |i| try std.testing.expectEqual(@as([*]const u8, data[i * bank ..].ptr), r.banks[i].?);
    try std.testing.expect(r.banks[4] == null);
    try std.testing.expect(r.all_direct());
    try std.testing.expectEqual(@as(u8, 0x7F), r.read(0x7FF0));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x10000));
}

test "rom: 48 KB slice gives 3 banks" {
    const data: [0xC000]u8 = @splat(1);
    const r = Rom.from_slice(&data);
    try std.testing.expectEqual(@as(u8, 3), r.bank_count);
    try std.testing.expect(r.banks[2] != null and r.banks[3] == null);
    try std.testing.expectEqual(@as(u8, 1), r.read(0xBFFF));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0xC000));
}

test "rom: partial last bank is read through the slice" {
    const data: [0x5000]u8 = @splat(7);
    const r = Rom.from_slice(&data);
    try std.testing.expectEqual(@as(u8, 2), r.bank_count);
    try std.testing.expect(r.banks[0] != null and r.banks[1] == null);
    try std.testing.expect(!r.all_direct());
    try std.testing.expectEqual(@as(u8, 7), r.read(0x4FFF));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x5000));
}

test "rom: null banks go through read_fallback" {
    const Ctx = struct {
        fn read(ctx: *const anyopaque, offset: u32) u8 {
            const base: *const u8 = @ptrCast(ctx);
            return base.* +% @as(u8, @truncate(offset));
        }
    };
    const seed: u8 = 0x10;
    var r: Rom = .{ .size = 2 * bank, .bank_count = 2, .read_fallback = .{ .ctx = &seed, .func = &Ctx.read } };
    const direct: [bank]u8 = @splat(0xAB);
    r.banks[0] = &direct;
    try std.testing.expectEqual(@as(u8, 0xAB), r.read(5));
    try std.testing.expectEqual(@as(u8, 0x15), r.read(bank + 5));
}
