//! Host tests for the saved game (snapshot.zig): the LZ round trip, the
//! header checks, and the main one: the autoplayer plays a game from the
//! first second to stage 3, and at checkpoints along the way the state is
//! saved, loaded into a fresh Game and both are run on, next to a copy
//! that was never saved (only canonicalized), comparing every field.
//! Built ReleaseSafe by the cart's build.zig (the long game run).

const std = @import("std");
const game = @import("game.zig");
const snap = game.snapshot;
const Game = game.Game;
const Bot = game.bot.Bot;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

var blob_buf: [snap.max_blob]u8 = undefined;
var games: [4]Game = undefined;

// ---- field-by-field comparison (floats by their bits) ----

const Diff = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    fn set(d: *Diff, comptime f: []const u8, args: anytype) void {
        if (d.len != 0) return;
        const s = std.fmt.bufPrint(&d.buf, f, args) catch &d.buf;
        d.len = s.len;
    }
};

fn diff_type(comptime T: type, a: *const T, b: *const T, comptime path: []const u8, d: *Diff) void {
    if (d.len != 0) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            diff_type(@FieldType(T, name), &@field(a, name), &@field(b, name), path ++ "." ++ name, d);
        },
        .array => |arr| for (0..arr.len) |i| {
            diff_type(arr.child, &a[i], &b[i], path ++ "[]", d);
            if (d.len != 0) {
                var tmp: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&tmp, "{s} (index {d})", .{ d.buf[0..d.len], i }) catch return;
                @memcpy(d.buf[0..msg.len], msg);
                d.len = msg.len;
                return;
            }
        },
        else => if (!std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b))) {
            d.set("{s}: {any} vs {any}", .{ path, a.*, b.* });
        },
    }
}

fn expect_same(a: *const Game, b: *const Game, what: []const u8) !void {
    var d: Diff = .{};
    diff_type(Game, a, b, "g", &d);
    if (d.len != 0) {
        std.debug.print("\n{s}: first difference {s}\n", .{ what, d.buf[0..d.len] });
        return error.TestExpectedEqual;
    }
}

fn copy(dst: *Game, src: *const Game) void {
    @memcpy(std.mem.asBytes(dst), std.mem.asBytes(src));
}

// ---- the compressor ----

test "lz round trip: zeros, text, noise, overlaps" {
    var src: [9000]u8 = undefined;
    var st: u64 = 0x9E3779B97F4A7C15;
    for (&src, 0..) |*c, i| {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        c.* = switch ((i / 700) % 4) {
            0 => 0,
            1 => "AutoClippers available "[i % 23],
            2 => @truncate(st),
            else => @intCast(i % 3),
        };
    }
    var packed_buf: [9000 + 9000 / 64]u8 = undefined;
    var out: [9000]u8 = undefined;
    const n = try snap.compress(&src, &packed_buf);
    try snap.decompress(packed_buf[0..n], &out);
    try expect(std.mem.eql(u8, &src, &out));
    std.debug.print("\nlz: 9000 mixed bytes -> {d}\n", .{n});
    try expect(n < 4500);
    // Incompressible input: the worst case fits `max_blob`'s margin.
    for (&src) |*c| {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        c.* = @truncate(st);
    }
    const m = try snap.compress(&src, &packed_buf);
    std.debug.print("lz: 9000 noise bytes -> {d}\n", .{m});
    try expect(m <= src.len + src.len / 64);
    try snap.decompress(packed_buf[0..m], &out);
    try expect(std.mem.eql(u8, &src, &out));
    // A buffer too small says so.
    try expectError(error.NoRoom, snap.compress(&src, packed_buf[0..100]));
    // Garbage does not run off the end.
    try expectError(error.Corrupt, snap.decompress(&.{ 0x85, 0x10, 0x00 }, &out));
    try expectError(error.Corrupt, snap.decompress(&.{ 0x05, 1, 2 }, &out));
}

// ---- the header ----

