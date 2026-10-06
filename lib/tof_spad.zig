//! User-defined SPAD masks for the TMF8820 (docs/TOF.md sections 3 and 4
//! M2): the mask, the datasheet's constraints, and the SPAD configuration
//! page the sensor takes them in. Plain data, no bus: lib/tof.zig sends
//! the page, lib/tof_virtual.zig decodes and checks it the same way.
//!
//! Sources (docs/TOF.md section 3 has the table):
//! - DS000693 7.4.1: spad_map_id 14 = one measurement of up to 9 zones;
//!   the mask is at most 18x10; enable mask and channel map the same size;
//!   channel 0 (the reference) unused; mask plus offset within 18x12 (the
//!   offsets are Q1, i.e. half SPADs: +-2 is one SPAD); at least two
//!   adjacent SPADs per used channel; no row with channel 1 and channel 8
//!   or 9; at least one channel of each TDC pair (2|3, 4|5, 6|7, 8|9).
//!   DS 8.6: page cid 0x17 (command 0x17 loads it), enable mask from
//!   0x24, channel map from 0x42, x/y offset 0x8D/0x8E, x/y size 0x8F/0x90.
//! - The ams host driver (`tmf882x_mode_app.c` encode_spad_config_msg,
//!   `tmf8x2x_config_page_SPAD.h`): the enable mask is one 24-bit LE word
//!   per row (bit x = column x), rows from the last (`y = ysize - 1`)
//!   first; the channel map is one 32-bit LE word per column at 0x42 +
//!   4x, holding the channel's three bits at yIdx, 10 + yIdx and 20 + yIdx;
//!   channels 8 and 9 are stored as 0 and 1 with the row's bit set in the
//!   24-bit channel-select word at 0x8A (which is why one row cannot have
//!   channel 1 and channel 8/9). The driver writes the common page with
//!   spad_map_id 14 before the SPAD page (`set_spad_config` refuses
//!   otherwise; DS status 0x0A says the device ignores the page then).
//! - Inference (unverified): `Mask.ch[r]` is register row r (yIdx), drawn
//!   top-down; column 0 is drawn left; channel c reports in result
//!   triplet c - 1 (zone c); the mask must sit on whole SPADs
//!   (18 - xsize + x_offset_2 and 12 - ysize + y_offset_2 even);
//!   "adjacent" means sharing an edge (diagonals rejected).
const std = @import("std");

/// The SPAD array (DS 7.4.1; one SPAD is 2.4 deg x 5.6 deg).
pub const cols = 18;
pub const rows = 10;
/// Rows the offset may reach (mask plus offset within 18x12).
pub const span_rows = 12;
/// spad_map_id for one user-defined measurement of up to 9 zones.
pub const map_id: u8 = 14;
/// Command that loads the SPAD page, and the page's cid in 0x20.
pub const cmd_load: u8 = 0x17;
pub const cid: u8 = 0x17;
/// DS status: the SPAD page was ignored (spad_map_id is not a user map).
pub const stat_ignored: u8 = 0x0A;

pub const reg = struct {
    pub const enable = 0x24;
    pub const tdc = 0x42;
    pub const select = 0x8A;
    pub const x_offset = 0x8D;
    pub const y_offset = 0x8E;
    pub const x_size = 0x8F;
    pub const y_size = 0x90;
};
/// The page from 0x24 through 0x90.
pub const page_len = reg.y_size + 1 - reg.enable;
pub const Page = [page_len]u8;

