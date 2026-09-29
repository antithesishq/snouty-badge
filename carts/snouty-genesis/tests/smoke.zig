//! M0 smoke test: the console constructs, one frame steps (with and
//! without rendering), the sizes of `Md` and `Keyframe` stay under the
//! SPEC.md section 13 estimates, the embedded ROM's header parses, the
//! Z80 import runs, keyframes round-trip and both ROM source kinds agree.
const std = @import("std");
const core = @import("core");
const rom_data = @import("rom");
const Md = core.Md;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// SPEC.md section 13: live console ~138 KB, Keyframe ~137 KB (the console
/// minus the ROM source and the sink). The asserts allow the section's
/// round figures, 140 KB and 139 KB; growing past them is a spec change.
const md_limit = 140 * 1024;
const keyframe_limit = 139 * 1024;

test "smoke: Md and Keyframe sizes are under the SPEC.md section 13 estimates" {
    std.debug.print("\nsnouty-genesis: @sizeOf(Md) = {d} B ({d} KB), @sizeOf(Keyframe) = {d} B ({d} KB)\n", .{
        @sizeOf(Md),          @sizeOf(Md) / 1024,
        @sizeOf(Md.Keyframe), @sizeOf(Md.Keyframe) / 1024,
    });
    try expect(@sizeOf(Md) <= md_limit);
    try expect(@sizeOf(Md.Keyframe) <= keyframe_limit);
}

const Capture = struct {
    rows: u32 = 0,
    last_row: u8 = 0,
    first: [core.out_w]u8 = undefined,
    row16: [core.out_w]u8 = undefined,

    fn on_line(ctx: *anyopaque, row: u8, line: *const [core.out_w]u8, cram: *const [64]u16) void {
        const c: *Capture = @ptrCast(@alignCast(ctx));
        if (row == 0) c.first = line.*;
        if (row == 16) c.row16 = line.*;
        c.rows += 1;
        c.last_row = row;
        _ = cram;
    }
};

test "smoke: Md constructs from the embedded ROM and steps a frame" {
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(rom_data.data));
    try expectEqual(@as(u32, 0), md.frame_count);
    // Reset fetched SSP and PC from the vectors.
    try expectEqual(core.rom.read32(&md.rom, 0), md.cpu.a[7]);
    try expectEqual(core.rom.read32(&md.rom, 4), md.cpu.pc);

    var cap: Capture = .{};
    md.line_sink = .{ .ctx = &cap, .func = &Capture.on_line };
    md.step_frame(core.Pad.start, false);
    try expectEqual(@as(u32, 0), cap.rows);
    md.step_frame(0, true);
    try expectEqual(@as(u32, 2), md.frame_count);
    try expectEqual(@as(u32, core.out_h), cap.rows);
    try expectEqual(@as(u8, core.out_h - 1), cap.last_row);
    // Row 16 is palette 0's 16 bars, 10 px each; row 0 is black.
    try expectEqual(@as(u8, 0), cap.first[159]);
    try expectEqual(@as(u8, 0), cap.row16[0]);
    try expectEqual(@as(u8, 15), cap.row16[159]);
    try expectEqual(@as(u16, 0), md.vdp.line);
    try expectEqual(@as(?core.Tone, null), md.tone());
}

test "smoke: the embedded ROM's header parses" {
    const src = core.RomSource.from_slice(rom_data.data);
    try expect(core.rom.is_genesis(&src));
    const h = core.rom.parse_header(&src);
    try expect(std.mem.startsWith(u8, &h.system, "SEGA"));
    try expect(core.rom.trim(&h.domestic).len > 0);
    std.debug.print("snouty-genesis: embedded {s}: \"{s}\", {d} bytes, header says {d}\n", .{
        rom_data.name, core.rom.trim(&h.domestic), src.size, h.declared_size(),
    });
    if (rom_data.placeholder) {
        try expectEqual(@as(u32, 512), src.size);
        try std.testing.expectEqualStrings("SEGA GENESIS", core.rom.trim(&h.system));
        try std.testing.expectEqualStrings("SNOUTY PLACEHOLDER", core.rom.trim(&h.domestic));
        try expectEqual(@as(u32, 512), h.declared_size());
        try std.testing.expectEqualStrings("JUE", &h.region);
    }
}

test "smoke: the Z80 runs a Z80 RAM program through Z80Bus" {
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    const data: [0x200]u8 = @splat(0);
    md.init_in_place(core.RomSource.from_slice(&data));
    // ld a,5A ; ld (1000),a ; jr $
    const prog = [_]u8{ 0x3E, 0x5A, 0x32, 0x00, 0x10, 0x18, 0xFE };
    @memcpy(md.z80_ram[0..prog.len], &prog);
    var zb = md.z80bus_for();
    var t: u32 = 0;
    for (0..3) |_| t += md.z80.step(&zb);
    try expectEqual(@as(u8, 0x5A), md.z80_ram[0x1000]);
    try expectEqual(@as(u16, 5), md.z80.pc);
    try expectEqual(@as(u32, 7 + 13 + 12), t);
}

test "md: keyframe round trip" {
    const data: [0x200]u8 = @splat(0);
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    const k = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(k);
    md.init_in_place(core.RomSource.from_slice(&data));
    md.step_frame(core.Pad.right, false);
    md.work_ram[5] = 0xAA;
    md.snapshot(k);
    md.work_ram[5] = 0;
    md.frame_count = 99;
    md.restore(k);
    try std.testing.expectEqual(@as(u8, 0xAA), md.work_ram[5]);
    try std.testing.expectEqual(@as(u32, 1), md.frame_count);
    try std.testing.expectEqual(core.Pad.right, md.pad);
}

test "rom: contiguous and clustered sources read the same bytes" {
    var data: [2048]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    const flat = core.RomSource.from_slice(&data);
    // A fake volume: data_base covers clusters 2..9; the file lives in
    // clusters 5, 3, 8, 2 (in file order).
    var vol: [8 * 512]u8 = @splat(0);
    const order = [_]u16{ 5, 3, 8, 2 };
    for (order, 0..) |cl, i| @memcpy(vol[(cl - 2) * 512 ..][0..512], data[i * 512 ..][0..512]);
    const frag: core.RomSource = .{ .size = data.len, .clusters = &order, .data_base = &vol };
    try std.testing.expect(frag.valid());
    var a: u32 = 0;
    while (a < data.len + 4) : (a += 1) {
        try std.testing.expectEqual(core.rom.read8(&flat, a), core.rom.read8(&frag, a));
        if (a & 1 == 0) try std.testing.expectEqual(core.rom.read16(&flat, a), core.rom.read16(&frag, a));
    }
    try std.testing.expectEqual(@as(u16, 0xFFFF), core.rom.read16(&flat, 2048));
    try std.testing.expectEqual(@as(u16, @as(u16, data[512]) << 8 | data[513]), core.rom.read16(&frag, 512));
}
