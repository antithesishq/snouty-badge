//! Number formatting exactly as the original prints it in a browser
//! (V8 + ICU, en-US): `Number.prototype.toString`, `toFixed`,
//! `toLocaleString()` (ICU: shortest round-trip digits, then rounding
//! half away from zero to the fraction digits, then grouping), and the
//! game's own `numberCruncher` and `timeCruncher`.
//!
//! Every function writes into the caller's buffer and returns the used
//! slice. A buffer that is too small truncates the text, it never
//! overflows. 64 bytes hold every number below 1e40; `toLocaleString` of
//! numbers above 1e21 prints every integer digit (up to ~410 bytes).

const std = @import("std");
const jsmath = @import("jsmath.zig");

pub const Out = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Out {
        return .{ .buf = buf };
    }
    pub fn byte(o: *Out, c: u8) void {
        if (o.len < o.buf.len) {
            o.buf[o.len] = c;
            o.len += 1;
        }
    }
    pub fn str(o: *Out, s: []const u8) void {
        for (s) |c| o.byte(c);
    }
    pub fn slice(o: *const Out) []const u8 {
        return o.buf[0..o.len];
    }
};

/// Shortest round-trip decimal digits of |x| (x finite, nonzero):
/// value = 0.d1d2...dn * 10^point.
const Digits = struct {
    d: [20]u8 = undefined,
    n: usize = 0,
    point: i32 = 0,
};

fn shortest(x: f64) Digits {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.float.render(&tmp, @abs(x), .{ .mode = .scientific }) catch unreachable;
    var r = Digits{};
    var i: usize = 0;
    while (i < s.len and s[i] != 'e') : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9') {
            r.d[r.n] = s[i];
            r.n += 1;
        }
    }
    var e: i32 = 0;
    var neg = false;
    i += 1;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') {
        i += 1;
    }
    while (i < s.len) : (i += 1) e = e * 10 + @as(i32, s[i] - '0');
    if (neg) e = -e;
    // Strip trailing zeros (shortest output has none but keep it safe).
    while (r.n > 1 and r.d[r.n - 1] == '0') r.n -= 1;
    r.point = e + 1;
    return r;
}

fn put_int(o: *Out, v: i64) void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
    o.str(s);
}

fn special(o: *Out, x: f64) bool {
    if (std.math.isNan(x)) {
        o.str("NaN");
        return true;
    }
    if (std.math.isInf(x)) {
        o.str(if (x < 0) "-Infinity" else "Infinity");
        return true;
    }
    return false;
}

/// JS `String(x)` / `"" + x` (Number::toString, radix 10).
pub fn num_str(buf: []u8, x: f64) []const u8 {
    var o = Out.init(buf);
    write_num(&o, x);
    return o.slice();
}

pub fn write_num(o: *Out, x: f64) void {
    if (special(o, x)) return;
    if (x == 0) {
        o.byte('0');
        return;
    }
    if (x < 0) o.byte('-');
    const d = shortest(x);
    const k: i32 = @intCast(d.n);
    const n = d.point;
    if (k <= n and n <= 21) {
        o.str(d.d[0..d.n]);
        var z: i32 = 0;
        while (z < n - k) : (z += 1) o.byte('0');
    } else if (0 < n and n <= 21) {
        const un: usize = @intCast(n);
        o.str(d.d[0..un]);
        o.byte('.');
        o.str(d.d[un..d.n]);
    } else if (-6 < n and n <= 0) {
        o.str("0.");
        var z: i32 = 0;
        while (z < -n) : (z += 1) o.byte('0');
        o.str(d.d[0..d.n]);
    } else {
        o.byte(d.d[0]);
        if (d.n > 1) {
            o.byte('.');
            o.str(d.d[1..d.n]);
        }
        o.byte('e');
        const e = n - 1;
        o.byte(if (e < 0) '-' else '+');
        put_int(o, @abs(e));
    }
}

/// JS `x.toFixed(f)` for 0 <= f <= 20: exact decimal value, ties up.
pub fn to_fixed(buf: []u8, x: f64, f: u5) []const u8 {
    var o = Out.init(buf);
    write_fixed(&o, x, f);
    return o.slice();
}

