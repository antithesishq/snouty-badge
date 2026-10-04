//! Compact number formats for tight rows and the status line. The game's
//! own exact formats (`toLocaleString`, `toFixed`, `numberCruncher`, as JS
//! prints them) live in `game/fmt.zig`; these are the badge's short forms
//! where 26 columns do not hold the original's text.
//!
//! Every function writes into a caller buffer and returns the slice. No
//! std.fmt (float printing pulls in a lot of code); f64 values are scaled
//! and printed as integers.
const std = @import("std");

/// Suffixes for powers of 1000, short scale (the original's numberCruncher
/// names, shortened).
const suffixes = [_][]const u8{ "", "k", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qt", "Qd", "Sd" };

/// Unsigned integer with thousands separators: 1234567 -> "1,234,567".
pub fn commas_u(buf: []u8, v: u64) []const u8 {
    var tmp: [32]u8 = undefined;
    var n: usize = 0;
    var x = v;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            tmp[n] = ',';
            n += 1;
        }
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
        digits += 1;
        x /= 10;
        if (x == 0) break;
    }
    const len = @min(n, buf.len);
    for (0..len) |i| buf[i] = tmp[n - 1 - i];
    return buf[0..len];
}

/// Signed integer with separators.
pub fn commas_i(buf: []u8, v: i64) []const u8 {
    if (v >= 0) return commas_u(buf, @intCast(v));
    buf[0] = '-';
    const rest = commas_u(buf[1..], @intCast(-%v));
    return buf[0 .. rest.len + 1];
}

/// floor(v) with separators while it fits in an i64, else compact().
pub fn int(buf: []u8, v: f64) []const u8 {
    if (std.math.isNan(v)) return copy(buf, "NaN");
    const f = @floor(v);
    if (@abs(f) < 9.0e18) return commas_i(buf, @intFromFloat(f));
    return compact(buf, v);
}

/// Unsigned integer printed plainly (no separators).
pub fn plain_u(buf: []u8, v: u64) []const u8 {
    var tmp: [24]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    const len = @min(n, buf.len);
    for (0..len) |i| buf[i] = tmp[n - 1 - i];
    return buf[0..len];
}

/// At most about 6 characters: 999 -> "999", 9999 -> "9,999",
/// 12345 -> "12.3k", 1234567 -> "1.23M", huge -> "1.2e60".
/// Negative values get a leading '-'.
pub fn compact(buf: []u8, v: f64) []const u8 {
    if (std.math.isNan(v)) return copy(buf, "NaN");
    if (v < 0) {
        buf[0] = '-';
        const rest = compact(buf[1..], -v);
        return buf[0 .. rest.len + 1];
    }
    if (std.math.isInf(v)) return copy(buf, "Inf");
    if (v < 10000) return commas_u(buf, @intFromFloat(@floor(v)));
    var m = v;
    var i: usize = 0;
    while (m >= 1000 and i + 1 < suffixes.len) : (i += 1) m /= 1000;
    if (m >= 1000) return sci(buf, v);
    // Three significant digits, truncated (never shows more than it has).
    var n: usize = 0;
    if (m >= 100) {
        n = plain_u(buf, @intFromFloat(@floor(m))).len;
    } else if (m >= 10) {
        const t: u64 = @intFromFloat(@floor(m * 10));
        n = plain_u(buf, t / 10).len;
        buf[n] = '.';
        buf[n + 1] = @intCast('0' + t % 10);
        n += 2;
    } else {
        const t: u64 = @intFromFloat(@floor(m * 100));
        n = plain_u(buf, t / 100).len;
        buf[n] = '.';
        buf[n + 1] = @intCast('0' + (t / 10) % 10);
        buf[n + 2] = @intCast('0' + t % 10);
        n += 3;
    }
    const s = suffixes[i];
    @memcpy(buf[n .. n + s.len], s);
    return buf[0 .. n + s.len];
}

/// "1.2e60": one decimal, for numbers past the last suffix.
pub fn sci(buf: []u8, v: f64) []const u8 {
    var e: i32 = 0;
    var m = v;
    while (m >= 10) : (e += 1) m /= 10;
    while (m > 0 and m < 1) : (e -= 1) m *= 10;
    const t: u64 = @intFromFloat(@floor(m * 10));
    var n = plain_u(buf, t / 10).len;
    buf[n] = '.';
    buf[n + 1] = @intCast('0' + t % 10);
    buf[n + 2] = 'e';
    n += 3;
    if (e < 0) {
        buf[n] = '-';
        n += 1;
    }
    n += plain_u(buf[n..], @intCast(@abs(e))).len;
    return buf[0..n];
}

