//! IEEE 754 binary64 add, subtract, multiply and compare in integer
//! arithmetic, for the badge (the Cortex-M33's FPU is single precision, so
//! every f64 operation is a library call). Results are bit-exact with any
//! IEEE double unit (round to nearest, ties to even; subnormals, infinities
//! and NaNs included): `tests.zig` checks them against the host's FPU on
//! hundreds of thousands of operands per run, millions in development.
//!
//! compiler_rt's generic versions cost ~155 cycles per add in ReleaseSmall
//! (64-bit shifts become calls); these work on 32-bit halves and are
//! exported on the badge only (ARM), as strong symbols that the linker
//! picks over compiler_rt's weak ones. Host and wasm builds use real f64.

const std = @import("std");
const builtin = @import("builtin");

const sign_bit: u64 = 1 << 63;
const exp_mask: u64 = 0x7ff0000000000000;
const frac_mask: u64 = (1 << 52) - 1;
const implicit: u64 = 1 << 52;
const inf_bits: u64 = exp_mask;
const qnan_bit: u64 = 1 << 51;

/// x >> n for 1 <= n <= 63, with the bits shifted out ORed into bit 0.
inline fn shr_sticky(x: u64, n: u32) u64 {
    const hi: u32 = @truncate(x >> 32);
    const lo: u32 = @truncate(x);
    var rhi: u32 = undefined;
    var rlo: u32 = undefined;
    var lost: u32 = undefined;
    if (n >= 32) {
        const k: u5 = @intCast(n - 32);
        rlo = hi >> k;
        rhi = 0;
        lost = lo | (if (k == 0) 0 else hi << @intCast(32 - @as(u32, k)));
    } else {
        const k: u5 = @intCast(n);
        rlo = (lo >> k) | (hi << @intCast(32 - n));
        rhi = hi >> k;
        lost = lo << @intCast(32 - n);
    }
    return (@as(u64, rhi) << 32) | rlo | @intFromBool(lost != 0);
}

/// x << n for 0 <= n <= 63.
inline fn shl(x: u64, n: u32) u64 {
    if (n == 0) return x;
    const hi: u32 = @truncate(x >> 32);
    const lo: u32 = @truncate(x);
    if (n >= 32) {
        const k: u5 = @intCast(n - 32);
        return @as(u64, lo << k) << 32;
    }
    const k: u5 = @intCast(n);
    return (@as(u64, (hi << k) | (lo >> @intCast(32 - n))) << 32) | (lo << k);
}

inline fn clz64(x: u64) u32 {
    const hi: u32 = @truncate(x >> 32);
    if (hi != 0) return @clz(hi);
    return 32 + @as(u32, @clz(@as(u32, @truncate(x))));
}

/// Round and pack: `m` has its leading 1 at bit 62 (bits 0..9 are round
/// and sticky bits), the value is m * 2^(e - 1085); `e` is the biased
/// exponent before rounding (any value).
inline fn round_pack(sign: u64, e_in: i32, m_in: u64) u64 {
    var e = e_in;
    var m = m_in;
    if (e >= 0x7ff) return sign | inf_bits;
    if (e <= 0) {
        const s: i32 = 1 - e;
        m = if (s > 63) @intFromBool(m != 0) else shr_sticky(m, @intCast(s));
        e = 0;
    }
    var r: u64 = (@as(u64, @intCast(e)) << 52) + (m >> 10);
    if (e > 0) r -= implicit; // the leading bit is the implicit one
    const rem: u32 = @as(u32, @truncate(m)) & 0x3ff;
    if (rem > 0x200 or (rem == 0x200 and (r & 1) != 0)) r += 1;
    return sign | r;
}

/// Pack a normal result: `m` with its leading 1 at bit 62, 1 <= e <= 0x7fe.
/// Ties to even without branches: adding 0x1ff plus the would-be last bit
/// carries exactly when the 10 dropped bits are above half, or at half
/// with an odd last bit; a carry out of the significand bumps the exponent
/// (to infinity at the top), as it should.
inline fn pack_normal(sign: u64, e: u32, m: u64) u64 {
    const rounded = (m + 0x1ff + ((m >> 10) & 1)) >> 10;
    return (sign | (@as(u64, e - 1) << 52)) + rounded;
}

