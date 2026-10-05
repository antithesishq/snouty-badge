//! The results screen (SPEC 8): rank, race time, best lap, rewinds used,
//! knockouts and thermal left, then COMMITTED. Draw only; main.zig owns the flow.
const cart = @import("cart-api");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const hud = @import("hud.zig");

/// Rewinds used this race (history/M3 sets it; 0 until then).
pub var rewinds: u32 = 0;

fn put_uint(out: []u8, v: u32) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
}

fn rank_word(rank: u8) []const u8 {
    return switch (rank) {
        1 => "1ST",
        2 => "2ND",
        3 => "3RD",
        4 => "4TH",
        5 => "5TH",
        else => "RETIRED",
    };
}

pub fn draw(frame: u32) void {
    const m = &world.w.machines[world.player];
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    hud.centered(if (m.active) "COMMITTED" else "JOB KILLED", 12, if (m.active) hud.cyan else hud.coral);
    hud.text("RANK", 24, 34, hud.white);
    const rank: u8 = if (!m.active) 0 else if (world.w.active_count > 1) m.rank else 1;
    hud.text(rank_word(rank), 88, 34, if (rank == 1) hud.cyan else if (rank == 0) hud.coral else hud.white);
    var clock: [7]u8 = undefined;
    hud.format_clock(&clock, m.finish_tick);
    hud.text("TIME", 24, 46, hud.white);
    hud.text(&clock, 88, 46, hud.white);
    hud.format_clock(&clock, m.best_lap);
    hud.text("BEST", 24, 58, hud.white);
    hud.text(&clock, 88, 58, hud.white);
    var n: [3]u8 = "  0".*;
    put_uint(&n, @min(rewinds, 999));
    hud.text("REWINDS", 24, 70, hud.white);
    hud.text(&n, 88, 70, hud.white);
    var kos: [3]u8 = "  0".*;
    put_uint(&kos, world.w.kos[0]);
    hud.text("KOS", 24, 82, hud.white);
    hud.text(&kos, 88, 82, if (world.w.kos[0] > 0) hud.cyan else hud.white);
    var pct: [4]u8 = "  0%".*;
    put_uint(pct[0..3], @intCast(@divTrunc(@as(i32, @max(0, m.thermal)) * 100, tuning.thermal_max)));
    hud.text("THERMAL", 24, 94, hud.white);
    hud.text(&pct, 88, 94, hud.orange);
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 112, hud.coral);
}
