//! dmg-acid2: run the ROM for 20 frames, compare the last full frame with
//! the reference (160x144 final shades, row-major, 0 lightest). Owner in
//! M1: track B. Needs a real CPU: skipped while `cpu.step` is the stub.
const std = @import("std");
const core = @import("core");

const rom = @embedFile("roms/dmg-acid2.gb");
const reference = @embedFile("acid2_reference.bin");
const W = core.screen_w;
const H = core.screen_h;

comptime {
    if (reference.len != W * H) @compileError("acid2_reference.bin must be 160x144 bytes");
}

const Frame = [H][W]u8;

const Capture = struct {
    work: Frame = @splat(@splat(0)),
    /// Last frame for which all 144 lines arrived in order.
    done: Frame = @splat(@splat(0)),
    have_done: bool = false,
    next_ly: u8 = 0,

    fn emit(ctx: *anyopaque, ly: u8, line: *const [W]u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (ly == 0) self.next_ly = 0;
        if (ly != self.next_ly) {
            self.next_ly = 0xFF; // out of order: this frame is incomplete
            return;
        }
        self.work[ly] = line.*;
        self.next_ly = ly + 1;
        if (ly == H - 1) {
            self.done = self.work;
            self.have_done = true;
        }
    }
};

/// Every 2nd column and 4th row, shades as " .+#".
fn dump(title: []const u8, f: *const Frame) void {
    std.debug.print("{s}\n", .{title});
    var y: usize = 0;
    while (y < H) : (y += 4) {
        var row: [W / 2]u8 = undefined;
        for (&row, 0..) |*c, i| c.* = " .+#"[f[y][i * 2] & 3];
        std.debug.print("|{s}|\n", .{&row});
    }
}

test "acid2 matches reference frame" {
    var gb = core.Gb.init(rom, .dmg, &.{});
    var cap: Capture = .{};
    gb.line_sink = .{ .ctx = &cap, .func = Capture.emit };

    gb.step_frame(0);
    const vram_touched = for (gb.vram) |b| {
        if (b != 0) break true;
    } else false;
    if (gb.cpu.pc == 0x0100 and !vram_touched) {
        std.debug.print("acid2: CPU is still the stub (PC stuck at 0x0100, VRAM untouched); skipping\n", .{});
        return error.SkipZigTest;
    }
    for (1..20) |_| gb.step_frame(0);

    if (!cap.have_done) {
        std.debug.print("acid2: no complete frame captured in 20 frames\n", .{});
        return error.TestUnexpectedResult;
    }
    const expected: *const Frame = @ptrCast(reference);
    for (0..H) |y| {
        for (0..W) |x| {
            if (cap.done[y][x] != expected[y][x]) {
                var diffs: usize = 0;
                for (0..H) |yy| for (0..W) |xx| {
                    if (cap.done[yy][xx] != expected[yy][xx]) diffs += 1;
                };
                std.debug.print("acid2: first mismatch at (x={d}, y={d}): expected shade {d}, got {d}; {d} pixels differ\n", .{ x, y, expected[y][x], cap.done[y][x], diffs });
                dump("expected:", expected);
                dump("actual:", &cap.done);
                return error.TestExpectedEqual;
            }
        }
    }
}