pub inline fn add(a: u64, b: u64) u64 {
    // Fast path: both normal, the larger first, the result normal.
    const ha: u32 = @truncate(a >> 32);
    const hb: u32 = @truncate(b >> 32);
    const ea_f: u32 = (ha >> 20) & 0x7ff;
    const eb_f: u32 = (hb >> 20) & 0x7ff;
    if (ea_f -% 1 < 0x7fe and eb_f -% 1 < 0x7fe) {
        var x = a;
        var y = b;
        var ex = ea_f;
        var ey = eb_f;
        if ((y & ~sign_bit) > (x & ~sign_bit)) {
            x = b;
            y = a;
            ex = eb_f;
            ey = ea_f;
        }
        const mx: u64 = ((x & frac_mask) | implicit) << 9; // leading bit 61
        var my: u64 = ((y & frac_mask) | implicit) << 9;
        const diff = ex - ey;
        if (diff != 0) my = if (diff >= 64) 1 else shr_sticky(my, diff);
        var m: u64 = undefined;
        var e: u32 = undefined;
        if (((a ^ b) & sign_bit) == 0) {
            m = mx + my; // leading bit 61 or 62
            if ((m >> 62) != 0) {
                e = ex + 1;
            } else {
                m <<= 1;
                e = ex;
            }
        } else if (diff >= 2) {
            m = mx - my; // leading bit 60 or 61
            if ((m >> 61) != 0) {
                m <<= 1;
                e = ex;
            } else {
                m <<= 2;
                e = ex - 1;
            }
        } else {
            // Exponents differ by at most one: exact, may cancel.
            m = mx - my;
            if (m == 0) return 0;
            const z = clz64(m); // >= 2
            m = shl(m, z - 1);
            const ei: i32 = @as(i32, @intCast(ex)) + 2 - @as(i32, @intCast(z));
            if (ei < 1) return round_pack(x & sign_bit, ei, m);
            e = @intCast(ei);
        }
        if (e -% 1 < 0x7fe) return pack_normal(x & sign_bit, e, m);
        return round_pack(x & sign_bit, @intCast(e), m);
    }
    // One operand zero, the other normal: x + 0 = x.
    if (eb_f -% 1 < 0x7fe and (a & ~sign_bit) == 0) return b;
    if (ea_f -% 1 < 0x7fe and (b & ~sign_bit) == 0) return a;
    return add_general(a, b);
}

pub fn add_general(a_in: u64, b_in: u64) u64 {
    var a = a_in;
    var b = b_in;
    var a_abs = a & ~sign_bit;
    var b_abs = b & ~sign_bit;
    // Zero, infinity or NaN among the operands.
    if (a_abs -% 1 >= inf_bits - 1 or b_abs -% 1 >= inf_bits - 1) {
        if (a_abs > inf_bits) return a | qnan_bit;
        if (b_abs > inf_bits) return b | qnan_bit;
        if (a_abs == inf_bits) {
            if ((a ^ b) == sign_bit) return inf_bits | qnan_bit; // inf - inf
            return a;
        }
        if (b_abs == inf_bits) return b;
        if (a_abs == 0) {
            if (b_abs == 0) return a & b;
            return b;
        }
        return a; // b is zero
    }
    if (b_abs > a_abs) {
        const t = a;
        a = b;
        b = t;
        const u = a_abs;
        a_abs = b_abs;
        b_abs = u;
    }
    const ea_f: u32 = @intCast(a_abs >> 52);
    const eb_f: u32 = @intCast(b_abs >> 52);
    var ma: u64 = a_abs & frac_mask;
    var mb: u64 = b_abs & frac_mask;
    const ea: u32 = if (ea_f == 0) 1 else ea_f;
    const eb: u32 = if (eb_f == 0) 1 else eb_f;
    if (ea_f != 0) ma |= implicit;
    if (eb_f != 0) mb |= implicit;
    // Leading bit at 61: room for the carry of an addition.
    ma <<= 9;
    mb <<= 9;
    const diff = ea - eb;
    if (diff != 0) mb = if (diff >= 64) 1 else shr_sticky(mb, diff);
    const sign = a & sign_bit;
    var m: u64 = undefined;
    if (((a ^ b) & sign_bit) != 0) {
        m = ma - mb;
        if (m == 0) return 0; // x - x = +0
    } else {
        m = ma + mb;
    }
    // Normalise to the leading bit at 62: value m * 2^(ea - 1084).
    const z = clz64(m); // >= 1
    return round_pack(sign, @as(i32, @intCast(ea)) + 2 - @as(i32, @intCast(z)), shl(m, z - 1));
}

