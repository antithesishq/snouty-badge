//! The JavaScript Math functions the game uses, bit for bit as V8 computes
//! them (V8 12.x `src/base/ieee754.cc`, the fdlibm code from FreeBSD's msun).
//! Zig's own `pow` (from Go) and the compiler-rt `sin`/`log`/`log10` differ
//! from V8 in the last bit for a few percent of inputs, which would make the
//! port drift from the original (costs, demand, wire price, qOps).

const std = @import("std");

inline fn hi(d: f64) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(d)) >> 32)));
}
inline fn lo(d: f64) u32 {
    return @truncate(@as(u64, @bitCast(d)));
}
inline fn words(h: i32, l: u32) f64 {
    return @bitCast((@as(u64, @as(u32, @bitCast(h))) << 32) | l);
}
inline fn set_lo(d: f64, l: u32) f64 {
    return words(hi(d), l);
}
inline fn set_hi(d: f64, h: i32) f64 {
    return words(h, lo(d));
}

pub fn floor(x: f64) f64 {
    return @floor(x);
}
pub fn ceil(x: f64) f64 {
    return @ceil(x);
}

/// JS Math.round: round half up (towards +inf), -0 kept for (-0.5, 0].
pub fn round(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return x;
    const f = @floor(x);
    const d = x - f;
    if (d >= 0.5) return f + 1.0;
    return f;
}

pub fn log(x_in: f64) f64 {
    const ln2_hi: f64 = 6.93147180369123816490e-01;
    const ln2_lo: f64 = 1.90821492927058770002e-10;
    const two54: f64 = 1.80143985094819840000e+16;
    const Lg1: f64 = 6.666666666666735130e-01;
    const Lg2: f64 = 3.999999999940941908e-01;
    const Lg3: f64 = 2.857142874366239149e-01;
    const Lg4: f64 = 2.222219843214978396e-01;
    const Lg5: f64 = 1.818357216161805012e-01;
    const Lg6: f64 = 1.531383769920937332e-01;
    const Lg7: f64 = 1.479819860511658591e-01;

    var x = x_in;
    var hx = hi(x);
    const lx = lo(x);
    var k: i32 = 0;
    if (hx < 0x00100000) {
        if (((hx & 0x7FFFFFFF) | @as(i32, @bitCast(lx))) == 0) return -std.math.inf(f64);
        if (hx < 0) return std.math.nan(f64);
        k -= 54;
        x *= two54;
        hx = hi(x);
    }
    if (hx >= 0x7FF00000) return x + x;
    k += (hx >> 20) - 1023;
    hx &= 0x000FFFFF;
    var i: i32 = (hx +% 0x95F64) & 0x100000;
    x = set_hi(x, hx | (i ^ 0x3FF00000));
    k += (i >> 20);
    const f = x - 1.0;
    if ((0x000FFFFF & (2 + hx)) < 3) {
        if (f == 0) {
            if (k == 0) return 0;
            const dk: f64 = @floatFromInt(k);
            return dk * ln2_hi + dk * ln2_lo;
        }
        const R = f * f * (0.5 - 0.33333333333333333 * f);
        if (k == 0) return f - R;
        const dk: f64 = @floatFromInt(k);
        return dk * ln2_hi - ((R - dk * ln2_lo) - f);
    }
    const s = f / (2.0 + f);
    const dk: f64 = @floatFromInt(k);
    const z = s * s;
    i = hx - 0x6147A;
    const w = z * z;
    const j: i32 = 0x6B851 - hx;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    i |= j;
    const R = t2 + t1;
    if (i > 0) {
        const hfsq = 0.5 * f * f;
        if (k == 0) return f - (hfsq - s * (hfsq + R));
        return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f);
    } else {
        if (k == 0) return f - s * (f - R);
        return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f);
    }
}

