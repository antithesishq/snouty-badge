//! A per-frame text arena: page builders format their numbers into it and
//! rows hold slices of it until the frame is drawn. Reset every frame.
const std = @import("std");

pub const Arena = struct {
    buf: [6144]u8 = undefined,
    n: usize = 0,

    pub fn reset(a: *Arena) void {
        a.n = 0;
    }

    /// Free space to format into; `commit` keeps `len` bytes of it.
    pub fn scratch(a: *Arena) []u8 {
        return a.buf[a.n..];
    }

    /// Concatenates the parts (each may already live in the arena's
    /// scratch space: they are copied in order into a fresh slice).
    pub fn join(a: *Arena, parts: []const []const u8) []const u8 {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        if (a.n + total > a.buf.len) return "";
        // Parts may live in the arena's free space (formatted there and
        // not kept), right where the result goes: then build the result
        // past the end of all of them and slide it back.
        var hi: usize = a.n;
        const base = @intFromPtr(&a.buf[0]);
        for (parts) |p| {
            const at = @intFromPtr(p.ptr);
            if (p.len > 0 and at >= base + a.n and at < base + a.buf.len) hi = @max(hi, at - base + p.len);
        }
        if (hi + total > a.buf.len) return "";
        var t: usize = hi;
        for (parts) |p| {
            for (p, 0..) |ch, k| a.buf[t + k] = ch;
            t += p.len;
        }
        if (hi != a.n) std.mem.copyForwards(u8, a.buf[a.n .. a.n + total], a.buf[hi .. hi + total]);
        const s = a.buf[a.n .. a.n + total];
        a.n += total;
        return s;
    }

    /// Keeps a string formatted into `scratch()` (returns it, now owned).
    pub fn keep(a: *Arena, s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const base = @intFromPtr(&a.buf[a.n]);
        if (@intFromPtr(s.ptr) == base) {
            a.n += s.len;
            return a.buf[a.n - s.len .. a.n];
        }
        return a.join(&.{s});
    }
};

/// Word wrap: the start/end of each line of at most `width` characters.
/// Returns the number of lines written to `out` (more lines are counted
/// but not stored).
pub const Span = struct { start: u16, end: u16 };

pub fn wrap(s: []const u8, width: usize, out: []Span) usize {
    var lines: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len) break;
        var end = @min(s.len, i + width);
        if (end < s.len and s[end] != ' ') {
            // Break at the last space inside the line, if any.
            var k = end;
            while (k > i and s[k - 1] != ' ') k -= 1;
            if (k > i) end = k;
        }
        var e = end;
        while (e > i and s[e - 1] == ' ') e -= 1;
        if (lines < out.len) out[lines] = .{ .start = @intCast(i), .end = @intCast(e) };
        lines += 1;
        i = end;
    }
    return lines;
}

test "wrap" {
    var spans: [8]Span = undefined;
    const s = "Admit failure, ask for budget increase to cover cost of 1 spool";
    const n = wrap(s, 26, &spans);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("Admit failure, ask for", s[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("budget increase to cover", s[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("cost of 1 spool", s[spans[2].start..spans[2].end]);
    // A word longer than the line is cut.
    try std.testing.expectEqual(@as(usize, 2), wrap("abcdefghij", 6, &spans));
}

test "join" {
    var a: Arena = .{};
    const x = a.join(&.{ "Funds ", "$1.00" });
    const y = a.join(&.{ "a", "b" });
    try std.testing.expectEqualStrings("Funds $1.00", x);
    try std.testing.expectEqualStrings("ab", y);
}
