//! Word wrap for the log and the prompt box (no cart API; host tested).
const std = @import("std");

/// The start/end of one wrapped line inside the source string.
pub const Span = struct { start: u16, end: u16 };

/// Word wrap: each line at most `width` characters, broken at spaces (a
/// word longer than a line is cut). Returns the number of lines; only the
/// first `out.len` are stored.
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

/// A printed line made fit for the narrow screen: runs of spaces (the
/// listing's TAB() and print zones) become one space; `lead` is how many
/// spaces the line started with.
pub const Squeezed = struct { text: []const u8, lead: usize };

pub fn squeeze(src: []const u8, buf: []u8) Squeezed {
    var lead: usize = 0;
    while (lead < src.len and src[lead] == ' ') lead += 1;
    var n: usize = 0;
    var space = false;
    for (src[lead..]) |c0| {
        const c = if (c0 == '\t') ' ' else c0;
        if (c == ' ') {
            space = true;
            continue;
        }
        if (space and n > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return .{ .text = buf[0..n], .lead = lead };
}

/// Decimal digits of `v` (v >= 0), at least 1.
pub fn digits(v: i32) u8 {
    var n: u8 = 1;
    var x = @max(v, 0);
    while (x >= 10) : (x = @divTrunc(x, 10)) n += 1;
    return n;
}

test "wrap" {
    var spans: [8]Span = undefined;
    const s = "THIS PROGRAM SIMULATES A TRIP OVER THE OREGON TRAIL FROM";
    const n = wrap(s, 26, &spans);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("THIS PROGRAM SIMULATES A", s[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("TRIP OVER THE OREGON TRAIL", s[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("FROM", s[spans[2].start..spans[2].end]);
    // A word longer than the line is cut.
    try std.testing.expectEqual(@as(usize, 2), wrap("abcdefghij", 6, &spans));
    // Exactly the width: one line.
    try std.testing.expectEqual(@as(usize, 1), wrap("abcdef", 6, &spans));
    try std.testing.expectEqual(@as(usize, 0), wrap("   ", 6, &spans));
}

test "squeeze" {
    var buf: [64]u8 = undefined;
    const a = squeeze("            THE MORE YOU SPEND,  THE FASTER", &buf);
    try std.testing.expectEqualStrings("THE MORE YOU SPEND, THE FASTER", a.text);
    try std.testing.expectEqual(@as(usize, 12), a.lead);
    const b = squeeze("RIDERS AHEAD.  THEY DON'T LOOK HOSTILE ", &buf);
    try std.testing.expectEqualStrings("RIDERS AHEAD. THEY DON'T LOOK HOSTILE", b.text);
    try std.testing.expectEqual(@as(usize, 0), b.lead);
}

test "digits" {
    try std.testing.expectEqual(@as(u8, 1), digits(0));
    try std.testing.expectEqual(@as(u8, 3), digits(300));
    try std.testing.expectEqual(@as(u8, 4), digits(1000));
}
