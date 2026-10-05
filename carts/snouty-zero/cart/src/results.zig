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

/// A link race's results (M6): both humans, this badge's first (YOU, the
/// partner PEER, "PEER (AI)" once the AI took its machine): place, time,
/// best lap and knockouts. No GP points. `desync`: the race stopped
/// where the two badges' Worlds parted (no times for the unfinished).
pub fn draw_link(frame: u32, me: u1, desync: bool) void {
    const w = &world.w;
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    if (desync) {
        hud.centered("DESYNC: RACE ENDED", 6, if ((frame / 20) % 2 == 0) hud.coral else hud.white);
    } else {
        hud.centered("COMMITTED", 6, hud.cyan);
    }
    for ([2]u1{ me, me ^ 1 }, 0..) |s, row| {
        const h = w.humans[s];
        if (h == world.no_human) continue;
        const m = &w.machines[h];
        const y0: i32 = 22 + @as(i32, @intCast(row)) * 44;
        const name: []const u8 = if (row == 0) "YOU" else if (w.ai_drives[s]) "PEER (AI)" else "PEER";
        hud.text(name, 16, y0, if (row == 0) hud.cyan else hud.white);
        const rank: u8 = if (!m.active) 0 else m.rank;
        hud.text(rank_word(rank), 144 - 8 * @as(i32, @intCast(rank_word(rank).len)), y0, if (rank == 1) hud.cyan else if (rank == 0) hud.coral else hud.white);
        var clock: [7]u8 = "-'--\"--".*;
        if (m.finished) hud.format_clock(&clock, m.finish_tick);
        hud.text("TIME", 24, y0 + 11, hud.white);
        hud.text(&clock, 88, y0 + 11, hud.white);
        clock = "-'--\"--".*;
        if (m.best_lap != 0) hud.format_clock(&clock, m.best_lap);
        hud.text("BEST", 24, y0 + 21, hud.white);
        hud.text(&clock, 88, y0 + 21, hud.white);
        var kos: [3]u8 = "  0".*;
        put_uint(&kos, w.kos[s]);
        hud.text("KOS", 24, y0 + 31, hud.white);
        hud.text(&kos, 88 + 32, y0 + 31, if (w.kos[s] > 0) hud.cyan else hud.white);
    }
    if ((frame / 30) % 2 == 0) hud.centered("A: LOBBY", 114, hud.coral);
}