pub fn log10(x_in: f64) f64 {
    const two54: f64 = 1.80143985094819840000e+16;
    const ivln10: f64 = 4.34294481903251816668e-01;
    const log10_2hi: f64 = 3.01029995663611771306e-01;
    const log10_2lo: f64 = 3.69423907715893078616e-13;

    var x = x_in;
    var hx = hi(x);
    var lx = lo(x);
    var k: i32 = 0;
    if (hx < 0x00100000) {
        if (((hx & 0x7FFFFFFF) | @as(i32, @bitCast(lx))) == 0) return -std.math.inf(f64);
        if (hx < 0) return std.math.nan(f64);
        k -= 54;
        x *= two54;
        hx = hi(x);
        lx = lo(x);
    }
    if (hx >= 0x7FF00000) return x + x;
    if (hx == 0x3FF00000 and lx == 0) return 0.0;
    k += (hx >> 20) - 1023;
    const i: i32 = @intCast(@as(u32, @bitCast(k)) >> 31);
    hx = (hx & 0x000FFFFF) | ((0x3FF - i) << 20);
    const y: f64 = @floatFromInt(k + i);
    x = words(hx, lx);
    const z = y * log10_2lo + ivln10 * log(x);
    return z + y * log10_2hi;
}

fn scalbn(x_in: f64, n_in: i32) f64 {
    return std.math.ldexp(x_in, n_in);
}