pub inline fn sub(a: u64, b: u64) u64 {
    return add(a, b ^ sign_bit);
}

/// The significand with its leading 1 at bit 52 and the matching biased
/// exponent (may go below 1 for subnormals); x is finite and nonzero.
inline fn unpack(x_abs: u64, e: *i32) u64 {
    const ef: i32 = @intCast(x_abs >> 52);
    var m = x_abs & frac_mask;
    if (ef == 0) {
        const s = clz64(m) - 11; // bring the leading 1 to bit 52
        m = shl(m, s);
        e.* = 1 - @as(i32, @intCast(s));
    } else {
        m |= implicit;
        e.* = ef;
    }
    return m;
}

pub inline fn mul(a: u64, b: u64) u64 {
    // Fast path: both normal, the product normal.
    const ea_f: u32 = @as(u32, @truncate(a >> 52)) & 0x7ff;
    const eb_f: u32 = @as(u32, @truncate(b >> 52)) & 0x7ff;
    if (ea_f -% 1 < 0x7fe and eb_f -% 1 < 0x7fe) {
        const ma = (a & frac_mask) | implicit;
        const mb = (b & frac_mask) | implicit;
        const a0: u64 = ma & 0xffffffff;
        const a1: u64 = ma >> 32;
        const b0: u64 = mb & 0xffffffff;
        const b1: u64 = mb >> 32;
        const p00 = a0 * b0;
        const p01 = a0 * b1;
        const p10 = a1 * b0;
        const p11 = a1 * b1;
        const mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff);
        const lo = (mid << 32) | (p00 & 0xffffffff);
        const hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
        var m = (hi << 22) | (lo >> 42) | @intFromBool((lo & ((1 << 42) - 1)) != 0);
        var e: i32 = @as(i32, @intCast(ea_f + eb_f)) - 1023;
        if (m >= 1 << 63) {
            m = (m >> 1) | (m & 1);
            e += 1;
        }
        if (e >= 1 and e <= 0x7fe) return pack_normal((a ^ b) & sign_bit, @intCast(e), m);
        return round_pack((a ^ b) & sign_bit, e, m);
    }
    const sign = (a ^ b) & sign_bit;
    const a_abs = a & ~sign_bit;
    const b_abs = b & ~sign_bit;
    if (a_abs -% 1 >= inf_bits - 1 or b_abs -% 1 >= inf_bits - 1) {
        if (a_abs > inf_bits) return a | qnan_bit;
        if (b_abs > inf_bits) return b | qnan_bit;
        if (a_abs == inf_bits) {
            if (b_abs == 0) return inf_bits | qnan_bit;
            return sign | inf_bits;
        }
        if (b_abs == inf_bits) {
            if (a_abs == 0) return inf_bits | qnan_bit;
            return sign | inf_bits;
        }
        return sign; // a zero
    }
    var ea: i32 = undefined;
    var eb: i32 = undefined;
    const ma = unpack(a_abs, &ea);
    const mb = unpack(b_abs, &eb);
    // 53 x 53 -> 106 bits from 32-bit halves.
    const a0: u64 = ma & 0xffffffff;
    const a1: u64 = ma >> 32;
    const b0: u64 = mb & 0xffffffff;
    const b1: u64 = mb >> 32;
    const p00 = a0 * b0;
    const p01 = a0 * b1;
    const p10 = a1 * b0;
    const p11 = a1 * b1;
    const mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff);
    const lo = (mid << 32) | (p00 & 0xffffffff);
    const hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    // P >> 42, sticky from the 42 bits below.
    var m = (hi << 22) | (lo >> 42) | @intFromBool((lo & ((1 << 42) - 1)) != 0);
    var e = ea + eb - 1023;
    if (m >= 1 << 63) {
        m = (m >> 1) | (m & 1);
        e += 1;
    }
    return round_pack(sign, e, m);
}

inline fn unordered(a: u64, b: u64) bool {
    return (a & ~sign_bit) > inf_bits or (b & ~sign_bit) > inf_bits;
}

/// Total order key on non-NaN values, -0 == +0.
inline fn key(x: u64) i64 {
    const mag: i64 = @bitCast(x & ~sign_bit);
    return if ((x & sign_bit) != 0) -mag else mag;
}

pub fn eq(a: u64, b: u64) bool {
    return !unordered(a, b) and key(a) == key(b);
}
pub fn lt(a: u64, b: u64) bool {
    return !unordered(a, b) and key(a) < key(b);
}
pub fn le(a: u64, b: u64) bool {
    return !unordered(a, b) and key(a) <= key(b);
}

