//! The saved game: the whole `Game` as one compact, versioned blob (the
//! cart stores it as `paperclips/game`, ui/saves.zig).
//!
//! The original's save() (main.js) writes ~250 globals, the projects'
//! uses/flags, the active list and the strategies to localStorage, and its
//! load() rebuilds the rest (the canvas battle starts over, the timers are
//! registered anew). The port keeps more state than that list (timer
//! phases, the message log, the live battle's ships, the RNG), so instead
//! of a field list this saves the `Game` struct's bytes: every field the
//! port has, nothing to forget, and a load continues bit for bit where the
//! save left off.
//!
//! Blob = 20-byte header + LZ-compressed image:
//!
//! | off | size | field |
//! |----:|----:|---|
//! | 0 | 4 | magic "UPCS" |
//! | 4 | 2 | format version (`version`) |
//! | 6 | 2 | 0 |
//! | 8 | 4 | `layout`: a hash of `Game`'s layout (every field's name, offset, size and type, recursively) |
//! | 12 | 4 | image length = `@sizeOf(Game)` |
//! | 16 | 4 | FNV-1a 32 of the image |
//!
//! A blob whose version, layout or length differs from this build's is
//! refused (`error.OldVersion`): any change to `Game` changes the layout
//! hash, so a save is never read into fields it was not written from. The
//! layout includes the target (pointer size, alignment), so a host save
//! does not load on the badge either.
//!
//! Dead state is zeroed before the image is taken (`canonicalize`): bytes
//! nothing reads before writing them again. That is what makes the image
//! small, and it is exact by construction (tests.zig "saved game ..." runs
//! a canonicalized copy against an untouched one):
//!
//! - `timers` past `timers_len`; `msg_buf` bytes outside the live entries
//!   and `msg_entries` slots outside the ring.
//! - The battle ships when nothing can read them: no live battle (one side
//!   gone, so no dice) and `battle_flag == 0` (the COMBAT canvas has never
//!   shown; the next battle's `battle_restart` rewrites them before any
//!   read). That is the opening skirmish's leftovers through stages 1 and 2.
//! - Otherwise ships past `num_ships`, `gx`/`gy` of every ship (update_grid
//!   writes them before each read), and the position and speed of a ship
//!   whose explosion is over (dead, `frames_dead == 10`: never drawn or
//!   moved again).
//!
//! The compressor is a small LZ77 (byte tokens, 16-bit offsets): runs of
//! zeros and repeated defaults shrink to a few bytes, the live numbers and
//! the log text stay mostly as they are. Sizes in PLAN.md "Saves".
const std = @import("std");
const game = @import("game.zig");
const combat = @import("combat.zig");
const Game = game.Game;

pub const magic: u32 = 0x53435055; // "UPCS" little endian
/// Bump when the blob format (not `Game`) changes.
pub const version: u16 = 1;
pub const header_len = 20;
pub const image_len = @sizeOf(Game);

/// The layout hash of this build's `Game` (comptime).
pub const layout: u32 = layout_hash();

/// The largest blob `encode` may produce: the header plus the whole image
/// incompressible (one literal token per 128 bytes, a byte more for the
/// odd accidental 3-byte match). Real saves are far smaller: 1-4 KB, the
/// opening skirmish's 400 live ships ~12 KB.
pub const max_blob = header_len + image_len + image_len / 64;

pub const Error = error{
    /// Not a saved game (wrong magic) or truncated / inconsistent data.
    Corrupt,
    /// Written by a different build of the port (version, layout, size).
    OldVersion,
    /// The output buffer is too small.
    NoRoom,
};

/// Zero the dead state (see the top of this file). Idempotent; changes
/// nothing the game will ever read.
pub fn canonicalize(g: *Game) void {
    // Timers past the live ones.
    const tl = @min(g.timers_len, g.timers.len);
    @memset(std.mem.sliceAsBytes(g.timers[tl..]), 0);

    // Messages: keep the ring's entries and their text, zero the rest.
    var live_bytes: [g.msg_buf.len / 8]u8 = @splat(0); // one bit per byte of msg_buf
    var live_slots: u64 = 0;
    const n_entries = g.msg_entries.len;
    var k: usize = 0;
    while (k < g.msg_len and k < n_entries) : (k += 1) {
        const idx = (g.msg_first + k) % n_entries;
        live_slots |= @as(u64, 1) << @intCast(idx);
        const e = g.msg_entries[idx];
        var b: usize = e.start;
        const end = @min(@as(usize, e.start) + e.len, g.msg_buf.len);
        while (b < end) : (b += 1) live_bytes[b >> 3] |= @as(u8, 1) << @intCast(b & 7);
    }
    for (&g.msg_buf, 0..) |*c, i| {
        if (live_bytes[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) == 0) c.* = 0;
    }
    for (&g.msg_entries, 0..) |*e, i| {
        if (live_slots & (@as(u64, 1) << @intCast(i)) == 0) e.* = .{ .start = 0, .len = 0 };
    }

    // Ships.
    if (!ships_live(g)) {
        @memset(std.mem.sliceAsBytes(g.ships[0..]), 0);
        return;
    }
    const n = @min(g.num_ships, g.ships.len);
    @memset(std.mem.sliceAsBytes(g.ships[n..]), 0);
    for (g.ships[0..n]) |*s| {
        s.gx = 0;
        s.gy = 0;
        if (!s.alive and s.frames_dead >= 10) {
            s.x = 0;
            s.y = 0;
            s.vx = 0;
            s.vy = 0;
        }
    }
}