pub fn write_fixed(o: *Out, x_in: f64, f: u5) void {
    if (std.math.isNan(x_in)) {
        o.str("NaN");
        return;
    }
    var x = x_in;
    if (x < 0) {
        o.byte('-');
        x = -x;
    }
    if (x >= 1e21) {
        write_num(o, x);
        return;
    }
    // x = m * 2^e exactly.
    const bits: u64 = @bitCast(x);
    const be: i32 = @intCast((bits >> 52) & 0x7ff);
    var m: u128 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (be == 0) {
        e = -1074;
    } else {
        m |= @as(u128, 1) << 52;
        e = be - 1075;
    }
    var p10: u128 = 1;
    var i: u5 = 0;
    while (i < f) : (i += 1) p10 *= 10;
    // n = round_half_up(m * 2^e * 10^f)
    var n: u128 = undefined;
    if (e >= 0) {
        n = (m << @intCast(e)) * p10; // x < 1e21 < 2^70, f <= 20: fits
    } else {
        const k: u32 = @intCast(-e);
        const prod = m * p10; // < 2^53 * 10^20 < 2^120
        if (k >= 127) {
            n = 0;
        } else {
            const sh: u7 = @intCast(k);
            n = prod >> sh;
            const rem = prod - (n << sh);
            const half = @as(u128, 1) << (sh - 1);
            if (rem >= half) n += 1;
        }
    }
    // Print n with f digits after the point.
    var digs: [48]u8 = undefined;
    var dn: usize = 0;
    var t = n;
    if (t == 0) {
        digs[0] = '0';
        dn = 1;
    }
    while (t > 0) : (t /= 10) {
        digs[dn] = @intCast('0' + @as(u8, @intCast(t % 10)));
        dn += 1;
    }
    // digs reversed; ensure at least f+1 digits
    while (dn < @as(usize, f) + 1) : (dn += 1) digs[dn] = '0';
    var idx: usize = dn;
    while (idx > 0) {
        idx -= 1;
        o.byte(digs[idx]);
        if (idx == f and f > 0) o.byte('.');
    }
}

/// JS `x.toLocaleString(undefined, {minimumFractionDigits: min_frac,
/// maximumFractionDigits: max_frac})`; plain `x.toLocaleString()` is
/// (0, 3).
pub fn locale(buf: []u8, x: f64, min_frac: u8, max_frac: u8) []const u8 {
    var o = Out.init(buf);
    write_locale(&o, x, min_frac, max_frac);
    return o.slice();
}

/// `x.toLocaleString()`.
pub fn loc(buf: []u8, x: f64) []const u8 {
    return locale(buf, x, 0, 3);
}

/// `x.toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})`.
pub fn loc2(buf: []u8, x: f64) []const u8 {
    return locale(buf, x, 2, 2);
}

pub fn write_locale(o: *Out, x: f64, min_frac: u8, max_frac: u8) void {
    if (std.math.isNan(x)) {
        o.str("NaN");
        return;
    }
    if (std.math.isInf(x)) {
        if (x < 0) o.byte('-');
        o.str("\u{221e}");
        return;
    }
    if (std.math.signbit(x)) o.byte('-');
    // Digits of the rounded value: int part digits + frac digits.
    var digs: [400]u8 = undefined; // all digits, decimal point after int_n
    var int_n: usize = 0; // number of integer digits (>= 1)
    var frac_n: usize = 0;
    if (x == 0) {
        digs[0] = '0';
        int_n = 1;
    } else {
        const d = shortest(x);
        const point = d.point;
        // Keep digits up to position point + max_frac.
        const keep: i32 = point + @as(i32, max_frac);
        var nd: [24]u8 = undefined; // kept significant digits (may carry)
        var nn: usize = 0;
        var pt = point;
        if (keep <= 0) {
            // Everything is dropped; round up if the first dropped digit
            // (d1 when keep == 0) is >= 5.
            if (keep == 0 and d.d[0] >= '5') {
                nd[0] = '1';
                nn = 1;
                pt = point + 1;
            } else {
                nn = 0;
            }
        } else {
            const ukeep: usize = @intCast(keep);
            if (ukeep >= d.n) {
                @memcpy(nd[0..d.n], d.d[0..d.n]);
                nn = d.n;
            } else {
                @memcpy(nd[0..ukeep], d.d[0..ukeep]);
                nn = ukeep;
                if (d.d[ukeep] >= '5') {
                    // carry
                    var j: usize = nn;
                    var carry = true;
                    while (carry and j > 0) {
                        j -= 1;
                        if (nd[j] == '9') {
                            nd[j] = '0';
                        } else {
                            nd[j] += 1;
                            carry = false;
                        }
                    }
                    if (carry) {
                        // all nines: prepend 1
                        std.mem.copyBackwards(u8, nd[1 .. nn + 1], nd[0..nn]);
                        nd[0] = '1';
                        nn += 1;
                        pt += 1;
                    }
                }
            }
        }
        // Now value = 0.nd * 10^pt (nn digits), with at most max_frac
        // fraction digits. Build int and frac parts.
        if (nn == 0) {
            digs[0] = '0';
            int_n = 1;
        } else if (pt <= 0) {
            digs[0] = '0';
            int_n = 1;
            const zeros: usize = @intCast(-pt);
            var z: usize = 0;
            while (z < zeros) : (z += 1) {
                digs[int_n + frac_n] = '0';
                frac_n += 1;
            }
            for (nd[0..nn]) |c| {
                digs[int_n + frac_n] = c;
                frac_n += 1;
            }
        } else {
            const upt: usize = @intCast(pt);
            var k: usize = 0;
            while (k < upt) : (k += 1) {
                digs[k] = if (k < nn) nd[k] else '0';
            }
            int_n = upt;
            while (k < nn) : (k += 1) {
                digs[int_n + frac_n] = nd[k];
                frac_n += 1;
            }
        }
        // Trim trailing zeros in the fraction.
        while (frac_n > 0 and digs[int_n + frac_n - 1] == '0') frac_n -= 1;
    }
    while (frac_n < min_frac) : (frac_n += 1) digs[int_n + frac_n] = '0';
    // Grouping.
    var k: usize = 0;
    while (k < int_n) : (k += 1) {
        o.byte(digs[k]);
        const left = int_n - k - 1;
        if (left > 0 and left % 3 == 0) o.byte(',');
    }
    if (frac_n > 0) {
        o.byte('.');
        o.str(digs[int_n .. int_n + frac_n]);
    }
}