/// floor(x), exact; NaN and infinities pass through, -0 stays -0.
pub fn floor(x: u64) u64 {
    const e: u32 = @intCast((x >> 52) & 0x7ff);
    if (e >= 1023 + 52) return x; // integral, inf or NaN
    if (e < 1023) { // |x| < 1
        if ((x & ~sign_bit) == 0) return x;
        return if ((x & sign_bit) != 0) 0xbff0000000000000 else 0;
    }
    const mask: u64 = frac_mask >> @intCast(e - 1023);
    if ((x & mask) == 0) return x;
    const t = x & ~mask;
    return if ((x & sign_bit) != 0) t + (mask + 1) else t;
}

/// ceil(x), exact; -0.5 gives -0.
pub fn ceil(x: u64) u64 {
    const e: u32 = @intCast((x >> 52) & 0x7ff);
    if (e >= 1023 + 52) return x;
    if (e < 1023) {
        if ((x & ~sign_bit) == 0) return x;
        return if ((x & sign_bit) != 0) sign_bit else 0x3ff0000000000000;
    }
    const mask: u64 = frac_mask >> @intCast(e - 1023);
    if ((x & mask) == 0) return x;
    const t = x & ~mask;
    return if ((x & sign_bit) != 0) t else t + (mask + 1);
}

/// f64 -> i32 by truncation, saturating like compiler_rt (NaN saturates
/// by its sign too).
pub fn to_i32(x: u64) i32 {
    const e: i32 = @as(i32, @intCast((x >> 52) & 0x7ff)) - 1023;
    if (e < 0) return 0;
    const neg = (x & sign_bit) != 0;
    if (e >= 31) return if (neg) std.math.minInt(i32) else std.math.maxInt(i32);
    const m: u32 = @truncate((x & frac_mask | implicit) >> @intCast(52 - e));
    const r: i32 = @intCast(m);
    return if (neg) -r else r;
}

// --- exports (badge only) ---------------------------------------------

pub const aapcs: std.builtin.CallingConvention = if (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()) .{ .arm_aapcs = .{} } else .c;

fn bits(x: f64) u64 {
    return @bitCast(x);
}
fn float(x: u64) f64 {
    return @bitCast(x);
}

fn aeabi_dadd(a: f64, b: f64) callconv(aapcs) f64 {
    return float(add(bits(a), bits(b)));
}
fn aeabi_dsub(a: f64, b: f64) callconv(aapcs) f64 {
    return float(sub(bits(a), bits(b)));
}
fn aeabi_drsub(a: f64, b: f64) callconv(aapcs) f64 {
    return float(sub(bits(b), bits(a)));
}
fn aeabi_dmul(a: f64, b: f64) callconv(aapcs) f64 {
    return float(mul(bits(a), bits(b)));
}
fn aeabi_dcmpeq(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(eq(bits(a), bits(b)));
}
fn aeabi_dcmplt(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(lt(bits(a), bits(b)));
}
fn aeabi_dcmple(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(le(bits(a), bits(b)));
}
fn aeabi_dcmpgt(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(lt(bits(b), bits(a)));
}
fn aeabi_dcmpge(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(le(bits(b), bits(a)));
}
fn aeabi_dcmpun(a: f64, b: f64) callconv(aapcs) i32 {
    return @intFromBool(unordered(bits(a), bits(b)));
}

fn c_floor(x: f64) callconv(.c) f64 {
    return float(floor(bits(x)));
}
fn c_ceil(x: f64) callconv(.c) f64 {
    return float(ceil(bits(x)));
}
fn aeabi_d2iz(x: f64) callconv(aapcs) i32 {
    return to_i32(bits(x));
}

/// Only the badge (32-bit ARM without a double-precision FPU).
pub const export_on_target = (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()) and
    !std.Target.arm.featureSetHas(builtin.cpu.features, .fp64);

