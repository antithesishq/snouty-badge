//! Miniplanets (`roms/miniplanets.bin`) from a fragmented drive layout
//! runs exactly as from the embedded copy (PLAN.md M4 Track A): the 68000
//! fetches through `rom.run_at` windows and the VDP DMAs run by run, so
//! every rendered row and the console state must match frame for frame.
//! Two layouts: every 512-byte cluster its own run (`--fragment 1`'s worst
//! case) and runs of four (`--fragment 4`). 300 updates (600 frames) with
//! golden-mini's input, through the title, the menus and a level load.
//! Skips if the ROM is absent.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const golden_mini = @import("golden_mini.zig");

const updates = 300;
const per_update = 2;
const rom_size = 0x80000;
const n_cl = rom_size / 512;

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };
var rom_buf: [rom_size]u8 = undefined;

fn read_rom() ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}roms/miniplanets.bin", .{pre}) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, &rom_buf) catch continue;
    }
    return null;
}

const Hasher = struct {
    hash: u64 = 0,

    fn on_line(ctx: *anyopaque, row: u8, line: [*]const u8, width: u16, cram: *const [64]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{row});
        w.update(line[0..width]);
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
    }
};

fn same_state(a: *const Md, b: *const Md) !void {
    try std.testing.expectEqualSlices(u8, &a.work_ram, &b.work_ram);
    try std.testing.expectEqualSlices(u8, &a.z80_ram, &b.z80_ram);
    try std.testing.expectEqualSlices(u8, &a.vdp.vram, &b.vdp.vram);
    try std.testing.expectEqualSlices(u32, &a.cpu.d, &b.cpu.d);
    try std.testing.expectEqualSlices(u32, &a.cpu.a, &b.cpu.a);
    try std.testing.expectEqual(a.cpu.pc, b.cpu.pc);
    try std.testing.expectEqual(a.cpu.get_sr(), b.cpu.get_sr());
    try std.testing.expectEqual(a.z80.pc, b.z80.pc);
}

test "rom: Miniplanets from fragmented layouts (runs of 1 and 4) matches the embedded run" {
    const rom = read_rom() orelse return error.SkipZigTest;
    if (rom.len != rom_size) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    // Volume cluster of file cluster k: runs of 1 scattered by a stride,
    // and runs of 4 whose groups are scattered the same way.
    var order1: [n_cl]u16 = undefined;
    var order4: [n_cl]u16 = undefined;
    for (0..n_cl) |k| {
        order1[k] = @intCast(2 + (k * 389) % n_cl);
        order4[k] = @intCast(2 + ((k / 4) * 37) % (n_cl / 4) * 4 + k % 4);
    }
    const vol1 = try alloc.alloc(u8, rom_size);
    defer alloc.free(vol1);
    const vol4 = try alloc.alloc(u8, rom_size);
    defer alloc.free(vol4);
    for (0..n_cl) |k| {
        @memcpy(vol1[(@as(usize, order1[k]) - 2) * 512 ..][0..512], rom[k * 512 ..][0..512]);
        @memcpy(vol4[(@as(usize, order4[k]) - 2) * 512 ..][0..512], rom[k * 512 ..][0..512]);
    }
    const srcs = [3]core.RomSource{
        core.RomSource.from_slice(rom),
        .{ .size = rom_size, .clusters = &order1, .data_base = vol1.ptr },
        .{ .size = rom_size, .clusters = &order4, .data_base = vol4.ptr },
    };
    var mds: [3]*Md = undefined;
    var hs: [3]Hasher = @splat(.{});
    for (&mds, srcs, &hs) |*m, s, *h| {
        m.* = try alloc.create(Md);
        m.*.init_in_place(s);
        m.*.line_sink = .{ .ctx = h, .func = &Hasher.on_line };
    }
    defer for (mds) |m| alloc.destroy(m);

    var u: u32 = 0;
    while (u < updates) : (u += 1) {
        for (mds) |m| {
            var f: u32 = 0;
            while (f < per_update) : (f += 1) m.step_frame(golden_mini.pad_at(u), f == per_update - 1);
        }
        try std.testing.expectEqual(hs[0].hash, hs[1].hash);
        try std.testing.expectEqual(hs[0].hash, hs[2].hash);
    }
    try same_state(mds[0], mds[1]);
    try same_state(mds[0], mds[2]);
}
