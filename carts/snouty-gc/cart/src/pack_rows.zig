//! The track and arena rows the menus cycle through (M7, SPEC 19.2): the
//! built-in tracks (`track.tracks`) then each drive pack's tracks, and The
//! Sandbox then each pack's arena. New for Snouty GCP. No cart API (the
//! select, BATTLE's setup, the LINK lobby and main.zig read it; host-tested
//! in pack_test.zig).
//!
//! A pack still being checked, or refused, takes one race row of its own
//! that shows its file name and why (`note`) and cannot be raced
//! (`race_track` is null). Arena rows list only packs that can be raced.
//! Asking for a pack row's track loads it (pack.zig: a few ms of
//! unpacking), so the select's panel and the setup's floor show it.
const std = @import("std");
const track = @import("track.zig");
const pack = @import("pack.zig");
const fmt = @import("pack_format.zig");
const net = @import("net.zig");

pub const Row = union(enum) {
    builtin: u8,
    /// Pack `p`'s track `k` (race tracks 0.., the arena at its track_n).
    pack: struct { p: u8, k: u8 },
    /// Pack `p` cannot be raced (yet): `pack.packs[p].status`.
    refused: u8,
};

const n_builtin: u8 = track.tracks.len;
const n_arenas: u8 = track.arenas.len;

/// Race rows: the built-in tracks, then per pack its tracks (or one row).
pub fn race_count() u8 {
    var n: u8 = n_builtin;
    for (pack.packs[0..pack.count]) |*p| n += if (p.ok()) p.track_n else 1;
    return n;
}

pub fn race_row(i: u8) Row {
    if (i < n_builtin) return .{ .builtin = i };
    var at: u8 = n_builtin;
    for (pack.packs[0..pack.count], 0..) |*p, pi| {
        const n: u8 = if (p.ok()) p.track_n else 1;
        if (i < at + n) return if (p.ok()) .{ .pack = .{ .p = @intCast(pi), .k = i - at } } else .{ .refused = @intCast(pi) };
        at += n;
    }
    return .{ .builtin = 0 };
}

/// Arena rows: The Sandbox, then each raceable pack's arena.
pub fn arena_count() u8 {
    var n: u8 = n_arenas;
    for (pack.packs[0..pack.count]) |*p| n += @intFromBool(p.ok() and p.arena_n > 0);
    return n;
}

pub fn arena_row(i: u8) Row {
    if (i < n_arenas) return .{ .builtin = i };
    var at: u8 = n_arenas;
    for (pack.packs[0..pack.count], 0..) |*p, pi| {
        if (!(p.ok() and p.arena_n > 0)) continue;
        if (i == at) return .{ .pack = .{ .p = @intCast(pi), .k = p.track_n } };
        at += 1;
    }
    return .{ .builtin = 0 };
}

/// Load pack `p`'s track `k` unless it is in the slots already.
pub fn ensure(p: u8, k: u8) bool {
    if (pack.loaded) |l| {
        if (l.pack == p and l.k == k and track.map_owner == &track.pack_track and track.art_league == &track.pack_league) return true;
    }
    return pack.load(p, k) == .ok;
}

/// The track of a row (loading a pack's), null for a pack that cannot be
/// raced (it may just have been refused by the load).
pub fn track_of(r: Row, battle: bool) ?*const track.Track {
    return switch (r) {
        .builtin => |b| if (battle) track.arenas[b % n_arenas] else track.tracks[b % n_builtin],
        .pack => |q| if (ensure(q.p, q.k)) &track.pack_track else null,
        .refused => null,
    };
}

/// `Setup.track` for a row (a pack's is `track.pack_base + k`; the pack
/// itself is whatever `ensure` loaded).
pub fn setup_track(r: Row) u8 {
    return switch (r) {
        .builtin => |b| b,
        .pack => |q| track.pack_base + q.k,
        .refused => 0,
    };
}