comptime {
    _ = @import("softfloat_arm.zig"); // __aeabi_dadd, __aeabi_dsub, __aeabi_dmul
    if (export_on_target) {
        @export(&aeabi_drsub, .{ .name = "__aeabi_drsub" });
        @export(&aeabi_dcmpeq, .{ .name = "__aeabi_dcmpeq" });
        @export(&aeabi_dcmplt, .{ .name = "__aeabi_dcmplt" });
        @export(&aeabi_dcmple, .{ .name = "__aeabi_dcmple" });
        @export(&aeabi_dcmpgt, .{ .name = "__aeabi_dcmpgt" });
        @export(&aeabi_dcmpge, .{ .name = "__aeabi_dcmpge" });
        @export(&aeabi_dcmpun, .{ .name = "__aeabi_dcmpun" });
        @export(&c_floor, .{ .name = "floor" });
        @export(&c_ceil, .{ .name = "ceil" });
        @export(&aeabi_d2iz, .{ .name = "__aeabi_d2iz" });
    }
}

// --- self-test (badge-bench, --poke paperclips_bench=99) ----------------

/// Runs `n` random operand pairs through the f64 operators as compiled
/// (on the badge: the Thumb-2 fast paths and these exports) and compares
/// with the integer reference functions above. Returns the mismatches.
pub fn self_test(n: u32, seed: u64) u32 {
    var st: u64 = 0x9e3779b97f4a7c15 ^ seed;
    var bad: u32 = 0;
    var i: u32 = 0;
    test_bad = @splat(0);
    while (i < n) : (i += 1) {
        const a = test_operand(&st);
        const b = if (i % 2 == 0) test_operand(&st) else test_related(&st, a);
        const fa: f64 = @bitCast(a);
        const fb: f64 = @bitCast(b);
        const pa: *volatile f64 = @constCast(&fa);
        const pb: *volatile f64 = @constCast(&fb);
        const x = pa.*;
        const y = pb.*;
        const got = [5]u64{ @bitCast(x + y), @bitCast(x - y), @bitCast(x * y), @intFromBool(x < y), @bitCast(@floor(x)) };
        const want = [5]u64{ add(a, b), sub(a, b), mul(a, b), @intFromBool(lt(a, b)), floor(a) };
        for (0..5) |k| {
            const ok = if (k == 3) got[k] == want[k] else same(@bitCast(got[k]), want[k]);
            if (!ok) {
                bad += 1;
                if (test_bad[k] == 0) test_first[k] = .{ a, b, got[k], want[k] };
                test_bad[k] += 1;
            }
        }
    }
    return bad;
}

/// Self-test details: failures per operation (add, sub, mul, lt, floor)
/// and the first failing a, b, got, want of each.
pub var test_bad: [5]u32 = @splat(0);
pub var test_first: [5][4]u64 = undefined;

fn same(x: f64, want: u64) bool {
    const xb: u64 = @bitCast(x);
    if ((want & ~sign_bit) > inf_bits) return (xb & ~sign_bit) > inf_bits;
    return xb == want;
}

fn test_next(st: *u64) u64 {
    st.* ^= st.* << 13;
    st.* ^= st.* >> 7;
    st.* ^= st.* << 17;
    return st.*;
}

const test_specials = [_]u64{ 0, 1 << 63, inf_bits, inf_bits | sign_bit, inf_bits | qnan_bit, 1, frac_mask, implicit, 0x7fefffffffffffff, 0x3ff0000000000000, 0xbff0000000000000, 0x3ff0000000000001, 0x3fefffffffffffff, 0x8000000000000001, 0x4340000000000000, 0x0020000000000000, 0x7fe0000000000000 };

fn test_operand(st: *u64) u64 {
    const r = test_next(st);
    switch (r % 8) {
        0 => return test_specials[@intCast((r >> 8) % test_specials.len)],
        1 => return test_next(st),
        2 => return test_next(st) & 0x800fffffffffffff,
        3 => {
            // near the exponent extremes (overflow, underflow)
            const e: u64 = if ((r >> 8) & 1 == 0) 1 + (r >> 9) % 40 else 0x7fe - (r >> 9) % 40;
            return (test_next(st) & 0x800fffffffffffff) | (e << 52);
        },
        else => {
            const e = 1023 + (r >> 8) % 120 -% 60;
            var m = test_next(st) & frac_mask;
            if ((r >> 20) % 3 == 0) m &= 0xffff000000000;
            return (r & sign_bit) | (e << 52) | m;
        },
    }
}

fn test_related(st: *u64, a: u64) u64 {
    const r = test_next(st);
    const d = (r >> 8) % 8;
    return switch (r % 4) {
        0 => a ^ sign_bit,
        1 => (a ^ sign_bit) +% d,
        2 => a +% ((r >> 16) % 65536),
        else => (a ^ (r & sign_bit)) -% (((r >> 12) % 3) << 52) +% d,
    };
}