pub fn pow(x: f64, y: f64) f64 {
    const bp = [2]f64{ 1.0, 1.5 };
    const dp_h = [2]f64{ 0.0, 5.84962487220764160156e-01 };
    const dp_l = [2]f64{ 0.0, 1.35003920212974897128e-08 };
    const one: f64 = 1.0;
    const two53: f64 = 9007199254740992.0;
    const huge: f64 = 1.0e300;
    const tiny: f64 = 1.0e-300;
    const L1: f64 = 5.99999999999994648725e-01;
    const L2: f64 = 4.28571428578550184252e-01;
    const L3: f64 = 3.33333329818377432918e-01;
    const L4: f64 = 2.72728123808534006489e-01;
    const L5: f64 = 2.30660745775561754067e-01;
    const L6: f64 = 2.06975017800338417784e-01;
    const P1: f64 = 1.66666666666666019037e-01;
    const P2: f64 = -2.77777777770155933842e-03;
    const P3: f64 = 6.61375632143793436117e-05;
    const P4: f64 = -1.65339022054652515390e-06;
    const P5: f64 = 4.13813679705723846039e-08;
    const lg2: f64 = 6.93147180559945286227e-01;
    const lg2_h: f64 = 6.93147182464599609375e-01;
    const lg2_l: f64 = -1.90465429995776804525e-09;
    const ovt: f64 = 8.0085662595372944372e-0017;
    const cp: f64 = 9.61796693925975554329e-01;
    const cp_h: f64 = 9.61796700954437255859e-01;
    const cp_l: f64 = -7.02846165095275826516e-09;
    const ivln2: f64 = 1.44269504088896338700e+00;
    const ivln2_h: f64 = 1.44269502162933349609e+00;
    const ivln2_l: f64 = 1.92596299112661746887e-08;

    const hx = hi(x);
    const lx = lo(x);
    const hy = hi(y);
    const ly = lo(y);
    var ix: i32 = hx & 0x7fffffff;
    const iy: i32 = hy & 0x7fffffff;

    if ((iy | @as(i32, @bitCast(ly))) == 0) return one;
    if (ix > 0x7ff00000 or (ix == 0x7ff00000 and lx != 0) or iy > 0x7ff00000 or (iy == 0x7ff00000 and ly != 0))
        return x + y;

    var yisint: i32 = 0;
    if (hx < 0) {
        if (iy >= 0x43400000) {
            yisint = 2;
        } else if (iy >= 0x3ff00000) {
            const k: i32 = (iy >> 20) - 0x3ff;
            if (k > 20) {
                const sh: u5 = @intCast(52 - k);
                const j: u32 = ly >> sh;
                if ((j << sh) == ly) yisint = 2 - @as(i32, @intCast(j & 1));
            } else if (ly == 0) {
                const sh: u5 = @intCast(20 - k);
                const j: i32 = iy >> sh;
                if ((j << sh) == iy) yisint = 2 - (j & 1);
            }
        }
    }

    if (ly == 0) {
        if (iy == 0x7ff00000) {
            if (((ix - 0x3ff00000) | @as(i32, @bitCast(lx))) == 0) {
                return y - y;
            } else if (ix >= 0x3ff00000) {
                return if (hy >= 0) y else 0.0;
            } else {
                return if (hy < 0) -y else 0.0;
            }
        }
        if (iy == 0x3ff00000) {
            return if (hy < 0) one / x else x;
        }
        if (hy == 0x40000000) return x * x;
        if (hy == 0x3fe00000) {
            if (hx >= 0) return @sqrt(x);
        }
    }

    var ax = @abs(x);
    if (lx == 0) {
        if (ix == 0x7ff00000 or ix == 0 or ix == 0x3ff00000) {
            var z = ax;
            if (hy < 0) z = one / z;
            if (hx < 0) {
                if (((ix - 0x3ff00000) | yisint) == 0) {
                    z = std.math.nan(f64);
                } else if (yisint == 1) {
                    z = -z;
                }
            }
            return z;
        }
    }

    var n: i32 = (hx >> 31) + 1;
    if ((n | yisint) == 0) return std.math.nan(f64);

    var s: f64 = one;
    if ((n | (yisint - 1)) == 0) s = -one;

    var t1: f64 = undefined;
    var t2: f64 = undefined;
    if (iy > 0x41e00000) {
        if (iy > 0x43f00000) {
            if (ix <= 0x3fefffff) return if (hy < 0) huge * huge else tiny * tiny;
            if (ix >= 0x3ff00000) return if (hy > 0) huge * huge else tiny * tiny;
        }
        if (ix < 0x3fefffff) return if (hy < 0) s * huge * huge else s * tiny * tiny;
        if (ix > 0x3ff00000) return if (hy > 0) s * huge * huge else s * tiny * tiny;
        const t = ax - one;
        const w = (t * t) * (0.5 - t * (0.3333333333333333333333 - t * 0.25));
        const u = ivln2_h * t;
        const v = t * ivln2_l - w * ivln2;
        t1 = set_lo(u + v, 0);
        t2 = v - (t1 - u);
    } else {
        n = 0;
        if (ix < 0x00100000) {
            ax *= two53;
            n -= 53;
            ix = hi(ax);
        }
        n += (ix >> 20) - 0x3ff;
        const j: i32 = ix & 0x000fffff;
        ix = j | 0x3ff00000;
        var k: usize = undefined;
        if (j <= 0x3988E) {
            k = 0;
        } else if (j < 0xBB67A) {
            k = 1;
        } else {
            k = 0;
            n += 1;
            ix -= 0x00100000;
        }
        ax = set_hi(ax, ix);

        var u = ax - bp[k];
        var v = one / (ax + bp[k]);
        const ss = u * v;
        const s_h = set_lo(ss, 0);
        var t_h = words(((ix >> 1) | 0x20000000) + 0x00080000 + (@as(i32, @intCast(k)) << 18), 0);
        var t_l = ax - (t_h - bp[k]);
        const s_l = v * ((u - s_h * t_h) - s_h * t_l);
        var s2 = ss * ss;
        var r = s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))));
        r += s_l * (s_h + ss);
        s2 = s_h * s_h;
        t_h = set_lo(3.0 + s2 + r, 0);
        t_l = r - ((t_h - 3.0) - s2);
        u = s_h * t_h;
        v = s_l * t_h + t_l * ss;
        const p_h = set_lo(u + v, 0);
        const p_l = v - (p_h - u);
        const z_h = cp_h * p_h;
        const z_l = cp_l * p_h + p_l * cp + dp_l[k];
        const t: f64 = @floatFromInt(n);
        t1 = set_lo((((z_h + z_l) + dp_h[k]) + t), 0);
        t2 = z_l - (((t1 - t) - dp_h[k]) - z_h);
    }

    const y1 = set_lo(y, 0);
    const p_l = (y - y1) * t1 + y * t2;
    var p_h = y1 * t1;
    var z = p_l + p_h;
    var j: i32 = hi(z);
    var i: i32 = @bitCast(lo(z));
    if (j >= 0x40900000) {
        if (((j - 0x40900000) | i) != 0) {
            return s * huge * huge;
        } else {
            if (p_l + ovt > z - p_h) return s * huge * huge;
        }
    } else if ((j & 0x7fffffff) >= 0x4090cc00) {
        if (((j -% @as(i32, @bitCast(@as(u32, 0xc090cc00)))) | i) != 0) {
            return s * tiny * tiny;
        } else {
            if (p_l <= z - p_h) return s * tiny * tiny;
        }
    }
    i = j & 0x7fffffff;
    var k: i32 = (i >> 20) - 0x3ff;
    n = 0;
    if (i > 0x3fe00000) {
        n = j + (@as(i32, 0x00100000) >> @intCast(k + 1));
        k = ((n & 0x7fffffff) >> 20) - 0x3ff;
        const t = words(n & ~(@as(i32, 0x000fffff) >> @intCast(k)), 0);
        n = ((n & 0x000fffff) | 0x00100000) >> @intCast(20 - k);
        if (j < 0) n = -n;
        p_h -= t;
    }
    var t = set_lo(p_l + p_h, 0);
    const u = t * lg2_h;
    const v = (p_l - (t - p_h)) * lg2 + t * lg2_l;
    z = u + v;
    const w = v - (z - u);
    t = z * z;
    t1 = z - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
    const r = (z * t1) / ((t1 - 2.0) - (w + z * w));
    z = one - (r - z);
    j = hi(z);
    j +%= @bitCast(@as(u32, @bitCast(n)) << 20);
    if ((j >> 20) <= 0) {
        z = scalbn(z, n);
    } else {
        z = set_hi(z, hi(z) +% @as(i32, @bitCast(@as(u32, @bitCast(n)) << 20)));
    }
    return s * z;
}