/// A refused row's file name (`NAME.GCP`).
pub fn note(r: Row) []const u8 {
    return switch (r) {
        .refused => |p| pack.packs[p].file_name(),
        else => "",
    };
}

/// Why a refused row cannot be raced.
pub fn reason(r: Row) []const u8 {
    return switch (r) {
        .refused => |p| pack.packs[p].status.text(),
        else => "",
    };
}

// --- The link (net.Rules carry `track` and the pack's id) -------------------

/// The pack id and track byte of row `r` for the link rules.
pub const Pick = struct { track: u8, pack: u32 };
pub fn link_pick(r: Row) Pick {
    return switch (r) {
        .builtin => |b| .{ .track = b, .pack = 0 },
        .pack => |q| .{ .track = track.pack_base + q.k, .pack = pack.packs[q.p].id },
        .refused => .{ .track = 0, .pack = 0 },
    };
}

/// The row a link rules' track and pack name on this badge (null: a pack
/// this drive lacks).
pub fn row_of(battle: bool, t: u8, id: u32) ?Row {
    if (t < track.pack_base) return .{ .builtin = t };
    const p = pack.find_id(id) orelse return null;
    const k = t - track.pack_base;
    const ps = &pack.packs[p];
    if (battle) {
        if (ps.arena_n == 0 or k != ps.track_n) return null;
    } else if (k >= ps.track_n) return null;
    return .{ .pack = .{ .p = p, .k = k } };
}

/// The index of row `r` in the race or arena rows (for the lobby's cursor).
pub fn index_of(battle: bool, r: Row) u8 {
    const n = if (battle) arena_count() else race_count();
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const x = if (battle) arena_row(i) else race_row(i);
        if (same(x, r)) return i;
    }
    return 0;
}

fn same(a: Row, b: Row) bool {
    return switch (a) {
        .builtin => |x| b == .builtin and b.builtin == x,
        .pack => |x| b == .pack and b.pack.p == x.p and b.pack.k == x.k,
        .refused => |x| b == .refused and b.refused == x,
    };
}

/// The name of the track a link rules name, if this badge has it.
pub fn place_name(battle: bool, t: u8, id: u32) []const u8 {
    const r = row_of(battle, t, id) orelse return "PARTNER'S PACK";
    return switch (r) {
        .builtin => |b| if (battle) track.arenas[b % n_arenas].name else track.tracks[b % n_builtin].name,
        .pack => |q| blk: {
            if (pack.loaded) |l| if (l.pack == q.p and l.k == q.k) break :blk track.pack_track.name;
            break :blk pack.packs[q.p].league[0..fmt.name_len];
        },
        .refused => "",
    };
}

/// Host, the LINK lobby's track row: Left / Right through the race or
/// arena rows, skipping packs that cannot be raced; sets `track` and
/// `pack`.
pub fn cycle(rules: *net.Rules, step: i32) void {
    const battle = rules.mode == .battle;
    const n: i32 = if (battle) arena_count() else race_count();
    const here = row_of(battle, rules.track, rules.pack) orelse Row{ .builtin = 0 };
    var i: i32 = index_of(battle, here);
    var tries: i32 = 0;
    var r: Row = here;
    while (tries < n) : (tries += 1) {
        i = @mod(i + step, n);
        r = if (battle) arena_row(@intCast(i)) else race_row(@intCast(i));
        if (r != .refused) break;
    }
    const pk = link_pick(r);
    rules.track = pk.track;
    rules.pack = pk.pack;
}

/// `net.Net.has`: this badge has the pack the rules name and loads it
/// (cached after the first time, so it is cheap every frame).
pub fn has_rules(rules: net.Rules) bool {
    const battle = rules.mode == .battle;
    const r = row_of(battle, rules.track, rules.pack) orelse return false;
    return switch (r) {
        .pack => |q| ensure(q.p, q.k),
        else => true,
    };
}
