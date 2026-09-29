//! cgb-acid2 byte-exact test (SPEC.md 19.6). Owner in M6: track B.
//! Runs tests/roms/cgb-acid2.gbc (read at run time; skipped if absent) in
//! CGB mode, converts every emitted line through palette RAM as it is at
//! emit time (the frontend's LUT does the same), and compares the last
//! complete frame with tests/cgb_acid2_reference.bin (160x144 RGB555 LE,
//! made by tools/make_cgb_ref.py from the upstream reference PNG).
const std = @import("std");
const core = @import("core");

const reference = @embedFile("cgb_acid2_reference.bin");
const W = core.screen_w;
const H = core.screen_h;

comptime {
    if (reference.len != W * H * 2) @compileError("cgb_acid2_reference.bin must be 160x144 u16");
}

/// The ROM draws its frame once and then loops on `LD B,B`; 60 frames is
/// ample.
const frames = 60;

const Frame = [H][W]u16;

const Capture = struct {
    gb: *const core.Gb,
    work: Frame = @splat(@splat(0)),
    /// Last frame for which all 144 lines arrived in order.
    done: Frame = @splat(@splat(0)),
    have_done: bool = false,
    next_ly: u8 = 0,

    fn emit(ctx: *anyopaque, ly: u8, line: *const [W]u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (ly == 0) self.next_ly = 0;
        if (ly != self.next_ly) {
            self.next_ly = 0xFF;
            return;
        }
        const p = &self.gb.ppu;
        for (&self.work[ly], line) |*px, v| {
            const pal = if (v < 32) &p.bg_pal else &p.obj_pal;
            const o = @as(usize, v & 31) * 2;
            px.* = (@as(u16, pal[o]) | @as(u16, pal[o + 1]) << 8) & 0x7FFF;
        }
        self.next_ly = ly + 1;
        if (ly == H - 1) {
            self.done = self.work;
            self.have_done = true;
        }
    }
};

var rom_buf: [0x10000]u8 = undefined;

fn load_rom() ?[]const u8 {
    const paths = [_][]const u8{
        "carts/snouty-boy/tests/roms/cgb-acid2.gbc",
        "tests/roms/cgb-acid2.gbc",
        "roms/cgb-acid2.gbc",
    };
    for (paths) |p| {
        return std.Io.Dir.cwd().readFile(std.testing.io, p, &rom_buf) catch continue;
    }
    return null;
}

/// Debug aid: the captured frame as a binary PPM in /tmp (not committed).
fn write_ppm(f: *const Frame) void {
    var buf: [15 + W * H * 3]u8 = undefined;
    const hdr = "P6\n160 144\n255\n";
    @memcpy(buf[0..hdr.len], hdr);
    var i: usize = hdr.len;
    for (f) |row| for (row) |c| {
        inline for (0..3) |k| {
            const c5: u8 = @truncate((c >> (5 * k)) & 31);
            buf[i] = (c5 << 3) | (c5 >> 2);
            i += 1;
        }
    };
    std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/cgb_acid2_actual.ppm", .data = buf[0..i] }) catch return;
    std.debug.print("cgb-acid2: wrote /tmp/cgb_acid2_actual.ppm\n", .{});
}

test "cgb-acid2 matches reference frame" {
    const rom = load_rom() orelse return error.SkipZigTest;
    const gb = try std.testing.allocator.create(core.Gb);
    defer std.testing.allocator.destroy(gb);
    gb.* = core.Gb.init_slice(rom, .cgb, &.{});
    const cap = try std.testing.allocator.create(Capture);
    defer std.testing.allocator.destroy(cap);
    cap.* = .{ .gb = gb };
    gb.line_sink = .{ .ctx = cap, .func = Capture.emit };

    for (0..frames) |_| gb.step_frame(0);

    if (!cap.have_done) {
        std.debug.print("cgb-acid2: no complete frame captured in {d} frames\n", .{frames});
        return error.TestUnexpectedResult;
    }
    var diffs: usize = 0;
    var first: ?[2]usize = null;
    for (0..H) |y| for (0..W) |x| {
        const o = (y * W + x) * 2;
        const want = @as(u16, reference[o]) | @as(u16, reference[o + 1]) << 8;
        if (cap.done[y][x] != want) {
            if (first == null) {
                first = .{ x, y };
                std.debug.print("cgb-acid2: first mismatch at (x={d}, y={d}): expected {X:0>4}, got {X:0>4}\n", .{ x, y, want, cap.done[y][x] });
            }
            diffs += 1;
        }
    };
    if (diffs != 0) {
        std.debug.print("cgb-acid2: {d} pixels differ\n", .{diffs});
        write_ppm(&cap.done);
        return error.TestExpectedEqual;
    }
}