/// Dollars with cents and separators: 1234.5 -> "$1,234.50"; past a
/// billion, compact: "$1.23B".
pub fn money(buf: []u8, v: f64) []const u8 {
    buf[0] = '$';
    if (std.math.isNan(v)) return buf[0 .. 1 + copy(buf[1..], "NaN").len];
    if (@abs(v) >= 1.0e9) return buf[0 .. 1 + compact(buf[1..], v).len];
    const neg = v < 0;
    const cents: u64 = @intFromFloat(@round(@abs(v) * 100));
    var n: usize = 1;
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    n += commas_u(buf[n..], cents / 100).len;
    buf[n] = '.';
    buf[n + 1] = @intCast('0' + (cents / 10) % 10);
    buf[n + 2] = @intCast('0' + cents % 10);
    return buf[0 .. n + 3];
}

/// Dollars, short: "$12.34" under $1,000, else "$" ++ compact.
pub fn money_short(buf: []u8, v: f64) []const u8 {
    if (@abs(v) < 1000) return money(buf, v);
    buf[0] = '$';
    return buf[0 .. 1 + compact(buf[1..], v).len];
}

/// Fixed decimals (0..6), rounded half away from zero, no separators.
/// Values past 1e15 fall back to compact().
pub fn fixed(buf: []u8, v: f64, decimals: u3) []const u8 {
    if (std.math.isNan(v)) return copy(buf, "NaN");
    if (@abs(v) >= 1.0e15) return compact(buf, v);
    var scale: f64 = 1;
    for (0..decimals) |_| scale *= 10;
    const neg = v < 0;
    const t: u64 = @intFromFloat(@round(@abs(v) * scale));
    const p: u64 = @intFromFloat(scale);
    var n: usize = 0;
    if (neg and t != 0) {
        buf[0] = '-';
        n = 1;
    }
    n += plain_u(buf[n..], t / p).len;
    if (decimals > 0) {
        buf[n] = '.';
        n += 1;
        var frac = t % p;
        var d: usize = decimals;
        while (d > 0) : (d -= 1) {
            buf[n + d - 1] = @intCast('0' + frac % 10);
            frac /= 10;
        }
        n += decimals;
    }
    return buf[0..n];
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

const testing = std.testing;

fn expect_compact(v: f64, want: []const u8) !void {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings(want, compact(&b, v));
}

test "commas" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("0", commas_u(&b, 0));
    try testing.expectEqualStrings("999", commas_u(&b, 999));
    try testing.expectEqualStrings("1,000", commas_u(&b, 1000));
    try testing.expectEqualStrings("1,234,567", commas_u(&b, 1234567));
    try testing.expectEqualStrings("-12,345", commas_i(&b, -12345));
    try testing.expectEqualStrings("18,446,744,073,709,551,615", commas_u(&b, std.math.maxInt(u64)));
}

test "compact" {
    try expect_compact(0, "0");
    try expect_compact(9999.9, "9,999");
    try expect_compact(12345, "12.3k");
    try expect_compact(999_499, "999k");
    try expect_compact(999_999, "999k");
    try expect_compact(1_000_000, "1.00M");
    try expect_compact(1_234_567, "1.23M");
    try expect_compact(45.6e9, "45.6B");
    try expect_compact(3.0e18, "3.00Qi");
    try expect_compact(-12345, "-12.3k");
    try expect_compact(3.0e55, "3.0e55");
}

test "money" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("$0.00", money(&b, 0));
    try testing.expectEqualStrings("$0.25", money(&b, 0.25));
    try testing.expectEqualStrings("$1,234.50", money(&b, 1234.5));
    try testing.expectEqualStrings("$-5.00", money(&b, -5));
    try testing.expectEqualStrings("$12.3k", money_short(&b, 12345));
    try testing.expectEqualStrings("$2.50B", money(&b, 2.5e9));
}

test "fixed" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("0.25", fixed(&b, 0.25, 2));
    try testing.expectEqualStrings("3", fixed(&b, 2.5, 0));
    try testing.expectEqualStrings("-1.5", fixed(&b, -1.5, 1));
    try testing.expectEqualStrings("0.050", fixed(&b, 0.05, 3));
}
