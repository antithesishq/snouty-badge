//! The log: every wrapped row the game printed, plus the player's answers,
//! in a ring of `cap` rows (no cart API; host tested). The game screen
//! shows its tail; Select shows all of it (SPEC 4.2).
//!
//! Rows are copied out of the game's line buffer (which `answer` reuses).
//! An empty printed line is a paragraph break: it becomes a short gap row,
//! but only once text follows it (no gaps doubled, none at the end).
const std = @import("std");
const font = @import("font.zig");
const text = @import("text.zig");

pub const cols = font.cols;
pub const cap = 256;

pub const Kind = enum(u8) {
    text,
    /// A paragraph break.
    gap,
    /// A divider where a new turn's date was printed: the date, small,
    /// between two dashed lines (the HUD shows the current date).
    rule,
};

pub const Style = enum(u8) {
    ink,
    /// Warnings, deaths: raspberry.
    warn,
    /// The player's answers ("> HUNT").
    answer,
    /// Good news: leaf green.
    good,
};

/// Row heights in pixels.
pub const text_h: i32 = 9;
pub const gap_h: i32 = 4;
pub const rule_h: i32 = 10;

pub const Row = struct {
    kind: Kind = .text,
    style: Style = .ink,
    /// Left inset in pixels (indented or centred lines).
    x: u8 = 0,
    len: u8 = 0,
    buf: [cols]u8 = undefined,

    pub fn str(r: *const Row) []const u8 {
        return r.buf[0..r.len];
    }

    pub fn height(r: *const Row) i32 {
        return switch (r.kind) {
            .text => text_h,
            .gap => gap_h,
            .rule => rule_h,
        };
    }
};

/// `.hang`: the first row at the margin, the rest two columns in (a
/// paragraph whose printed lines were indented after the first, like the
/// instructions' item list). `.center`: each row centred (the letters'
/// signatures).
pub const Align = enum { left, hang, center };

pub const Log = struct {
    rows: [cap]Row = undefined,
    /// Rows ever appended: row i lives at rows[i % cap] while i >= oldest().
    total: u32 = 0,
    /// A paragraph break is waiting for the next text row.
    gap_pending: bool = false,

    pub fn reset(l: *Log) void {
        l.total = 0;
        l.gap_pending = false;
    }

    pub fn oldest(l: *const Log) u32 {
        return l.total -| cap;
    }

    pub fn get(l: *const Log, i: u32) *const Row {
        return &l.rows[i % cap];
    }

    fn append(l: *Log, r: Row) void {
        l.rows[l.total % cap] = r;
        l.total += 1;
    }

    fn last_kind(l: *const Log) ?Kind {
        if (l.total == 0) return null;
        return l.get(l.total - 1).kind;
    }

    pub fn gap(l: *Log) void {
        if (l.total > 0) l.gap_pending = true;
    }

    /// A turn divider labelled `label` (replaces a pending paragraph break).
    pub fn rule(l: *Log, label: []const u8) void {
        l.gap_pending = false;
        if (l.last_kind() == .gap) l.total -= 1;
        var r: Row = .{ .kind = .rule };
        var buf: [64]u8 = undefined;
        const sq = text.squeeze(label, &buf);
        r.len = @intCast(@min(sq.text.len, cols));
        @memcpy(r.buf[0..r.len], sq.text[0..r.len]);
        l.append(r);
    }

    fn flush_gap(l: *Log) void {
        if (!l.gap_pending) return;
        l.gap_pending = false;
        if (l.last_kind()) |k| if (k == .text) l.append(.{ .kind = .gap });
    }

    /// Appends a printed line (or a paragraph of them), word-wrapped at
    /// 26 columns, runs of spaces squeezed. Returns the number of rows added.
    pub fn line(l: *Log, src: []const u8, style: Style, al: Align) u32 {
        var buf: [512]u8 = undefined;
        const sq = text.squeeze(src, &buf);
        if (sq.text.len == 0) {
            l.gap();
            return 0;
        }
        l.flush_gap();
        var spans: [24]text.Span = undefined;
        var n: usize = 0;
        if (al == .hang) {
            // The first row at full width, the rest two columns narrower.
            var first: [1]text.Span = undefined;
            _ = text.wrap(sq.text, cols, &first);
            spans[0] = first[0];
            const rest_at: usize = first[0].end;
            const m = @min(text.wrap(sq.text[rest_at..], cols - 2, spans[1..]), spans.len - 1);
            for (spans[1 .. 1 + m]) |*sp| {
                sp.start += @intCast(rest_at);
                sp.end += @intCast(rest_at);
            }
            n = 1 + m;
        } else {
            n = @min(text.wrap(sq.text, cols, &spans), spans.len);
        }
        for (spans[0..n], 0..) |sp, k| {
            var r: Row = .{ .style = style };
            const s = sq.text[sp.start..sp.end];
            r.len = @intCast(@min(s.len, cols));
            @memcpy(r.buf[0..r.len], s[0..r.len]);
            switch (al) {
                .left => {},
                .hang => if (k > 0) {
                    r.x = 2 * font.cell_w;
                },
                .center => r.x = @intCast(@max(0, @divTrunc(160 - 4 - font.width(r.len), 2))),
            }
            l.append(r);
        }
        return @intCast(n);
    }

    /// Pixel height of rows [from, to).
    pub fn height(l: *const Log, from: u32, to: u32) i32 {
        var h: i32 = 0;
        var i = @max(from, l.oldest());
        while (i < to) : (i += 1) h += l.get(i).height();
        return h;
    }

    /// The end of the longest run of rows from `from` that fits in `px`
    /// (at least one row, so paging always moves on).
    pub fn fit_from(l: *const Log, from: u32, to: u32, px: i32) u32 {
        var h: i32 = 0;
        var i = @max(from, l.oldest());
        while (i < to) : (i += 1) {
            h += l.get(i).height();
            if (h > px) break;
        }
        return @max(i, @min(from + 1, to));
    }
};