fn kernel_cos(x: f64, y: f64) f64 {
    const C1: f64 = 4.16666666666666019037e-02;
    const C2: f64 = -1.38888888888741095749e-03;
    const C3: f64 = 2.48015872894767294178e-05;
    const C4: f64 = -2.75573143513906633035e-07;
    const C5: f64 = 2.08757232129817482790e-09;
    const C6: f64 = -1.13596475577881948265e-11;
    const ix: i32 = hi(x) & 0x7FFFFFFF;
    if (ix < 0x3E400000) {
        if (@as(i32, @intFromFloat(x)) == 0) return 1.0;
    }
    const z = x * x;
    const r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))));
    if (ix < 0x3FD33333) {
        return 1.0 - (0.5 * z - (z * r - x * y));
    }
    const qx: f64 = if (ix > 0x3FE90000) 0.28125 else words(ix - 0x00200000, 0);
    const iz = 0.5 * z - qx;
    const a = 1.0 - qx;
    return a - (iz - (z * r - x * y));
}

fn kernel_sin(x: f64, y: f64, iy: i32) f64 {
    const S1: f64 = -1.66666666666666324348e-01;
    const S2: f64 = 8.33333333332248946124e-03;
    const S3: f64 = -1.98412698298579493134e-04;
    const S4: f64 = 2.75573137070700676789e-06;
    const S5: f64 = -2.50507602534068634195e-08;
    const S6: f64 = 1.58969099521155010221e-10;
    const ix: i32 = hi(x) & 0x7FFFFFFF;
    if (ix < 0x3E400000) {
        if (@as(i32, @intFromFloat(x)) == 0) return x;
    }
    const z = x * x;
    const v = z * x;
    const r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
    if (iy == 0) return x + v * (S1 + z * r);
    return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

const npio2_hw = [32]i32{
    0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
    0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
    0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
    0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
    0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
    0x404858EB, 0x404921FB,
};

/// Argument reduction for |x| up to 2^19*(pi/2) (the game never goes
/// further: qClock would need 228 hours of play). Larger arguments fall
/// back to Zig's @sin.
fn rem_pio2(x: f64, y: *[2]f64) ?i32 {
    const invpio2: f64 = 6.36619772367581382433e-01;
    const pio2_1: f64 = 1.57079632673412561417e+00;
    const pio2_1t: f64 = 6.07710050650619224932e-11;
    const pio2_2: f64 = 6.07710050630396597660e-11;
    const pio2_2t: f64 = 2.02226624879595063154e-21;
    const pio2_3: f64 = 2.02226624871116645580e-21;
    const pio2_3t: f64 = 8.47842766036889956997e-32;

    const hx = hi(x);
    const ix: i32 = hx & 0x7FFFFFFF;
    if (ix <= 0x3FE921FB) {
        y[0] = x;
        y[1] = 0;
        return 0;
    }
    if (ix < 0x4002D97C) {
        if (hx > 0) {
            var z = x - pio2_1;
            if (ix != 0x3FF921FB) {
                y[0] = z - pio2_1t;
                y[1] = (z - y[0]) - pio2_1t;
            } else {
                z -= pio2_2;
                y[0] = z - pio2_2t;
                y[1] = (z - y[0]) - pio2_2t;
            }
            return 1;
        } else {
            var z = x + pio2_1;
            if (ix != 0x3FF921FB) {
                y[0] = z + pio2_1t;
                y[1] = (z - y[0]) + pio2_1t;
            } else {
                z += pio2_2;
                y[0] = z + pio2_2t;
                y[1] = (z - y[0]) + pio2_2t;
            }
            return -1;
        }
    }
    if (ix <= 0x413921FB) {
        var t = @abs(x);
        const n: i32 = @intFromFloat(t * invpio2 + 0.5);
        const fnn: f64 = @floatFromInt(n);
        var r = t - fnn * pio2_1;
        var w = fnn * pio2_1t;
        if (n < 32 and ix != npio2_hw[@intCast(n - 1)]) {
            y[0] = r - w;
        } else {
            const j: i32 = ix >> 20;
            y[0] = r - w;
            var high: u32 = @bitCast(hi(y[0]));
            var i: i32 = j - @as(i32, @intCast((high >> 20) & 0x7FF));
            if (i > 16) {
                t = r;
                w = fnn * pio2_2;
                r = t - w;
                w = fnn * pio2_2t - ((t - r) - w);
                y[0] = r - w;
                high = @bitCast(hi(y[0]));
                i = j - @as(i32, @intCast((high >> 20) & 0x7FF));
                if (i > 49) {
                    t = r;
                    w = fnn * pio2_3;
                    r = t - w;
                    w = fnn * pio2_3t - ((t - r) - w);
                    y[0] = r - w;
                }
            }
        }
        y[1] = (r - y[0]) - w;
        if (hx < 0) {
            y[0] = -y[0];
            y[1] = -y[1];
            return -n;
        }
        return n;
    }
    return null;
}

pub fn sin(x: f64) f64 {
    const ix: i32 = hi(x) & 0x7FFFFFFF;
    if (ix <= 0x3FE921FB) return kernel_sin(x, 0.0, 0);
    if (ix >= 0x7FF00000) return x - x;
    var y: [2]f64 = undefined;
    const n = rem_pio2(x, &y) orelse return @sin(x);
    return switch (n & 3) {
        0 => kernel_sin(y[0], y[1], 1),
        1 => kernel_cos(y[0], y[1]),
        2 => -kernel_sin(y[0], y[1], 1),
        else => -kernel_cos(y[0], y[1]),
    };
}