/// A user SPAD mask. `ch[r][x]` is the zone channel (1..9) of SPAD (x, r)
/// of the mask, 0 = disabled; only the top-left `xsize` x `ysize` corner
/// counts. Offsets in half SPADs from the field-of-view centre.
pub const Mask = struct {
    xsize: u8 = cols,
    ysize: u8 = rows,
    xoff_q1: i8 = 0,
    yoff_q1: i8 = 0,
    ch: [rows][cols]u8 = @splat(@splat(0)),

    pub fn at(m: *const Mask, x: usize, r: usize) u8 {
        return if (x < m.xsize and r < m.ysize) m.ch[r][x] else 0;
    }

    /// Enabled SPADs on channel `c`.
    pub fn count(m: *const Mask, c: u8) u32 {
        var n: u32 = 0;
        for (0..m.ysize) |r| for (0..m.xsize) |x| {
            n += @intFromBool(m.ch[r][x] == c);
        };
        return n;
    }

    /// Bit c set when channel c has a SPAD.
    pub fn used(m: *const Mask) u16 {
        var u: u16 = 0;
        for (0..m.ysize) |r| for (0..m.xsize) |x| {
            u |= @as(u16, 1) << @intCast(m.ch[r][x]);
        };
        return u & ~@as(u16, 1);
    }

    /// The physical SPAD column / row (0..17, 0..11) of mask SPAD (x, r),
    /// for a mask that passed `validate` (whole-SPAD placement).
    pub fn phys_col(m: *const Mask, x: usize) i32 {
        return @as(i32, @intCast(x)) + @divFloor(@as(i32, cols) - m.xsize + m.xoff_q1, 2);
    }
    pub fn phys_row(m: *const Mask, r: usize) i32 {
        return @as(i32, @intCast(r)) + @divFloor(@as(i32, span_rows) - m.ysize + m.yoff_q1, 2);
    }
};

