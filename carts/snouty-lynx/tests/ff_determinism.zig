//! Fast forward (docs/FAST_FORWARD.md at the root, main.zig `run_frame`)
//! changes nothing the game can see: a console stepped in fast-forward
//! updates (batches of 4 frames, the simulator's; the badge's run 1 to 8,
//! every one with `audio_render` off as main.zig does while fast, each
//! recorded by the scrubber) equals one stepped a frame per update with
//! sound rendered, RAM byte for byte and `Lynx.Small` field by field after
//! every update, and shows the same picture. The renderer's state (the DC blocker, the
//! bins) runs either way; `audio_render` only stops the sample stores.
//! raycast under the m1 play script, and Hard Drivin' (local dump, its
//! title music) when `~/roms/lynx/hard_drivin.lnx` exists.
const std = @import("std");
const core = @import("core");
const Lynx = core.Lynx;
const undo = core.undo;
const runner = @import("runner.zig");
const files = @import("testfiles.zig");
const uu = @import("undo_unit.zig");
const expect = std.testing.expect;

/// frontend/tuning.zig `ff_max_frames`: one simulator update's frames.
const batch = 4;

const Pads = union(enum) {
    play: uu.PlayPads,
    none,

    fn at(p: *const Pads, f: u32) u16 {
        return switch (p.*) {
            .play => |*q| q.at(f),
            .none => 0,
        };
    }
};

fn check(name: []const u8, cart: core.Cart, pads: Pads, frames: u32) !void {
    const a = std.testing.allocator;
    const fast = try a.create(Lynx);
    defer a.destroy(fast);
    const plain = try a.create(Lynx);
    defer a.destroy(plain);
    const st = try a.alloc(uu.State, 2);
    defer a.free(st);
    const arena = try a.alignedAlloc(u8, .@"4", 8 << 20);
    defer a.free(arena);

    fast.init_in_place(cart);
    plain.init_in_place(cart);
    undo.frames_per_record = 60; // the cart's figure
    undo.init(arena);
    defer undo.disable();
    undo.reset(fast);

    var f: u32 = 0;
    while (f < frames) : (f += batch) {
        for (0..batch) |i| {
            const pad = pads.at(f + @as(u32, @intCast(i)));
            fast.audio_render = false;
            fast.step_frame(pad);
            undo.record_frame(fast);
            plain.audio_render = true;
            plain.step_frame(pad);
        }
        var buf: [48]u8 = undefined;
        const what = try std.fmt.bufPrint(&buf, "{s} frame {d}", .{ name, f + batch });
        uu.snapshot(fast, &st[0]);
        uu.snapshot(plain, &st[1]);
        try uu.same_state(what, &st[0], &st[1]);
        if (runner.frame_hash(fast.frame()) != runner.frame_hash(plain.frame())) {
            std.debug.print("{s}: the pictures differ\n", .{what});
            return error.PictureDiffers;
        }
    }
    try expect(!undo.lost_history());
}

test "ff: raycast, 600 frames in fast-forward updates equal 600 at 1x" {
    try check("raycast", try uu.raycast(), .{ .play = try uu.PlayPads.init() }, 600);
}

var hd_buf: [1 << 18]u8 = undefined;

test "ff: Hard Drivin' (local dump), 600 frames with its music, fast equals 1x" {
    const rom = files.read_home_file("roms/lynx/hard_drivin.lnx", &hd_buf) orelse return error.SkipZigTest;
    const cart = switch (runner.cart_from_file(rom)) {
        .ok => |c| c,
        .refused => return error.TestUnexpectedResult,
    };
    try check("hard_drivin", cart, .none, 600);
}