/// Whether anything can still read the ships: a live battle (both sides
/// have ships, so the dice roll) or a game in space whose COMBAT canvas
/// shows them (`battle_flag`).
pub fn ships_live(g: *const Game) bool {
    if (g.battle_flag != 0) return true;
    return g.num_left_ships > 0 and g.num_right_ships > 0;
}

/// Write `g` as a saved game into `out`; returns the blob's length.
/// Canonicalizes `g` first (no visible change).
pub fn encode(g: *Game, out: []u8) Error![]const u8 {
    canonicalize(g);
    if (out.len < header_len) return error.NoRoom;
    const img = std.mem.asBytes(g);
    const n = try compress(img, out[header_len..]);
    std.mem.writeInt(u32, out[0..4], magic, .little);
    std.mem.writeInt(u16, out[4..6], version, .little);
    std.mem.writeInt(u16, out[6..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], layout, .little);
    std.mem.writeInt(u32, out[12..16], image_len, .little);
    std.mem.writeInt(u32, out[16..20], fnv1a(img), .little);
    return out[0 .. header_len + n];
}

/// What a blob's header says, without decoding it.
pub const Check = enum { ok, corrupt, old_version };

pub fn check_header(blob: []const u8) Check {
    if (blob.len < header_len) return .corrupt;
    if (std.mem.readInt(u32, blob[0..4], .little) != magic) return .corrupt;
    if (std.mem.readInt(u16, blob[4..6], .little) != version) return .old_version;
    if (std.mem.readInt(u32, blob[8..12], .little) != layout) return .old_version;
    if (std.mem.readInt(u32, blob[12..16], .little) != image_len) return .old_version;
    return .ok;
}

/// Load a saved game into `g`. On an error `g` holds garbage: start a new
/// game into it (`game.init`).
pub fn decode(blob: []const u8, g: *Game) Error!void {
    switch (check_header(blob)) {
        .ok => {},
        .corrupt => return error.Corrupt,
        .old_version => return error.OldVersion,
    }
    const img = std.mem.asBytes(g);
    try decompress(blob[header_len..], img);
    if (fnv1a(img) != std.mem.readInt(u32, blob[16..20], .little)) return error.Corrupt;
    // Cheap sanity on the counts the game indexes with.
    if (g.timers_len > g.timers.len or g.msg_len > g.msg_entries.len or g.num_ships > g.ships.len) return error.Corrupt;
}

// ---- layout hash ----

fn layout_hash() u32 {
    @setEvalBranchQuota(400_000);
    var h: u32 = fnv_basis;
    h = mix_int(h, version);
    h = mix_type(h, Game);
    return h;
}

fn mix_type(h0: u32, comptime T: type) u32 {
    var h = mix_int(h0, @sizeOf(T));
    h = mix_int(h, @alignOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names, s.field_types) |name, FT| {
                h = mix_bytes(h, name);
                h = mix_int(h, @offsetOf(T, name));
                h = mix_type(h, FT);
            }
        },
        .array => |a| {
            h = mix_int(h, a.len);
            h = mix_type(h, a.child);
        },
        .@"enum" => |e| {
            h = mix_type(h, e.tag_type);
            inline for (e.field_names, e.field_values) |name, v| {
                h = mix_bytes(h, name);
                h = mix_int(h, v);
            }
        },
        .int, .float, .bool => h = mix_bytes(h, @typeName(T)),
        else => @compileError("snapshot: no layout rule for " ++ @typeName(T)),
    }
    return h;
}

const fnv_basis: u32 = 0x811c9dc5;
const fnv_prime: u32 = 0x01000193;

fn mix_bytes(h0: u32, bytes: []const u8) u32 {
    var h = h0;
    for (bytes) |c| {
        h ^= c;
        h *%= fnv_prime;
    }
    return h ^ 0xff; // separator
}