pub const Kind = enum(u8) {
    /// xsize not 1..18 or ysize not 1..10.
    size,
    /// Mask plus offset beyond 18x12.
    offset,
    /// The offset puts the mask between SPADs (inference).
    half_spad,
    /// A channel number above 9.
    channel,
    /// No SPAD enabled.
    empty,
    /// A used channel without two SPADs that share an edge (`at` = channel).
    lonely,
    /// A row uses channel 1 and channel 8 or 9 (`at` = row).
    row_mix,
    /// A TDC pair with neither channel used (`at` = its lower channel).
    tdc,

    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

pub const Problem = struct {
    kind: Kind,
    at: u8 = 0,
};

/// The datasheet's constraints (and the inferred whole-SPAD placement);
/// null if the mask may be sent.
pub fn validate(m: *const Mask) ?Problem {
    if (m.xsize < 1 or m.xsize > cols or m.ysize < 1 or m.ysize > rows) return .{ .kind = .size };
    const ax: i32 = @intCast(@abs(@as(i32, m.xoff_q1)));
    const ay: i32 = @intCast(@abs(@as(i32, m.yoff_q1)));
    if (ax + m.xsize > cols or ay + m.ysize > span_rows) return .{ .kind = .offset };
    if (@mod(@as(i32, cols) - m.xsize + m.xoff_q1, 2) != 0 or
        @mod(@as(i32, span_rows) - m.ysize + m.yoff_q1, 2) != 0) return .{ .kind = .half_spad };
    for (0..m.ysize) |r| for (0..m.xsize) |x| {
        if (m.ch[r][x] > 9) return .{ .kind = .channel, .at = m.ch[r][x] };
    };
    const u = m.used();
    if (u == 0) return .{ .kind = .empty };
    var c: u8 = 1;
    while (c <= 9) : (c += 1) {
        if (u & (@as(u16, 1) << @intCast(c)) != 0 and !has_pair(m, c)) return .{ .kind = .lonely, .at = c };
    }
    for (0..m.ysize) |r| {
        var one = false;
        var high = false;
        for (m.ch[r][0..m.xsize]) |v| {
            one = one or v == 1;
            high = high or v == 8 or v == 9;
        }
        if (one and high) return .{ .kind = .row_mix, .at = @intCast(r) };
    }
    c = 2;
    while (c <= 8) : (c += 2) {
        if (u & (@as(u16, 3) << @intCast(c)) == 0) return .{ .kind = .tdc, .at = c };
    }
    return null;
}

fn has_pair(m: *const Mask, c: u8) bool {
    for (0..m.ysize) |r| for (0..m.xsize) |x| {
        if (m.ch[r][x] != c) continue;
        if (x + 1 < m.xsize and m.ch[r][x + 1] == c) return true;
        if (r + 1 < m.ysize and m.ch[r + 1][x] == c) return true;
    };
    return false;
}

/// The SPAD page (0x24..0x90) for `m`, in the ams driver's layout.
/// Register row yIdx is mask row yIdx (see the header on the inference).
pub fn encode(m: *const Mask, p: *Page) void {
    @memset(p, 0);
    var select: u32 = 0;
    for (0..m.ysize) |r| {
        var bits: u32 = 0;
        for (0..m.xsize) |x| {
            if (m.ch[r][x] != 0) bits |= @as(u32, 1) << @intCast(x);
            if (m.ch[r][x] >= 8) select |= @as(u32, 1) << @intCast(r);
        }
        put(p, reg.enable + 3 * r, 3, bits);
    }
    for (0..m.xsize) |x| {
        var w: u32 = 0;
        for (0..m.ysize) |r| {
            var c: u32 = m.ch[r][x];
            if (c >= 8) c -= 8;
            const y: u5 = @intCast(r);
            w |= (c & 1) << y | ((c >> 1) & 1) << (10 + y) | ((c >> 2) & 1) << (20 + y);
        }
        put(p, reg.tdc + 4 * x, 4, w);
    }
    put(p, reg.select, 3, select);
    p[reg.x_offset - reg.enable] = @bitCast(m.xoff_q1);
    p[reg.y_offset - reg.enable] = @bitCast(m.yoff_q1);
    p[reg.x_size - reg.enable] = m.xsize;
    p[reg.y_size - reg.enable] = m.ysize;
}

pub const Decoded = struct {
    mask: Mask = .{},
    /// Enabled SPADs whose channel decodes to 0 (the reference): the page
    /// is not a valid user mask.
    ch0: u32 = 0,
    /// Sizes out of range (the mask is clamped).
    bad_size: bool = false,
};

/// A SPAD page back into a mask (how the model reads what the driver
/// wrote, and how the driver checks the read-back).
pub fn decode(p: *const Page) Decoded {
    var d: Decoded = .{};
    const m = &d.mask;
    const xs = p[reg.x_size - reg.enable];
    const ys = p[reg.y_size - reg.enable];
    d.bad_size = xs < 1 or xs > cols or ys < 1 or ys > rows;
    m.xsize = @min(@max(xs, 1), cols);
    m.ysize = @min(@max(ys, 1), rows);
    m.xoff_q1 = @bitCast(p[reg.x_offset - reg.enable]);
    m.yoff_q1 = @bitCast(p[reg.y_offset - reg.enable]);
    const select = get(p, reg.select, 3);
    for (0..m.ysize) |r| {
        const bits = get(p, reg.enable + 3 * r, 3);
        const y: u5 = @intCast(r);
        for (0..m.xsize) |x| {
            if (bits >> @intCast(x) & 1 == 0) continue;
            const w = get(p, reg.tdc + 4 * x, 4);
            var c: u8 = @intCast((w >> y & 1) | (w >> (10 + y) & 1) << 1 | (w >> (20 + y) & 1) << 2);
            if (select >> y & 1 != 0 and c < 2) c += 8;
            if (c == 0) d.ch0 += 1;
            m.ch[r][x] = c;
        }
    }
    return d;
}

/// Where two masks differ (what the read-back check reports): null if
/// they are the same mask; else 0xFF00 | field for a size or offset
/// (0 x size, 1 y size, 2 x offset, 3 y offset), or row << 8 | column of
/// the first SPAD that differs.
pub fn diff(a: *const Mask, b: *const Mask) ?u16 {
    if (a.xsize != b.xsize) return 0xFF00;
    if (a.ysize != b.ysize) return 0xFF01;
    if (a.xoff_q1 != b.xoff_q1) return 0xFF02;
    if (a.yoff_q1 != b.yoff_q1) return 0xFF03;
    for (0..a.ysize) |r| for (0..a.xsize) |x| {
        if (a.ch[r][x] != b.ch[r][x]) return @intCast(r << 8 | x);
    };
    return null;
}

fn put(p: *Page, r: usize, n: usize, v: u32) void {
    for (0..n) |i| p[r - reg.enable + i] = @truncate(v >> @intCast(8 * i));
}

fn get(p: *const Page, r: usize, n: usize) u32 {
    var v: u32 = 0;
    for (0..n) |i| v |= @as(u32, p[r - reg.enable + i]) << @intCast(8 * i);
    return v;
}

// ---- masks the carts use ----

/// A 3x3 user mask over the whole array (rows 3 / 4 / 3, columns of 6):
/// what spad_map_id 14 shows before a cart sets its own.
pub fn grid_3x3() Mask {
    var m: Mask = .{};
    for (0..rows) |r| {
        const zr: u8 = if (r < 3) 0 else if (r < 7) 1 else 2;
        for (0..cols) |x| m.ch[r][x] = zr * 3 + @as(u8, @intCast(x / 6)) + 1;
    }
    return m;
}

/// The STRIPES layout (docs/TOF.md M5): 8 full-height vertical stripes
/// over the whole array, stripe k on channel k + 2 (2..9), so it reports
/// in result triplet k + 1. Channel 1 is never used: a full-height
/// stripe puts its channel in every row, and no row may hold channel 1
/// with 8 or 9 (DS 7.4.1), so 9 stripes cannot be built. Every TDC pair
/// (2|3 .. 8|9) is used. The two spare columns widen the outer stripes.
pub const stripe_count = 8;
/// First SPAD column and width of each stripe (columns 3 2 2 2 2 2 2 3).
pub const stripe_first = [stripe_count + 1]u8{ 0, 3, 5, 7, 9, 11, 13, 15, 18 };
/// The channel of stripe k.
pub const stripe_channel0: u8 = 2;

pub fn stripes() Mask {
    var m: Mask = .{};
    for (0..stripe_count) |k| {
        for (stripe_first[k]..stripe_first[k + 1]) |x| {
            for (0..rows) |r| m.ch[r][x] = stripe_channel0 + @as(u8, @intCast(k));
        }
    }
    return m;
}

/// Mask column `x` (0..17) to its stripe.
pub fn stripe_of_col(x: usize) u8 {
    var k: u8 = 0;
    while (k + 1 < stripe_count and x >= stripe_first[k + 1]) k += 1;
    return k;
}

/// The depth photo's layouts (lib/tof_depth.zig): horizontal SPAD pairs,
/// nine per shot. The coarse pass tiles every row with pairs at columns
/// (0,1), (2,3) .. (16,17): 90 pairs, 10 shots, a 9x10 image. The fine
/// pass shifts the pairs one SPAD right, (1,2) .. (15,16): 80 pairs, 10
/// shots of 8; both together sample 17 columns. Each shot covers two rows:
/// one row's pairs on channels 1..4, the other's on 5..9, so no row mixes
/// channel 1 with 8 or 9 and every TDC pair is used.
pub const shots_per_pass = 10;

pub const Pass = enum(u1) { coarse, fine };

/// One shot: the mask and, per channel 1..9, the image pixel it fills
/// (column in the 17-wide grid, row 0..9), or none.
pub const Shot = struct {
    mask: Mask = .{},
    px: [9]?Pixel = @splat(null),
};

pub const Pixel = struct { col: u8, row: u8 };

/// Image columns (17-wide grid) of each pass's pairs: the pair at SPAD
/// columns (k, k + 1) fills image column k.
pub fn pairs_in_row(pass: Pass) u8 {
    return if (pass == .coarse) 9 else 8;
}

pub fn shot(pass: Pass, k: u8) Shot {
    var s: Shot = .{};
    const rp: u8 = k / 2;
    const half: u8 = k % 2;
    const n = pairs_in_row(pass);
    const first_col: u8 = @backingInt(pass);
    // Row a = 2rp, row b = 2rp + 1. Half 0: a's first 4 pairs on 1..4, b's
    // first n - 4 pairs on 5..; half 1: a's remaining pairs on 5.., b's
    // remaining 4 on 1..4.
    const low_row: u8 = 2 * rp + half; // the row on channels 1..4
    const high_row: u8 = 2 * rp + (1 - half);
    var ch: u8 = 1;
    const a_from: u8 = if (half == 0) 0 else 4;
    const a_to: u8 = if (half == 0) 4 else n;
    const b_from: u8 = if (half == 0) 0 else n - 4;
    const b_to: u8 = if (half == 0) n - 4 else n;
    // Low channels first, on low_row.
    const low_from = if (half == 0) a_from else b_from;
    const low_to = if (half == 0) a_to else b_to;
    const high_from = if (half == 0) b_from else a_from;
    const high_to = if (half == 0) b_to else a_to;
    var i = low_from;
    while (i < low_to) : (i += 1) {
        add_pair(&s, ch, low_row, first_col + 2 * i);
        ch += 1;
    }
    ch = 5;
    i = high_from;
    while (i < high_to) : (i += 1) {
        add_pair(&s, ch, high_row, first_col + 2 * i);
        ch += 1;
    }
    return s;
}

fn add_pair(s: *Shot, c: u8, r: u8, x: u8) void {
    s.mask.ch[r][x] = c;
    s.mask.ch[r][x + 1] = c;
    s.px[c - 1] = .{ .col = x, .row = r };
}

test "grid_3x3 and every depth layout pass the datasheet's rules" {
    try std.testing.expectEqual(@as(?Problem, null), validate(&grid_3x3()));
    var covered: [rows][cols]u8 = @splat(@splat(0));
    inline for (.{ Pass.coarse, Pass.fine }) |pass| {
        for (0..shots_per_pass) |k| {
            const s = shot(pass, @intCast(k));
            if (validate(&s.mask)) |p| {
                std.debug.print("{s} shot {d}: {s} at {d}\n", .{ @tagName(pass), k, p.kind.name(), p.at });
                return error.Invalid;
            }
            for (s.px, 0..) |px, c| if (px) |p| {
                try std.testing.expectEqual(@as(u8, @intCast(c + 1)), s.mask.ch[p.row][p.col]);
                covered[p.row][p.col] += 1;
            };
        }
    }
    // Coarse: every even column once; fine: every odd column but 17.
    for (0..rows) |r| for (0..17) |x| try std.testing.expectEqual(@as(u8, 1), covered[r][x]);
}

test "the stripes mask passes the datasheet's rules and covers every SPAD once" {
    const m = stripes();
    try std.testing.expectEqual(@as(?Problem, null), validate(&m));
    // Channels 2..9, never 1 (no row may hold 1 with 8 or 9).
    try std.testing.expectEqual(@as(u16, 0b11_1111_1100), m.used());
    for (0..rows) |r| for (0..cols) |x| {
        try std.testing.expect(m.ch[r][x] >= 2);
        try std.testing.expectEqual(stripe_channel0 + stripe_of_col(x), m.ch[r][x]);
    };
    // Outer stripes 3 columns, inner 2: 30 and 20 SPADs.
    try std.testing.expectEqual(@as(u32, 30), m.count(2));
    try std.testing.expectEqual(@as(u32, 20), m.count(5));
    try std.testing.expectEqual(@as(u32, 30), m.count(9));
    // Through the page and back unchanged (channels 8 and 9 via the select
    // bits on every row).
    var p: Page = undefined;
    encode(&m, &p);
    try std.testing.expectEqual(@as(?u16, null), diff(&m, &decode(&p).mask));
    // Nine full-height stripes cannot be built: channel 1 shares rows with 8 and 9.
    var nine = m;
    for (0..rows) |r| {
        nine.ch[r][0] = 1;
        nine.ch[r][1] = 1;
    }
    try std.testing.expectEqual(Kind.row_mix, validate(&nine).?.kind);
}

test "encode and decode are inverse, channels 8 and 9 through the select bits" {
    var m: Mask = .{ .xsize = 6, .ysize = 4, .xoff_q1 = 2, .yoff_q1 = -2 };
    const layout = [4][6]u8{
        .{ 1, 1, 2, 2, 3, 3 },
        .{ 4, 4, 5, 5, 0, 0 },
        .{ 6, 6, 7, 7, 8, 8 },
        .{ 9, 9, 0, 0, 0, 0 },
    };
    for (layout, 0..) |row, r| @memcpy(m.ch[r][0..6], &row);
    try std.testing.expectEqual(@as(?Problem, null), validate(&m));
    var p: Page = undefined;
    encode(&m, &p);
    // Row 2 and 3 use the select bits.
    try std.testing.expectEqual(@as(u8, 0b1100), p[reg.select - reg.enable]);
    // Row 0's enable word: six bits.
    try std.testing.expectEqual(@as(u8, 0x3F), p[0]);
    const d = decode(&p);
    try std.testing.expectEqual(@as(u32, 0), d.ch0);
    try std.testing.expectEqual(@as(?u16, null), diff(&m, &d.mask));
    // One SPAD changed in the page shows up as that SPAD.
    p[reg.tdc - reg.enable + 4 * 2] ^= 1; // column 2, row 0, channel bit 0
    try std.testing.expectEqual(@as(?u16, 0x0002), diff(&m, &decode(&p).mask));
}

test "the validator rejects each broken rule" {
    const base = grid_3x3();
    var m = base;
    m.xsize = 19;
    try std.testing.expectEqual(Kind.size, validate(&m).?.kind);
    m = base;
    m.xoff_q1 = 2;
    try std.testing.expectEqual(Kind.offset, validate(&m).?.kind);
    m = base;
    m.yoff_q1 = 2; // 18x10 may move one row
    try std.testing.expectEqual(@as(?Problem, null), validate(&m));
    m.yoff_q1 = 4;
    try std.testing.expectEqual(Kind.offset, validate(&m).?.kind);
    m.yoff_q1 = 1;
    try std.testing.expectEqual(Kind.half_spad, validate(&m).?.kind);
    m = .{};
    try std.testing.expectEqual(Kind.empty, validate(&m).?.kind);
    m = base;
    m.ch[0][0] = 12;
    try std.testing.expectEqual(Kind.channel, validate(&m).?.kind);
    // A lonely SPAD, or two only touching at a corner.
    var s = shot(.coarse, 0).mask;
    s.ch[9][17] = 7;
    try std.testing.expectEqual(@as(?Problem, null), validate(&s)); // channel 7 still has its pair
    s = shot(.coarse, 0).mask;
    s.ch[0][1] = 0; // channel 1 down to one SPAD
    try std.testing.expectEqual(Problem{ .kind = .lonely, .at = 1 }, validate(&s).?);
    s.ch[1][1] = 1; // diagonal neighbour
    try std.testing.expectEqual(Problem{ .kind = .lonely, .at = 1 }, validate(&s).?);
    s.ch[1][0] = 1; // now (0,0)-(0,1) vertical
    try std.testing.expectEqual(Problem{ .kind = .row_mix, .at = 1 }, validate(&s).?); // row 1 holds 5..9
    // Channel 1 next to 8 in one row.
    s = shot(.coarse, 0).mask;
    s.ch[0][16] = 8;
    s.ch[0][17] = 8;
    try std.testing.expectEqual(Problem{ .kind = .row_mix, .at = 0 }, validate(&s).?);
    // A TDC pair unused: drop channels 6 and 7.
    s = shot(.coarse, 0).mask;
    for (&s.ch) |*row| for (row) |*v| {
        if (v.* == 6 or v.* == 7) v.* = 0;
    };
    try std.testing.expectEqual(Problem{ .kind = .tdc, .at = 6 }, validate(&s).?);
}