const cruncher_steps = [_]struct { limit: f64, div: f64, suffix: []const u8 }{
    .{ .limit = 999999999999999999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000000000000000000.0, .suffix = "sexdecillion" },
    .{ .limit = 999999999999999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000000000000000.0, .suffix = "quindecillion" },
    .{ .limit = 999999999999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000000000000.0, .suffix = "quattuordecillion" },
    .{ .limit = 999999999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000000000.0, .suffix = "tredecillion" },
    .{ .limit = 999999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000000.0, .suffix = "duodecillion" },
    .{ .limit = 999999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000000.0, .suffix = "undecillion" },
    .{ .limit = 999999999999999999999999999999999.0, .div = 1000000000000000000000000000000000.0, .suffix = "decillion" },
    .{ .limit = 999999999999999999999999999999.0, .div = 1000000000000000000000000000000.0, .suffix = "nonillion" },
    .{ .limit = 999999999999999999999999999.0, .div = 1000000000000000000000000000.0, .suffix = "octillion" },
    .{ .limit = 999999999999999999999999.0, .div = 1000000000000000000000000.0, .suffix = "septillion" },
    .{ .limit = 999999999999999999999.0, .div = 1000000000000000000000.0, .suffix = "sextillion" },
    .{ .limit = 999999999999999999.0, .div = 1000000000000000000.0, .suffix = "quintillion" },
    .{ .limit = 999999999999999.0, .div = 1000000000000000.0, .suffix = "quadrillion" },
    .{ .limit = 999999999999.0, .div = 1000000000000.0, .suffix = "trillion" },
    .{ .limit = 999999999.0, .div = 1000000000.0, .suffix = "billion" },
    .{ .limit = 999999.0, .div = 1000000.0, .suffix = "million" },
    .{ .limit = 999.0, .div = 1000.0, .suffix = "thousand" },
};

/// The game's `numberCruncher(number, decimals)` (decimals defaults to 2
/// in the JS; pass 2). Note the trailing space when there is no suffix.
pub fn number_cruncher(buf: []u8, number_in: f64, decimals: u5) []const u8 {
    var o = Out.init(buf);
    write_number_cruncher(&o, number_in, decimals);
    return o.slice();
}

pub fn write_number_cruncher(o: *Out, number_in: f64, decimals: u5) void {
    var number = number_in;
    var precision = decimals;
    var suffix: []const u8 = "";
    var found = false;
    for (cruncher_steps) |s| {
        if (number > s.limit) {
            number = number / s.div;
            suffix = s.suffix;
            found = true;
            break;
        }
    }
    if (!found and number < 1000) precision = 0;
    write_fixed(o, number, precision);
    o.byte(' ');
    o.str(suffix);
}

/// The game's `timeCruncher(t)`, t in 10 ms ticks.
pub fn time_cruncher(buf: []u8, t: f64) []const u8 {
    var o = Out.init(buf);
    write_time_cruncher(&o, t);
    return o.slice();
}

pub fn write_time_cruncher(o: *Out, t: f64) void {
    const x = t / 100;
    const h = @floor(x / 3600);
    const m = @floor(@rem(x, 3600) / 60);
    const s = @floor(@rem(@rem(x, 3600), 60));
    if (h > 0) {
        write_num(o, h);
        o.str(if (h == 1) " hour " else " hours ");
    }
    if (m > 0) {
        write_num(o, m);
        o.str(if (m == 1) " minute " else " minutes ");
    }
    if (s > 0) {
        write_num(o, s);
        o.str(if (s == 1) " second" else " seconds");
    }
}

test "fmt basics" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("1.001", loc(&b, 1.0005));
    _ = jsmath;
}