test "saved game: a different version, layout or size is refused, damage is caught" {
    const g = &games[0];
    game.init(g, 5);
    game.advance_ms(g, 3000);
    const blob = try snap.encode(g, &blob_buf);
    const b = &games[1];
    try snap.decode(blob, b);
    try expect_same(g, b, "fresh decode");

    var bad: [snap.max_blob]u8 = undefined;
    const variants = [_]struct { at: usize, err: snap.Error }{
        .{ .at = 0, .err = error.Corrupt }, // magic
        .{ .at = 4, .err = error.OldVersion }, // format version
        .{ .at = 8, .err = error.OldVersion }, // layout hash
        .{ .at = 12, .err = error.OldVersion }, // image size
        .{ .at = 16, .err = error.Corrupt }, // checksum
    };
    for (variants) |v| {
        @memcpy(bad[0..blob.len], blob);
        bad[v.at] ^= 0x41;
        try expectError(v.err, snap.decode(bad[0..blob.len], b));
    }
    // Damage in the payload: refused, or (a flipped offset inside a run of
    // zeros) decodes to the very same image.
    var refused: usize = 0;
    var p: usize = snap.header_len;
    while (p < blob.len) : (p += 5) {
        @memcpy(bad[0..blob.len], blob);
        bad[p] ^= 0x41;
        if (snap.decode(bad[0..blob.len], b)) {
            try expect_same(g, b, "damaged but decoded");
        } else |e| {
            try expectEqual(error.Corrupt, e);
            refused += 1;
        }
    }
    try expect(refused > 0);
    try expectEqual(snap.Check.old_version, blob_check_with_layout(blob, snap.layout +% 1));
    try expectError(error.Corrupt, snap.decode(blob[0 .. blob.len - 1], b));
    try expectError(error.Corrupt, snap.decode(blob[0..10], b));
}

fn blob_check_with_layout(blob: []const u8, layout: u32) snap.Check {
    var tmp: [snap.header_len]u8 = undefined;
    @memcpy(&tmp, blob[0..snap.header_len]);
    std.mem.writeInt(u32, tmp[8..12], layout, .little);
    return snap.check_header(&tmp);
}

test "saved game: canonicalize is idempotent and the blob is stable" {
    const g = &games[0];
    game.init(g, 11);
    game.advance_ms(g, 90_000);
    const a = try snap.encode(g, &blob_buf);
    var first: [snap.max_blob]u8 = undefined;
    @memcpy(first[0..a.len], a);
    const b = try snap.encode(g, &blob_buf);
    try expect(std.mem.eql(u8, first[0..a.len], b));
}

// ---- the round trip through a whole game ----

const Point = enum { skirmish, minute, projects, hypno, stage2, space, battle, flock, observed_battle };

/// Save at `pt`, load into a fresh Game, run the original, the loaded and
/// an only-canonicalized copy on for `run_ms` with the same bot, compare.
fn round_trip(a: *Game, bot: *const Bot, pt: Point, run_ms: u64) !usize {
    const loaded = &games[1];
    const plain = &games[2];
    copy(plain, a); // never saved
    @memset(std.mem.asBytes(loaded), 0xA5);
    const blob = try snap.encode(a, &blob_buf);
    const size = blob.len;
    try snap.decode(blob, loaded);
    try expect_same(a, loaded, @tagName(pt));
    // The untouched copy, canonicalized, is the same state.
    const plain_canon = &games[3];
    copy(plain_canon, plain);
    snap.canonicalize(plain_canon);
    try expect_same(a, plain_canon, "canonical");

    var bots = [3]Bot{ bot.*, bot.*, bot.* };
    const runs = [3]*Game{ a, loaded, plain };
    const end = a.now_ms + run_ms;
    for (runs, &bots) |g, *b| {
        while (g.now_ms < end) {
            game.advance_ms(g, 100);
            b.step(g);
        }
    }
    try expect_same(a, loaded, "after the run (loaded)");
    // The never-saved run kept its dead bytes: compare it canonicalized.
    snap.canonicalize(a);
    snap.canonicalize(plain);
    try expect_same(a, plain, "after the run (never saved)");
    return size;
}