fn mix_int(h: u32, v: u64) u32 {
    const b: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, v));
    return mix_bytes(h, &b);
}

pub fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = fnv_basis;
    for (bytes) |c| {
        h ^= c;
        h *%= fnv_prime;
    }
    return h;
}

// ---- LZ77 ----
//
// Tokens: 0x00..0x7F = a run of (t + 1) literal bytes follows; 0x80..0xFF
// = a match of (t & 0x7F) + 3 bytes, and when that is 130 the length goes
// on in bytes (each adds itself; 255 means another follows), then the
// offset back (1..65535, u16 little endian). Matches may overlap their
// output (offset 1 repeats a byte).

const min_match = 3;
const max_lit = 128;
const hash_bits = 11;

fn hash3(p: []const u8) usize {
    const v = @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16;
    return (v *% 2654435761) >> (32 - hash_bits);
}

/// Compress `src` into `dst`; returns the length written.
pub fn compress(src: []const u8, dst: []u8) Error!usize {
    std.debug.assert(src.len < 0xFFFF); // positions + 1 fit the u16 table
    // Position + 1 of the last occurrence of each 3-byte hash (0 = none).
    var table: [1 << hash_bits]u16 = @splat(0);
    var o: usize = 0;
    var lit: usize = 0; // start of the pending literals
    var i: usize = 0;
    while (i + min_match <= src.len) {
        const h = hash3(src[i..]);
        const cand = table[h];
        table[h] = @intCast(i + 1);
        if (cand != 0) {
            const c = cand - 1;
            const off = i - c;
            if (off <= 0xFFFF and src[c] == src[i] and src[c + 1] == src[i + 1] and src[c + 2] == src[i + 2]) {
                var len: usize = min_match;
                while (i + len < src.len and src[c + len] == src[i + len]) len += 1;
                o = try put_literals(dst, o, src[lit..i]);
                o = try put_match(dst, o, len, off);
                // Keep the table fresh across a short match.
                if (len < 16) {
                    var j = i + 1;
                    while (j < i + len and j + min_match <= src.len) : (j += 1) table[hash3(src[j..])] = @intCast(j + 1);
                }
                i += len;
                lit = i;
                continue;
            }
        }
        i += 1;
    }
    return put_literals(dst, o, src[lit..]);
}

fn put_literals(dst: []u8, o0: usize, bytes: []const u8) Error!usize {
    var o = o0;
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, max_lit);
        if (o + 1 + n > dst.len) return error.NoRoom;
        dst[o] = @intCast(n - 1);
        @memcpy(dst[o + 1 ..][0..n], rest[0..n]);
        o += 1 + n;
        rest = rest[n..];
    }
    return o;
}

fn put_match(dst: []u8, o0: usize, len: usize, off: usize) Error!usize {
    var o = o0;
    const code = len - min_match;
    if (o + 1 > dst.len) return error.NoRoom;
    if (code < 127) {
        dst[o] = 0x80 | @as(u8, @intCast(code));
        o += 1;
    } else {
        dst[o] = 0xFF;
        o += 1;
        var rest = code - 127;
        while (true) {
            if (o + 1 > dst.len) return error.NoRoom;
            const b: u8 = @intCast(@min(rest, 255));
            dst[o] = b;
            o += 1;
            if (b < 255) break;
            rest -= 255;
        }
    }
    if (o + 2 > dst.len) return error.NoRoom;
    std.mem.writeInt(u16, dst[o..][0..2], @intCast(off), .little);
    return o + 2;
}

/// Decompress `src` into exactly `dst.len` bytes.
pub fn decompress(src: []const u8, dst: []u8) Error!void {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const t = src[i];
        i += 1;
        if (t < 0x80) {
            const n = @as(usize, t) + 1;
            if (i + n > src.len or o + n > dst.len) return error.Corrupt;
            @memcpy(dst[o..][0..n], src[i..][0..n]);
            i += n;
            o += n;
            continue;
        }
        var len: usize = @as(usize, t & 0x7F) + min_match;
        if (t == 0xFF) {
            while (true) {
                if (i >= src.len) return error.Corrupt;
                const b = src[i];
                i += 1;
                len += b;
                if (b < 255) break;
            }
        }
        if (i + 2 > src.len) return error.Corrupt;
        const off: usize = std.mem.readInt(u16, src[i..][0..2], .little);
        i += 2;
        if (off == 0 or off > o or o + len > dst.len) return error.Corrupt;
        var k: usize = 0;
        while (k < len) : (k += 1) dst[o + k] = dst[o + k - off];
        o += len;
    }
    if (o != dst.len) return error.Corrupt;
}
