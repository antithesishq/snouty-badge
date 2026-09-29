//! Golden frames of the shipped ROM (SPEC.md section 16): run
//! `roms/waternet.gg` for 600 frames under the scripted input of
//! `tools/scripts/m1_play.json` (the preview/badge-bench script shape:
//! `[{ "from": f, "to": t, "hold": ["RIGHT", "B", ...] }]`, frames 0-based,
//! `to` inclusive, badge button names: B = button 1, A = button 2, SELECT
//! ignored), hash every frame's 144 lines plus CRAM, and compare the hashes
//! at `checkpoints` with `expected`.
//!
//! Both files are read at run time (they live outside this test module's
//! directory, so `@embedFile` cannot reach them); the test skips if the
//! ROM is absent. `expected` starts empty: the test then only prints the
//! hashes, and integration fills the table after reviewing the frames by
//! eye.
const std = @import("std");
const core = @import("core");
const Gg = core.Gg;
const Pad = core.Pad;

const frames = 600;
/// Frames with content on screen in the m1_play run (reviewed 2026-09-29):
/// 120 main menu, 180 mode select, 360 the pipe grid, 570 the grid again
/// after the quit prompt was declined.
const checkpoints = [_]u32{ 120, 180, 360, 570 };
/// Hashes at `checkpoints` from the reviewed M1 run (empty: print only).
const expected = [_]u64{ 0x111996CE647897B6, 0x8DF535FC3DFF2F30, 0x32C976B8D958EF08, 0xB5B09532EB293AE2 };

const Hasher = struct {
    lines: u32 = 0,
    next_y: u32 = 0,
    in_order: bool = true,
    hash: u64 = 0,

    fn on_line(ctx: *anyopaque, y: u8, pixels: *const [core.screen_w]u5, cram: *const [32]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        if (y != h.next_y) h.in_order = false;
        h.next_y = @as(u32, y) + 1;
        h.lines += 1;
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{y});
        var bytes: [core.screen_w]u8 = undefined;
        for (&bytes, pixels) |*b, p| b.* = p;
        w.update(&bytes);
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
    }

    fn sink(h: *Hasher) core.LineSink {
        return .{ .ctx = h, .func = &on_line };
    }

    fn start_frame(h: *Hasher) void {
        h.* = .{};
    }

    /// The frame's hash: the lines, then the CRAM as it is at the end of
    /// the frame (so a stub VDP that emits no lines still hashes something).
    fn finish(h: *const Hasher, gg: *const Gg) u64 {
        var w = std.hash.Wyhash.init(h.hash);
        w.update(std.mem.sliceAsBytes(&gg.vdp.cram));
        return w.final();
    }
};

/// Tried in order; the test binary's working directory depends on how the
/// build runs it.
const prefixes = [_][]const u8{ "", "carts/snouty-gear/", "../", "../../" };

fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

const Hold = struct { from: u32, to: u32, hold: []const []const u8 };

fn button(name: []const u8) !u8 {
    const map = [_]struct { []const u8, u8 }{
        .{ "UP", Pad.up },       .{ "DOWN", Pad.down }, .{ "LEFT", Pad.left },
        .{ "RIGHT", Pad.right }, .{ "B", Pad.b1 },      .{ "A", Pad.b2 },
        .{ "START", Pad.start }, .{ "SELECT", 0 },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return error.UnknownButton;
}

/// Pad byte per frame from the script.
fn script_pads(json: []const u8, pads: *[frames]u8) !void {
    const parsed = try std.json.parseFromSlice([]const Hold, std.testing.allocator, json, .{});
    defer parsed.deinit();
    @memset(pads, 0);
    for (parsed.value) |h| {
        var bits: u8 = 0;
        for (h.hold) |name| bits |= try button(name);
        var f = h.from;
        while (f <= h.to and f < frames) : (f += 1) pads[f] |= bits;
    }
}

var rom_buf: [0x80000]u8 = undefined;
var script_buf: [0x4000]u8 = undefined;

test "golden: waternet.gg scripted run, frame hashes at checkpoints" {
    const rom = read_any("roms/waternet.gg", &rom_buf) orelse return error.SkipZigTest;
    const json = read_any("tools/scripts/m1_play.json", &script_buf) orelse return error.FileNotFound;
    var pads: [frames]u8 = undefined;
    try script_pads(json, &pads);

    const gg = try std.testing.allocator.create(Gg);
    defer std.testing.allocator.destroy(gg);
    gg.init_in_place(core.Rom.from_slice(rom));
    var h: Hasher = .{};
    gg.line_sink = h.sink();

    var got: [checkpoints.len]u64 = undefined;
    var ci: usize = 0;
    for (pads, 1..) |pad, f| {
        h.start_frame();
        gg.step_frame(pad);
        // The M0 VDP stub emits no lines; the real one emits 144 in order.
        try std.testing.expect(h.lines == 0 or h.lines == core.screen_h);
        try std.testing.expect(h.in_order);
        if (ci < checkpoints.len and f == checkpoints[ci]) {
            got[ci] = h.finish(gg);
            ci += 1;
        }
    }
    try std.testing.expectEqual(checkpoints.len, ci);

    if (expected.len == 0) {
        std.debug.print("\ngolden: waternet.gg frame hashes (fill `expected` after review):\n", .{});
        for (checkpoints, got) |c, g| std.debug.print("  frame {d}: 0x{X:0>16}\n", .{ c, g });
        std.debug.print("  pc {X:0>4} frame IRQs {d} line IRQs {d}\n", .{ gg.cpu.pc, gg.irq_frame_count, gg.irq_line_count });
    } else {
        for (expected, got, checkpoints) |e, g, c| {
            if (e != g) std.debug.print("golden: frame {d}: got 0x{X:0>16}, want 0x{X:0>16}\n", .{ c, g, e });
        }
        try std.testing.expectEqualSlices(u64, &expected, &got);
    }
}