test "saved game: load continues bit for bit, early to stage 3" {
    const a = &games[0];
    game.init(a, 2026);
    var bot = Bot{};
    var done: std.EnumSet(Point) = .empty;
    var sizes: [@typeInfo(Point).@"enum".field_names.len]usize = @splat(0);
    var observed_from: u64 = 0;
    while (a.now_ms < 16 * 3600 * 1000 and done.count() < sizes.len) {
        game.advance_ms(a, 100);
        bot.step(a);
        const t = a.now_ms;
        const live = a.num_left_ships > 0 and a.num_right_ships > 0;
        const pt: ?Point = if (!done.contains(.skirmish) and t >= 1000)
            .skirmish
        else if (!done.contains(.minute) and t >= 60_000)
            .minute
        else if (!done.contains(.projects) and a.active_len >= 4 and t >= 600_000)
            .projects
        else if (!done.contains(.hypno) and a.human_flag == 0)
            .hypno
        else if (!done.contains(.stage2) and done.contains(.hypno) and a.space_flag == 0 and a.factory_level >= 1)
            .stage2
        else if (!done.contains(.space) and a.space_flag == 1)
            .space
        else if (!done.contains(.battle) and a.battles_len > 0 and live)
            .battle
        else if (!done.contains(.flock) and done.contains(.battle) and a.battle_flag == 1 and !live)
            .flock
        else if (!done.contains(.observed_battle) and observed_from != 0 and t >= observed_from + 30_000 and live)
            .observed_battle
        else
            null;
        if (pt) |p| {
            if (p == .skirmish) try expect(live); // the opening battle is still on
            if (p == .flock) {
                // From here the COMBAT page is on screen: the flock moves.
                a.ships_observed = true;
                observed_from = t;
            }
            sizes[@backingInt(p)] = try round_trip(a, &bot, p, if (p == .skirmish) 3000 else 20_000);
            done.insert(p);
        }
    }
    std.debug.print("\nsaved game sizes (seed 2026, bytes): ", .{});
    for (sizes, 0..) |s, i| std.debug.print("{s} {d}  ", .{ @typeInfo(Point).@"enum".field_names[i], s });
    std.debug.print("(image {d}, layout {x})\n", .{ snap.image_len, snap.layout });
    try expectEqual(sizes.len, done.count());
}

test "saved game: the biggest real save (a live 200 vs 200 battle, a full log) fits the cart's 22 KB" {
    const a = &games[0];
    game.init(a, 77);
    game.prepare.prepare(a, 3);
    // A battle that has just started: all 400 ships alive.
    a.battle_left_ships = 200;
    a.battle_right_ships = 200;
    game.combat.battle_restart(a);
    try expectEqual(@as(u16, 400), a.num_ships);
    // Fill the log: 64 long, varied messages.
    var line: [80]u8 = undefined;
    for (0..64) |i| {
        const t = std.fmt.bufPrint(&line, "Drifter attack {d}: probes lost {d}, honor {d} of {d}", .{ i * 7919, i * 104729, i % 13, a.now_ms }) catch unreachable;
        a.display_message(t);
    }
    const blob = try snap.encode(a, &blob_buf);
    std.debug.print("\nbiggest save: {d} bytes ({d} ships, {d} messages)\n", .{ blob.len, a.num_ships, a.msg_len });
    try expect(blob.len <= 22 * 1024 - 2048);
    _ = try round_trip(a, &Bot{}, .battle, 5_000);
}

test "saved game: the ending and a new universe" {
    const a = &games[0];
    game.init(a, 77);
    game.prepare.prepare(a, 3);
    var bot = Bot{};
    _ = try round_trip(a, &bot, .space, 10_000);
    // Prestige carried by a new game.
    a.prestige_u = 2;
    a.prestige_s = 1;
    a.has_save_prestige = true;
    const blob = try snap.encode(a, &blob_buf);
    const b = &games[1];
    try snap.decode(blob, b);
    game.init_with_prestige(b, 9, b.prestige_u, b.prestige_s);
    try expectEqual(@as(f64, 2), b.prestige_u);
    try expect(b.has_save_prestige and b.human_flag == 1 and b.clips == 0);
}