test "log: wrap, hanging indent, gaps, rules" {
    var l: Log = .{};
    try std.testing.expectEqual(@as(u32, 3), l.line("THIS PROGRAM SIMULATES A TRIP OVER THE OREGON TRAIL FROM", .ink, .left));
    l.gap();
    l.gap();
    _ = l.line("", .ink, .left);
    _ = l.line("     OXEN - YOU CAN SPEND $200-$300 ON YOUR TEAM THE MORE YOU SPEND", .ink, .hang);
    // Three rows, one gap (not three), then the paragraph: 26 columns,
    // then 24 indented.
    try std.testing.expectEqual(Kind.gap, l.get(3).kind);
    try std.testing.expectEqualStrings("OXEN - YOU CAN SPEND", l.get(4).str());
    try std.testing.expectEqual(@as(u8, 0), l.get(4).x);
    try std.testing.expectEqualStrings("$200-$300 ON YOUR TEAM", l.get(5).str());
    try std.testing.expectEqual(@as(u8, 12), l.get(5).x);
    try std.testing.expectEqualStrings("THE MORE YOU SPEND", l.get(6).str());
    try std.testing.expectEqual(@as(u32, 7), l.total);
    // A trailing gap is not stored.
    l.gap();
    try std.testing.expectEqual(@as(u32, 7), l.total);
    try std.testing.expectEqual(@as(i32, 3 * 9 + 4 + 3 * 9), l.height(0, 7));
    // A rule replaces a pending gap and carries its label.
    l.gap();
    l.rule("MONDAY APRIL 12 1847");
    try std.testing.expectEqual(@as(u32, 8), l.total);
    try std.testing.expectEqual(Kind.rule, l.get(7).kind);
    try std.testing.expectEqualStrings("MONDAY APRIL 12 1847", l.get(7).str());
}

test "log: the ring keeps the last cap rows" {
    var l: Log = .{};
    var k: u32 = 0;
    while (k < cap + 10) : (k += 1) _ = l.line("ROW", .ink, .left);
    try std.testing.expectEqual(@as(u32, 10), l.oldest());
    try std.testing.expectEqual(@as(i32, cap * 9), l.height(0, l.total));
}

test "log: fit_from" {
    var l: Log = .{};
    var k: u32 = 0;
    while (k < 20) : (k += 1) _ = l.line("ROW", .ink, .left);
    try std.testing.expectEqual(@as(u32, 5), l.fit_from(0, 20, 45));
    try std.testing.expectEqual(@as(u32, 5), l.fit_from(0, 20, 53));
    try std.testing.expectEqual(@as(u32, 20), l.fit_from(18, 20, 100));
    // Always at least one row.
    try std.testing.expectEqual(@as(u32, 1), l.fit_from(0, 20, 3));
}
